#!/bin/bash

echo "========================================="
echo "MeetingScribe TCC Diagnostic"
echo "========================================="
echo ""

APP_PATH="/Applications/MeetingScribe.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at $APP_PATH"
    exit 1
fi

echo "✅ App found at: $APP_PATH"
echo ""

echo "Bundle Info:"
echo "  Bundle ID: $(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "ERROR")"
echo "  Version: $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "ERROR")"
echo ""

echo "Code Signature:"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature" | head -5
echo ""

echo "Running Processes:"
ps aux | grep "[m]eetingscribe" | awk '{print "  PID: " $2 " | Command: " $11 " " $12 " " $13}'
echo ""

echo "LaunchAgent Status:"
if [ -f ~/Library/LaunchAgents/com.meetingscribe.daemon.plist ]; then
    echo "  ✅ Plist exists at ~/Library/LaunchAgents/com.meetingscribe.daemon.plist"
else
    echo "  ❌ Plist not found"
fi

LOADED=$(launchctl list | grep -i meeting || echo "")
if [ -n "$LOADED" ]; then
    echo "  ✅ LaunchAgent loaded:"
    echo "    $LOADED"
else
    echo "  ❌ LaunchAgent not loaded"
fi
echo ""

echo "TCC Database (Screen Recording):"
echo "  User database:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%meeting%';" 2>/dev/null || echo "    (none or error)"

echo "  System database:"
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceScreenCapture' AND client LIKE '%meeting%';" 2>/dev/null || echo "    (none or error)"
echo ""

echo "TCC Database (Microphone):"
echo "  User database:"
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%meeting%';" 2>/dev/null || echo "    (none or error)"

echo "  System database:"
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason FROM access WHERE service='kTCCServiceMicrophone' AND client LIKE '%meeting%';" 2>/dev/null || echo "    (none or error)"
echo ""

echo "Recent Logs (last 20 lines):"
tail -20 ~/Library/Logs/MeetingScribe/stderr.log 2>/dev/null || echo "  (no logs)"
echo ""

echo "========================================="
echo "Diagnostic complete"
echo "========================================="
