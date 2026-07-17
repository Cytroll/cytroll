# Binaries

This folder holds executables embedded in `Cytroll.app/Binaries/` at build time.

## Required at build time

| File | Purpose |
|------|---------|
| `cytrollhelper` | Built from `Cytroll/Core/RootHelper/cytrollhelper.c` by `build.sh` |
| `insert_dylib` | Built from `Cytroll/Core/RootHelper/insert_dylib.c` by `build.sh` — patches `LC_LOAD_DYLIB` into a target app's Mach-O executable for per-app tweak injection |
| `tar` | Extract Procursus bootstrap archive |
| `zstd` | Decompress `.tar.zst` bootstrap |
| `ldid` | Pseudo-sign binaries after bootstrap extraction, and to re-sign injected third-party apps |

## Optional (bootstrap)

Bootstrap archives can be **downloaded on-device** (preferred, keeps IPA small) or bundled here:

| File | iOS version |
|------|-------------|
| `bootstrap_1800.tar.zst` | iOS 15.x |
| `bootstrap_1900.tar.zst` | iOS 16.0+ |

Run `Scripts/fetch-binaries.sh` on macOS to download tools and bootstrap archives.

## Security

- All jailbreak files install only under `/var/mobile/.lara_jb`
- `cytrollhelper` allowlists executables and blocks SSV paths
- Never place system binaries from `/System` here
- `insert_dylib` is compiled from vendored source (not downloaded as a
  precompiled binary like `ldid`/`tar`/`zstd`) so the exact bytes running
  on-device are auditable. `cytrollhelper` only allows it to operate on
  third-party app bundles under `Bundle/Application/*.app/` — never on
  system binaries.
