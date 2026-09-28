#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANER="${TARE_NAME_CLEAN_CLI:-$HOME/Library/Application Support/NameClean/clean-name-cli.py}"
OUTPUT_DIR="${TARE_OUTPUT_DIR:-}"
LOG_DIR="$HOME/Library/Logs/Tare"
LOG_FILE="$LOG_DIR/quick-action-clean-then-transcribe.log"
BATCH_ARGS=()

notify() {
  /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
}

if [[ $# -eq 0 ]]; then
  exit 0
fi

if [[ ! -x "$CLEANER" ]]; then
  notify "Cleaner script is missing" "Clean and Transcribe"
  exit 1
fi

read_app_pref() {
  /usr/bin/defaults read com.tejas.Tare "$1" 2>/dev/null || true
}

SAVED_ATTACH="$(read_app_pref attachCaptionedVideoToSource)"
SAVED_CREATE_BATCH="$(read_app_pref createBatchFolder)"
SAVED_MODEL="$(read_app_pref modelIdentifier)"
SAVED_LANGUAGE="$(read_app_pref localeIdentifier)"
SAVED_FORMATS="$(read_app_pref selectedFormatsCSV)"
ATTACH_TO_SOURCE="${TARE_ATTACH_TO_SOURCE:-$SAVED_ATTACH}"
CREATE_BATCH_FOLDER="${TARE_CREATE_BATCH_FOLDER:-$SAVED_CREATE_BATCH}"
MODEL_IDENTIFIER="${TARE_MODEL:-$SAVED_MODEL}"
LANGUAGE_IDENTIFIER="${TARE_LANGUAGE:-${TARE_LOCALE:-$SAVED_LANGUAGE}}"
FORMAT_LIST="${TARE_FORMATS:-$SAVED_FORMATS}"
CHUNK_SECONDS="${TARE_CHUNK_SECONDS:-}"
CHUNK_WORKERS="${TARE_CHUNK_WORKERS:-}"

if [[ -z "$ATTACH_TO_SOURCE" || "$ATTACH_TO_SOURCE" == "1" || "$ATTACH_TO_SOURCE" == "true" || "$ATTACH_TO_SOURCE" == "TRUE" || "$ATTACH_TO_SOURCE" == "YES" ]]; then
  BATCH_ARGS+=(--attach-to-source)
fi
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  BATCH_ARGS+=(--output "$OUTPUT_DIR")
else
  BATCH_ARGS+=(--output-source-folder)
fi
if [[ "$CREATE_BATCH_FOLDER" == "0" || "$CREATE_BATCH_FOLDER" == "false" || "$CREATE_BATCH_FOLDER" == "FALSE" || "$CREATE_BATCH_FOLDER" == "NO" ]]; then
  BATCH_ARGS+=(--flat-output)
fi
if [[ -n "$MODEL_IDENTIFIER" ]]; then
  BATCH_ARGS+=(--model "$MODEL_IDENTIFIER")
fi
if [[ -n "$LANGUAGE_IDENTIFIER" ]]; then
  BATCH_ARGS+=(--language "$LANGUAGE_IDENTIFIER")
fi
if [[ -n "$FORMAT_LIST" ]]; then
  BATCH_ARGS+=(--formats "$FORMAT_LIST")
fi
if [[ -n "$CHUNK_SECONDS" ]]; then
  BATCH_ARGS+=(--chunk-seconds "$CHUNK_SECONDS")
fi
if [[ -n "$CHUNK_WORKERS" ]]; then
  BATCH_ARGS+=(--chunk-workers "$CHUNK_WORKERS")
fi
mkdir -p "$LOG_DIR"
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

{
  echo
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Clean and Transcribe Quick Action"
  printf 'Input: %s\n' "$@"
} >> "$LOG_FILE"

notify "Cleaning $# item(s). Progress is logged." "Clean and Transcribe"

set +e
"$CLEANER" --json --progress "$@" > "$TMP_JSON" 2>> "$LOG_FILE"
clean_status=$?
set -e

if [[ $clean_status -ne 0 ]]; then
  notify "Clean failed. See $LOG_FILE" "Clean and Transcribe"
  exit "$clean_status"
fi

TARGETS=()
while IFS= read -r target; do
  TARGETS+=("$target")
done < <(/usr/bin/python3 - "$TMP_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for item in json.load(handle):
        print(item["target_path"] if item.get("changed") else item["path"])
PY
)

notify "Transcribing ${#TARGETS[@]} item(s). Progress is logged." "Clean and Transcribe"

set +e
{
  printf 'Target: %s\n' "${TARGETS[@]}"
  cd "$ROOT_DIR"
  swift run TranscriberBatch -- "${BATCH_ARGS[@]}" "${TARGETS[@]}"
} 2>&1 | tee -a "$LOG_FILE"
transcribe_status=${PIPESTATUS[0]}
set -e

if [[ $transcribe_status -ne 0 ]]; then
  notify "Transcription failed. See $LOG_FILE" "Clean and Transcribe"
  exit "$transcribe_status"
fi

notify "Cleaned names and saved transcripts" "Tare"
