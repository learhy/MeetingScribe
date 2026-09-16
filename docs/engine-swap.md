# Engine-Swap Decision Framework (P2-1)

Implementation of plan §3: a framework, not a decision. The engine choice is
made **only** by harness runs on Dan's real meeting audio.

## Current state

| Engine | Status | Notes |
|---|---|---|
| `whisper-1` + roster prompt (P0-2) | **DEFAULT** | unchanged — all other engines are eval-only |
| AssemblyAI Universal-3 Pro | EVAL-ONLY (Dan's Q2 opt-in) | `transcription.provider = "assemblyai"`; keyterms = RosterBuilder output |
| Parakeet TDT 0.6B (GGUF / NeMo-Speech.cpp) | STUB — interface + config only | see "Local candidates" below |
| Apple SpeechAnalyzer (macOS 26) | STUB — interface + config only | see "Local candidates" below |

Config seam: `transcription.provider` accepts `openai` (default), `local`,
`assemblyai`, and the two reserved stub ids `parakeet` /
`apple-speechanalyzer`. Anything else falls back to OpenAI as before.

## AssemblyAI setup (eval only)

1. Key: add `transcription.assemblyai.apiKey` to `~/.meetingscribe/config.json`
   **or** (preferred) store it in the Keychain — service `com.meetingscribe`,
   account `assemblyai.apiKey` (same `SecretsManager` path as the OpenAI key).
2. Biasing: `transcription.assemblyai.keytermsFromRoster = true` (default)
   maps the per-meeting RosterBuilder prompt to AssemblyAI's `keyterms`
   parameter — attendee names, the right side of taught corrections, and
   glossary terms, capped at 50. `extraKeyterms` adds manual entries.
3. Failure behavior: any upload/poll/API error throws, and the existing
   fallback chain (diarization → plain transcription) applies exactly as for
   whisper-1. No new failure mode is introduced by configuration alone.
4. Privacy: audio goes to a **second cloud** — NFR-12 posture change, gated by
   Dan's Q2 opt-in and eval-only until promotion.

## Running the A/B (Dan's Mac, once the corpus baseline exists)

Prereqs: corpus exported and hand-checked per `tools/eval/README.md`
(`reference.txt` + `roster.txt` + `roster-prompt.txt` per case), and both API
keys in the environment.

```bash
export OPENAI_API_KEY=sk-...
export ASSEMBLYAI_API_KEY=...

./tools/eval/run_engine_ab.sh ~/MeetingScribe-eval/corpus ~/MeetingScribe-eval
```

What it does: transcribes every corpus case with BOTH engines (whisper-1 gets
the roster prompt; AssemblyAI gets the same roster mapped to keyterms), scores
both with `score_wer.py`, and writes
`~/MeetingScribe-eval/engine_ab_comparison.json` containing, per engine:

- `corpus_wer`
- `hard_name_accuracy` (per-name) + mean
- `cost_estimate_usd` / `cost_estimate_per_minute_usd`
- the §3 step-2 adoption verdict (computed from the thresholds below)

Override pricing with `OPENAI_PRICE_PER_MIN` / `ASSEMBLYAI_PRICE_PER_MIN`
defaults: 0.006 / 0.012 $/min — **verify AssemblyAI's price on Dan's plan
tier before quoting the number**.

## Adoption thresholds (plan §3 step 2, verbatim)

Adopt AssemblyAI only if ALL hold:

1. **Corpus WER improves by ≥1 point** over `whisper-1`+roster
   (`wer_gain >= 0.01` in the comparison JSON).
2. **Hard-name accuracy does not regress** (per-name AND mean).
3. **No new failure mode appears** — manually review both hypothesis dirs for
   hallucinated silences, empty outputs, odd substitutions (the script marks
   this `REVIEW MANUALLY`; it cannot be automated honestly).

If all three pass, the promotion step is Dan's decision: flip
`transcription.provider` to `assemblyai` on the Mac. Until then the default
stays `whisper-1` + roster. Eval-only means: run the A/B, keep the JSON, make
no production config change.

## Local candidates (stubs — plan §3 step 4)

Interface + config plumbing only; no provider code. Each must provide, before
adoption: a reproducible runtime story on the Mac, a memory-budget check, and
a fallback path (already satisfied — any provider failure degrades to
whisper-1).

### Parakeet TDT 0.6B v2/v3 (`parakeet`)

- Runtime: GGUF via **NeMo-Speech.cpp**; model download ~1.2–1.3 GB, ~1.3 GB
  RAM at inference. Implementation would reuse
  `LocalWhisperProvider.resampleAudio` (16 kHz mono WAV) and shell out to the
  NeMo-Speech.cpp binary — see `ParakeetTDTProvider` in
  `src/core/ParakeetStub.swift`.
- WER (third-party measured): 2.01 / 3.40 (v2/v3), AMI 11.31 — but the biasing
  surface is weak/absent (initial-prompt conditioning is weak), so name
  accuracy depends on the P1-1 dictionary + P1-2 verification pass instead.
- No diarization — pair with the existing `diarize_audio_fast.py`.
- Posture: improves (on-device, CC-BY-4.0). No privacy gate needed.

### Apple SpeechAnalyzer (`apple-speechanalyzer`)

- Runtime: macOS 26 SpeechAnalyzer API — OS-managed memory, effectively free;
  requires macOS 26 SDK + runtime on the build Mac.
- WER (third-party, int8): 2.12 / 4.56. No biasing surface documented; no
  diarization (same external-diarizer pairing).
- Posture: improves (nothing leaves the device). No privacy gate needed.

Sequencing per plan §3 step 5, if cloud A/B is acceptable: `gpt-4o-transcribe`
first (same vendor, no posture change) — not wired in this batch — then
AssemblyAI, then Parakeet.
