#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/version.env"
BUILD_MODE="${CODEX_MULTI_SWITCHER_BUILD_MODE:-preview}"
case "$BUILD_MODE" in
  preview)
    APP_NAME="Codex Multi Switcher Preview"
    BUNDLE_ID="com.codexmultiswitcher.preview"
    SWIFT_FLAG="CODEX_MULTI_SWITCHER_PREVIEW"
    ;;
  local)
    APP_NAME="Codex Multi Switcher Local"
    BUNDLE_ID="com.codexmultiswitcher.local"
    SWIFT_FLAG="CODEX_MULTI_SWITCHER_LOCAL"
    ;;
  *)
    echo "Unknown build mode: $BUILD_MODE" >&2
    exit 1
    ;;
esac
BUILD_DIR="$ROOT_DIR/.build/$BUILD_MODE-build"
APP_BUNDLE="${1:-$ROOT_DIR/.build/$APP_NAME.app}"

if [[ -e "$APP_BUNDLE" ]]; then
  echo "Output already exists; choose a new output path: $APP_BUNDLE" >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

BUILD_ARGS=(--package-path "$ROOT_DIR" -c debug --scratch-path "$BUILD_DIR"
  -Xswiftc "-D$SWIFT_FLAG")
if [[ -n "${CODEX_PROFILE_SDK:-}" ]]; then
  BUILD_ARGS+=(--sdk "$CODEX_PROFILE_SDK")
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

mkdir -p "$(dirname "$APP_BUNDLE")"
STAGING="$(mktemp -d "$(dirname "$APP_BUNDLE")/.switcher-preview.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Helpers" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/CodexMultiSwitcher" "$STAGED_APP/Contents/MacOS/CodexMultiSwitcher"
cp "$BIN_DIR/codex-profile" "$STAGED_APP/Contents/Helpers/codex-profile"
cp "$ROOT_DIR/assets/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/assets/codex-multi-switcher-menu-icon-empty.png" "$STAGED_APP/Contents/Resources/"
cp "$ROOT_DIR/assets/openai-knot-menu.png" "$STAGED_APP/Contents/Resources/"
cp "$ROOT_DIR/Scripts/ClaudeStatuslineBridge.py" "$STAGED_APP/Contents/Resources/ClaudeStatuslineBridge.py"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>CodexMultiSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP/Contents/Helpers/codex-profile"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
mv "$STAGED_APP" "$APP_BUNDLE"
printf 'Built %s: %s\n' "$BUILD_MODE" "$APP_BUNDLE"
printf 'Open with: open "%s"\n' "$APP_BUNDLE"
