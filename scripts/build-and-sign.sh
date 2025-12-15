#!/bin/bash

set -e

echo "Building MeetingScribe..."

# Build with Swift Package Manager
swift build -c release

# Create binary directory
mkdir -p build

# Copy binary
cp .build/release/meetingscribe build/

echo "✅ Build complete: build/meetingscribe"

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
