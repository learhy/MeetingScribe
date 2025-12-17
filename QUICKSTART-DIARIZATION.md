# Quick Start: Enable Speaker Diarization

Get speaker labels in your transcripts in 5 minutes!

## Step 1: Install Python Dependencies

```bash
cd ~/My\ Drive/software_projects/meeting-scribe
pip3 install -r scripts/requirements-diarization.txt
```

⏱️ This takes 5-10 minutes and downloads ~2-4GB of models.

## Step 2: Get HuggingFace Token

1. Sign up at [huggingface.co](https://huggingface.co) (free)
2. Accept model agreements:
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
3. Generate token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

## Step 3: Update Config

Edit `~/.meetingscribe/config.json` and add:

```json
{
  "transcription": {
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

**Important:** Use the full path to python3. Find yours with: `which python3`

**Replace `hf_YOUR_TOKEN_HERE` with your actual token!**

## Step 4: Test It

```bash
# Rebuild and restart
cd ~/My\ Drive/software_projects/meeting-scribe
swift build
meetingscribe-ctl restart

# Record a test meeting
# Check logs
tail -f ~/Library/Logs/MeetingScribe/stderr.log
```

Look for:
```
Diarization enabled, attempting diarized transcription
Running diarization script...
Diarization completed: 3 speakers detected
```

## Result

Your transcripts will now look like:

```
SPEAKER_00: Hi everyone, glad you could join.
SPEAKER_01: Thanks for having me.
SPEAKER_00: Let's get started with the agenda...
SPEAKER_02: I have a question about the timeline.
```

## Troubleshooting

**"Missing required dependency"**
```bash
pip3 install pyannote.audio torch openai-whisper
```

**"Error loading diarization pipeline: 401"**
- Check your token in config.json
- Make sure you accepted BOTH model agreements

**"python3 doesn't exist" or "ffmpeg not found"**
- Use full path to python: `"pythonPath": "/Applications/miniforge3/bin/python3"`
- Find your path with: `which python3`

**Still having issues?**

See [DIARIZATION.md](DIARIZATION.md) for complete documentation.

## What's Next?

Phase 1 ✅ Generic speaker labels (SPEAKER_00, etc.)  
Phase 2 ⏳ Local vs remote detection ("ME" vs "THEM")  
Phase 3 ⏳ Actual speaker names
