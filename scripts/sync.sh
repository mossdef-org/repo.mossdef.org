#!/bin/bash
# sync.sh — reconcile repo.mossdef.org from package-repo GitHub Releases (CI edition).
#
# Runs inside the repo.mossdef.org GitHub Actions workflow (see
# .github/workflows/sync.yml). Same job as the box's scripts/sync_repo.sh, but:
#   - package set is DISCOVERED dynamically (any mossdef-org repo carrying
#     .github/workflows/openwrt-release.yml), with per-repo exceptions declared
#     in scripts/packages.yml (non-main gating branch, 25.12-only lines, excludes).
#   - OpenWrt host tools (apk mkndx, mkhash, usign, ipkg-make-index.sh) and the
#     signing keys come from the environment (the workflow provides them).
#   - single-writer is the workflow's concurrency group, not flock.
#   - a GC pass removes published files a package no longer produces (dropped
#     arch or dropped release line) so stale binaries expire.
#
# Required env (set by the workflow):
#   REPO_DIR   checkout of repo.mossdef.org (default: $GITHUB_WORKSPACE or PWD)
#   APK_BIN MKHASH USIGN MKINDEX   absolute paths to the host tools
#   APK_KEY    apk mkndx signing key file        (from secret REPO_APK_KEY)
#   IPK_KEY    usign signing key file            (from secret IPK_KEY; 24.10 only)
# Optional env:
#   ORG (default mossdef-org)  WORKFLOW (default openwrt-release.yml)
#   PACKAGES_YML (default $REPO_DIR/scripts/packages.yml)  DRY_RUN  GIT_NAME  GIT_EMAIL
set -uo pipefail

### ----------------------------------------------------------------- config
REPO_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-$PWD}}"
readonly REPO_DIR
# exported (not readonly) so the discover() python subprocess inherits them
export ORG="${ORG:-mossdef-org}"
export WORKFLOW="${WORKFLOW:-openwrt-release.yml}"
export PACKAGES_YML="${PACKAGES_YML:-${REPO_DIR}/scripts/packages.yml}"
readonly GIT_NAME="${GIT_NAME:-github-actions[bot]}"
readonly GIT_EMAIL="${GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
readonly DRY_RUN="${DRY_RUN:-}"

# release lines to publish: "version ext"
readonly LINES=("25.12 apk" "24.10 ipk")

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die(){ log "FATAL: $*"; exit 1; }

# stem 'pkg-1.2.4-r5.apk' / 'pkg-1.2.4-5.ipk' -> 'pkg' (release 'r' optional)
pkg_stem(){ echo "${1}" | sed -E 's/-[0-9][^-]*-r?[0-9]+\.(apk|ipk)$//'; }

### ------------------------------------------------------------- preflight
command -v gh >/dev/null 2>&1        || die "gh CLI not found"
command -v python3 >/dev/null 2>&1   || die "python3 not found"
[ -n "${APK_BIN:-}" ] && [ -x "$APK_BIN" ] || die "apk (mkndx) not found: ${APK_BIN:-unset}"
[ -n "${MKHASH:-}" ]  && [ -x "$MKHASH" ]  || die "mkhash not found: ${MKHASH:-unset}"
[ -n "${USIGN:-}" ]   && [ -x "$USIGN" ]   || die "usign not found: ${USIGN:-unset}"
[ -n "${MKINDEX:-}" ] && [ -f "$MKINDEX" ] || die "ipkg-make-index.sh not found: ${MKINDEX:-unset}"
[ -f "${APK_KEY:-}" ] || die "apk signing key not found: ${APK_KEY:-unset}"
[ -f "${IPK_KEY:-}" ] || log "WARN: usign key not found (${IPK_KEY:-unset}) — 24.10 opkg signing will fail if any 24.10 package is published"
[ -d "${REPO_DIR}/.git" ] || die "not a git checkout: ${REPO_DIR}"

