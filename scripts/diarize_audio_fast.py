#!/usr/bin/env python3
"""
Fast speaker diarization script for MeetingScribe.

This script uses SpeechBrain ECAPA-TDNN embeddings + MeanShift clustering
for 6-7x faster diarization compared to pyannote.audio pipelines.

Requirements:
- speechbrain
- scikit-learn
- openai-whisper
- torch
- torchaudio

Usage:
    python diarize_audio_fast.py <audio_file> [options]
"""

import argparse
import json
import sys
import os
import warnings
import random
import numpy as np
from pathlib import Path
from typing import List, Dict, Any, Tuple
from dataclasses import dataclass

# Set random seeds for reproducibility
RANDOM_SEED = 42
random.seed(RANDOM_SEED)
np.random.seed(RANDOM_SEED)

# Suppress warnings
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", message=".*torchaudio.*")

# Add common ffmpeg locations
if '/opt/homebrew/bin' not in os.environ.get('PATH', ''):
    os.environ['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', '')

try:
    import torch
    import whisper
    import torchaudio
    from speechbrain.pretrained import EncoderClassifier
    from sklearn.cluster import AgglomerativeClustering
    
    # Set PyTorch seed for reproducibility
    torch.manual_seed(RANDOM_SEED)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(RANDOM_SEED)
    # Note: MPS (Apple Silicon) doesn't have a separate seed function
except ImportError as e:
    print(f"Error: Missing required dependency: {e}", file=sys.stderr)
    print("Please install: pip install speechbrain scikit-learn openai-whisper torch torchaudio", file=sys.stderr)
    sys.exit(1)


@dataclass
class DiarizationSegment:
    """Represents a speaker segment with timing information."""
    start: float
    end: float
    speaker: str


def get_device() -> str:
    """Determine the best device to use."""
    if torch.backends.mps.is_available():
        return "mps"
    elif torch.cuda.is_available():
        return "cuda"
    else:
        return "cpu"


def load_and_preprocess_audio(audio_path: str) -> Tuple[torch.Tensor, int]:
    """Load audio file and preprocess to mono 16kHz."""
    print(f"Loading audio: {audio_path}", file=sys.stderr)
    waveform, sample_rate = torchaudio.load(audio_path)
    
    # Convert to mono
    if waveform.shape[0] > 1:
        waveform = torch.mean(waveform, dim=0, keepdim=True)
    
    # Resample to 16kHz if needed
    if sample_rate != 16000:
        print(f"Resampling from {sample_rate}Hz to 16000Hz...", file=sys.stderr)
        resampler = torchaudio.transforms.Resample(sample_rate, 16000)
        waveform = resampler(waveform)
        sample_rate = 16000
    
    return waveform, sample_rate


