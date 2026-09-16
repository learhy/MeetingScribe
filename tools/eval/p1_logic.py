#!/usr/bin/env python3
"""p1_logic.py — Python mirrors of the P1 Swift logic for host-side regression.

No Swift toolchain exists on this host, so the pure-logic P1 types are
re-implemented here (same rules as the Swift sources) and exercised by
run_regression.py. KEEP IN SYNC with:

  src/core/CorrectionDictionary.swift   (teach parsing, store, corrections map)
  src/core/VerificationPass.swift       (label normalization, edit plausibility)
  src/core/AudioGuards.swift            (guards: <5 s, near-silent, WAV parse)
  src/core/AudioRetentionPolicy.swift   (30-day default retention)
  src/core/ArtifactWriter.swift         ({meeting-id}.raw.md / .note.md naming)

Any divergence between these mirrors and the Swift sources is a bug.
"""

import re
import struct
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# P1-1: CorrectionDictionary
# ---------------------------------------------------------------------------

TEACH_SEPARATORS = ["->", "=>", "→", "=gt;", "="]


def parse_teach_argument(argument: str) -> tuple[str, str]:
    """Mirror of CorrectionDictionary.parseTeachArgument."""
    for separator in TEACH_SEPARATORS:
        if separator in argument:
            wrong, right = argument.split(separator, 1)
            wrong = wrong.strip()
            right = right.strip()
            if not wrong or not right:
                raise ValueError("empty side")
            return wrong, right
    raise ValueError("missing separator")


def corrections_map(entries: list[dict]) -> dict[str, str]:
    """Mirror of CorrectionDictionary.correctionsMap (no-op entries excluded)."""
    return {
        e["wrong"]: e["right"]
        for e in entries
        if e["wrong"].lower() != e["right"].lower()
    }


def format_corrections(corrections: dict[str, str]) -> str:
    """Mirror of CorrectionDictionary.formatCorrections."""
    if not corrections:
        return ""
    pairs = " | ".join(
        f"{w} → {r}" for w, r in sorted(corrections.items(), key=lambda kv: kv[0].lower())
    )
    return (
        "\n\n## USER-TAUGHT CORRECTIONS (apply these exactly: the left name is a "
        f"known ASR error, replace it with the right name wherever it appears)\n{pairs}\n"
    )


# ---------------------------------------------------------------------------
# P1-2: VerificationPass
# ---------------------------------------------------------------------------

SPEAKER_LABEL = re.compile(r"SPEAKER_(\d{2})")


def normalize_labels(text: str, label_map: dict[str, str]) -> str:
    """Mirror of VerificationPass.normalizeLabels / NotesLabelCleaner.clean.

    Resolved labels → canonical names; unresolved → "Speaker N".
    """

    def repl(match: re.Match) -> str:
        full = match.group(0)
        if full in label_map:
            return label_map[full]
        return f"Speaker {int(match.group(1))}"

    return SPEAKER_LABEL.sub(repl, text)


def raw_text(segments: list[dict]) -> str:
    """Mirror of VerificationPass.rawText: raw labels kept verbatim."""
    return "\n".join(f"{s['speaker']}: {s['text']}" for s in segments).strip()


def is_plausible_edit(original: str, candidate: str) -> bool:
    """Mirror of VerificationPass.isPlausibleEdit (±30% word count, non-empty)."""
    if not candidate:
        return False
    original_words = len(original.split())
    candidate_words = len(candidate.split())
    if original_words == 0:
        return candidate_words > 0
    ratio = candidate_words / original_words
    return 0.7 <= ratio <= 1.3


# ---------------------------------------------------------------------------
# P1-4: AudioGuards + AudioRetentionPolicy
# ---------------------------------------------------------------------------

MINIMUM_DURATION_SECONDS = 5.0
SILENCE_RMS_FLOOR = 0.001  # ≈ -60 dBFS
NEAR_SILENT_FRACTION_THRESHOLD = 0.98


