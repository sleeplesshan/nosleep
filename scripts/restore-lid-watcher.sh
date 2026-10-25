#!/bin/bash
# Restore only a backup made by NoSleep's explicit legacy-watcher migration.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/restore-lid-watcher.sh '/path/to/NoSleep/Backups/backup-id'" >&2
  exit 2
fi
LABEL='local.han.display-sleep-on-lid-close'
BACKUP="$1/$LABEL.plist"
DESTINATION="$HOME/Library/LaunchAgents/$LABEL.plist"
[[ -f "$BACKUP" ]] || { echo 'Backup plist not found.' >&2; exit 1; }
[[ ! -e "$DESTINATION" ]] || { echo 'An existing plist will not be overwritten.' >&2; exit 1; }
if /usr/bin/pgrep -x '(NoSleep|Sleeplesshan)' >/dev/null; then
  echo 'Quit Sleeplesshan before restoring the older watcher to avoid duplicate actions.' >&2
  exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents"
cp "$BACKUP" "$DESTINATION"
/bin/launchctl bootstrap "gui/$(id -u)" "$DESTINATION"
echo 'Previous lid watcher restored. Sleeplesshan will detect it and suspend its own lid actions.'
