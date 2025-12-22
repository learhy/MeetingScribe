#!/bin/bash

# First-run installer for MeetingScribe
# This script runs automatically when the app is launched for the first time
# It handles the complete installation: permissions, LaunchAgent, CLI tools, etc.

set -e
set -o pipefail  # Ensure piped commands propagate failures

BUNDLE_ID="com.meetingscribe.daemon"
APP_PATH="$1"  # Passed by the main binary
NO_DIALOGS="${2:-}"  # Optional --no-dialogs flag
INSTALL_MARKER="$HOME/.meetingscribe/.installed"

# Function to log messages
log() {
    echo "[Installer] $1"
    logger -t "MeetingScribe" "$1"
}

# Function to show native dialog
show_dialog() {
    if [ "$NO_DIALOGS" != "--no-dialogs" ]; then
        osascript -e "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"MeetingScribe Setup\" with icon note"
    fi
}

# Function to show dialog with Yes/No options
show_confirm_dialog() {
    if [ "$NO_DIALOGS" = "--no-dialogs" ]; then
        return 0  # Auto-accept in no-dialogs mode
    fi
    osascript -e "display dialog \"$1\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" with title \"MeetingScribe Setup\" with icon note" >/dev/null 2>&1
    return $?
}

# Check if already installed
if [ -f "$INSTALL_MARKER" ]; then
    INSTALLED_PATH=$(cat "$INSTALL_MARKER")
    
    # Check if app moved since installation
    if [ "$APP_PATH" != "$INSTALLED_PATH" ]; then
        log "App location changed from $INSTALLED_PATH to $APP_PATH"
        log "Updating installation..."
        
        # Show dialog about reinstallation
        show_dialog "MeetingScribe has moved to a new location.\\n\\nReinstalling from:\\n$APP_PATH"
    else
        # Already installed at correct location
        exit 0
    fi
else
    log "First run detected"
fi

# Determine if app is in /Applications or ~/Applications
EXPECTED_LOCATION=""
CURRENT_LOCATION=""

