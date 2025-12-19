# First-Run Installer System

## Overview

The first-run installer solves the problem of users dragging the app from a DMG directly to Applications (or anywhere else) and running it without a proper installation process. The installer automatically runs on first launch and handles all setup steps.

## How It Works

### 1. Detection

On every launch, `FirstRunInstaller.needsInstallation()` checks:
- Does `~/.meetingscribe/.installed` exist?
- If yes, has the app location changed since installation?
- If no, this is the first run

### 2. Execution Flow

When installation is needed, the app:

1. **Pauses startup** - Shows no UI until installation completes
2. **Runs installer script** - Executes `first-run-installer.sh` with app bundle path
3. **Handles result** - Either continues or quits based on installer exit code

### 3. Installer Steps

The `first-run-installer.sh` script handles everything:

#### Step 1: Location Check
- Detects if app is in /Applications or ~/Applications
- If running from elsewhere (DMG, Downloads, Desktop):
  - Shows dialog offering to install to /Applications
  - If accepted: copies app and tells user to launch from new location
  - If declined: exits (user can move manually)

#### Step 2: Clear Previous Installation
- Unloads existing LaunchAgent (if any)
- Removes old CLI tool
- Resets TCC permissions
- Clears app preferences

#### Step 3: Create Directory Structure
```
~/.meetingscribe/
  .installed              # Marker file with app path
  templates/
    default.md            # Default transcript template
  cache/
    models/               # ML model cache
  config.json             # App configuration

~/Documents/MeetingScribe/  # Output directory
~/Library/Logs/MeetingScribe/  # Log files
```

#### Step 4: Install LaunchAgent
- Creates `~/Library/LaunchAgents/com.meetingscribe.daemon.plist`
- Configures it to point to the current app location
- Ensures daemon starts on login

#### Step 5: Install CLI Tools
- Copies `meetingscribe-ctl` to `/usr/local/bin/` (requires sudo)
- Makes it executable
- Provides system-wide CLI access

#### Step 6: Create Default Configuration
- Creates `~/.meetingscribe/config.json` if needed
- Creates default transcript template
- All settings are user-modifiable later

#### Step 7: Request Permissions
- Shows dialog explaining required permissions
- User clicks through to grant Screen Recording
- Optionally grants Microphone access

#### Step 8: Start Daemon
- Bootstraps the LaunchAgent
- Kickstarts the daemon to run immediately
- App appears in menu bar

#### Step 9: Write Installation Marker
- Writes app path to `~/.meetingscribe/.installed`
- Prevents installer from running again (unless app moves)

#### Step 10: Show Completion
- Shows success dialog with CLI commands
- Lists configuration file locations
- User can now use the app

## User Dialogs

The installer uses native macOS dialogs via `osascript`:

### Welcome Dialog
```
Welcome to MeetingScribe!

This wizard will:
1. Reset any previous permissions
2. Set up the background daemon
3. Install command-line tools
4. Configure required permissions

Click Continue to begin setup.
```

### Location Warning (if not in Applications)
```
MeetingScribe should be installed in the Applications folder.

Current location:
/Users/dan/Downloads/MeetingScribe.app

Please drag MeetingScribe.app to your Applications folder
and run it from there.

Would you like to install to /Applications now?
```

### Permissions Prompt
```
MeetingScribe needs permissions to work:

• Screen Recording: Required to capture audio
• Microphone: Optional for voice recording

You will see permission dialogs next.

Click Continue to grant permissions.
```

### Completion Dialog
```
Installation complete!

MeetingScribe is now running in the background.
Look for the microphone icon in your menu bar.

You can control MeetingScribe with:
  meetingscribe-ctl status
  meetingscribe-ctl stop
  meetingscribe-ctl start
  meetingscribe-ctl logs

Configuration: ~/.meetingscribe/config.json
Recordings: ~/Documents/MeetingScribe
```

## Build Integration

The installer is embedded into the app bundle during build:

### 1. Build Script (`build-and-sign.sh`)
```bash
# Embed first-run installer and all supporting scripts
echo "Embedding first-run installer..."
./scripts/embed-installer.sh "$APP_DIR"
```

### 2. Embed Script (`embed-installer.sh`)
Copies to `Contents/Resources/scripts/`:
- `first-run-installer.sh` - Main installer
- `meetingscribe-ctl.sh` - CLI tool
- `uninstall.sh` - Uninstaller
- `reset-permissions.sh` - Permission reset utility
- `diarize_audio_fast.py` - Diarization script

### 3. App Bundle Structure
```
MeetingScribe.app/
  Contents/
    MacOS/
      meetingscribe           # Main binary
    Resources/
      python/                 # Bundled Python environment
      scripts/
        first-run-installer.sh
        meetingscribe-ctl.sh
        uninstall.sh
        reset-permissions.sh
        diarize_audio_fast.py
    Info.plist
```

## Code Integration

### Swift Side (`FirstRunInstaller.swift`)

