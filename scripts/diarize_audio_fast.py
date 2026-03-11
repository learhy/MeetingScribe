#!/usr/bin/env python3
"""
Fast speaker diarization script for MeetingScribe.

This script uses SpeechBrain ECAPA-TDNN embeddings + MeanShift clustering
for 6-7x faster diarization compared to pyannote.audio pipelines.

Optionally integrates smart prompt generation for speaker-adaptive vocabulary:
- Use --smart-prompt to enable speaker-based prompt generation
- Matches speakers against a local database for vocabulary caching
- Falls back gracefully to static prompts on any failure

Requirements:
- speechbrain
- scikit-learn
- openai-whisper
- torch
- torchaudio
- (optional) tiktoken, spacy for smart prompts

Usage:
    python diarize_audio_fast.py <audio_file> [options]
    python diarize_audio_fast.py <audio_file> --smart-prompt [--speaker-db-path PATH]
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
    distance_threshold: float = 0.25
) -> np.ndarray:
    """
    Cluster speaker embeddings using Agglomerative Clustering.
    
    Args:
        embeddings: Array of shape (num_windows, embedding_dim)
        distance_threshold: Cosine DISTANCE threshold for clustering.
                           This is 1 - cosine_similarity, so:
                           - 0.15 = merge if similarity > 0.85 (strict, more speakers)
                           - 0.25 = merge if similarity > 0.75 (moderate, default)
                           - 0.40 = merge if similarity > 0.60 (loose, fewer speakers)
                           Typical range: 0.15-0.40
    
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


def _find_speaker_at_time(
    time: float,
    dia_segments: List[DiarizationSegment],
    dia_starts: List[float]
) -> str:
    """
    Find the speaker at a given time using binary search.
    
    Args:
        time: The timestamp to look up
        dia_segments: List of diarization segments (sorted by start time)
        dia_starts: Pre-computed list of segment start times for binary search
    
    Returns:
        Speaker label, or "UNKNOWN" if no segment covers this time
    """
    import bisect
    
    # Find the rightmost segment that starts at or before this time
    idx = bisect.bisect_right(dia_starts, time) - 1
    
    if idx < 0:
        # Time is before all segments - assign to first segment if close
        if dia_segments and time < dia_segments[0].start + 0.5:
            return dia_segments[0].speaker
        return "UNKNOWN"
    
    seg = dia_segments[idx]
    
    # Check if time falls within this segment
    if time <= seg.end:
        return seg.speaker
    
    # Time is in a gap - assign to nearest segment
    # Check distance to current segment's end vs next segment's start
    if idx + 1 < len(dia_segments):
        next_seg = dia_segments[idx + 1]
        dist_to_current = time - seg.end
        dist_to_next = next_seg.start - time
        if dist_to_next < dist_to_current:
            return next_seg.speaker
    
    return seg.speaker


