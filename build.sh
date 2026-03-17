#!/bin/bash

APP_NAME="VolumeNavigator"
BUNDLE_ID="com.local.volumenavigator"
BUILD_DIR="$(pwd)"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

swiftc main.swift \
  -o "$MACOS_DIR/$APP_NAME" \
  -framework Cocoa \
  -framework Carbon \
  -framework ApplicationServices

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>This app needs accessibility access to control windows and tabs.</string>
</dict>
</plist>
EOF

chmod +x "$MACOS_DIR/$APP_NAME"

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_NAME.app in current directory."
