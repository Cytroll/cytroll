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

echo "[*] Step 4: Pseudo-signing with ldid (The TrollStore Magic)..."
# هذه الخطوة هي التي تزرع صلاحيات التخطي داخل التطبيق وملفاته لكي يقبلها TrollStore

# توقيع أداة الـ Root Helper
if [ -f "Payload/Cytroll.app/cytrollhelper" ]; then
    echo "    -> Signing cytrollhelper..."
    ldid -S"Cytroll/Cytroll.entitlements" Payload/Cytroll.app/cytrollhelper
else
    echo "    [!] Warning: cytrollhelper not found in App Bundle. Please make sure it's added to Xcode."
fi

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
