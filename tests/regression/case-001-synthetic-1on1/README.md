Regression fixture corpus — case-001-synthetic-1on1

This is a SYNTHETIC case: no real meeting audio, safe to commit. It seeds the
permanent CI regression suite (approved plan P0-1 sub-item) and documents the
case layout Dan's real corpus follows.

Layout reference:
    audio.wav                      (absent here — synthetic cases have no audio)
    reference.txt                  hand-checked reference transcript
    roster.txt                     attendee names, one per line, organizer first
    reference-diarization.json     hand-checked speaker events
    hypothesis-diarization.json    synthetic pipeline output
    titles.txt                     note titles the refusal gate must pass
    expected/
        wer-reference-values.json  hand-computed expected scores
