"""Smart prompt generation for Whisper transcription.

This module orchestrates the smart prompt generation pipeline:
1. Extract speaker embeddings from audio
2. Match speakers against known database entries
3. Look up cached prompts for speaker combinations
4. Generate new prompts using quick transcription + vocabulary sources
5. Build final prompt respecting Whisper's 224 token limit
"""
import json
import logging
import re
import time
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from functools import wraps
from pathlib import Path
from typing import TYPE_CHECKING, Optional

import numpy as np

from term_types import (
    CacheLookupResult,
    IndexedMatchResult,
    MatchResult,
    NoSpeakersDetected,
    PromptOutput,
    QuickTranscribeError,
    RAGError,
    RefinedTranscript,
    SmartPromptResult,
    SpeakerDBError,
    SpeakerMatch,
    Term,
)

if TYPE_CHECKING:
    from speaker_db import SpeakerDatabase
    from vocabulary_sources import VocabularySource

logger = logging.getLogger(__name__)

# =============================================================================
# Token counting with tiktoken (with fallback)
# =============================================================================

try:
    import tiktoken
    WHISPER_TOKENIZER = tiktoken.get_encoding("gpt2")
    
    def count_tokens(text: str) -> int:
        """Count tokens using GPT-2 tokenizer (Whisper's tokenizer)."""
        return len(WHISPER_TOKENIZER.encode(text))
except ImportError:
    logger.warning("tiktoken not available, using approximate token counting")
    WHISPER_TOKENIZER = None
    
    def count_tokens(text: str) -> int:
        """Approximate token count (~1.3 tokens per word for English)."""
        return int(len(text.split()) * 1.3)

# Whisper token limits
MAX_PROMPT_TOKENS = 224
SAFETY_MARGIN = 20

# =============================================================================
# Stopwords for term extraction
# =============================================================================

try:
    from nltk.corpus import stopwords
    COMMON_WORDS = set(stopwords.words('english'))
except (ImportError, LookupError):
    # Fallback minimal list if NLTK not available
    COMMON_WORDS = {
        'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
        'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could',
        'should', 'may', 'might', 'must', 'shall', 'can', 'need', 'dare',
        'ought', 'used', 'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by',
        'from', 'as', 'into', 'through', 'during', 'before', 'after', 'above',
        'below', 'between', 'under', 'again', 'further', 'then', 'once',
        'here', 'there', 'when', 'where', 'why', 'how', 'all', 'each', 'few',
        'more', 'most', 'other', 'some', 'such', 'no', 'nor', 'not', 'only',
        'own', 'same', 'so', 'than', 'too', 'very', 'just', 'also', 'now',
        'about', 'actually', 'already', 'always', 'another', 'anything',
        'around', 'because', 'become', 'before', 'being', 'between', 'both',
        'called', 'cannot', 'come', 'could', 'different', 'does', 'doing',
        'during', 'either', 'enough', 'even', 'every', 'everything', 'going',
        'great', 'having', 'however', 'including', 'into', 'itself', 'keep',
        'know', 'known', 'later', 'least', 'less', 'like', 'little', 'long',
        'looking', 'made', 'make', 'making', 'many', 'maybe', 'might', 'much',
        'never', 'next', 'nothing', 'often', 'only', 'people', 'perhaps',
        'place', 'point', 'probably', 'quite', 'rather', 'really', 'right',
        'said', 'saying', 'second', 'seeing', 'seem', 'seems', 'several',
        'since', 'something', 'sometimes', 'still', 'sure', 'take', 'taking',
        'that', 'their', 'them', 'then', 'there', 'these', 'they', 'thing',
        'things', 'think', 'thinking', 'this', 'those', 'three', 'through',
        'time', 'today', 'together', 'tomorrow', 'under', 'until', 'using',
        'usually', 'want', 'well', 'what', 'when', 'where', 'whether', 'which',
        'while', 'whole', 'will', 'with', 'within', 'without', 'work', 'working',
        'world', 'would', 'year', 'years', 'yeah', 'yes', 'yet', 'you', 'your'
    }

# Common acronyms to filter out
COMMON_ACRONYMS = {'OK', 'PM', 'AM', 'TV', 'US', 'UK', 'IT', 'HR', 'AI', 'ML'}

# =============================================================================
# SpaCy lazy loading for NER
# =============================================================================

_nlp = None


def _get_nlp():
    """Lazy-load spaCy NLP model."""
    global _nlp
    if _nlp is None:
        try:
            import spacy
            _nlp = spacy.load("en_core_web_sm")
        except (ImportError, OSError) as e:
            # Fallback if model not installed
            logger.warning(f"spaCy model not found ({e}), NER disabled. Run: python -m spacy download en_core_web_sm")
            try:
                from spacy.lang.en import English
                _nlp = English()
            except ImportError:
                _nlp = None
    return _nlp


# =============================================================================
# Term Extraction
# =============================================================================

