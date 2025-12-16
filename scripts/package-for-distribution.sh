#!/bin/bash

# Package MeetingScribe for distribution
# Creates a distributable DMG or ZIP archive

set -e

VERSION="${1:-1.0}"
OUTPUT_DIR="dist"
APP_NAME="MeetingScribe"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "Packaging ${APP_NAME} v${VERSION} for distribution..."

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle not found. Run ./scripts/build-and-sign.sh first"
    exit 1
fi

# Verify app bundle is signed
if ! codesign --verify "$APP_BUNDLE" 2>/dev/null; then
    echo "⚠️  Warning: App bundle is not properly signed"
    echo "   For distribution, you should sign with a Developer ID"
    echo "   Set SIGNING_IDENTITY and rebuild"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Option 1: Create DMG (prettier, more Mac-like)
echo "Creating DMG..."
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

# Create temporary DMG directory
DMG_TEMP="build/dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

# Copy app bundle to temp directory
cp -R "$APP_BUNDLE" "$DMG_TEMP/"

# Create a symbolic link to /Applications for easy drag-and-drop
ln -s /Applications "$DMG_TEMP/Applications"

# Create README for users
cat > "$DMG_TEMP/README.txt" << EOF
MeetingScribe v${VERSION}

Installation:
1. Drag MeetingScribe.app to the Applications folder
2. Open MeetingScribe from Applications
3. Grant permissions when prompted (Screen Recording, Microphone)
4. Look for the microphone icon in your menu bar

Requirements:
- macOS 13.0 (Ventura) or later
- Screen Recording permission
- Microphone permission (optional)

Configuration:
Configuration file: ~/.meetingscribe/config.json
Default template: ~/.meetingscribe/templates/default.md

For more information, visit:
https://github.com/your-repo/meeting-scribe

Control Commands (after installation):
  meetingscribe-ctl status   - Check daemon status
  meetingscribe-ctl stop     - Stop daemon
  meetingscribe-ctl start    - Start daemon
  meetingscribe-ctl restart  - Restart daemon
  meetingscribe-ctl logs     - View logs
EOF

# Create DMG using hdiutil
echo "Building DMG image..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_TEMP"

echo "✅ DMG created: $DMG_PATH"

# Option 2: Create ZIP (simpler, smaller)
echo "Creating ZIP archive..."
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"

# Create temporary directory for ZIP
ZIP_TEMP="build/zip_temp"
rm -rf "$ZIP_TEMP"
mkdir -p "$ZIP_TEMP"

# Copy app bundle
cp -R "$APP_BUNDLE" "$ZIP_TEMP/"

# Copy README
cp "$OUTPUT_DIR/../build/dmg_temp/README.txt" "$ZIP_TEMP/" 2>/dev/null || \
cat > "$ZIP_TEMP/README.txt" << EOF
MeetingScribe v${VERSION}

Installation:
1. Extract this archive
2. Move MeetingScribe.app to /Applications
3. Open MeetingScribe from Applications
4. Grant permissions when prompted

See DMG for full documentation.
EOF

# Create ZIP
cd "$ZIP_TEMP"
zip -r "../../$ZIP_PATH" . -x "*.DS_Store"
cd ../..

rm -rf "$ZIP_TEMP"

echo "✅ ZIP created: $ZIP_PATH"

# Display package info
echo ""
echo "📦 Distribution packages created:"
echo "   DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "   ZIP: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
echo ""

# Check for notarization
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "📝 Next steps for distribution:"
    echo "   1. Notarize the app with Apple:"
    echo "      xcrun notarytool submit '$DMG_PATH' --keychain-profile 'AC_PASSWORD' --wait"
    echo "   2. Staple the notarization ticket:"
    echo "      xcrun stapler staple '$DMG_PATH'"
    echo ""
else
    echo "⚠️  For public distribution, you should:"
    echo "   1. Sign with a Developer ID certificate"
    echo "   2. Notarize with Apple"
    echo "   3. Staple the notarization ticket"
    echo ""
fi

echo "Distribution packages ready for testing!"
