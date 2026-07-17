#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/packaging"
BUILD_DIR="$ROOT/build/deb"
STAGING="$BUILD_DIR/staging"

if [ ! -f "$ROOT/Cytroll.tipa" ] && [ ! -d "$ROOT/Payload/Cytroll.app" ]; then
    echo "[!] Run ./build.sh first to produce Cytroll.app / Cytroll.tipa"
    exit 1
fi

echo "[*] Building Cytroll .deb for Procursus (/var/jb)..."

rm -rf "$STAGING"
mkdir -p "$STAGING/DEBIAN"
mkdir -p "$STAGING/var/jb/Applications"

if [ -d "$ROOT/Payload/Cytroll.app" ]; then
    cp -R "$ROOT/Payload/Cytroll.app" "$STAGING/var/jb/Applications/"
else
    unzip -qo "$ROOT/Cytroll.tipa" -d "$BUILD_DIR/tipa_extract"
    cp -R "$BUILD_DIR/tipa_extract/Payload/Cytroll.app" "$STAGING/var/jb/Applications/"
fi

# Merge any optional static files (see packaging/layout/README.md)
if [ -d "$PKG_DIR/layout" ]; then
    find "$PKG_DIR/layout" -mindepth 1 -maxdepth 1 ! -name "README.md" -exec cp -R {} "$STAGING/" \;
fi

cp "$PKG_DIR/debian/control" "$STAGING/DEBIAN/control"
cp "$PKG_DIR/debian/postinst" "$STAGING/DEBIAN/postinst"
cp "$PKG_DIR/debian/prerm" "$STAGING/DEBIAN/prerm"
chmod 755 "$STAGING/DEBIAN/postinst" "$STAGING/DEBIAN/prerm"

mkdir -p "$ROOT/dist"
DEB="$ROOT/dist/com.cytroll.app_1.0.0_iphoneos-arm64.deb"

if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -b "$STAGING" "$DEB"
    echo "[+] Created $DEB"
else
    echo "[!] dpkg-deb not found — staging tree at $STAGING"
fi
