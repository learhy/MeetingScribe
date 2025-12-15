# Product Requirements Document: Meeting Transcription & Notes Service

**Version:** 1.0  
**Date:** December 15, 2025  
**Target Platform:** macOS 13.0+  
**Coding Assistant:** Warp.dev  
**Project Name:** `meeting-scribe` (suggested)

---

## Executive Summary

This document specifies a macOS background service that automatically detects Microsoft Teams meetings, captures bidirectional audio, transcribes the recording, generates AI-powered meeting notes, and saves them to Bear.app (with extensible support for other notes applications).

The service leverages proven solutions from existing research spikes for call detection and audio capture, ensuring reliability and maintainability.

---

## System Architecture

### High-Level Flow

```
User Login
    ↓
Service Starts (LaunchAgent)
    ↓
Monitor for Teams Calls (Hybrid Detection)
    ↓
Call Detected → Start Audio Capture (ScreenCaptureKit)
    ↓
Call Ends → Stop Capture
    ↓
Transcribe Audio (Whisper API / Local)
    ↓
Generate Notes (LLM: OpenAI/Anthropic/Ollama)
    ↓
Format Notes (Template Engine)
    ↓
Save to Bear.app (Plugin Architecture)
    ↓
Ready for Next Meeting
```

### Component Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MeetingScribe Service                │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Call         │  │ Audio        │  │ Transcription│ │
│  │ Detection    │→ │ Capture      │→ │ Service      │ │
│  │ Module       │  │ Module       │  │              │ │
│  └──────────────┘  └──────────────┘  └──────┬───────┘ │
│         ↑                                    │         │
│         │                                    ↓         │
│  ┌──────────────┐                   ┌──────────────┐  │
│  │ Menu Bar     │                   │ Notes        │  │
│  │ Interface    │                   │ Generation   │  │
│  │              │                   │ Service      │  │
│  └──────────────┘                   └──────┬───────┘  │
│                                            │          │
│                                            ↓          │
│                                   ┌──────────────┐   │
│                                   │ Notes Plugin │   │
│                                   │ System       │   │
│                                   │ (Bear, etc.) │   │
│                                   └──────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## Functional Requirements

### 1. Call Detection Module

**Based On:** `RFC_CALL_DETECTION_IMPLEMENTATION.md`

**Requirements:**
- FR-1.1: Implement hybrid call detection with >90% accuracy
- FR-1.2: Support detection of Microsoft Teams calls (both scheduled and ad-hoc)
- FR-1.3: Use primary method: Window title pattern matching (90% confidence)
- FR-1.4: Use secondary method: UDP media port monitoring (85% confidence)
- FR-1.5: Use fallback method: Window count heuristic for Teams (80% confidence)
- FR-1.6: Implement temporal debouncing (N=2 consecutive checks) to reduce false positives
- FR-1.7: Detection latency must be <5 seconds
- FR-1.8: Expose call state changes via callbacks: `onCallStarted()`, `onCallEnded()`

**Implementation Notes:**
- Reuse detection logic from call detection spike
- Poll interval: 2.0 seconds (configurable)
- Confidence threshold: 85% minimum to trigger recording
- State machine: NO_CALL ↔ IN_CALL with debouncing

### 2. Audio Capture Module

**Based On:** `04-ARCHITECTURE-DESIGN.md` and `05-SPIKE-SUMMARY-AND-RECOMMENDATIONS.md`

**Requirements:**
- FR-2.1: Capture bidirectional audio (system output + microphone input) from Teams
- FR-2.2: Use ScreenCaptureKit for system audio capture (proven approach)
- FR-2.3: Save audio as 48kHz, 16-bit, stereo WAV files
- FR-2.4: Create new file per meeting with naming: `meeting_YYYY-MM-DD_HH-MM-SS.wav`
- FR-2.5: Store recordings in configurable directory (default: `~/Documents/MeetingScribe/recordings/`)
- FR-2.6: CPU usage must be <5% during capture
- FR-2.7: Memory usage must be <100MB
- FR-2.8: Handle permissions gracefully (Screen Recording TCC permission)
- FR-2.9: Automatic restart on capture failure
- FR-2.10: Clean shutdown on call end (flush buffers, close file)

