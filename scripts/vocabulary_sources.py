"""Vocabulary source abstraction for smart prompt generation.

This module provides a unified interface for vocabulary sources:
- BearRAGSource: Queries bear-rag API for semantic search of historical transcripts
- LocalGlossarySource: Uses existing local glossary file
- CompositeVocabularySource: Combines multiple sources with priority ordering
"""
import json
import logging
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeoutError
from typing import Protocol

from term_types import Term

logger = logging.getLogger(__name__)


class VocabularySource(Protocol):
    """Abstract interface for vocabulary sources.
    
    All methods return the unified Term type for seamless integration.
    """
    
    def get_vocabulary_for_person(self, name: str) -> list[Term]:
        """Get vocabulary associated with a person.
        
        Args:
            name: Person's name to look up
        
        Returns:
            List of Term objects associated with the person
        """
        ...
    
    def get_vocabulary_for_context(self, context: str) -> list[Term]:
        """Get vocabulary for a general context/topic.
        
        Args:
            context: Context string or topic
        
        Returns:
            List of Term objects related to the context
        """
        ...


def dedupe_terms(terms: list[Term]) -> list[Term]:
    """Remove duplicate terms, keeping highest confidence."""
    seen: dict[str, Term] = {}
    for t in terms:
        key = t.text.lower()
        if key not in seen or t.confidence > seen[key].confidence:
            seen[key] = t
    return sorted(seen.values(), key=lambda t: t.confidence, reverse=True)


def extract_terms_simple(content: str) -> list[Term]:
    """Simple term extraction without NER (fast path for RAG results).
    
    Args:
        content: Text content to extract terms from
    
    Returns:
        List of Term objects
    """
    import re
    from collections import Counter
    
    terms = []
    
    # Acronyms: 2-6 uppercase letters
    COMMON_ACRONYMS = {'OK', 'PM', 'AM', 'TV', 'US', 'UK', 'IT', 'HR', 'AI', 'ML'}
    acronyms = re.findall(r'\b[A-Z]{2,6}\b', content)
    for acr in set(acronyms):
        if acr not in COMMON_ACRONYMS:
            freq = acronyms.count(acr)
            terms.append(Term(
                text=acr,
                category='acronym',
                confidence=min(0.8, 0.4 + freq * 0.1),
                source='rag'
            ))
    
    # Capitalized phrases (potential names/projects)
    cap_phrases = re.findall(r'\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})\b', content)
    cap_counter = Counter(cap_phrases)
    
    for phrase, count in cap_counter.items():
        if count >= 2 and phrase.split()[0].lower() not in {'the', 'this', 'that', 'i', 'we', 'you', 'a', 'an'}:
            category = 'person_name' if len(phrase.split()) >= 2 else 'other'
            terms.append(Term(
                text=phrase,
                category=category,
                confidence=0.5,
                source='rag'
            ))
    
    return dedupe_terms(terms)[:20]


class BearRAGSource:
    """Implementation using bear-rag API.
    
    Queries the bear-rag service for semantic search of historical meeting
    transcripts and returns vocabulary terms from matching documents.
    """
    
    def __init__(self, endpoint: str = "http://localhost:8000", timeout: float = 2.0):
        """Initialize BearRAG client.
        
        Args:
            endpoint: Base URL for bear-rag API
            timeout: Request timeout in seconds
        """
        self.endpoint = endpoint.rstrip('/')
        self.timeout = timeout
    
    def get_vocabulary_for_person(self, name: str) -> list[Term]:
        """Get vocabulary from meetings with a specific person.
        
        Args:
            name: Person's name to search for
        
        Returns:
            List of Term objects from matching documents
        """
        try:
            import requests
            response = requests.post(
                f"{self.endpoint}/search",
                json={"query": f"meetings with {name}", "limit": 10, "tags": ["meetings"]},
                timeout=self.timeout
            )
            if response.ok:
                return self._extract_vocabulary(response.json())
        except Exception as e:
            logger.warning(f"RAG request failed for person '{name}': {e}")
        return []
    
    def get_vocabulary_for_context(self, context: str) -> list[Term]:
        """Get vocabulary for a general context/topic.
        
        Args:
            context: Context string to search for
        
        Returns:
            List of Term objects from matching documents
        """
        try:
            import requests
            response = requests.post(
                f"{self.endpoint}/search",
                json={"query": context, "limit": 5},
                timeout=self.timeout
            )
            if response.ok:
                return self._extract_vocabulary(response.json())
        except Exception as e:
            logger.warning(f"RAG request failed for context: {e}")
        return []
    
    def _extract_vocabulary(self, results: dict) -> list[Term]:
        """Extract technical terms from search results.
        
        Args:
            results: Search results from bear-rag API
        
        Returns:
            List of Term objects
        """
        terms = []
        for result in results.get('results', []):
            content = result.get('content', '')
            # Use simple extraction (skip NER for speed)
            extracted = extract_terms_simple(content)
            for t in extracted:
                # Re-wrap with 'rag' source and slightly lower confidence
                terms.append(Term(
                    text=t.text,
                    category=t.category,
                    confidence=t.confidence * 0.8,
                    source='rag'
                ))
        return dedupe_terms(terms)[:20]


