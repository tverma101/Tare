#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Tare"
BUNDLE_ID="com.tejas.Tare"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ROOT="/tmp/tare-dev-bundle"
RUN_BUNDLE="$RUN_ROOT/$APP_NAME.app"
RUN_CONTENTS="$RUN_BUNDLE/Contents"
RUN_MACOS="$RUN_CONTENTS/MacOS"
RUN_RESOURCES="$RUN_CONTENTS/Resources"
RUN_BINARY="$RUN_MACOS/$APP_NAME"

resolve_signing_identity() {
  if [[ -n "${TARE_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$TARE_CODESIGN_IDENTITY"
    return
  fi

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
    exec "$ROOT_DIR/script/package_release.sh" "$MODE"
    ;;
  run|--stage-only|stage-only|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--stage-only|--debug|--logs|--telemetry|--verify|--dmg|--install|--all]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_MACOS" "$RUN_RESOURCES"
cp "$BUILD_BINARY" "$RUN_BINARY"
cp "$ROOT_DIR/script/mlx_transcribe.py" "$RUN_RESOURCES/mlx_transcribe.py"
cp "$ROOT_DIR/script/canary_transcribe.py" "$RUN_RESOURCES/canary_transcribe.py"
cp "$ROOT_DIR/script/voxtral_transcribe.py" "$RUN_RESOURCES/voxtral_transcribe.py"
cp "$ROOT_DIR/script/manage_models.py" "$RUN_RESOURCES/manage_models.py"
cp "$ROOT_DIR/Assets/Tare.icns" "$RUN_RESOURCES/Tare.icns"
chmod +x "$RUN_BINARY"

cat >"$RUN_CONTENTS/Info.plist" <<PLIST
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
  <string>0.1.4</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$RUN_BUNDLE"

open_app() {
  if [[ -n "${TARE_NO_ACTIVATE:-}" ]]; then
    # -g launches without bringing the app forward.
    /usr/bin/open -g -a "$RUN_BUNDLE"
  else
    /usr/bin/open -n "$RUN_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --stage-only|stage-only)
    # Build and sign the bundle without launching it. Used for automated checks
    # that need a bundle on disk but must not disturb what the user is doing.
    echo "Staged $RUN_BUNDLE without launching."
    ;;
  --debug|debug)
    lldb -- "$RUN_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
