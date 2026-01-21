# Outlook Integration Enhancements

## Overview
This document describes the enhancements made to the Outlook calendar participant resolution feature to improve logging, data extraction robustness, participant mapping, and diarization speaker guidance.

## Changes Made

### 1. Configuration
**New Config Option**: `participants.debugLogging`
- Type: Boolean (default: `false`)
- Purpose: Controls verbose debug logging for participant resolution
- Location: `src/config/ConfigManager.swift`

### 2. Enhanced Data Structures

#### New `Participant` Struct
```swift
struct Participant {
    let email: String
    let firstName: String
    let isMe: Bool
    let inferredRole: String?  // "remote", "local", or nil
}
```

#### Updated `MeetingParticipants` Struct
- Added `participants: [Participant]` field
- Maintains backward compatibility with existing `attendeeEmails` and `attendeeFirstNames` arrays
- Enhanced `formatForLLMContext()` with intelligent diarization guidance

### 3. Improved Logging

#### Always-On Info Logs
- ✓ Successfully retrieved user email from Outlook
- ✓ Found matching calendar event (recordId, attendeeCount)
- ✓ Extracted N attendee email(s) in X.XXs
- ✓ Successfully resolved N participant(s): Name (me) + Other Names
- ✗ Error conditions with clear reasons

#### Debug Logs (when `debugLogging: true`)
- User email address
- Event details (start, end, path)
- Extracted email list
- Participant mapping with roles

### 4. Hardened Data Extraction

#### File Validation
- Check file existence before extraction
- Validate file size (reject empty files)
- Log file paths for debugging

#### Retry Logic
- First attempt: standard `strings` command
- If empty: retry with `strings -a -n 4` (more aggressive)
- Log which extraction method was used

#### Error Handling
- Graceful failure for missing/corrupted files
- UTF-8 decoding validation
- Process execution error catching

### 5. Participant Mapping

#### Intelligent Role Assignment
- **1:1 meetings**: Remote participant marked as `"remote"`
- **Group meetings**: Remote participants have `nil` role (uncertain)
- **All meetings**: Local user always marked as `"local"`

#### Identity Matching
- Case-insensitive email comparison for "me" identification
- Ensures participant list always populated when extraction succeeds
- Fallback to email-based name derivation

### 6. Diarization Speaker Guidance

The LLM context now includes explicit, scenario-specific guidance:

#### For 1:1 Calls
```
Diarization speaker mapping guidance:
- This appears to be a 1:1 conversation between Dan (local user) and Pradeep (remote participant).
- Attempt to intelligently infer which diarized speaker (SPEAKER_00, SPEAKER_01, etc.) corresponds to the local user based on context clues.
- DO NOT assume SPEAKER_00 is always the local user - this varies by audio setup.
- Look for context like "I think...", "from my perspective...", or references that indicate the speaker's role.
- Once you've identified which speaker is likely the local user, map: Dan = that speaker, Pradeep = the other speaker.
```

#### For Group Calls
```
Diarization speaker mapping guidance:
- This is a group conversation with 4 participants including Dan (local) and 3 remote participant(s).
- Attempt to map diarized speakers (SPEAKER_00, SPEAKER_01, etc.) to actual participants based on conversation context.
- DO NOT assume SPEAKER_00 is the local user - analyze the content to infer speaker identity.
- If you cannot confidently map a speaker, you may provide likely mappings with a caveat about uncertainty.
- Participant list with emails for reference: Dan <dan.rohan@ibm.com> (me), Pradeep <pradeep.sekar1@ibm.com>, ...
```

#### For Solo Meetings
```
Diarization speaker mapping guidance:
- Only the local user (Dan) was detected in the calendar event.
- Any diarized speakers are likely all Dan, unless other voices are present in the audio.
```

## Testing

### Unit Tests Added/Updated
1. ✅ `testResolveParticipants_HappyPath_ReturnsCorrectParticipants` - Enhanced with participant structure validation
2. ✅ `testResolveParticipants_OneOnOneMeeting_MarksRemoteParticipant` - New test for 1:1 role mapping
3. ✅ `testMeetingParticipants_OneOnOne_ProvidesDiarizationGuidance` - New test for 1:1 LLM context
4. ✅ `testMeetingParticipants_FormatsContextCorrectly` - Updated for group meeting guidance
5. ✅ All existing tests updated to use new `participants` field

### Manual Testing Checklist
- [ ] Run app with Outlook installed and verify logs show clear participant resolution steps
- [ ] Test with 1:1 meeting and verify "remote" role assignment
- [ ] Test with group meeting and verify nil role for multiple participants
- [ ] Enable `debugLogging: true` and verify detailed logs appear
- [ ] Disable `debugLogging: false` and verify only info-level logs appear
- [ ] Test LLM notes generation with diarization to verify speaker mapping works

## Benefits

### For Users
- **Transparency**: Clear logs show exactly what participant data was found and from where
- **Reliability**: Retry logic and validation prevent silent failures
- **Accuracy**: Better diarization guidance helps LLM correctly attribute statements to speakers

### For Developers
- **Debuggability**: Detailed logs when needed, clean logs in production
- **Maintainability**: Well-structured participant data with clear role semantics
- **Testability**: Comprehensive test coverage with mocked dependencies

## Configuration Example

To enable debug logging, add to `~/.meetingscribe/config.json`:

```json
{
  "participants": {
    "enabled": true,
    "outlookDatabasePath": "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/",
    "debugLogging": true
  }
}
```

## Migration Notes

### Backward Compatibility
The changes are fully backward compatible:
- Existing `attendeeEmails` and `attendeeFirstNames` arrays are maintained
- New `participants` field is additive
- Existing code using `formatForLLMContext()` continues to work

### Breaking Changes
None - this is a purely additive enhancement.

## Future Improvements

Potential enhancements for future iterations:
1. Support for other calendar systems (Apple Calendar, Google Calendar)
2. Machine learning-based speaker identification
3. Caching of participant data to reduce database queries
4. Voice profile matching for automatic speaker identification
5. Integration with contact management systems for richer participant metadata
