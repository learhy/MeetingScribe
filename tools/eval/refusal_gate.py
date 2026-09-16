#!/usr/bin/env python3
"""refusal_gate.py — P0-4 gate: assert 0 refusal-pattern outputs in a corpus.

Mirrors TitleValidator.refusalPatterns from src/core/TitleValidator.swift.
KEEP IN SYNC with the Swift source — the sync test in test_gate_sync()
checks this list against the Swift file when run inside the repo.

A "refusal output" is a note title or first line of generated output that
matches any refusal pattern (case-insensitive) — the LLM refused to produce
a real title/note and its refusal prose leaked into the artifact.
"""

import re
from pathlib import Path

# Mirrors src/core/TitleValidator.swift refusalPatterns (lowercase here)
REFUSAL_PATTERNS = [
    "i don't see a transcript",
    "i'd be happy to help",
    "id be happy to help",
    "could you please provide",
    "once you share the transcript",
    "unable to generate",
    "meeting transcript correction request",
    "please provide the meeting transcript",
    "i don't have access to",
    "i cannot generate",
    "i'm unable to",
    "im unable to",
]

_COMPILED = [re.compile(re.escape(p), re.IGNORECASE) for p in REFUSAL_PATTERNS]


def contains_refusal(text: str) -> bool:
    """True if the text contains any refusal pattern."""
    return any(p.search(text) for p in _COMPILED)


def validate_title(title: str) -> str | None:
    """Mirror of TitleValidator.validate: cleaned title or None if unusable."""
    trimmed = title.strip()
    if len(trimmed) < 3:
        return None
    if contains_refusal(trimmed):
        return None
    if trimmed.endswith(".") and len(trimmed) > 60:
        return None
    cleaned = trimmed
    if (cleaned.startswith('"') and cleaned.endswith('"')) or \
       (cleaned.startswith("'") and cleaned.endswith("'")):
        cleaned = cleaned[1:-1]
    if len(cleaned) > 100:
        prefix = cleaned[:100]
        last_space = prefix.rfind(" ")
        cleaned = prefix[:last_space] if last_space > 0 else prefix
    return cleaned if cleaned else None


def scan_file(path: Path) -> list[str]:
    """Return the lines in a file that trip the refusal gate."""
    hits = []
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if contains_refusal(line):
            hits.append(f"{path.name}:{i}: {line.strip()[:100]}")
    return hits


def sync_with_swift(repo_root: Path) -> list[str]:
    """Parse refusalPatterns from TitleValidator.swift; return mismatches."""
    swift = repo_root / "src" / "core" / "TitleValidator.swift"
    if not swift.exists():
        return [f"TitleValidator.swift not found at {swift}"]
    body = swift.read_text(encoding="utf-8")
    swift_patterns = re.findall(r'"((?:[^"\\]|\\.)*)"', body.split("refusalPatterns")[1].split("]")[0])
    swift_patterns = [p.replace('\\"', '"').lower() for p in swift_patterns if p]
    mine = [p.lower() for p in REFUSAL_PATTERNS]
    mismatches = []
    for p in swift_patterns:
        if p not in mine:
            mismatches.append(f"Swift pattern missing from Python gate: {p!r}")
    for p in mine:
        if p not in swift_patterns:
            mismatches.append(f"Python gate pattern missing from Swift: {p!r}")
    return mismatches
