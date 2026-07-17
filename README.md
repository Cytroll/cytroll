# Cytroll

A minimal rootless package manager and bootstrap installer for iOS 15.0 - 17.x, designed to be installed via TrollStore.

## Overview

Cytroll acts as both a bootstrap installer and a package manager. Unlike traditional jailbreak apps that bundle the bootstrap inside the app bundle, Cytroll downloads the required `bootstrap.tar` on-demand to keep the `.ipa` size under 3MB. It uses native Swift parsers to interact with the dpkg status file and APT indices directly, avoiding slow shell wrappers.

## Architecture & AMFI Bypass

Cytroll uses the standard TrollStore Root Helper architecture (similar to Sileo and Filza). To execute commands outside the App Bundle (like `/var/mobile/.lara_jb/usr/bin/dpkg`) without being killed by Apple Mobile File Integrity (AMFI), Cytroll invokes a bundled command-line utility called `cytrollhelper`.

The `cytrollhelper` binary must be compiled and placed inside the app bundle and signed with the following entitlements:
- `com.apple.private.security.no-sandbox`
- `platform-application`

The Swift UI layer passes execution commands as arguments to `cytrollhelper`, which allowlists both the target executable and every argument before running it. Privilege escalation (`setuid(0)`/`setgid(0)`) is attempted but is **best-effort, not guaranteed** — it only actually succeeds when the binary on disk is owned by `root` with the setuid bit set (`4755`), which requires something that already has root to configure. On the primary TrollStore `.tipa` install path that never happens (there is no legitimate way for an app to grant itself root on a device that isn't already jailbroken), so `cytrollhelper` simply proceeds as whatever UID it already has. This is fine in practice: Cytroll keeps `/var/mobile/.lara_jb` owned by `mobile` specifically so an unsandboxed-but-unprivileged TrollStore process can manage it without real root. The `.deb`-based install path (`packaging/`, for installing on top of an *existing* rootless env) is the one place `cytrollhelper` can legitimately get real root — its `postinst` script runs under that env's already-root `dpkg` and does the one-time `chown root:wheel` + `chmod 4755`.

## Features

- **Remote Bootstrap**: Downloads and extracts the Procursus bootstrap into `/var/mobile/.lara_jb` dynamically (archives unpack as `var/jb` temporarily, then Cytroll relocates and rewrites paths).
- **Package Management**: Native Swift implementation for parsing `dpkg` and APT repos.
- **Root Helper Injection**: Uses a secondary binary (`cytrollhelper`) to safely spawn root-level processes.
- **Tweak Management**: Built-in toggle to disable tweak injection (Safe Mode equivalent), plus utilities for `sbreload`, `uicache`, and userspace reboots.
- **Per-App Tweak Injection**: TrollFools-style patching of a single third-party app's executable to load a MobileSubstrate-style tweak's dylib — see [Per-App Tweak Injection](#per-app-tweak-injection) below.
- **Cydia-Style Package Management**: Package Details, Categories, source editing/removal, held/pinned versions, and more — see [Cydia-Style Package Management](#cydia-style-package-management) below.
- **Rootless**: Strictly compliant with rootless standards. Never touches the signed system volume (SSV).

## Per-App Tweak Injection

Cytroll's Tweaks tab (`Settings → Manage Injected Tweaks`) patches third-party apps to load an installed tweak's dylib, in the same spirit as [TrollFools](https://github.com/Lessica/TrollFools): it adds an `LC_LOAD_WEAK_DYLIB` load command to the app's executable with `insert_dylib`, then re-signs it with `ldid`.

**How target apps are chosen:** after installing a tweak `.deb`, Cytroll reads the standard MobileSubstrate `Filter -> Bundles` array from that tweak's companion `.plist` and offers injection into **installed apps whose bundle ID is listed there**. If a tweak ships no `Filter` (or you add a raw `.dylib` directly — see "Sideloading" below), you instead pick manually from every installed app, same as TrollFools' own picker.

**Multiple tweaks per app, safely:** every inject/restore/re-inject *rebuilds the whole app* from one shared, verified "pristine" backup (`AppPristineBackupStore`, one per app, not one per tweak) plus whatever full set of tweaks should currently be active — entirely inside a temp copy, verified, then atomically swapped into place. This means removing tweak A can never accidentally wipe out tweak B on the same app: B is always freshly reapplied as part of the very same rebuild, instead of restoring an older per-tweak snapshot that predates B's own injection.

**Safety pipeline (every step verified, any failure leaves the live app untouched):**
1. A pristine backup of the target `.app` is taken once (reused, not repeated, for every later inject/restore of that app) and verified (file count + total size) before anything is touched.
2. Original entitlements extracted from that backup (`ldid -e`), to be reapplied when re-signing.
3. A **temp working copy** of the backup is built: each active tweak's dylib is copied into its `Frameworks/` folder, ad-hoc signed, and patched in with `insert_dylib --inplace --weak --strip-codesig` — all inside the temp copy, never the live app.
4. `ldid -S<entitlements>` re-signs the temp copy's executable, and a post-patch signature check runs.
5. Only once the temp copy is fully verified is it **atomically swapped** in for the live app (rename-aside, move-into-place, delete-old) — any failure up to this point leaves the live app exactly as it was; a failure during the swap itself is retried and, in the rare case that also fails, self-heals on the next launch via a background sweep for leftover temp directories.

**Also available:**
- **Batch injection** — select multiple apps at once in the target picker to inject the same tweak into all of them in one operation.
- **Sideloading** — "Add .dylib File…" in the Tweaks tab lets you inject a raw `.dylib` you already have (e.g. from Files), without needing an apt package at all. It's copied into Cytroll's own managed storage and goes through the exact same pipeline, tracking, and reconciliation as an apt-installed tweak.
- **Backup Storage** screen — shows how much space per-app backups are using, with one-tap cleanup for orphaned leftovers (e.g. from an app uninstalled while injected).
- A best-effort `uicache -p <bundleID>` runs automatically after every successful inject/restore.

**Real limitations — please read before using:**
- Works **only** on third-party apps under `Bundle/Application/*.app/` — Apple's own apps and SpringBoard live on the sealed system volume and can never be touched, by construction (not just by policy).
- Depends on the same class of CoreTrust/AMFI bypass TrollStore itself relies on being active on your iOS version — if that bypass doesn't persist system-wide on your device, the patched app simply won't launch until you restore it.
- **Breaks silently on the target app's next update** — App Store/TrollStore updates replace the executable with an unpatched original. The Tweaks tab flags this as "Needs Reapply" (compares the app's current version against the version recorded at injection time) with a one-tap re-inject button that reapplies every active tweak for that app together.
- The injected app usually needs to be force-quit/restarted (sometimes a full respring) before the tweak takes effect.
- Doesn't handle dylibs loaded dynamically at runtime instead of via a static load command (rare; TrollFools needs a dedicated Mach-O engine for that case, out of scope here).
- Disabling or fully removing (apt purge) a tweak, or deleting a sideloaded dylib, automatically restores every app it was injected into — you never need to do this by hand.

## Cydia-Style Package Management

Beyond the base install/remove/upgrade queue, Cytroll's Packages tab now covers the classic Cydia workflow end-to-end:

- **Package Details** — tap any package (Packages tab, Categories, or Changes) to see its full description, installed/download size, maintainer, section, Depends/Conflicts, source, and homepage — all parsed natively from `dpkg status`/APT `_Packages` indices (`AptIndexParser`/`DpkgStatusParser`), never shelled out.
- **Categories** — "Browse by Category" groups every known package by its Debian `Section:` field (System, Tweaks, Utilities, ...), same as Cydia's Sections list.
- **Other Versions & pinned installs** — Package Details lists every version of a package found across all configured sources; picking one queues an install for that *exact* version via apt's native `name=version` syntax (`TransactionManager`), not just whatever apt would pick as the candidate.
- **Held/Pinned packages** — "Hold" a package from its Details screen to pin it via `apt-mark hold`; held packages are automatically excluded from the Changes tab's upgrade list (mirrors `apt list --upgradable`) until unheld.
- **Source management** — Sources tab now supports swipe-to-edit and swipe-to-delete, in addition to adding new ones. Edits/removals are applied directly to whichever file under `sources.list.d/` actually contains that source, preserving every other entry in it.
- **Depictions** — if a repo provides a `Depiction:`/`SileoDepiction:` field, Package Details shows a "View Full Depiction Page" button that renders it in an in-app `WKWebView` (classic Cydia-style HTML depictions; Sileo's newer native JSON depiction format is out of scope).
- **Package Manager settings** (`Settings → Package Manager`) — toggle whether architecture-incompatible packages (watchOS, macOS, etc.) are hidden from the Packages tab, and whether Package Details' "Other Versions" list starts expanded by default.
- **Real Activity Log** — the Home tab's activity feed now shows real install/remove/upgrade/reinstall history (`ActivityLogManager`, persisted to `/var/mobile/.lara_jb/var/cytroll/activity.json`) instead of placeholder rows.

**Bug fixed along the way:** `DpkgStatusParser` used to match the `Status:` field by looking for the literal substring `"install ok installed"`. A held package's status is `"hold ok installed"` (dpkg's `Status:` format is `<want> <flag> <status>` — the *want* word changes to `hold`, not the actual install state), so the old check silently dropped every held package from every list in the app. It now parses the three words correctly and only looks at the real status word.

**Full-project audit (2026-07):** a top-to-bottom review of every Swift/C file, the Xcode project, and the whole build/packaging pipeline turned up and fixed several build-breaking or install-breaking issues that a source-level read of the Swift code alone wouldn't surface:
- `cytrollhelper.c`'s executable allowlist checked `"/bin/"`/`"/usr/bin/"` (trailing slash) against `path_has_prefix()`'s boundary check, which requires the character *after* the matched prefix to be `/` or end-of-string — with the slash baked into the prefix itself, that check always failed. This silently rejected every bare `/bin/rm`, `/bin/mv`, `/bin/cp`, `/bin/mkdir` call the app makes (bootstrap removal, the entire per-app injection pipeline, tweak enable/disable, backup cleanup all use these). Fixed to match the slash-less convention already used correctly elsewhere in the same file.
- `cytrollhelper`'s `setuid(0)`/`setgid(0)` was a hard requirement (`return 1` on failure) with no fallback beyond "helper file not found." Since nothing in the build pipeline can legitimately grant a TrollStore-installed binary real root (chown-to-root itself requires pre-existing root), this meant the helper — which always exists once bundled — would refuse to run *anything* on the primary `.tipa` install path. Now best-effort: it tries to escalate, but proceeds regardless, relying on `/var/mobile/.lara_jb` being `mobile`-writable either way.
- `CytrollCoreBridge` reset `cytrollhelper`'s permissions to `0o755` before every single command, which would have silently stripped a legitimately-configured setuid bit (see next point) on every call. Now only touches permissions when the file isn't already executable, and preserves an existing setuid bit.
- Added the one place `cytrollhelper` *can* legitimately get real root: `packaging/debian/postinst` (the `.deb` install path, for installing on top of an existing rootless jailbreak) now `chown root:wheel` + `chmod 4755`s it, since that script runs under that jailbreak's already-root `dpkg`.
- `build.sh` compiled `cytrollhelper`/`insert_dylib` straight into the Payload but never copied the pre-fetched `tar`/`ldid`/`zstd` from `Binaries/` into it — every real build would have shipped a `.tipa` with no bootstrap-extraction or code-signing tools at all, breaking bootstrap install and every `ldid` re-sign call. Fixed to copy them in before signing.
- `Scripts/fetch-binaries.sh` downloaded `ldid` from a nonexistent asset name (`ldid_macos_arm64` — the real asset is just `ldid`) and `tar`/`zstd` from a nonexistent repo/tag entirely (`khcrysalis/ldid@v2.1.5-procursus7-iphoneos-arm64` — 404s). Fixed `ldid` to the correct asset, and `tar`/`zstd` to pull the real binaries straight out of Procursus's own official `iphoneos-arm64-rootless` `.deb`s (the same binaries a real Procursus bootstrap uses internally), verified against `apt.procurs.us` directly.

## Compatibility

- iOS 15.0 - 17.x
- Requires [TrollStore](https://github.com/opa334/TrollStore). Cytroll relies on the CoreTrust bug and TrollStore's unsandboxed environment.

## Building

1. Clone this repository.
2. Open the project in Xcode. `Cytroll.entitlements` is already wired as `CODE_SIGN_ENTITLEMENTS` for the main target.
3. Run `Scripts/fetch-binaries.sh` on macOS to fetch `ldid`, `tar`, `zstd` into `Binaries/`.
4. Run `./build.sh` — it compiles `cytrollhelper` and `insert_dylib` from their vendored C sources in `Cytroll/Core/RootHelper/`, pseudo-signs everything with `ldid` using `Cytroll.entitlements`, and packages `Cytroll.tipa`.
5. Alternatively, build the Xcode project directly (`CODE_SIGNING_ALLOWED=NO`) and run the signing steps from `build.sh` manually.
6. Install the resulting `.tipa`/`.ipa` via TrollStore.

## Credits

- The Sileo Team for APT parsing concepts and Root Helper proxy architecture.
- opa334 for TrollStore.
- Tyilo for [`insert_dylib`](https://github.com/Tyilo/insert_dylib), vendored under `Cytroll/Core/RootHelper/insert_dylib.c`.
- Lessica for [TrollFools](https://github.com/Lessica/TrollFools), the reference design for the per-app injection pipeline.
