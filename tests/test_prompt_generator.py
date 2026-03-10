"""Unit tests for the prompt generator module."""
import sys
import unittest
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from term_types import Term, PromptOutput
from prompt_generator import (
    extract_terms,
    dedupe_terms,
    build_prompt_with_budget,
    merge_vocabulary,
    count_tokens,
    truncate_to_tokens,
    compute_embedding_quality,
    compute_cache_confidence,
    MAX_PROMPT_TOKENS,
    SAFETY_MARGIN,
)


class TestTermExtraction(unittest.TestCase):
    """Test term extraction from text."""
    
    def test_extract_acronyms(self):
        """Test extraction of acronyms."""
        text = "We discussed the API integration and the SDK documentation. The API is critical."
        terms = extract_terms(text, use_ner=False)
        
        term_texts = {t.text for t in terms}
        self.assertIn("API", term_texts)
        self.assertIn("SDK", term_texts)
    
    def test_extract_capitalized_names(self):
        """Test extraction of capitalized names."""
        text = "John Smith and Alice Johnson discussed the project. John Smith had concerns."
        terms = extract_terms(text, use_ner=False)
        
        term_texts = {t.text for t in terms}
        # Multi-word capitalized phrases should be detected
        self.assertIn("John Smith", term_texts)
    
    def test_extract_technical_terms(self):
        """Test extraction of technical terms."""
        text = "The kubernetes cluster is running. We need to configure kubernetes properly. The kubernetes deployment is ready."
        terms = extract_terms(text, use_ner=False)
        
        term_texts = {t.text.lower() for t in terms}
        self.assertIn("kubernetes", term_texts)
    
    def test_empty_text(self):
        """Test extraction from empty text."""
        terms = extract_terms("", use_ner=False)
        self.assertEqual(len(terms), 0)
        
        terms = extract_terms("   \n  ", use_ner=False)
        self.assertEqual(len(terms), 0)
    
    def test_common_acronyms_filtered(self):
        """Test that common acronyms are filtered out."""
        text = "The meeting is at 3 PM. OK, let's go. We're in the US."
        terms = extract_terms(text, use_ner=False)
        
        term_texts = {t.text for t in terms}
        self.assertNotIn("PM", term_texts)
        self.assertNotIn("OK", term_texts)
        self.assertNotIn("US", term_texts)


class TestTermDeduplication(unittest.TestCase):
    """Test term deduplication."""
    
    def test_dedupe_keeps_highest_confidence(self):
        """Test that deduplication keeps the highest confidence term."""
        terms = [
            Term(text="project", category="technical", confidence=0.5, source="extract"),
            Term(text="Project", category="other", confidence=0.8, source="rag"),
            Term(text="PROJECT", category="acronym", confidence=0.3, source="glossary"),
        ]
        
        deduped = dedupe_terms(terms)
        
        self.assertEqual(len(deduped), 1)
        self.assertEqual(deduped[0].confidence, 0.8)
        self.assertEqual(deduped[0].source, "rag")
    
    def test_dedupe_preserves_unique_terms(self):
        """Test that unique terms are preserved."""
        terms = [
            Term(text="apple", category="other", confidence=0.5, source="extract"),
            Term(text="banana", category="other", confidence=0.6, source="extract"),
            Term(text="cherry", category="other", confidence=0.7, source="extract"),
        ]
        
        deduped = dedupe_terms(terms)
        
        self.assertEqual(len(deduped), 3)


