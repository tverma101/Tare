#!/usr/bin/env bash
set -euo pipefail

CLEANER="/Users/tejas/Name Clean/NameCleanApp/clean-name-cli.py"
LOG_DIR="$HOME/Library/Logs/NameClean"
LOG_FILE="$LOG_DIR/quick-action-clean.log"

notify() {
  /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
}

if [[ $# -eq 0 ]]; then
  exit 0
fi

if [[ ! -x "$CLEANER" ]]; then
  notify "Cleaner script is missing" "Clean File Names"
  exit 1
fi

mkdir -p "$LOG_DIR"

notify "Cleaning $# item(s). Progress is logged." "Clean File Names"

set +e
{
  echo
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Clean Name Quick Action"
  printf 'Input: %s\n' "$@"
  "$CLEANER" --progress "$@"
} 2>&1 | tee -a "$LOG_FILE"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  notify "Clean failed. See $LOG_FILE" "Clean File Names"
  exit "$status"
fi

notify "Processed $# item(s). Log saved." "Clean File Names"
