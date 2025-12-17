#!/usr/bin/env python3
"""
Speaker diarization script for MeetingScribe.

This script performs speaker diarization on audio files using pyannote-audio
and aligns the results with Whisper transcription to produce speaker-labeled
transcripts.

Requirements:
- pyannote.audio 3.1+
- openai-whisper
- torch (with MPS support for Mac Metal acceleration)
- HuggingFace token with access to pyannote models

Usage:
    python diarize_audio.py <audio_file> [options]
"""

import argparse
import json
import sys
import os
import warnings
from pathlib import Path
from typing import List, Dict, Any, Optional

# Suppress warnings from libraries
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", message=".*torchcodec.*")
warnings.filterwarnings("ignore", message=".*FP16.*")
warnings.filterwarnings("ignore", message=".*torchaudio.*")

# Add common ffmpeg locations to PATH for Whisper
if '/opt/homebrew/bin' not in os.environ.get('PATH', ''):
    os.environ['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', '')

try:
    import torch
    import whisper
    from pyannote.audio import Pipeline
    import torchaudio
except ImportError as e:
    print(f"Error: Missing required dependency: {e}", file=sys.stderr)
    print("Please install requirements: pip install -r requirements-diarization.txt", file=sys.stderr)
    sys.exit(1)


def get_device() -> str:
    """Determine the best device to use (MPS for Mac, CUDA for GPU, or CPU)."""
    if torch.backends.mps.is_available():
        return "mps"
    elif torch.cuda.is_available():
        return "cuda"
    else:
        return "cpu"


def load_diarization_pipeline(hf_token: str, device: str) -> Pipeline:
    """Load the pyannote speaker diarization pipeline."""
    try:
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=hf_token
        )
        
        # Move pipeline to device (mps/cuda/cpu)
        if device != "cpu":
            pipeline.to(torch.device(device))
        
        return pipeline
    except Exception as e:
        print(f"Error loading diarization pipeline: {e}", file=sys.stderr)
        print("", file=sys.stderr)
        print("To fix this:", file=sys.stderr)
        print("1. Visit https://huggingface.co/pyannote/speaker-diarization-3.1 and accept user conditions", file=sys.stderr)
        print("2. Visit https://huggingface.co/pyannote/segmentation-3.0 and accept user conditions", file=sys.stderr)
        print("3. Generate a HuggingFace access token at https://huggingface.co/settings/tokens", file=sys.stderr)
        print("4. Add the token to your ~/.meetingscribe/config.json", file=sys.stderr)
        sys.exit(1)


def transcribe_with_whisper(
    audio_path: str,
    model_name: str = "base",
    device: str = "cpu"
) -> Dict[str, Any]:
    """Transcribe audio with Whisper, including word-level timestamps."""
    print(f"Loading Whisper model '{model_name}' on {device}...", file=sys.stderr)
    
    # Note: Whisper doesn't support MPS well, so use CPU for Mac
    whisper_device = "cpu" if device == "mps" else device
    model = whisper.load_model(model_name, device=whisper_device)
    
    print(f"Transcribing {audio_path}...", file=sys.stderr)
    result = model.transcribe(
        audio_path,
        word_timestamps=True,
        verbose=False
    )
    
    return result


def align_transcription_with_diarization(
    transcription: Dict[str, Any],
    diarization: Any,
    min_overlap: float = 0.3
) -> List[Dict[str, Any]]:
    """
    Align Whisper transcription segments with pyannote diarization results.
    
    Args:
        transcription: Whisper transcription result with segments
        diarization: Pyannote diarization result
        min_overlap: Minimum overlap ratio to assign speaker to segment
    
    Returns:
        List of segments with speaker labels
    """
    aligned_segments = []
    
    # Extract diarization turns as (start, end, speaker) tuples
    diarization_turns = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        diarization_turns.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker
        })
    
    # Process each transcription segment
    for segment in transcription.get("segments", []):
        seg_start = segment["start"]
        seg_end = segment["end"]
        seg_text = segment["text"].strip()
        
        if not seg_text:
            continue
        
        # Find the diarization turn with maximum overlap
        max_overlap = 0
        assigned_speaker = "UNKNOWN"
        
        for turn in diarization_turns:
            # Calculate overlap
            overlap_start = max(seg_start, turn["start"])
            overlap_end = min(seg_end, turn["end"])
            overlap_duration = max(0, overlap_end - overlap_start)
            
            segment_duration = seg_end - seg_start
            if segment_duration > 0:
                overlap_ratio = overlap_duration / segment_duration
                
                if overlap_ratio > max_overlap:
                    max_overlap = overlap_ratio
                    assigned_speaker = turn["speaker"]
        
        # Only assign speaker if overlap is sufficient
        if max_overlap >= min_overlap:
            aligned_segments.append({
                "start": seg_start,
                "end": seg_end,
                "speaker": assigned_speaker,
                "text": seg_text
            })
        else:
            # No clear speaker match
            aligned_segments.append({
                "start": seg_start,
                "end": seg_end,
                "speaker": "UNKNOWN",
                "text": seg_text
            })
    
    return aligned_segments


