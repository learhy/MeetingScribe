# MeetingScribe - TODO for Remaining Work

This document tracks features and functionality specified in `MEETING-SCRIBE-PROJECT-SPEC.MD` that have not yet been fully implemented. The project has a functional MVP, but several features from the specification remain incomplete.

## Status Overview

**✅ COMPLETED (MVP)**
- Basic call detection (window title matching, window count heuristic)
- Audio capture infrastructure (ScreenCaptureKit integration)
- OpenAI Whisper transcription (API integration)
- Multi-LLM notes generation (OpenAI, Anthropic, Ollama)
- Template engine with variable substitution
- Bear.app plugin with fallback to local files
- Menu bar interface (basic)
- Configuration system (JSON file + keychain for secrets)
- LaunchAgent setup

**⚠️ INCOMPLETE / TODO**
See sections below for details

---

## 1. Call Detection - Missing Features

### 1.1 UDP Media Port Monitoring (FR-1.4)
**Status:** Placeholder implementation only  
**Location:** `src/core/CallDetector.swift` - `AVDeviceDetector` class  
**Description:** The spec requires UDP port monitoring as a secondary detection method (85% confidence). Currently returns `nil`.

**Tasks:**
- [ ] Implement BSD sysctl or libproc APIs to enumerate network connections by process
- [ ] Detect Teams media ports: UDP 50000-50089 with no remote address
- [ ] Detect Zoom: 7+ UDP connections
- [ ] Return confidence scores per the spec
- [ ] Test with real Teams/Zoom calls

**Priority:** Medium (detection works without it, but would improve reliability)

### 1.2 Zoom Call Detection Improvements
**Status:** Basic window title matching only  
**Spec Reference:** FR-1.2 (Zoom support noted as Phase 2 enhancement)

**Tasks:**
- [ ] Test Zoom detection patterns thoroughly
- [ ] Add more Zoom window title patterns if needed
- [ ] Validate Zoom detection accuracy >85%

**Priority:** Low (Spec lists as Phase 2)

---

## 2. Audio Capture - Integration Issues

### 2.1 Audio Capture Not Connected to Call Detection
**Status:** ✅ COMPLETED  
**Location:** `src/main.swift` - `handleCallStarted()`  
**Description:** Audio capture is now fully integrated with call detection.

**Completed Tasks:**
- [x] Create `StreamHandler` instance when call is detected
- [x] Find the correct application (Teams/Zoom) using `SCRunningApplication`
- [x] Start audio capture with proper error handling
- [x] Store reference to active capture session
- [x] Stop capture cleanly in `handleCallEnded()`
- [x] Handle permission errors gracefully
- [x] Pass audio file path to processing pipeline

**Remaining:**
- [ ] Test end-to-end with real Teams/Zoom calls

**Priority:** Testing needed

### 2.2 Microphone Permission Handling
**Status:** Basic permission check exists but not fully integrated  
**Location:** `src/core/PermissionChecker.swift`

**Tasks:**
- [ ] Ensure mic permission prompt on first run
- [ ] Handle cases where mic is denied but screen recording granted
- [ ] Update UI to reflect mic status
- [ ] Test system-only vs dual-track recording

**Priority:** Medium

---

## 3. Transcription - Missing Local Whisper

### 3.1 Local Whisper Implementation (FR-3.1)
**Status:** ✅ COMPLETED  
**Location:** `src/core/Transcription.swift` - `LocalWhisperProvider`  
**Description:** Local whisper.cpp integration now fully implemented.

**Completed Tasks:**
- [x] Chose integration approach: Shell out to whisper.cpp CLI (Option B)
- [x] Implement audio file transcription via Process API
- [x] Handle model loading and errors with validation
- [x] Auto-detect whisper.cpp binary in sibling project
- [x] Clean up temporary output files
- [x] Updated default config to use local provider
- [x] Set default model path to existing ggml-base.en.bin

**Configuration:**
- Default provider: `local`
- Binary: `~/My Drive/software_projects/whisper.cpp/main`
- Model: `~/My Drive/software_projects/whisper.cpp/models/ggml-base.en.bin`

**Remaining:**
- [ ] Test with real audio files
- [ ] Add progress indication (optional per spec)
- [ ] Document model installation in README

**Priority:** Testing needed

---

## 4. Notes Generation - Missing Features

### 4.1 Token Limit Handling (FR-4.5)
**Status:** Not implemented  
**Location:** `src/core/NotesGeneration.swift`

