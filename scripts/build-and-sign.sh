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

# Bundle Python environment
echo "Bundling Python environment..."
if [ ! -d "build/python-bundle" ]; then
    echo "Python bundle not found, creating it (this may take 5-10 minutes)..."
    ./scripts/bundle-python-env.sh
else
    echo "Using existing Python bundle (run ./scripts/bundle-python-env.sh to rebuild)"
fi

# Copy Python bundle to app Resources
echo "Copying Python bundle to app..."
mkdir -p "$APP_DIR/Contents/Resources"
cp -R build/python-bundle "$APP_DIR/Contents/Resources/python"

# Copy diarization script to Resources
mkdir -p "$APP_DIR/Contents/Resources/scripts"
cp scripts/diarize_audio_fast.py "$APP_DIR/Contents/Resources/scripts/"
cp scripts/requirements-diarization.txt "$APP_DIR/Contents/Resources/scripts/"

# Make bundled Python executable
chmod +x "$APP_DIR/Contents/Resources/python/bin/python3"

echo "✅ Build complete: build/meetingscribe"
echo "✅ App bundle ready: $APP_DIR"

# Code signing
# Auto-detect Apple Developer certificate if SIGNING_IDENTITY not set
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "No SIGNING_IDENTITY set, checking for Apple Developer certificate..."
    
    # Look for Apple Development certificate
    DEV_CERT=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n1 | awk '{print $2}')
    
    if [ -n "$DEV_CERT" ]; then
        SIGNING_IDENTITY="$DEV_CERT"
        echo "✅ Found Apple Developer certificate: $DEV_CERT"
        echo "   Using this for stable TCC identity across builds"
    else
        echo "⚠️  WARNING: No Apple Developer certificate found"
        echo "   TCC permissions will reset on each build with ad-hoc signing"
        echo ""
        echo "   To fix this:"
        echo "   1. Get a free Apple Developer certificate (no $99 membership needed)"
        echo "   2. See DISTRIBUTION.md for setup instructions"
        echo "   3. Or set SIGNING_IDENTITY environment variable"
        echo ""
        echo "   Continuing with ad-hoc signing..."
    fi
fi

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
