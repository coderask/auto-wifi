#!/usr/bin/env bash
#
# Re-sign an existing .app bundle with a real Developer ID Application identity, hardened
# runtime, and a secure timestamp. Required for notarization.
#
# Required env:
#   DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Aarnav Koushik (TEAMID)"
#
# Usage:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: …" ./Scripts/sign.sh
#
set -euo pipefail

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "✗ DEVELOPER_ID_APPLICATION not set." >&2
  echo "  Find your identity name with: security find-identity -v -p codesigning" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/auto-wifi.app"

if [[ ! -d "$APP" ]]; then
  echo "✗ Bundle not found at $APP — run make app first." >&2
  exit 1
fi

echo "▸ Signing with: $DEVELOPER_ID_APPLICATION"
codesign --force --deep --sign "$DEVELOPER_ID_APPLICATION" \
  --entitlements "$ROOT/Resources/AutoWiFi.entitlements" \
  --options runtime \
  --timestamp \
  "$APP"

echo "▸ Verifying…"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
spctl --assess --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true

echo "✓ Signed $APP"
