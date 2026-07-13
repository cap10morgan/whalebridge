#!/bin/bash
# Compile the Liquid Glass app icon (assets/Whalebridge.icon via actool) and
# render the menu bar template PNG (assets/menubar.svg via librsvg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found — brew install librsvg" >&2; exit 1; }

# Liquid Glass icon: actool emits Assets.car (macOS 26 renders real glass from
# it) plus a flattened Whalebridge.icns fallback for everything else.
OUT="$ROOT/build/icon"
rm -rf "$OUT"
mkdir -p "$OUT"
xcrun actool --output-format human-readable-text --notices --warnings \
    --app-icon Whalebridge --include-all-app-icons \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx \
    --output-partial-info-plist "$OUT/partial.plist" \
    --compile "$OUT" "$ROOT/assets/Whalebridge.icon" >/dev/null

# Single 36px (18pt @2x) template image; the app sets its point size to 18.
mkdir -p "$ROOT/app/Sources/Whalebridge/Resources"
rsvg-convert -w 36 -h 36 "$ROOT/assets/menubar.svg" -o "$ROOT/app/Sources/Whalebridge/Resources/MenuBarIcon.png"

echo "generated build/icon/{Assets.car,Whalebridge.icns} and app MenuBarIcon.png"