**Tasks:**
- [ ] Implement chunking for transcripts exceeding token limits
- [ ] Handle chunk-by-chunk processing
- [ ] Merge chunked outputs into cohesive notes
- [ ] Test with 2+ hour meeting transcripts

**Priority:** Low (most meetings fit in token limits)

---

## 5. Template System - Missing Resources

### 5.1 Default Template File (FR-5.3)
**Status:** Template engine exists but no default file  
**Spec Reference:** See `MEETING-SCRIBE-PROJECT-SPEC.MD` lines 184-202

**Tasks:**
- [ ] Create `~/.meetingscribe/templates/default.md` on first run
- [ ] Include all template variables from spec
- [ ] Add logic to ConfigManager to create default resources
- [ ] Test template hot-reload

**Priority:** High

### 5.2 Default System Prompt File (FR-4.3)
**Status:** Hardcoded in code, not in external file  
**Location:** `src/core/NotesGeneration.swift` - `defaultSystemPrompt`

**Tasks:**
- [ ] Create `~/.meetingscribe/prompts/default.txt` on first run
- [ ] Move default prompt text to file
- [ ] Keep hardcoded fallback for safety
- [ ] Document customization in README

**Priority:** Medium

---

## 6. Menu Bar Interface - Missing Features

### 6.1 Dynamic Icon States (FR-7.2)
**Status:** Basic recording/idle icons only  
**Spec Requirements:**
- Idle: Default icon ✅
- Listening: Pulsing/animated icon ❌
- Recording: Red dot indicator ❌

**Tasks:**
- [ ] Add animated icon for "listening" state
- [ ] Add distinct recording icon (red dot)
- [ ] Update icon in response to call detection state
- [ ] Test icon states across macOS dark/light modes

**Priority:** Low (cosmetic)

### 6.2 "View Recent Notes" Menu Item (FR-7.3)
**Status:** Not implemented

**Tasks:**
- [ ] Add menu item
- [ ] Track last N meetings (timestamps + file paths)
- [ ] Open Bear notes or fallback directory
- [ ] Show "No recent notes" if empty

**Priority:** Low

### 6.3 Preferences Window (FR-7.6)
**Status:** Opens config directory, no GUI  
**Location:** `src/ui/MenuBarController.swift` - `openPreferences()`

**Tasks:**
- [ ] Create PreferencesWindow.swift
- [ ] Build SwiftUI or AppKit preferences UI with tabs:
  - General (detection settings)
  - Audio (capture settings)
  - Transcription (provider, API keys)
  - Notes (LLM provider, prompts, template)
  - Backends (Bear settings)
- [ ] Wire up to ConfigManager
- [ ] Support editing and saving secrets to Keychain
- [ ] Add validation for required fields

**Priority:** Medium (users can edit JSON manually for now)

---

## 7. Configuration System - Gaps

### 7.1 First-Run Setup (FR-8.6)
**Status:** Partial - config.json created, but not prompts/templates

**Tasks:**
- [ ] Create directory structure on first run:
  - `~/.meetingscribe/`
  - `~/.meetingscribe/prompts/`
  - `~/.meetingscribe/templates/`
  - `~/.meetingscribe/models/` (for local Whisper)
- [ ] Populate default-config.json
- [ ] Populate default-template.md
- [ ] Populate default-prompt.txt
- [ ] Add first-run wizard (optional, could be CLI prompts)

**Priority:** High

### 7.2 API Key Setup Workflow
**Status:** No user-facing way to add keys  
**Description:** Users must manually use `security add-generic-password` command

**Tasks:**
- [ ] Add CLI command to store API keys: `meetingscribe setup --openai-key=...`
- [ ] Or integrate into Preferences window (see 6.3)
- [ ] Document manual keychain usage as fallback

**Priority:** High

---

## 8. Installation Scripts - Missing Pieces

### 8.1 first-run-permissions.sh (FR-9.7)
**Status:** Not created  
**Spec Reference:** Lines 686, 410

**Tasks:**
- [ ] Create `scripts/first-run-permissions.sh`
- [ ] Guide user to grant Screen Recording permission
- [ ] Guide user to grant Microphone permission
- [ ] Check permissions and report status
- [ ] Link to System Settings with instructions

**Priority:** Medium (manual permission grant works, but script would improve UX)

### 8.2 verify-installation.sh (FR-9.7)
**Status:** Not created  
**Spec Reference:** Line 692

**Tasks:**
- [ ] Create `scripts/verify-installation.sh`
- [ ] Check if binary exists at `/usr/local/bin/meetingscribe`
- [ ] Check if LaunchAgent plist exists
- [ ] Check if service is loaded: `launchctl list | grep meetingscribe`
- [ ] Check permissions status
- [ ] Report any issues

