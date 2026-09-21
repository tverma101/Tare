#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---all}"
APP_NAME="Tare"
BUNDLE_ID="com.tejas.Tare"
MIN_SYSTEM_VERSION="14.0"
VERSION="${TARE_VERSION:-0.1.4}"

resolve_signing_identity() {
  if [[ -n "${TARE_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$TARE_CODESIGN_IDENTITY"
    return
  fi

  # macOS file-based Keychain ACLs bind an app signed ad hoc to each build's
  # code hash. Prefer the installed Apple Development identity so a normal
  # rebuild keeps the same designated requirement and does not re-prompt for
  # every API-key read. Keep an explicit ad-hoc fallback for machines without
  # a local Apple signing identity.
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' '/Apple Development:/{print $2; exit}'
}

SIGNING_IDENTITY="$(resolve_signing_identity)"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
  echo "No Apple Development signing identity found; using ad-hoc signing. Keychain prompts may recur after rebuilds." >&2
else
  echo "Using stable local signing identity: $SIGNING_IDENTITY"
fi

case "$MODE" in
  --dmg|dmg|--install|install|--all|all)
    ;;
  *)
    echo "usage: $0 [--dmg|--install|--all]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SOURCE_PYTHON="$ROOT_DIR/.venv/bin/python"
INSTALL_PATH="/Applications/Tare.app"
LEGACY_INSTALL_PATH="/Applications/LocalVideoTranscriber.app"
USER_TRASH_DIR="${HOME}/.Trash"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported macOS architecture: $ARCH" >&2
    exit 2
    ;;
esac

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "TARE_VERSION must look like 0.1.3, got: $VERSION" >&2
  exit 2
fi

DMG_PATH="$DIST_DIR/Tare-${VERSION}-macOS-${ARCH}.dmg"
CHECKSUM_PATH="$DIST_DIR/Tare-${VERSION}-macOS-${ARCH}.sha256"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tare-release.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
STAGED_BINARY="$STAGED_MACOS/$APP_NAME"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

cd "$ROOT_DIR"

require_backend() {
  if [[ ! -x "$SOURCE_PYTHON" ]]; then
    echo "Release packaging requires a complete backend at $SOURCE_PYTHON." >&2
    echo "Run ./script/setup_transcription_backend.sh, then retry." >&2
    exit 1
  fi

  if ! env PYTHONDONTWRITEBYTECODE=1 "$SOURCE_PYTHON" - <<'PY'
import importlib.util
import sys

required = (
    "huggingface_hub",
    "mlx",
    "mlx_audio",
    "mlx_lm",
    "mlx_voxtral",
    "mlx_whisper",
    "parakeet_mlx",
    "librosa",
    "numpy",
    "torch",
    "transformers",
    "moss_transcribe_diarize",
)
missing = [name for name in required if importlib.util.find_spec(name) is None]
if missing:
    print("missing backend modules: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    echo "The local backend is incomplete; refusing to create a distributable." >&2
    exit 1
  fi
}

build_bundle() {
  swift build -c release
  local build_binary
  build_binary="$(swift build --show-bin-path -c release)/$APP_NAME"

  mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
  cp "$build_binary" "$STAGED_BINARY"
  cp "$ROOT_DIR/script/mlx_transcribe.py" "$STAGED_RESOURCES/mlx_transcribe.py"
  cp "$ROOT_DIR/script/canary_transcribe.py" "$STAGED_RESOURCES/canary_transcribe.py"
  cp "$ROOT_DIR/script/voxtral_transcribe.py" "$STAGED_RESOURCES/voxtral_transcribe.py"
  cp "$ROOT_DIR/script/manage_models.py" "$STAGED_RESOURCES/manage_models.py"
  cp "$ROOT_DIR/Assets/Tare.icns" "$STAGED_RESOURCES/Tare.icns"

  ditto "$ROOT_DIR/.venv" "$STAGED_RESOURCES/.venv"
  local bundled_python="$STAGED_RESOURCES/.venv/bin/python3.11"
  if [[ -L "$bundled_python" ]]; then
    local resolved_python
    resolved_python="$("$SOURCE_PYTHON" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$ROOT_DIR/.venv/bin/python3.11")"
    rm "$bundled_python"
    cp "$resolved_python" "$bundled_python"
  fi

  chmod +x "$STAGED_BINARY"

  cat >"$STAGED_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>Tare</string>
  <key>CFBundleIconName</key>
  <string>Tare</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Tare uses local transcription for files you choose.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Tare does not record microphone audio.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Video and Audio</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.video</string>
        <string>public.audio</string>
        <string>com.apple.quicktime-movie</string>
        <string>public.mpeg-4</string>
        <string>public.mp3</string>
        <string>com.microsoft.waveform-audio</string>
        <string>com.apple.m4a-audio</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$STAGED_APP"
}

