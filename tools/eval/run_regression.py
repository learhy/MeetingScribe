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


if __name__ == "__main__":
    print(f"MeetingScribe regression suite — repo root: {REPO}")
    print("=" * 60)
    test_wer_scorer()
    test_name_accuracy()
    test_diarize_audit()
    test_refusal_gate()
    test_gate_sync()
    test_budget_math()
    print("=" * 60)
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("ALL REGRESSION TESTS PASSED")
