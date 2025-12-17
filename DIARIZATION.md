# Speaker Diarization Setup Guide

This guide explains how to enable speaker diarization in MeetingScribe, which automatically identifies different speakers in your meeting transcripts.

## What is Speaker Diarization?

Speaker diarization is the process of identifying "who spoke when" in an audio recording. With diarization enabled, your transcripts will show labels like:

```
SPEAKER_00: Hi, Lori. Glad you're here.
SPEAKER_01: Thanks.
SPEAKER_00: I think I can second a lot of stuff that Jim said...
SPEAKER_02: I agree completely.
```

Instead of a wall of undifferentiated text.

## Requirements

### 1. Python 3.9 or Later

Check if you have Python installed:

```bash
python3 --version
```

If not installed, download from [python.org](https://www.python.org/downloads/) or install via Homebrew:

```bash
brew install python3
```

### 2. Install Python Dependencies

Navigate to the MeetingScribe directory and install the required packages:

```bash
cd ~/My\ Drive/software_projects/meeting-scribe
pip3 install -r scripts/requirements-diarization.txt
```

This will install:
- PyTorch (with Mac Metal/MPS support)
- pyannote.audio (speaker diarization models)
- openai-whisper (speech recognition)

**Note:** The initial installation downloads several GB of models. Be patient!

### 3. HuggingFace Account Setup

Speaker diarization uses models from HuggingFace that require authentication.

#### Step 1: Create a HuggingFace Account

1. Go to [huggingface.co](https://huggingface.co) and sign up (it's free)
2. Verify your email address

#### Step 2: Accept Model User Agreements

You must accept the terms for these models:

1. Visit [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   - Click "Agree and access repository"
   - Fill out the form if prompted

2. Visit [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   - Click "Agree and access repository"
   - Fill out the form if prompted

**Important:** You must accept BOTH agreements, or diarization will fail with authentication errors.

#### Step 3: Generate Access Token

1. Go to [HuggingFace Settings > Access Tokens](https://huggingface.co/settings/tokens)
2. Click "New token"
3. Name it something like "meetingscribe"
4. Select "Read" permissions (write not needed)
5. Click "Generate token"
6. **Copy the token immediately** - you won't be able to see it again!

## Configuration

### 1. Create or Edit Config File

Open or create `~/.meetingscribe/config.json`:

```bash
mkdir -p ~/.meetingscribe
vim ~/.meetingscribe/config.json
```

### 2. Add Diarization Configuration

Add this section to your config file under `transcription`:

```json
{
  "transcription": {
    "provider": "local",
    "diarization": {
      "enabled": true,
      "minSpeakers": 2,
      "maxSpeakers": 10,
      "hfToken": "hf_YOUR_TOKEN_HERE",
      "pythonPath": "/Applications/miniforge3/bin/python3",
      "scriptPath": "~/My Drive/software_projects/meeting-scribe/scripts/diarize_audio.py",
      "whisperModel": "base"
    }
  }
}
```

**Important Notes:**
- `pythonPath` must be the **full absolute path** to python3 (not just `python3`)
- Find your path with: `which python3`
- `maxSpeakers`: Set to 10 for larger meetings (supports 2-10 speakers)

**Configuration Options:**

- `enabled` (boolean): Turn diarization on/off
- `minSpeakers` (integer, optional): Minimum expected speakers (helps accuracy)
- `maxSpeakers` (integer, optional): Maximum expected speakers (helps accuracy)
- `hfToken` (string, **required**): Your HuggingFace access token
- `pythonPath` (string): Path to Python 3 executable (usually `python3`)
- `scriptPath` (string): Path to diarization script
- `whisperModel` (string): Whisper model size (`tiny`, `base`, `small`, `medium`, `large`)
  - `tiny`: Fastest, least accurate
  - `base`: Good balance (recommended)
  - `small`: Better accuracy, slower
  - `medium`/`large`: Best accuracy, much slower

### 3. Full Example Config

Here's a complete working configuration:

```json
{
  "version": "1.0",
  "transcription": {
    "provider": "local",
    "diarization": {
      "enabled": true,
      "minSpeakers": 2,
      "maxSpeakers": 10,
      "hfToken": "hf_abcdefghijklmnopqrstuvwxyz1234567890",
      "pythonPath": "/Applications/miniforge3/bin/python3",
      "scriptPath": "~/My Drive/software_projects/meeting-scribe/scripts/diarize_audio.py",
      "whisperModel": "base"
    },
    "local": {
      "modelPath": "~/My Drive/software_projects/whisper.cpp/models/ggml-base.en.bin",
      "whisperBinaryPath": "~/My Drive/software_projects/whisper.cpp/main"
    }
  }
}
```

## Testing

### Standalone Testing

Test the diarization script directly before using it with MeetingScribe:

```bash
cd ~/My\ Drive/software_projects/meeting-scribe
python3 scripts/diarize_audio.py \
  "/path/to/your/test/audio.wav" \
  --hf-token "hf_YOUR_TOKEN" \
  --whisper-model base \
  --min-speakers 2 \
  --max-speakers 4
```

You should see output like:

```
Using device: mps
Loading diarization pipeline...
Running speaker diarization on /path/to/audio.wav...
Detected 3 speaker(s): ['SPEAKER_00', 'SPEAKER_01', 'SPEAKER_02']
Loading Whisper model 'base' on cpu...
Transcribing /path/to/audio.wav...
Aligning transcription with speaker diarization...
Diarization complete!
```

### End-to-End Testing

1. Restart MeetingScribe:
   ```bash
   meetingscribe-ctl restart
   ```

2. Record a test meeting (or use manual recording)

3. Check the logs:
   ```bash
   tail -f ~/Library/Logs/MeetingScribe/stderr.log
   ```

4. Look for diarization messages like:
   ```
   Diarization enabled, attempting diarized transcription
   Running diarization script: /path/to/diarize_audio.py
   Diarization completed: 3 speakers detected
   ```

## Troubleshooting

### "Missing required dependency" Error

**Problem:** Python packages not installed

**Solution:**
```bash
pip3 install -r scripts/requirements-diarization.txt
```

### "Error loading diarization pipeline: 401 Client Error"

**Problem:** Invalid HuggingFace token or model agreements not accepted

**Solution:**
1. Verify your token is correct in `config.json`
2. Make sure you accepted agreements for BOTH models:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0
3. Generate a new token if needed

### "Diarization script not found"

**Problem:** Script path is incorrect

**Solution:**
Update `scriptPath` in your config to the correct absolute path:
```json
"scriptPath": "/Users/yourusername/My Drive/software_projects/meeting-scribe/scripts/diarize_audio.py"
```

### "python3 doesn't exist" or "FileNotFoundError: ffmpeg"

**Problem:** Python path not found or ffmpeg not in PATH

**Solution:**
1. Use **full absolute path** to python3 (not just `python3`):
   ```bash
   which python3  # Find your python path
   ```
2. Update config with full path:
   ```json
   "pythonPath": "/Applications/miniforge3/bin/python3"
   ```
3. The script automatically adds common ffmpeg locations to PATH, but if issues persist, ensure ffmpeg is installed:
   ```bash
   brew install ffmpeg
   ```

### Diarization is Very Slow

**Problem:** Running on CPU without GPU acceleration

**Solution:**
- On Mac with Apple Silicon, ensure PyTorch is using Metal (MPS)
- Check logs for "Using device: mps" (good) vs "Using device: cpu" (slower)
- For long meetings, consider using smaller Whisper model: `"whisperModel": "tiny"`

### Speaker Labels are Inaccurate

**Problem:** Diarization isn't detecting speakers correctly

**Solutions:**
1. Set `minSpeakers` and `maxSpeakers` to narrow the range
2. Check audio quality - poor audio affects accuracy
3. Try a larger Whisper model for better transcription: `"whisperModel": "small"`

### Diarization Falling Back to Standard Transcription

**Problem:** Diarization fails but app continues with non-diarized transcript

**Solution:**
- Check logs for specific error: `tail -f ~/Library/Logs/MeetingScribe/stderr.log`
- Common causes:
  - HuggingFace token missing or invalid
  - Python dependencies not installed
  - Insufficient disk space for model downloads

## Performance Notes

- **First run:** Downloads ~2-4GB of models (one-time)
- **Processing time:** ~2-5% of recording length with GPU
  - 1 hour meeting = 1.5-3 minutes processing
- **Memory usage:** ~2-4GB RAM during diarization
- **Mac Metal:** Apple Silicon Macs get significant speed boost via MPS

## Disabling Diarization

To temporarily disable diarization without removing the configuration:

```json
{
  "transcription": {
    "diarization": {
      "enabled": false
    }
  }
}
```

Then restart MeetingScribe:
```bash
meetingscribe-ctl restart
```

## Next Steps: Phase 2

Phase 1 provides generic speaker labels (SPEAKER_00, SPEAKER_01, etc.).

Phase 2 will add:
- **Local vs Remote detection:** Label "ME" for your voice vs "SPEAKER_00" for others
- **Actual speaker names:** Extract from meeting context or voice enrollment

Stay tuned for Phase 2 documentation!

## Getting Help

If you encounter issues:

1. Check logs: `tail -f ~/Library/Logs/MeetingScribe/stderr.log`
2. Test Python script standalone (see Testing section)
3. Verify all dependencies are installed
4. Confirm HuggingFace setup is complete
