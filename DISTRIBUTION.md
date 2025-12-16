# Distribution Guide

This guide explains how to build, package, and distribute MeetingScribe.

## For End Users

### Installation

#### Option 1: From DMG (Recommended)
1. Download `MeetingScribe-X.X.dmg`
2. Open the DMG file
3. Drag `MeetingScribe.app` to the `Applications` folder
4. Eject the DMG
5. Open `MeetingScribe` from Applications
6. Grant permissions when prompted:
   - Screen Recording (required)
   - Microphone (optional, for local audio track)

#### Option 2: From ZIP
1. Download and extract `MeetingScribe-X.X.zip`
2. Move `MeetingScribe.app` to `/Applications`
3. Open `MeetingScribe` from Applications
4. Grant permissions when prompted

### First Launch

On first launch, macOS may show a security warning. To allow the app:

1. Go to **System Settings > Privacy & Security**
2. Scroll down to find the security message
3. Click **Open Anyway**

Or right-click the app and select **Open**, then confirm.

### Controlling the Daemon

After installation, use these commands in Terminal:

```bash
meetingscribe-ctl status    # Check if daemon is running
meetingscribe-ctl stop      # Stop the daemon
meetingscribe-ctl start     # Start the daemon
meetingscribe-ctl restart   # Restart the daemon
meetingscribe-ctl logs      # View daemon logs
```

### Configuration

Configuration file: `~/.meetingscribe/config.json`

Edit this file to customize:
- Transcription provider (OpenAI Whisper API or local Whisper)
- Notes generation LLM (OpenAI, Anthropic, or Ollama)
- Audio settings
- Notification preferences

### Uninstallation

```bash
# Stop and remove the daemon
meetingscribe-ctl stop
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist
rm ~/Library/LaunchAgents/com.meetingscribe.daemon.plist

# Remove the app
rm -rf /Applications/MeetingScribe.app
sudo rm /usr/local/bin/meetingscribe-ctl

# Optional: Remove data
rm -rf ~/.meetingscribe              # Config and templates
rm -rf ~/Documents/MeetingScribe     # Recordings and notes
rm -rf ~/Library/Logs/MeetingScribe  # Logs
```

---

## For Developers

### Building from Source

#### Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools: `xcode-select --install`
- Swift 5.9+

#### Build Steps

```bash
# Clone the repository
git clone https://github.com/your-repo/meeting-scribe.git
cd meeting-scribe

# Build the app
./scripts/build-and-sign.sh

# Install locally for development
./scripts/install.sh

# Or install system-wide
./scripts/install.sh system
```

### Code Signing

**IMPORTANT for Development**: TCC (macOS privacy permissions) identifies apps by their code signature. Ad-hoc signing changes the signature on every build, causing TCC to treat each build as a new app and reset permissions. Using a stable signing identity (Apple Developer certificate) solves this.

#### Why You Need a Signing Certificate

<cite index="11-1,11-2,12-1,12-2">According to Apple engineers, TCC requires a stable signing identity to persist permissions across builds. Ad-hoc signing causes "TCC thrash" where permissions reset every time you rebuild.</cite>

**The Problem:**
- Each build with ad-hoc signing creates a new code signature
- TCC sees this as a "new app" and requires re-granting permissions
- Old permission entries become orphaned in TCC database
- You must manually go to System Settings and enable permissions after every build

**The Solution:**
- Use an Apple Developer certificate (free with Apple ID - no $99/year membership needed)
- Certificate provides stable identity across builds
- TCC remembers permissions permanently

#### Setup Code Signing

1. **Get an Apple Developer Certificate (FREE)**
   
   **Option A: Apple Development Certificate (Free - Recommended for Development)**
   - Sign in to Xcode with your Apple ID (Xcode > Settings > Accounts)
   - Click "Manage Certificates..."
   - Click "+" and select "Apple Development"
   - Certificate is automatically installed in your Keychain
   - No paid Apple Developer Program membership required!
   
   **Option B: Developer ID Certificate (For Distribution)**
   - Requires Apple Developer Program membership ($99/year)
   - Generate a Developer ID Application certificate at developer.apple.com
   - Download and install the certificate in your Keychain

2. **Find Your Signing Identity**
   ```bash
   security find-identity -v -p codesigning
   ```
   
   Look for:
   - "Apple Development: Your Name (XXXXXXXXXX)" (free certificate)
   - or "Developer ID Application: Your Name (XXXXXXXXXX)" (paid certificate)