### --------------------------------------------- discover the package work-list
# Emits one line per package to publish:  <slug>\t<branch>\t<lines-csv>
# Dynamic: every ORG repo with WORKFLOW, minus packages.yml `exclude`, with
# per-repo `branch` and `only_2512` overrides (defaults: main / "25.12,24.10").
discover(){
  python3 - <<'PY'
import os, json, subprocess, sys

org = os.environ["ORG"]; wf = os.environ["WORKFLOW"]; yml = os.environ["PACKAGES_YML"]

def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""

# minimal YAML reader for our tiny, flat exceptions file (no external yq dependency).
# Inline comments are stripped, so `exclude:  # note` is still recognised.
def load_yaml(path):
    data = {"exclude": [], "only_2512": [], "branch": {}}
    if not os.path.exists(path):
        return data
    section = None
    for raw in open(path):
        line = raw.split("#", 1)[0].rstrip()      # drop inline comment + trailing ws
        if not line.strip():
            continue
        if not line[:1].isspace() and line.endswith(":"):
            section = line[:-1].strip(); continue
        item = line.strip()
        if section in ("exclude", "only_2512") and item.startswith("- "):
            data[section].append(item[2:].strip().strip('"\''))
        elif section == "branch" and ":" in item:
            k, v = item.split(":", 1)
            data["branch"][k.strip().strip('"\'')] = v.strip().strip('"\'')
    return data

exc = load_yaml(yml)

# list all org repos with their default branch (paginated)
repos = {}
page = 1
while True:
    out = gh("api", f"/orgs/{org}/repos?per_page=100&page={page}")
    try:
        arr = json.loads(out) if out else []
    except json.JSONDecodeError:
        arr = []
    if not arr:
        break
    for r in arr:
        repos[r["name"]] = r.get("default_branch", "main")
    if len(arr) < 100:
        break
    page += 1

work = []
for name in sorted(repos):
    if name in exc["exclude"]:
        continue
    # branch we gate/pull from: an explicit override, else the repo's default.
    # (pbr/luci-app-pbr/sunwait keep the build workflow on a version branch, not main.)
    branch = exc["branch"].get(name, repos[name])
    # keep only repos that actually carry the package build workflow on that branch
    if not gh("api", f"/repos/{org}/{name}/contents/.github/workflows/{wf}?ref={branch}", "--jq", ".name"):
        continue
    lines = "25.12" if name in exc["only_2512"] else "25.12,24.10"
    work.append(f"{org}/{name}\t{branch}\t{lines}")

sys.stdout.write("\n".join(work) + ("\n" if work else ""))
PY
}

