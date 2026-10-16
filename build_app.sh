#!/usr/bin/env bash
# One-click build: fetches engines, compiles OpenRecast.app and packages a drag-to-install DMG.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
APP="dist/OpenRecast.app"

./scripts/fetch_binaries.sh

echo "Compiling…"
swift build -c release --arch arm64
BUILD="$(swift build -c release --arch arm64 --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "Drawing app icon…"
  swift scripts/make_icon.swift Resources/AppIcon.icns
fi

echo "Assembling $APP…"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BUILD/OpenRecast" "$APP/Contents/MacOS/OpenRecast"
cp Resources/bin/ffmpeg "$APP/Contents/Resources/bin/ffmpeg"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenRecast</string>
  <key>CFBundleDisplayName</key><string>OpenRecast</string>
  <key>CFBundleIdentifier</key><string>app.openrecast.OpenRecast</string>
  <key>CFBundleExecutable</key><string>OpenRecast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>OpenRecast · MIT License</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP/Contents/Resources/bin/ffmpeg"
codesign --force --sign - "$APP"

echo "Packaging DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OpenRecast" -srcfolder "$STAGE" -ov -format UDZO "dist/OpenRecast-${VERSION}.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Done:"
echo "  dist/OpenRecast.app"
echo "  dist/OpenRecast-${VERSION}.dmg ($(du -h "dist/OpenRecast-${VERSION}.dmg" | cut -f1))"
