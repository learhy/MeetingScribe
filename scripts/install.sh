#!/bin/bash

set -e

# Installation mode: 'user' (default) or 'system'
INSTALL_MODE="${1:-user}"

echo "Installing MeetingScribe..."

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check if binary exists
if [ ! -f "$PROJECT_DIR/build/meetingscribe" ]; then
    echo "❌ Binary not found. Run ./scripts/build-and-sign.sh first"
    exit 1
fi

# Determine installation directory based on mode
if [ "$INSTALL_MODE" = "system" ]; then
    APP_DEST_DIR="/Applications"
    echo "Installing app bundle (system-wide)..."
else
    APP_DEST_DIR="$HOME/Applications"
    echo "Installing app bundle (user)..."
fi

APP_SRC="$PROJECT_DIR/build/MeetingScribe.app"
APP_DEST="$APP_DEST_DIR/MeetingScribe.app"

if [ ! -d "$APP_SRC" ]; then
    echo "❌ App bundle not found at: $APP_SRC"
    echo "Run ./scripts/build-and-sign.sh first"
    exit 1
fi

if [ "$INSTALL_MODE" = "system" ]; then
    sudo mkdir -p "$APP_DEST_DIR"
    sudo rm -rf "$APP_DEST"
    sudo cp -R "$APP_SRC" "$APP_DEST"
    sudo chmod +x "$APP_DEST/Contents/MacOS/meetingscribe"
else
    mkdir -p "$APP_DEST_DIR"
    rm -rf "$APP_DEST"
    cp -R "$APP_SRC" "$APP_DEST"
    chmod +x "$APP_DEST/Contents/MacOS/meetingscribe"
fi

# Install CLI control script
echo "Installing CLI control script..."
sudo mkdir -p /usr/local/bin
sudo cp "$PROJECT_DIR/scripts/meetingscribe-ctl.sh" /usr/local/bin/meetingscribe-ctl
sudo chmod +x /usr/local/bin/meetingscribe-ctl

# Install LaunchAgent
echo "Installing LaunchAgent..."
PLIST_SRC="$PROJECT_DIR/resources/com.meetingscribe.daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"

# Replace USERNAME placeholder
sed "s/USERNAME/$USER/g" "$PLIST_SRC" > "$PLIST_DEST"

# Verify app was actually copied
if [ ! -d "$APP_DEST" ]; then
    echo "❌ Failed to copy app bundle to $APP_DEST"
    exit 1
fi
echo "✅ App bundle installed to: $APP_DEST"

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
echo "Control the daemon with:"
echo "  meetingscribe-ctl status   # Check status"
echo "  meetingscribe-ctl stop     # Stop daemon"
echo "  meetingscribe-ctl start    # Start daemon"
echo "  meetingscribe-ctl restart  # Restart daemon"
echo "  meetingscribe-ctl logs     # View logs"
echo ""
echo "Installed to: $APP_DEST"
