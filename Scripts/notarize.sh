#!/usr/bin/env bash
#
# Submit the signed .app to Apple's notarization service and staple the ticket.
#
# Required: a notarytool keychain profile created once with:
#   xcrun notarytool store-credentials AutoWiFiNotarization \
#     --apple-id YOUR_APPLE_ID \
#     --team-id YOUR_TEAM_ID \
#     --password "app-specific-password"
#
# Required env:
#   NOTARY_PROFILE   (default: AutoWiFiNotarization)
#
# Usage:
#   ./Scripts/notarize.sh
#
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-AutoWiFiNotarization}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/auto-wifi.app"
ZIP="$ROOT/dist/auto-wifi.zip"

if [[ ! -d "$APP" ]]; then
  echo "✗ Bundle not found at $APP — run make sign first." >&2
  exit 1
fi

echo "▸ Zipping bundle for upload…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling ticket…"
xcrun stapler staple "$APP"

echo "▸ Verifying staple…"
xcrun stapler validate "$APP"
spctl --assess --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true

echo "✓ Notarized and stapled."