**Implementation Notes:**
- Reuse ScreenCaptureKit implementation from audio capture spike
- Implement as LaunchAgent with `ProcessType: Interactive`
- Code signing required for TCC permissions
- Use `AVAssetWriter` for WAV file creation

### 3. Transcription Service

**Requirements:**
- FR-3.1: Support multiple transcription providers:
  - OpenAI Whisper API (cloud)
  - Local Whisper model (via whisper.cpp or similar)
- FR-3.2: Configurable provider selection in settings
- FR-3.3: Transcription output format: Plain text with timestamps
- FR-3.4: Error handling: Retry on transient failures (network errors)
- FR-3.5: Progress indication for long transcriptions (optional)
- FR-3.6: Store transcript as `.txt` file alongside WAV file
- FR-3.7: Transcript naming: `meeting_YYYY-MM-DD_HH-MM-SS.txt`

**API Integration:**
- OpenAI Whisper API: `/v1/audio/transcriptions`
- Local Whisper: Use whisper.cpp bindings or similar
- Fallback order: Primary → Fallback → Error notification

### 4. Notes Generation Service

**Requirements:**
- FR-4.1: Support multiple LLM providers:
  - OpenAI (GPT-4, GPT-3.5-turbo)
  - Anthropic (Claude 4.5 Sonnet, Claude 3.5 Sonnet)
  - Ollama (local models: llama3, mistral, etc.)
- FR-4.2: Configurable model selection per provider
- FR-4.3: Customizable system prompts for notes generation
- FR-4.4: Default prompt template included (editable via config)
- FR-4.5: Token limit handling (chunk long transcripts if needed)
- FR-4.6: Error handling: Fallback to raw transcript if LLM fails
- FR-4.7: Output format: Markdown

**Default Prompt Template:**
```
You are a meeting notes assistant. Generate concise, well-structured notes from the following meeting transcript.

Include:
- Meeting summary (2-3 sentences)
- Key discussion points (bullet points)
- Action items (if any)
- Decisions made (if any)

Format the output in Markdown.

Transcript:
{transcript}
```

### 5. Notes Template System

**Requirements:**
- FR-5.1: Configurable note template with placeholders
- FR-5.2: Support template variables:
  - `{date}`: Meeting date
  - `{time}`: Meeting time
  - `{duration}`: Meeting duration
  - `{title}`: Auto-generated or default title
  - `{summary}`: LLM-generated summary
  - `{notes}`: LLM-generated notes
  - `{transcript}`: Full transcript
  - `{audio_file}`: Path to WAV file
- FR-5.3: Template stored as file (Markdown format)
- FR-5.4: Template hot-reload (changes apply to next meeting)

**Default Template:**
```markdown
# Meeting Notes - {date}

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
```

### 6. Notes Backend Plugin System

**Requirements:**
- FR-6.1: Plugin architecture for notes backends
- FR-6.2: Initial implementation: Bear.app plugin
- FR-6.3: Plugin interface specification:
  - `save(note: FormattedNote) -> Result<NoteID, Error>`
  - `configure(settings: Dictionary) -> Bool`
  - `healthCheck() -> Bool`
- FR-6.4: Plugin discovery: Load from `~/.meetingscribe/plugins/`
- FR-6.5: Plugin configuration per backend (API keys, endpoints, etc.)
- FR-6.6: Fallback: If plugin fails, save as Markdown file locally

**Bear.app Plugin Specifics:**
- Use Bear's x-callback-url API: `bear://x-callback-url/create?text={note}`
- Tag support: Configurable default tags (e.g., `#meetings`, `#teams`)
- Title extraction: First line of formatted note

**Future Plugin Examples:**
- Notion
- Obsidian (file-based)
- Apple Notes
- Evernote

### 7. Menu Bar Interface

