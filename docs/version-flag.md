# Version Flag Feature

## Overview
MeetingScribe now supports displaying its version number via command-line flags.

## Usage

### Using the CLI tool (recommended):
```bash
meetingscribe-ctl version
```

### Output:
```
MeetingScribe 1.2.3
Location: /Applications/MeetingScribe.app
```

### From the app bundle directly:
```bash
./MeetingScribe.app/Contents/MacOS/meetingscribe --version
# or
./MeetingScribe.app/Contents/MacOS/meetingscribe -v
```

### Output:
```
MeetingScribe 1.2.3
```

## How It Works

### Version Injection
When you package the app for distribution:
```bash
./scripts/package-for-distribution.sh 1.2.3
```

The packaging script:
1. Updates `CFBundleShortVersionString` in `Info.plist` to `1.2.3`
2. Updates `CFBundleVersion` in `Info.plist` to `1.2.3`
3. Creates DMG/ZIP with the version in the filename

### Runtime Behavior
When the app is launched with `--version` or `-v`:
1. Reads version from `Bundle.main.infoDictionary["CFBundleShortVersionString"]`
2. Prints `MeetingScribe <version>` to stdout
3. Exits immediately without launching the GUI

### Normal Launch
If no version flag is provided, the app launches normally as a background daemon with menu bar icon.

## Implementation Details

### main.swift
Command-line argument checking occurs before NSApplication initialization:
```swift
// Handle --version flag before initializing GUI app
if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    print("MeetingScribe \(version)")
    exit(0)
}
```

### package-for-distribution.sh
Uses PlistBuddy to inject the version:
```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
```

### meetingscribe-ctl.sh
The CLI tool's `version` command:
1. Searches for the app in `/Applications/MeetingScribe.app` or `~/Applications/MeetingScribe.app`
2. Reads version from the bundle's `Info.plist` using PlistBuddy
3. Displays version and installation location

## Notes

- The standalone binary (`build/meetingscribe`) will show "unknown" since it doesn't have an Info.plist
- The app bundle version is what gets distributed to users
- Version format supports semantic versioning (e.g., `1.2.3`) and pre-release tags (e.g., `1.2.3-beta`, `2.0.0-rc1`)
- The version is also logged on app startup in the daemon logs
