#!/bin/bash

# Reset TCC permissions for MeetingScribe
# This clears all privacy permissions so they can be granted again

set -e

BUNDLE_ID="com.meetingscribe.daemon"

echo "Resetting TCC permissions for MeetingScribe..."
echo ""

# Check if app bundle exists
APP_PATH=""
if [ -d "/Applications/MeetingScribe.app" ]; then
    APP_PATH="/Applications/MeetingScribe.app"
elif [ -d "$HOME/Applications/MeetingScribe.app" ]; then
    APP_PATH="$HOME/Applications/MeetingScribe.app"
fi

if [ -z "$APP_PATH" ]; then
    echo "⚠️  Warning: MeetingScribe.app not found in /Applications or ~/Applications"
    echo "   tccutil reset may not work if the app is not at its original location"
    echo ""
fi

# Reset permissions
echo "Running: tccutil reset All $BUNDLE_ID"
tccutil reset All "$BUNDLE_ID"

echo ""
echo "✅ TCC permissions reset"
echo ""
echo "Next steps:"
echo "1. Restart MeetingScribe: meetingscribe-ctl restart"
echo "2. Grant permissions when prompted"
echo "3. Or manually enable in System Settings > Privacy & Security > Screen Recording"
