#!/usr/bin/env python3
"""assemblyai_transcribe.py — minimal AssemblyAI Universal-3 client for the A/B.

Upload + transcript-job polling per the AssemblyAI v2 API. Mirrors the Swift
provider (src/core/AssemblyAIProvider.swift) so the shell A/B and the app use
the same job model. The roster prompt (roster-prompt.txt, RosterBuilder output)
is mapped to the `keyterms` parameter — same parse as the Swift
`keyterms(fromRosterPrompt:)`, mirrored in tools/eval/p2_logic.py.

Usage:
    assemblyai_transcribe.py <audio.wav> <out.txt> [--roster-prompt roster.txt]
Requires ASSEMBLYAI_API_KEY in the environment.
"""

import argparse
import json
import os
import sys
import time
import urllib.request

API_BASE = "https://api.assemblyai.com/v2"


def keyterms_from_roster_prompt(prompt: str, max_keyterms: int = 50) -> list:
    """Mirror of AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt:)."""
    if not prompt:
        return []
    sections = {
        "names": "The following people may be mentioned in this meeting: ",
        "corrections": "Common corrections: ",
        "terms": "Technical terms that may come up: ",
    }

    def section_body(intro: str):
        idx = prompt.find(intro)
        if idx < 0:
            return None
        tail = prompt[idx + len(intro):]
        end = tail.find(".")
        body = tail[:end if end >= 0 else len(tail)].strip()
        return body or None

    result, seen = [], set()

    def add(raw: str):
        term = raw.strip()
        if not term or term.lower() in seen:
            return
        seen.add(term.lower())
        result.append(term)

    body = section_body(sections["names"])
    if body:
        for name in body.split(","):
            add(name)
    body = section_body(sections["corrections"])
    if body:
        for pair in body.split(","):
            if "→" in pair:
                add(pair.split("→", 1)[1])
    body = section_body(sections["terms"])
    if body:
        for term in body.split(","):
            add(term)
    return result[:max_keyterms]


def request_json(url: str, method: str, api_key: str, body=None, raw_body: bytes | None = None,
                 content_type: str = "application/json"):
    data = raw_body if raw_body is not None else (
        json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("authorization", api_key)
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("output")
    parser.add_argument("--roster-prompt", help="roster-prompt.txt path (RosterBuilder output)")
    parser.add_argument("--model", default="universal-3-pro")
    parser.add_argument("--poll-interval", type=float, default=3.0)
    parser.add_argument("--max-poll-attempts", type=int, default=600)
    args = parser.parse_args()

    api_key = os.environ.get("ASSEMBLYAI_API_KEY")
    if not api_key:
        print("ERROR: ASSEMBLYAI_API_KEY not set", file=sys.stderr)
        return 1

    roster = ""
    if args.roster_prompt and os.path.exists(args.roster_prompt):
        roster = open(args.roster_prompt, encoding="utf-8").read()
    keyterms = keyterms_from_roster_prompt(roster)

    # 1. Upload
    with open(args.audio, "rb") as f:
        upload = request_json(f"{API_BASE}/upload", "POST", api_key,
                              raw_body=f.read(), content_type="application/octet-stream")
    print(f"uploaded -> {upload['upload_url']}", file=sys.stderr)

    # 2. Create job
    body = {"audio_url": upload["upload_url"], "speech_model": args.model, "language_code": "en"}
    if keyterms:
        body["keyterms"] = keyterms
    job = request_json(f"{API_BASE}/transcript", "POST", api_key, body=body)
    print(f"job {job['id']} created ({len(keyterms)} keyterms)", file=sys.stderr)

    # 3. Poll
    for attempt in range(1, args.max_poll_attempts + 1):
        state = request_json(f"{API_BASE}/transcript/{job['id']}", "GET", api_key)
        if state["status"] == "completed":
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(state.get("text") or "")
            print(f"completed ({len(state.get('text') or '')} chars)", file=sys.stderr)
            return 0
        if state["status"] == "error":
            print(f"ERROR: AssemblyAI job failed: {state.get('error')}", file=sys.stderr)
            return 1
        if attempt % 10 == 1:
            print(f"poll {attempt}: {state['status']}", file=sys.stderr)
        time.sleep(args.poll_interval)
    print("ERROR: poll timed out", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
