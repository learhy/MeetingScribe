# Performance Optimization Plan for Whisper Diarization Script

## Objective
Optimize `scripts/diarize_audio_transformers.py` to achieve 2.5-4x faster processing on Apple M3 hardware without changing core functionality or adding complex dependencies.

## Current Script Location
`scripts/diarize_audio_transformers.py`

## Baseline Performance
- Test file: `~/Documents/MeetingScribe/recordings/meeting_2025-12-17_11-38-01_mixed.wav`
- Current model: `openai/whisper-base`
- Current batch_size: 4
- Measure and record current execution time before starting

---

## Required Changes (4 Optimizations)

### **OPTIMIZATION 1: Force pyannote to CPU**
**Priority:** HIGH  
**Expected Speedup:** 2-3x for diarization phase  
**Effort:** 5 minutes

#### What to change:
In the `load_diarization_pipeline()` function (currently lines 104-111):

**Current code:**
```python
def load_diarization_pipeline(hf_token: str, device: str) -> Pipeline:
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=hf_token
    )
    pipeline.to(torch.device(device))
    return pipeline
```

**New code:**
```python
def load_diarization_pipeline(hf_token: str, device: str) -> Pipeline:
    """
    Load speaker diarization pipeline.
    Note: Forced to CPU because pyannote.audio has poor MPS optimization.
    CPU is paradoxically 2-3x faster on Apple Silicon.
    """
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=hf_token
    )
    # Force CPU for pyannote - actually faster on M3 than MPS
    pipeline.to(torch.device("cpu"))
    return pipeline
```

