#!/bin/sh
# Usage: ./build.sh            build "Multi Claude.app" in this folder
#        ./build.sh install    build, copy to /Applications, open at login, launch
#        ./build.sh dmg        build a universal (arm64 + x86_64) app and package dist/MultiClaude.dmg
set -e
cd "$(dirname "$0")"
APP="Multi Claude.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with: swift tools/make-icon.swift
if [ "$1" = "dmg" ]; then
  swiftc -O -target arm64-apple-macos13 Sources/*.swift -o /tmp/MultiClaude-arm64
  swiftc -O -target x86_64-apple-macos13 Sources/*.swift -o /tmp/MultiClaude-x86_64
  lipo -create /tmp/MultiClaude-arm64 /tmp/MultiClaude-x86_64 -output "$APP/Contents/MacOS/MultiClaude"
  rm -f /tmp/MultiClaude-arm64 /tmp/MultiClaude-x86_64
else
  swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/MultiClaude"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Multi Claude</string>
  <key>CFBundleIdentifier</key><string>dev.multiclaude.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MultiClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $PWD/$APP"

if [ "$1" = "install" ]; then
  pkill -f "Multi Claude.app/Contents/MacOS/MultiClaude" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  "/Applications/$APP/Contents/MacOS/MultiClaude" --register-login || echo "Couldn't add to Login Items; use the Open at Login switch in the app."
  open "/Applications/$APP"
  echo "Installed to /Applications and launched."
fi

if [ "$1" = "dmg" ]; then
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  mkdir -p dist
  rm -f dist/MultiClaude.dmg
  hdiutil create -volname "Multi Claude" -srcfolder "$STAGE" -ov -format UDZO dist/MultiClaude.dmg >/dev/null
  rm -rf "$STAGE"
  echo "Packaged $PWD/dist/MultiClaude.dmg"
fi