class TestPromptBuilding(unittest.TestCase):
    """Test prompt building with token budget."""
    
    def test_basic_prompt_building(self):
        """Test basic prompt building."""
        vocabulary = [
            Term(text="Alice", category="person_name", confidence=0.9, source="extract"),
            Term(text="API", category="technical", confidence=0.8, source="extract"),
        ]
        names = ["Bob"]
        
        output = build_prompt_with_budget(vocabulary, names)
        
        self.assertIn("Speakers:", output.initial_prompt)
        self.assertIn("Bob", output.initial_prompt)
        self.assertIn("Alice", output.initial_prompt)
        self.assertIn("API", output.vocabulary_terms)
    
    def test_names_have_priority(self):
        """Test that names have highest priority in prompt."""
        vocabulary = [
            Term(text="Alice", category="person_name", confidence=0.9, source="extract"),
            Term(text="some context", category="other", confidence=0.5, source="extract"),
        ]
        names = ["Bob", "Charlie"]
        
        output = build_prompt_with_budget(vocabulary, names)
        
        # All names should be in the prompt
        self.assertIn("Bob", output.initial_prompt)
        self.assertIn("Charlie", output.initial_prompt)
        self.assertIn("Alice", output.initial_prompt)
    
    def test_technical_terms_go_to_vocab_file(self):
        """Test that technical terms go to vocabulary file."""
        vocabulary = [
            Term(text="kubernetes", category="technical", confidence=0.8, source="extract"),
            Term(text="API", category="acronym", confidence=0.7, source="extract"),
            Term(text="ProjectX", category="project", confidence=0.6, source="extract"),
        ]
        
        output = build_prompt_with_budget(vocabulary, [])
        
        self.assertIn("kubernetes", output.vocabulary_terms)
        self.assertIn("API", output.vocabulary_terms)
        self.assertIn("ProjectX", output.vocabulary_terms)
    
    def test_respects_token_budget(self):
        """Test that prompt respects token budget."""
        # Create many terms
        vocabulary = [
            Term(text=f"term_{i}" * 5, category="other", confidence=0.5, source="extract")
            for i in range(50)
        ]
        
        output = build_prompt_with_budget(vocabulary, [])
        
        # Should be under the limit
        self.assertLessEqual(output.prompt_token_count, MAX_PROMPT_TOKENS - SAFETY_MARGIN)
    
    def test_empty_vocabulary(self):
        """Test with empty vocabulary."""
        output = build_prompt_with_budget([], [])
        
        self.assertEqual(output.initial_prompt, "")
        self.assertEqual(output.vocabulary_terms, [])
        self.assertEqual(output.prompt_token_count, 0)


class TestVocabularyMerging(unittest.TestCase):
    """Test vocabulary merging from multiple sources."""
    
    def test_merge_with_weights(self):
        """Test merging with source weights."""
        source1 = [
            Term(text="high_priority", category="technical", confidence=1.0, source="extract"),
        ]
        source2 = [
            Term(text="low_priority", category="technical", confidence=1.0, source="rag"),
        ]
        
        merged = merge_vocabulary([(source1, 1.0), (source2, 0.5)])
        
        # Both should be present, but confidence should reflect weights
        term_dict = {t.text: t for t in merged}
        self.assertGreater(
            term_dict["high_priority"].confidence,
            term_dict["low_priority"].confidence
        )
    
    def test_merge_deduplicates(self):
        """Test that merging deduplicates terms."""
        source1 = [Term(text="common", category="technical", confidence=0.9, source="extract")]
        source2 = [Term(text="common", category="technical", confidence=0.5, source="rag")]
        
        merged = merge_vocabulary([(source1, 1.0), (source2, 1.0)])
        
        # Should only have one instance
        common_terms = [t for t in merged if t.text == "common"]
        self.assertEqual(len(common_terms), 1)
        # Should keep highest confidence
        self.assertEqual(common_terms[0].confidence, 0.9)
    
    def test_merge_respects_max_terms(self):
        """Test that merging respects max_terms limit."""
        source = [
            Term(text=f"term_{i}", category="technical", confidence=1.0 - i*0.01, source="extract")
            for i in range(100)
        ]
        
        merged = merge_vocabulary([(source, 1.0)], max_terms=10)
        
        self.assertEqual(len(merged), 10)
        # Should keep highest confidence terms
        self.assertEqual(merged[0].text, "term_0")
    
    def test_merge_handles_strings(self):
        """Test that merging handles string inputs."""
        source = ["term1", "term2", "term3"]
        
        merged = merge_vocabulary([(source, 0.8)], max_terms=10)
        
        self.assertEqual(len(merged), 3)
        for term in merged:
            self.assertEqual(term.confidence, 0.8)


class TestTokenCounting(unittest.TestCase):
    """Test token counting functions."""
    
    def test_count_tokens_basic(self):
        """Test basic token counting."""
        text = "Hello world"
        count = count_tokens(text)
        
        # Should be at least 2 tokens
        self.assertGreaterEqual(count, 2)
    
    def test_count_tokens_empty(self):
        """Test token counting on empty string."""
        count = count_tokens("")
        self.assertEqual(count, 0)
    
    def test_truncate_to_tokens(self):
        """Test text truncation to token limit."""
        long_text = "This is a very long text " * 100
        
        truncated = truncate_to_tokens(long_text, max_tokens=20)
        
        # Should be shorter than original
        self.assertLess(len(truncated), len(long_text))
        
        # Should be within token limit
        self.assertLessEqual(count_tokens(truncated), 20)