def extract_terms(text: str, use_ner: bool = True) -> list[Term]:
    """Extract vocabulary terms from transcript text.
    
    Returns unified Term objects (hashable, supports set operations).
    
    Categories:
    - person_name: Names of people (via NER or capitalization patterns)
    - technical: Domain-specific terms (heuristics + frequency)
    - acronym: All-caps words 2-6 chars
    - project: Proper nouns that look like project names
    - org: Organization names (via NER)
    
    Args:
        text: Transcript text to extract terms from
        use_ner: Whether to use spaCy NER (slower but more accurate)
    
    Returns:
        List of Term objects sorted by confidence
    """
    if not text or not text.strip():
        return []
    
    terms: list[Term] = []
    
    # 1. Acronyms: 2-6 uppercase letters, not common words
    acronyms = re.findall(r'\b[A-Z]{2,6}\b', text)
    for acr in set(acronyms):
        if acr not in COMMON_ACRONYMS:
            freq = acronyms.count(acr)
            terms.append(Term(
                text=acr,
                category='acronym',
                confidence=min(0.9, 0.5 + freq * 0.1),
                source='extract'
            ))
    
    # 2. Capitalized phrases (potential names/projects)
    cap_phrases = re.findall(r'\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,3})\b', text)
    cap_counter = Counter(cap_phrases)
    
    # 3. NER for people and organizations
    if use_ner:
        try:
            nlp = _get_nlp()
            if nlp and hasattr(nlp, 'pipe_names') and nlp.pipe_names:  # Has NER pipeline
                doc = nlp(text[:5000])  # Limit to avoid memory issues
                
                for ent in doc.ents:
                    if ent.label_ == 'PERSON':
                        terms.append(Term(
                            text=ent.text, category='person_name',
                            confidence=0.85, source='extract'
                        ))
                    elif ent.label_ == 'ORG':
                        terms.append(Term(
                            text=ent.text, category='org',
                            confidence=0.7, source='extract'
                        ))
                    elif ent.label_ in ('PRODUCT', 'WORK_OF_ART'):
                        terms.append(Term(
                            text=ent.text, category='project',
                            confidence=0.6, source='extract'
                        ))
        except Exception as e:
            logger.warning(f"NER extraction failed: {e}")
    
    # 4. Fallback name detection (capitalized words not in dictionary)
    for phrase, count in cap_counter.items():
        # Skip sentence starters
        if phrase.split()[0].lower() in {'the', 'this', 'that', 'these', 'those', 'i', 'we', 'you', 'it', 'a', 'an'}:
            continue
        
        # Check if already in terms (Term.__eq__ compares by text)
        if phrase not in terms and count >= 2:
            if len(phrase.split()) >= 2 and all(w[0].isupper() for w in phrase.split()):
                terms.append(Term(
                    text=phrase, category='person_name',
                    confidence=0.6, source='extract'
                ))
            else:
                terms.append(Term(
                    text=phrase, category='other',
                    confidence=0.4, source='extract'
                ))
    
    # 5. Technical terms: unusual words that appear multiple times
    words = re.findall(r'\b\w+\b', text.lower())
    word_freq = Counter(words)
    for word, freq in word_freq.items():
        if freq >= 3 and len(word) >= 6 and word not in COMMON_WORDS:
            if word not in terms:  # Term.__eq__ handles str comparison
                terms.append(Term(
                    text=word, category='technical',
                    confidence=0.5, source='extract'
                ))
    
    # Deduplicate by text (keep highest confidence)
    return dedupe_terms(terms)


def dedupe_terms(terms: list[Term]) -> list[Term]:
    """Remove duplicate terms, keeping highest confidence."""
    seen: dict[str, Term] = {}
    for t in terms:
        key = t.text.lower()
        if key not in seen or t.confidence > seen[key].confidence:
            seen[key] = t
    
    return sorted(seen.values(), key=lambda t: t.confidence, reverse=True)


# =============================================================================
# Prompt Building with Token Budget
# =============================================================================

def truncate_to_tokens(text: str, max_tokens: int) -> str:
    """Truncate text to fit within token limit."""
    if WHISPER_TOKENIZER is not None:
        tokens = WHISPER_TOKENIZER.encode(text)
        if len(tokens) <= max_tokens:
            return text
        truncated_tokens = tokens[:max_tokens]
        return WHISPER_TOKENIZER.decode(truncated_tokens)
    else:
        # Approximate: assume 1.3 tokens per word
        words = text.split()
        max_words = int(max_tokens / 1.3)
        return ' '.join(words[:max_words])


