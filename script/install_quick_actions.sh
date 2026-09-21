#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="$HOME/Library/Services"
TRANSCRIBER_SUPPORT_DIR="$HOME/Library/Application Support/Tare"
NAMECLEAN_SUPPORT_DIR="$HOME/Library/Application Support/NameClean"

mkdir -p "$SERVICES_DIR" "$TRANSCRIBER_SUPPORT_DIR" "$NAMECLEAN_SUPPORT_DIR"

# Remove the pre-Tare action so Finder does not expose two transcription entry points.
rm -rf "$SERVICES_DIR/Transcribe with Local Video Transcriber.workflow"

cd "$ROOT_DIR"
/usr/bin/swift build -c release --product TranscriberBatch >/dev/null
BUILD_BIN="$(/usr/bin/swift build --show-bin-path -c release)/TranscriberBatch"
cp "$BUILD_BIN" "$TRANSCRIBER_SUPPORT_DIR/TranscriberBatch"
cp "$ROOT_DIR/script/mlx_transcribe.py" "$TRANSCRIBER_SUPPORT_DIR/mlx_transcribe.py"
chmod +x "$TRANSCRIBER_SUPPORT_DIR/TranscriberBatch"

CLEANER_SOURCE=""
for candidate in \
  "$HOME/Name Clean/NameCleanApp/clean-name-cli.py" \
  "$HOME/Experiemnts/NameCleanApp/clean-name-cli.py" \
  "$NAMECLEAN_SUPPORT_DIR/clean-name-cli.py"
do
  if [[ -f "$candidate" ]]; then
    CLEANER_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$CLEANER_SOURCE" ]]; then
  echo "Could not find clean-name-cli.py. Expected it in Name Clean, Experiemnts, or Application Support." >&2
  exit 1
fi

if [[ "$CLEANER_SOURCE" != "$NAMECLEAN_SUPPORT_DIR/clean-name-cli.py" ]]; then
  cp "$CLEANER_SOURCE" "$NAMECLEAN_SUPPORT_DIR/clean-name-cli.py"
fi
chmod +x "$NAMECLEAN_SUPPORT_DIR/clean-name-cli.py"

/usr/bin/python3 - "$ROOT_DIR" "$SERVICES_DIR" "$TRANSCRIBER_SUPPORT_DIR" "$NAMECLEAN_SUPPORT_DIR" <<'PY'
import plistlib
import shutil
import shlex
import sys
from pathlib import Path

root = Path(sys.argv[1])
services_dir = Path(sys.argv[2])
transcriber_support_dir = Path(sys.argv[3])
nameclean_support_dir = Path(sys.argv[4])
cleaner = nameclean_support_dir / "clean-name-cli.py"
transcriber_batch = transcriber_support_dir / "TranscriberBatch"
mlx_script = transcriber_support_dir / "mlx_transcribe.py"
python = root / ".venv/bin/python"

actions = [
    ("Clean Name", "clean", "NSTouchBarWand"),
    ("Transcribe with Tare", "transcribe", "NSTouchBarAudioInput"),
    ("Clean Names then Transcribe", "clean-transcribe", "NSTouchBarComposeTemplate"),
]


def input_prelude() -> str:
    return (
        'set -euo pipefail\n'
        'export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"\n'
        'if [ "$#" -eq 0 ]; then\n'
        '  while IFS= read -r item; do\n'
        '    [ -n "$item" ] && set -- "$@" "$item"\n'
        '  done\n'
        'fi\n'
        'if [ "$#" -eq 0 ]; then\n'
        '  exit 0\n'
        'fi\n'
        'notify() {\n'
        "  /usr/bin/osascript -e 'on run argv' \\\n"
        "    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \\\n"
        "    -e 'end run' \"$1\" \"$2\" >/dev/null 2>&1 || true\n"
        '}\n'
    )