verify_bundle() {
  /usr/bin/codesign --verify --deep --strict "$STAGED_APP"
  if find "$STAGED_APP" -type f \( -name '*.safetensors' -o -name '*.gguf' -o \( -name '*.bin' -a -size +32M \) \) -print -quit | grep -q .; then
    echo "Refusing to ship model weights inside Tare.app." >&2
    exit 1
  fi
}

create_dmg() {
  mkdir -p "$DIST_DIR"
  local dmg_staging="$STAGING_ROOT/dmg"
  mkdir -p "$dmg_staging"
  ditto "$STAGED_APP" "$dmg_staging/$APP_NAME.app"
  ln -s /Applications "$dmg_staging/Applications"

  rm -f "$DMG_PATH" "$CHECKSUM_PATH"
  hdiutil create \
    -volname "Tare" \
    -srcfolder "$dmg_staging" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
  shasum -a 256 "$DMG_PATH" >"$CHECKSUM_PATH"
  hdiutil verify "$DMG_PATH" 2>&1
}

quarantine_existing_install() {
  local quarantine_root="$USER_TRASH_DIR/Tare-replaced-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$quarantine_root"

  if [[ -e "$INSTALL_PATH" ]]; then
    mv "$INSTALL_PATH" "$quarantine_root/Tare.app"
  fi
  if [[ -e "$LEGACY_INSTALL_PATH" ]]; then
    mv "$LEGACY_INSTALL_PATH" "$quarantine_root/LocalVideoTranscriber.app"
  fi
  echo "Previous app bundles moved to $quarantine_root"
}

install_app() {
  local install_stage="$STAGING_ROOT/Tare-install.app"
  ditto "$STAGED_APP" "$install_stage"
  /usr/bin/codesign --verify --deep --strict "$install_stage"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  quarantine_existing_install
  mv "$install_stage" "$INSTALL_PATH"
  /usr/bin/codesign --verify --deep --strict "$INSTALL_PATH"
  /usr/bin/open -n "$INSTALL_PATH"
  echo "Installed exactly one canonical app at $INSTALL_PATH"
}

quarantine_legacy_dist_artifacts() {
  local quarantine_root="$USER_TRASH_DIR/Tare-dist-legacy-$(date +%Y%m%d-%H%M%S)"
  local moved_count=0

  for artifact in "$DIST_DIR/Tare.app" "$DIST_DIR/Tare.dmg" "$DIST_DIR/dmg-staging"; do
    if [[ -e "$artifact" || -L "$artifact" ]]; then
      if [[ "$moved_count" -eq 0 ]]; then
        mkdir -p "$quarantine_root"
      fi
      mv "$artifact" "$quarantine_root/"
      moved_count=$((moved_count + 1))
    fi
  done

  for artifact in "$DIST_DIR"/Tare-*.dmg "$DIST_DIR"/Tare-*.sha256; do
    [[ -e "$artifact" || -L "$artifact" ]] || continue
    if [[ "$artifact" == "$DMG_PATH" || "$artifact" == "$CHECKSUM_PATH" ]]; then
      continue
    fi
    if [[ "$moved_count" -eq 0 ]]; then
      mkdir -p "$quarantine_root"
    fi
    mv "$artifact" "$quarantine_root/"
    moved_count=$((moved_count + 1))
  done

  if [[ "$moved_count" -gt 0 ]]; then
    echo "Moved legacy dist artifacts to $quarantine_root"
  fi
}

require_backend
build_bundle
verify_bundle
quarantine_legacy_dist_artifacts

case "$MODE" in
  --dmg|dmg)
    create_dmg
    echo "Wrote $DMG_PATH"
    echo "Wrote $CHECKSUM_PATH"
    ;;
  --install|install)
    install_app
    ;;
  --all|all)
    create_dmg
    install_app
    echo "Wrote $DMG_PATH"
    echo "Wrote $CHECKSUM_PATH"
    ;;
esac
