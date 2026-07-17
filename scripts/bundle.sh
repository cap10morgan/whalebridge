#!/bin/bash
# Assemble build/Whalebridge.app from the release builds of the app and the
# vendored socktainer daemon. Ad-hoc signed; use SIGN_IDENTITY for releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT/app/.build/release/Whalebridge"
DAEMON_BIN="$ROOT/vendor/socktainer/.build/release/socktainer"
SPARKLE_FW="$ROOT/app/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
OUT="$ROOT/build/Whalebridge.app"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Sparkle: where the app looks for updates, and the public half of the EdDSA key
# whose private half lives in the release manager's login keychain. An empty
# APPCAST_URL builds an app with the update UI hidden.
APPCAST_URL="${APPCAST_URL:-https://github.com/cap10morgan/whalebridge/releases/latest/download/appcast.xml}"
SUPUBLIC_ED_KEY="${SUPUBLIC_ED_KEY:-hMwzmzzRFbLpZ4YmzHAxM8v1Py1WV7vEhItZ4n8oQLI=}"
# apple/container version the vendored socktainer pins — the app offers to
# install exactly this version on first run.
REQUIRED_CONTAINER_VERSION="$(sed -n 's/.*appleContainerVersion = "\([0-9.]*\)".*/\1/p' "$ROOT/vendor/socktainer/Package.swift" | head -1)"
[[ -n "$REQUIRED_CONTAINER_VERSION" ]] || { echo "could not read appleContainerVersion from vendor/socktainer/Package.swift" >&2; exit 1; }

for bin in "$APP_BIN" "$DAEMON_BIN"; do
    [[ -x "$bin" ]] || { echo "missing $bin — run make bundle" >&2; exit 1; }
done

[[ -d "$SPARKLE_FW" ]] || { echo "missing $SPARKLE_FW — run swift build in app/" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"

cp "$APP_BIN" "$OUT/Contents/MacOS/Whalebridge"
cp "$DAEMON_BIN" "$OUT/Contents/MacOS/socktainer"
# The app binary links @rpath/Sparkle.framework (rpath set in Package.swift).
cp -R "$SPARKLE_FW" "$OUT/Contents/Frameworks/"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$OUT/Contents/Resources/"
[[ -f "$ROOT/build/icon/Assets.car" ]] || { echo "missing build/icon/Assets.car — run make icons" >&2; exit 1; }
cp "$ROOT/build/icon/Assets.car" "$OUT/Contents/Resources/Assets.car"
cp "$ROOT/build/icon/Whalebridge.icns" "$OUT/Contents/Resources/Whalebridge.icns"
# SPM resource bundle (menu bar icon). MenuBarIcon looks for it here first
# (see MenuBarIcon.swift) — SwiftPM's generated Bundle.module accessor
# expects a flat layout next to the executable, which a real .app isn't.
[[ -d "$ROOT/app/.build/release/Whalebridge_Whalebridge.bundle" ]] || { echo "missing app/.build/release/Whalebridge_Whalebridge.bundle — run swift build in app/" >&2; exit 1; }
cp -R "$ROOT/app/.build/release/Whalebridge_Whalebridge.bundle" "$OUT/Contents/Resources/"

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
    <key>SUFeedURL</key><string>${APPCAST_URL}</string>
    <key>SUPublicEDKey</key><string>${SUPUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
EOF

# The hardened runtime enables library validation, which demands the embedded
# Sparkle.framework share the app's Team ID. Ad-hoc signatures have no team, so
# nothing can satisfy it and dyld refuses to load the framework — harden only
# when there's a real identity (which notarized releases need anyway).
sign() {
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
    fi
}

# Nested code signs innermost-out; --deep would skip these and produce a bundle
# that launches but can't run the updater.
FW="$OUT/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$FW/XPCServices/Downloader.xpc" "$FW/XPCServices/Installer.xpc" \
    "$FW/Updater.app" "$FW/Autoupdate"; do
    sign "$nested"
done
sign "$OUT/Contents/Frameworks/Sparkle.framework"
sign "$OUT/Contents/MacOS/socktainer"
sign "$OUT"

echo "built $OUT"