def clean_command() -> str:
    return input_prelude() + f'''
CLEANER={shlex.quote(str(cleaner))}
LOG_DIR="$HOME/Library/Logs/NameClean"
LOG_FILE="$LOG_DIR/quick-action-clean.log"
mkdir -p "$LOG_DIR"

if [[ ! -f "$CLEANER" ]]; then
  notify "Cleaner script is missing" "Clean File Names"
  exit 1
fi

notify "Cleaning $# item(s). Progress is logged." "Clean File Names"

TMP_JSON="$(mktemp)"
TARGETS_FILE="$(mktemp)"
SUMMARY_FILE="$(mktemp)"
trap 'rm -f "$TMP_JSON" "$TARGETS_FILE" "$SUMMARY_FILE"' EXIT

{{
  echo
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Clean Name Quick Action"
  printf 'Input: %s\\n' "$@"
}} >> "$LOG_FILE"

set +e
/usr/bin/python3 "$CLEANER" --json --progress "$@" > "$TMP_JSON" 2>> "$LOG_FILE"
run_status=$?
set -e

if [[ $run_status -ne 0 ]]; then
  notify "Clean failed. See $LOG_FILE" "Clean File Names"
  exit "$run_status"
fi

/usr/bin/python3 - "$TMP_JSON" "$TARGETS_FILE" "$SUMMARY_FILE" <<'RESULTS_PY' >> "$LOG_FILE"
import json
import sys

json_path, targets_path, summary_path = sys.argv[1:4]
with open(json_path, "r", encoding="utf-8") as handle:
    results = json.load(handle)

targets = []
renamed = 0
changed = 0
for item in results:
    target = item.get("target_path") or item.get("path")
    if target:
        targets.append(str(target))
    if item.get("renamed"):
        renamed += 1
    if item.get("changed"):
        changed += 1
    old_name = str(item.get("old_name", ""))
    new_name = str(item.get("new_name", ""))
    reason = str(item.get("reason", ""))
    if item.get("renamed"):
        print("Renamed: " + old_name + " -> " + new_name + " (" + reason + ")")
    else:
        print("Skipped: " + old_name + " (" + reason + ")")

with open(targets_path, "w", encoding="utf-8") as handle:
    handle.write("\\n".join(targets))
    if targets:
        handle.write("\\n")

total = len(results)
if renamed:
    summary = "Renamed " + str(renamed) + " of " + str(total) + " item(s)."
elif changed:
    summary = "Prepared " + str(changed) + " of " + str(total) + " item(s)."
else:
    summary = "No filename changes needed for " + str(total) + " item(s)."

with open(summary_path, "w", encoding="utf-8") as handle:
    handle.write(summary)
print(summary)
RESULTS_PY

first_target="$(/usr/bin/head -n 1 "$TARGETS_FILE" 2>/dev/null || true)"
if [[ -n "$first_target" && -e "$first_target" ]]; then
  /usr/bin/open -R "$first_target" >/dev/null 2>&1 || true
fi

summary="$(/bin/cat "$SUMMARY_FILE" 2>/dev/null || printf 'Processed %s item(s).' "$#")"
notify "$summary" "Clean File Names"
'''


