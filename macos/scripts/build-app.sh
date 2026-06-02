#!/bin/bash
set -euo pipefail

# Build yt-grab-macos as a proper .app bundle
# Usage: ./scripts/build-app.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="YouTube Grabber"
BUNDLE_NAME="${APP_NAME}.app"
VERSION=$(grep -m1 'CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist" -A1 | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

echo "🔨 Building yt-grab v${VERSION}..."

# Build configuration
if [[ "${1:-}" == "--release" ]]; then
    BUILD_CONFIG="release"
    SWIFT_FLAGS="-c release"
    echo "   Mode: Release (optimized)"
else
    BUILD_CONFIG="debug"
    SWIFT_FLAGS=""
    echo "   Mode: Debug"
fi

# Step 1: Build the binary
cd "$PROJECT_DIR"
swift build $SWIFT_FLAGS 2>&1
BINARY_PATH=".build/${BUILD_CONFIG}/yt-grab-macos"

if [[ ! -f "$BINARY_PATH" ]]; then
    # Try arch-specific path
    BINARY_PATH=".build/arm64-apple-macosx/${BUILD_CONFIG}/yt-grab-macos"
fi

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "❌ Binary not found!"
    exit 1
fi

echo "✅ Binary built: $BINARY_PATH"

# Step 2: Create .app bundle structure
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/yt-grab-macos"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Copy icon if exists
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "✅ App bundle created: $APP_DIR"

# Step 3: Create DMG
DMG_NAME="yt-grab-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
DMG_TEMP="$DIST_DIR/dmg-temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP_DIR" "$DMG_TEMP/"

# Create symlink to /Applications
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create -volname "YouTube Grabber" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH" 2>/dev/null

rm -rf "$DMG_TEMP"

echo "✅ DMG created: $DMG_PATH"
echo ""
echo "📦 Distribution files:"
echo "   $APP_DIR"
echo "   $DMG_PATH"
echo ""
echo "To install: open $DMG_PATH and drag YouTube Grabber to Applications"