3. **Build with Signing**
   
   **Automatic (Recommended):**
   ```bash
   ./scripts/build-and-sign.sh
   ```
   The script will auto-detect your Apple Development certificate!
   
   **Manual:**
   ```bash
   export SIGNING_IDENTITY="Apple Development: Your Name"
   ./scripts/build-and-sign.sh
   ```
   
   Or for distribution:
   ```bash
   export SIGNING_IDENTITY="Developer ID Application: Your Name"
   ./scripts/build-and-sign.sh
   ```

### Creating Distribution Packages

```bash
# Build and sign first
export SIGNING_IDENTITY="Developer ID Application: Your Name"
./scripts/build-and-sign.sh

# Create distribution packages (DMG and ZIP)
./scripts/package-for-distribution.sh 1.0

# Output will be in dist/ directory:
#   - MeetingScribe-1.0.dmg
#   - MeetingScribe-1.0.zip
```

### Notarization (Required for Public Distribution)

Apple requires apps distributed outside the Mac App Store to be notarized.

#### Setup Notarization

1. **Create an App-Specific Password**
   - Go to appleid.apple.com
   - Generate an app-specific password
   - Save it securely

2. **Store Credentials in Keychain**
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id "your@email.com" \
       --team-id "XXXXXXXXXX" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```

3. **Notarize the DMG**
   ```bash
   # Submit for notarization
   xcrun notarytool submit dist/MeetingScribe-1.0.dmg \
       --keychain-profile "AC_PASSWORD" \
       --wait
   
   # Staple the notarization ticket
   xcrun stapler staple dist/MeetingScribe-1.0.dmg
   
   # Verify
   xcrun stapler validate dist/MeetingScribe-1.0.dmg
   ```

### Development Workflow

```bash
# Make code changes
vim src/main.swift

# Rebuild
./scripts/build-and-sign.sh

# Restart daemon to test
meetingscribe-ctl restart

# View logs
meetingscribe-ctl logs
```

### Testing

```bash
# Run unit tests
swift test

# Manual testing
./build/meetingscribe  # Run directly without LaunchAgent

# Test installation
./scripts/uninstall.sh
./scripts/build-and-sign.sh
./scripts/install.sh
```

### Release Checklist

- [ ] Update version in `Info.plist`
- [ ] Update version in `Package.swift` if needed
- [ ] Update `CHANGELOG.md` (if exists)
- [ ] Build with code signing
- [ ] Test app bundle functionality
- [ ] Create distribution packages
- [ ] Notarize DMG
- [ ] Test installation on clean system
- [ ] Create GitHub release with DMG and ZIP
- [ ] Update README with new version

### Project Structure

```
meeting-scribe/
├── src/                    # Source code
│   ├── main.swift         # Entry point
│   ├── core/              # Core functionality
│   ├── ui/                # Menu bar UI
│   ├── config/            # Configuration management
│   └── plugins/           # Notes backend plugins
├── scripts/               # Build and installation scripts
│   ├── build-and-sign.sh          # Build and sign app
│   ├── install.sh                 # Install app and daemon
│   ├── uninstall.sh               # Remove app and daemon
│   ├── meetingscribe-ctl.sh       # Daemon control CLI
│   └── package-for-distribution.sh # Create DMG/ZIP
├── resources/             # Resources
│   └── com.meetingscribe.daemon.plist  # LaunchAgent config
├── tests/                 # Unit tests
├── build/                 # Build output (gitignored)
├── dist/                  # Distribution packages (gitignored)
├── Info.plist            # App bundle metadata
├── Package.swift         # Swift package definition
└── README.md             # User documentation
```

### Troubleshooting

#### App Won't Open
- Check code signature: `codesign --verify --verbose build/MeetingScribe.app`
- Check permissions: System Settings > Privacy & Security

#### Daemon Won't Start
- Check logs: `meetingscribe-ctl logs`
- Verify plist: `plutil ~/Library/LaunchAgents/com.meetingscribe.daemon.plist`
- Check daemon status: `launchctl list | grep meetingscribe`

#### Build Failures
- Clean build: `swift package clean`
- Reset build folder: `rm -rf .build build`
- Update tools: `xcode-select --install`

### Contributing

See the main README.md for contribution guidelines.
