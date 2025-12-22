# PREFERENCES-UI.md

## Overview
This document specifies the Preferences Window UI for MeetingScribe, a macOS menubar application. The preferences window uses a tabbed interface to organize configuration settings across multiple categories.

## Window Specifications

### Window Properties
- **Type**: Standard macOS preferences window (non-modal, single instance)
- **Size**: 600px width × 500px height (minimum), resizable
- **Activation**: Launched from menubar menu item "Preferences..." (⌘,)
- **Instance Management**: Only one preferences window can be open at a time. If already open, bring to front.

### Window Controls
- **Title**: "MeetingScribe Preferences"
- **Bottom Bar** (fixed, always visible):
  - Left side: Empty
  - Right side: Two buttons
    - "Cancel" button: Discards all changes, closes window
    - "Save" button: Validates and saves all changes, closes window on success

### Tab Structure
Tabs appear at the top of the window in this order:
1. General
2. Audio
3. Detection
4. Transcription
5. Notes
6. LLM Providers
7. Template Editor
8. Log Viewer

---

## Tab 1: General

### Section: UI Preferences
**Path in config**: `ui`

All fields are required.

| Field Label | Config Key | Type | Default | Notes |
|-------------|-----------|------|---------|-------|
| Show Notifications | `showNotifications` | Checkbox | true | Master toggle |
| Notify on Recording Start | `notifyOnStart` | Checkbox | true | Indented/dependent on showNotifications |
| Notify on Recording End | `notifyOnEnd` | Checkbox | true | Indented/dependent on showNotifications |
| Auto-Recording Enabled | `autoRecordingEnabled` | Checkbox | true | |

**Validation**:
- None required (all boolean values)

**Behavior**:
- When `showNotifications` is unchecked, disable (gray out) `notifyOnStart` and `notifyOnEnd` checkboxes

---

## Tab 2: Audio

### Section: Audio Recording Settings
**Path in config**: `audio`

All fields are required.

| Field Label | Config Key | Type | Validation | Notes |
|-------------|-----------|------|------------|-------|
| Sample Rate (Hz) | `sampleRate` | Number field | Integer, > 0, common values: 44100, 48000 | Provide dropdown with common values + "Custom" option |
| Bit Depth | `bitDepth` | Number field | Integer, must be 8, 16, 24, or 32 | Dropdown with these options |
| Channels | `channels` | Number field | Integer, 1 (Mono) or 2 (Stereo) | Dropdown: "Mono (1)" and "Stereo (2)" |
| Output Directory | `outputDirectory` | Path field with browse button | Must be valid directory path, tilde expansion supported | Shows "Choose Folder..." button |

**Validation**:
- Sample Rate: Must be positive integer
- Bit Depth: Must be exactly 8, 16, 24, or 32
- Channels: Must be 1 or 2
- Output Directory: Non-empty, warn if directory doesn't exist (but allow save)

**Path Field Behavior**:
- Display text field with current path
- "Browse..." button opens NSOpenPanel configured for directories
- Support tilde (`~`) expansion in display
- Create directory if it doesn't exist when "Save" is clicked (prompt user first)

---

## Tab 3: Detection

### Section: Meeting Detection Settings
**Path in config**: `detection`

All fields are required.

| Field Label | Config Key | Type | Validation | Notes |
|-------------|-----------|------|------------|-------|
| Poll Interval (seconds) | `pollInterval` | Number field | Integer, ≥ 1 | How often to check for meetings |
| Confidence Threshold (%) | `confidenceThreshold` | Number field | Integer, 0-100 | Slider with number field |
| Debounce Checks | `debounceChecks` | Number field | Integer, ≥ 1 | Number of consistent checks required |

**Validation**:
- Poll Interval: Integer, minimum 1
- Confidence Threshold: Integer, 0-100 inclusive
- Debounce Checks: Integer, minimum 1

