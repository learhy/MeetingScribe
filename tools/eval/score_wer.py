#!/usr/bin/env python3
"""score_wer.py — WER scorer for the configured engine (P0-1 eval harness).

Computes Word Error Rate of a hypothesis transcript against a hand-checked
reference, with a per-name accuracy breakdown for the known-hard names.

Usage:
    # Score one case directory (expects reference.txt and hypothesis.txt):
    python3 score_wer.py corpus/case-001/

    # Score a whole corpus and write a JSON report:
    python3 score_wer.py corpus/ --json report.json

    # Compare two runs (e.g. baseline vs P0-2 roster prompt):
    python3 score_wer.py corpus/ --hypothesis-dir runs/baseline/ --json baseline.json
    python3 score_wer.py corpus/ --hypothesis-dir runs/p0-2/   --json p0-2.json

Case layout (see corpus-schema.json and README.md):
    <case>/
        audio.wav            # the clip
        reference.txt        # hand-checked transcript
        roster.txt           # attendee names, one per line (optional)
        hypothesis.txt       # engine output (or <hypothesis-dir>/<case>/hypothesis.txt)

Scoring:
    - WER = (S + D + I) / N via standard Levenshtein alignment on word tokens.
    - Name accuracy: for each roster name (and the 5 known-hard names), the
      fraction of reference occurrences that appear verbatim in the hypothesis
      (case-insensitive, after normalization).
"""

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

# Known-hard names that must appear in >=1 corpus case each (approved plan P0-1).
KNOWN_HARD_NAMES = [
    "Rachana",
    "Sapta",
    "Saptaparni",
    "Anando",
    "Mukesh Marodia",
    "Krishnan",
]


def normalize(text: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace."""
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[^\w\s']", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def edit_distance(a: list, b: list) -> list:
    """Full DP matrix (words)."""
    m, n = len(a), len(b)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(m + 1):
        dp[i][0] = i
    for j in range(n + 1):
        dp[0][j] = j
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            dp[i][j] = min(
                dp[i - 1][j] + 1,        # deletion
                dp[i][j - 1] + 1,        # insertion
                dp[i - 1][j - 1] + (a[i - 1] != b[j - 1]),  # substitution
            )
    return dp


def wer(ref: str, hyp: str) -> dict:
    ref_words = normalize(ref).split()
    hyp_words = normalize(hyp).split()
    n = len(ref_words)
    if n == 0:
        return {"wer": 1.0 if hyp_words else 0.0, "n": 0, "s": 0, "d": 0, "i": 0}

    dp = edit_distance(ref_words, hyp_words)
    # Backtrack for S/D/I counts
    i, j = len(ref_words), len(hyp_words)
    s = d = ins = 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and dp[i][j] == dp[i - 1][j - 1] + (ref_words[i - 1] != hyp_words[j - 1]):
            if ref_words[i - 1] != hyp_words[j - 1]:
                s += 1
            i, j = i - 1, j - 1
        elif i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            d += 1
            i -= 1
        else:
            ins += 1
            j -= 1

    total_err = s + d + ins
    return {"wer": round(total_err / n, 4), "n": n, "s": s, "d": d, "i": ins}


def name_accuracy(ref: str, hyp: str, names: list) -> dict:
    """Fraction of reference occurrences of each name present in the hypothesis."""
    ref_norm = normalize(ref)
    hyp_norm = normalize(hyp)
    report = {}
    for name in names:
        needle = normalize(name)
        if not needle:
            continue
        occurrences = ref_norm.count(needle)
        if occurrences == 0:
            continue  # name not in this reference; not scored here
        correct = hyp_norm.count(needle)
        report[name] = {
            "ref_occurrences": occurrences,
            "correct": min(correct, occurrences),
            "accuracy": round(min(correct, occurrences) / occurrences, 4),
        }
    return report


def score_case(case_dir: Path, hypothesis_dir: Path | None = None) -> dict | None:
    hyp_path = (hypothesis_dir / case_dir.name / "hypothesis.txt") if hypothesis_dir \
        else case_dir / "hypothesis.txt"
    ref_path = case_dir / "reference.txt"
    if not ref_path.exists():
        print(f"SKIP {case_dir.name}: no reference.txt", file=sys.stderr)
        return None
    if not hyp_path.exists():
        print(f"SKIP {case_dir.name}: no hypothesis.txt at {hyp_path}", file=sys.stderr)
        return None

    ref = ref_path.read_text(encoding="utf-8")
    hyp = hyp_path.read_text(encoding="utf-8")

    roster = []
    roster_path = case_dir / "roster.txt"
    if roster_path.exists():
        roster = [line.strip() for line in roster_path.read_text(encoding="utf-8").splitlines() if line.strip()]

    names_to_check = list(dict.fromkeys(roster + KNOWN_HARD_NAMES))
    result = wer(ref, hyp)
    return {
        "case": case_dir.name,
        **result,
        "name_accuracy": name_accuracy(ref, hyp, names_to_check),
    }


def main():
    parser = argparse.ArgumentParser(description="WER + name-accuracy scorer.")
    parser.add_argument("input", help="A case directory or a corpus root containing case dirs")
    parser.add_argument("--hypothesis-dir", help="Root holding <case>/hypothesis.txt for this run "
                        "(default: hypothesis.txt inside each case dir)")
    parser.add_argument("--json", dest="json_out", help="Write full report to this JSON file")
    args = parser.parse_args()

    root = Path(args.input)
    hyp_root = Path(args.hypothesis_dir) if args.hypothesis_dir else None

    if (root / "reference.txt").exists():
        case_dirs = [root]
    else:
        case_dirs = sorted(d for d in root.iterdir() if d.is_dir())

    reports = [r for r in (score_case(d, hyp_root) for d in case_dirs) if r is not None]
    if not reports:
        print("No cases scored.", file=sys.stderr)
        sys.exit(1)

    total_n = sum(r["n"] for r in reports)
    total_err = sum(r["s"] + r["d"] + r["i"] for r in reports)
    corpus_wer = total_err / total_n if total_n else 0.0

    # Aggregate hard-name accuracy
    hard_agg = {}
    for name in KNOWN_HARD_NAMES:
        ref_occ = correct = 0
        for r in reports:
            stats = r["name_accuracy"].get(name)
            if stats:
                ref_occ += stats["ref_occurrences"]
                correct += stats["correct"]
        if ref_occ:
            hard_agg[name] = round(correct / ref_occ, 4)

    print("=" * 60)
    print("WER + name-accuracy report")
    print("=" * 60)
    for r in reports:
        print(f"\n{r['case']}:  WER={r['wer']*100:.2f}%  (n={r['n']} S={r['s']} D={r['d']} I={r['i']})")
        for name, stats in r["name_accuracy"].items():
            print(f"    {name:<28} acc={stats['accuracy']*100:.0f}%  "
                  f"({stats['correct']}/{stats['ref_occurrences']})")
    print("\n" + "-" * 60)
    print(f"CORPUS WER: {corpus_wer*100:.2f}% over {len(reports)} case(s), {total_n} words")
    if hard_agg:
        print("Known-hard names (corpus-wide):")
        for name, acc in hard_agg.items():
            print(f"    {name:<28} {acc*100:.0f}%")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump({"cases": reports,
                       "corpus_wer": corpus_wer,
                       "hard_name_accuracy": hard_agg},
                      f, indent=2)
        print(f"Full report written to {args.json_out}")


if __name__ == "__main__":
    main()
