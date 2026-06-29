# MOSSDeF OpenWrt package repository

Unified binary package repo for [MOSSDeF](https://docs.mossdef.org) OpenWrt packages.

## Layout

```
releases/<openwrt-version>/<arch>/
```

- `releases/25.12/<arch>/` — apk packages + signed `packages.adb` index (OpenWrt 25.12+).
- `releases/24.10/<arch>/` — opkg `.ipk` packages + `Packages` index (OpenWrt 24.10, frozen).

`<arch>` matches the OpenWrt target architecture string exactly. Architecture-independent
(`arch:all`) packages are duplicated into every arch directory so a single feed line per
router provides everything.

## Keys

- `apk.mossdef.org.pem` — apk signing public key.
- `stangri.pub` — usign public key for the legacy opkg (`.ipk`) feeds.

Documentation: <https://docs.mossdef.org>
