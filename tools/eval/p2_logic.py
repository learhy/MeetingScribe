#!/usr/bin/env python3
"""p2_logic.py — Python mirrors of the P2 Swift logic for host-side regression.

No Swift toolchain exists on this host, so the pure-logic P2 types are
re-implemented here (same rules as the Swift sources) and exercised by
run_regression.py. KEEP IN SYNC with:

  src/core/AssemblyAIProvider.swift    (roster prompt -> keyterms mapping)
  src/core/NameResolver.swift          (1:1 calendar-inference attribution basis)
  src/core/NotesLabelCleaner.swift     ("(likely)" presentation rule)
  src/core/DictionaryHygiene.swift     (hygiene audit rules)

Any divergence between these mirrors and the Swift sources is a bug.
"""

from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# P2-1: AssemblyAI keyterms mapping
# ---------------------------------------------------------------------------

NAMES_SECTION_INTRO = "The following people may be mentioned in this meeting: "
CORRECTIONS_SECTION_INTRO = "Common corrections: "
TERMS_SECTION_INTRO = "Technical terms that may come up: "
MAX_KEYTERMS = 50


def _section(prompt: str, intro: str) -> Optional[str]:
    idx = prompt.find(intro)
    if idx < 0:
        return None
    tail = prompt[idx + len(intro):]
    end = tail.find(".")
    body = tail[:end if end >= 0 else len(tail)].strip()
    return body or None


def keyterms_from_roster_prompt(prompt: str, max_keyterms: int = MAX_KEYTERMS) -> list:
    """Mirror of AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt:).

    Attendee names first, then the RIGHT side of correction pairs, then
    glossary terms — de-duplicated case-insensitively, order preserved.
    """
    if not prompt:
        return []
    result, seen = [], set()

    def add(raw: str):
        term = raw.strip()
        if not term or term.lower() in seen:
            return
        seen.add(term.lower())
        result.append(term)

    names = _section(prompt, NAMES_SECTION_INTRO)
    if names:
        for name in names.split(","):
            add(name)
    corrections = _section(prompt, CORRECTIONS_SECTION_INTRO)
    if corrections:
        for pair in corrections.split(","):
            if "→" in pair:
                add(pair.split("→", 1)[1])
    terms = _section(prompt, TERMS_SECTION_INTRO)
    if terms:
        for term in terms.split(","):
            add(term)
    return result[:max_keyterms]


# ---------------------------------------------------------------------------
# P2-2: calendar-primed speaker attribution
# ---------------------------------------------------------------------------

VOICE_MATCH_THRESHOLD = 0.6
CALENDAR_INFERENCE_CONFIDENCE = 0.7


@dataclass
class Participant:
    email: str
    first_name: str
    is_me: bool = False


@dataclass
class SpeakerIdentity:
    name: str
    confidence: float


@dataclass
class CanonicalName:
    display_name: str
    source: str                 # "voiceMatch" | "contacts" | "calendar"
    confidence: float
    email: Optional[str] = None
    basis: str = "voiceMatch"   # "voiceMatch" | "calendarInference"


def resolve_attribution(
    participants: Optional[list],       # list[Participant] or None (no calendar)
    speaker_map: Optional[dict],        # label -> SpeakerIdentity | None
) -> dict:
    """Mirror of NameResolver.resolve attribution rules (name only, no
    contact reconciliation): returns label -> CanonicalName.

    Rule 1 (voice): identity present, named, confidence >= 0.6 -> basis
    voiceMatch. Rule 3 (1:1 fallback, P2-2 applied): exactly one unmatched
    label + exactly one unmatched (non-me) attendee -> assign that name with
    basis calendarInference. Larger meetings never get a 1:1 inference.
    """
    label_map: dict[str, CanonicalName] = {}

    speaker_map = speaker_map or {}
    voice_names: set[str] = set()
    if speaker_map:
        for label, identity in speaker_map.items():
            if identity and identity.name and identity.confidence >= VOICE_MATCH_THRESHOLD:
                label_map[label] = CanonicalName(
                    display_name=identity.name, source="voiceMatch",
                    confidence=identity.confidence)
                voice_names.add(identity.name.split(" ")[0].lower())

    if speaker_map is not None and participants:
        unmatched_labels = [l for l, v in speaker_map.items() if v is None]
        unmatched_attendees = [
            p for p in participants
            if not p.is_me and p.first_name.lower() not in voice_names
        ]
        # 1:1 only — never applied to multi-speaker meetings
        if len(unmatched_labels) == 1 and len(unmatched_attendees) == 1:
            label = unmatched_labels[0]
            attendee = unmatched_attendees[0]
            label_map[label] = CanonicalName(
                display_name=attendee.first_name, source="calendar",
                confidence=CALENDAR_INFERENCE_CONFIDENCE,
                email=attendee.email, basis="calendarInference")
    return label_map


def assignment_basis_line(label: str, name: str, basis: str, confidence: float, detail: str) -> str:
    """Mirror of NameResolver.assignmentBasisLine (log format)."""
    basis_name = {"voiceMatch": "voice", "calendarInference": "calendar-inference"}[basis]
    return (f"[SpeakerAttribution] {label} → {name} basis={basis_name} "
            f"confidence={confidence:.2f} ({detail})")


