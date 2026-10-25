#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
APP="$PWD/outputs/Sleeplesshan.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Sleeplesshan")
case "$ARCH" in
  arm64) PLATFORM=arm64 ;;
  *) echo "This release package requires Apple Silicon; found: $ARCH" >&2; exit 1 ;;
esac
NAME="Sleeplesshan-${VERSION}-macOS-${PLATFORM}"
STAGING=$(mktemp -d "$PWD/work/release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/$NAME"
ditto --noextattr --noqtn "$APP" "$STAGING/$NAME/Sleeplesshan.app"
cp LICENSE "$STAGING/$NAME/LICENSE.txt"
cp docs/INSTALL.txt "$STAGING/$NAME/INSTALL.txt"
/usr/bin/codesign --verify --strict "$STAGING/$NAME/Sleeplesshan.app"
mkdir -p outputs/releases
/usr/bin/ditto -c -k --norsrc --keepParent --noextattr --noqtn "$STAGING/$NAME" "outputs/releases/$NAME.zip"
(cd outputs/releases && /usr/bin/shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
printf 'Packaged: %s/outputs/releases/%s.zip\n' "$PWD" "$NAME"
