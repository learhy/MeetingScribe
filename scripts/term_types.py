"""Unified type definitions for the smart prompt generation system.

This module provides consistent type definitions used throughout the system
to avoid type mismatches and enable set operations on vocabulary terms.
"""
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Term:
    """Unified term representation used throughout the system.
    
    Hashable by normalized text only, allowing set operations and deduplication.
    
    Categories:
        - person_name: Names of people (via NER or capitalization patterns)
        - technical: Domain-specific terms (heuristics + frequency)
        - acronym: All-caps words 2-6 chars
        - project: Proper nouns that look like project names
        - org: Organization names (via NER)
        - phrase: Multi-word phrases (for context)
        - context: Context hints (general topic)
        - other: Uncategorized terms
    
    Sources:
        - extract: Extracted from transcript text
        - rag: Retrieved from bear-rag semantic search
        - glossary: From local glossary file
        - speaker_history: From speaker's term history in database
        - static: From static vocabulary file
        - merged: Combined from multiple sources
    """
    text: str
    category: str = 'other'
    confidence: float = 1.0
    source: str = 'unknown'
    
    def __hash__(self):
        return hash(self.text.lower())
    
    def __eq__(self, other):
        if isinstance(other, str):
            return self.text.lower() == other.lower()
        if isinstance(other, Term):
            return self.text.lower() == other.text.lower()
        return False
    
    def with_weight(self, weight: float) -> 'Term':
        """Return copy with adjusted confidence (used for weighting during merge)."""
        return Term(
            text=self.text,
            category=self.category,
            confidence=self.confidence * weight,
            source=self.source
        )
    
    def with_source(self, source: str) -> 'Term':
        """Return copy with different source."""
        return Term(
            text=self.text,
            category=self.category,
            confidence=self.confidence,
            source=source
        )


@dataclass
class RefinedTranscript:
    """Result of iterative quick-transcribe refinement.
    
    This captures the output of the two-pass transcription process,
    where terms appearing in both passes get higher confidence.
    """
    text: str                            # Final transcribed text
    extracted_names: list[str]           # Person names only (for prompt priority)
    high_confidence_terms: list[Term]    # Terms appearing in both passes
    all_terms: list[Term]                # Union of all extracted terms


@dataclass
class PromptOutput:
    """Two-channel output for Whisper prompt generation.
    
    Whisper has a 224 token limit on initial_prompt, so we split vocabulary:
    - initial_prompt: Names and key context phrases (≤224 tokens)
    - vocabulary_terms: Technical terms go to separate vocabulary file
    """
    initial_prompt: str           # For --initial-prompt (≤224 tokens)
    vocabulary_terms: list[str]   # For --vocabulary-file (technical terms)
    prompt_token_count: int
    terms_in_prompt: int
    terms_in_vocab_file: int


@dataclass
class SmartPromptResult:
    """Final result of smart prompt generation.
    
    This is returned by generate_smart_prompt() and contains everything
    needed to configure Whisper transcription.
    """
    initial_prompt: str                      # For --initial-prompt arg
    vocabulary_file_path: Optional[str]      # Path to generated vocab file, for --vocabulary-file
    source: str                              # 'cache_full', 'cache_partial', 'generated', 'fallback_static', 'speaker_terms_only'
    speaker_ids: list[str]                   # Matched speaker IDs
    confidence: float                        # 0.0-1.0
    new_speakers_created: int = 0            # Count of new speaker entries
    prompt_token_count: int = 0              # Tokens used in initial_prompt
    vocab_term_count: int = 0                # Terms written to vocabulary file
    cache_key: Optional[str] = None          # Cache key used (for quality feedback)
    speaker_label_map: Optional[dict[str, Optional[str]]] = None  # SPEAKER_XX → speaker_id (for JSON output)


@dataclass
class SpeakerMatch:
    """Result of matching an embedding against the speaker database."""
    speaker_id: str
    similarity: float
    confidence_gap: float  # Gap to second-best match
    is_confident: bool     # True if gap > threshold or similarity very high


@dataclass
class MatchResult:
    """Aggregated result of matching multiple embeddings."""
    matched: list[SpeakerMatch]
    unknown: list  # List of embeddings with no confident match (np.ndarray)
    ambiguous: list[SpeakerMatch]  # Matches with low confidence gap


@dataclass
class IndexedMatchResult:
    """Match result that preserves the mapping from cluster index to speaker identity.
    
    Each key in `speaker_map` corresponds to a cluster label (e.g., 0 for SPEAKER_00).
    Values are SpeakerMatch for confident/ambiguous matches, or None for unknown speakers.
    """
    speaker_map: dict[int, Optional[SpeakerMatch]]  # cluster_index → match or None
    matched: list[SpeakerMatch]        # Confident matches (for backward compat)
    unknown: list                       # Unknown embeddings (np.ndarray)
    ambiguous: list[SpeakerMatch]       # Ambiguous matches
    
    def to_match_result(self) -> MatchResult:
        """Convert to legacy MatchResult for backward compatibility."""
        return MatchResult(
            matched=self.matched,
            unknown=self.unknown,
            ambiguous=self.ambiguous
        )


@dataclass
class CacheLookupResult:
    """Result of cache lookup."""
    prompt: Optional['CachedPrompt']  # Forward reference
    match_type: str  # 'full', 'partial', 'miss'
    confidence: float


@dataclass
class CachedPrompt:
    """Cached prompt entry from database."""
    cache_key: str
    known_speakers_key: str
    speaker_ids: list[str]
    unknown_speaker_count: int
    prompt_text: str
    vocabulary_terms: list[str]
    created_at: str
    last_used_at: str
    use_count: int
    base_confidence: float
    last_quality_score: Optional[float]
    effective_confidence: float  # Computed with decay


@dataclass
class Speaker:
    """Speaker entry from database."""
    speaker_id: str
    name: Optional[str]
    name_confidence: Optional[float]
    email: Optional[str]
    embedding_count: int
    created_at: str
    last_seen_at: str


@dataclass
class PendingNameSuggestion:
    """Pending name suggestion requiring user confirmation."""
    suggestion_id: str
    speaker_id: str
    suggested_name: str
    source: str  # 'transcript', 'calendar', 'manual'
    confidence: float
    context: Optional[str]
    created_at: str
    status: str  # 'pending', 'accepted', 'rejected'


@dataclass
class Contact:
    """Contact entry for people metadata."""
    email: str
    display_name: Optional[str]
    preferred_name: Optional[str]
    pronunciation: Optional[str]
    aliases: Optional[list[str]]  # Stored as JSON in DB
    role: Optional[str]
    team: Optional[str]
    source: str  # 'manual', 'calendar', 'auto'
    created_at: str
    updated_at: str


# Custom exceptions
class SpeakerDBError(Exception):
    """Error accessing or operating on the speaker database."""
    pass


class NoSpeakersDetected(Exception):
    """No speakers were detected in the audio."""
    pass


class QuickTranscribeError(Exception):
    """Error during quick transcription."""
    pass


class RAGError(Exception):
    """Error communicating with the RAG service."""
    pass
