#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARIES="$ROOT/Binaries"
HELPER_SRC="$ROOT/Cytroll/Core/RootHelper/cytrollhelper.c"
INSERT_DYLIB_SRC="$ROOT/Cytroll/Core/RootHelper/insert_dylib.c"

mkdir -p "$BINARIES"

echo "[*] Fetching rootless build tools into Binaries/..."

fetch_if_missing() {
    local name="$1"
    local url="$2"
    if [ ! -f "$BINARIES/$name" ]; then
        echo "    -> Downloading $name"
        curl -fsSL "$url" -o "$BINARIES/$name"
        chmod +x "$BINARIES/$name"
    else
        echo "    -> $name already present"
    fi
}

# opa334's TrollStore-signed ldid — pre-signed with the CoreTrust bug so it
# runs directly on iOS under TrollStore's AMFI implant. The asset is
# literally named "ldid" (verified against the actual release — a prior
# version of this script pointed at a nonexistent "ldid_macos_arm64" asset
# and always 404'd).
fetch_if_missing "ldid" "https://github.com/opa334/ldid/releases/latest/download/ldid"

# tar/zstd have no standalone static-binary GitHub release anywhere (a
# prior version of this script pointed at a "khcrysalis/ldid" repo/tag that
# doesn't exist and always 404'd). Procursus's own official repo does
# publish real iphoneos-arm64 rootless .debs for both — pull the binary
# straight out of the one already used inside every real Procursus
# bootstrap, verified against https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/1800/{tar,zstd}/ (2026-07).
fetch_tool_from_procursus_deb() {
    local name="$1"
    local deb_url="$2"
    if [ -f "$BINARIES/$name" ]; then
        echo "    -> $name already present"
        return
    fi
    echo "    -> Downloading $name from Procursus ($deb_url)"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "$deb_url" -o "$tmp/pkg.deb"
    (cd "$tmp" && ar x pkg.deb data.tar.zst && tar -xf data.tar.zst "./var/jb/usr/bin/$name")
    cp "$tmp/var/jb/usr/bin/$name" "$BINARIES/$name"
    chmod +x "$BINARIES/$name"
    rm -rf "$tmp"
}

fetch_tool_from_procursus_deb "tar"  "https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/1800/tar/tar_1.35_iphoneos-arm64.deb"
fetch_tool_from_procursus_deb "zstd" "https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/1800/zstd/zstd_1.5.5_iphoneos-arm64.deb"

echo "[*] Bootstrap archives (optional — app can download on-device):"
for ver in 1800 1900; do
    archive="bootstrap_${ver}.tar.zst"
    if [ ! -f "$BINARIES/$archive" ]; then
        echo "    [!] $archive not found — place manually or rely on on-device download"
    else
        echo "    [+] $archive present"
    fi
done

if [ -f "$HELPER_SRC" ]; then
    echo "[*] Compiling cytrollhelper (host preview — final build in build.sh)..."
    xcrun -sdk iphoneos clang -arch arm64 -o "$BINARIES/cytrollhelper" "$HELPER_SRC" 2>/dev/null || \
        echo "    [!] Skip host compile (requires Xcode iphoneos SDK on macOS)"
fi

if [ -f "$INSERT_DYLIB_SRC" ]; then
    echo "[*] Compiling insert_dylib (host preview — final build in build.sh)..."
    echo "    (vendored from https://github.com/Tyilo/insert_dylib for per-app tweak injection)"
    xcrun -sdk iphoneos clang -arch arm64 -o "$BINARIES/insert_dylib" "$INSERT_DYLIB_SRC" 2>/dev/null || \
        echo "    [!] Skip host compile (requires Xcode iphoneos SDK on macOS)"
fi

echo "[+] Done. Binaries directory ready at: $BINARIES"