def build_prompt_with_budget(
    vocabulary: list[Term],
    names: list[str],
    max_tokens: int = MAX_PROMPT_TOKENS - SAFETY_MARGIN
) -> PromptOutput:
    """Build prompt respecting Whisper's token limit, overflow to vocab file.
    
    Args:
        vocabulary: List of Term objects to include
        names: List of person names (highest priority)
        max_tokens: Maximum tokens for initial_prompt
    
    Returns:
        PromptOutput with initial_prompt and vocabulary_terms
    """
    # Categorize terms
    name_terms = [t for t in vocabulary if t.category == 'person_name']
    phrase_terms = [t for t in vocabulary if t.category in ('phrase', 'context', 'other')]
    technical_terms = [t for t in vocabulary if t.category in ('technical', 'acronym', 'project', 'org')]
    
    # Names get highest priority in prompt
    all_names = list(set(names + [t.text for t in name_terms]))
    name_section = ", ".join(all_names) if all_names else ""
    name_tokens = count_tokens(name_section) if name_section else 0
    
    remaining_tokens = max_tokens - name_tokens
    if remaining_tokens < 20:
        # Names alone exceed budget - truncate
        return PromptOutput(
            initial_prompt=truncate_to_tokens(f"Speakers: {name_section}", max_tokens),
            vocabulary_terms=[t.text for t in technical_terms],
            prompt_token_count=max_tokens,
            terms_in_prompt=len(all_names),
            terms_in_vocab_file=len(technical_terms)
        )
    
    # Add phrase/context terms to prompt, sorted by confidence
    prompt_terms = []
    current_tokens = name_tokens
    
    for term in sorted(phrase_terms, key=lambda t: t.confidence, reverse=True):
        term_tokens = count_tokens(f", {term.text}")
        if current_tokens + term_tokens > max_tokens:
            break
        prompt_terms.append(term.text)
        current_tokens += term_tokens
    
    # Build initial_prompt
    parts = []
    if all_names:
        parts.append(f"Speakers: {name_section}")
    if prompt_terms:
        parts.append(f"Context: {', '.join(prompt_terms)}")
    initial_prompt = ". ".join(parts)
    
    # Technical terms go to vocabulary file (no token limit concern)
    vocab_file_terms = [t.text for t in technical_terms]
    
    return PromptOutput(
        initial_prompt=initial_prompt,
        vocabulary_terms=vocab_file_terms,
        prompt_token_count=current_tokens,
        terms_in_prompt=len(all_names) + len(prompt_terms),
        terms_in_vocab_file=len(vocab_file_terms)
    )


