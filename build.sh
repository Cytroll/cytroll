#!/bin/bash
set -e

echo "========================================================="
echo "   Cytroll TrollStore Builder & AMFI Bypass Script       "
echo "========================================================="

# التخطي الفعلي لمشكلة أبل (Apple Signing Restriction):
# أبل ترفض تصدير أي تطبيق يحتوي على صلاحيات (com.apple.private.security.no-sandbox).
# الحل هو إجبار Xcode على تجميع الكود "بدون توقيع"، ثم نقوم نحن بتوقيعه يدوياً باستخدام ldid.

echo "[*] Step 1: Cleaning previous builds..."
rm -rf build Payload Cytroll.tipa Cytroll.ipa

echo "[*] Step 2: Compiling Xcode Project (Bypassing Apple Code Signing)..."
# الأمر CODE_SIGNING_ALLOWED=NO هو السر هنا لكي لا يتوقف Xcode ويرفض البناء
xcodebuild build \
    -project Cytroll.xcodeproj \
    -scheme Cytroll \
    -configuration Release \
    -sdk iphoneos \
    -arch arm64 \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO

echo "[*] Step 3: Preparing the Payload directory..."
mkdir -p Payload
# نسخ التطبيق المُجمّع من مسار البناء الخاص بـ Xcode
cp -r build/Build/Products/Release-iphoneos/Cytroll.app Payload/
mkdir -p Payload/Cytroll.app/Binaries

echo "    -> Copying pre-fetched static tools (tar/ldid/zstd) from Binaries/..."
# BootstrapConfig/AppInjectionManager resolve these purely by bundle path
# (RootlessPaths.bundledBinariesDir + "/<tool>") — nothing else stages them
# into the .app, so skipping this step used to silently ship a .tipa with
# no tar/zstd/ldid at all: BootstrapManager.extractBootstrap would abort
# every install with "Missing zstd or tar in app Binaries/.", and every
# ldid re-sign call (tweak injection, prep_bootstrap.sh) would have no
# bundled fallback either. Run ./Scripts/fetch-binaries.sh first if these
# are missing.
for tool in tar ldid zstd; do
    if [ -f "Binaries/$tool" ]; then
        cp "Binaries/$tool" "Payload/Cytroll.app/Binaries/$tool"
    else
        echo "       [!] Warning: Binaries/$tool not found — run ./Scripts/fetch-binaries.sh first."
    fi
done

# Optional — BootstrapManager tries a remote download first and only falls
# back to a bundled archive if that fails, so these are never required,
# but bundle them when present for a fully offline-capable install.
for archive in bootstrap_1800.tar.zst bootstrap_1900.tar.zst; do
    if [ -f "Binaries/$archive" ]; then
        cp "Binaries/$archive" "Payload/Cytroll.app/Binaries/$archive"
        echo "       [+] Bundled $archive for offline bootstrap fallback"
    fi
done

echo "    -> Compiling cytrollhelper from C source..."
xcrun -sdk iphoneos clang -arch arm64 -o Payload/Cytroll.app/Binaries/cytrollhelper Cytroll/Core/RootHelper/cytrollhelper.c

echo "    -> Compiling insert_dylib from C source (per-app tweak injection)..."
xcrun -sdk iphoneos clang -arch arm64 -o Payload/Cytroll.app/Binaries/insert_dylib Cytroll/Core/RootHelper/insert_dylib.c

echo "[*] Step 4: Pseudo-signing with ldid (The TrollStore Magic)..."
# هذه الخطوة هي التي تزرع صلاحيات التخطي داخل التطبيق وملفاته لكي يقبلها TrollStore

# توقيع أداة الـ Root Helper والأدوات المساعدة في مسار Binaries/
echo "    -> Setting execution permissions and signing Binaries..."
for tool in cytrollhelper insert_dylib tar ldid zstd; do
    tool_path="Payload/Cytroll.app/Binaries/$tool"
    if [ -f "$tool_path" ]; then
        chmod +x "$tool_path"
        ldid -S"Cytroll/Cytroll.entitlements" "$tool_path"
        echo "       [+] Signed $tool"
    else
        echo "       [!] Warning: $tool not found in Binaries/"
    fi
done

# توقيع التطبيق الأساسي
echo "    -> Signing Main Application Executable..."
ldid -S"Cytroll/Cytroll.entitlements" Payload/Cytroll.app/Cytroll

echo "[*] Step 5: Packaging into a TrollStore IPA (.tipa)..."
zip -qr Cytroll.tipa Payload

echo "[*] Step 6: Cleaning up temp files..."
rm -rf build Payload

echo "========================================================="
echo "[+] SUCCESS! Cytroll.tipa has been generated."
echo "[+] Send this file to your iPhone and install via TrollStore."
echo "========================================================="
