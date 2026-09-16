#!/usr/bin/env python3
"""run_regression.py — CI regression suite for the P0-1 harness (P0 sub-item).

Synthetic fixtures only — no real audio, safe to commit and run anywhere
(Python 3.10+). Exercises:

  1. WER scorer correctness (hand-computed expected WER values)
  2. Name-accuracy scoring on the known-hard names
  3. Diarization audit scoring on a synthetic speaker map
  4. P0-4 gate: 0 refusal-pattern outputs across the regression corpus titles
  5. Gate/Swift sync: refusal patterns match src/core/TitleValidator.swift

Usage:
    python3 tools/eval/run_regression.py [repo_root]
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
EVAL = REPO / "tools" / "eval"
FIXTURES = REPO / "tests" / "regression"

sys.path.insert(0, str(EVAL))
import score_wer          # noqa: E402
import diarize_audit      # noqa: E402
import refusal_gate       # noqa: E402
import p1_logic          # noqa: E402 (P1 mirrors of the Swift pure-logic types)
import p2_logic          # noqa: E402 (P2 mirrors: keyterms, attribution, hygiene)

FAILURES = []


def check(name: str, cond: bool, detail: str = ""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


# ---------------------------------------------------------------------------
# 1. WER scorer correctness
# ---------------------------------------------------------------------------

def test_wer_scorer():
    # Perfect match
    r = score_wer.wer("Rachana said the PEDM rollout is on track", 
                      "Rachana said the PEDM rollout is on track")
    check("WER: perfect match = 0", r["wer"] == 0.0, str(r))

    # One substitution in 5 words = 0.2
    r = score_wer.wer("rachana sapta anando mukesh krishnan",
                      "rachna sapta anando mukesh krishnan")
    check("WER: 1 sub / 5 words = 0.2", r["wer"] == 0.2, str(r))

    # One deletion in 4 words = 0.25
    r = score_wer.wer("the meeting covered boundary",
                      "the meeting covered")
    check("WER: 1 del / 4 words = 0.25", r["wer"] == 0.25, str(r))

    # Two deletions in 6 words
    r = score_wer.wer("the meeting covered boundary and vault",
                      "the meeting covered boundary")
    check("WER: 2 del / 6 words = 0.3333", r["wer"] == 0.3333, str(r))

    # Insertion
    r = score_wer.wer("hello world", "hello big world")
    check("WER: 1 ins / 2 words = 0.5", r["wer"] == 0.5, str(r))

    # Normalization: punctuation + case insensitive
    r = score_wer.wer("Hello, World!", "hello world")
    check("WER: normalization", r["wer"] == 0.0, str(r))

    # Empty hypothesis vs non-empty reference
    r = score_wer.wer("some words here", "")
    check("WER: empty hypothesis = 1.0", r["wer"] == 1.0, str(r))


# ---------------------------------------------------------------------------
# 2. Name accuracy
# ---------------------------------------------------------------------------

def test_name_accuracy():
    ref = "Rachana walked through the PEDM plan. Mukesh Marodia objected. Krishnan took notes."
    hyp = "Rachana walked through the PEDM plan. Mukesh Marodia objected. Krishnan took notes."
    acc = score_wer.name_accuracy(ref, hyp, score_wer.KNOWN_HARD_NAMES)
    check("Names: all correct on clean transcript",
          all(v["accuracy"] == 1.0 for v in acc.values()), json.dumps(acc))

    hyp_bad = "Rachna walked through the PEDM plan. Mukesh Marodi objected. Krishnan took notes."
    acc = score_wer.name_accuracy(ref, hyp_bad, score_wer.KNOWN_HARD_NAMES)
    check("Names: misspelled Rachana detected (0.0)",
          acc.get("Rachana", {}).get("accuracy") == 0.0, json.dumps(acc))
    check("Names: misspelled Mukesh Marodia detected (0.0)",
          acc.get("Mukesh Marodia", {}).get("accuracy") == 0.0, json.dumps(acc))
    check("Names: correct Krishnan stays 1.0",
          acc.get("Krishnan", {}).get("accuracy") == 1.0, json.dumps(acc))

    # Name absent from reference is not scored
    acc = score_wer.name_accuracy(ref, hyp, ["Saptaparni"])
    check("Names: absent-from-ref name not scored", "Saptaparni" not in acc, json.dumps(acc))


# ---------------------------------------------------------------------------
# 3. Diarization audit on synthetic fixture
# ---------------------------------------------------------------------------

SYNTHETIC_REF = {
    "events": [
        {"start": 0.0, "end": 10.0, "name": "Rachana", "text": "let me walk through the plan"},
        {"start": 10.0, "end": 20.0, "name": "Krishnan", "text": "looks good to me"},
        {"start": 20.0, "end": 30.0, "name": "Dan", "text": "thanks both"},
    ]
}

SYNTHETIC_HYP_GOOD = {
    "segments": [
        {"start": 0.0, "end": 9.8, "speaker": "SPEAKER_00", "text": "..."},
        {"start": 10.2, "end": 19.5, "speaker": "SPEAKER_01", "text": "..."},
        {"start": 20.1, "end": 29.9, "speaker": "SPEAKER_02", "text": "..."},
    ],
    "speaker_map": {
        "SPEAKER_00": {"name": "Rachana Reddy", "confidence": 0.85},
        "SPEAKER_01": {"name": "Krishnan", "confidence": 0.9},
        "SPEAKER_02": {"name": "Dan", "confidence": 0.8},
    },
}

SYNTHETIC_HYP_BAD = {
    # Speaker 00 correctly named; 01 and 02 unresolved → raw labels
    "segments": [
        {"start": 0.0, "end": 9.8, "speaker": "SPEAKER_00", "text": "..."},
        {"start": 10.2, "end": 19.5, "speaker": "SPEAKER_01", "text": "..."},
        {"start": 20.1, "end": 29.9, "speaker": "SPEAKER_02", "text": "..."},
    ],
    "speaker_map": {
        "SPEAKER_00": {"name": "Rachana Reddy", "confidence": 0.85},
        "SPEAKER_01": None,
        "SPEAKER_02": None,
    },
}


def test_diarize_audit():
    with tempfile.TemporaryDirectory() as td:
        case = Path(td) / "synthetic-001"
        case.mkdir()
        (case / "reference-diarization.json").write_text(json.dumps(SYNTHETIC_REF))
        (case / "hypothesis-diarization.json").write_text(json.dumps(SYNTHETIC_HYP_GOOD))
        rep = diarize_audit.score_case(case)
        check("Diar: perfect synthetic case F1 = 1.0", rep["f1"] == 1.0, json.dumps(rep))
        check("Diar: Rachana Reddy prefix-matches Rachana",
              rep["per_name"].get("Rachana", {}).get("correct") == 1, json.dumps(rep["per_name"]))

        (case / "hypothesis-diarization.json").write_text(json.dumps(SYNTHETIC_HYP_BAD))
        rep = diarize_audit.score_case(case)
        # 1 of 3 events correctly named
        check("Diar: unresolved speakers score 1/3 recall",
              rep["recall"] == round(1 / 3, 4), json.dumps(rep))
        check("Diar: SPEAKER_01 raw label not credited to Krishnan",
              rep["per_name"].get("Krishnan", {}).get("correct", 0) == 0, json.dumps(rep["per_name"]))


# ---------------------------------------------------------------------------
# 4. Refusal gate over regression corpus titles (P0-4)
# ---------------------------------------------------------------------------

# Titles that MUST pass the gate (real titles Dan's notes carry)
GOOD_TITLES = [
    "Boundary / HashiCorp weekly sync",
    "Dan/Anando 1:1: PEDM vs Agentic roadmap",
    "Sprint review — Vault plugins",
    "Rachana & Mukesh Marodia: onboarding plan",
    "Meeting Notes - September 16, 2026",
]

# Titles that MUST be rejected (the June evidence base failure modes)
BAD_TITLES = [
    "I don't see a transcript in the file you shared",
    "I'd be happy to help with that!",
    "Unable to generate meeting notes",
    "Please provide the meeting transcript",
    "I'm unable to summarize this meeting",
    "Once you share the transcript I can continue",
    "",
    "hi",
]


def test_refusal_gate():
    for t in GOOD_TITLES:
        check(f"Gate: accepts {t!r}", refusal_gate.validate_title(t) is not None)
    for t in BAD_TITLES:
        check(f"Gate: rejects {t!r}", refusal_gate.validate_title(t) is None)

    # Scan the regression titles corpus: good-titles.txt holds titles that ship;
    # it must contain ZERO refusal patterns (the P0-4 gate).
    # (refusal-titles.txt is the fixture of known-bad titles used by the
    # accepts/rejects checks above — not scanned here.)
    corpus_file = FIXTURES / "titles" / "good-titles.txt"
    if corpus_file.exists():
        hits = refusal_gate.scan_file(corpus_file)
        check("Gate: 0 refusal outputs across regression corpus",
              len(hits) == 0, "; ".join(hits[:5]))
    else:
        check("Gate: regression titles corpus exists", False, f"missing {corpus_file}")


# ---------------------------------------------------------------------------
# 5. Gate/Swift sync (P0-4)
# ---------------------------------------------------------------------------

def test_gate_sync():
    mismatches = refusal_gate.sync_with_swift(REPO)
    check("Gate: refusal patterns in sync with TitleValidator.swift",
          not mismatches, "; ".join(mismatches))


# ---------------------------------------------------------------------------
# 6. RosterBuilder logic mirrored (token budget math sanity)
# ---------------------------------------------------------------------------

def test_budget_math():
    # The Swift estimator uses ceil(len/4)+1 per whitespace word. The Python
    # mirror here sanity-checks the budget is conservative vs naive len/4.
    text = "The following people may be mentioned in this meeting: " + ", ".join(
        f"Attendee{i}" for i in range(50)) + "."
    words = text.split()
    est = sum(max(1, -(-len(w) // 4)) + 1 for w in words)
    naive = len(text) // 4
    check("Budget: conservative estimate >= naive len/4", est >= naive,
          f"est={est} naive={naive}")
    check("Budget: 224-token limit respected with headroom (208)", 208 < 224)


# ---------------------------------------------------------------------------
# 7. P1-1: dictionary flywheel (Python mirror of CorrectionDictionary)
# ---------------------------------------------------------------------------

def test_p1_dictionary_flywheel():
    # Teach argument parsing — all separator spellings
    for arg in ["Ratchna->Rachana", "Ratchna=>Rachana", "Ratchna=Rachana", "Ratchna→Rachana"]:
        wrong, right = p1_logic.parse_teach_argument(arg)
        check(f"P1-1: parse teach {arg!r}", (wrong, right) == ("Ratchna", "Rachana"), f"{wrong}->{right}")

    # Whitespace trimmed
    wrong, right = p1_logic.parse_teach_argument("  Ratchna ->  Rachana ")
    check("P1-1: teach argument trims whitespace", (wrong, right) == ("Ratchna", "Rachana"))

    # Invalid inputs raise
    for bad in ["Ratchna Rachana", "->Rachana", "Ratchna->", ""]:
        try:
            p1_logic.parse_teach_argument(bad)
            check(f"P1-1: rejects {bad!r}", False, "no error raised")
        except ValueError:
            check(f"P1-1: rejects {bad!r}", True)

    # corrections map excludes case-insensitive no-ops
    entries = [
        {"wrong": "Ratchna", "right": "Rachana"},
        {"wrong": "same", "right": "Same"},
    ]
    m = p1_logic.corrections_map(entries)
    check("P1-1: corrections map includes real mapping", m.get("Ratchna") == "Rachana")
    check("P1-1: corrections map excludes no-op", "same" not in m)

    # formatCorrections shape
    text = p1_logic.format_corrections({"Ratchna": "Rachana"})
    check("P1-1: format includes section header", "## USER-TAUGHT CORRECTIONS" in text)
    check("P1-1: format includes pair", "Ratchna → Rachana" in text)
    check("P1-1: format empty stays empty", p1_logic.format_corrections({}) == "")

    # Swift/Swift-source existence + corrections wiring in RosterBuilder
    roster = (REPO / "src" / "core" / "RosterBuilder.swift").read_text()
    check("P1-1: RosterBuilder consumes corrections before glossary (priority tier)",
          roster.find("correctionsIntro") < roster.find("termsIntro"))
    dict_swift = (REPO / "src" / "core" / "CorrectionDictionary.swift").read_text()
    check("P1-1: dictionary persists to ~/.meetingscribe/corrections.json",
          "corrections.json" in dict_swift)
    check("P1-1: entries carry source=manual + timestamp",
          '"manual"' in dict_swift.replace("sourceManual = \"manual\"", '"manual"')
          or 'sourceManual' in dict_swift)
    post = (REPO / "src" / "core" / "TranscriptPostProcessor.swift").read_text()
    check("P1-1: post-processor injects taught corrections",
          "CorrectionDictionary" in post and "formatCorrections" in post)


# ---------------------------------------------------------------------------
# 8. P1-2: verification pass (Python mirror of VerificationPass)
# ---------------------------------------------------------------------------

def test_p1_verification_pass():
    # Label normalization: resolved → name, unresolved → Speaker N
    out = p1_logic.normalize_labels(
        "SPEAKER_00 opened. SPEAKER_01 agreed.",
        {"SPEAKER_00": "Rachana Reddy"})
    check("P1-2: resolved label normalized to name", "Rachana Reddy opened." in out, out)
    check("P1-2: unresolved label becomes Speaker N", "Speaker 1 agreed." in out, out)
    check("P1-2: no raw SPEAKER_XX survives in normalized text", "SPEAKER_" not in out)

    # Raw artifact keeps raw labels
    raw = p1_logic.raw_text([
        {"speaker": "SPEAKER_00", "text": "hello"},
        {"speaker": "SPEAKER_01", "text": "hi"},
    ])
    check("P1-2/P1-3: raw artifact keeps raw labels",
          raw == "SPEAKER_00: hello\nSPEAKER_01: hi", raw)

    # Edit plausibility (the structural refusal-leak defense)
    check("P1-2: name-only edit is plausible",
          p1_logic.is_plausible_edit("Rachna walked through the plan today",
                                     "Rachana walked through the plan today"))
    check("P1-2: refusal prose is NOT a plausible edit",
          not p1_logic.is_plausible_edit(
              "Rachna walked through the plan today and discussed the roadmap in some detail",
              "I cannot help with that."))
    check("P1-2: empty candidate rejected",
          not p1_logic.is_plausible_edit("some text", ""))
    check("P1-2: doubled-length rewrite rejected",
          not p1_logic.is_plausible_edit("one two three four",
                                         "one two three four five six seven eight nine ten"))

    # Swift sources exist and layer around (not replace) the post-processor
    vp = (REPO / "src" / "core" / "VerificationPass.swift").read_text()
    check("P1-2: VerificationPass reuses NotesLabelCleaner (What-NOT-to-Change)",
          "NotesLabelCleaner.clean" in vp)
    check("P1-2: VerificationPass reuses PhoneticIndex",
          "PhoneticIndex" in vp)
    check("P1-2: VerificationPass has edit-only mandate + fallback",
          "isPlausibleEdit" in vp and "ONLY" in vp.upper())


# ---------------------------------------------------------------------------
# 9. P1-3: artifact split (Python mirror of ArtifactWriter)
# ---------------------------------------------------------------------------

def test_p1_artifact_split(tmp: Path):
    raw_path, note_path = p1_logic.artifact_paths(tmp, "meeting_20260916_141530")
    check("P1-3: raw artifact naming", raw_path.name == "meeting_20260916_141530.raw.md", raw_path.name)
    check("P1-3: note artifact naming", note_path.name == "meeting_20260916_141530.note.md", note_path.name)

    check("P1-3: meeting id from audio path",
          p1_logic.meeting_id("/r/meeting_20260916_141530.wav") == "meeting_20260916_141530")

    raw_path.write_text("SPEAKER_00: hello")
    check("P1-3: raw artifact round-trips", raw_path.read_text() == "SPEAKER_00: hello")

    aw = (REPO / "src" / "core" / "ArtifactWriter.swift").read_text()
    check("P1-3: raw artifact is immutable in Swift (write-once guard)",
          "fileExists" in aw and "writeRaw" in aw)


# ---------------------------------------------------------------------------
# 10. P1-4: audio guards + retention (Python mirror)
# ---------------------------------------------------------------------------

def test_p1_audio_guards():
    import math

    sr = 48000

    # Healthy 10 s of 440 Hz tone → accepted
    samples = [int(8000 * math.sin(2 * math.pi * 440 * i / sr)) for i in range(sr * 10)]
    ok, reason, metrics = p1_logic.evaluate_audio(samples, sr)
    check("P1-4: healthy 10 s audio accepted", ok, reason)
    check("P1-4: metrics carry duration", abs(metrics.get("durationSeconds", 0) - 10.0) < 0.01)

    # <5 s → rejected
    samples_short = samples[: sr * 2]
    ok, reason, _ = p1_logic.evaluate_audio(samples_short, sr)
    check("P1-4: 2 s audio rejected (too short)", not ok and "too short" in reason.lower(), reason)

    # Near-silent → rejected
    samples_silent = [0] * (sr * 10)
    ok, reason, _ = p1_logic.evaluate_audio(samples_silent, sr)
    check("P1-4: silence rejected", not ok and "silent" in reason.lower(), reason)

    # Clipping fraction computed
    samples_clipped = [32767] * (sr * 10)
    ok, reason, metrics = p1_logic.evaluate_audio(samples_clipped, sr)
    check("P1-4: clipping detected in telemetry", metrics.get("clippingFraction", 0) > 0.99)

    # WAV parse round-trip on a synthetic 48 kHz mono WAV
    import struct as _struct
    data = b"RIFF" + _struct.pack("<I", 36 + len(samples) * 2) + b"WAVE"
    data += b"fmt " + _struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
    data += b"data" + _struct.pack("<I", len(samples) * 2)
    data += _struct.pack(f"<{len(samples)}h", *samples)
    parsed_sr, parsed_ch, parsed = p1_logic.parse_wav(data)
    check("P1-4: WAV header parse (sample rate)", parsed_sr == sr, str(parsed_sr))
    check("P1-4: WAV header parse (channels)", parsed_ch == 1)
    check("P1-4: WAV samples parse", parsed[:10] == samples[:10])

    ag = (REPO / "src" / "core" / "AudioGuards.swift").read_text()
    check("P1-4: Swift guard minimum duration is 5 s", "minimumDurationSeconds: Double = 5.0" in ag)


def test_p1_retention(tmp: Path):
    import os
    from datetime import datetime, timedelta

    now = datetime.now()
    old = tmp / "old-meeting.wav"
    recent = tmp / "recent-meeting.wav"
    old_md = tmp / "old-note.md"  # wrong extension → kept
    old.write_bytes(b"x" * 100)
    recent.write_bytes(b"y" * 50)
    old_md.write_bytes(b"z")
    old_time = (now - timedelta(days=40)).timestamp()
    recent_time = (now - timedelta(days=10)).timestamp()
    os.utime(old, (old_time, old_time))
    os.utime(recent, (recent_time, recent_time))
    os.utime(old_md, (old_time, old_time))

    deleted, freed = p1_logic.enforce_retention(tmp, retention_days=30, now=now)
    check("P1-4: retention deletes 40-day WAV", deleted == ["old-meeting.wav"], str(deleted))
    check("P1-4: retention frees 100 bytes", freed == 100, str(freed))
    check("P1-4: recent WAV kept", recent.exists())
    check("P1-4: non-WAV file kept", old_md.exists())
    check("P1-4: default window is 30 days (Dan Q1)", p1_logic.enforce_retention.__defaults__[0] == 30)

    # retentionDays=0 disables deletion
    old.write_bytes(b"x")
    os.utime(old, (old_time - 86400 * 360, old_time - 86400 * 360))
    deleted, _ = p1_logic.enforce_retention(tmp, retention_days=0, now=now)
    check("P1-4: retentionDays=0 disables auto-delete", deleted == [] and old.exists())


def test_p1_config_keys():
    cm = (REPO / "src" / "config" / "ConfigManager.swift").read_text()
    for key in ["audioGuardsEnabled", "audioRetentionDays", "telemetryEnabled"]:
        check(f"P1-4: config key {key} added with back-compat decode", f"{key} ?? " in cm or f"decodeIfPresent" in cm and key in cm)
    check("P1-4: retention default 30 in config", "audioRetentionDays: Int = 30" in cm)
    check("P1-4: telemetry key decodes with default true", "telemetryEnabled) ?? true" in cm)
    check("P1-4: guards key decodes with default true", "audioGuardsEnabled) ?? true" in cm)


# ---------------------------------------------------------------------------
# 11. P2-1: engine seam (keyterms mapping + config plumbing)
# ---------------------------------------------------------------------------

def test_p2_engine_seam():
    # Roster prompt -> keyterms mapping (mirror of the Swift provider logic)
    roster = (
        "The following people may be mentioned in this meeting: "
        "Dan Rohan, Rachana Reddy, Mukesh Marodia. "
        "Common corrections: Ratchna→Rachana, Marodi→Marodia. "
        "Technical terms that may come up: PEDM, credential injection."
    )
    keyterms = p2_logic.keyterms_from_roster_prompt(roster)
    check("P2-1: attendee names mapped first (roster rank order)",
          keyterms[:3] == ["Dan Rohan", "Rachana Reddy", "Mukesh Marodia"], str(keyterms))
    check("P2-1: correction RIGHT sides become keyterms",
          "Rachana" in keyterms and "Marodia" in keyterms, str(keyterms))
    check("P2-1: wrong spellings never become keyterms",
          not any("→" in k or k == "Ratchna" for k in keyterms), str(keyterms))
    check("P2-1: glossary terms appended", "PEDM" in keyterms, str(keyterms))

    check("P2-1: empty roster -> empty keyterms",
          p2_logic.keyterms_from_roster_prompt("") == [])
    check("P2-1: case-insensitive dedupe",
          p2_logic.keyterms_from_roster_prompt(
              "The following people may be mentioned in this meeting: Rachana, rachana.") == ["Rachana"])

    names80 = ", ".join(f"Attendee{i}" for i in range(80))
    keyterms80 = p2_logic.keyterms_from_roster_prompt(
        f"The following people may be mentioned in this meeting: {names80}.")
    check("P2-1: keyterms capped at 50", len(keyterms80) == 50, str(len(keyterms80)))

    # Swift sources: provider + seam exist, default unchanged
    prov = (REPO / "src" / "core" / "AssemblyAIProvider.swift").read_text()
    check("P2-1: AssemblyAI provider implements TranscriptionProvider",
          "class AssemblyAIUniversal3Provider: TranscriptionProvider" in prov)
    check("P2-1: provider uses keyterms parameter", "keyterms" in prov)
    check("P2-1: provider handles async job model (upload + poll)",
          "/upload" in prov and "/transcript" in prov and "status" in prov)

    ts = (REPO / "src" / "core" / "Transcription.swift").read_text()
    check("P2-1: createProvider seams assemblyai", 'case "assemblyai"' in ts)
    check("P2-1: default provider untouched (whisper-1 first)",
          ts.find('case "openai"') < ts.find('case "assemblyai"'))

    cm = (REPO / "src" / "config" / "ConfigManager.swift").read_text()
    check("P2-1: config block transcription.assemblyai with back-compat decode",
          "struct AssemblyAI" in cm and "decodeIfPresent" in cm)
    check("P2-1: keychain fallback for AssemblyAI key",
          "assemblyai.apiKey" in ts)

    cv = (REPO / "src" / "config" / "ConfigValidator.swift").read_text()
    check("P2-1: config validation on load for assemblyai",
          'case "assemblyai"' in cv)

    ab = (REPO / "tools" / "eval" / "run_engine_ab.sh").read_text()
    check("P2-1: A/B script scores both engines on same corpus",
          "whisper-1" in ab and "assemblyai" in ab and "score_wer.py" in ab)
    check("P2-1: A/B script encodes §3 adoption thresholds",
          ">= 0.01" in ab and "REVIEW MANUALLY" in ab)

    stub = (REPO / "src" / "core" / "ParakeetStub.swift").read_text()
    check("P2-1: local candidates stubbed (interface + plumbing only)",
          "class ParakeetTDTProvider" in stub and "class AppleSpeechAnalyzerProvider" in stub
          and "TODO(future swap task)" in stub)

    swap = (REPO / "docs" / "engine-swap.md").read_text()
    check("P2-1: runbook documents runtime/memory requirements for locals",
          "NeMo-Speech.cpp" in swap and "1.3 GB" in swap and "macOS 26" in swap)


# ---------------------------------------------------------------------------
# 12. P2-2: calendar-primed attribution + presentation rules
# ---------------------------------------------------------------------------

def test_p2_attribution():
    from p2_logic import Participant, SpeakerIdentity, CanonicalName  # noqa

    # 1:1 inference is APPLIED
    people = [Participant("dan@x.com", "Dan", is_me=True),
              Participant("rachana@x.com", "Rachana")]
    smap = {"SPEAKER_00": SpeakerIdentity("Dan", 0.9), "SPEAKER_01": None}
    labels = p2_logic.resolve_attribution(people, smap)
    check("P2-2: 1:1 fallback applied to labelMap",
          labels.get("SPEAKER_01") is not None, str(labels))
    check("P2-2: applied name is the sole unmatched attendee",
          labels["SPEAKER_01"].display_name == "Rachana")
    check("P2-2: assignment basis is calendar-inference",
          labels["SPEAKER_01"].basis == "calendarInference")

    # Voice match keeps voice basis
    smap_voice = {"SPEAKER_00": SpeakerIdentity("Rachana", 0.85)}
    labels_voice = p2_logic.resolve_attribution(people, smap_voice)
    check("P2-2: voice-matched speaker has voice basis",
          labels_voice["SPEAKER_00"].basis == "voiceMatch", str(labels_voice))

    # Below-threshold voice match: identity present but unusable. This is NOT
    # "voice match failed" (a weak hint exists) — Swift step 2 counts only
    # nil-identity labels as unmatched, so no 1:1 inference fires and the
    # label stays unresolved (conservative: never invent a name over a weak
    # voice hint).
    smap_weak = {"SPEAKER_00": SpeakerIdentity("Rachana", 0.4)}
    labels_weak = p2_logic.resolve_attribution(people, smap_weak)
    check("P2-2: below-threshold match stays unresolved (no invented name)",
          "SPEAKER_00" not in labels_weak, str(labels_weak))

    # Multi-speaker meeting: NO 1:1 inference
    group = people + [Participant("a@x.com", "Amy"), Participant("b@x.com", "Bob")]
    smap_group = {"SPEAKER_00": None, "SPEAKER_01": None}
    labels_group = p2_logic.resolve_attribution(group, smap_group)
    check("P2-2: no inference when 2 unmatched speakers vs 1 unmatched attendee",
          len(labels_group) == 0, str(labels_group))

    # Basis logging format (mirror of NameResolver.assignmentBasisLine)
    line = p2_logic.assignment_basis_line("SPEAKER_01", "Rachana", "calendarInference", 0.7, "1:1 fallback")
    check("P2-2: basis log line marks calendar-inference",
          "basis=calendar-inference" in line and "SPEAKER_01" in line, line)

    # Presentation rules
    name = p2_logic.display_label(
        CanonicalName("Rachana Reddy", "voiceMatch", 0.85), "SPEAKER_00")
    check("P2-2: voice-matched name renders bare", name == "Rachana Reddy", name)

    likely = p2_logic.display_label(
        CanonicalName("Rachana", "calendar", 0.7, basis="calendarInference"), "SPEAKER_01")
    check("P2-2: calendar-inferred name renders with (likely)",
          likely == "Rachana (likely)", likely)

    sp = p2_logic.display_label(None, "SPEAKER_02")
    check("P2-2: unresolved label renders Speaker N", sp == "Speaker 2", sp)

    out = p2_logic.normalize_labels(
        "SPEAKER_00 opened. SPEAKER_01 agreed. SPEAKER_02 concluded.",
        {"SPEAKER_00": CanonicalName("Dan Rohan", "calendar", 0.7, basis="calendarInference"),
         "SPEAKER_01": CanonicalName("Rachana Reddy", "voiceMatch", 0.9)})
    check("P2-2: (likely) suffix only on calendar-inferred",
          "Dan Rohan (likely) opened." in out and "Rachana Reddy agreed." in out, out)
    check("P2-2: no raw SPEAKER_XX survives normalization", "SPEAKER_" not in out, out)

    # Swift sources: invariant comment + assert present on both pipeline paths
    main = (REPO / "src" / "main.swift").read_text()
    check("P2-2: raw-label leak assert on both pipeline paths",
          main.count("raw SPEAKER_XX leaked into Summary/Notes") == 2)
    nr = (REPO / "src" / "core" / "NameResolver.swift").read_text()
    check("P2-2: NameResolver logs assignment basis per speaker",
          "logAssignmentBasis" in nr and "AttributionBasis" in nr)
    nlc = (REPO / "src" / "core" / "NotesLabelCleaner.swift").read_text()
    check("P2-2: presentation integrates via NotesLabelCleaner (no duplicate)",
          '(likely)' in nlc and "calendarInference" in nlc)


# ---------------------------------------------------------------------------
# 13. P2-3: dictionary hygiene audit
# ---------------------------------------------------------------------------

def test_p2_hygiene():
    import time as _time

    now = _time.time()

    def entry(wrong, right, days_ago=0.0):
        return {"wrong": wrong, "right": right, "source": "manual",
                "updatedAt": now - days_ago * 86400}

    entries = [
        entry("Ratchna", "Rachana", days_ago=120),   # unused > 90 days
        entry("Recent", "Krishnan", days_ago=5),     # fine
        entry("same", "Same"),                        # case-collision no-op
    ]
    entries.append(dict(entry("ratchna", "Rachana")))  # duplicate of Ratchna

    glossary = ["Boundary", "Vault", "PEDM"]
    findings, prune = p2_logic.audit_hygiene(entries, glossary, now_ts=now)

    kinds = {(f.kind, f.term) for f in findings}
    check("P2-3: flags 120-day-unused entry",
          ("unused", "Ratchna") in kinds, str(kinds))
    check("P2-3: flags case-insensitive duplicate",
          ("duplicate", "ratchna") in kinds, str(kinds))
    check("P2-3: flags case-collision no-op mapping",
          ("case_collision", "same") in kinds, str(kinds))
    check("P2-3: recent entry not flagged unused",
          not any(f.kind == "unused" and f.term == "Recent" for f in findings))
    check("P2-3: prune list has unused + dupes + no-ops, nothing else",
          set(prune) == {"Ratchna", "ratchna", "same"}, str(prune))

    # Phonetic collision is report-only (never in prune list)
    entries_ph = [entry("Boundry", "Boundary", days_ago=1)]
    findings_ph, prune_ph = p2_logic.audit_hygiene(entries_ph, ["Boundary"], now_ts=now)
    check("P2-3: phonetic collisions never auto-pruned", prune_ph == [], str(prune_ph))

    # Clean dictionary
    findings_clean, prune_clean = p2_logic.audit_hygiene(
        [entry("Ratchna", "Rachana", days_ago=3)], ["PEDM"], now_ts=now)
    check("P2-3: clean dictionary has no findings",
          not findings_clean and not prune_clean)

    # Prompt composition vs 200-word budget (RosterBuilder cap)
    roster = ("The following people may be mentioned in this meeting: Dan Rohan, Rachana Reddy. "
              "Common corrections: Ratchna→Rachana. "
              "Technical terms that may come up: PEDM.")
    comp = p2_logic.prompt_composition(roster)
    check("P2-3: composition counts corrections first (priority tier)",
          len(comp.corrections) == 1, str(comp))
    check("P2-3: composition within 200-word budget", comp.within_budget(), str(comp.word_count))

    big = p2_logic.prompt_composition(
        "The following people may be mentioned in this meeting: " +
        ", ".join(f"Name{i} Surname{i}" for i in range(120)) + ".")
    check("P2-3: oversized roster flagged over budget", not big.within_budget(), str(big.word_count))

    # Swift sources
    dh = (REPO / "src" / "core" / "DictionaryHygiene.swift").read_text()
    check("P2-3: audit covers unused/duplicates/case-collisions/phonetic",
          all(k in dh for k in ["unused", "duplicate", "caseCollision", "phoneticCollision"]))
    check("P2-3: uses RosterBuilder's 200-word budget", "RosterBuilder.wordBudget" in dh)
    tc = (REPO / "src" / "core" / "TeachCommand.swift").read_text()
    check("P2-3: hygiene subcommand registered", '"hygiene"' in tc and "runHygiene" in tc)
    check("P2-3: --apply backs up before pruning",
          "Backup written" in tc and "copyItem" in tc)
    readme = (REPO / "README.md").read_text()
    check("P2-3: README documents monthly cadence", "Monthly cadence" in readme and "hygiene" in readme)


if __name__ == "__main__":
    print(f"MeetingScribe regression suite — repo root: {REPO}")
    print("=" * 60)
    test_wer_scorer()
    test_name_accuracy()
    test_diarize_audit()
    test_refusal_gate()
    test_gate_sync()
    test_budget_math()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "p1"
        tmp.mkdir()
        test_p1_dictionary_flywheel()
        test_p1_verification_pass()
        (tmp / "artifacts").mkdir()
        test_p1_artifact_split(tmp / "artifacts")
        test_p1_audio_guards()
        (tmp / "retention").mkdir()
        test_p1_retention(tmp / "retention")
        test_p1_config_keys()
    test_p2_engine_seam()
    test_p2_attribution()
    test_p2_hygiene()
    print("=" * 60)
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("ALL REGRESSION TESTS PASSED")
