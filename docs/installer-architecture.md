# First-Run Installer Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     User Action: Launch App                  │
│                  (from any location: DMG,                    │
│                Downloads, Desktop, Applications)             │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                      main.swift                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  func applicationDidFinishLaunching()                  │ │
│  │                                                        │ │
│  │  if FirstRunInstaller.needsInstallation() {           │ │
│  │      let success = FirstRunInstaller.runInstaller()   │ │
│  │      if !success { NSApp.terminate() }                │ │
│  │  }                                                     │ │
│  └────────────────────────────────────────────────────────┘ │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│            FirstRunInstaller.swift (Swift Layer)             │
│                                                              │
│  • needsInstallation()                                       │
│    └─→ Checks ~/.meetingscribe/.installed                   │
│    └─→ Compares app path if exists                          │
│                                                              │
│  • runInstaller()                                            │
│    └─→ Finds embedded script in app bundle                  │
│    └─→ Runs: /bin/bash first-run-installer.sh <app_path>    │
│    └─→ Captures stdout/stderr to logs                       │
│    └─→ Returns success/failure                              │
│                                                              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│       first-run-installer.sh (Bash Script Layer)             │
│                                                              │
│  Step 1: Location Check                                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Is app in /Applications or ~/Applications?           │  │
│  │ NO → Show dialog: "Move to Applications?"            │  │
│  │      YES → Copy and exit (relaunch required)         │  │
│  │      NO → Exit                                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 2: Clear Previous Installation                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • launchctl bootout (unload LaunchAgent)             │  │
│  │ • rm LaunchAgent plist                               │  │
│  │ • rm CLI tool                                         │  │
│  │ • tccutil reset (clear permissions)                  │  │
│  │ • defaults delete (clear preferences)                │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 3: Create Directories                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • ~/.meetingscribe/                                  │  │
│  │ • ~/.meetingscribe/templates/                        │  │
│  │ • ~/.meetingscribe/cache/models/                     │  │
│  │ • ~/Documents/MeetingScribe/                         │  │
│  │ • ~/Library/Logs/MeetingScribe/                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 4: Install LaunchAgent                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • Create plist with current app path                 │  │
│  │ • Save to ~/Library/LaunchAgents/                    │  │
│  │ • Set RunAtLoad=true, KeepAlive=true                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 5: Install CLI Tools                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • osascript with administrator privileges            │  │
│  │ • Copy to /usr/local/bin/meetingscribe-ctl           │  │
│  │ • chmod +x                                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 6: Create Default Config                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • ~/.meetingscribe/config.json                       │  │
│  │ • ~/.meetingscribe/templates/default.md              │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 7: Request Permissions                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • Show dialog explaining permissions                 │  │
│  │ • User will see macOS permission prompts             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 8: Start Daemon                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • launchctl bootstrap                                │  │
│  │ • launchctl kickstart -k                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 9: Write Installation Marker                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • echo $APP_PATH > ~/.meetingscribe/.installed       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Step 10: Show Completion                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • osascript dialog with success message              │  │
│  │ • Show CLI commands and config locations             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Exit Code: 0 (success) or 1 (failure/cancel)               │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              Back to FirstRunInstaller.swift                 │
│                                                              │
│  if process.terminationStatus == 0:                          │
│      logger.info("Installation successful")                 │
│      return true                                             │
│  else:                                                       │
│      logger.error("Installation failed")                    │
│      return false                                            │
└────────────────────────┬────────────────────────────────────┘
                         │
            ┌────────────┴────────────┐
            │                         │
         Success                   Failure
            │                         │
            ▼                         ▼
┌──────────────────────┐    ┌──────────────────────┐
│  Continue Normal     │    │  Show Error          │
│  App Startup         │    │  NSApp.terminate()   │
│                      │    │                      │
│  • Init menu bar     │    └──────────────────────┘
│  • Check permissions │
│  • Start service     │
└──────────────────────┘
```

## File Structure After Build

```
MeetingScribe.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── meetingscribe                    (Swift binary)
│   └── Resources/
│       ├── python/                           (Bundled Python env)
│       │   ├── bin/
│       │   │   └── python3
│       │   └── lib/
│       │       └── python3.x/
│       │           └── site-packages/
│       └── scripts/                          (Embedded scripts)
│           ├── first-run-installer.sh        ← Main installer
│           ├── meetingscribe-ctl.sh          ← CLI tool
│           ├── uninstall.sh                  ← Uninstaller
│           ├── reset-permissions.sh          ← Permission reset
│           └── diarize_audio_fast.py         ← Python script
```

## State Management

### Installation States

```
┌─────────────────────┐
│   Not Installed     │  (~/.meetingscribe/.installed does not exist)
└──────────┬──────────┘
           │ First launch
           ▼
┌─────────────────────┐
│   Installing        │  (Installer running)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Installed         │  (~/.meetingscribe/.installed exists with path)
└──────────┬──────────┘
           │
           │ App moved?
           ▼