**UI Pattern**:
- Confidence Threshold: Use slider (0-100) with adjacent number field (synced bidirectionally)

---

## Tab 4: Transcription

### Section: Transcription Provider
**Path in config**: `transcription.provider`

User selects ONE provider (radio buttons or segmented control):
- **Local** (whisper.cpp)
- **OpenAI**

Based on selection, show only relevant settings below.

### Subsection: Local Transcription Settings
**Path in config**: `transcription.local`

Shown when provider = "local". All fields required.

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Whisper Binary Path | `whisperBinaryPath` | Path field + browse | File must exist, executable |
| Model Path | `modelPath` | Path field + browse | File must exist, .bin extension |

### Subsection: OpenAI Transcription Settings
**Path in config**: `transcription.openai`

Shown when provider = "openai". All fields required.

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| API Key | `apiKey` | Text field (visible) | Non-empty string |
| Model | `model` | Text field | Non-empty, default "whisper-1" |

**Additional Controls**:
- "Test Connection" button next to API Key: Validates API key with OpenAI API

### Subsection: Diarization Settings (Advanced)
**Path in config**: `transcription.diarization`

Collapsible/expandable section (disclosure group). Optional feature.

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Enable Diarization | `enabled` | Checkbox | Boolean |
| HuggingFace Token | `hfToken` | Text field | Required if enabled is true |
| Python Path | `pythonPath` | Path field + browse | Required if enabled, must be executable |
| Diarization Script Path | `scriptPath` | Path field + browse | Required if enabled, must exist |
| Whisper Model | `whisperModel` | Dropdown | Options: tiny, base, small, medium, large |
| Distance Threshold | `distanceThreshold` | Number field | Float, 0.0-1.0 |

**Validation**:
- When `enabled` is true: hfToken, pythonPath, scriptPath all required
- When `enabled` is false: other fields optional but preserved

---

## Tab 5: Notes

### Section: Notes Backend
**Path in config**: `notes.backend`

User selects ONE backend (dropdown or radio buttons):
- **Bear**

Currently only Bear is supported. Design UI to easily add more backends later.

### Subsection: Bear Settings
**Path in config**: `notes.bear`

Shown when backend = "bear". All fields required.

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Tags | `tags` | Tag input field | Array of strings, each starting with # |
| Fallback Directory | `fallbackDirectory` | Path field + browse | Valid directory path |