**Requirements:**
- FR-7.1: Menu bar icon always visible when service is running
- FR-7.2: Icon states:
  - Idle: Default icon
  - Listening: Pulsing/animated icon
  - Recording: Red dot or recording indicator
- FR-7.3: Menu options:
  - "Start Meeting" (manual trigger)
  - "Stop Recording" (if recording active)
  - "Open Preferences"
  - "View Recent Notes"
  - "Quit MeetingScribe"
- FR-7.4: Click "Start Meeting" → Start recording immediately (skip call detection)
- FR-7.5: Click "Stop Recording" → Stop current recording, process normally
- FR-7.6: Preferences window for configuration (see Configuration section)

**UI/UX Notes:**
- Use SF Symbols for icons
- Keyboard shortcuts optional (e.g., Cmd+Shift+M for manual start)
- Notifications on meeting start/end (macOS Notification Center)

### 8. Configuration System

**Requirements:**
- FR-8.1: Configuration file: `~/.meetingscribe/config.json`
- FR-8.2: Configuration GUI in Preferences window
- FR-8.3: Configurable settings:

**Call Detection Settings:**
- `detection.pollInterval`: 2.0 (seconds)
- `detection.debounceChecks`: 2
- `detection.confidenceThreshold`: 85 (percentage)

**Audio Capture Settings:**
- `audio.outputDirectory`: `~/Documents/MeetingScribe/recordings/`
- `audio.sampleRate`: 48000
- `audio.bitDepth`: 16
- `audio.channels`: 2

**Transcription Settings:**
- `transcription.provider`: `openai` | `local`
- `transcription.openai.apiKey`: `<secret>`
- `transcription.openai.model`: `whisper-1`
- `transcription.local.modelPath`: `<path>`

**Notes Generation Settings:**
- `notes.llm.provider`: `openai` | `anthropic` | `ollama`
- `notes.llm.openai.apiKey`: `<secret>`
- `notes.llm.openai.model`: `gpt-4`
- `notes.llm.anthropic.apiKey`: `<secret>`
- `notes.llm.anthropic.model`: `claude-4.5-sonnet`
- `notes.llm.ollama.endpoint`: `http://localhost:11434`
- `notes.llm.ollama.model`: `llama3`
- `notes.llm.systemPrompt`: `<template>`
- `notes.template.path`: `~/.meetingscribe/note-template.md`

**Notes Backend Settings:**
- `notes.backend`: `bear` | `notion` | `obsidian` | etc.
- `notes.bear.tags`: `["#meetings", "#teams"]`
- `notes.bear.fallbackDirectory`: `~/Documents/MeetingScribe/notes/`

**UI Settings:**
- `ui.showNotifications`: `true`
- `ui.notifyOnStart`: `true`
- `ui.notifyOnEnd`: `true`

FR-8.4: Secrets stored securely (macOS Keychain)
FR-8.5: Config validation on load
FR-8.6: Default config created on first run

### 9. LaunchAgent / Background Service

**Requirements:**
- FR-9.1: Run as LaunchAgent (user context, not system daemon)
- FR-9.2: Start automatically on user login
- FR-9.3: `ProcessType: Interactive` for audio access
- FR-9.4: KeepAlive: `true` (restart on crash)
- FR-9.5: Standard logging to `~/Library/Logs/MeetingScribe/`
- FR-9.6: Graceful shutdown on SIGTERM
- FR-9.7: Installation script: `./scripts/install.sh`
- FR-9.8: Uninstallation script: `./scripts/uninstall.sh`

**LaunchAgent Plist:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.meetingscribe.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/meetingscribe</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/Users/{username}/Library/Logs/MeetingScribe/stderr.log</string>
    <key>StandardOutPath</key>
    <string>/Users/{username}/Library/Logs/MeetingScribe/stdout.log</string>