def align_transcription_with_diarization(
    transcription: Dict[str, Any],
    diarization_segments: List[DiarizationSegment],
    min_overlap: float = 0.3  # Kept for API compatibility, not used in new logic
) -> List[Dict[str, Any]]:
    """
    Align Whisper transcription with diarization segments using word-level timestamps.
    
    This function splits Whisper segments at speaker boundaries to preserve
    speaker turns even when Whisper doesn't segment at speaker changes.
    """
    if not diarization_segments:
        # No diarization - return segments with UNKNOWN speaker
        return [
            {
                "start": seg["start"],
                "end": seg["end"],
                "speaker": "UNKNOWN",
                "text": seg["text"].strip()
            }
            for seg in transcription.get("segments", [])
            if seg["text"].strip()
        ]
    
    # Sort diarization segments by start time and pre-compute starts for binary search
    dia_sorted = sorted(diarization_segments, key=lambda s: s.start)
    dia_starts = [s.start for s in dia_sorted]
    
    aligned_segments = []
    
    for segment in transcription.get("segments", []):
        words = segment.get("words", [])
        
        if not words:
            # Fallback: no word timestamps, use segment-level assignment
            seg_text = segment["text"].strip()
            if not seg_text:
                continue
            seg_mid = (segment["start"] + segment["end"]) / 2
            speaker = _find_speaker_at_time(seg_mid, dia_sorted, dia_starts)
            aligned_segments.append({
                "start": segment["start"],
                "end": segment["end"],
                "speaker": speaker,
                "text": seg_text
            })
            continue
        
        # Group consecutive words by speaker
        current_speaker = None
        current_words = []
        current_start = None
        current_end = None
        
        for word_info in words:
            word_text = word_info.get("word", "").strip()
            if not word_text:
                continue
            
            word_start = word_info.get("start", 0)
            word_end = word_info.get("end", word_start)
            
            # Use word start time to determine speaker
            speaker = _find_speaker_at_time(word_start, dia_sorted, dia_starts)
            
            if speaker == current_speaker:
                # Same speaker - extend current group
                current_words.append(word_text)
                current_end = word_end
            else:
                # Speaker changed - emit current group and start new one
                if current_words:
                    aligned_segments.append({
                        "start": current_start,
                        "end": current_end,
                        "speaker": current_speaker,
                        "text": "".join(current_words).strip()
                    })
                
                current_speaker = speaker
                current_words = [word_text]
                current_start = word_start
                current_end = word_end
        
        # Emit final group
        if current_words:
            aligned_segments.append({
                "start": current_start,
                "end": current_end,
                "speaker": current_speaker,
                "text": "".join(current_words).strip()
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
        default=0.25,
        help="Cosine DISTANCE threshold for clustering (default: 0.25). "
             "This is 1 - similarity, so 0.25 means merge if similarity > 0.75. "
             "Lower values = stricter matching = more speakers. Range: 0.15-0.40"
    )
    parser.add_argument(
        "--output",
        "-o",
        help="Output JSON file path (default: stdout)"
    )
    
    # Smart prompt arguments
    parser.add_argument(
        "--smart-prompt",
        action="store_true",
        help="Enable smart prompt generation based on speaker identification"
    )
    parser.add_argument(
        "--speaker-db-path",
        type=str,
        default=os.path.expanduser("~/.meetingscribe/speaker.db"),
        help="Path to speaker database (default: ~/.meetingscribe/speaker.db)"
    )
    parser.add_argument(
        "--rag-endpoint",
        type=str,
        default="",
        help="RAG API endpoint for vocabulary enrichment (optional)"
    )
    parser.add_argument(
        "--iterative-refinement",
        action="store_true",
        help="Enable two-pass quick transcription for better term extraction"
    )
    parser.add_argument(
        "--quick-transcribe-seconds",
        type=float,
        default=45.0,
        help="Duration for quick transcription in smart prompt mode (default: 45)"
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
    
    # Debug: show segment distribution to verify clustering is balanced
    from collections import Counter
    speaker_counts = Counter(seg.speaker for seg in diarization_segments)
    print(f"Diarization segment distribution: {dict(speaker_counts)}", file=sys.stderr)
    
    # Step 5: Generate smart prompt (if enabled) or use static prompt
    effective_initial_prompt = args.initial_prompt
    effective_vocabulary_file = args.vocabulary_file
    smart_prompt_result = None
    
    if args.smart_prompt:
        try:
            from speaker_db import SpeakerDatabase
            from prompt_generator import generate_smart_prompt
            from vocabulary_sources import create_vocabulary_source
            
            print("Generating smart prompt based on speaker identification...", file=sys.stderr)
            
            # Initialize speaker database
            speaker_db = SpeakerDatabase(args.speaker_db_path)
            
            # Create vocabulary source if RAG endpoint provided
            rag_client = None
            if args.rag_endpoint:
                rag_client = create_vocabulary_source(rag_endpoint=args.rag_endpoint)
            
            # Generate smart prompt using embeddings we already extracted
            # Convert cluster centroids to averaged embeddings for matching
            from sklearn.preprocessing import normalize
            embeddings_normalized = normalize(embeddings, axis=1, norm='l2')
            
            # Get unique speaker embeddings (average by cluster)
            unique_labels = np.unique(labels)
            speaker_embeddings_list = []
            for label in unique_labels:
                mask = labels == label
                cluster_embeddings = embeddings_normalized[mask]
                centroid = np.mean(cluster_embeddings, axis=0)
                speaker_embeddings_list.append(centroid)
            
            # Match speakers and generate prompt
            from prompt_generator import (
                match_speakers, lookup_cache, build_prompt_with_budget,
                extract_terms, dedupe_terms, merge_vocabulary, count_tokens,
                write_vocabulary_file, compute_cache_confidence
            )
            from term_types import Term, SmartPromptResult
            
            match_result = match_speakers(speaker_embeddings_list, speaker_db)
            known_ids = [m.speaker_id for m in match_result.matched]
            unknown_count = len(match_result.unknown)
            
            # Build speaker_label_map: SPEAKER_XX → speaker_id
            speaker_label_map = {}
            for cluster_idx, match in match_result.speaker_map.items():
                label = f"SPEAKER_{cluster_idx:02d}"
                speaker_label_map[label] = match.speaker_id if match else None
            
            print(f"  Matched {len(known_ids)} known speakers, {unknown_count} unknown", file=sys.stderr)
            
            # Try cache lookup
            cache_result = lookup_cache(speaker_db, known_ids, unknown_count)
            
            if cache_result.match_type == "full" and cache_result.confidence > 0.8:
                # Cache hit!
                print(f"  Cache hit (confidence={cache_result.confidence:.2f})", file=sys.stderr)
                speaker_db.record_cache_hit(cache_result.prompt.cache_key)
                effective_initial_prompt = cache_result.prompt.prompt_text
                # Note: cached vocab terms would need to be written to file if we want to use them
                smart_prompt_result = SmartPromptResult(
                    initial_prompt=cache_result.prompt.prompt_text,
                    vocabulary_file_path=None,
                    source="cache_full",
                    speaker_ids=known_ids,
                    confidence=cache_result.confidence,
                    prompt_token_count=count_tokens(cache_result.prompt.prompt_text),
                    vocab_term_count=len(cache_result.prompt.vocabulary_terms) if cache_result.prompt.vocabulary_terms else 0,
                    cache_key=cache_result.prompt.cache_key,
                    speaker_label_map=speaker_label_map,
                )
            else:
                # Cache miss - generate new prompt
                print(f"  Cache miss, generating prompt...", file=sys.stderr)
                
                # Get known speaker terms
                known_terms = speaker_db.get_speaker_terms(known_ids, cooccurring_ids=known_ids) if known_ids else []
                
                # Quick transcribe for term extraction (if enabled)
                extracted_terms = []
                extracted_names = []
                if args.iterative_refinement:
                    try:
                        from prompt_generator import refined_quick_transcribe
                        refined = refined_quick_transcribe(
                            args.audio_file,
                            duration=args.quick_transcribe_seconds,
                            known_speaker_terms=[t.text for t in known_terms]
                        )
                        extracted_terms = refined.all_terms
                        extracted_names = refined.extracted_names
                        print(f"  Extracted {len(extracted_terms)} terms, {len(extracted_names)} names", file=sys.stderr)
                    except Exception as e:
                        print(f"  Quick transcription failed: {e}", file=sys.stderr)
                
                # Query RAG if available
                rag_terms = []
                if rag_client and (known_ids or extracted_names):
                    try:
                        from vocabulary_sources import fetch_rag_vocabulary_parallel
                        speaker_names = [speaker_db.get_speaker(sid).name for sid in known_ids 
                                        if speaker_db.get_speaker(sid) and speaker_db.get_speaker(sid).name]
                        rag_terms = fetch_rag_vocabulary_parallel(
                            rag_client,
                            speaker_names=speaker_names,
                            extracted_names=extracted_names,
                            timeout=2.0
                        )
                        print(f"  Retrieved {len(rag_terms)} terms from RAG", file=sys.stderr)
                    except Exception as e:
                        print(f"  RAG query failed: {e}", file=sys.stderr)
                
                # Merge vocabulary from all sources
                vocabulary = merge_vocabulary(
                    sources=[
                        (extracted_terms, 1.0) if extracted_terms else ([], 0),
                        (known_terms, 0.8),
                        (rag_terms, 0.6),
                    ],
                    max_terms=100,
                    dedupe=True
                )
                
                # Build prompt with token budget
                prompt_output = build_prompt_with_budget(
                    vocabulary=vocabulary,
                    names=extracted_names
                )
                
                effective_initial_prompt = prompt_output.initial_prompt
                
                # Write vocabulary file if we have overflow terms
                if prompt_output.vocabulary_terms:
                    from pathlib import Path
                    vocab_file_path = write_vocabulary_file(
                        prompt_output.vocabulary_terms,
                        output_dir=Path(args.audio_file).parent / '.meetingscribe_temp'
                    )
                    effective_vocabulary_file = vocab_file_path
                
                # Compute confidence for caching
                confidence = compute_cache_confidence(
                    known_speaker_ratio=len(known_ids) / (len(known_ids) + unknown_count) if (known_ids or unknown_count) else 0,
                    match_quality=sum(m.confidence_gap for m in match_result.matched) / len(match_result.matched) if match_result.matched else 0,
                    has_ambiguous=len(match_result.ambiguous) > 0
                )
                
                # Cache the result
                speaker_db.save_prompt(
                    known_ids=known_ids,
                    unknown_count=unknown_count,
                    prompt=prompt_output.initial_prompt,
                    vocabulary=[t.text for t in vocabulary],
                    confidence=confidence
                )
                
                # Register unknown speakers
                new_speakers = 0
                for emb in match_result.unknown:
                    new_id = speaker_db.create_speaker(centroid=np.array(emb))
                    new_speakers += 1
                    if len(match_result.unknown) == 1 and len(extracted_names) == 1:
                        speaker_db.suggest_name(
                            speaker_id=new_id,
                            suggested_name=extracted_names[0],
                            source='transcript',
                            confidence=0.5,
                            context=None
                        )
                
                from prompt_generator import compute_full_cache_key
                generated_cache_key = compute_full_cache_key(known_ids, unknown_count)
                
                smart_prompt_result = SmartPromptResult(
                    initial_prompt=prompt_output.initial_prompt,
                    vocabulary_file_path=effective_vocabulary_file,
                    source="generated",
                    speaker_ids=known_ids,
                    confidence=confidence,
                    new_speakers_created=new_speakers,
                    prompt_token_count=prompt_output.prompt_token_count,
                    vocab_term_count=prompt_output.terms_in_vocab_file,
                    cache_key=generated_cache_key,
                    speaker_label_map=speaker_label_map,
                )
                
                print(f"  Generated prompt: {len(effective_initial_prompt)} chars, {prompt_output.prompt_token_count} tokens", file=sys.stderr)
            
            speaker_db.close()
            
        except ImportError as e:
            print(f"Warning: Smart prompt dependencies not available ({e}), using static prompt", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Smart prompt generation failed ({e}), using static prompt", file=sys.stderr)
    
    # Step 6: Transcribe with Whisper
    transcription = transcribe_with_whisper(
        args.audio_file,
        model_name=args.whisper_model,
        initial_prompt=effective_initial_prompt,
        vocabulary_file=effective_vocabulary_file,
        audio_duration_seconds=audio_duration_seconds
    )
    
    # Step 7: Align transcription with diarization
    print("Aligning transcription with diarization...", file=sys.stderr)
    aligned_segments = align_transcription_with_diarization(
        transcription,
        diarization_segments
    )
    
    # Step 8: Merge consecutive segments
    merged_segments = merge_consecutive_segments(aligned_segments)
    
    # Step 9: Update speaker terms and cache quality after successful transcription
    if args.smart_prompt and smart_prompt_result and smart_prompt_result.speaker_ids:
        try:
            from speaker_db import SpeakerDatabase
            from prompt_generator import extract_terms, record_cache_quality
            
            speaker_db = SpeakerDatabase(args.speaker_db_path)
            
            # Extract terms from final transcription
            full_text = " ".join(seg["text"] for seg in merged_segments)
            new_terms = extract_terms(full_text, use_ner=True)
            
            # Update terms for all matched speakers
            for speaker_id in smart_prompt_result.speaker_ids:
                speaker_db.update_speaker_terms(
                    speaker_id,
                    new_terms[:50],  # Limit to top 50
                    cooccurring_speaker_ids=smart_prompt_result.speaker_ids
                )
            
            # Record cache quality feedback (improves prompt cache over time)
            if smart_prompt_result.cache_key:
                record_cache_quality(speaker_db, smart_prompt_result.cache_key, full_text)
                print(f"Recorded cache quality for key {smart_prompt_result.cache_key[:12]}...", file=sys.stderr)
            
            speaker_db.close()
            print(f"Updated speaker vocabulary with {len(new_terms)} terms", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Failed to update speaker terms: {e}", file=sys.stderr)
    
    # Prepare output
    output_data = {
        "segments": merged_segments,
        "speakers": speakers,
        "num_speakers": len(speakers),
        "audio_file": args.audio_file
    }
    
    # Include smart prompt metadata if available
    if smart_prompt_result:
        output_data["smart_prompt"] = {
            "source": smart_prompt_result.source,
            "confidence": smart_prompt_result.confidence,
            "known_speakers": len(smart_prompt_result.speaker_ids),
            "new_speakers": smart_prompt_result.new_speakers_created,
            "prompt_tokens": smart_prompt_result.prompt_token_count,
            "vocab_terms": smart_prompt_result.vocab_term_count
        }
        
        # Include speaker_map: SPEAKER_XX → {speaker_id, name, confidence}
        # This allows the Swift side to replace SPEAKER_XX with actual names
        if smart_prompt_result.speaker_label_map:
            speaker_map = {}
            try:
                from speaker_db import SpeakerDatabase
                speaker_db = SpeakerDatabase(args.speaker_db_path)
                for label, sid in smart_prompt_result.speaker_label_map.items():
                    if sid:
                        speaker = speaker_db.get_speaker(sid)
                        # Find confidence from match_result.speaker_map
                        cluster_idx = int(label.split("_")[1])
                        match_info = match_result.speaker_map.get(cluster_idx) if 'match_result' in dir() else None
                        speaker_map[label] = {
                            "speaker_id": sid,
                            "name": speaker.name if speaker else None,
                            "confidence": match_info.similarity if match_info else 0.0,
                        }
                    else:
                        speaker_map[label] = None
                speaker_db.close()
            except Exception as e:
                print(f"Warning: Failed to build speaker_map names: {e}", file=sys.stderr)
                # Fall back to IDs only (no names)
                speaker_map = {
                    label: {"speaker_id": sid, "name": None, "confidence": 0.0} if sid else None
                    for label, sid in smart_prompt_result.speaker_label_map.items()
                }
            output_data["speaker_map"] = speaker_map
    
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
