#!/bin/bash
# YouTube Grabber Installer
# Double-click this file to install YouTube Grabber.

clear
echo "=============================="
echo "  YouTube Grabber - Installer"
echo "=============================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/YouTube Grabber.app"
APP_DEST="/Applications/YouTube Grabber.app"

if [[ ! -d "$APP_SRC" ]]; then
    echo "❌ Error: YouTube Grabber.app not found."
    echo "   Make sure you opened the DMG first."
    echo ""
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# Remove old version if exists
if [[ -d "$APP_DEST" ]]; then
    echo "→ Removing previous version..."
    rm -rf "$APP_DEST"
fi

# Copy app to Applications
echo "→ Copying to Applications..."
cp -R "$APP_SRC" "$APP_DEST"

# Remove quarantine attribute (bypasses Gatekeeper for unsigned apps)
echo "→ Clearing quarantine..."
xattr -cr "$APP_DEST"

echo ""
echo "✅ YouTube Grabber installed!"
echo "→ Launching..."
echo ""

open "$APP_DEST"

# Close terminal window after 2s
sleep 2
osascript -e 'tell application "Terminal" to close front window' 2>/dev/null &
exit 0