class TestQualityScoring(unittest.TestCase):
    """Test quality scoring functions."""
    
    def test_embedding_quality_duration_factors(self):
        """Test that duration affects embedding quality."""
        import numpy as np
        embedding = np.random.randn(192).astype(np.float32)
        
        # Very short segment
        short_quality = compute_embedding_quality(embedding, segment_duration=0.5)
        
        # Optimal duration
        optimal_quality = compute_embedding_quality(embedding, segment_duration=5.0)
        
        # Very long segment
        long_quality = compute_embedding_quality(embedding, segment_duration=20.0)
        
        # Optimal should be best
        self.assertGreater(optimal_quality, short_quality)
        self.assertGreater(optimal_quality, long_quality)
    
    def test_embedding_quality_overlap_penalty(self):
        """Test that overlap penalizes quality."""
        import numpy as np
        embedding = np.random.randn(192).astype(np.float32)
        
        no_overlap = compute_embedding_quality(embedding, segment_duration=5.0, speaker_overlap_ratio=0.0)
        high_overlap = compute_embedding_quality(embedding, segment_duration=5.0, speaker_overlap_ratio=0.8)
        
        self.assertGreater(no_overlap, high_overlap)
    
    def test_embedding_quality_invalid_embedding(self):
        """Test that invalid embeddings get zero quality."""
        import numpy as np
        
        nan_embedding = np.array([np.nan] * 192, dtype=np.float32)
        quality = compute_embedding_quality(nan_embedding, segment_duration=5.0)
        self.assertEqual(quality, 0.0)
        
        inf_embedding = np.array([np.inf] * 192, dtype=np.float32)
        quality = compute_embedding_quality(inf_embedding, segment_duration=5.0)
        self.assertEqual(quality, 0.0)
    
    def test_cache_confidence_factors(self):
        """Test cache confidence computation."""
        # All known speakers, high quality
        high_conf = compute_cache_confidence(
            known_speaker_ratio=1.0,
            match_quality=0.9,
            has_ambiguous=False
        )
        
        # Mixed speakers, medium quality
        medium_conf = compute_cache_confidence(
            known_speaker_ratio=0.5,
            match_quality=0.5,
            has_ambiguous=False
        )
        
        # Ambiguous matches
        ambiguous_conf = compute_cache_confidence(
            known_speaker_ratio=1.0,
            match_quality=0.9,
            has_ambiguous=True
        )
        
        # High should be best
        self.assertGreater(high_conf, medium_conf)
        # Ambiguous should penalize
        self.assertGreater(high_conf, ambiguous_conf)
        
        # All should be in valid range
        self.assertGreaterEqual(high_conf, 0.0)
        self.assertLessEqual(high_conf, 1.0)


class TestTermClass(unittest.TestCase):
    """Test Term class functionality."""
    
    def test_term_hashable(self):
        """Test that Terms are hashable."""
        term1 = Term(text="test", category="technical", confidence=0.8, source="extract")
        term2 = Term(text="TEST", category="other", confidence=0.5, source="rag")
        
        # Same text (case-insensitive) should have same hash
        self.assertEqual(hash(term1), hash(term2))
        
        # Should work in sets
        term_set = {term1, term2}
        self.assertEqual(len(term_set), 1)
    
    def test_term_equality(self):
        """Test Term equality by text."""
        term1 = Term(text="Project", category="technical", confidence=0.8, source="extract")
        term2 = Term(text="project", category="other", confidence=0.5, source="rag")
        
        # Should be equal (case-insensitive)
        self.assertEqual(term1, term2)
        
        # Should also work with strings
        self.assertEqual(term1, "project")
        self.assertEqual(term1, "PROJECT")
    
    def test_term_with_weight(self):
        """Test Term.with_weight() method."""
        term = Term(text="test", category="technical", confidence=0.8, source="extract")
        
        weighted = term.with_weight(0.5)
        
        # Original should be unchanged (frozen dataclass)
        self.assertEqual(term.confidence, 0.8)
        
        # Weighted should have adjusted confidence
        self.assertEqual(weighted.confidence, 0.4)
        self.assertEqual(weighted.text, term.text)
        self.assertEqual(weighted.category, term.category)
        self.assertEqual(weighted.source, term.source)
    
    def test_term_with_source(self):
        """Test Term.with_source() method."""
        term = Term(text="test", category="technical", confidence=0.8, source="extract")
        
        new_source = term.with_source("rag")
        
        # Original should be unchanged
        self.assertEqual(term.source, "extract")
        
        # New should have different source
        self.assertEqual(new_source.source, "rag")
        self.assertEqual(new_source.text, term.text)
        self.assertEqual(new_source.confidence, term.confidence)


if __name__ == '__main__':
    unittest.main()