**Priority:** Low (helpful for debugging)

---

## 9. LaunchAgent - Improvements

### 9.1 Dynamic Username in Plist (FR-9.6)
**Status:** Hardcoded "USERNAME" placeholder  
**Location:** `resources/com.meetingscribe.daemon.plist` line 18-20

**Tasks:**
- [ ] Update install.sh to replace USERNAME with actual username
- [ ] Test that logs directory exists and is writable

**Priority:** High

---

## 10. Error Handling - Improvements

### 10.1 Capture Error Recovery (FR-2.9)
**Status:** Basic error logging, no automatic restart  
**Spec Requirement:** "Automatic restart on capture failure"

**Tasks:**
- [ ] Detect capture failures (stream errors)
- [ ] Implement retry logic with exponential backoff
- [ ] Log failures for debugging
- [ ] Notify user if persistent failures

**Priority:** Medium

### 10.2 Transcription Retry Logic (FR-3.4)
**Status:** Not implemented  
**Spec Requirement:** "Retry on transient failures (network errors)"

**Tasks:**
- [ ] Detect network vs API errors
- [ ] Retry network errors with exponential backoff (e.g., 3 attempts)
- [ ] Fallback to alternative provider if configured
- [ ] Save raw transcript if all attempts fail

**Priority:** Medium

### 10.3 User-Facing Error Notifications (Section: Error Handling)
**Status:** Basic notifications exist but error states incomplete  
**Spec Reference:** Lines 592-600

**Tasks:**
- [ ] Add menu bar error state icon (red exclamation)
- [ ] Add "View Logs" menu item
- [ ] Open logs in Console.app or Text Editor
- [ ] Improve error message clarity for users

**Priority:** Low

---

## 11. Testing - Missing Coverage

### 11.1 Unit Tests (NFR-17)
**Status:** Test target exists but minimal tests  
**Spec Requirement:** "Unit test coverage >70%"  
**Location:** `tests/MeetingScribeTests.swift`

**Tasks:**
- [ ] Write tests for CallDetector (mock window lists)
- [ ] Write tests for TranscriptionService (mock API responses)
- [ ] Write tests for NotesGenerationService (mock LLM responses)
- [ ] Write tests for TemplateEngine
- [ ] Write tests for BearPlugin (mock Bear availability)
- [ ] Write tests for ConfigManager (config loading/saving)
- [ ] Measure coverage: `swift test --enable-code-coverage`

**Priority:** Medium

### 11.2 Integration Tests (NFR-18)
**Status:** Not implemented  
**Spec Reference:** Lines 481-483

**Tasks:**
- [ ] Create integration test suite
- [ ] Test: Fake call detection → mock audio → mock transcription → mock LLM → save
- [ ] Test: Config loading and validation
- [ ] Test: Plugin fallback (Bear unavailable → file save)

**Priority:** Low

### 11.3 Manual Testing Checklist (Appendix C)
**Status:** Not formally tracked  
**Spec Reference:** Lines 968-1043

**Tasks:**
- [ ] Create manual test checklist document
- [ ] Execute pre-launch testing checklist
- [ ] Document test results

**Priority:** High (before v1.0 release)

---

## 12. Documentation - Gaps

### 12.1 User Guide
**Status:** README covers basics, no comprehensive guide  
**Spec Requirement:** NFR-19 "Documentation: README, API docs, user guide"

**Tasks:**
- [ ] Create USER_GUIDE.md with:
  - Setup walkthrough (with screenshots)
  - Configuration examples
  - Troubleshooting common issues
  - Privacy and legal considerations
  - Customizing prompts and templates
- [ ] Add to README

**Priority:** Medium

### 12.2 API Documentation
**Status:** Code comments exist but no generated docs

**Tasks:**
- [ ] Add DocC documentation comments to public APIs
- [ ] Generate documentation: `swift package generate-documentation`
- [ ] Host or include in repo

**Priority:** Low

---

## 13. Plugin System - Future Extensions

### 13.1 Plugin Discovery (FR-6.4)
**Status:** Not implemented (Bear is hardcoded)  
**Spec Reference:** "Plugin discovery: Load from `~/.meetingscribe/plugins/`"

**Tasks:**
- [ ] Design plugin bundle format (`.meetingscribe-plugin`)
- [ ] Implement plugin loading from directory
- [ ] Plugin registry/manifest system
- [ ] Dynamic plugin selection in config