</dict>
</plist>
```

---

## Non-Functional Requirements

### Performance
- NFR-1: CPU usage <5% average during recording
- NFR-2: Memory usage <200MB total
- NFR-3: Transcription start within 5 seconds of recording end
- NFR-4: Notes generation complete within 30 seconds (typical meeting)
- NFR-5: UI responsiveness: All menu actions <500ms

### Reliability
- NFR-6: Uptime: 99.9% (measured over 30 days)
- NFR-7: Automatic crash recovery via LaunchAgent
- NFR-8: Data integrity: No corrupted WAV files
- NFR-9: Graceful degradation: Save transcript if LLM fails

### Security & Privacy
- NFR-10: API keys stored in macOS Keychain
- NFR-11: WAV files encrypted at rest (optional, future)
- NFR-12: No audio data sent to cloud without user consent
- NFR-13: Clear privacy policy and consent mechanism
- NFR-14: User control over data retention

### Maintainability
- NFR-15: Modular architecture (see component diagram)
- NFR-16: Comprehensive logging (debug, info, warning, error)
- NFR-17: Unit test coverage >70%
- NFR-18: Integration tests for end-to-end flow
- NFR-19: Documentation: README, API docs, user guide

### Compatibility
- NFR-20: macOS 13.0+ (Ventura and later)
- NFR-21: Apple Silicon and Intel Macs
- NFR-22: Microsoft Teams (latest version)
- NFR-23: Zoom support (future, nice-to-have)

---

## Implementation Guidelines

### Code Organization

**Project Structure:**
```
meeting-scribe/
├── src/
│   ├── core/
│   │   ├── CallDetector.swift          # From call detection spike
│   │   ├── AudioCapture.swift          # From audio capture spike
│   │   ├── Transcription.swift         # New
│   │   ├── NotesGeneration.swift       # New
│   │   └── TemplateEngine.swift        # New
│   ├── plugins/
│   │   ├── NotesPlugin.swift           # Protocol definition
│   │   └── BearPlugin.swift            # Bear implementation
│   ├── ui/
│   │   ├── MenuBarController.swift
│   │   └── PreferencesWindow.swift
│   ├── config/
│   │   ├── ConfigManager.swift
│   │   └── SecretsManager.swift
│   └── main.swift
├── tests/
│   ├── CallDetectorTests.swift
│   ├── AudioCaptureTests.swift
│   ├── TranscriptionTests.swift
│   └── IntegrationTests.swift
├── scripts/
│   ├── build-and-sign.sh
│   ├── install.sh
│   ├── uninstall.sh
│   └── first-run-permissions.sh
├── resources/
│   ├── com.meetingscribe.daemon.plist
│   ├── default-config.json
│   ├── default-template.md
│   └── default-prompt.txt
└── README.md
```

### Spike Integration

**Call Detection:**
- Reference: `RFC_CALL_DETECTION_IMPLEMENTATION.md`
- Reuse: Hybrid detection logic (window title + UDP ports + window count)
- Adapt: Wrap in Swift class `CallDetector` with callbacks

**Audio Capture:**
- Reference: `04-ARCHITECTURE-DESIGN.md`, `05-SPIKE-SUMMARY-AND-RECOMMENDATIONS.md`, `06-TEST-RESULTS-AND-FINDINGS.md`
- Reuse: ScreenCaptureKit implementation, WAV writer, permission handling
- Adapt: Integrate with call detection lifecycle

**New Components:**
- Transcription: Implement from scratch (OpenAI/local Whisper support)
- Notes Generation: Implement from scratch (multi-LLM support)
- Plugin System: Implement from scratch (start with Bear)

### Coding Standards

**Follow WARP.md Guidelines:**
- Use Swift 5.9+ features
- Async/await for asynchronous operations
- Structured concurrency (Tasks, TaskGroups)
- Error handling: Result types and throws
- Logging: Use `os_log` framework
- Code style: SwiftLint compliance
- Documentation: Inline comments + DocC

**Best Practices:**
- Single Responsibility Principle
- Dependency injection for testability
- Protocol-oriented design for plugins
- Immutable data structures where possible
- Avoid force unwrapping (use guard/if-let)

### Dependencies

**Required:**
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ggerganov/whisper.cpp", from: "1.5.0"), // Local Whisper
    // No other external dependencies - use native frameworks
]
```