def merge_consecutive_segments(segments: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Merge consecutive segments from the same speaker."""
    if not segments:
        return []
    
    merged = []
    current = segments[0].copy()
    
    for segment in segments[1:]:
        # If same speaker and close in time (within 1 second), merge
        if (segment["speaker"] == current["speaker"] and 
            segment["start"] - current["end"] < 1.0):
            current["end"] = segment["end"]
            current["text"] += " " + segment["text"]
        else:
            merged.append(current)
            current = segment.copy()
    
    merged.append(current)
    return merged


def main():
    parser = argparse.ArgumentParser(
        description="Perform speaker diarization on audio files"
    )
    parser.add_argument(
        "audio_file",
        help="Path to audio file (WAV, MP3, etc.)"
    )
    parser.add_argument(
        "--hf-token",
        required=True,
        help="HuggingFace access token"
    )
    parser.add_argument(
        "--whisper-model",
        default="base",
        choices=["tiny", "base", "small", "medium", "large", "large-v2", "large-v3"],
        help="Whisper model size (default: base)"
    )
    parser.add_argument(
        "--min-speakers",
        type=int,
        help="Minimum number of speakers"
    )
    parser.add_argument(
        "--max-speakers",
        type=int,
        help="Maximum number of speakers"
    )
    parser.add_argument(
        "--output",
        "-o",
        help="Output JSON file path (default: stdout)"
    )
    parser.add_argument(
        "--device",
        choices=["auto", "cpu", "cuda", "mps"],
        default="auto",
        help="Device to use (default: auto-detect)"
    )
    
    args = parser.parse_args()
    
    # Validate audio file exists
    if not os.path.exists(args.audio_file):
        print(f"Error: Audio file not found: {args.audio_file}", file=sys.stderr)
        sys.exit(1)
    
    # Determine device
    device = get_device() if args.device == "auto" else args.device
    print(f"Using device: {device}", file=sys.stderr)
    
    # Load diarization pipeline
    print("Loading diarization pipeline...", file=sys.stderr)
    diarization_pipeline = load_diarization_pipeline(args.hf_token, device)
    
    # Run diarization
    print(f"Running speaker diarization on {args.audio_file}...", file=sys.stderr)
    diarization_kwargs = {}
    if args.min_speakers:
        diarization_kwargs["min_speakers"] = args.min_speakers
    if args.max_speakers:
        diarization_kwargs["max_speakers"] = args.max_speakers
    
    # Load audio using torchaudio to avoid pyannote's torchcodec issues
    print("Loading audio with torchaudio...", file=sys.stderr)
    waveform, sample_rate = torchaudio.load(args.audio_file)
    
    # Convert to mono if needed
    if waveform.shape[0] > 1:
        waveform = torch.mean(waveform, dim=0, keepdim=True)
    
    # Resample to 16kHz if needed (pyannote expects 16kHz)
    if sample_rate != 16000:
        print(f"Resampling from {sample_rate}Hz to 16000Hz...", file=sys.stderr)
        resampler = torchaudio.transforms.Resample(orig_freq=sample_rate, new_freq=16000)
        waveform = resampler(waveform)
        sample_rate = 16000
    
    # Pass audio as tensor to avoid file loading issues
    audio_input = {"waveform": waveform, "sample_rate": sample_rate}
    diarization = diarization_pipeline(audio_input, **diarization_kwargs)
    
    # Extract annotation from DiarizeOutput (pyannote 3.x)
    annotation = diarization.speaker_diarization
    
    # Count speakers
    speakers = set()
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        speakers.add(speaker)
    print(f"Detected {len(speakers)} speaker(s): {sorted(speakers)}", file=sys.stderr)
    
    # Transcribe with Whisper
    transcription = transcribe_with_whisper(
        args.audio_file,
        model_name=args.whisper_model,
        device=device
    )
    
    # Align transcription with diarization
    print("Aligning transcription with speaker diarization...", file=sys.stderr)
    aligned_segments = align_transcription_with_diarization(
        transcription,
        annotation
    )
    
    # Merge consecutive segments from same speaker
    merged_segments = merge_consecutive_segments(aligned_segments)
    
    # Prepare output
    output_data = {
        "segments": merged_segments,
        "speakers": sorted(list(speakers)),
        "num_speakers": len(speakers),
        "audio_file": args.audio_file
    }
    
    # Write output
    output_json = json.dumps(output_data, indent=2, ensure_ascii=False)
    
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output_json)
        print(f"Output written to {args.output}", file=sys.stderr)
    else:
        print(output_json)
    
    print("Diarization complete!", file=sys.stderr)


if __name__ == "__main__":
    main()
