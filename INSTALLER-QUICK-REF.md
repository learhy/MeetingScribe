# First-Run Installer - Quick Reference

## What Problem Does This Solve?

**Problem**: Users drag the app from the DMG to Applications and run it directly. This bypasses the installation process, so the LaunchAgent, CLI tools, and permissions aren't set up properly.

**Solution**: The app automatically runs a first-run installer on launch that handles all setup, regardless of where the app is run from.

## Files Created/Modified

### New Files
- `scripts/first-run-installer.sh` - Main installer script (bash)
- `scripts/embed-installer.sh` - Embeds installer into app bundle
- `src/utils/FirstRunInstaller.swift` - Swift wrapper for installer
- `INSTALLER.md` - Full documentation

### Modified Files
- `src/main.swift` - Calls installer before app starts
- `scripts/build-and-sign.sh` - Embeds installer during build
- `scripts/package-for-distribution.sh` - Updated README text

## How It Works (High Level)

```
User launches app from any location
         ↓
FirstRunInstaller.needsInstallation() checks if setup needed
         ↓
    ┌────┴────┐
    │         │
  YES        NO
    │         └─→ Continue normal startup
    │
    ↓
Run first-run-installer.sh
    ↓
    ┌─────────────────────────────┐
    │ 1. Check/fix app location   │
    │ 2. Clear old installation   │
    │ 3. Create directories       │
    │ 4. Install LaunchAgent      │
    │ 5. Install CLI tools        │
    │ 6. Create config files      │
    │ 7. Request permissions      │
    │ 8. Start daemon             │
    │ 9. Write marker             │
    │ 10. Show success            │
    └─────────────────────────────┘
         ↓
    Success?
    ┌────┴────┐
    │         │
   YES        NO
    │         └─→ Show error, quit
    │
    ↓
Continue normal app startup
```

## Installation Steps (User Experience)

1. **User drags app from DMG to Applications**
2. **User double-clicks app** → Welcome dialog appears
3. **User clicks Continue** → Installer runs (30-60 seconds)
4. **Permission dialogs appear** → User grants Screen Recording
5. **Completion dialog** → App is now running in menu bar
6. **Done** → Everything is set up

## Build Process

```bash
# Build creates app bundle
swift build -c release

# Embed installer into bundle
./scripts/embed-installer.sh build/MeetingScribe.app

# Sign the bundle (includes embedded installer)
codesign --sign "$IDENTITY" build/MeetingScribe.app

# Package for distribution
./scripts/package-for-distribution.sh
```

## Testing Checklist

- [ ] Fresh install from DMG
- [ ] Running from Downloads (should offer to move)
- [ ] Running from Desktop (should offer to move)
- [ ] App relocation after install (should update)
- [ ] Canceling installer (app should quit)
- [ ] Reinstall after uninstall
- [ ] CLI tool works after install
- [ ] LaunchAgent starts on login
- [ ] Permissions are granted correctly

## Key Decisions

### Why bash script instead of pure Swift?
- Native dialogs via `osascript`
- Easier sudo handling with AppleScript auth
- Better logging integration (`logger`)
- Familiar shell operations

### Why synchronous install on first run?
- Prevents race conditions
- Ensures complete setup before app starts
- Clear user experience (wizard → completion)

### Why installation marker?
- Prevents installer from running every time
- Tracks app location for relocation detection
- Simple file-based state

### Why embedded scripts?
- Self-contained distribution
- No external dependencies
- Scripts are code-signed with app
- Easy to access from app bundle

## Common Issues & Solutions

### Issue: Installer doesn't run
**Check**: Is `FirstRunInstaller.swift` included in build?
**Fix**: Add to Package.swift or Xcode target

### Issue: Script not found
**Check**: Was `embed-installer.sh` run during build?
**Fix**: Verify it's in `build-and-sign.sh`

### Issue: Permission denied on script
**Check**: Are scripts executable?
**Fix**: `chmod +x scripts/*.sh`

### Issue: CLI tool not installed
**Check**: Did user enter sudo password?
**Fix**: Installer shows sudo prompt, user must authorize

### Issue: App won't start after install
**Check**: LaunchAgent loaded?
**Fix**: `launchctl list | grep meetingscribe`

## File Locations (After Install)

```
# Installation marker
~/.meetingscribe/.installed

# Configuration
~/.meetingscribe/config.json
~/.meetingscribe/templates/default.md

# LaunchAgent
~/Library/LaunchAgents/com.meetingscribe.daemon.plist

# CLI tool
/usr/local/bin/meetingscribe-ctl

# Logs
~/Library/Logs/MeetingScribe/stdout.log
~/Library/Logs/MeetingScribe/stderr.log

# App bundle
/Applications/MeetingScribe.app
  Contents/Resources/scripts/
    first-run-installer.sh
    meetingscribe-ctl.sh
    uninstall.sh
    reset-permissions.sh
```

## Manual Installation (Fallback)

If the automatic installer fails, users can run:

```bash
cd /Applications/MeetingScribe.app/Contents/Resources/scripts
./first-run-installer.sh /Applications/MeetingScribe.app
```

Or use the old install script:

```bash
cd /path/to/meeting-scribe
./scripts/install.sh
```

## Uninstallation

```bash
/Applications/MeetingScribe.app/Contents/Resources/scripts/uninstall.sh
```

Or manually:

```bash
# Stop and remove LaunchAgent
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist
rm ~/Library/LaunchAgents/com.meetingscribe.daemon.plist

# Remove CLI tool
sudo rm /usr/local/bin/meetingscribe-ctl

# Remove app
rm -rf /Applications/MeetingScribe.app

# Reset permissions
tccutil reset All com.meetingscribe.daemon

# Optional: Clean user data
rm -rf ~/.meetingscribe
rm -rf ~/Documents/MeetingScribe
rm -rf ~/Library/Logs/MeetingScribe
```

## Next Steps After Implementing

1. **Test thoroughly** - All scenarios in testing checklist
2. **Update README** - Document the new installation flow
3. **Test on clean Mac** - VM or friend's computer
4. **Get user feedback** - Is the wizard clear?
5. **Consider telemetry** - Track installer success rate (optional)
