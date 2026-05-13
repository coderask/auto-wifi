#!/usr/bin/env bash
#
# Wrap the SwiftPM-built executable into a macOS .app bundle.
#
# Why this script exists:
#   Xcode is not installed in this environment (only Command Line Tools). SwiftPM alone
#   produces a bare Mach-O executable — but macOS Location Services authorization requires
#   a proper .app bundle with a stable bundle identifier. This script assembles that bundle
#   by hand so the app can request Location auth without an Xcode project.
#
# Usage:
#   ./Scripts/make-app.sh [debug|release]   # default: debug
#
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/auto-wifi.app"
EXECUTABLE_NAME="AutoWiFi"

echo "▸ Building Swift package ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG" --product "$EXECUTABLE_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "✗ Built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "▸ Assembling .app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP/Contents/MacOS/$EXECUTABLE_NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Icon assets — regenerate if missing, then copy into Contents/Resources/.
# AppIcon.icns gives us the Dock / Finder / Mission Control icon.
# MenuBarIcon.png + @2x is the custom template image for the menubar status item.
if [[ ! -f "$ROOT/Resources/Icons/AppIcon.icns" ]]; then
  echo "▸ Generating icon assets (one-time)…"
  "$ROOT/Scripts/make-icons.sh"
fi
cp "$ROOT/Resources/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Icons/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "$ROOT/Resources/Icons/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"

# A bundle without PkgInfo is technically valid but Finder/launchd are happier with it.
echo -n "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Ad-hoc signing (Developer ID swap-in happens in sign.sh for release)…"
codesign --force --sign - \
  --entitlements "$ROOT/Resources/AutoWiFi.entitlements" \
  --options runtime \
  --timestamp=none \
  "$APP"

echo "▸ Verifying bundle structure…"
codesign --display --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

echo
echo "✓ Built $APP"
echo "  Launch with: open '$APP'"
