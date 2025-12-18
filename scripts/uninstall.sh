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

# Remove CLI control script
if [ -f "/usr/local/bin/meetingscribe-ctl" ]; then
    sudo rm /usr/local/bin/meetingscribe-ctl
    echo "✅ CLI control script removed"
fi

# Remove app bundle (check both user and system locations)
if [ -d "$HOME/Applications/MeetingScribe.app" ]; then
    rm -rf "$HOME/Applications/MeetingScribe.app"
    echo "✅ App bundle removed (user)"
fi

if [ -d "/Applications/MeetingScribe.app" ]; then
    sudo rm -rf "/Applications/MeetingScribe.app"
    echo "✅ App bundle removed (system)"
fi

# Reset privacy permissions (TCC database)
echo ""
echo "Resetting privacy permissions..."
BUNDLE_ID="com.meetingscribe.daemon"
tccutil reset All "$BUNDLE_ID" 2>/dev/null || echo "⚠️  Could not reset permissions (may need manual cleanup in System Settings)"
echo "✅ Privacy permissions reset"

# Reset UserDefaults (including CLI installation prompt)
defaults delete com.meetingscribe.daemon 2>/dev/null || true
echo "✅ App preferences cleared"

echo ""
echo "MeetingScribe has been uninstalled"
echo "Privacy permissions (Screen Recording, Notifications) have been reset"
echo ""
echo "Optional cleanup:"
echo "  rm -rf ~/.meetingscribe              # Remove config"
echo "  rm -rf ~/Documents/MeetingScribe     # Remove recordings"
echo "  rm -rf ~/Library/Logs/MeetingScribe  # Remove logs"