```swift
// In main.swift, before any other initialization:
if FirstRunInstaller.needsInstallation() {
    let success = FirstRunInstaller.runInstaller()
    if !success {
        NSApp.terminate(nil)
        return
    }
}
```

The Swift wrapper:
1. Checks if installation is needed
2. Finds the embedded installer script
3. Runs it with the current bundle path
4. Captures and logs output
5. Handles success/failure/cancellation

### Bash Side (`first-run-installer.sh`)

The bash script:
1. Takes bundle path as argument
2. Uses `osascript` for native dialogs
3. Uses `logger` for system logging
4. Handles all sudo operations (via AppleScript auth)
5. Returns exit code 0 for success, 1 for cancellation/failure

## Handling App Relocation

If the user moves the app after installation:

1. `FirstRunInstaller.needsInstallation()` returns true
2. Installer detects path change
3. Shows "App has moved" dialog
4. Updates LaunchAgent plist with new path
5. Reinstalls CLI tool (may point to old location)
6. Updates installation marker

## Uninstallation

The embedded `uninstall.sh` script (run separately):

```bash
/Applications/MeetingScribe.app/Contents/Resources/scripts/uninstall.sh
```

Removes:
- LaunchAgent plist
- CLI tool
- App bundle(s)
- TCC permissions
- App preferences

Preserves (user can manually delete):
- `~/.meetingscribe/` - Configuration and cache
- `~/Documents/MeetingScribe/` - Recordings
- `~/Library/Logs/MeetingScribe/` - Logs

## Security Considerations

### Why sudo is needed
- Installing CLI tool to `/usr/local/bin/` requires root
- AppleScript's "with administrator privileges" prompts for password
- User explicitly authorizes each privileged operation

### Why TCC reset is safe
- Only resets permissions for this app's bundle ID
- User must re-grant permissions (can't auto-grant)
- Follows Apple's security model

### Code signing implications
- Installer runs after code signing
- Embedded scripts are part of signed bundle
- Moving app invalidates signature (expected for dev builds)
- Production: notarize after packaging

## Testing the Installer

### Test Scenario 1: Fresh Install
```bash
# Build and package
./scripts/build-and-sign.sh
./scripts/package-for-distribution.sh

# Mount DMG
open dist/MeetingScribe-1.0.dmg

# Drag to Applications and launch
# Expected: Installer runs, shows all dialogs, completes successfully
```

### Test Scenario 2: Running from Wrong Location
```bash
# Copy app to Downloads
cp -R /Applications/MeetingScribe.app ~/Downloads/

# Launch from Downloads
open ~/Downloads/MeetingScribe.app

# Expected: Dialog offers to install to /Applications
```

### Test Scenario 3: App Relocation
```bash
# Install normally first
# Then move app
mv /Applications/MeetingScribe.app ~/Applications/

# Launch from new location
open ~/Applications/MeetingScribe.app

# Expected: Detects move, updates installation
```

### Test Scenario 4: Reinstallation
```bash
# Uninstall first
/Applications/MeetingScribe.app/Contents/Resources/scripts/uninstall.sh

# Delete marker to force fresh install
rm -rf ~/.meetingscribe

# Launch app
open /Applications/MeetingScribe.app

# Expected: Full installation wizard runs again
```

## Troubleshooting

### Installer hangs
- Check Console.app for logs tagged "MeetingScribe"
- Check `~/Library/Logs/MeetingScribe/stderr.log`
- Kill with: `pkill -9 meetingscribe`

### CLI tool not installed
- Check if `/usr/local/bin/meetingscribe-ctl` exists
- Verify permissions: `ls -la /usr/local/bin/meetingscribe-ctl`
- Manually install: `sudo cp "$APP/Contents/Resources/scripts/meetingscribe-ctl.sh" /usr/local/bin/meetingscribe-ctl`

### LaunchAgent not starting
- Check if loaded: `launchctl list | grep meetingscribe`
- Check plist: `cat ~/Library/LaunchAgents/com.meetingscribe.daemon.plist`
- Manually load: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist`

### Permissions not working
- Reset: `tccutil reset All com.meetingscribe.daemon`
- Check System Settings > Privacy & Security > Screen Recording
- Try: `/Applications/MeetingScribe.app/Contents/Resources/scripts/reset-permissions.sh`

## Future Enhancements

### Potential Improvements
1. **Progress indicator** - Show progress bar during long operations
2. **Skip CLI tool** - Allow users to skip CLI installation
3. **Custom install location** - Support installing anywhere
4. **Rollback on failure** - Restore previous state if installation fails
5. **Silent mode** - Environment variable to skip dialogs (for CI/testing)
6. **Update in place** - Detect upgrades vs fresh installs

### Not Recommended
- Auto-granting permissions (not possible on macOS)
- Installing without user interaction (violates macOS guidelines)
- Modifying system directories outside /usr/local/bin (security risk)
