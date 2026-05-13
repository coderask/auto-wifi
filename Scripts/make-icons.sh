#!/usr/bin/env bash
#
# Generate macOS-ready icon assets from the source PNGs in Resources/Icons/.
#
# Inputs:
#   Resources/Icons/AppIcon-source.png    — colored 1024×1024+ app icon (full-color, w/ rounded square frame)
#   Resources/Icons/MenuBar-source.png    — blue-on-white version for the menubar template
#
# Outputs:
#   Resources/Icons/AppIcon.icns          — Apple icon bundle, all sizes 16→1024
#   Resources/Icons/MenuBarIcon.png       — 22×22 black-on-transparent template (1x menubar)
#   Resources/Icons/MenuBarIcon@2x.png    — 44×44 black-on-transparent template (retina)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS="$ROOT/Resources/Icons"
APP_SRC="$ICONS/AppIcon-source.png"
MENU_SRC="$ICONS/MenuBar-source.png"
TEMPLATE_HI_RES="$ICONS/MenuBar-template-2048.png"

if [[ ! -f "$APP_SRC" || ! -f "$MENU_SRC" ]]; then
    echo "✗ Missing source files. Need both:" >&2
    echo "    $APP_SRC" >&2
    echo "    $MENU_SRC" >&2
    exit 1
fi

# ---- App icon ----------------------------------------------------------------

echo "▸ Building AppIcon.icns from $APP_SRC"

ICONSET="$ICONS/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple's iconset naming convention: icon_NxN.png + icon_NxN@2x.png for retina.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    SIZE="${entry%%:*}"
    NAME="${entry##*:}"
    sips -z "$SIZE" "$SIZE" "$APP_SRC" --out "$ICONSET/$NAME" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICONS/AppIcon.icns"
rm -rf "$ICONSET"

echo "  ✓ $ICONS/AppIcon.icns"

# ---- Menubar template --------------------------------------------------------

echo "▸ Converting menubar template (blue → black on transparent)"
swift "$ROOT/Scripts/process-menubar-icon.swift" "$MENU_SRC" "$TEMPLATE_HI_RES"

echo "▸ Resizing menubar template to 1x (22) + 2x (44)"
sips -z 22 22 "$TEMPLATE_HI_RES" --out "$ICONS/MenuBarIcon.png" >/dev/null
sips -z 44 44 "$TEMPLATE_HI_RES" --out "$ICONS/MenuBarIcon@2x.png" >/dev/null

echo "  ✓ $ICONS/MenuBarIcon.png + @2x"
echo
echo "✓ Icon assets ready."
