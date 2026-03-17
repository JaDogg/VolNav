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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>This app needs accessibility access to control windows and tabs.</string>
</dict>
</plist>
EOF

# Build icon from SVG if icon.svg exists and iconutil/magick are available
if [ -f "$BUILD_DIR/icon.svg" ] && command -v magick &>/dev/null && command -v iconutil &>/dev/null; then
    ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    magick "$BUILD_DIR/icon.svg" -resize 16x16     "$ICONSET_DIR/icon_16x16.png"
    magick "$BUILD_DIR/icon.svg" -resize 32x32     "$ICONSET_DIR/icon_16x16@2x.png"
    magick "$BUILD_DIR/icon.svg" -resize 32x32     "$ICONSET_DIR/icon_32x32.png"
    magick "$BUILD_DIR/icon.svg" -resize 64x64     "$ICONSET_DIR/icon_32x32@2x.png"
    magick "$BUILD_DIR/icon.svg" -resize 128x128   "$ICONSET_DIR/icon_128x128.png"
    magick "$BUILD_DIR/icon.svg" -resize 256x256   "$ICONSET_DIR/icon_128x128@2x.png"
    magick "$BUILD_DIR/icon.svg" -resize 256x256   "$ICONSET_DIR/icon_256x256.png"
    magick "$BUILD_DIR/icon.svg" -resize 512x512   "$ICONSET_DIR/icon_256x256@2x.png"
    magick "$BUILD_DIR/icon.svg" -resize 512x512   "$ICONSET_DIR/icon_512x512.png"
    magick "$BUILD_DIR/icon.svg" -resize 1024x1024 "$ICONSET_DIR/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
    echo "Icon built and added to bundle."
fi

chmod +x "$MACOS_DIR/$APP_NAME"

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_NAME.app in current directory."