**Native Frameworks:**
- ScreenCaptureKit (audio capture)
- AVFoundation (WAV writing)
- AppKit (menu bar UI)
- Security (Keychain)
- Foundation (networking, JSON)

### Testing Strategy

**Unit Tests:**
- CallDetector: Mock window list, network connections
- AudioCapture: Mock ScreenCaptureKit (difficult, focus on integration)
- Transcription: Mock API responses
- NotesGeneration: Mock LLM responses
- TemplateEngine: Test variable substitution

**Integration Tests:**
- End-to-end: Fake call detection → real audio capture → mock transcription → mock LLM
- Plugin tests: Bear plugin with test notes
- Config loading and validation

**Manual Testing:**
- Real Teams meeting capture
- Audio quality verification
- Transcription accuracy check
- Notes quality assessment
- UI responsiveness

**Automated Testing (Future):**
- CI/CD pipeline (GitHub Actions)
- Periodic background operation tests
- Regression testing on macOS updates

---

## User Workflows

### Workflow 1: Automatic Meeting Recording

1. User logs into macOS
2. MeetingScribe starts automatically (LaunchAgent)
3. Service monitors for Teams calls (idle, menu bar icon visible)
4. User joins Teams meeting
5. Service detects call within 5 seconds
6. Audio capture starts automatically
7. User receives notification: "Recording started"
8. Menu bar icon shows recording state
9. User participates in meeting
10. Meeting ends, user leaves call
11. Service detects call end within 5 seconds
12. Audio capture stops
13. Transcription begins (notification: "Transcribing...")
14. Transcript generated
15. Notes generation begins (notification: "Generating notes...")
16. Notes saved to Bear.app
17. User receives notification: "Notes saved to Bear" (with link)
18. Service returns to idle state

### Workflow 2: Manual Meeting Recording

1. User clicks menu bar icon
2. Selects "Start Meeting"
3. Audio capture starts immediately
4. User conducts meeting (Teams, Zoom, or any audio source)
5. User clicks menu bar icon
6. Selects "Stop Recording"
7. Processing continues as in Workflow 1 (steps 12-18)

### Workflow 3: Configuration

1. User clicks menu bar icon
2. Selects "Open Preferences"
3. Preferences window opens with tabs:
   - General (detection settings)
   - Audio (capture settings)
   - Transcription (provider, API keys)
   - Notes (LLM provider, prompts, template)
   - Backends (Bear settings, future plugins)
4. User modifies settings
5. Clicks "Save"
6. Service reloads configuration
7. Changes apply to next meeting

### Workflow 4: Plugin Installation (Future)

1. User downloads Notion plugin (`.meetingscribe-plugin` bundle)
2. User double-clicks plugin
3. Plugin installer opens
4. User clicks "Install"
5. Plugin copied to `~/.meetingscribe/plugins/`
6. Service detects new plugin
7. Plugin appears in Preferences > Backends
8. User configures plugin (Notion API key, database ID)
9. User selects Notion as active backend
10. Next meeting notes saved to Notion

---

## Error Handling

### Error Categories

**1. Permission Errors:**
- Screen recording permission denied
- Microphone permission denied
- **Action**: Show alert with instructions, wait for user to grant, retry

**2. API Errors:**
- OpenAI API key invalid
- Anthropic rate limit exceeded
- Network timeout
- **Action**: Retry with exponential backoff, fallback to local/alternative provider

**3. Capture Errors:**
- Teams not found
- Audio stream failed
- Disk full
- **Action**: Log error, notify user, attempt recovery, save state

**4. Processing Errors:**
- Transcription failed
- LLM generation failed
- Plugin save failed
- **Action**: Fallback to raw transcript, save locally, notify user

### Error Notification Strategy

**User-Facing Errors:**
- macOS Notification Center for critical errors
- Menu bar icon shows error state (red exclamation)
- "View Logs" option in menu