def extract_embeddings_with_speechbrain(
    waveform: torch.Tensor,
    sample_rate: int,
    window_size: float = 1.5,
    step_size: float = 0.75
) -> Tuple[np.ndarray, List[float]]:
    """
    Extract speaker embeddings using SpeechBrain ECAPA-TDNN.
    
    Args:
        waveform: Audio tensor (1, num_samples)
        sample_rate: Sample rate (should be 16000)
        window_size: Window size in seconds
        step_size: Step size in seconds (overlap)
    
    Returns:
        embeddings: Array of shape (num_windows, embedding_dim)
        timestamps: List of window start times
    """
    # Use user cache directory for models (works for both bundled and development)
    cache_dir = os.path.expanduser("~/.meetingscribe/cache/models")
    os.makedirs(cache_dir, exist_ok=True)
    model_dir = os.path.join(cache_dir, "spkrec-ecapa-voxceleb")
    
    print("Loading SpeechBrain ECAPA-TDNN model...", file=sys.stderr)
    if not os.path.exists(model_dir):
        print(f"Downloading model to {model_dir} (first run only, ~500MB)...", file=sys.stderr)
    
    classifier = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir=model_dir,
        run_opts={"device": "cpu"}  # SpeechBrain works best on CPU
    )
    
    # Calculate window parameters
    window_samples = int(window_size * sample_rate)
    step_samples = int(step_size * sample_rate)
    audio_length = waveform.shape[1]
    
    # Calculate total windows for progress reporting
    total_windows = max(1, (audio_length - window_samples) // step_samples + 1)
    
    embeddings = []
    timestamps = []
    
    print(f"Extracting embeddings (window={window_size}s, step={step_size}s)...", file=sys.stderr)
    
    # Progress tracking
    last_progress_pct = 0
    window_idx = 0
    
    # Sliding window extraction
    for start_sample in range(0, audio_length - window_samples + 1, step_samples):
        end_sample = start_sample + window_samples
        window = waveform[:, start_sample:end_sample]
        
        # Extract embedding for this window
        with torch.no_grad():
            embedding = classifier.encode_batch(window)
            embeddings.append(embedding.squeeze().cpu().numpy())
        
        # Store timestamp (in seconds)
        timestamps.append(start_sample / sample_rate)
        
        # Emit progress every 10%
        window_idx += 1
        progress_pct = int((window_idx / total_windows) * 100)
        if progress_pct >= last_progress_pct + 10:
            print(f"PROGRESS:embedding:{window_idx}:{total_windows}", file=sys.stderr)
            last_progress_pct = progress_pct
    
    embeddings_array = np.array(embeddings)
    print(f"Extracted {len(embeddings)} embeddings", file=sys.stderr)
    
    return embeddings_array, timestamps


def cluster_speakers(
    embeddings: np.ndarray,
    distance_threshold: float = 0.90
) -> np.ndarray:
    """
    Cluster speaker embeddings using Agglomerative Clustering.
    
    Args:
        embeddings: Array of shape (num_windows, embedding_dim)
        distance_threshold: Cosine distance threshold for clustering (0.3-0.8)
                           Lower = more speakers, Higher = fewer speakers
    
    Returns:
        labels: Array of speaker labels for each window
    """
    # Normalize embeddings (L2 norm) for cosine distance
    from sklearn.preprocessing import normalize
    embeddings_normalized = normalize(embeddings, axis=1, norm='l2')
    
    print(f"Clustering speakers (distance_threshold={distance_threshold:.2f}, metric=cosine)...", file=sys.stderr)
    
    # Agglomerative clustering with cosine distance
    clustering = AgglomerativeClustering(
        n_clusters=None,              # Auto-detect number of speakers
        distance_threshold=distance_threshold,
        metric='cosine',              # Better for embeddings
        linkage='average'             # Average linkage works well for speaker diarization
    )
    labels = clustering.fit_predict(embeddings_normalized)
    
    num_speakers = len(np.unique(labels))
    print(f"Detected {num_speakers} speaker(s)", file=sys.stderr)
    
    return labels


def create_diarization_segments(
    labels: np.ndarray,
    timestamps: List[float],
    window_size: float = 1.5
) -> List[DiarizationSegment]:
    """
    Convert cluster labels to diarization segments.
    
    Merges consecutive windows with the same speaker label.
    """
    segments = []
    
    if len(labels) == 0:
        return segments
    
    # Start first segment
    current_speaker = labels[0]
    current_start = timestamps[0]
    current_end = timestamps[0] + window_size
    
    for i in range(1, len(labels)):
        if labels[i] == current_speaker:
            # Same speaker, extend segment
            current_end = timestamps[i] + window_size
        else:
            # Speaker changed, save segment and start new one
            segments.append(DiarizationSegment(
                start=current_start,
                end=current_end,
                speaker=f"SPEAKER_{current_speaker:02d}"
            ))
            current_speaker = labels[i]
            current_start = timestamps[i]
            current_end = timestamps[i] + window_size
    
    # Add final segment
    segments.append(DiarizationSegment(
        start=current_start,
        end=current_end,
        speaker=f"SPEAKER_{current_speaker:02d}"
    ))
    
    return segments


def load_vocabulary_file(vocab_path: str) -> str:
    """Load vocabulary terms from a file and format as prompt."""
    if not vocab_path or not os.path.exists(vocab_path):
        return ""
    
    try:
        with open(vocab_path, 'r', encoding='utf-8') as f:
            terms = [line.strip() for line in f if line.strip() and not line.startswith('#')]
        if terms:
            return "Glossary: " + ", ".join(terms)
    except Exception as e:
        print(f"Warning: Could not load vocabulary file: {e}", file=sys.stderr)
    return ""


def transcribe_with_whisper(
    audio_path: str,
    model_name: str = "base",
    initial_prompt: str = None,
    vocabulary_file: str = None,
    audio_duration_seconds: float = None
) -> Dict[str, Any]:
    """Transcribe audio with Whisper."""
    print(f"Loading Whisper model '{model_name}'...", file=sys.stderr)
    model = whisper.load_model(model_name, device="cpu")
    
    # Build the prompt from vocabulary file and/or initial prompt
    prompt_parts = []
    if vocabulary_file:
        vocab_prompt = load_vocabulary_file(vocabulary_file)
        if vocab_prompt:
            prompt_parts.append(vocab_prompt)
            print(f"Loaded vocabulary from: {vocabulary_file}", file=sys.stderr)
    if initial_prompt:
        prompt_parts.append(initial_prompt)
        print(f"Using initial prompt: {initial_prompt[:50]}...", file=sys.stderr)
    
    final_prompt = " ".join(prompt_parts) if prompt_parts else None
    
    # Estimate total chunks for progress (Whisper processes ~30 second chunks)
    total_chunks = int((audio_duration_seconds or 0) / 30) + 1 if audio_duration_seconds else None
    if total_chunks:
        print(f"Transcribing (~{total_chunks} chunks)...", file=sys.stderr)
    else:
        print(f"Transcribing...", file=sys.stderr)
    
    transcribe_kwargs = {
        "word_timestamps": True,
        "verbose": False
    }
    
    if final_prompt:
        transcribe_kwargs["initial_prompt"] = final_prompt
        # Keep the prompt across segments for consistent vocabulary recognition
        transcribe_kwargs["condition_on_previous_text"] = True
    
    result = model.transcribe(audio_path, **transcribe_kwargs)
    
    # Report completion with segment count
    num_segments = len(result.get("segments", []))
    print(f"PROGRESS:transcribe:{num_segments}:{num_segments}", file=sys.stderr)
    print(f"Transcription complete: {num_segments} segments", file=sys.stderr)
    
    return result


def align_transcription_with_diarization(
    transcription: Dict[str, Any],
    diarization_segments: List[DiarizationSegment],
    min_overlap: float = 0.3
) -> List[Dict[str, Any]]:
    """
    Align Whisper transcription with diarization segments.
    """
    aligned_segments = []
    
    for segment in transcription.get("segments", []):
        seg_start = segment["start"]
        seg_end = segment["end"]
        seg_text = segment["text"].strip()
        
        if not seg_text:
            continue
        
        # Find best matching diarization segment
        max_overlap = 0
        assigned_speaker = "UNKNOWN"
        
        for dia_seg in diarization_segments:
            overlap_start = max(seg_start, dia_seg.start)
            overlap_end = min(seg_end, dia_seg.end)
            overlap_duration = max(0, overlap_end - overlap_start)
            
            segment_duration = seg_end - seg_start
            if segment_duration > 0:
                overlap_ratio = overlap_duration / segment_duration
                
                if overlap_ratio > max_overlap:
                    max_overlap = overlap_ratio
                    assigned_speaker = dia_seg.speaker
        
        if max_overlap >= min_overlap:
            aligned_segments.append({
                "start": seg_start,
                "end": seg_end,
                "speaker": assigned_speaker,
                "text": seg_text
            })
        else:
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
        description="Fast speaker diarization using SpeechBrain + MeanShift"
    )
    parser.add_argument(
        "audio_file",
        help="Path to audio file (WAV, MP3, etc.)"
    )
    parser.add_argument(
        "--whisper-model",
        default="turbo",
        choices=["tiny", "base", "small", "medium", "large", "turbo"],
        help="Whisper model size (default: turbo)"
    )
    parser.add_argument(
        "--initial-prompt",
        type=str,
        default=None,
        help="Initial prompt for Whisper (e.g., 'Glossary: QBR, MBR, GTM')"
    )
    parser.add_argument(
        "--vocabulary-file",
        type=str,
        default=None,
        help="Path to vocabulary file with domain terms (one per line)"
    )
    parser.add_argument(
        "--window-size",
        type=float,
        default=1.5,
        help="Embedding window size in seconds (default: 1.5)"
    )
    parser.add_argument(
        "--step-size",
        type=float,
        default=0.75,
        help="Embedding step size in seconds (default: 0.75)"
    )
    parser.add_argument(
        "--distance-threshold",
        type=float,
        default=0.90,
        help="Agglomerative clustering distance threshold (default: 0.90, range: 0.85-0.95)"
    )
    parser.add_argument(
        "--output",
        "-o",
        help="Output JSON file path (default: stdout)"
    )
    
    args = parser.parse_args()
    
    # Validate audio file
    if not os.path.exists(args.audio_file):
        print(f"Error: Audio file not found: {args.audio_file}", file=sys.stderr)
        sys.exit(1)
    
    # Step 1: Load and preprocess audio
    waveform, sample_rate = load_and_preprocess_audio(args.audio_file)
    
    # Calculate audio duration for progress reporting
    audio_duration_seconds = waveform.shape[1] / sample_rate
    print(f"Audio duration: {audio_duration_seconds:.1f}s ({audio_duration_seconds/60:.1f} minutes)", file=sys.stderr)
    
    # Step 2: Extract speaker embeddings
    embeddings, timestamps = extract_embeddings_with_speechbrain(
        waveform,
        sample_rate,
        window_size=args.window_size,
        step_size=args.step_size
    )
    
    # Step 3: Cluster speakers
    labels = cluster_speakers(embeddings, distance_threshold=args.distance_threshold)
    
    # Step 4: Create diarization segments
    diarization_segments = create_diarization_segments(
        labels,
        timestamps,
        window_size=args.window_size
    )
    
    # Extract unique speakers
    speakers = sorted(set(seg.speaker for seg in diarization_segments))
    print(f"Identified speakers: {speakers}", file=sys.stderr)
    
    # Step 5: Transcribe with Whisper
    transcription = transcribe_with_whisper(
        args.audio_file,
        model_name=args.whisper_model,
        initial_prompt=args.initial_prompt,
        vocabulary_file=args.vocabulary_file,
        audio_duration_seconds=audio_duration_seconds
    )
    
    # Step 6: Align transcription with diarization
    print("Aligning transcription with diarization...", file=sys.stderr)
    aligned_segments = align_transcription_with_diarization(
        transcription,
        diarization_segments
    )
    
    # Step 7: Merge consecutive segments
    merged_segments = merge_consecutive_segments(aligned_segments)
    
    # Prepare output
    output_data = {
        "segments": merged_segments,
        "speakers": speakers,
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