**Key points:**
- Ignore the `device` parameter for pyannote
- Add docstring explaining why CPU is used
- Keep Whisper on MPS (don't change that)

---

### **OPTIMIZATION 2: Apply torch.compile() to Whisper**
**Priority:** HIGH  
**Expected Speedup:** 1.2-1.4x for transcription phase  
**Effort:** 10 minutes

#### What to change:
In the `transcribe_with_transformers()` function (around line 115-145):

**Current code:**
```python
def transcribe_with_transformers(
    audio_file: str, 
    model_id: str, 
    device: str,
    batch_size: int = 4
) -> Dict[str, Any]:
    print(f"Loading Transformers Whisper pipeline '{model_id}' on {device}...")
    
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_id,
        torch_dtype=torch.float16 if device != "cpu" else torch.float32,
        device=device,
        model_kwargs={"attn_implementation": "sdpa"}
    )
```

**New code:**
```python
def transcribe_with_transformers(
    audio_file: str, 
    model_id: str, 
    device: str,
    batch_size: int = 4
) -> Dict[str, Any]:
    print(f"Loading Transformers Whisper pipeline '{model_id}' on {device}...")
    
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_id,
        dtype=torch.float16 if device != "cpu" else torch.float32,  # Changed from torch_dtype
        device=device,
        model_kwargs={"attn_implementation": "sdpa"}
    )
    
    # Apply torch.compile for 20-40% speedup
    if device != "cpu":  # Only compile for GPU/MPS
        print("Compiling model with torch.compile() for optimized inference...")
        pipe.model = torch.compile(pipe.model, mode="reduce-overhead")
```

**Key points:**
- Fix deprecation: `torch_dtype` → `dtype`
- Add `torch.compile()` only for non-CPU devices
- Add print statement so user knows compilation is happening
- Compilation happens once, first inference will be slower (warmup)

---

### **OPTIMIZATION 3: Increase default batch_size**
**Priority:** MEDIUM  
**Expected Speedup:** 1.3-1.5x for transcription phase  
**Effort:** 2 minutes

#### What to change:
In the argument parser (around line 166):

**Current code:**
```python
parser.add_argument(
    "--batch-size",
    type=int,
    default=4,
    help="Batch size for Whisper inference"
)
```

**New code:**
```python
parser.add_argument(
    "--batch-size",
    type=int,
    default=8,  # Changed from 4 to 8
    help="Batch size for Whisper inference (default: 8, increase to 16 if you have RAM)"
)
```

**Key points:**
- Change default from 4 to 8
- Update help text
- User can still override with `--batch-size 4` if needed
- If batch_size=8 causes OOM errors, can try 12 or 16 based on available RAM

---

### **OPTIMIZATION 4: Load audio once and reuse**
**Priority:** MEDIUM  
**Expected Speedup:** 1.1-1.2x overall  
**Effort:** 30 minutes

#### What to change:
This requires refactoring the `main()` function and `transcribe_with_transformers()`.

**Current flow (inefficient):**
1. Line 181: pyannote loads audio from file path
2. Line 208: `transcribe_with_transformers()` loads audio with torchaudio
3. Inside pipeline: audio loaded again

**New flow (efficient):**
1. Load audio once in `main()`
2. Resample once to 16kHz
3. Convert to mono once
4. Pass tensor to both pipelines

#### Step-by-step changes:

**STEP A:** Create a new helper function at the top of the file (after imports):

```python
def load_and_prepare_audio(audio_path: str) -> Tuple[torch.Tensor, int]:
    """
    Load audio file once, resample to 16kHz, convert to mono.
    Returns (waveform, sample_rate) for reuse across pipelines.
    """
    print(f"Loading audio file: {audio_path}")
    waveform, sample_rate = torchaudio.load(audio_path)
    
    # Resample to 16kHz if needed
    if sample_rate != 16000:
        print(f"Resampling from {sample_rate}Hz to 16000Hz...")
        resampler = torchaudio.transforms.Resample(sample_rate, 16000)
        waveform = resampler(waveform)
        sample_rate = 16000
    
    # Convert to mono if needed
    if waveform.shape[0] > 1:
        print("Converting stereo to mono...")
        waveform = torch.mean(waveform, dim=0, keepdim=True)
    
    return waveform, sample_rate
```

**STEP B:** Update `transcribe_with_transformers()` signature and implementation:

**Current signature:**
```python
def transcribe_with_transformers(
    audio_file: str, 
    model_id: str, 
    device: str,
    batch_size: int = 4
) -> Dict[str, Any]:
```

**New signature:**
```python
def transcribe_with_transformers(
    audio_input: Union[str, Tuple[torch.Tensor, int]],  # Can accept file path OR (waveform, sr) tuple
    model_id: str, 
    device: str,
    batch_size: int = 8
) -> Dict[str, Any]:
```

**Update the function body:**

Replace this section (lines ~120-135):
```python
    print(f"Loading audio {audio_file} with torchaudio...")
    waveform, sample_rate = torchaudio.load(audio_file)
    
    if sample_rate != 16000:
        print(f"Resampling from {sample_rate}Hz to 16000Hz...")
        resampler = torchaudio.transforms.Resample(sample_rate, 16000)
        waveform = resampler(waveform)
        sample_rate = 16000
    
    if waveform.shape[0] > 1:
        print("Converting stereo to mono...")
        waveform = torch.mean(waveform, dim=0, keepdim=True)
    
    audio_array = waveform.squeeze().numpy()
```

With:
```python
    # Handle both file path and pre-loaded audio
    if isinstance(audio_input, str):
        # Legacy path: load from file
        print(f"Loading audio {audio_input} with torchaudio...")
        waveform, sample_rate = torchaudio.load(audio_input)
        
        if sample_rate != 16000:
            print(f"Resampling from {sample_rate}Hz to 16000Hz...")
            resampler = torchaudio.transforms.Resample(sample_rate, 16000)
            waveform = resampler(waveform)
            sample_rate = 16000
        
        if waveform.shape[0] > 1:
            print("Converting stereo to mono...")
            waveform = torch.mean(waveform, dim=0, keepdim=True)
    else:
        # Optimized path: audio already loaded
        waveform, sample_rate = audio_input
        print("Using pre-loaded audio (optimized path)...")
    
    audio_array = waveform.squeeze().numpy()
```

**STEP C:** Update `main()` function (around line 176-215):

**Current code:**
```python
def main():
    args = parse_args()
    device = get_device()
    print(f"Using device: {device}")
    
    print("Loading diarization pipeline...")
    diarization_pipeline = load_diarization_pipeline(args.hf_token, device)
    
    print(f"Running speaker diarization on {args.audio_file}...")
    annotation = diarization_pipeline(args.audio_file, min_speakers=args.min_speakers, max_speakers=args.max_speakers)
    
    # ... rest of code
    
    print(f"Transcribing with Whisper model {args.whisper_model}...")
    transcription = transcribe_with_transformers(
        args.audio_file,
        args.whisper_model,
        device,
        batch_size=args.batch_size
    )
```

**New code:**
```python
def main():
    args = parse_args()
    device = get_device()
    print(f"Using device: {device}")
    
    # OPTIMIZATION: Load audio once for both pipelines
    waveform, sample_rate = load_and_prepare_audio(args.audio_file)
    
    print("Loading diarization pipeline...")
    diarization_pipeline = load_diarization_pipeline(args.hf_token, device)
    
    print(f"Running speaker diarization on {args.audio_file}...")
    # pyannote can accept {"waveform": tensor, "sample_rate": int} dict
    annotation = diarization_pipeline(
        {"waveform": waveform, "sample_rate": sample_rate},
        min_speakers=args.min_speakers,
        max_speakers=args.max_speakers
    )
    
    # ... rest of code (speakers detection, etc.)
    
    print(f"Transcribing with Whisper model {args.whisper_model}...")
    # Pass pre-loaded audio to avoid redundant loading
    transcription = transcribe_with_transformers(
        (waveform, sample_rate),  # Pass tuple instead of file path
        args.whisper_model,
        device,
        batch_size=args.batch_size
    )
```

**Key points:**
- Add necessary import at top: `from typing import Union, Tuple`
- Maintain backward compatibility (can still accept file paths)
- Audio is loaded, resampled, and converted to mono exactly once
- Both pipelines receive the same preprocessed audio



---


```markdown
### **OPTIMIZATION 5: Fast Resampling**
**Priority:** HIGH  
**Expected Speedup:** 6-8x for resampling step  
**Effort:** 15 minutes

In `load_and_prepare_audio()`, replace the resampling code with:

```python
if sample_rate != 16000:
    print(f"Resampling from {sample_rate}Hz to 16000Hz on {device}...")
    
    # Move to GPU for fast resampling
    device_obj = torch.device(device)
    waveform = waveform.to(device_obj)
    
    # Fast resampler with lower quality settings (fine for speech)
    resampler = torchaudio.transforms.Resample(
        orig_freq=sample_rate,
        new_freq=16000,
        lowpass_filter_width=16,  # 4x faster than default
        rolloff=0.85,              # Lower = faster
        resampling_method="sinc_interp_kaiser"
    ).to(device_obj)
    
    waveform = resampler(waveform)
    waveform = waveform.cpu()  # Move back for compatibility
    sample_rate = 16000
```

And update the function signature to accept device:
```python
def load_and_prepare_audio(audio_path: str, device: str = "cpu") -> Tuple[torch.Tensor, int]:
```
```

---

## Testing Plan

### Before optimization:
```bash
# Record baseline time
time python scripts/diarize_audio_transformers.py \
  ~/Documents/MeetingScribe/recordings/meeting_2025-12-17_11-38-01_mixed.wav \
  --hf-token YOUR_TOKEN \
  --whisper-model base \
  --min-speakers 2 \
  --max-speakers 10 \
  --batch-size 4 \
  --output /tmp/baseline.json
```

### After each optimization:
1. Apply optimization
2. Run same command (update batch-size to 8 for opt #3)
3. Record time
4. Verify output JSON is identical (or very similar)

### After all optimizations:
```bash
# Test with new defaults
time python scripts/diarize_audio_transformers.py \
  ~/Documents/MeetingScribe/recordings/meeting_2025-12-17_11-38-01_mixed.wav \
  --hf-token YOUR_TOKEN \
  --whisper-model base \
  --min-speakers 2 \
  --max-speakers 10 \
  --output /tmp/optimized.json

# Compare results
diff /tmp/baseline.json /tmp/optimized.json
```

### Expected results:
- **Total speedup:** 2.5-4x faster
- **Output:** Should be identical or nearly identical
- **Warnings:** Should see fewer deprecation warnings

---

## Rollback Plan

If any optimization causes issues:

1. **Git commit after each optimization** so you can revert individually
2. **Keep original file as backup:** `cp scripts/diarize_audio_transformers.py scripts/diarize_audio_transformers.py.backup`
3. **Test incrementally** - don't apply all changes at once

---

## Additional Notes

### Memory considerations:
- If `batch_size=8` causes OOM (Out of Memory):
  - Try `batch_size=6`
  - Or revert to `batch_size=4`
- Monitor with: `Activity Monitor` → Memory tab while running

### torch.compile() warmup:
- First run after compilation will be slower (20-30s extra)
- Subsequent runs will be faster
- This is normal PyTorch behavior

### Compatibility:
- All changes maintain backward compatibility
- Existing command-line usage still works
- No new dependencies required

---

## Success Criteria

✅ Script runs 2.5-4x faster on same hardware  
✅ Output quality unchanged (same or very similar transcription)  
✅ No new errors or crashes  
✅ Fewer deprecation warnings in output  
✅ Code remains readable and maintainable  

---

## Implementation Order

1. **Optimization 1** (pyannote CPU) - Biggest impact, easiest
2. **Optimization 2** (torch.compile) - Easy, good return
3. **Optimization 3** (batch_size) - Trivial change
4. **Optimization 4** (load once) - Most complex, do last