**Developer Errors:**
- Comprehensive logging to `~/Library/Logs/MeetingScribe/`
- Log rotation (keep last 7 days)
- Crash reports to local file (optional: send to developer)

---

## Configuration Schema

**Config File:** `~/.meetingscribe/config.json`

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
      "apiKeyKeychainItem": "MeetingScribe-OpenAI-Key",
      "model": "whisper-1"
    },
    "local": {
      "modelPath": "~/.meetingscribe/models/whisper-base.bin"
    }
  },
  "notes": {
    "llm": {
      "provider": "anthropic",
      "openai": {
        "apiKeyKeychainItem": "MeetingScribe-OpenAI-Key",
        "model": "gpt-4"
      },
      "anthropic": {
        "apiKeyKeychainItem": "MeetingScribe-Anthropic-Key",
        "model": "claude-4.5-sonnet"
      },
      "ollama": {
        "endpoint": "http://localhost:11434",
        "model": "llama3"
      },
      "systemPromptFile": "~/.meetingscribe/prompts/default.txt"
    },
    "templateFile": "~/.meetingscribe/templates/default.md",
    "backend": "bear",
    "bear": {
      "tags": ["#meetings", "#teams"],
      "fallbackDirectory": "~/Documents/MeetingScribe/notes/"
    }
  },
  "ui": {
    "showNotifications": true,
    "notifyOnStart": true,
    "notifyOnEnd": true
  }
}
```

---

## Installation & Deployment

### Prerequisites

- macOS 13.0+ (Ventura)
- Xcode Command Line Tools
- Apple Developer account (for code signing)
- Screen Recording permission

### Installation Steps

```bash
# 1. Clone repository
git clone <repo-url> meeting-scribe
cd meeting-scribe

# 2. Build and sign
./scripts/build-and-sign.sh

# 3. First-run permission grant
./scripts/first-run-permissions.sh

# 4. Install LaunchAgent
./scripts/install.sh

# 5. Verify installation
./scripts/verify-installation.sh
```

### Uninstallation

```bash
./scripts/uninstall.sh
```

**Steps:**
1. Unload LaunchAgent
2. Remove binary
3. Remove LaunchAgent plist
4. Optionally remove config and data
5. Optionally reset TCC permissions

---

## Future Enhancements

### Phase 1 (v1.0) - Core Functionality
- ✅ Call detection (Teams)
- ✅ Audio capture
- ✅ Transcription
- ✅ Notes generation
- ✅ Bear.app plugin
- ✅ Menu bar interface
- ✅ LaunchAgent

### Phase 2 (v1.1) - Polish
- ⚠️ Zoom call detection
- ⚠️ Audio quality monitoring
- ⚠️ Silence detection (auto-stop recording)
- ⚠️ Notes editing in-app
- ⚠️ Search recent meetings

### Phase 3 (v1.2) - Extensibility
- ⚠️ Plugin SDK documentation
- ⚠️ Notion plugin
- ⚠️ Obsidian plugin
- ⚠️ Apple Notes plugin
- ⚠️ Custom template editor

### Phase 4 (v2.0) - Advanced Features
- ⚠️ Speaker diarization (identify speakers)
- ⚠️ Action item extraction
- ⚠️ Meeting summaries dashboard
- ⚠️ Cloud sync
- ⚠️ Team collaboration features

---

## Success Metrics

**Technical Metrics:**
- Call detection accuracy: >90%
- Audio capture reliability: >99%
- Transcription accuracy: >95% (human-verified sample)
- Notes quality: Subjective, user feedback
- Crash rate: <1% of meetings

**User Metrics:**
- Time saved per meeting: 10-15 minutes (manual note-taking)
- User satisfaction: >4.5/5 (survey)
- Adoption rate: >80% of installed users actively use

**Performance Metrics:**
- CPU usage: <5% average
- Memory usage: <200MB
- Disk usage: ~50MB per 1-hour meeting (audio + transcript + notes)

---

## Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| LLM API costs too high | High | Medium | Offer local Ollama as default, budget controls |
| Transcription accuracy poor | High | Low | Use Whisper (proven), allow manual correction |
| Bear.app API changes | Medium | Low | Monitor Bear updates, maintain plugin |
| macOS updates break capture | High | Low | Monitor Apple releases, test betas early |
| User privacy concerns | Critical | Medium | Clear privacy policy, local-first option (Ollama + local Whisper) |

---

## Open Questions

1. **Should we support video capture?**
   - **Answer**: No, out of scope for v1.0 (audio only)

2. **Should we include speaker diarization?**
   - **Answer**: Nice-to-have for v2.0, not critical for MVP

3. **How to handle multi-hour meetings?**
   - **Answer**: Chunk transcription/processing, warn user if >2 hours

4. **Should we support Windows/Linux?**
   - **Answer**: No, macOS only for v1.0

5. **What if user has multiple Teams accounts?**
   - **Answer**: Detect all Teams windows, capture first detected

---

## Appendix A: API References

### OpenAI Whisper API

**Endpoint:**
```
POST https://api.openai.com/v1/audio/transcriptions
```

**Request:**
```bash
curl -X POST https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@meeting.wav" \
  -F "model=whisper-1"
