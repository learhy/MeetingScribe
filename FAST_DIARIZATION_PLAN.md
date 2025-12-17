# Fast Approximate Diarization Implementation Plan

## Objective
Replace slow pyannote.audio diarization with SpeechBrain ECAPA-TDNN + MeanShift clustering for 6-7x speedup.

## Current Performance
- **Total time**: 3+ minutes for 26-minute recording
- **Diarization**: ~3 minutes (bottleneck)
- **Transcription**: ~75 seconds (openai-whisper)

## Target Performance
- **Total time**: <2 minutes for 26-minute recording
- **Diarization**: ~30 seconds (6-7x faster)
- **Transcription**: ~75 seconds (unchanged)

## Approach
Based on "Towards Approximate Fast Diarization" methodology:
1. Use SpeechBrain's `speechbrain/spkrec-ecapa-voxceleb` for speaker embeddings
2. Apply MeanShift clustering instead of pyannote's complex pipeline
3. Align resulting segments with Whisper transcription

## Implementation Steps

### Step 1: Install Dependencies
```bash
pip install speechbrain scikit-learn
```

### Step 2: Create New Diarization Function
Replace `load_diarization_pipeline()` with:
- `extract_speaker_embeddings()` - Get ECAPA-TDNN embeddings
- `cluster_speakers()` - MeanShift clustering
- `create_diarization_segments()` - Build annotation object

### Step 3: Key Algorithm Changes

**Current (slow):**
```python
pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
diarization = pipeline(audio_file)
```

**New (fast):**
```python
from speechbrain.pretrained import EncoderClassifier
from sklearn.cluster import MeanShift

# 1. Extract embeddings for sliding windows
classifier = EncoderClassifier.from_hparams(
    source="speechbrain/spkrec-ecapa-voxceleb",
    savedir="tmp/spkrec-ecapa-voxceleb"
)
embeddings = []
timestamps = []
for window in sliding_windows(audio, window_size=1.5s, step=0.75s):
    emb = classifier.encode_batch(window)
    embeddings.append(emb)
    timestamps.append(window_start)

# 2. Cluster embeddings
clustering = MeanShift(bandwidth=0.8)
labels = clustering.fit_predict(embeddings)

# 3. Create segments from labels
segments = merge_consecutive_labels(labels, timestamps)
```

### Step 4: Optimize Parameters
- **Window size**: 1.5 seconds (balance between accuracy and speed)
- **Step size**: 0.75 seconds (50% overlap)
- **Bandwidth**: 0.8 (MeanShift clustering parameter)

### Step 5: Testing
```bash
time python scripts/diarize_audio_fast.py \
  ~/Documents/MeetingScribe/recordings/meeting_2025-12-17_11-38-01_mixed.wav \
  --whisper-model base \
  --output /tmp/fast_diarization.json
```

## Expected Benefits
1. **6-7x faster diarization** (3min → 30s)
2. **No HuggingFace token required** (SpeechBrain is fully open)
3. **CPU-friendly** (works great on M3)
4. **Simpler code** (fewer dependencies)

## Trade-offs
- Slightly lower accuracy than pyannote 3.1 (acceptable for podcast/meeting content)
- Less sophisticated voice activity detection
- May need tuning for specific audio types

## Success Criteria
✅ Total processing time <2 minutes for 26-min audio
✅ Output format compatible with existing Swift code
✅ 3+ speakers detected correctly
✅ Transcription quality maintained
