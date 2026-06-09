#!/bin/bash
# Builds DripWriter.app from source. Re-run this any time you change main.swift.
set -e
cd "$(dirname "$0")"

APP="DripWriter.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "→ Compiling…"
swiftc -O -swift-version 5 \
    -sdk "$SDK" \
    -framework Cocoa \
    Sources/*.swift \
    -o build/DripWriter

echo "→ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/DripWriter "$APP/Contents/MacOS/DripWriter"
cp Info.plist "$APP/Contents/Info.plist"

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $(pwd)/$APP"
