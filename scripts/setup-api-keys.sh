#!/bin/bash

# MeetingScribe API Key Setup Script
# This script helps you store API keys securely in macOS Keychain

set -e

echo "================================================"
echo "MeetingScribe API Key Setup"
echo "================================================"
echo ""

# Function to add a key to keychain
add_key() {
    local service_name=$1
    local prompt_text=$2
    
    echo "$prompt_text"
    echo -n "Enter API key (or press Enter to skip): "
    read -s api_key
    echo ""
    
    if [ -z "$api_key" ]; then
        echo "⏭️  Skipped"
        echo ""
        return
    fi
    
    # Check if key already exists
    if security find-generic-password -a "$service_name" -s "com.meetingscribe" >/dev/null 2>&1; then
        echo "⚠️  Key already exists. Updating..."
        security delete-generic-password -a "$service_name" -s "com.meetingscribe"
    fi
    
    # Add new key
    security add-generic-password -a "$service_name" -s "com.meetingscribe" -w "$api_key"
    echo "✅ Key stored in Keychain"
    echo ""
}

# Function to verify a key
verify_key() {
    local service_name=$1
    local key_name=$2
    
    if security find-generic-password -a "$service_name" -s "com.meetingscribe" -w >/dev/null 2>&1; then
        echo "✅ $key_name is configured"
        return 0
    else
        echo "❌ $key_name is NOT configured"
        return 1
    fi
}

echo "This script will securely store your API key in macOS Keychain."
echo "Your key will never be displayed on screen or stored in plain text."
echo ""
echo "You'll need:"
echo "  - Anthropic API key (for Claude notes generation)"
echo ""
echo "Note: Transcription uses local whisper.cpp (no OpenAI key needed)."
echo ""
echo "Press Enter to continue, or Ctrl+C to cancel..."
read

echo ""
echo "-------------------------------------------"
echo "Anthropic API Key Setup"
echo "-------------------------------------------"
add_key "MeetingScribe-Anthropic-Key" "Enter your Anthropic API key (starts with sk-ant-...):"

echo "-------------------------------------------"
echo "Configuration Complete!"
echo "-------------------------------------------"
echo ""
echo "Verifying stored keys..."
echo ""

anthropic_ok=false

verify_key "MeetingScribe-Anthropic-Key" "Anthropic API Key" && anthropic_ok=true

echo ""

if $anthropic_ok; then
    echo "✅ API key configured successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify whisper.cpp is available:"
    echo "     ls -lh \"~/My Drive/software_projects/whisper.cpp/main\""
    echo "  2. Build the project: swift build"
    echo "  3. Run the app: ./.build/debug/meetingscribe"
    echo "  4. Grant Screen Recording permission when prompted"
    echo "  5. Test manual recording (see TESTING.md)"
    exit 0
else
    echo "⚠️  No API key configured."
    echo ""
    echo "You need the Anthropic API key for notes generation."
    echo "(Transcription uses local whisper.cpp - no API key needed)"
    echo ""
    echo "Run this script again to add your key."
    exit 1
fi
