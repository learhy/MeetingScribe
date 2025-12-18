# MeetingScribe

Automated meeting transcription and notes service for macOS that automatically detects Microsoft Teams meetings, captures audio, transcribes it, generates AI-powered notes, and saves them to Bear.app.

## Features

- ✅ **Automatic Call Detection**: Hybrid detection for Teams/Zoom calls using window analysis and network monitoring
- ✅ **Audio Capture**: High-quality bidirectional audio recording using ScreenCaptureKit
- ✅ **AI Transcription**: Support for OpenAI Whisper API and local Whisper models
- ✅ **Speaker Diarization**: Automatically identify different speakers in transcripts (see [DIARIZATION.md](DIARIZATION.md))
- ✅ **Smart Notes Generation**: Multi-LLM support (OpenAI, Anthropic Claude, Ollama)
- ✅ **LLM-Generated Titles**: Automatic meeting title generation from transcript content
- ✅ **Bear.app Integration**: Automatic note saving with fallback to local files
- ✅ **Menu Bar Interface**: Manual recording control, status light indicator, and auto-recording toggle
- ✅ **CLI Control**: Start, stop, restart daemon and view logs from command line
- ✅ **Background Service**: Runs automatically on login as LaunchAgent

## Requirements

- macOS 13.0+ (Ventura or later)
- Screen Recording permission
- Microphone permission (optional, for local track)
- ~2GB disk space for app bundle (includes bundled Python + ML models)
- Additional ~500MB for ML model cache (downloaded on first use)

## Installation

### For End Users

Download the latest release from [Releases](https://github.com/your-repo/meeting-scribe/releases):

1. Download `MeetingScribe-X.X.dmg`
2. Open the DMG and drag `MeetingScribe.app` to `/Applications`
3. Open MeetingScribe from Applications
4. Grant permissions when prompted

**That's it!** Python and all ML dependencies are bundled. On first transcription with speaker diarization, models (~500MB) will be downloaded automatically to `~/.meetingscribe/cache/`.

See [DISTRIBUTION.md](DISTRIBUTION.md) for detailed installation instructions.

### For Developers

**Prerequisites**:
- Swift 5.9+
- Xcode Command Line Tools
- Python 3.9+ (for building bundled environment)

#### 1. Build and Sign (Recommended)

To avoid keychain prompts on every run, set your signing identity:

```bash
export SIGNING_IDENTITY="Your Developer ID"
./scripts/build-and-sign.sh
```

Or build unsigned for local development:
```bash
./scripts/build-and-sign.sh
```

#### 2. Install

This installs the app bundle to `~/Applications/MeetingScribe.app` and sets up the LaunchAgent:

```bash
# User installation (recommended for development)
./scripts/install.sh

# Or system-wide installation
./scripts/install.sh system
```

### 3. Grant Permissions

On first run, macOS will prompt for:
- **Screen Recording** permission (required)
- **Microphone** permission (optional)
- **Keychain access** for API keys (first use only)

**Important**: Grant permissions to `MeetingScribe.app` in **System Settings > Privacy & Security > Screen & System Audio Recording**

If you see repeated permission denials:
```bash
# Reset TCC permissions
tccutil reset ScreenCapture com.meetingscribe.daemon

# Restart the service
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.meetingscribe.daemon.plist
```

### 4. Configure API Keys

On first transcription/notes generation, you'll be prompted to allow keychain access.

The app stores API keys in macOS Keychain. Configure your provider in `~/.meetingscribe/config.json`:

```bash
# Edit configuration
vim ~/.meetingscribe/config.json
```

For local Whisper (no API key needed), set:
```json
{
  "transcription": {
    "provider": "local",
    "local": {
      "modelPath": "~/path/to/whisper.cpp/models/ggml-base.en.bin",
      "whisperBinaryPath": "~/path/to/whisper.cpp/main"
    }
  }
}
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
- **Disable Auto Recording** - Prevent automatic recording detection

### Daemon Control

Control the background daemon using the CLI:

```bash
meetingscribe-ctl status    # Check if daemon is running
meetingscribe-ctl stop      # Stop the daemon
meetingscribe-ctl start     # Start the daemon
meetingscribe-ctl restart   # Restart the daemon
meetingscribe-ctl logs      # View daemon logs (tail -f)
```

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
meetingscribe-ctl logs
# Or directly:
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
   meetingscribe-ctl restart
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
│   │   ├── CallDetector.swift          # Hybrid Teams/Zoom detection
│   │   ├── AudioCapture.swift          # ScreenCaptureKit audio
│   │   ├── Transcription.swift         # OpenAI/Local Whisper
│   │   ├── NotesGeneration.swift       # Multi-LLM with timeouts
│   │   ├── GeneratedNotesParser.swift  # Split summary/notes
│   │   ├── TemplateEngine.swift        # Note formatting
│   │   ├── NotificationManager.swift   # UserNotifications (macOS 11+)
│   │   ├── PermissionChecker.swift     # TCC permission handling
│   │   ├── DualLogger.swift            # Unified+stderr logging
│   │   └── WAVStreamWriter.swift       # Audio file output
│   ├── plugins/           # Notes backend plugins
│   │   ├── NotesPlugin.swift
│   │   └── BearPlugin.swift            # Bear.app integration
│   ├── config/            # Configuration
│   │   ├── ConfigManager.swift
│   │   └── SecretsManager.swift        # Keychain API key storage
│   └── main.swift         # Entry point + service orchestration
├── tests/                 # Unit tests
│   └── MeetingScribeTests.swift
├── scripts/               # Build and install scripts
│   ├── build-and-sign.sh  # Creates .app bundle
│   ├── install.sh         # Installs to ~/Applications
│   └── uninstall.sh
├── resources/             # LaunchAgent plist, templates
│   └── com.meetingscribe.daemon.plist
├── build/                 # Build artifacts (gitignored)
│   ├── meetingscribe      # Standalone binary
│   └── MeetingScribe.app  # App bundle
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

## Recent Improvements

- ✅ **Fast speaker diarization** - 60% faster using SpeechBrain (2:26 vs 4+ min for 26-min audio), no HF token required
- ✅ **Speaker diarization (Phase 1)** - Identify different speakers with SPEAKER_00, SPEAKER_01 labels
- ✅ **Local Whisper.cpp integration** - No API costs for transcription
- ✅ **UserNotifications framework** - Modern notification system (macOS 11+)
- ✅ **App bundle packaging** - Stable permissions and keychain access
- ✅ **Notes parsing** - Prevents duplicate summary/notes sections
- ✅ **LLM timeouts** - 120s timeout prevents hanging on API calls
- ✅ **Port crash fix** - Handles negative port values from proc_info
- ✅ **LaunchAgent compatibility** - Uses modern bootstrap/bootout

## Future Enhancements

- [ ] Zoom call detection improvements (window count threshold tuning)
- [ ] Additional notes backend plugins (Notion, Obsidian)
- [ ] Speaker diarization Phase 2 (local vs remote speaker detection)
- [ ] Speaker diarization Phase 3 (actual speaker names via voice profiles)
- [ ] Add Silero VAD for noise filtering in diarization
- [ ] Action item extraction
- [ ] Encryption at rest
- [ ] Menu bar UI improvements

## License

This is a research/development project. Check with legal before using in production.

## Credits

Built with learnings from:
- `audio_capture_daemon_spike` - ScreenCaptureKit audio capture
- `call_detection_spike` - Hybrid call detection methodology