**Priority:** Very Low (Phase 3 feature)

### 13.2 Additional Backend Plugins
**Status:** Only Bear implemented  
**Spec Future Plugins:** Notion, Obsidian, Apple Notes, Evernote

**Tasks:**
- [ ] Notion plugin (requires Notion API integration)
- [ ] Obsidian plugin (file-based, simpler)
- [ ] Apple Notes plugin (via ScriptingBridge)

**Priority:** Very Low (Phase 3 feature)

---

## 14. Performance & Reliability

### 14.1 Performance Testing (NFR-1 to NFR-5)
**Status:** Not formally tested against spec requirements

**Spec Requirements:**
- CPU usage <5% during recording
- Memory usage <200MB total
- Transcription start within 5 seconds
- Notes generation within 30 seconds
- UI responsiveness <500ms

**Tasks:**
- [ ] Create performance benchmarking script
- [ ] Monitor CPU/memory during long recordings
- [ ] Measure transcription time for typical meetings (30 min, 1 hour)
- [ ] Measure notes generation time
- [ ] Validate against spec thresholds

**Priority:** Medium

### 14.2 Log Rotation (Section: Error Notification Strategy)
**Status:** Logs grow unbounded  
**Spec Requirement:** "Log rotation (keep last 7 days)"  
**Reference:** Line 599

**Tasks:**
- [ ] Implement log rotation in DualLogger or via external tool
- [ ] Delete logs older than 7 days on startup
- [ ] Configure LaunchAgent to handle log size limits

**Priority:** Low

---

## 15. Privacy & Security

### 15.1 Privacy Policy (NFR-13)
**Status:** Brief warning in README, no formal policy  
**Spec Requirement:** "Clear privacy policy and consent mechanism"

**Tasks:**
- [ ] Draft PRIVACY.md document
- [ ] Explain what data is captured and where it's stored
- [ ] Explain what data is sent to APIs (transcripts to OpenAI/Anthropic)
- [ ] Add consent dialog on first run (optional)

**Priority:** High (especially if distributing publicly)

### 15.2 Audio Encryption at Rest (NFR-11)
**Status:** Not implemented (noted as "optional, future" in spec)  
**Spec Reference:** Line 357

**Tasks:**
- [ ] Research macOS FileVault vs app-level encryption
- [ ] Implement AES encryption for WAV files (optional)
- [ ] Store encryption key in Keychain

**Priority:** Very Low (Phase 4 feature)

---

## 16. Known Bugs / Issues

### 16.1 Main Service Audio Capture Integration
**Status:** ✅ COMPLETED  
**Description:** Audio capture is now integrated with call detection.

See **Section 2.1** above.

### 16.2 Transcript/Notes Placeholders in main.swift
**Status:** ✅ COMPLETED  
**Location:** `main.swift` lines 181-188  
**Description:** Transcription and notes generation are now using real API calls.

**Completed Tasks:**
- [x] Uncomment actual API calls
- [x] Remove placeholder strings

**Remaining:**
- [ ] Test with real audio files and API keys

**Priority:** Testing needed

---

## 17. End-to-End Testing Requirements

### 17.1 Prerequisites for Testing
**Status:** Required before testing  

**Tasks:**
- [ ] Set up API keys in macOS Keychain:
  ```bash
  # OpenAI API Key (for Whisper transcription)
  security add-generic-password -a "$USER" -s "MeetingScribe-OpenAI-Key" -w "YOUR_OPENAI_KEY"
  
  # Anthropic API Key (for Claude notes generation)
  security add-generic-password -a "$USER" -s "MeetingScribe-Anthropic-Key" -w "YOUR_ANTHROPIC_KEY"
  ```
- [ ] Grant Screen Recording permission to the app
- [ ] Grant Microphone permission (optional but recommended)
- [ ] Ensure output directory exists and is writable
- [ ] Have Teams or Zoom installed and ready for test call

**Priority:** HIGH - Required for testing

### 17.2 Manual Test Plan
**Status:** Ready to execute  

**Test Scenarios:**

1. **Build and Run**
   - [ ] Build: `swift build`
   - [ ] Run directly: `./.build/debug/meetingscribe`
   - [ ] Check logs: `tail -f ~/Library/Logs/MeetingScribe/stderr.log`
   - [ ] Verify menu bar icon appears

