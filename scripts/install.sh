#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if /usr/bin/pgrep -x '(NoSleep|Sleeplesshan)' >/dev/null; then
  echo 'Quit Sleeplesshan before installing. The running app will not be overwritten.' >&2
  exit 1
fi
APP="$PWD/outputs/Sleeplesshan.app"
[[ -d "$APP" ]] || { echo 'Run bash scripts/build.sh first.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "$APP"
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/Sleeplesshan.app"
/usr/bin/codesign --verify --strict "$HOME/Applications/Sleeplesshan.app"
printf 'Installed: %s\n' "$HOME/Applications/Sleeplesshan.app"