def parse_wav(data: bytes) -> tuple[int, int, list[int]]:
    """Mirror of AudioGuards.parseWAV: (sample_rate, channels, samples)."""
    if len(data) <= 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a WAV file")
    sample_rate, channels, pcm_start, pcm_length = 48000, 1, None, 0
    offset = 12
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        (chunk_size,) = struct.unpack("<I", data[offset + 4:offset + 8])
        body = offset + 8
        if chunk_id == b"fmt " and body + 16 <= len(data):
            channels = struct.unpack("<H", data[body + 2:body + 4])[0]
            (sample_rate,) = struct.unpack("<I", data[body + 4:body + 8])
        elif chunk_id == b"data":
            pcm_start = body
            pcm_length = min(chunk_size, len(data) - body)
        offset = body + chunk_size + (chunk_size % 2)
    if pcm_start is None or pcm_length <= 0:
        raise ValueError("no data chunk")
    count = pcm_length // 2
    samples = list(struct.unpack(f"<{count}h", data[pcm_start:pcm_start + count * 2]))
    return sample_rate, channels, samples


def evaluate_audio(samples: list[int], sample_rate: float, channels: int = 1) -> tuple[bool, str, dict]:
    """Mirror of AudioGuards.evaluate. Returns (accepted, reason, metrics)."""
    if not samples:
        return False, "Audio contains no samples (empty capture)", {}
    frames = len(samples) / max(1, channels)
    duration = frames / sample_rate

    norm = [s / 32768.0 for s in samples]
    rms = (sum(n * n for n in norm) / len(norm)) ** 0.5
    peak = max(abs(n) for n in norm)
    clipped = sum(1 for n in norm if abs(n) >= 0.99) / len(norm)

    frame_size = 4800  # 100 ms at 48 kHz
    silent_frames = 0
    total_frames = 0
    for i in range(0, len(norm), frame_size):
        frame = norm[i:i + frame_size]
        mean_mag = sum(abs(n) for n in frame) / len(frame)
        if mean_mag < SILENCE_RMS_FLOOR:
            silent_frames += 1
        total_frames += 1
    silent_fraction = silent_frames / total_frames if total_frames else 1.0

    metrics = {
        "durationSeconds": duration,
        "rms": rms,
        "peak": peak,
        "clippingFraction": clipped,
        "silentFrameFraction": silent_fraction,
    }

    if duration < MINIMUM_DURATION_SECONDS:
        return False, f"Audio too short: {duration:.1f}s (minimum {MINIMUM_DURATION_SECONDS:.0f}s)", metrics
    if rms < SILENCE_RMS_FLOOR or silent_fraction >= NEAR_SILENT_FRACTION_THRESHOLD:
        return False, f"Audio is near-silent: RMS {rms:.6f}, {silent_fraction * 100:.0f}% silent frames", metrics
    return True, "ok", metrics


def enforce_retention(directory: Path, retention_days: int = 30,
                      extensions: set[str] | None = None,
                      now: datetime | None = None) -> tuple[list[str], int]:
    """Mirror of AudioRetentionPolicy.enforceRetention."""
    import os

    extensions = extensions or {"wav"}
    now = now or datetime.now()
    if retention_days <= 0 or not directory.is_dir():
        return [], 0
    cutoff = now - timedelta(days=retention_days)
    deleted, freed = [], 0
    for path in directory.iterdir():
        if path.suffix.lstrip(".").lower() not in extensions:
            continue
        mtime = datetime.fromtimestamp(path.stat().st_mtime)
        if mtime < cutoff:
            size = path.stat().st_size
            path.unlink()
            deleted.append(path.name)
            freed += size
    return deleted, freed


# ---------------------------------------------------------------------------
# P1-3: ArtifactWriter naming
# ---------------------------------------------------------------------------

def artifact_paths(directory: Path, meeting_id: str) -> tuple[Path, Path]:
    """Mirror of ArtifactWriter.artifactPaths."""
    return directory / f"{meeting_id}.raw.md", directory / f"{meeting_id}.note.md"


def meeting_id(audio_file_path: str) -> str:
    """Mirror of ArtifactWriter.meetingID."""
    return Path(audio_file_path).stem