2. **Manual Recording Test**
   - [ ] Click menu bar icon > "Start Recording"
   - [ ] Play audio from any source (e.g., YouTube video)
   - [ ] Wait 30-60 seconds
   - [ ] Click menu bar icon > "Stop Recording"
   - [ ] Check for WAV file in `~/Documents/MeetingScribe/recordings/`
   - [ ] Monitor logs for transcription/notes generation
   - [ ] Verify notes saved to Bear or fallback directory

3. **Automatic Teams Detection Test**
   - [ ] Start the service
   - [ ] Join a Teams meeting (or test call)
   - [ ] Verify notification: "Recording Started"
   - [ ] Participate in meeting briefly
   - [ ] Leave Teams meeting
   - [ ] Verify notification: "Processing Meeting"
   - [ ] Wait for processing to complete
   - [ ] Check Bear for meeting notes

4. **Error Handling Tests**
   - [ ] Test without API keys configured (should error gracefully)
   - [ ] Test with invalid API keys (should report error)
   - [ ] Test without screen recording permission (should prompt)
   - [ ] Test when Bear is not installed (should fallback to file)

**Priority:** HIGH

### 17.3 Known Issues to Watch For

1. **Audio File Path Timing**
   - The audio file path is constructed immediately when capture starts, but the file may not exist until capture stops and finalizes
   - May need to add a small delay or verification that file exists before transcription

2. **Async Stop and Process Race Condition** ✅ FIXED
   - ~~`stopAudioCapture()` calls `stopCapture()` and then immediately starts processing~~
   - Now uses `stopAudioCaptureAndProcess()` which waits for file finalization before processing
   - Added file existence check before transcription

3. **ScreenCaptureKit Permission Prompts**
   - First run will require permission grants
   - App may need to be restarted after permissions granted

4. **Audio Output Directory** ✅ IMPROVED
   - Default config uses `~/Documents/MeetingScribe/recordings/`
   - AudioCapture.swift falls back to `~/Library/Logs/AudioCapture/recordings/` if directory creation fails
   - Now creates the configured directory before starting capture
   - May still fall back if creation fails (permissions, etc.)

**Priority:** Testing recommended

---

## 18. Compliance & Legal

### 17.1 Recording Consent (User Responsibility)
**Status:** Warning in README, no technical enforcement  
**Spec Reference:** Lines 224-236 (Privacy & Legal section)

**Tasks:**
- [ ] Add prominent warning on first run
- [ ] Link to jurisdiction-specific recording laws
- [ ] Consider optional "announce recording" feature (Phase 2+)

**Priority:** High (user education, not technical)

---

## Phase 2 Features (From Spec Lines 721-727)

These are explicitly listed as future enhancements in the spec:

- [ ] Zoom call detection (improved)
- [ ] Audio quality monitoring
- [ ] Silence detection (auto-stop recording)
- [ ] Notes editing in-app
- [ ] Search recent meetings

**Priority:** Not for MVP

---

## Phase 3 Features (From Spec Lines 728-733)

- [ ] Plugin SDK documentation
- [ ] Additional plugins (Notion, Obsidian, Apple Notes)
- [ ] Custom template editor (GUI)

**Priority:** Not for MVP

---

## Phase 4 Features (From Spec Lines 734-740)

- [ ] Speaker diarization
- [ ] Action item extraction
- [ ] Meeting summaries dashboard
- [ ] Cloud sync
- [ ] Team collaboration

**Priority:** Not for MVP

---

## Summary of Critical TODOs for v1.0

To reach a production-ready v1.0 per the spec, prioritize these:

1. ~~**[CRITICAL]** Connect audio capture to call detection (Section 2.1)~~ ✅ DONE
2. ~~**[MEDIUM]** Local Whisper implementation (Section 3.1)~~ ✅ DONE
3. **[HIGH]** End-to-end testing with real calls (NEW)
4. **[HIGH]** First-run resource creation: templates, prompts (Section 7.1)
5. **[HIGH]** LaunchAgent username replacement (Section 9.1)
6. **[HIGH]** Manual testing checklist execution (Section 11.3)
7. **[HIGH]** Privacy policy (Section 15.1)
8. **[MEDIUM]** Preferences GUI (Section 6.3) - OR document JSON editing well
9. **[MEDIUM]** Performance validation (Section 14.1)

Everything else can be deferred to v1.1+ or left as "nice to have."

---

## Contributing

When working on items from this TODO:
1. Check off items as completed: `- [x]`
2. Add notes/blockers inline
3. Update this file with any newly discovered gaps
4. Reference the spec section for context

---

**Last Updated:** December 15, 2025  
**Spec Version:** 1.0 (MEETING-SCRIBE-PROJECT-SPEC.MD)
