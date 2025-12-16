#!/bin/bash

set -e

echo "Uninstalling MeetingScribe..."

PLIST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"

# Unload LaunchAgent
if [ -f "$PLIST" ]; then
    DOMAIN="gui/$(id -u)"
    launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
    rm "$PLIST"
    echo "✅ LaunchAgent removed"
fi

# Remove binary
if [ -f "/usr/local/bin/meetingscribe" ]; then
    sudo rm /usr/local/bin/meetingscribe
    echo "✅ Binary removed"
fi

echo ""
echo "MeetingScribe has been uninstalled"
echo ""
echo "Optional cleanup:"
echo "  rm -rf ~/.meetingscribe              # Remove config"
echo "  rm -rf ~/Documents/MeetingScribe     # Remove recordings"
echo "  rm -rf ~/Library/Logs/MeetingScribe  # Remove logs"
