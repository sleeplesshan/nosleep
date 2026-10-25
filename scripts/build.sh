#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/outputs/Sleeplesshan.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/Sleeplesshan" "$APP/Contents/MacOS/Sleeplesshan"
cp scripts/Info.plist "$APP/Contents/Info.plist"
ditto Resources/Fonts "$APP/Contents/Resources/Fonts"
swift scripts/make-icon.swift "$PWD/work/AppIcon.iconset"
/usr/bin/iconutil -c icns "$PWD/work/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign "${NOSLEEP_SIGNING_IDENTITY:--}" --identifier io.github.sleeplesshan.NoSleep "$APP"
/usr/bin/codesign --verify --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
