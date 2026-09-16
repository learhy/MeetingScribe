#!/usr/bin/env bash
# run_engine_ab.sh — engine A/B: whisper-1 (baseline) vs assemblyai
# universal-3-pro on the SAME corpus (plan §2 P2-1 / §3 steps 1–3).
#
# Runs on Dan's Mac (needs OPENAI_API_KEY + ASSEMBLYAI_API_KEY and the
# exported eval corpus). Emits the §3 comparison JSON:
#   { corpus_wer, hard_name_accuracy, cost_estimate_per_minute } per engine,
#   plus the §3 step-2 adoption verdict.
#
# Usage:
#   export OPENAI_API_KEY=sk-...          # baseline engine
#   export ASSEMBLYAI_API_KEY=...         # eval engine (Q2: eval-only)
#   ./tools/eval/run_engine_ab.sh ~/MeetingScribe-eval/corpus ~/MeetingScribe-eval
#
# Adoption rule (plan §3 step 2, verbatim): adopt only if corpus WER improves
# by >=1 point AND hard-name accuracy does not regress AND no new failure mode.
# Default stays whisper-1+roster until a harness run says otherwise; AssemblyAI
# runs are EVAL-ONLY until Dan promotes it.

set -euo pipefail

CORPUS="${1:?usage: run_engine_ab.sh <corpus_root> <out_dir> [audio_seconds_total]}"
OUT="${2:?usage: run_engine_ab.sh <corpus_root> <out_dir> [audio_seconds_total]}"
TOTAL_SECONDS="${3:-}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL="$REPO/tools/eval"

OPENAI_PRICE_PER_MIN="${OPENAI_PRICE_PER_MIN:-0.006}"     # whisper-1, $/min
ASSEMBLYAI_PRICE_PER_MIN="${ASSEMBLYAI_PRICE_PER_MIN:-0.012}"  # Universal-3 Pro list price — verify with Dan's plan tier

for var in OPENAI_API_KEY ASSEMBLYAI_API_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set." >&2
    exit 1
  fi
done

mkdir -p "$OUT/whisper-1" "$OUT/assemblyai"

# ---------------------------------------------------------------- total audio
if [ -z "$TOTAL_SECONDS" ]; then
  TOTAL_SECONDS=$(python3 - "$CORPUS" <<'PY'
import sys, wave
from pathlib import Path
total = 0.0
for wav in Path(sys.argv[1]).rglob("audio.wav"):
    try:
        with wave.open(str(wav)) as w:
            total += w.getnframes() / w.getframerate()
    except Exception:
        pass
print(int(total))
PY
)
fi

echo "== Engine A/B on $CORPUS (total audio ~$TOTAL_SECONDS s) =="

# ------------------------------------------------------------- run whisper-1
for case_dir in "$CORPUS"/*/; do
  case_id=$(basename "$case_dir")
  [ -f "$case_dir/audio.wav" ] || continue
  hyp="$OUT/whisper-1/$case_id"
  mkdir -p "$hyp"
  echo "-- whisper-1: $case_id"
  curl -sS https://api.openai.com/v1/audio/transcriptions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F model=whisper-1 -F language=en \
    -F prompt="$(cat "$case_dir/roster-prompt.txt" 2>/dev/null || true)" \
    -F file=@"$case_dir/audio.wav" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['text'])" \
    > "$hyp/hypothesis.txt"
done

# ------------------------------------------------------------ run assemblyai
for case_dir in "$CORPUS"/*/; do
  case_id=$(basename "$case_dir")
  [ -f "$case_dir/audio.wav" ] || continue
  hyp="$OUT/assemblyai/$case_id"
  mkdir -p "$hyp"
  echo "-- assemblyai: $case_id"
  "$EVAL/assemblyai_transcribe.py" "$case_dir/audio.wav" "$hyp/hypothesis.txt" \
      --roster-prompt "$case_dir/roster-prompt.txt"
done

# ------------------------------------------------------------------- scoring
python3 "$EVAL/score_wer.py" "$CORPUS" --hypothesis-dir "$OUT/whisper-1"  --json "$OUT/whisper-1.json"
python3 "$EVAL/score_wer.py" "$CORPUS" --hypothesis-dir "$OUT/assemblyai" --json "$OUT/assemblyai.json"

# --------------------------------------------- comparison + adoption verdict
python3 - "$OUT" "$TOTAL_SECONDS" "$OPENAI_PRICE_PER_MIN" "$ASSEMBLYAI_PRICE_PER_MIN" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
total_seconds = int(sys.argv[2])
prices = {"whisper-1": float(sys.argv[3]), "assemblyai": float(sys.argv[4])}

def load(name):
    return json.loads((out / f"{name}.json").read_text())

def hard_mean(report):
    acc = [v for v in report.get("hard_name_accuracy", {}).values()]
    return sum(acc) / len(acc) if acc else None

summary = {"corpus": str(out), "audio_seconds": total_seconds, "engines": {}}
for name in ("whisper-1", "assemblyai"):
    r = load(name)
    minutes = total_seconds / 60.0
    summary["engines"][name] = {
        "corpus_wer": round(r["corpus_wer"], 4),
        "hard_name_accuracy": r.get("hard_name_accuracy", {}),
        "hard_name_accuracy_mean": hard_mean(r),
        "cost_estimate_usd": round(minutes * prices[name], 4),
        "cost_estimate_per_minute_usd": prices[name],
    }

# Plan §3 step 2 thresholds (verbatim)
b = summary["engines"]["whisper-1"]
c = summary["engines"]["assemblyai"]
wer_gain = b["corpus_wer"] - c["corpus_wer"]           # >0 means candidate better
name_ok = (
    c["hard_name_accuracy_mean"] is not None
    and b["hard_name_accuracy_mean"] is not None
    and c["hard_name_accuracy_mean"] >= b["hard_name_accuracy_mean"]
)
summary["adoption_check"] = {
    "wer_improves_by_at_least_1_point": wer_gain >= 0.01,
    "wer_gain": round(wer_gain, 4),
    "hard_name_accuracy_does_not_regress": name_ok,
    "no_new_failure_mode": "REVIEW MANUALLY — read both hypothesis dirs; look for hallucinated silences / empty outputs (Whisper-lineage artifact)",
    "verdict": ("CANDIDATE WINS — Dan may promote assemblyai"
                if wer_gain >= 0.01 and name_ok
                else "KEEP whisper-1+roster (default unchanged)"),
}

(out / "engine_ab_comparison.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

echo ""
echo "Comparison written to $OUT/engine_ab_comparison.json"
echo "Next: review both hypothesis dirs for new failure modes (§3 step 2c),"
echo "then per docs/engine-swap.md: default stays whisper-1 until Dan promotes."
