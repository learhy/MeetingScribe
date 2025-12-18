#!/bin/bash

# Embed the first-run installer and supporting scripts into the app bundle
# This should be run after building the app bundle but before packaging

set -e

APP_BUNDLE="${1:-build/MeetingScribe.app}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle not found: $APP_BUNDLE"
    exit 1
fi

echo "Embedding installer and scripts into app bundle..."

# Create Resources/scripts directory if it doesn't exist
SCRIPTS_DIR="$APP_BUNDLE/Contents/Resources/scripts"
mkdir -p "$SCRIPTS_DIR"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy installer scripts
echo "  • Copying first-run-installer.sh"
cp "$SCRIPT_DIR/first-run-installer.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/first-run-installer.sh"

echo "  • Copying meetingscribe-ctl.sh"
cp "$SCRIPT_DIR/meetingscribe-ctl.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/meetingscribe-ctl.sh"

echo "  • Copying uninstall.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/uninstall.sh"

echo "  • Copying reset-permissions.sh"
cp "$SCRIPT_DIR/reset-permissions.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/reset-permissions.sh"

# Copy any Python scripts that might be needed
if [ -f "$SCRIPT_DIR/diarize_audio_fast.py" ]; then
    echo "  • Copying diarize_audio_fast.py"
    cp "$SCRIPT_DIR/diarize_audio_fast.py" "$SCRIPTS_DIR/"
fi

echo "✅ Installer and scripts embedded successfully"
