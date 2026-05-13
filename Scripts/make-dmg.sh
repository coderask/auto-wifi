#!/usr/bin/env bash
#
# Build a distributable DMG from the notarized .app bundle. Uses `hdiutil` (built into macOS)
# so there's no third-party dependency.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/auto-wifi.app"
DMG="$ROOT/dist/auto-wifi.dmg"
STAGING="$ROOT/dist/dmg-staging"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

if [[ ! -d "$APP" ]]; then
  echo "✗ Bundle not found at $APP — run make release first." >&2
  exit 1
fi

echo "▸ Staging DMG contents…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "▸ Creating DMG (v$VERSION)…"
hdiutil create -volname "auto-wifi $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"
echo "✓ DMG at $DMG"
