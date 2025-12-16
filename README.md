# MeetingScribe

Automated meeting transcription and notes service for macOS that automatically detects Microsoft Teams meetings, captures audio, transcribes it, generates AI-powered notes, and saves them to Bear.app.

## Features

- ✅ **Automatic Call Detection**: Hybrid detection for Teams/Zoom calls using window analysis and network monitoring
- ✅ **Audio Capture**: High-quality bidirectional audio recording using ScreenCaptureKit
- ✅ **AI Transcription**: Support for OpenAI Whisper API and local Whisper models
- ✅ **Smart Notes Generation**: Multi-LLM support (OpenAI, Anthropic Claude, Ollama)
- ✅ **Bear.app Integration**: Automatic note saving with fallback to local files
- ✅ **Menu Bar Interface**: Manual recording control and status monitoring
- ✅ **Background Service**: Runs automatically on login as LaunchAgent

## Requirements

- macOS 13.0+ (Ventura or later)
- Swift 5.9+
- Xcode Command Line Tools
- Screen Recording permission
- Microphone permission (optional, for local track)

## Installation

### 1. Build

```bash
./scripts/build-and-sign.sh
```

### 2. Install

```bash
./scripts/install.sh
```

### 3. Grant Permissions

On first run, macOS will prompt for:
- **Screen Recording** permission (required)
- **Microphone** permission (optional)

Grant these in **System Settings > Privacy & Security**

### 4. Configure API Keys

```bash
# Create configuration directory
mkdir -p ~/.meetingscribe

# The app will create a default config on first run
# Edit ~/.meetingscribe/config.json to customize settings
```

Store API keys securely using the built-in secrets manager:

```bash
# Example: Store OpenAI API key
# (This will be done through the app, not directly)
```

## Usage

### Automatic Mode

Once installed, MeetingScribe runs in the background and automatically:
1. Detects when you join a Teams meeting
2. Starts audio recording
3. Stops when the meeting ends
4. Transcribes the audio
5. Generates meeting notes
6. Saves to Bear.app

### Manual Mode

Click the menu bar icon and select:
- **Start Recording** - Begin manual recording
- **Stop Recording** - Stop and process recording

## Configuration

Edit `~/.meetingscribe/config.json`:

```json
{
  "version": "1.0",
  "detection": {
    "pollInterval": 2.0,
    "debounceChecks": 2,
    "confidenceThreshold": 85
  },
  "audio": {
    "outputDirectory": "~/Documents/MeetingScribe/recordings/",
    "sampleRate": 48000,
    "bitDepth": 16,
    "channels": 2
  },
  "transcription": {
    "provider": "openai",
    "openai": {
      "model": "whisper-1"
    }
  },
  "notes": {
    "llm": {
      "provider": "anthropic",
      "anthropic": {
        "model": "claude-4.5-sonnet"
      }
    },
    "backend": "bear"
  }
}
```

## Architecture

Based on proven implementations from:
- **Call Detection**: Ported from `call_detection_spike` (Python → Swift)
- **Audio Capture**: Adapted from `audio_capture_daemon_spike` (ScreenCaptureKit)

### Component Overview

```
┌─────────────────────────────────────────┐
│         MeetingScribe Service           │
│                                         │
│  CallDetector → AudioCapture            │
│        ↓                                │
│  Transcription → NotesGeneration        │
│        ↓                                │
│  TemplateEngine → NotesPlugin (Bear)    │
└─────────────────────────────────────────┘
```

## Development

### Build for Development

```bash
swift build
./.build/debug/meetingscribe
```

### Run Tests

```bash
swift test
```

### Debugging

View logs:
```bash
tail -f ~/Library/Logs/MeetingScribe/stderr.log
```

## Troubleshooting

### Permission Issues

If screen recording permission is denied:
1. Open **System Settings**
2. Go to **Privacy & Security > Screen Recording**
3. Enable checkbox for **meetingscribe**
4. Restart the service:
   ```bash
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist 2>/dev/null || true
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist
   launchctl kickstart -k gui/$(id -u)/com.meetingscribe.daemon 2>/dev/null || true
   ```

### Teams Not Detected

Ensure Microsoft Teams is running and check logs for detection signals.

### No Audio Captured

Verify:
1. Screen recording permission is granted
2. Teams is playing audio
3. Service is running: `launchctl list | grep meetingscribe`

## Uninstallation

```bash
./scripts/uninstall.sh
```

Optional cleanup:
```bash
rm -rf ~/.meetingscribe              # Remove config
rm -rf ~/Documents/MeetingScribe     # Remove recordings
rm -rf ~/Library/Logs/MeetingScribe  # Remove logs
```

## Project Structure

```
meeting-scribe/
├── src/
│   ├── core/              # Core functionality
│   │   ├── CallDetector.swift
│   │   ├── AudioCapture.swift
│   │   ├── Transcription.swift
│   │   ├── NotesGeneration.swift
│   │   └── TemplateEngine.swift
│   ├── plugins/           # Notes backend plugins
│   │   ├── NotesPlugin.swift
│   │   └── BearPlugin.swift
│   ├── ui/                # User interface
│   │   └── MenuBarController.swift
│   ├── config/            # Configuration
│   │   ├── ConfigManager.swift
│   │   └── SecretsManager.swift
│   └── main.swift         # Entry point
├── tests/                 # Unit tests
├── scripts/               # Build and install scripts
├── resources/             # LaunchAgent plist, templates
└── README.md
```

## Privacy & Legal

⚠️ **IMPORTANT**: This tool captures ALL audio from meetings, including other participants.

**Legal Requirements**:
- May require consent from all parties (check local laws)
- Consider implementing notification mechanisms
- Document data retention policies
- Ensure compliance with recording laws in your jurisdiction

**Privacy Considerations**:
- Audio files stored locally (unencrypted by default)
- User has full control over captured files
- No audio transmitted externally except to configured APIs (OpenAI/Anthropic/Ollama)
- API keys stored securely in macOS Keychain

## Future Enhancements

- [ ] Zoom call detection improvements
- [ ] Local Whisper.cpp integration
- [ ] Additional notes backend plugins (Notion, Obsidian)
- [ ] Speaker diarization
- [ ] Action item extraction
- [ ] Encryption at rest

## License

This is a research/development project. Check with legal before using in production.

## Credits

Built with learnings from:
- `audio_capture_daemon_spike` - ScreenCaptureKit audio capture
- `call_detection_spike` - Hybrid call detection methodology