### ----------------------------------------------- fan-stage per line (arch:all)
declare -A FANSTAGE
for line in "${LINES[@]}"; do read -r v _ <<< "$line"; FANSTAGE["$v"]="$(mktemp -d)"; done
cleanup(){ for d in "${FANSTAGE[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# download a repo's assets for one release line and place them; echoes count placed
fetch_place(){ # $1=slug $2=ver $3=ext
  local slug="$1" ver="$2" ext="$3" reldir="${REPO_DIR}/releases/$2" fst="${FANSTAGE[$2]}"
  local tmp base arch natural dst n=0 f
  tmp="$(mktemp -d)"
  if gh release download --repo "$slug" --dir "$tmp" --pattern "*_openwrt-${ver}_*.${ext}" --clobber >/dev/null 2>&1; then
    shopt -s nullglob
    for f in "$tmp"/*_openwrt-"${ver}"_*."${ext}"; do
      base="$(basename "$f")"; arch="${base##*_openwrt-${ver}_}"; arch="${arch%.${ext}}"
      [ -n "$arch" ] || continue
      natural="${base/_openwrt-${ver}_${arch}/}"       # -> pkg-ver-rel.<ext>
      if [ "$arch" = "all" ] || [ "$arch" = "noarch" ]; then
        rm -f "${fst}/$(pkg_stem "$natural")-"*."${ext}"; cp "$f" "${fst}/${natural}"
      else
        dst="${reldir}/${arch}"; mkdir -p "$dst"
        rm -f "${dst}/$(pkg_stem "$natural")-"*."${ext}"; cp "$f" "${dst}/${natural}"
      fi
      n=$((n+1))
    done
    shopt -u nullglob
  fi
  rm -rf "$tmp"; echo "$n"
}

# GC: remove published files for a package that its current release no longer
# produces (dropped arch, or dropped/again-excluded line). Only ever touches this
# package's own stems — never another package's. $2 = lines this pkg publishes.
gc_package(){ # $1=slug $2=lines-csv
  local slug="$1" pubcsv="$2" names
  names="$(gh release view --repo "$slug" --json assets --jq '.assets[].name' 2>/dev/null)" || return 0
  [ -n "$names" ] || return 0
  declare -A STEMS=() AUTH=()
  local n ext ver a natural stem
  while IFS= read -r n; do
    case "$n" in *_openwrt-*.ipk|*_openwrt-*.apk) ;; *) continue;; esac
    ext="${n##*.}"; ver="${n#*_openwrt-}"; ver="${ver%%_*}"
    a="${n##*_openwrt-${ver}_}"; a="${a%.${ext}}"
    natural="${n/_openwrt-${ver}_${a}/}"; stem="$(pkg_stem "$natural")"
    [ -n "$stem" ] || continue
    STEMS["$stem"]=1
    # only treat a line as authoritative if we actually publish it for this pkg
    case ",${pubcsv}," in *",${ver},"*) ;; *) continue;; esac
    case "$a" in all|noarch) a="ALL";; esac
    AUTH["${ver}|${stem}|${a}"]=1
  done <<< "$names"
  [ "${#STEMS[@]}" -gt 0 ] || return 0
  local line reldir f fb fstem archdir removed=0
  for line in "${LINES[@]}"; do
    read -r ver ext <<< "$line"
    reldir="${REPO_DIR}/releases/${ver}"; [ -d "$reldir" ] || continue
    shopt -s nullglob
    for f in "$reldir"/*/*."$ext"; do
      fb="$(basename "$f")"; fstem="$(pkg_stem "$fb")"
      [ -n "${STEMS[$fstem]:-}" ] || continue                     # not this package
      archdir="$(basename "$(dirname "$f")")"
      [ -n "${AUTH["${ver}|${fstem}|ALL"]:-}" ] && continue       # arch:all — kept everywhere
      [ -n "${AUTH["${ver}|${fstem}|${archdir}"]:-}" ] && continue
      if [ -n "$DRY_RUN" ]; then log "  GC [dry-run] would remove releases/${ver}/${archdir}/${fb}"
      else rm -f "$f"; fi
      removed=$((removed+1))
    done
    shopt -u nullglob
  done
  [ "$removed" -gt 0 ] && log "  GC: ${removed} stale file(s) for $(basename "$slug")"
  return 0
}

### per-arch index generators
reindex_apk(){ ( cd "$1" && rm -f packages.adb && \
  "$APK_BIN" mkndx --allow-untrusted --sign-key "$APK_KEY" --output packages.adb ./*.apk >/dev/null 2>&1 ); }
reindex_ipk(){ ( cd "$1" && rm -f Packages Packages.gz Packages.sig Packages.manifest && \
  MKHASH="$MKHASH" "$MKINDEX" . 2>/dev/null > Packages.manifest && \
  grep -vE '^(Maintainer|LicenseFiles|Source|Require)' Packages.manifest > Packages && rm -f Packages.manifest && \
  gzip -9nc Packages > Packages.gz && \
  "$USIGN" -S -m Packages -s "$IPK_KEY" -x Packages.sig >/dev/null 2>&1 ); }

### ---------------------------------------------------------- 0. refresh clone
log "sync start (REPO_DIR=${REPO_DIR}${DRY_RUN:+, DRY_RUN})"
git -C "$REPO_DIR" config user.name  "$GIT_NAME"
git -C "$REPO_DIR" config user.email "$GIT_EMAIL"

### ------------------------------------------------------ discover work-list
mapfile -t WORK < <(discover)
[ "${#WORK[@]}" -gt 0 ] || die "no packages discovered (check gh auth / packages.yml)"
log "packages to publish: ${#WORK[@]}"

declare -a CHANGED_PKGS=()

### 1. per repo: gate on run status, rerun failed, else fetch its published lines
for row in "${WORK[@]}"; do
  IFS=$'\t' read -r slug branch lines_csv <<< "$row"
  pkg="$(basename "$slug")"
  run_json="$(gh run list --repo "$slug" --workflow "$WORKFLOW" --branch "$branch" --limit 1 \
              --json databaseId,status,conclusion 2>/dev/null || echo '[]')"
  read -r rid status concl < <(printf '%s' "$run_json" | python3 -c '
import sys,json
a=json.load(sys.stdin); r=a[0] if a else {}
print(r.get("databaseId","-"), r.get("status","-"), r.get("conclusion","-") or "-")' 2>/dev/null || echo "- - -")
  if [ "${rid:--}" = "-" ]; then log "  ${pkg}: no runs on ${branch} — skip"; continue; fi
  if [ "$status" != "completed" ]; then log "  ${pkg}: run ${rid} ${status} — defer"; continue; fi
  if [ "$concl" != "success" ]; then
    log "  ${pkg}: run ${rid} concluded '${concl}' — re-running failed jobs"
    if [ -n "$DRY_RUN" ]; then log "  ${pkg}: [dry-run] would 'gh run rerun ${rid} --failed'"; continue; fi
    gh run rerun "$rid" --failed --repo "$slug" >/dev/null 2>&1 \
      && log "  ${pkg}: rerun triggered — defer" || log "  ${pkg}: WARN could not trigger rerun"
    continue
  fi
  placed=0
  for line in "${LINES[@]}"; do
    read -r v e <<< "$line"
    case ",${lines_csv}," in *",${v},"*) ;; *) continue;; esac   # pkg doesn't publish this line
    c="$(fetch_place "$slug" "$v" "$e")"; placed=$((placed + c))
  done
  gc_package "$slug" "$lines_csv"
  log "  ${pkg}: placed ${placed} pkg file(s) from run ${rid}"
  [ "$placed" -gt 0 ] && CHANGED_PKGS+=("$pkg")
done

### 2. per line: fan arch:all, reindex ONLY changed arch dirs
for line in "${LINES[@]}"; do
  read -r ver ext <<< "$line"
  reldir="${REPO_DIR}/releases/${ver}"; fst="${FANSTAGE[$ver]}"; mkdir -p "$reldir"

  # 2a. fan arch:all into every existing arch dir for this line
  shopt -s nullglob; fan_pkgs=( "$fst"/*."$ext" ); arch_dirs=( "$reldir"/*/ ); shopt -u nullglob
  if [ "${#fan_pkgs[@]}" -gt 0 ] && [ "${#arch_dirs[@]}" -gt 0 ]; then
    log "${ver}: fanning ${#fan_pkgs[@]} arch:all into ${#arch_dirs[@]} arch dir(s)"
    for archdir in "${arch_dirs[@]}"; do
      for f in "${fan_pkgs[@]}"; do rm -f "${archdir}$(pkg_stem "$(basename "$f")")-"*."$ext"; cp "$f" "$archdir"; done
    done
  elif [ "${#fan_pkgs[@]}" -gt 0 ]; then
    log "WARN ${ver}: ${#fan_pkgs[@]} arch:all staged but no arch dirs yet — deferring"
  fi

  # 2b. reindex ONLY arch dirs whose package set changed
  git -C "$REPO_DIR" add -A "releases/${ver}" >/dev/null 2>&1
  mapfile -t dirty < <(
    git -C "$REPO_DIR" diff --cached --name-only -- "releases/${ver}" 2>/dev/null \
      | grep -E "\\.${ext}\$" | awk -v OFS=/ -F/ 'NF{NF--; print}' | sort -u )
  if [ "${#dirty[@]}" -eq 0 ]; then
    log "${ver}: no package changes — indexes untouched"
  else
    log "${ver}: reindexing ${#dirty[@]} changed arch dir(s)"
    for rel in "${dirty[@]}"; do
      archdir="${REPO_DIR}/${rel}/"; [ -d "$archdir" ] || continue
      shopt -s nullglob; pkgs=( "$archdir"*."$ext" ); shopt -u nullglob
      if [ "${#pkgs[@]}" -eq 0 ]; then
        rm -f "${archdir}"packages.adb "${archdir}"Packages "${archdir}"Packages.gz "${archdir}"Packages.sig
        rmdir "$archdir" 2>/dev/null; continue
      fi
      if [ "$ext" = apk ]; then reindex_apk "$archdir" || log "WARN mkndx failed in ${archdir}"
      else reindex_ipk "$archdir" || log "WARN opkg index failed in ${archdir}"; fi
    done
  fi
done

### 3. commit + push (no force)
cd "$REPO_DIR" || die "cannot cd ${REPO_DIR}"
git add -A releases    # sync only ever changes releases/ — never stage CI scratch
if git diff --cached --quiet; then log "no changes — nothing to publish"; exit 0; fi
summary="$(printf '%s\n' "${CHANGED_PKGS[@]}" | sort -u | paste -sd, -)"
msg="$(date +%F): sync — ${summary:-update}"
if [ -n "$DRY_RUN" ]; then
  log "[dry-run] would commit + push: ${msg}"
  log "[dry-run] staged:"; git diff --cached --stat | tail -40
  exit 0
fi
git commit -q -m "$msg"
git pull -q --rebase origin main || die "rebase before push failed"
git push -q origin main && log "pushed: ${msg}" || die "push failed"
