#!/bin/bash
# Builds DripWriter.app from source. Re-run this any time you change main.swift.
set -e
cd "$(dirname "$0")"

APP="DripWriter.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOY="13.0"   # minimum macOS
mkdir -p build

# Generate the app icon (AppIcon.icns) from make-icon.swift if it's missing.
if [ ! -f AppIcon.icns ]; then
    echo "→ Generating app icon…"
    swiftc -swift-version 5 -sdk "$SDK" -framework Cocoa make-icon.swift -o build/mkicon
    build/mkicon build/icon_1024.png
    SET=build/DripWriter.iconset; rm -rf "$SET"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" build/icon_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s*2))" "$((s*2))" build/icon_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o AppIcon.icns
fi

echo "→ Compiling universal binary (arm64 + x86_64)…"
swiftc -O -swift-version 5 -sdk "$SDK" -target "arm64-apple-macosx$DEPLOY" \
    -framework Cocoa Sources/*.swift -o build/DripWriter-arm64
swiftc -O -swift-version 5 -sdk "$SDK" -target "x86_64-apple-macosx$DEPLOY" \
    -framework Cocoa Sources/*.swift -o build/DripWriter-x86_64
lipo -create build/DripWriter-arm64 build/DripWriter-x86_64 -output build/DripWriter
echo "  $(lipo -archs build/DripWriter)"

echo "→ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/DripWriter "$APP/Contents/MacOS/DripWriter"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $(pwd)/$APP"
