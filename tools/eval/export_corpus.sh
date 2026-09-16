#!/bin/bash
# export_corpus.sh — export real meeting clips + roster stubs for the eval corpus.
#
# RUN THIS ON DAN'S MAC. The pipeline discards WAVs today (retention is P1),
# so the corpus must be captured from re-processed retained recordings or
# freshly recorded meetings, then hand-checked.
#
# Usage:
#   ./tools/eval/export_corpus.sh ~/Documents/MeetingScribe/recordings ~/MeetingScribe-eval/corpus
#
# For each meeting_*.wav in the recordings dir this creates a corpus case:
#   <out>/<case-id>/audio.wav      (copied clip, >=30 s)
#   <out>/<case-id>/reference.txt  (EMPTY — you hand-check it)
#   <out>/<case-id>/roster.txt     (EMPTY — you list attendees, organizer first)
#   <out>/<case-id>/case.json      (schema-conformant stub, "id" pre-filled)
#
# Corpus checklist (approved plan P0-1):
#   - 15-20 clips, >=30 s each
#   - the 5 known-hard names each in >=1 case: Rachana, Sapta/Saptaparni,
#     Anando, Mukesh Marodia, Krishnan
#   - >=2 clips where diarization fails to resolve a speaker
#   - sensitive-meeting cases stay LOCAL on the Mac (never commit audio)

set -euo pipefail

RECORDINGS_DIR="${1:?Usage: export_corpus.sh <recordings-dir> <out-dir>}"
OUT_DIR="${2:?Usage: export_corpus.sh <recordings-dir> <out-dir>}"
MIN_SECONDS=30
MIN_BYTES=$((48000 * 2 * 2 * MIN_SECONDS))  # 48kHz 16-bit stereo ~192KB/s

mkdir -p "$OUT_DIR"
n=0

for wav in "$RECORDINGS_DIR"/meeting_*.wav; do
    [ -e "$wav" ] || { echo "No meeting_*.wav found in $RECORDINGS_DIR"; exit 1; }

    size=$(stat -f%z "$wav" 2>/dev/null || stat -c%s "$wav")
    if [ "$size" -lt "$MIN_BYTES" ]; then
        echo "SKIP $(basename "$wav") (< ${MIN_SECONDS}s)"
        continue
    fi

    n=$((n + 1))
    base=$(basename "$wav" .wav)
    case_id="case-$(printf '%03d' "$n")-$base"
    case_dir="$OUT_DIR/$case_id"
    mkdir -p "$case_dir"

    cp "$wav" "$case_dir/audio.wav"

    # Empty files for hand-checking — the harness skips cases until these are filled
    touch "$case_dir/reference.txt" "$case_dir/roster.txt"

    cat > "$case_dir/case.json" <<EOF
{
  "id": "$case_id",
  "audio": "audio.wav",
  "reference": "reference.txt",
  "roster": "roster.txt",
  "engine": "",
  "prompt": "",
  "notes": "",
  "hard_names": []
}
EOF

    echo "Created $case_dir — fill reference.txt and roster.txt by hand."
done

echo
echo "Exported $n case(s) to $OUT_DIR"
echo "Next: hand-check each reference.txt (listen + correct), fill roster.txt,"
echo "then verify coverage of the 5 hard names before scoring."
