#!/bin/bash

set -e

echo "Installing MeetingScribe..."

# Check if binary exists
if [ ! -f "build/meetingscribe" ]; then
    echo "❌ Binary not found. Run ./scripts/build-and-sign.sh first"
    exit 1
fi

# Install app bundle (preferred for permissions + stability)
echo "Installing app bundle..."
APP_SRC="build/MeetingScribe.app"
APP_DEST_DIR="$HOME/Applications"
APP_DEST="$APP_DEST_DIR/MeetingScribe.app"

if [ ! -d "$APP_SRC" ]; then
    echo "❌ App bundle not found. Run ./scripts/build-and-sign.sh first"
    exit 1
fi

mkdir -p "$APP_DEST_DIR"
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
chmod +x "$APP_DEST/Contents/MacOS/meetingscribe"

# Keep a /usr/local/bin convenience shim for manual testing if desired
echo "Installing binary shim..."
sudo mkdir -p /usr/local/bin
sudo cp build/meetingscribe /usr/local/bin/
sudo chmod +x /usr/local/bin/meetingscribe

# Install LaunchAgent
echo "Installing LaunchAgent..."
PLIST_SRC="resources/com.meetingscribe.daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"

# Replace USERNAME placeholder
sed "s/USERNAME/$USER/g" "$PLIST_SRC" > "$PLIST_DEST"

# Create log directory
mkdir -p "$HOME/Library/Logs/MeetingScribe"

# Load LaunchAgent (modern launchctl)
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
# Ensure it's started/restarted now
launchctl kickstart -k "$DOMAIN/com.meetingscribe.daemon" 2>/dev/null || true

echo "✅ Installation complete"
echo ""
echo "MeetingScribe is now running in the background"
echo "Look for the microphone icon in your menu bar"
echo ""
echo "Logs: tail -f ~/Library/Logs/MeetingScribe/stderr.log"
