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

echo ""
echo "MeetingScribe has been uninstalled"
echo ""
echo "Optional cleanup:"
echo "  rm -rf ~/.meetingscribe              # Remove config"
echo "  rm -rf ~/Documents/MeetingScribe     # Remove recordings"
echo "  rm -rf ~/Library/Logs/MeetingScribe  # Remove logs"