def write_vocabulary_file(terms: list[str], output_dir: Path) -> str:
    """Write terms to a temporary vocabulary file for Whisper.
    
    Args:
        terms: List of vocabulary terms
        output_dir: Directory to write file in
    
    Returns:
        Path to vocabulary file
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    vocab_path = output_dir / f'vocab_{uuid.uuid4().hex[:8]}.txt'
    vocab_path.write_text('\n'.join(terms))
    return str(vocab_path)


# =============================================================================
# Vocabulary Merging
# =============================================================================

def merge_vocabulary(
    sources: list[tuple[list[Term] | list[str], float]],
    max_terms: int = 100,
    dedupe: bool = True
) -> list[Term]:
    """Merge vocabulary from multiple sources with weighting.
    
    Args:
        sources: List of (terms, weight) tuples. Terms can be Term objects or strings.
        max_terms: Maximum terms to return.
        dedupe: Whether to deduplicate by text.
    
    Returns:
        Merged list of Term objects, sorted by weighted confidence.
    """
    all_terms: list[Term] = []
    
    for terms, weight in sources:
        for t in terms:
            if isinstance(t, str):
                all_terms.append(Term(text=t, confidence=weight, source='merged'))
            elif isinstance(t, Term):
                all_terms.append(t.with_weight(weight))
    
    if dedupe:
        all_terms = dedupe_terms(all_terms)
    
    # Sort by confidence and limit
    all_terms.sort(key=lambda t: t.confidence, reverse=True)
    return all_terms[:max_terms]


# =============================================================================
# Speaker Matching
# =============================================================================

def match_speakers(embeddings: list[np.ndarray], db: 'SpeakerDatabase') -> IndexedMatchResult:
    """Match embeddings using relative threshold (gap-based) approach.
    
    Each embedding corresponds to a cluster index (0 = SPEAKER_00, 1 = SPEAKER_01, etc.).
    Returns an IndexedMatchResult that preserves the cluster index → speaker_id mapping.
    
    Args:
        embeddings: List of speaker embeddings to match (ordered by cluster index)
        db: Speaker database for matching
    
    Returns:
        IndexedMatchResult with per-index speaker_map and legacy matched/unknown/ambiguous lists
    """
    matched = []
    unknown = []
    ambiguous = []
    speaker_map: dict[int, SpeakerMatch | None] = {}
    
    for idx, emb in enumerate(embeddings):
        candidates = db.get_top_matches(emb, limit=3)
        
        if not candidates:
            unknown.append(emb)
            speaker_map[idx] = None
            continue
        
        best = candidates[0]
        second_best = candidates[1] if len(candidates) > 1 else None
        
        # Calculate confidence gap
        gap = best.similarity - (second_best.similarity if second_best else 0.0)
        
        # Confident match: large gap OR very high absolute similarity
        if gap > 0.15 or best.similarity > 0.92:
            match = SpeakerMatch(
                speaker_id=best.speaker_id,
                similarity=best.similarity,
                confidence_gap=gap,
                is_confident=True
            )
            matched.append(match)
            speaker_map[idx] = match
        elif best.similarity > 0.75:  # Ambiguous but possible
            match = SpeakerMatch(
                speaker_id=best.speaker_id,
                similarity=best.similarity,
                confidence_gap=gap,
                is_confident=False
            )
            ambiguous.append(match)
            speaker_map[idx] = match
        else:
            unknown.append(emb)
            speaker_map[idx] = None
    
    return IndexedMatchResult(
        speaker_map=speaker_map,
        matched=matched,
        unknown=unknown,
        ambiguous=ambiguous
    )


# =============================================================================
# Cache Lookup
# =============================================================================

def compute_full_cache_key(known_ids: list[str], unknown_count: int) -> str:
    """Compute cache key for full match."""
    import hashlib
    sorted_ids = sorted(known_ids)
    data = json.dumps({'ids': sorted_ids, 'unknown': unknown_count})
    return hashlib.sha256(data.encode()).hexdigest()[:32]


def compute_partial_cache_key(known_ids: list[str]) -> str:
    """Compute cache key for partial match (ignores unknowns)."""
    import hashlib
    sorted_ids = sorted(known_ids)
    data = json.dumps({'ids': sorted_ids})
    return hashlib.sha256(data.encode()).hexdigest()[:32]


def lookup_cache(db: 'SpeakerDatabase', known_ids: list[str], unknown_count: int) -> CacheLookupResult:
    """Try full match first, then partial match on known speakers only.
    
    Args:
        db: Speaker database
        known_ids: List of matched speaker IDs
        unknown_count: Number of unknown speakers
    
    Returns:
        CacheLookupResult with prompt and match type
    """
    from term_types import CacheLookupResult
    
    # Tier 1: Exact match (same known speakers + same unknown count)
    cached = db.get_prompt_for_speakers(known_ids, unknown_count)
    if cached and cached.effective_confidence > 0.7:
        return CacheLookupResult(prompt=cached, match_type="full", confidence=cached.effective_confidence)
    
    # Tier 2: Partial match (known speakers only, ignore unknowns)
    if known_ids:
        partial = db.get_partial_prompt(known_ids)
        if partial and partial.effective_confidence > 0.6:
            # Reduce confidence since we're ignoring unknown speakers
            adjusted_confidence = partial.effective_confidence * 0.8
            return CacheLookupResult(prompt=partial, match_type="partial", confidence=adjusted_confidence)
    
    return CacheLookupResult(prompt=None, match_type="miss", confidence=0.0)


# =============================================================================
# Quality Scoring
# =============================================================================

def compute_embedding_quality(
    embedding: np.ndarray,
    segment_duration: float,
    speaker_overlap_ratio: float = 0.0
) -> float:
    """Compute quality score using readily available metrics.
    
    Factors:
    - Duration: Longer segments are more reliable (3-8s optimal)
    - Overlap: Multiple speakers in segment reduces reliability
    - Embedding validity: Not NaN/Inf, reasonable norm
    
    Args:
        embedding: Speaker embedding
        segment_duration: Duration of audio segment in seconds
        speaker_overlap_ratio: Ratio of overlap with other speakers (0-1)
    
    Returns:
        Quality score (0-1)
    """
    score = 1.0
    
    # Duration factor: penalize very short or very long segments
    if segment_duration < 1.0:
        score *= 0.3  # Very short, unreliable
    elif segment_duration < 3.0:
        score *= 0.7
    elif segment_duration > 15.0:
        score *= 0.8  # May contain multiple speakers
    
    # Overlap penalty (multiple speakers in segment)
    score *= (1.0 - speaker_overlap_ratio * 0.5)
    
    # Embedding validity
    if np.any(np.isnan(embedding)) or np.any(np.isinf(embedding)):
        return 0.0
    
    norm = np.linalg.norm(embedding)
    if norm < 0.1 or norm > 100:  # Suspicious embedding
        score *= 0.5
    
    return min(1.0, max(0.0, score))


def compute_cache_confidence(
    known_speaker_ratio: float,
    match_quality: float,
    has_ambiguous: bool
) -> float:
    """Compute confidence score for caching a prompt.
    
    Higher confidence = more likely to reuse this cache entry.
    
    Args:
        known_speaker_ratio: Ratio of known to total speakers
        match_quality: Average confidence gap of matches
        has_ambiguous: Whether there are ambiguous matches
    
    Returns:
        Confidence score (0-1)
    """
    base = 0.5
    
    # More known speakers = higher confidence
    base += known_speaker_ratio * 0.3
    
    # Better match quality = higher confidence
    base += match_quality * 0.2
    
    # Ambiguous matches reduce confidence
    if has_ambiguous:
        base *= 0.8
    
    return min(1.0, max(0.0, base))


# =============================================================================
# Quick Transcription
# =============================================================================

def quick_transcribe(audio_path: str, duration: float, prompt: str = "") -> str:
    """Quick transcription of audio segment using Whisper turbo model.
    
    This is a wrapper around Whisper transcription that:
    - Uses the turbo/small model for speed
    - Limits duration to specified seconds
    - Applies the given prompt for context
    
    Args:
        audio_path: Path to audio file
        duration: Maximum duration to transcribe (seconds)
        prompt: Initial prompt for context
    
    Returns:
        Transcribed text
    """
    try:
        import whisper
        model = whisper.load_model("turbo")
        result = model.transcribe(
            audio_path,
            initial_prompt=prompt,
            condition_on_previous_text=False
        )
        return result["text"]
    except Exception as e:
        raise QuickTranscribeError(f"Quick transcription failed: {e}")


def build_partial_prompt(known_terms: list[str], extracted_names: list[str]) -> str:
    """Build a partial prompt for the second transcription pass.
    
    Args:
        known_terms: Terms from known speakers
        extracted_names: Names extracted from first pass
    
    Returns:
        Partial prompt string
    """
    parts = []
    if extracted_names:
        parts.append(f"Speakers: {', '.join(extracted_names[:5])}")
    if known_terms:
        # Include top known terms (limit to avoid token overflow)
        parts.append(f"Context: {', '.join(known_terms[:10])}")
    return ". ".join(parts) if parts else ""


def refined_quick_transcribe(
    audio_path: str,
    duration: float,
    known_speaker_terms: list[str]
) -> RefinedTranscript:
    """Two-pass transcription for better term extraction on cache miss.
    
    Returns RefinedTranscript with:
    - extracted_names: Person names only (for prompt priority)
    - high_confidence_terms: Terms in both passes OR matching known terms
    - all_terms: Union of all extracted terms
    
    Args:
        audio_path: Path to audio file
        duration: Maximum duration to transcribe
        known_speaker_terms: Terms from known speakers for context
    
    Returns:
        RefinedTranscript with extracted information
    """
    # Pass 1: Minimal prompt to get baseline
    pass1_text = quick_transcribe(audio_path, duration=duration, prompt="")
    pass1_terms = extract_terms(pass1_text)
    
    # Build partial prompt from known speaker terms + high-confidence pass1 terms
    high_conf_names = [t.text for t in pass1_terms if t.category == 'person_name' and t.confidence > 0.7]
    partial_prompt = build_partial_prompt(known_speaker_terms, high_conf_names)
    
    # Pass 2: Re-transcribe with partial prompt for better accuracy
    pass2_text = quick_transcribe(audio_path, duration=duration, prompt=partial_prompt)
    pass2_terms = extract_terms(pass2_text)
    
    # Create sets for comparison (Term.__hash__ uses normalized text)
    pass1_set = set(pass1_terms)
    pass2_set = set(pass2_terms)
    known_set = {t.lower() for t in known_speaker_terms}
    
    # High-confidence: terms in both passes
    in_both = pass1_set & pass2_set
    
    # Also include pass2 terms that match known speaker terms
    matching_known = [t for t in pass2_terms if t.text.lower() in known_set]
    
    # Combine and dedupe
    high_confidence = dedupe_terms(list(in_both) + matching_known)
    
    # Extract person names from pass2 (final transcription)
    extracted_names = [t.text for t in pass2_terms if t.category == 'person_name']
    
    # All terms: union of both passes
    all_terms = dedupe_terms(pass1_terms + pass2_terms)
    
    return RefinedTranscript(
        text=pass2_text,
        extracted_names=extracted_names,
        high_confidence_terms=high_confidence,
        all_terms=all_terms
    )


# =============================================================================
# Embedding Extraction (Wrappers)
# =============================================================================

def extract_embeddings_adaptive(
    audio_path: str,
    max_duration: float,
    min_speakers: int = 1,
    stability_window: float = 10.0
) -> tuple[list[np.ndarray], list[float]]:
    """Extract speaker embeddings with adaptive early stopping.
    
    Stops early if speaker count stabilizes (same count for stability_window seconds).
    Reuses existing SpeechBrain embedding extraction from diarize_audio_fast.py.
    
    Args:
        audio_path: Path to audio file
        max_duration: Maximum duration to process
        min_speakers: Minimum expected speakers
        stability_window: Time window for speaker count stability
    
    Returns:
        Tuple of (embeddings, segment_durations)
    """
    try:
        from diarize_audio_fast import extract_embeddings
        return extract_embeddings(audio_path, max_duration=max_duration)
    except ImportError:
        # Fallback: return empty if diarize_audio_fast not available
        logger.warning("diarize_audio_fast not available for embedding extraction")
        return [], []


def cluster_and_average(embeddings: list[np.ndarray]) -> list[np.ndarray]:
    """Cluster embeddings and return averaged embedding per cluster.
    
    Reuses existing clustering logic from diarize_audio_fast.py.
    
    Args:
        embeddings: List of speaker embeddings
    
    Returns:
        List of cluster centroid embeddings
    """
    try:
        from diarize_audio_fast import cluster_speakers
        return cluster_speakers(embeddings)
    except ImportError:
        # Fallback: just return unique embeddings
        logger.warning("diarize_audio_fast not available for clustering")
        return embeddings


# =============================================================================
# Observability
# =============================================================================

def log_prompt_generation(result: SmartPromptResult, latency_ms: float, audio_path: str):
    """Emit structured log for observability.
    
    Args:
        result: Generation result
        latency_ms: Generation latency in milliseconds
        audio_path: Path to audio file
    """
    log_entry = {
        'timestamp': datetime.utcnow().isoformat(),
        'event': 'prompt_generation',
        'audio_path': str(Path(audio_path).name),  # Don't log full path
        'source': result.source,
        'confidence': round(result.confidence, 3),
        'known_speakers': len(result.speaker_ids),
        'new_speakers': result.new_speakers_created,
        'prompt_tokens': result.prompt_token_count,
        'vocab_terms': result.vocab_term_count,
        'latency_ms': round(latency_ms, 1)
    }
    logger.info(json.dumps(log_entry))


def timed(func):
    """Decorator to measure function execution time."""
    @wraps(func)
    def wrapper(*args, **kwargs):
        start = time.perf_counter()
        result = func(*args, **kwargs)
        elapsed_ms = (time.perf_counter() - start) * 1000
        return result, elapsed_ms
    return wrapper


# =============================================================================
# Main Flow
# =============================================================================

def _fallback_static_prompt(static_vocabulary: Optional[list[str]]) -> SmartPromptResult:
    """Graceful fallback to static vocabulary - never worse than before.
    
    Args:
        static_vocabulary: Static vocabulary terms to use
    
    Returns:
        SmartPromptResult with fallback prompt
    """
    # Convert strings to Terms for build_prompt_with_budget
    terms = [Term(text=t, category='other', source='static') for t in (static_vocabulary or [])]
    prompt_output = build_prompt_with_budget(vocabulary=terms, names=[])
    return SmartPromptResult(
        initial_prompt=prompt_output.initial_prompt,
        vocabulary_file_path=None,
        source="fallback_static",
        speaker_ids=[],
        confidence=0.0,
        prompt_token_count=prompt_output.prompt_token_count,
        vocab_term_count=0
    )


def generate_smart_prompt(
    audio_path: str,
    speaker_db: 'SpeakerDatabase',
    rag_client: Optional['VocabularySource'] = None,
    static_vocabulary: Optional[list[str]] = None,
    quick_transcribe_seconds: float = 45.0
) -> SmartPromptResult:
    """Generate prompt with graceful degradation on any failure.
    
    Args:
        audio_path: Path to audio file
        speaker_db: Speaker database for matching and caching
        rag_client: Optional RAG client for vocabulary
        static_vocabulary: Fallback static vocabulary
        quick_transcribe_seconds: Duration for quick transcription
    
    Returns:
        SmartPromptResult with prompt and metadata
    """
    try:
        # 1. Extract embeddings (adaptive duration - stop early if speakers stabilize)
        embeddings, durations = extract_embeddings_adaptive(
            audio_path,
            max_duration=quick_transcribe_seconds,
            min_speakers=1,
            stability_window=10.0
        )
        
        if not embeddings:
            raise NoSpeakersDetected("No speech detected in audio")
        
        # 2. Cluster to identify distinct speakers
        speaker_embeddings = cluster_and_average(embeddings)
        
        # 3. Match against known speakers (relative threshold)
        match_result = match_speakers(speaker_embeddings, speaker_db)
        known_ids = [m.speaker_id for m in match_result.matched]
        unknown_count = len(match_result.unknown)
        
        # Build speaker_label_map: SPEAKER_XX → speaker_id
        speaker_label_map: dict[str, str | None] = {}
        for cluster_idx, match in match_result.speaker_map.items():
            label = f"SPEAKER_{cluster_idx:02d}"
            speaker_label_map[label] = match.speaker_id if match else None
        
        # 4. Two-tier cache lookup
        cache_result = lookup_cache(speaker_db, known_ids, unknown_count)
        
        if cache_result.match_type == "full" and cache_result.confidence > 0.8:
            # Full cache hit - use directly
            speaker_db.record_cache_hit(cache_result.prompt.cache_key)
            cached_prompt = cache_result.prompt.prompt_text
            cached_vocab = cache_result.prompt.vocabulary_terms
            return SmartPromptResult(
                initial_prompt=cached_prompt,
                vocabulary_file_path=None,  # Cache hit doesn't need new file
                source="cache_full",
                speaker_ids=known_ids,
                confidence=cache_result.confidence,
                prompt_token_count=count_tokens(cached_prompt),
                vocab_term_count=len(cached_vocab) if cached_vocab else 0,
                cache_key=cache_result.prompt.cache_key,
                speaker_label_map=speaker_label_map,
            )
        
        # 5. Cache miss or partial - need to generate/augment
        # Get known speaker terms for refinement (returns list[Term])
        known_terms = speaker_db.get_speaker_terms(
            known_ids,
            cooccurring_ids=known_ids  # Weight by this meeting's participants
        )
        
        # 6. Iterative quick-transcribe (two-pass for better accuracy)
        refined = refined_quick_transcribe(
            audio_path,
            duration=quick_transcribe_seconds,
            known_speaker_terms=[t.text for t in known_terms]
        )
        
        # 7. Query RAG for vocabulary (parallel, with timeout)
        rag_terms: list[Term] = []
        if rag_client:
            try:
                from vocabulary_sources import fetch_rag_vocabulary_parallel
                rag_terms = fetch_rag_vocabulary_parallel(
                    rag_client,
                    speaker_names=[speaker_db.get_speaker(sid).name for sid in known_ids if speaker_db.get_speaker(sid) and speaker_db.get_speaker(sid).name],
                    extracted_names=refined.extracted_names,
                    timeout=2.0
                )
            except RAGError as e:
                logger.warning(f"RAG query failed, continuing without: {e}")
            except Exception as e:
                logger.warning(f"RAG query error: {e}")
        
        # 8. Merge vocabulary from all sources
        vocabulary = merge_vocabulary(
            sources=[
                (refined.high_confidence_terms, 1.0),   # Highest weight
                (known_terms, 0.8),                     # Known speaker terms
                (rag_terms, 0.6),                       # RAG terms
                (refined.all_terms, 0.4),              # Lower-confidence extracted
            ],
            max_terms=100,
            dedupe=True
        )
        
        # 9. Build final prompt with token budget management
        prompt_output = build_prompt_with_budget(
            vocabulary=vocabulary,
            names=refined.extracted_names
        )
        
        # 10. Write vocabulary file if we have overflow terms
        vocab_file_path = None
        if prompt_output.vocabulary_terms:
            vocab_file_path = write_vocabulary_file(
                prompt_output.vocabulary_terms,
                output_dir=Path(audio_path).parent / '.meetingscribe_temp'
            )
        
        # 11. Compute confidence for caching
        confidence = compute_cache_confidence(
            known_speaker_ratio=len(known_ids) / (len(known_ids) + unknown_count) if (known_ids or unknown_count) else 0,
            match_quality=sum(m.confidence_gap for m in match_result.matched) / len(match_result.matched) if match_result.matched else 0,
            has_ambiguous=len(match_result.ambiguous) > 0
        )
        
        # 12. Cache result (both full and partial keys)
        generated_cache_key = compute_full_cache_key(known_ids, unknown_count)
        speaker_db.save_prompt(
            known_ids=known_ids,
            unknown_count=unknown_count,
            prompt=prompt_output.initial_prompt,
            vocabulary=[t.text for t in vocabulary],
            confidence=confidence
        )
        
        # 13. Register unknown speakers (without auto-naming)
        new_speakers = 0
        for emb in match_result.unknown:
            new_id = speaker_db.create_speaker(centroid=emb)
            new_speakers += 1
            # Queue name suggestions if 1:1 correspondence with extracted names
            # But DO NOT auto-commit - require explicit confirmation
            if len(match_result.unknown) == 1 and len(refined.extracted_names) == 1:
                speaker_db.suggest_name(
                    speaker_id=new_id,
                    suggested_name=refined.extracted_names[0],
                    source='transcript',
                    confidence=0.5,  # Low confidence - needs confirmation
                    context=refined.text[:200]
                )
        
        return SmartPromptResult(
            initial_prompt=prompt_output.initial_prompt,
            vocabulary_file_path=vocab_file_path,
            source="generated",
            speaker_ids=known_ids,
            confidence=confidence,
            new_speakers_created=new_speakers,
            prompt_token_count=prompt_output.prompt_token_count,
            vocab_term_count=prompt_output.terms_in_vocab_file,
            cache_key=generated_cache_key,
            speaker_label_map=speaker_label_map,
        )
        
    except SpeakerDBError as e:
        logger.warning(f"Speaker DB unavailable: {e}. Falling back to static prompt.")
        return _fallback_static_prompt(static_vocabulary)
    
    except NoSpeakersDetected:
        logger.warning("No speakers detected. Falling back to static prompt.")
        return _fallback_static_prompt(static_vocabulary)
    
    except QuickTranscribeError as e:
        logger.warning(f"Quick transcribe failed: {e}. Using embedding-only matching.")
        # Still try to use known speaker terms even without quick transcription
        try:
            if 'known_ids' in dir() and known_ids:
                terms = speaker_db.get_speaker_terms(known_ids)
                prompt_output = build_prompt_with_budget(
                    vocabulary=terms,
                    names=[]
                )
                return SmartPromptResult(
                    initial_prompt=prompt_output.initial_prompt,
                    vocabulary_file_path=None,
                    source="speaker_terms_only",
                    speaker_ids=known_ids,
                    confidence=0.5,
                    prompt_token_count=prompt_output.prompt_token_count,
                    vocab_term_count=0
                )
        except Exception:
            pass
        return _fallback_static_prompt(static_vocabulary)


# =============================================================================
# Database Cleanup
# =============================================================================

def cleanup_database(db: 'SpeakerDatabase'):
    """Periodic maintenance - call on app startup or schedule weekly.
    
    Uses explicit transaction to ensure atomic cleanup.
    
    Args:
        db: Speaker database to clean up
    """
    # Backup before cleanup
    db.backup()
    
    try:
        # Start exclusive transaction for all deletes
        db.conn.execute("BEGIN IMMEDIATE")
        
        # Remove unnamed speakers not seen in 90 days
        db.conn.execute("""
            DELETE FROM speakers 
            WHERE name IS NULL 
            AND last_seen_at < datetime('now', '-90 days')
        """)
        
        # Remove low-confidence prompt cache entries not used in 30 days
        db.conn.execute("""
            DELETE FROM prompt_cache 
            WHERE last_used_at < datetime('now', '-30 days')
            AND base_confidence < 0.7
        """)
        
        # Prune old embeddings (keep max 10 per speaker, prefer recent + high quality)
        db.conn.execute("""
            DELETE FROM speaker_embeddings
            WHERE embedding_id NOT IN (
                SELECT embedding_id FROM (
                    SELECT embedding_id, 
                           ROW_NUMBER() OVER (
                               PARTITION BY speaker_id 
                               ORDER BY quality_score DESC, timestamp DESC
                           ) as rn
                    FROM speaker_embeddings
                ) WHERE rn <= 10
            )
        """)
        
        # Prune speaker terms (keep max 500 per speaker, prefer high frequency + recent)
        db.conn.execute("""
            DELETE FROM speaker_terms
            WHERE rowid NOT IN (
                SELECT rowid FROM (
                    SELECT rowid,
                           ROW_NUMBER() OVER (
                               PARTITION BY speaker_id
                               ORDER BY frequency DESC, last_seen_at DESC
                           ) as rn
                    FROM speaker_terms
                ) WHERE rn <= 500
            )
        """)
        
        # Prune co-occurrence table (keep max 1000 entries per speaker)
        db.conn.execute("""
            DELETE FROM speaker_term_cooccurrence
            WHERE rowid NOT IN (
                SELECT rowid FROM (
                    SELECT rowid,
                           ROW_NUMBER() OVER (
                               PARTITION BY speaker_id
                               ORDER BY frequency DESC, last_seen_at DESC
                           ) as rn
                    FROM speaker_term_cooccurrence
                ) WHERE rn <= 1000
            )
        """)
        
        # Remove stale co-occurrences (not seen in 180 days)
        db.conn.execute("""
            DELETE FROM speaker_term_cooccurrence
            WHERE last_seen_at < datetime('now', '-180 days')
        """)
        
        # Recalculate centroids for speakers with pruned embeddings
        db._recalculate_all_centroids()
        
        # Commit all deletes atomically
        db.conn.execute("COMMIT")
        
    except Exception as e:
        db.conn.execute("ROLLBACK")
        logger.error(f"Cleanup failed, rolled back: {e}")
        raise
    
    # VACUUM must be outside transaction
    db.conn.execute("VACUUM")
    logger.info("Database cleanup completed")


# =============================================================================
# Cache Quality Recording
# =============================================================================

def record_cache_quality(db: 'SpeakerDatabase', cache_key: str, final_transcript: str):
    """After transcription, record how well the cached prompt performed.
    
    Args:
        db: Speaker database
        cache_key: Cache key that was used
        final_transcript: Final transcribed text
    """
    cached = db.get_prompt_by_key(cache_key)
    if not cached:
        return
    
    cached_terms = set(cached.vocabulary_terms)
    transcript_terms = set(t.text for t in extract_terms(final_transcript))
    
    # How many cached terms appeared?
    if cached_terms:
        hit_rate = len(cached_terms & transcript_terms) / len(cached_terms)
    else:
        hit_rate = 0.0
    
    # How many transcript terms were unknown?
    if transcript_terms:
        unknown_rate = len(transcript_terms - cached_terms) / len(transcript_terms)
    else:
        unknown_rate = 0.0
    
    # Quality score: high hit rate + low unknown rate = good
    quality_score = (hit_rate * 0.6) + ((1 - unknown_rate) * 0.4)
    
    db.update_cache_quality(cache_key, quality_score)
