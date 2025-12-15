#!/bin/bash

set -e

echo "Installing MeetingScribe..."

# Check if binary exists
if [ ! -f "build/meetingscribe" ]; then
    echo "❌ Binary not found. Run ./scripts/build-and-sign.sh first"
    exit 1
fi

# Install binary
echo "Installing binary..."
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

# Load LaunchAgent
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "✅ Installation complete"
echo ""
echo "MeetingScribe is now running in the background"
echo "Look for the microphone icon in your menu bar"
echo ""
echo "Logs: tail -f ~/Library/Logs/MeetingScribe/stderr.log"