def transcribe_body(prefix: str = "") -> str:
    return f'''
BATCH={shlex.quote(str(transcriber_batch))}
PYTHON={shlex.quote(str(python))}
MLX_SCRIPT={shlex.quote(str(mlx_script))}
OUTPUT_ROOT="${{TARE_OUTPUT_DIR:-}}"
LOG_DIR="$HOME/Library/Logs/Tare"
LOG_FILE="$LOG_DIR/{prefix}quick-action-transcribe.log"
read_app_pref() {{
  /usr/bin/defaults read com.tejas.Tare "$1" 2>/dev/null || true
}}
SAVED_ATTACH="$(read_app_pref attachCaptionedVideoToSource)"
SAVED_CREATE_BATCH="$(read_app_pref createBatchFolder)"
SAVED_MODEL="$(read_app_pref modelIdentifier)"
SAVED_LANGUAGE="$(read_app_pref localeIdentifier)"
SAVED_FORMATS="$(read_app_pref selectedFormatsCSV)"
ATTACH_TO_SOURCE="${{TARE_ATTACH_TO_SOURCE:-$SAVED_ATTACH}}"
CREATE_BATCH_FOLDER="${{TARE_CREATE_BATCH_FOLDER:-$SAVED_CREATE_BATCH}}"
MODEL_IDENTIFIER="${{TARE_MODEL:-$SAVED_MODEL}}"
LANGUAGE_IDENTIFIER="${{TARE_LANGUAGE:-${{TARE_LOCALE:-$SAVED_LANGUAGE}}}}"
FORMAT_LIST="${{TARE_FORMATS:-$SAVED_FORMATS}}"
CHUNK_SECONDS="${{TARE_CHUNK_SECONDS:-}}"
CHUNK_WORKERS="${{TARE_CHUNK_WORKERS:-}}"
BATCH_ARGS=()
if [[ -z "$ATTACH_TO_SOURCE" || "$ATTACH_TO_SOURCE" == "1" || "$ATTACH_TO_SOURCE" == "true" || "$ATTACH_TO_SOURCE" == "TRUE" || "$ATTACH_TO_SOURCE" == "YES" ]]; then
  BATCH_ARGS+=(--attach-to-source)
fi
if [[ -n "$OUTPUT_ROOT" ]]; then
  mkdir -p "$OUTPUT_ROOT"
  BATCH_ARGS+=(--output "$OUTPUT_ROOT")
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
RUN_OUTPUT="$(mktemp)"
trap 'rm -f "$RUN_OUTPUT"' EXIT

if [[ ! -x "$BATCH" ]]; then
  notify "Transcriber binary is missing. Reinstall Quick Actions." "Tare"
  exit 1
fi

notify "Transcribing $# item(s). Progress is logged." "Tare"

set +e
{{
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Transcribe Quick Action"
  printf 'Input: %s\\n' "$@"
  TARE_PYTHON="$PYTHON" TARE_SCRIPT="$MLX_SCRIPT" "$BATCH" "${{BATCH_ARGS[@]}}" "$@"
}} 2>&1 | /usr/bin/tee -a "$LOG_FILE" | /usr/bin/tee "$RUN_OUTPUT" >/dev/null
run_status=${{PIPESTATUS[0]}}
set -e

if [[ $run_status -ne 0 ]]; then
  notify "Transcription failed. See $LOG_FILE" "Tare"
  exit "$run_status"
fi

OUTPUT_FOLDER="$(/usr/bin/awk -F'Output folder: ' '/Output folder:/ {{print $2}}' "$RUN_OUTPUT" | /usr/bin/tail -n 1)"
if [[ -n "$OUTPUT_FOLDER" && -d "$OUTPUT_FOLDER" ]]; then
  /usr/bin/open "$OUTPUT_FOLDER" >/dev/null 2>&1 || true
fi

notify "Output saved to ${{OUTPUT_FOLDER:-source folder}}" "Tare"
'''


def transcribe_command() -> str:
    return input_prelude() + transcribe_body()