def display_label(canonical: Optional[CanonicalName], raw_label: str) -> str:
    """Mirror of NotesLabelCleaner.clean presentation for one label.

    Resolved voice-matched -> bare name; resolved calendar-inferred ->
    "Name (likely)"; unresolved -> "Speaker N". Raw SPEAKER_XX never renders.
    """
    if canonical is not None:
        if canonical.basis == "calendarInference":
            name = canonical.display_name
            return name if name.endswith("(likely)") else f"{name} (likely)"
        return canonical.display_name
    try:
        n = int(raw_label.rsplit("_", 1)[1])
    except (IndexError, ValueError):
        return raw_label
    return f"Speaker {n}"


def normalize_labels(text: str, label_map: dict) -> str:
    """Mirror of VerificationPass.normalizeLabels with P2-2 "(likely)" rule."""
    import re
    out = text
    for match in sorted(set(re.findall(r"SPEAKER_\d{2}", text))):
        canonical = label_map.get(match)
        out = out.replace(match, display_label(canonical, match))
    return out


# ---------------------------------------------------------------------------
# P2-3: dictionary hygiene audit
# ---------------------------------------------------------------------------

HYGIENE_UNUSED_DAYS = 90
ROSTER_WORD_BUDGET = 200


@dataclass
class HygieneFinding:
    kind: str          # "unused" | "duplicate" | "case_collision" | "phonetic_collision"
    term: str
    detail: str


def _simple_metaphone(word: str) -> str:
    """Deliberately rough phonetic skeleton for collision detection in the
    mirror (the Swift side uses DoubleMetaphone): first letter + consonant
    skeleton with common vowel elision."""
    import re
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return ""
    skeleton = w[0] + re.sub(r"[aeiouy]", "", w[1:])
    return skeleton[:6]


def audit_hygiene(
    entries: list[dict],        # corrections.json entries: wrong/right/updatedAt
    glossary_terms: list[str],
    now_ts: float,
    unused_days: int = HYGIENE_UNUSED_DAYS,
) -> tuple[list[HygieneFinding], list[str]]:
    """Mirror of DictionaryHygiene.audit.

    Flags: entries unused > 90 days, exact duplicates, case-collisions, and
    phonetic collisions (corrections + glossary sharing a phonetic skeleton
    where one historically required a correction). Returns (findings,
    suggested_prune_terms).
    """
    findings: list[HygieneFinding] = []
    prune: list[str] = []
    cutoff = now_ts - unused_days * 86400

    seen: dict[str, str] = {}          # lower(wrong) -> original wrong
    for entry in entries:
        wrong, right = entry["wrong"], entry["right"]
        key = wrong.lower()
        if key in seen:
            findings.append(HygieneFinding(
                "duplicate", wrong, f"case-insensitive duplicate of '{seen[key]}'"))
            prune.append(wrong)
            continue
        seen[key] = wrong
        if entry.get("updatedAt", 0) < cutoff:
            findings.append(HygieneFinding(
                "unused", wrong,
                f"unused for {int((now_ts - entry.get('updatedAt', 0)) / 86400)} days"))
            prune.append(wrong)
        if wrong.lower() == right.lower():
            findings.append(HygieneFinding(
                "case_collision", wrong, "wrong/right differ only by case (no-op mapping)"))
            prune.append(wrong)

    # Phonetic collisions between correction terms and glossary names —
    # historically the source of "odd substitutions" when two near-homophones
    # are both active prompt vocabulary.
    glossary_by_code: dict[str, str] = {}
    for term in glossary_terms:
        code = _simple_metaphone(term)
        if code and code not in glossary_by_code:
            glossary_by_code[code] = term
    for entry in entries:
        wrong = entry["wrong"]
        code = _simple_metaphone(wrong)
        clash = glossary_by_code.get(code)
        if clash and clash.lower() != wrong.lower():
            findings.append(HygieneFinding(
                "phonetic_collision", wrong,
                f"phonetically collides with glossary term '{clash}' — review, do not auto-prune"))

    return findings, prune


@dataclass
class PromptComposition:
    corrections: list[str] = field(default_factory=list)
    names: list[str] = field(default_factory=list)
    terms: list[str] = field(default_factory=list)

    @property
    def word_count(self) -> int:
        text = " ".join(self.corrections + self.names + self.terms)
        return len(text.split())

    def within_budget(self, budget: int = ROSTER_WORD_BUDGET) -> bool:
        return self.word_count <= budget


def prompt_composition(roster_prompt: str) -> PromptComposition:
    """Mirror of DictionaryHygiene.promptComposition: what the active roster
    prompt spends its 200-word budget on (corrections -> names -> glossary)."""
    comp = PromptComposition()

    def items(intro: str) -> list[str]:
        body = _section(roster_prompt, intro)
        return [s.strip() for s in body.split(",") if s.strip()] if body else []

    comp.names = items(NAMES_SECTION_INTRO)
    corrections_body = _section(roster_prompt, CORRECTIONS_SECTION_INTRO)
    if corrections_body:
        comp.corrections = [s.strip() for s in corrections_body.split(",") if s.strip()]
    comp.terms = items(TERMS_SECTION_INTRO)
    return comp
