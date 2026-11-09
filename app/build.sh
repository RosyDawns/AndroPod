#!/bin/sh
# Builds AndroPod.app without Xcode. SwiftPM produces the binary; this script
# wraps it in a bundle so AppKit gives us a real window and Dock presence.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
BUNDLE="$APP_DIR/build/AndroPod.app"

cd "$APP_DIR"
swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$APP_DIR/.build/release/AndroPod" "$BUNDLE/Contents/MacOS/AndroPod"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AndroPod</string>
    <key>CFBundleDisplayName</key>
    <string>AndroPod</string>
    <key>CFBundleIdentifier</key>
    <string>com.andropod.app</string>
    <key>CFBundleExecutable</key>
    <string>AndroPod</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- This app owns no document windows worth restoring. Leaving window
         restoration on means every killed-and-relaunched debug cycle shows a
         modal "reopen windows?" alert, which blocks launch behind user input. -->
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "已生成: $BUNDLE"