def clean_then_transcribe_command() -> str:
    return input_prelude() + f'''
CLEANER={shlex.quote(str(cleaner))}
BATCH={shlex.quote(str(transcriber_batch))}
PYTHON={shlex.quote(str(python))}
MLX_SCRIPT={shlex.quote(str(mlx_script))}
OUTPUT_ROOT="${{TARE_OUTPUT_DIR:-}}"
LOG_DIR="$HOME/Library/Logs/Tare"
LOG_FILE="$LOG_DIR/quick-action-clean-then-transcribe.log"
read_app_pref() {{
  /usr/bin/defaults read com.tejas.Tare "$1" 2>/dev/null || true
}}
SAVED_ATTACH="$(read_app_pref attachCaptionedVideoToSource)"
SAVED_CREATE_BATCH="$(read_app_pref createBatchFolder)"
SAVED_MODEL="$(read_app_pref modelIdentifier)"
SAVED_LANGUAGE="$(read_app_pref localeIdentifier)"
SAVED_FORMATS="$(read_app_pref selectedFormatsCSV)"
ATTACH_TO_SOURCE="${{TARE_ATTACH_TO_SOURCE:-$SAVED_ATTACH}}"
CREATE_BATCH_FOLDER="${{TARE_CREATE_BATCH_FOLDER:-$SAVED_CREATE_BATCH}}"
MODEL_IDENTIFIER="${{TARE_MODEL:-$SAVED_MODEL}}"
LANGUAGE_IDENTIFIER="${{TARE_LANGUAGE:-${{TARE_LOCALE:-$SAVED_LANGUAGE}}}}"
FORMAT_LIST="${{TARE_FORMATS:-$SAVED_FORMATS}}"
CHUNK_SECONDS="${{TARE_CHUNK_SECONDS:-}}"
CHUNK_WORKERS="${{TARE_CHUNK_WORKERS:-}}"
BATCH_ARGS=()
if [[ -z "$ATTACH_TO_SOURCE" || "$ATTACH_TO_SOURCE" == "1" || "$ATTACH_TO_SOURCE" == "true" || "$ATTACH_TO_SOURCE" == "TRUE" || "$ATTACH_TO_SOURCE" == "YES" ]]; then
  BATCH_ARGS+=(--attach-to-source)
fi
if [[ -n "$OUTPUT_ROOT" ]]; then
  mkdir -p "$OUTPUT_ROOT"
  BATCH_ARGS+=(--output "$OUTPUT_ROOT")
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
RUN_OUTPUT="$(mktemp)"
trap 'rm -f "$TMP_JSON" "$RUN_OUTPUT"' EXIT

if [[ ! -f "$CLEANER" ]]; then
  notify "Cleaner script is missing" "Clean and Transcribe"
  exit 1
fi
if [[ ! -x "$BATCH" ]]; then
  notify "Transcriber binary is missing. Reinstall Quick Actions." "Clean and Transcribe"
  exit 1
fi

{{
  echo
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Clean and Transcribe Quick Action"
  printf 'Input: %s\\n' "$@"
}} >> "$LOG_FILE"

notify "Cleaning $# item(s). Progress is logged." "Clean and Transcribe"

set +e
/usr/bin/python3 "$CLEANER" --json --progress "$@" > "$TMP_JSON" 2>> "$LOG_FILE"
clean_status=$?
set -e

if [[ $clean_status -ne 0 ]]; then
  notify "Clean failed. See $LOG_FILE" "Clean and Transcribe"
  exit "$clean_status"
fi

TARGETS=()
while IFS= read -r target; do
  TARGETS+=("$target")
done < <(/usr/bin/python3 - "$TMP_JSON" <<'TARGETS_PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for item in json.load(handle):
        print(item["target_path"] if item.get("changed") else item["path"])
TARGETS_PY
)

if [[ ${{#TARGETS[@]}} -gt 0 && -e "${{TARGETS[0]}}" ]]; then
  /usr/bin/open -R "${{TARGETS[0]}}" >/dev/null 2>&1 || true
fi

notify "Transcribing ${{#TARGETS[@]}} item(s). Progress is logged." "Clean and Transcribe"

set +e
{{
  printf 'Target: %s\\n' "${{TARGETS[@]}}"
  TARE_PYTHON="$PYTHON" TARE_SCRIPT="$MLX_SCRIPT" "$BATCH" "${{BATCH_ARGS[@]}}" "${{TARGETS[@]}}"
}} 2>&1 | /usr/bin/tee -a "$LOG_FILE" | /usr/bin/tee "$RUN_OUTPUT" >/dev/null
transcribe_status=${{PIPESTATUS[0]}}
set -e

if [[ $transcribe_status -ne 0 ]]; then
  notify "Transcription failed. See $LOG_FILE" "Clean and Transcribe"
  exit "$transcribe_status"
fi

OUTPUT_FOLDER="$(/usr/bin/awk -F'Output folder: ' '/Output folder:/ {{print $2}}' "$RUN_OUTPUT" | /usr/bin/tail -n 1)"
if [[ -n "$OUTPUT_FOLDER" && -d "$OUTPUT_FOLDER" ]]; then
  /usr/bin/open "$OUTPUT_FOLDER" >/dev/null 2>&1 || true
fi

notify "Cleaned names and saved transcripts to ${{OUTPUT_FOLDER:-source folder}}" "Tare"
'''


