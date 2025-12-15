# MeetingScribe Testing Guide

## ✅ Build Status
- **Build:** SUCCESSFUL
- **Warnings:** Deprecated NSUserNotification API (cosmetic, works on macOS 13)
- **Binary:** `.build/debug/meetingscribe`

## Critical Fixes Completed

1. ✅ **Audio capture integration** - Now properly connected to call detection
2. ✅ **Race condition fix** - Audio finalization waits before processing
3. ✅ **File existence check** - Validates audio file before transcription
4. ✅ **Real API calls** - Transcription and notes generation no longer use placeholders
5. ✅ **Output directory** - Creates configured directory before capture
6. ✅ **Local Whisper** - Uses local whisper.cpp, no OpenAI API key needed for transcription

## Prerequisites for Testing

### 1. Set Up API Keys

You need Anthropic API key for notes generation. Transcription now uses local whisper.cpp (no OpenAI key needed).

```bash
# Anthropic API Key (for Claude notes generation)
security add-generic-password -a "$USER" -s "MeetingScribe-Anthropic-Key" -w "YOUR_ANTHROPIC_KEY"
```

To verify key is stored:
```bash
security find-generic-password -a "$USER" -s "MeetingScribe-Anthropic-Key" -w
```

**Note:** Transcription uses local whisper.cpp by default. No OpenAI API key required.

### 2. Create Output Directories

```bash
mkdir -p ~/Documents/MeetingScribe/recordings
mkdir -p ~/Documents/MeetingScribe/notes
mkdir -p ~/.meetingscribe
```

### 3. Check Configuration

The default configuration is created at `~/.meetingscribe/config.json` on first run. You can review and modify it:

```bash
cat ~/.meetingscribe/config.json
```

## Test Plan

### Test 1: Basic Build and Run ✅

```bash
# Run from project directory
cd "/Users/dan.rohan/My Drive/software_projects/meeting-scribe"

# Run the binary
./.build/debug/meetingscribe
```

**Expected Results:**
- Menu bar icon appears (microphone icon)
- No errors in terminal
- App stays running

**To monitor logs in another terminal:**
```bash
tail -f ~/Library/Logs/MeetingScribe/stderr.log
```

### Test 2: Manual Recording (Recommended First Test)

This test doesn't require Teams/Zoom and verifies the full pipeline.

**Steps:**
1. Run the app: `./.build/debug/meetingscribe`
2. Click the menu bar icon
3. Select "Start Recording"
4. Play audio from any source:
   - Open YouTube in browser and play a video
   - Or use system audio test: `afplay /System/Library/Sounds/Sosumi.aiff`
5. Let it record for 30-60 seconds
6. Click menu bar icon again
7. Select "Stop Recording"

**Expected Results:**
- Notification: "Recording Started"
- Menu bar icon changes to filled microphone
- After stopping:
  - Notification: "Processing Meeting"
  - WAV file created in `~/Documents/MeetingScribe/recordings/meeting_YYYY-MM-DD_HH-MM-SS_system.wav`
  - Logs show transcription progress
  - Logs show notes generation progress
  - Notification: "Notes Ready" or "Saved to Bear"/"Saved to fallback directory"
  - Notes file in Bear or `~/Documents/MeetingScribe/notes/`

**Debug if it fails:**
```bash
# Check for audio file
ls -lh ~/Documents/MeetingScribe/recordings/

# Check logs
tail -100 ~/Library/Logs/MeetingScribe/stderr.log

# Check if Bear is running (affects save location)
ps aux | grep Bear
```

### Test 3: Permissions Check

On first run, macOS will prompt for permissions:

**Screen Recording Permission:**
- Go to System Settings > Privacy & Security > Screen Recording
- Find and enable `meetingscribe`
- Restart the app

**Microphone Permission (optional but recommended):**
- Go to System Settings > Privacy & Security > Microphone  
- Find and enable `meetingscribe`
- Restart the app

**To test permissions programmatically:**
```bash
# After running once, check:
tail -20 ~/Library/Logs/MeetingScribe/stderr.log | grep -i permission
```

### Test 4: Teams/Zoom Detection (Advanced)

**Requirements:**
- Teams or Zoom installed
- Active meeting or test call

**Steps:**
1. Start MeetingScribe
2. Join a Teams meeting
3. Speak/listen for a minute
4. Leave the meeting

**Expected Results:**
- Notification when meeting starts: "Recording Started"
- Automatic audio capture
- Notification when meeting ends: "Processing Meeting"
- Transcription and notes generated automatically

## Troubleshooting

### Issue: No audio file created

**Check:**
1. Screen Recording permission granted?
2. Application (Teams/Zoom/Chrome) was actually running?
3. Check alternative output location: `ls ~/Library/Logs/AudioCapture/recordings/`

### Issue: "Processing Failed: No audio file was recorded"

**Possible causes:**
- Permissions not granted
- Output directory not writable
- Race condition (file not finalized yet)

**Fix:**
- Grant permissions and restart
- Check logs for specific error

### Issue: "API error" during transcription/notes

**Check:**
1. API keys correctly stored in Keychain
2. API keys are valid and have credits
3. Network connectivity

```bash
# Test Anthropic API  
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: $(security find-generic-password -a "$USER" -s "MeetingScribe-Anthropic-Key" -w)" \
  -H "anthropic-version: 2023-06-01"

# Test local whisper.cpp
"~/My Drive/software_projects/whisper.cpp/main" --help
ls -lh "~/My Drive/software_projects/whisper.cpp/models/ggml-base.en.bin"
```

### Issue: Build errors

**Common fixes:**
```bash
# Clean and rebuild
swift package clean
swift build

# If still failing, check Swift version
swift --version  # Should be 5.9+
```

### Issue: Menu bar icon not appearing

**Possible causes:**
- App crashed on startup
- NSApplication not running

**Check:**
```bash
# Look for crash logs
ls -lh ~/Library/Logs/DiagnosticReports/meetingscribe*

# Check if process is running
ps aux | grep meetingscribe
```

## Known Limitations

1. **First run requires restart** - After granting permissions, restart the app
2. **Manual recording fallback** - For manual mode, tries to find Teams/Zoom or falls back to Chrome/Safari
3. **No preferences GUI** - Must edit `~/.meetingscribe/config.json` manually
4. **Deprecated notifications** - Uses NSUserNotification (works but shows warnings)
5. **Whisper.cpp required** - Local whisper binary must be at `~/My Drive/software_projects/whisper.cpp/main`

## Success Criteria

✅ The system works if:
1. Build completes without errors
2. App runs and menu bar icon appears
3. Manual recording captures audio to WAV file
4. Transcription completes and produces text
5. Notes generation completes and produces markdown
6. Notes saved to Bear or fallback directory

## Next Steps After Testing

If all tests pass:
1. Test with real Teams meeting
2. Verify notes quality
3. Set up as LaunchAgent for auto-start: `./scripts/install.sh`
4. Add default templates and prompts (see TODO.md Section 7.1)
5. Create privacy policy (see TODO.md Section 15.1)

## Support

If you encounter issues:
1. Check logs: `~/Library/Logs/MeetingScribe/stderr.log`
2. Review TODO.md for known issues
3. Check that all prerequisites are met
4. Verify API keys and permissions

---

**Last Updated:** December 15, 2025  
**Build:** DEBUG  
**Status:** Ready for Manual Testing
