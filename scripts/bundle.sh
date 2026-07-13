#!/bin/bash
# Assemble build/Whalebridge.app from the release builds of the app and the
# vendored socktainer daemon. Ad-hoc signed; use SIGN_IDENTITY for releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT/app/.build/release/Whalebridge"
DAEMON_BIN="$ROOT/vendor/socktainer/.build/release/socktainer"
OUT="$ROOT/build/Whalebridge.app"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# apple/container version the vendored socktainer pins — the app offers to
# install exactly this version on first run.
REQUIRED_CONTAINER_VERSION="$(sed -n 's/.*appleContainerVersion = "\([0-9.]*\)".*/\1/p' "$ROOT/vendor/socktainer/Package.swift" | head -1)"
[[ -n "$REQUIRED_CONTAINER_VERSION" ]] || { echo "could not read appleContainerVersion from vendor/socktainer/Package.swift" >&2; exit 1; }

for bin in "$APP_BIN" "$DAEMON_BIN"; do
    [[ -x "$bin" ]] || { echo "missing $bin — run make bundle" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$APP_BIN" "$OUT/Contents/MacOS/Whalebridge"
cp "$DAEMON_BIN" "$OUT/Contents/MacOS/socktainer"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$OUT/Contents/Resources/"
[[ -f "$ROOT/build/icon/Assets.car" ]] || { echo "missing build/icon/Assets.car — run make icons" >&2; exit 1; }
cp "$ROOT/build/icon/Assets.car" "$OUT/Contents/Resources/Assets.car"
cp "$ROOT/build/icon/Whalebridge.icns" "$OUT/Contents/Resources/Whalebridge.icns"
# SPM resource bundle (menu bar icon)
cp -R "$ROOT/app/.build/release/Whalebridge_Whalebridge.bundle" "$OUT/Contents/Resources/" 2>/dev/null || true

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Whalebridge</string>
    <key>CFBundleIdentifier</key><string>me.wesmorgan.whalebridge</string>
    <key>CFBundleName</key><string>Whalebridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Whalebridge</string>
    <key>CFBundleIconName</key><string>Whalebridge</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Wes Morgan. Apache License 2.0.</string>
    <key>WBRequiredContainerVersion</key><string>${REQUIRED_CONTAINER_VERSION}</string>
</dict>
</plist>
EOF

codesign --force --options runtime --sign "$SIGN_IDENTITY" "$OUT/Contents/MacOS/socktainer"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$OUT"

echo "built $OUT"