if [[ "$APP_PATH" == /Applications/* ]]; then
    EXPECTED_LOCATION="/Applications/MeetingScribe.app"
    CURRENT_LOCATION="system"
elif [[ "$APP_PATH" == $HOME/Applications/* ]]; then
    EXPECTED_LOCATION="$HOME/Applications/MeetingScribe.app"
    CURRENT_LOCATION="user"
else
    # App is running from unexpected location (e.g., Downloads, DMG, Desktop)
    log "App is running from unexpected location: $APP_PATH"
    
    DIALOG_MSG="MeetingScribe should be installed in the Applications folder.\\n\\nCurrent location:\\n$APP_PATH\\n\\nPlease drag MeetingScribe.app to your Applications folder and run it from there.\\n\\nWould you like to install to /Applications now?"
    
    if show_confirm_dialog "$DIALOG_MSG"; then
        # User wants to install
        EXPECTED_LOCATION="/Applications/MeetingScribe.app"
        CURRENT_LOCATION="system"
        
        # Copy app to /Applications
        log "Copying app to $EXPECTED_LOCATION..."
        
        # Check if already exists
        if [ -d "$EXPECTED_LOCATION" ]; then
            log "Removing existing installation at $EXPECTED_LOCATION"
            if ! sudo rm -rf "$EXPECTED_LOCATION"; then
                show_dialog "Failed to remove existing installation. Please manually remove MeetingScribe from Applications and try again."
                exit 1
            fi
        fi
        
        if ! sudo cp -R "$APP_PATH" "$EXPECTED_LOCATION"; then
            show_dialog "Failed to copy to Applications folder. Please manually drag MeetingScribe.app to Applications."
            exit 1
        fi
        
        # Update APP_PATH to new location
        APP_PATH="$EXPECTED_LOCATION"
        
        show_dialog "MeetingScribe has been installed to Applications.\\n\\nPlease launch it from Applications (not from the original location)."
        
        # Write marker before exiting (user will launch from new location)
        mkdir -p "$(dirname "$INSTALL_MARKER")"
        echo "$EXPECTED_LOCATION" > "$INSTALL_MARKER"
        
        # Exit - user should launch from new location
        exit 0
    else
        # User cancelled
        log "User cancelled installation"
        exit 1
    fi
fi

# Welcome message shown by Swift, skip bash dialog

#
# Step 1: Clear previous permissions and installations
#
log "Step 1: Clearing previous installation..."

# Unload any existing LaunchAgent
PLIST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"
if [ -f "$PLIST" ]; then
    log "Removing existing LaunchAgent..."
    DOMAIN="gui/$(id -u)"
    launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
fi

# Remove existing CLI tool (only if writable)
if [ -f "/usr/local/bin/meetingscribe-ctl" ] && [ -w "/usr/local/bin/meetingscribe-ctl" ]; then
    log "Removing existing CLI tool..."
    rm -f /usr/local/bin/meetingscribe-ctl
fi

# Reset TCC permissions
log "Resetting permissions..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || log "Could not reset TCC permissions (may be first install)"

# Clear preferences
defaults delete "$BUNDLE_ID" 2>/dev/null || true

#
# Step 2: Create necessary directories
#
log "Step 2: Creating directories..."

mkdir -p "$HOME/.meetingscribe"
mkdir -p "$HOME/.meetingscribe/templates"
mkdir -p "$HOME/.meetingscribe/cache/models"
mkdir -p "$HOME/Documents/MeetingScribe"
mkdir -p "$HOME/Library/Logs/MeetingScribe"

#
# Step 3: Install LaunchAgent
#
log "Step 3: Installing LaunchAgent..."

# Create LaunchAgent plist
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.meetingscribe.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH/Contents/MacOS/meetingscribe</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/MeetingScribe/stderr.log</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/MeetingScribe/stdout.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST"

# Verify plist was created successfully
if [ ! -f "$PLIST" ]; then
    log "ERROR: Failed to create plist file at $PLIST"
    exit 1
fi

log "LaunchAgent plist created at $PLIST"

#
# Step 4: Install CLI tools
#
log "Step 4: Installing CLI tools..."

# Install meetingscribe-ctl to /usr/local/bin
CLI_SOURCE="$APP_PATH/Contents/Resources/scripts/meetingscribe-ctl.sh"
CLI_DEST="/usr/local/bin/meetingscribe-ctl"

if [ -f "$CLI_SOURCE" ]; then
    # Try to install CLI tool with elevated privileges via AppleScript
    # Use a more descriptive prompt
    log "Installing CLI tool from $CLI_SOURCE to $CLI_DEST"
    
    osascript <<EOF 2>/dev/null
do shell script "mkdir -p /usr/local/bin && cp '$CLI_SOURCE' '$CLI_DEST' && chmod +x '$CLI_DEST'" with administrator privileges with prompt "MeetingScribe needs to install command-line tools to /usr/local/bin. Enter your password to continue:"
EOF
    if [ $? -eq 0 ]; then
        log "CLI tool installed to $CLI_DEST"
    else
        log "User skipped CLI tool installation (requires password)"
    fi
else
    log "Warning: CLI tool not found at $CLI_SOURCE"
fi

#
# Step 5: Create default configuration if needed
#
log "Step 5: Creating default configuration..."

CONFIG_FILE="$HOME/.meetingscribe/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
  "output_dir": "~/Documents/MeetingScribe",
  "template": "~/.meetingscribe/templates/default.md",
  "audio_format": "wav",
  "sample_rate": 16000,
  "diarization": {
    "enabled": true,
    "min_speakers": 1,
    "max_speakers": 10
  },
  "model": {
    "size": "base",
    "language": "en",
    "device": "cpu"
  }
}
EOF
    log "Default config created at $CONFIG_FILE"
fi

# Create default template if needed
TEMPLATE_FILE="$HOME/.meetingscribe/templates/default.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
    cat > "$TEMPLATE_FILE" << 'EOF'
# {title}

**Date:** {date}
**Time:** {time}
**Duration:** {duration}

## Summary
{summary}

## Notes
{notes}

## Full Transcript
{transcript}

---
*Generated automatically by MeetingScribe*
*Audio: {audio_file}*
EOF
    log "Default template created at $TEMPLATE_FILE"
fi

#
# Step 6: Set up permissions
#
log "Step 6: Setting up permissions..."

PERMISSIONS_MSG="MeetingScribe needs permissions to work:\\n\\n• Screen Recording: Required to capture audio\\n• Microphone: Optional for voice recording\\n\\nYou will see permission dialogs next.\\n\\nClick Continue to grant permissions."

show_dialog "$PERMISSIONS_MSG"

#
# Step 7: Start the daemon
#
log "Step 7: Starting MeetingScribe daemon..."

# Bootstrap the LaunchAgent
DOMAIN="gui/$(id -u)"
log "Bootstrapping LaunchAgent to domain $DOMAIN"

if launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1 | tee >(logger -t "MeetingScribe") ; then
    log "LaunchAgent bootstrapped successfully"
else
    BOOTSTRAP_EXIT=$?
    log "WARNING: launchctl bootstrap failed with exit code $BOOTSTRAP_EXIT (may already be loaded)"
    # Try to kickstart it anyway in case it's already loaded
fi

# Give it a moment to start
sleep 2

# Kickstart to ensure it's running
log "Kickstarting daemon"
if launchctl kickstart -k "$DOMAIN/com.meetingscribe.daemon" 2>&1 | tee >(logger -t "MeetingScribe") ; then
    log "Daemon kickstarted successfully"
else
    log "WARNING: launchctl kickstart returned error (daemon may still be starting)"
fi

log "Daemon started"

#
# Step 8: Verify installation and write marker
#
log "Verifying installation..."

# Verify critical files exist
if [ ! -f "$PLIST" ]; then
    log "ERROR: Installation verification failed - plist not found at $PLIST"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Installation verification failed - config not found at $CONFIG_FILE"
    exit 1
fi

log "Installation verification passed"
echo "$APP_PATH" > "$INSTALL_MARKER"
log "Installation marker written to $INSTALL_MARKER"

#
# Step 9: Installation complete
#
log "Installation complete!"
# Completion dialog shown by Swift
exit 0