```

**Response:**
```json
{
  "text": "This is the transcribed text of the audio file."
}
```

### Anthropic Messages API

**Endpoint:**
```
POST https://api.anthropic.com/v1/messages
```

**Request:**
```bash
curl -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-4.5-sonnet-20250514",
    "max_tokens": 4096,
    "messages": [
      {
        "role": "user",
        "content": "Generate meeting notes from this transcript: ..."
      }
    ]
  }'
```

**Response:**
```json
{
  "id": "msg_...",
  "content": [
    {
      "type": "text",
      "text": "# Meeting Notes\n\n..."
    }
  ]
}
```

### Ollama API

**Endpoint:**
```
POST http://localhost:11434/api/generate
```

**Request:**
```bash
curl -X POST http://localhost:11434/api/generate \
  -d '{
    "model": "llama3",
    "prompt": "Generate meeting notes: ...",
    "stream": false
  }'
```

**Response:**
```json
{
  "model": "llama3",
  "response": "# Meeting Notes\n\n..."
}
```

### Bear x-callback-url API

**Create Note:**
```
bear://x-callback-url/create?title={title}&text={text}&tags={tags}
```

**Example:**
```
bear://x-callback-url/create?title=Meeting%20Notes%20-%20Dec%2015&text=%23%20Summary%0A...&tags=meetings,teams
```

**Response:** Bear opens with new note created

---

## Appendix B: Prompt Templates

### Default System Prompt

**File:** `~/.meetingscribe/prompts/default.txt`

```
You are a professional meeting notes assistant. Your task is to generate clear, concise, and well-structured meeting notes from transcripts.

Guidelines:
1. Start with a brief summary (2-3 sentences) of the meeting's purpose and outcome
2. Extract key discussion points as bullet points
3. Identify action items with owners (if mentioned)
4. List any decisions made
5. Note any follow-up meetings or deadlines
6. Use clear, professional language
7. Format output in Markdown

Structure:
- Summary
- Key Points
- Action Items (if any)
- Decisions (if any)
- Next Steps (if any)

Be concise but comprehensive. Focus on actionable information.
```

### Example Output

**Input Transcript:**
```
John: Hey everyone, thanks for joining. Today we need to discuss the Q1 roadmap.
Sarah: I think we should prioritize the new dashboard feature.
John: Agreed. Sarah, can you own that? We need it by end of January.
Sarah: Yes, I'll have a prototype ready by Jan 15.
Mike: What about the API integration?
John: Let's push that to Q2. Not critical right now.
Sarah: Sounds good. I'll send a design doc this week.
```

**Expected Output:**
```markdown
# Meeting Notes - December 15, 2025

## Summary
Team discussed Q1 roadmap priorities. Decided to prioritize new dashboard feature with Jan 31 deadline, postponing API integration to Q2.

## Key Discussion Points
- New dashboard feature identified as Q1 priority
- API integration deprioritized to Q2 due to lower urgency

