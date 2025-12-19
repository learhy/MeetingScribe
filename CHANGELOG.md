# Changelog

## [Unreleased] - 2024-12-18

### Added
- Professional app icon (pen and paper design using SF Symbols)
- Automatic config file monitoring - detects when API keys are added and auto-restarts
- First-run installer with improved UX flow
- Config error state with orange warning icon when API keys missing
- Interactive DMG with proper styling and visible Applications symlink

### Changed
- **BREAKING**: API keys now stored in `~/.meetingscribe/config.json` instead of macOS Keychain
- Improved installation flow to prevent duplicate app instances
- Installer now properly installs `meetingscribe-ctl` CLI tool
- DMG background changed from black to light gray for better visibility
- Completion dialog now shows after permissions are granted (not before)
- Warning messages more prominent with emoji and better formatting

### Fixed
- App icon now displays correctly in DMG and Applications folder
- Applications symlink in DMG now visible with proper folder icon
- Credential prompts now explain why password is needed
- Welcome dialog no longer appears twice
- CLI tool installation works correctly with installer flow
- Menu bar icon automatically updates when config file is modified

### Improved
- Installation error messages are more descriptive
- Password prompts clearly explain what's being installed
- Config folder automatically opens after installation
- Menu bar shows helpful error states with clickable actions

## Previous Versions
See git history for earlier changes.
