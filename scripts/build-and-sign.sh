#!/bin/bash

set -e

echo "Building MeetingScribe..."

# Build with Swift Package Manager
swift build -c release

# Create build artifacts directory
mkdir -p build

# Copy standalone binary (handy for local testing)
cp .build/release/meetingscribe build/

# Create minimal app bundle (improves macOS permissions + UserNotifications behavior)
APP_NAME="MeetingScribe.app"
APP_DIR="build/$APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/meetingscribe "$APP_DIR/Contents/MacOS/meetingscribe"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "✅ Build complete: build/meetingscribe"
echo "✅ App bundle ready: $APP_DIR"

# Optional: Code signing
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing binary with identity: $SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements MeetingScribe.entitlements \
        --options runtime \
        build/meetingscribe
    echo "✅ Code signing complete"
else
    echo "⚠️  No signing identity found (set SIGNING_IDENTITY environment variable to sign)"
fi

echo ""
echo "Next steps:"
echo "  ./scripts/install.sh    # Install as LaunchAgent"
echo "  ./build/meetingscribe   # Run directly for testing"