class LocalGlossarySource:
    """Implementation using existing local glossary file.
    
    Loads vocabulary from a JSON glossary file and provides it
    based on context matching.
    """
    
    def __init__(self, glossary_path: str):
        """Initialize with glossary file.
        
        Args:
            glossary_path: Path to JSON glossary file
        """
        self.glossary_path = glossary_path
        self.glossary = self._load_glossary(glossary_path)
    
    def _load_glossary(self, path: str) -> list[dict]:
        """Load glossary from JSON file.
        
        Args:
            path: Path to glossary file
        
        Returns:
            List of glossary entries
        """
        try:
            with open(path) as f:
                data = json.load(f)
                # Handle both list and dict formats
                if isinstance(data, list):
                    return data
                elif isinstance(data, dict) and 'entries' in data:
                    return data['entries']
                elif isinstance(data, dict):
                    # Convert dict to list of entries
                    return [{'term': k, **v} if isinstance(v, dict) else {'term': k, 'definition': v} 
                            for k, v in data.items()]
                return []
        except (FileNotFoundError, json.JSONDecodeError) as e:
            logger.warning(f"Failed to load glossary from {path}: {e}")
            return []
    
    def get_vocabulary_for_person(self, name: str) -> list[Term]:
        """Get vocabulary associated with a person.
        
        Glossary doesn't track person associations, so returns empty.
        
        Args:
            name: Person's name (unused)
        
        Returns:
            Empty list
        """
        return []
    
    def get_vocabulary_for_context(self, context: str) -> list[Term]:
        """Get vocabulary for a context.
        
        Returns all glossary terms (caller can filter by relevance).
        
        Args:
            context: Context string (unused, returns all terms)
        
        Returns:
            List of Term objects from glossary
        """
        return [
            Term(
                text=entry.get('term', entry.get('name', '')),
                category='technical',
                confidence=1.0,
                source='glossary'
            )
            for entry in self.glossary
            if entry.get('term') or entry.get('name')
        ]


class CompositeVocabularySource:
    """Combines multiple sources with priority ordering.
    
    Queries multiple vocabulary sources and merges results,
    weighting terms by source priority.
    """
    
    def __init__(self, sources: list[tuple[VocabularySource, float]]):
        """Initialize with weighted sources.
        
        Args:
            sources: List of (source, weight) tuples
        """
        self.sources = sources
    
    def get_vocabulary_for_person(self, name: str) -> list[Term]:
        """Get vocabulary for a person from all sources.
        
        Args:
            name: Person's name
        
        Returns:
            Merged list of Term objects from all sources
        """
        all_terms = []
        for source, weight in self.sources:
            try:
                terms = source.get_vocabulary_for_person(name)
                all_terms.extend(t.with_weight(weight) for t in terms)
            except Exception as e:
                logger.warning(f"Source failed for person lookup: {e}")
        return dedupe_terms(all_terms)
    
    def get_vocabulary_for_context(self, context: str) -> list[Term]:
        """Get vocabulary for a context from all sources.
        
        Args:
            context: Context string
        
        Returns:
            Merged list of Term objects from all sources
        """
        all_terms = []
        for source, weight in self.sources:
            try:
                terms = source.get_vocabulary_for_context(context)
                all_terms.extend(t.with_weight(weight) for t in terms)
            except Exception as e:
                logger.warning(f"Source failed for context lookup: {e}")
        return dedupe_terms(all_terms)


def fetch_rag_vocabulary_parallel(
    rag_client: VocabularySource,
    speaker_names: list[str],
    extracted_names: list[str],
    timeout: float = 2.0
) -> list[Term]:
    """Fetch vocabulary from RAG for multiple names in parallel.
    
    Queries the RAG source for each name concurrently to minimize
    total latency.
    
    Args:
        rag_client: Vocabulary source to query
        speaker_names: Names of known speakers
        extracted_names: Names extracted from transcription
        timeout: Timeout for each query
    
    Returns:
        Merged list of Term objects from all queries
    """
    all_names = list(set(speaker_names + extracted_names))
    if not all_names:
        return []
    
    all_terms: list[Term] = []
    
    with ThreadPoolExecutor(max_workers=min(4, len(all_names))) as executor:
        futures = {
            executor.submit(rag_client.get_vocabulary_for_person, name): name
            for name in all_names[:5]  # Limit to 5 names
        }
        
        for future in futures:
            try:
                terms = future.result(timeout=timeout)
                all_terms.extend(terms)
            except FuturesTimeoutError:
                logger.warning(f"RAG query timed out for {futures[future]}")
            except Exception as e:
                logger.warning(f"RAG query failed for {futures[future]}: {e}")
    
    return dedupe_terms(all_terms)


def create_vocabulary_source(
    rag_endpoint: str = "",
    glossary_path: str = "",
    rag_weight: float = 0.8,
    glossary_weight: float = 1.0
) -> VocabularySource:
    """Factory function to create appropriate vocabulary source.
    
    Creates a composite source from available sources (RAG and/or glossary).
    
    Args:
        rag_endpoint: bear-rag API endpoint (empty to disable)
        glossary_path: Path to glossary file (empty to disable)
        rag_weight: Weight for RAG terms (0-1)
        glossary_weight: Weight for glossary terms (0-1)
    
    Returns:
        Configured VocabularySource instance
    """
    sources = []
    
    if rag_endpoint:
        sources.append((BearRAGSource(rag_endpoint), rag_weight))
    
    if glossary_path:
        sources.append((LocalGlossarySource(glossary_path), glossary_weight))
    
    if not sources:
        # Return a no-op source
        class EmptySource:
            def get_vocabulary_for_person(self, name: str) -> list[Term]:
                return []
            def get_vocabulary_for_context(self, context: str) -> list[Term]:
                return []
        return EmptySource()
    
    if len(sources) == 1:
        return sources[0][0]
    
    return CompositeVocabularySource(sources)