┌─────────────────────┐
│   Needs Update      │  (Path in marker != current path)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Reinstalling      │  (Installer runs again)
└─────────────────────┘
```

## User Interaction Flow

```
┌─────────────────────────────────────────────────────────────┐
│                   User Experience Timeline                   │
└─────────────────────────────────────────────────────────────┘

[0s]   User: Double-click MeetingScribe.app
       App:  Launch starts, check installation marker

[0.5s] App:  No marker found → Run installer
       
[1s]   Dialog: "Welcome to MeetingScribe! ... Click Continue"
       User:   Clicks Continue

[2s]   Dialog: "Would you like to install to /Applications?"
              (only if running from wrong location)
       User:   Clicks Continue or Cancel

[3s]   Progress: Clearing previous installation...
       Progress: Creating directories...
       Progress: Installing LaunchAgent...

[5s]   Dialog: "Install CLI Tool?" (via AppleScript sudo prompt)
       User:   Enters password

[7s]   Progress: Installing CLI tools...
       Progress: Creating configuration...

[10s]  Dialog: "MeetingScribe needs permissions..."
       User:   Clicks OK

[12s]  System: Shows Screen Recording permission prompt
       User:   Clicks "Open System Settings" → Enable

[15s]  Progress: Starting daemon...

[17s]  Dialog: "Installation complete!"
       Shows: CLI commands, config locations
       User:   Clicks OK

[18s]  App:    Menu bar icon appears
       User:   Can now use MeetingScribe
```

## Error Handling

```
┌──────────────────────────────────────────────────────────┐
│                    Error Scenarios                        │
└──────────────────────────────────────────────────────────┘

Error: User cancels installation
├─→ Exit code: 1
├─→ Swift sees failure
├─→ Shows: "Installation cancelled" (if needed)
└─→ NSApp.terminate()

Error: User cancels sudo prompt
├─→ CLI tool not installed
├─→ Installer continues anyway
├─→ Shows warning in completion dialog
└─→ User can manually install later

Error: No disk space
├─→ mkdir or cp fails
├─→ Bash script catches error (set -e)
├─→ Exit code: 1
└─→ Swift shows error dialog

Error: LaunchAgent fails to load
├─→ launchctl returns error
├─→ Logged to stderr
├─→ Installer continues
└─→ User can manually load later

Error: App not in expected location
├─→ Offer to move to /Applications
├─→ If accepted: copy and exit
├─→ If declined: exit
└─→ User can move manually
```

## Security Model

```
┌──────────────────────────────────────────────────────────┐
│              Security & Privilege Boundaries              │
└──────────────────────────────────────────────────────────┘

User Space (No privileges needed):
├── Create ~/.meetingscribe/
├── Create ~/Documents/MeetingScribe/
├── Create ~/Library/LaunchAgents/*.plist
├── Create ~/Library/Logs/MeetingScribe/
└── Write installation marker

System Space (Requires sudo):
└── Copy to /usr/local/bin/meetingscribe-ctl
    ├─→ AppleScript: "with administrator privileges"
    ├─→ User prompted for password
    └─→ Only CLI tool installation needs this

macOS Permissions (User grants):
├── Screen Recording
│   └─→ System Settings > Privacy & Security
└── Microphone (optional)
    └─→ System Settings > Privacy & Security

Code Signing:
├── Bundle signed during build
├── Embedded scripts included in signature
└── Moving app invalidates signature (OK for dev)
```

## Comparison: Old vs New Installation

### Old Method (Manual)
```
1. User builds from source OR downloads DMG
2. User drags to Applications
3. User must manually run: ./scripts/install.sh
4. Script sets up LaunchAgent, CLI, etc.
5. User manually grants permissions
6. User manually starts app
```

### New Method (Automatic)
```
1. User downloads DMG
2. User drags to Applications
3. User launches app
4. ✨ Installer runs automatically ✨
5. User clicks through dialogs
6. Done - everything set up
```

## Integration with Build Pipeline

```
Developer Workflow:
┌────────────────────────────────────────────────────────┐
│                                                         │
│  ./scripts/build-and-sign.sh                           │
│      ├─→ swift build -c release                        │
│      ├─→ Create app bundle                             │
│      ├─→ Bundle Python environment                     │
│      ├─→ ./scripts/embed-installer.sh   ← NEW STEP    │
│      │      ├─→ Copy first-run-installer.sh            │
│      │      ├─→ Copy meetingscribe-ctl.sh              │
│      │      ├─→ Copy uninstall.sh                      │
│      │      └─→ Copy reset-permissions.sh              │
│      └─→ codesign                                       │
│                                                         │
│  ./scripts/package-for-distribution.sh                 │
│      ├─→ Create DMG                                     │
│      ├─→ Include README with new instructions          │
│      └─→ Ready for distribution                        │
│                                                         │
└────────────────────────────────────────────────────────┘
```
