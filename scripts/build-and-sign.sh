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

# Code signing
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing app bundle with identity: $SIGNING_IDENTITY"
    
    # Check if entitlements file exists
    if [ -f "MeetingScribe.entitlements" ]; then
        ENTITLEMENTS_FLAG="--entitlements MeetingScribe.entitlements"
    else
        echo "⚠️  No entitlements file found, signing without entitlements"
        ENTITLEMENTS_FLAG=""
    fi
    
    # Sign the binary inside the app bundle
    codesign --force --sign "$SIGNING_IDENTITY" \
        $ENTITLEMENTS_FLAG \
        --options runtime \
        "$APP_DIR/Contents/MacOS/meetingscribe"
    
    # Sign the entire app bundle
    codesign --force --sign "$SIGNING_IDENTITY" \
        $ENTITLEMENTS_FLAG \
        --options runtime \
        "$APP_DIR"
    
    # Verify signature
    echo "Verifying signature..."
    codesign --verify --verbose "$APP_DIR"
    
    echo "✅ Code signing complete"
else
    echo "⚠️  No signing identity found (set SIGNING_IDENTITY environment variable to sign)"
    echo "     App will be ad-hoc signed for local use only"
    
    # Ad-hoc signing for local development
    codesign --force --sign - "$APP_DIR/Contents/MacOS/meetingscribe" 2>/dev/null || true
    codesign --force --sign - "$APP_DIR" 2>/dev/null || true
fi

echo ""
echo "Next steps:"
echo "  ./scripts/install.sh    # Install as LaunchAgent"
echo "  ./build/meetingscribe   # Run directly for testing"