def shell_command_for(kind: str) -> str:
    if kind == "clean":
        return clean_command()
    if kind == "transcribe":
        return transcribe_command()
    if kind == "clean-transcribe":
        return clean_then_transcribe_command()
    raise ValueError(kind)


def workflow_document(kind: str, icon: str) -> dict:
    shell_command = shell_command_for(kind)
    return {
        "AMApplicationBuild": "523",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [
            {
                "action": {
                    "AMAccepts": {
                        "Container": "List",
                        "Optional": False,
                        "Types": ["com.apple.cocoa.path", "com.apple.cocoa.string"],
                    },
                    "AMActionVersion": "2.0.3",
                    "AMApplication": ["Automator"],
                    "AMParameterProperties": {
                        "COMMAND_STRING": {},
                        "CheckedForUserDefaultShell": {},
                        "inputMethod": {},
                        "shell": {},
                        "source": {},
                    },
                    "AMProvides": {
                        "Container": "List",
                        "Types": ["com.apple.cocoa.path", "com.apple.cocoa.string"],
                    },
                    "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                    "ActionName": "Run Shell Script",
                    "ActionParameters": {
                        "COMMAND_STRING": shell_command,
                        "CheckedForUserDefaultShell": True,
                        "inputMethod": 0,
                        "shell": "/bin/bash",
                        "source": shell_command,
                    },
                    "BundleIdentifier": "com.apple.RunShellScript",
                    "CFBundleVersion": "2.0.3",
                    "CanShowSelectedItemsWhenRun": False,
                    "CanShowWhenRun": True,
                    "Category": ["AMCategoryUtilities"],
                    "Class Name": "RunShellScriptAction",
                    "InputUUID": "E7577533-3F5F-4EBD-93AE-7685D2CE9FB3",
                    "OutputUUID": "76D21AE5-63DF-4903-8820-2E2469C31CE8",
                    "UUID": "4FECD21D-B890-4A3C-93DE-9AB6C2B6A2CD",
                    "UnlocalizedApplications": ["Automator"],
                    "arguments": {
                        "0": {"default value": 0, "name": "inputMethod", "required": "0", "type": "0", "uuid": "0"},
                        "1": {"default value": False, "name": "CheckedForUserDefaultShell", "required": "0", "type": "0", "uuid": "1"},
                        "2": {"default value": "", "name": "source", "required": "0", "type": "0", "uuid": "2"},
                        "3": {"default value": "", "name": "COMMAND_STRING", "required": "0", "type": "0", "uuid": "3"},
                        "4": {"default value": "/bin/sh", "name": "shell", "required": "0", "type": "0", "uuid": "4"},
                    },
                    "isViewVisible": 1,
                    "location": "309.000000:305.000000",
                    "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
                },
                "isViewVisible": 1,
            }
        ],
        "connectors": {},
        "workflowMetaData": {
            "applicationBundleIDsByPath": {},
            "applicationPaths": [],
            "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
            "presentationMode": 15,
            "processesInput": True,
            "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": True,
            "systemImageName": icon,
            "useAutomaticInputType": False,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
        },
    }


def workflow_info(name: str) -> dict:
    return {
        "NSServices": [
            {
                "NSMenuItem": {"default": name},
                "NSMessage": "runWorkflowAsService",
                "NSSendFileTypes": ["public.item"],
            }
        ]
    }


for name, kind, icon in actions:
    workflow_dir = services_dir / f"{name}.workflow"
    contents_dir = workflow_dir / "Contents"
    if workflow_dir.exists() and not workflow_dir.is_dir():
        workflow_dir.unlink()
    contents_dir.mkdir(parents=True, exist_ok=True)

    with (contents_dir / "document.wflow").open("wb") as handle:
        plistlib.dump(workflow_document(kind, icon), handle, sort_keys=False)

    with (contents_dir / "Info.plist").open("wb") as handle:
        plistlib.dump(workflow_info(name), handle, sort_keys=False)

print("Installed Quick Actions:")
for name, _, _ in actions:
    print(f"  {services_dir / (name + '.workflow')}")
PY

if [[ -x /System/Library/CoreServices/pbs ]]; then
  /System/Library/CoreServices/pbs -flush || true
fi
