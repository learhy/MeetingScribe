# MeetingScribe Eval Harness (P0-1)

Fixed benchmark for measuring transcription/diarization accuracy on Dan's real
meeting audio. **Nothing in the accuracy plan merges without a harness score
attached.**

## Layout

```
tools/eval/
    corpus-schema.json     JSON schema for a corpus case (case.json)
    export_corpus.sh       Mac-side: create corpus cases from retained WAVs
    score_wer.py           WER + per-name accuracy scorer
    diarize_audit.py       name-event F1 + per-name assignment accuracy
    refusal_gate.py        P0-4 gate: 0 refusal outputs in titles
    p1_logic.py            Python mirrors of the P1 Swift pure-logic types
    run_regression.py      CI regression suite (88 checks, synthetic only)
    README.md              this file
corpus/                    (local-only, git-ignored) Dan's real clips
tests/regression/          synthetic fixtures + CI regression suite
```

## Corpus case format

Each case is a directory:

```
<case-id>/
    audio.wav                      # clip, >=30 s, 48 kHz preferred
    reference.txt                  # hand-checked transcript (you write this)
    roster.txt                     # attendee display names, one per line, organizer first
    case.json                      # metadata per corpus-schema.json
    reference-diarization.json     # optional: hand-checked speaker events (for diarize_audit)
    hypothesis.txt                 # engine output to score
    hypothesis-diarization.json    # optional: pipeline diarization output (for diarize_audit)
```

**Corpus checklist (from the approved plan):**

- 15–20 clips, ≥30 s each
- The 5 known-hard names each in ≥1 case: **Rachana, Sapta/Saptaparni,
  Anando, Mukesh Marodia, Krishnan** (+5 cloud-API practice names)
- ≥2 clips where diarization fails to resolve a speaker
- Sensitive-meeting cases stay **local on the Mac only** — never commit audio

## Running a score (Dan's Mac)

### 1. Export clips

```bash
cd /path/to/MeetingScribe
./tools/eval/export_corpus.sh ~/Documents/MeetingScribe/recordings ~/MeetingScribe-eval/corpus
```

Then hand-check each `reference.txt` (listen and correct) and fill
`roster.txt`. Cases with empty reference files are skipped by the scorers.

### 2. Produce hypotheses

Run the pipeline over each clip (or call the API directly for an A/B):

```bash
# Baseline (no prompt):
curl https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F model=whisper-1 -F language=en \
  -F file="@corpus/case-001/audio.wav" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['text'])" \
  > corpus/case-001/hypothesis.txt

# P0-2 (roster prompt): add -F prompt="<RosterBuilder output for this meeting>"
```

### 3. Score

```bash
# WER + name accuracy for the whole corpus:
python3 tools/eval/score_wer.py ~/MeetingScribe-eval/corpus --json ~/MeetingScribe-eval/baseline.json

# Diarization audit (only cases with *-diarization.json):
python3 tools/eval/diarize_audit.py ~/MeetingScribe-eval/corpus/case-* --json ~/MeetingScribe-eval/diag.json
```

### 4. Before/after (the P0-2 gate)

```bash
# Run 1: baseline hypotheses in runs/baseline/<case>/hypothesis.txt
python3 tools/eval/score_wer.py ~/MeetingScribe-eval/corpus \
    --hypothesis-dir runs/baseline --json runs/baseline.json

# Run 2: same audio with the roster prompt, hypotheses in runs/p0-2/
python3 tools/eval/score_wer.py ~/MeetingScribe-eval/corpus \
    --hypothesis-dir runs/p0-2 --json runs/p0-2.json

diff <(python3 -c "import json;print(json.dumps(json.load(open('runs/baseline.json')),indent=1))") \
     <(python3 -c "import json;print(json.dumps(json.load(open('runs/p0-2.json')),indent=1))")
```

**Adoption rule (plan §3):** any change wins only if corpus WER improves by
≥1 point AND known-hard name accuracy does not regress.

## Regression suite (CI)

`tests/regression/` holds synthetic fixtures — no real audio, safe to commit.
`run_regression.py` scores the reference-vs-fixture outputs and asserts:

1. WER scorer correctness against hand-computed expected values
2. Diarization audit correctness on a synthetic speaker-map
3. **0 refusal-pattern outputs** across the regression corpus titles
   (P0-4 gate: `TitleValidator.refusalPatterns` list mirrored in
   `refusal_gate.py`, kept in sync with the Swift source)

```bash
python3 tools/eval/run_regression.py tests/regression/
```

This runs anywhere Python 3.10+ exists — including this Linux host and CI.