## Action Items
- Sarah: Own dashboard feature implementation (Due: Jan 31)
- Sarah: Deliver prototype (Due: Jan 15)
- Sarah: Send design doc (Due: This week)

## Decisions
- Dashboard feature prioritized for Q1
- API integration moved to Q2

## Next Steps
- Await Sarah's design doc
- Review prototype on Jan 15
```

---

## Appendix C: Testing Checklist

### Pre-Launch Testing

**Build & Installation:**
- [ ] Swift code compiles without errors
- [ ] Binary is properly signed
- [ ] Installation script completes successfully
- [ ] LaunchAgent loads correctly
- [ ] Service starts automatically on login

**Permissions:**
- [ ] Screen recording permission requested
- [ ] Permission dialog appears on first run
- [ ] Permission persists after grant
- [ ] Service handles permission denial gracefully

**Call Detection:**
- [ ] Detects scheduled Teams meetings
- [ ] Detects ad-hoc Teams calls
- [ ] Detection latency <5 seconds
- [ ] No false positives during idle
- [ ] Proper state transitions

**Audio Capture:**
- [ ] Captures system audio (remote participants)
- [ ] Captures microphone audio (local user)
- [ ] WAV file created correctly
- [ ] Audio quality is acceptable (no clipping, noise)
- [ ] CPU usage <5% during capture
- [ ] Memory usage <200MB

**Transcription:**
- [ ] OpenAI Whisper API integration works
- [ ] Local Whisper model works
- [ ] Transcript quality >95% accuracy
- [ ] Handles API errors gracefully
- [ ] Fallback to alternative provider works

**Notes Generation:**
- [ ] OpenAI GPT-4 integration works
- [ ] Anthropic Claude integration works
- [ ] Ollama local model integration works
- [ ] Notes quality is satisfactory
- [ ] Prompt customization works
- [ ] Template rendering works

**Bear Plugin:**
- [ ] Note created in Bear successfully
- [ ] Tags applied correctly
- [ ] Fallback to local file works if Bear unavailable

**Menu Bar UI:**
- [ ] Icon displays correctly
- [ ] Menu items functional
- [ ] Manual start/stop works
- [ ] Preferences window opens
- [ ] Notifications appear correctly

**Configuration:**
- [ ] Config file loads correctly
- [ ] Settings saved and persisted
- [ ] Secrets stored in Keychain
- [ ] Invalid config handled gracefully

**Error Handling:**
- [ ] Permission errors logged and notified
- [ ] API errors retried and handled
- [ ] Capture errors trigger recovery
- [ ] Processing errors fall back gracefully

**End-to-End:**
- [ ] Full workflow (detect → capture → transcribe → generate → save) works
- [ ] Multiple meetings in sequence work
- [ ] Service recovers from crashes
- [ ] Logs are comprehensive and useful

---

**END OF SPECIFICATION**

---

## Summary for Coding Assistant

**Project:** MeetingScribe - Automated meeting transcription and notes service for macOS

**Core Requirements:**
1. Detect Teams meetings automatically (use call detection spike)
2. Capture bidirectional audio (use audio capture spike)
3. Transcribe audio (OpenAI Whisper or local)
4. Generate notes via LLM (OpenAI/Anthropic/Ollama)
5. Save to Bear.app (extensible plugin system)
6. Run as LaunchAgent background service
7. Provide menu bar interface for manual control

**Key Technologies:**
- Swift 5.9+
- ScreenCaptureKit (audio capture)
- LaunchAgent (background service)
- OpenAI/Anthropic/Ollama APIs
- Bear x-callback-url

**Spike Integration:**
- Reuse call detection logic from RFC_CALL_DETECTION_IMPLEMENTATION.md
- Reuse audio capture from 04-ARCHITECTURE-DESIGN.md and related docs
- Implement transcription and notes generation from scratch

**Deliverables:**
- Working macOS application
- Installation scripts
- Configuration system
- Comprehensive documentation
- Test suite

**Follow:** WARP.md coding guidelines

Good luck!