**Tag Input Behavior**:
- Display tags as chips/tokens
- Allow adding tags (auto-prepend # if user forgets)
- Allow removing tags (X button on each chip)
- At least one tag should be present (warn if empty)

### Section: Template File
**Path in config**: `notes.templateFile`

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Template File Path | `templateFile` | Path field + browse | File path, .md extension recommended |

**Additional Controls**:
- "Edit Template" button: Opens Tab 7 (Template Editor) and loads this file

---

## Tab 6: LLM Providers

### Section: LLM Configuration
**Path in config**: `notes.llm`

**Important**: Users can enable MULTIPLE LLM providers simultaneously. Each provider has an "Enabled" checkbox.

### Subsection: System Prompt
**Path in config**: `notes.llm.systemPromptFile`

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| System Prompt File | `systemPromptFile` | Path field + browse | File path, must exist |

### Subsection: Anthropic
**Path in config**: `notes.llm.anthropic`

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Enable Anthropic | N/A (derived from config) | Checkbox | Boolean |
| API Key | `apiKey` | Text field (visible) | Required if enabled |
| Model | `model` | Dropdown or text | Required if enabled, default "claude-sonnet-4-5" |

**Additional Controls**:
- "Test API Key" button: Makes test API call to verify key

**Model Dropdown Options**:
- claude-sonnet-4-5
- claude-opus-4
- claude-haiku-4
- Custom (text input)

### Subsection: OpenAI
**Path in config**: `notes.llm.openai`

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Enable OpenAI | N/A (derived) | Checkbox | Boolean |
| API Key | `apiKey` | Text field (visible) | Required if enabled |
| Model | `model` | Dropdown or text | Required if enabled, default "gpt-4" |

**Additional Controls**:
- "Test API Key" button: Makes test API call

**Model Dropdown Options**:
- gpt-4
- gpt-4-turbo
- gpt-3.5-turbo
- Custom (text input)

### Subsection: Ollama
**Path in config**: `notes.llm.ollama`

| Field Label | Config Key | Type | Validation |
|-------------|-----------|------|------------|
| Enable Ollama | N/A (derived) | Checkbox | Boolean |
| Endpoint | `endpoint` | Text field | Required if enabled, valid URL format |
| Model | `model` | Text field | Required if enabled, default "llama3" |

**Additional Controls**:
- "Test Connection" button: Verifies endpoint is reachable

**Validation**:
- At least ONE LLM provider must be enabled
- For each enabled provider, all required fields must be filled
- API keys: non-empty strings when provider enabled
- Ollama endpoint: valid URL format (http:// or https://)

**UI Layout**:
Each provider subsection should be visually separated (boxes or dividers) with the "Enable [Provider]" checkbox at the top of each box. When unchecked, gray out that provider's fields.

---

## Tab 7: Template Editor

### Section: Markdown Template Editor
**Path in config**: Loads file from `notes.templateFile`

| Component | Description |
|-----------|-------------|
| File Path Display | Read-only text showing current template file path |
| Text Editor | Multi-line text editor for markdown content |
| Syntax | Markdown with support for variables/placeholders |

**Editor Features**:
- Monospaced font
- Line numbers (optional but nice)
- Syntax highlighting for markdown (optional)
- Minimum 300px height, expandable

**Behavior**:
- Load template file content when tab opens or when switched to
- If file doesn't exist, show empty editor with placeholder text: "Template file not found. Content will be saved to specified path on Save."
- Changes are in-memory until "Save" button clicked
- On Save: Write editor content to file specified in `notes.templateFile`

**Validation**:
- Warn if template file path is empty (show message in editor area)
- Allow saving even if file doesn't exist yet (will create it)

## Tab 8: Log Viewer
*Thinking...*

> The user wants me to add a section for a Log Viewer tab to the spec. This should be added to the tab structure and then detailed as a section. Let me add this as Tab 8 and create a specification for it.
> 
> I should include:
> - Tab order update
> - What logs to show
> - How to display them
> - Filtering/searching capabilities
> - Auto-refresh options
> - Export/clear functionality
> - Log levels
> - Timestamp format
> 
> Since this is a Mac app for meeting transcription/recording, the logs would likely include:
> - Meeting detection events
> - Recording start/stop
> - Transcription progress
> - API calls/errors
> - File operations
> - Configuration changes
> 
> I'll make it practical and useful for debugging while keeping it simple for the initial implementation.

# Addition to PREFERENCES-UI.md

## Updated Tab Structure
Tabs appear at the top of the window in this order:
1. General
2. Audio
3. Detection
4. Transcription
5. Notes
6. LLM Providers
7. Template Editor
8. **Log Viewer**

---

## Tab 8: Log Viewer

### Section: Application Logs
Display real-time and historical application logs for debugging and monitoring.

**Layout**:
- Top toolbar with controls
- Main log display area (scrollable text view)
- Bottom status bar showing log count and last update time

### Toolbar Controls

| Control | Type | Purpose |
|---------|------|---------|
| Search Field | Search box | Filter logs by text content (live search) |
| Auto-scroll | Checkbox | Auto-scroll to bottom as new logs arrive (default: on) |
| Clear | Button | Clear current log display (doesn't delete log files) |

### Log Display Area

**Format**: Monospaced font (SF Mono or Menlo), each log entry on separate line


**Example**:
```
[2024-12-22 14:32:15] [INFO] [Detection] Meeting detected: Team Standup
[2024-12-22 14:32:16] [INFO] [Recording] Started recording to ~/Documents/MeetingScribe/recordings/2024-12-22_143215.wav
[2024-12-22 14:32:16] [DEBUG] [Audio] Sample rate: 48000Hz, Bit depth: 16, Channels: 2
[2024-12-22 14:35:42] [INFO] [Recording] Stopped recording (duration: 3m 27s)
[2024-12-22 14:35:43] [INFO] [Transcription] Starting transcription with provider: local
[2024-12-22 14:36:12] [INFO] [Transcription] Transcription complete
[2024-12-22 14:36:13] [INFO] [LLM] Generating notes with provider: anthropic
[2024-12-22 14:36:45] [INFO] [Notes] Note created in Bear with tags: #meetings, #teams
[2024-12-22 14:36:45] [ERROR] [API] OpenAI API key test failed: Invalid API key
```

**Color Coding**:
- DEBUG: Gray
- INFO: Default text color
- WARNING: Orange
- ERROR: Red

### Behavior

**Real-time Updates**:
- Tail log file in real-time (1 second refresh interval)
- Show new entries as they arrive
- Max display: Last 1000 entries (configurable )
- Auto-scroll when enabled and user hasn't manually scrolled up

**Search**:
- Filter logs containing search text (case-insensitive)
- Highlight matching text in results
- Search applies to all fields (timestamp, level, component, message)

**Clear**:
- Clears display only (doesn't delete log files)
- Show confirmation: "Clear log display? (Log files will not be deleted)"

### Bottom Status Bar

Display:
- Left side: "Showing X of Y entries" (X = filtered, Y = total in current session)
- Right side: "Last updated: [timestamp]"



### Implementation Notes

**Performance**:
- Use virtualized/lazy loading for large log files
- Limit in-memory logs to prevent memory bloat
- Async file reading to avoid UI blocking

**Log Writing**:
- Application should write logs to file asynchronously
- Use unified logging system (os_log) or custom logger
- Thread-safe log writing

**Error Handling**:
- If log file can't be read, show error message in display area
- Gracefully handle corrupted log entries


---

## Validation & Error Handling

### Field-Level Validation
- **On Change**: Validate individual fields as user types/changes values
- **Visual Indicators**: 
  - Invalid fields: Red border or red text below field with error message
  - Valid fields: Normal appearance
  - Required but empty: Yellow/warning indicator

### Save-Time Validation
When "Save" button clicked:

1. **Validate all required fields** across all tabs
2. **Check provider-specific requirements**:
   - At least one LLM provider enabled with complete config
   - Transcription provider selected with complete config
   - Notes backend selected with complete config
3. **If validation fails**:
   - Show alert dialog listing all errors
   - Switch to first tab containing error
   - Highlight invalid fields
   - Do NOT close window
4. **If validation succeeds**:
   - Write config to disk (JSON file)
   - Close preferences window
   - Notify main app to reload config

### Test Button Behavior
For API key "Test" buttons:

1. Show loading spinner/indicator on button
2. Make minimal API call (e.g., list models, verify credentials)
3. Show result:
   - Success: Green checkmark icon + "Connected successfully"
   - Failure: Red X icon + error message from API
4. Display result for 3 seconds or until field changes

---

## Data Persistence

### Config File Location
`~/.meetingscribe/config.json`

### Save Operation
1. Collect all form values
2. Construct JSON object matching config structure
3. Expand tilde (`~`) to actual home directory path before saving
4. Write atomically (write to temp file, then move)
5. Preserve any config keys not shown in UI

### Load Operation
1. Read config file on window open
2. Parse JSON
3. Populate all form fields with values
4. Handle missing keys with sensible defaults (or show as empty/unchecked)

### Dirty State Tracking
- Track whether any changes made since window opened
- On window close (via X button or Cancel): 
  - If dirty, show "Discard changes?" confirmation dialog
  - If not dirty, close immediately

---

## UI Guidelines

### macOS Design Patterns
- Use standard macOS controls (NSButton, NSTextField, NSSegmentedControl, etc.)
- Follow HIG spacing: 8px between related items, 20px between sections
- Right-align field labels, left-align inputs (standard macOS form layout)
- Use system fonts

### Accessibility
- All controls must have accessibility labels
- Support keyboard navigation (Tab between fields)
- Form inputs announce validation errors to screen readers

### Visual Hierarchy
- Section headers: 13pt Bold
- Field labels: 11pt Regular
- Help text: 10pt Secondary color
- Adequate whitespace between sections

---

## Edge Cases

1. **Config file doesn't exist**: Create default config on first save
2. **Config file corrupted**: Show error, load defaults, allow user to reconfigure
3. **Paths with spaces or special characters**: Handle properly, use proper escaping
4. **Very long paths**: Truncate in UI with ellipsis, show full path on hover
5. **File/directory doesn't exist**: Allow save but warn user, offer to create
6. **Multiple LLMs enabled, all API keys invalid**: Allow save, but warn that transcription may fail
7. **Template file too large**: No limit for now, but consider warning for files >1MB

---

## Implementation Notes

### Technology Recommendation
- **SwiftUI**: Preferred for modern Swift apps, easier state management
- **AppKit**: If existing codebase uses AppKit

### State Management
- Use `@State` or `@Published` properties for form fields
- Implement two-way binding to config model
- Track original vs. current state for dirty checking

### File Operations
- Use `FileManager` for path operations
- Implement proper error handling for I/O operations
- Support path expansion (tilde to home directory)

### Thread Safety
- File I/O should be async/background thread
- UI updates on main thread
- Show loading states for async operations (Test buttons, Save operation)

### Other features
- Reset to defaults button (see below)
- Config profiles/presets
- Inline help tooltips
- Advanced mode toggle (hides complex settings)
- Log viewer tab


### Defauult settings:
 Below is a default configuration file:

 ```
 {
  "audio" : {
    "bitDepth" : 16,
    "channels" : 2,
    "outputDirectory" : "~\/Documents\/MeetingScribe\/recordings\/",
    "sampleRate" : 48000
  },
  "detection" : {
    "confidenceThreshold" : 85,
    "debounceChecks" : 2,
    "pollInterval" : 2
  },
  "notes" : {
    "backend" : "bear",
    "bear" : {
      "fallbackDirectory" : "~\/Documents\/MeetingScribe\/notes\/",
      "tags" : [
        "#meetings",
        "#teams"
      ]
    },
    "llm" : {
      "anthropic" : {
        "apiKey" : "",
        "model" : "claude-sonnet-4-5"
      },
      "ollama" : {
        "endpoint" : "http:\/\/localhost:11434",
        "model" : "llama3"
      },
      "openai" : {
        "apiKey" : "",
        "model" : "gpt-4"
      },
      "provider" : "anthropic",
      "systemPromptFile" : "~\/.meetingscribe\/prompts\/default.txt"
    },
    "templateFile" : "~\/.meetingscribe\/templates\/default.md"
  },
  "transcription" : {
    "diarization" : {
      "distanceThreshold" : 0.9,
      "enabled" : false,
      "hfToken" : "",
      "pythonPath" : "python3",
      "scriptPath" : "/Applications/MeetingScribe.app/Contents/Resources/scripts/diarize_audio_fast.py",
      "whisperModel" : ""
    },
    "local" : {
      "modelPath" : ",
      "whisperBinaryPath" : ""
    },
    "openai" : {
      "apiKey" : "",
      "model" : "whisper-1"
    },
    "provider" : "local"
  },
  "ui" : {
    "autoRecordingEnabled" : true,
    "notifyOnEnd" : true,
    "notifyOnStart" : true,
    "showNotifications" : true
  },
  "version" : "1.0"
}
```