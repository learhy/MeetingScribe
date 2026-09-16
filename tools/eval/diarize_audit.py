#!/usr/bin/env python3
"""diarize_audit.py — name-event F1 + per-name assignment accuracy for MeetingScribe.

Scores a diarized hypothesis (event list + voice-match map) against a reference
case for the P0-1 eval harness.

Reference side (per corpus case):
    <case>/reference-diarization.json  — hand-checked event list:
        {
          "events": [
            {"start": 0.0, "end": 12.4, "name": "Rachana", "text": "..."},
            ...
          ]
        }
    (text optional; only start/end/name are scored)

Hypothesis side (produced by the pipeline):
    <case>/hypothesis-diarization.json — diarization output + voice-match map:
        {
          "segments": [{"start": 0.0, "end": 12.4, "speaker": "SPEAKER_00", "text": "..."}],
          "speaker_map": {"SPEAKER_00": {"name": "Rachana Reddy", "confidence": 0.82},
                          "SPEAKER_01": null}
        }

Scoring:
    1. Name-event F1: hypothesis events (segment + resolved name, or the raw
       speaker label if unresolved) are matched to reference events by temporal
       overlap >= 0.5 of the shorter event AND matching name (case-insensitive
       prefix match so "Rachana" matches "Rachana Reddy"). Precision/recall/F1
       over the whole case, plus per-name breakdown.
    2. Assignment accuracy per name: of the reference events attributed to name
       X, the fraction covered by a hypothesis event attributed to X.

Usage:
    python3 diarize_audit.py <case_dir> [<case_dir> ...]
    python3 diarize_audit.py corpus/ --json report.json
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def load_json(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def overlap(a_start, a_end, b_start, b_end) -> float:
    """Temporal overlap of two intervals normalized by the shorter interval."""
    inter = min(a_end, b_end) - max(a_start, b_start)
    if inter <= 0:
        return 0.0
    shorter = min(a_end - a_start, b_end - b_start)
    if shorter <= 0:
        return 0.0
    return inter / shorter


def name_matches(hyp_name: str, ref_name: str) -> bool:
    """Case-insensitive prefix match: 'Rachana' matches 'Rachana Reddy'."""
    h = (hyp_name or "").strip().lower()
    r = (ref_name or "").strip().lower()
    if not h or not r:
        return False
    return h == r or h.startswith(r) or r.startswith(h)


def extract_ref_events(case_dir: Path) -> list:
    ref = load_json(case_dir / "reference-diarization.json")
    events = []
    for ev in ref.get("events", []):
        events.append({
            "start": float(ev["start"]),
            "end": float(ev["end"]),
            "name": ev.get("name", ""),
        })
    return events


def extract_hyp_events(case_dir: Path) -> list:
    hyp = load_json(case_dir / "hypothesis-diarization.json")
    speaker_map = hyp.get("speaker_map") or {}
    conf_threshold = 0.6  # matches TranscriptionService.speakerNameConfidenceThreshold

    events = []
    for seg in hyp.get("segments", []):
        label = seg.get("speaker", "")
        identity = speaker_map.get(label)
        name = None
        if identity and identity.get("name"):
            if identity.get("confidence", 0.0) >= conf_threshold:
                name = identity["name"]
        events.append({
            "start": float(seg["start"]),
            "end": float(seg["end"]),
            "name": name if name else label,  # raw SPEAKER_XX counts as its own "name"
        })
    return events


def score_case(case_dir: Path) -> dict:
    ref_events = extract_ref_events(case_dir)
    hyp_events = extract_hyp_events(case_dir)

    # Greedy temporal-overlap matching: for each ref event, find the best
    # overlapping hyp event (each hyp event consumed at most once).
    used = [False] * len(hyp_events)
    tp = 0
    per_name = defaultdict(lambda: {"ref": 0, "correct": 0, "hyp": 0})

    for ref in ref_events:
        per_name[ref["name"]]["ref"] += 1
        best_i, best_ov = None, 0.0
        for i, hyp in enumerate(hyp_events):
            if used[i]:
                continue
            ov = overlap(ref["start"], ref["end"], hyp["start"], hyp["end"])
            if ov >= 0.5 and ov > best_ov:
                best_i, best_ov = i, ov
        if best_i is not None and name_matches(hyp_events[best_i]["name"], ref["name"]):
            used[best_i] = True
            tp += 1
            per_name[ref["name"]]["correct"] += 1

    for hyp in hyp_events:
        per_name[hyp["name"]]["hyp"] += 1

    fp = len(hyp_events) - tp
    fn = len(ref_events) - tp
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0

    name_report = {}
    for name, counts in sorted(per_name.items()):
        acc = counts["correct"] / counts["ref"] if counts["ref"] else 0.0
        name_report[name] = {
            "ref_events": counts["ref"],
            "hyp_events": counts["hyp"],
            "correct": counts["correct"],
            "assignment_accuracy": round(acc, 4),
        }

    return {
        "case": case_dir.name,
        "ref_events": len(ref_events),
        "hyp_events": len(hyp_events),
        "tp": tp, "fp": fp, "fn": fn,
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "f1": round(f1, 4),
        "per_name": name_report,
    }


def main():
    parser = argparse.ArgumentParser(description="Score diarization name-event accuracy.")
    parser.add_argument("cases", nargs="+", help="Case directories (each containing "
                        "reference-diarization.json and hypothesis-diarization.json)")
    parser.add_argument("--json", dest="json_out", help="Write full report to this JSON file")
    args = parser.parse_args()

    reports = []
    for case in args.cases:
        case_dir = Path(case)
        try:
            reports.append(score_case(case_dir))
        except FileNotFoundError as e:
            print(f"SKIP {case_dir.name}: missing file ({e.filename})", file=sys.stderr)

    if not reports:
        print("No cases scored.", file=sys.stderr)
        sys.exit(1)

    # Aggregate
    total_tp = sum(r["tp"] for r in reports)
    total_fp = sum(r["fp"] for r in reports)
    total_fn = sum(r["fn"] for r in reports)
    p = total_tp / (total_tp + total_fp) if (total_tp + total_fp) else 0.0
    r = total_tp / (total_tp + total_fn) if (total_tp + total_fn) else 0.0
    f1 = 2 * p * r / (p + r) if (p + r) else 0.0

    print("=" * 60)
    print("Diarization name-event audit")
    print("=" * 60)
    for rep in reports:
        print(f"\n{rep['case']}:  F1={rep['f1']:.3f}  P={rep['precision']:.3f}  "
              f"R={rep['recall']:.3f}  (tp={rep['tp']} fp={rep['fp']} fn={rep['fn']})")
        for name, stats in rep["per_name"].items():
            print(f"    {name:<28} acc={stats['assignment_accuracy']:.2f}  "
                  f"(ref={stats['ref_events']}, hyp={stats['hyp_events']}, ok={stats['correct']})")
    print("\n" + "-" * 60)
    print(f"AGGREGATE: F1={f1:.3f}  P={p:.3f}  R={r:.3f}  over {len(reports)} case(s)")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump({"cases": reports,
                       "aggregate": {"precision": p, "recall": r, "f1": f1,
                                     "cases_scored": len(reports)}},
                      f, indent=2)
        print(f"Full report written to {args.json_out}")


if __name__ == "__main__":
    main()
