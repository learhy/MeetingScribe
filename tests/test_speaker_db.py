"""Unit tests for the speaker database module."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

from speaker_db import SpeakerDatabase, EMBEDDING_DIM
from term_types import Term, SpeakerDBError


class TestSpeakerDatabaseBasics(unittest.TestCase):
    """Test basic database operations."""
    
    def setUp(self):
        """Create a temporary database for testing."""
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
    
    def tearDown(self):
        """Clean up temporary database."""
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        # Clean up WAL files if they exist
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_database_creation(self):
        """Test that database is created with correct schema."""
        self.assertTrue(os.path.exists(self.db_path))
        
        # Check tables exist
        cursor = self.db.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
        tables = {row['name'] for row in cursor.fetchall()}
        
        expected_tables = {
            'metadata', 'speakers', 'speaker_embeddings', 'prompt_cache',
            'speaker_terms', 'speaker_term_cooccurrence', 'pending_name_associations'
        }
        self.assertTrue(expected_tables.issubset(tables))
    
    def test_metadata_initialization(self):
        """Test that metadata is properly initialized."""
        schema_version = self.db._get_metadata('schema_version')
        embedding_model = self.db._get_metadata('embedding_model')
        embedding_dim = self.db._get_metadata('embedding_dim')
        
        self.assertEqual(schema_version, '1')
        self.assertEqual(embedding_model, 'speechbrain/spkrec-ecapa-voxceleb')
        self.assertEqual(embedding_dim, str(EMBEDDING_DIM))


class TestSpeakerManagement(unittest.TestCase):
    """Test speaker creation and management."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
        
        # Create a sample embedding
        np.random.seed(42)
        self.sample_embedding = np.random.randn(EMBEDDING_DIM).astype(np.float32)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_create_speaker(self):
        """Test creating a new speaker."""
        speaker_id = self.db.create_speaker(self.sample_embedding)
        
        self.assertIsNotNone(speaker_id)
        self.assertEqual(len(speaker_id), 36)  # UUID format
        
        speaker = self.db.get_speaker(speaker_id)
        self.assertIsNotNone(speaker)
        self.assertIsNone(speaker.name)
        self.assertEqual(speaker.embedding_count, 1)
    
    def test_create_speaker_with_name(self):
        """Test creating a speaker with a name."""
        speaker_id = self.db.create_speaker(self.sample_embedding, name="Alice")
        
        speaker = self.db.get_speaker(speaker_id)
        self.assertEqual(speaker.name, "Alice")
    
    def test_add_embedding(self):
        """Test adding embeddings to a speaker."""
        speaker_id = self.db.create_speaker(self.sample_embedding)
        
        # Add another embedding
        new_embedding = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        self.db.add_embedding(speaker_id, new_embedding, "test_audio.wav", quality_score=0.8)
        
        speaker = self.db.get_speaker(speaker_id)
        self.assertEqual(speaker.embedding_count, 2)
    
    def test_get_all_speakers(self):
        """Test retrieving all speakers."""
        # Create multiple speakers
        self.db.create_speaker(self.sample_embedding, name="Alice")
        self.db.create_speaker(np.random.randn(EMBEDDING_DIM).astype(np.float32), name="Bob")
        self.db.create_speaker(np.random.randn(EMBEDDING_DIM).astype(np.float32))  # Unnamed
        
        all_speakers = self.db.get_all_speakers()
        self.assertEqual(len(all_speakers), 3)
        
        named_only = self.db.get_all_speakers(include_unnamed=False)
        self.assertEqual(len(named_only), 2)
    
    def test_delete_speaker(self):
        """Test deleting a speaker."""
        speaker_id = self.db.create_speaker(self.sample_embedding, name="ToDelete")
        
        # Verify speaker exists
        self.assertIsNotNone(self.db.get_speaker(speaker_id))
        
        # Delete speaker
        self.db.delete_speaker(speaker_id)
        
        # Verify speaker is gone
        self.assertIsNone(self.db.get_speaker(speaker_id))
    
    def test_merge_speakers(self):
        """Test merging two speakers."""
        emb1 = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        emb2 = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        
        speaker1_id = self.db.create_speaker(emb1, name="Alice")
        speaker2_id = self.db.create_speaker(emb2)
        
        # Add some terms to speaker2
        self.db.update_speaker_terms(speaker2_id, [
            Term(text="project", category="technical", confidence=0.8, source="extract")
        ])
        
        # Merge speaker2 into speaker1
        self.db.merge_speakers(speaker1_id, speaker2_id)
        
        # speaker1 should have 2 embeddings now
        speaker = self.db.get_speaker(speaker1_id)
        self.assertEqual(speaker.embedding_count, 2)
        
        # speaker2 should be gone
        self.assertIsNone(self.db.get_speaker(speaker2_id))


class TestSpeakerMatching(unittest.TestCase):
    """Test speaker embedding matching."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
        
        np.random.seed(42)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_match_same_speaker(self):
        """Test that same speaker matches with high similarity."""
        # Create base embedding
        base_embedding = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        base_embedding = base_embedding / np.linalg.norm(base_embedding)
        
        speaker_id = self.db.create_speaker(base_embedding, name="TestUser")
        
        # Create very similar embedding (tiny perturbation)
        # Use smaller noise to ensure high cosine similarity
        similar_embedding = base_embedding + 0.01 * np.random.randn(EMBEDDING_DIM).astype(np.float32)
        similar_embedding = similar_embedding / np.linalg.norm(similar_embedding)
        
        matches = self.db.match_embedding(similar_embedding)
        
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].speaker_id, speaker_id)
        # With 0.01 noise scale, similarity should be very high
        self.assertGreater(matches[0].similarity, 0.95)
    
    def test_match_different_speakers(self):
        """Test matching returns multiple candidates for different speakers."""
        # Create two distinct speakers
        emb1 = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        emb1 = emb1 / np.linalg.norm(emb1)
        
        emb2 = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        emb2 = emb2 / np.linalg.norm(emb2)
        
        speaker1_id = self.db.create_speaker(emb1, name="Speaker1")
        speaker2_id = self.db.create_speaker(emb2, name="Speaker2")
        
        # Query with a new embedding similar to speaker1
        query = emb1 + 0.05 * np.random.randn(EMBEDDING_DIM).astype(np.float32)
        query = query / np.linalg.norm(query)
        
        matches = self.db.match_embedding(query, limit=2)
        
        self.assertEqual(len(matches), 2)
        self.assertEqual(matches[0].speaker_id, speaker1_id)  # Most similar
    
    def test_match_no_speakers(self):
        """Test matching with empty database returns empty list."""
        query = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        matches = self.db.match_embedding(query)
        
        self.assertEqual(len(matches), 0)


class TestPromptCache(unittest.TestCase):
    """Test prompt caching functionality."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_save_and_retrieve_prompt(self):
        """Test saving and retrieving a cached prompt."""
        known_ids = ["speaker-1", "speaker-2"]
        unknown_count = 1
        prompt = "Speakers: Alice, Bob"
        vocabulary = ["project", "meeting", "deadline"]
        
        self.db.save_prompt(known_ids, unknown_count, prompt, vocabulary, confidence=0.8)
        
        # Retrieve by full match
        cached = self.db.get_prompt_for_speakers(known_ids, unknown_count)
        
        self.assertIsNotNone(cached)
        self.assertEqual(cached.prompt_text, prompt)
        self.assertEqual(cached.vocabulary_terms, vocabulary)
        self.assertEqual(cached.base_confidence, 0.8)
    
    def test_partial_cache_lookup(self):
        """Test partial cache lookup ignores unknown count."""
        known_ids = ["speaker-1", "speaker-2"]
        
        # Save with unknown_count = 1
        self.db.save_prompt(known_ids, 1, "Test prompt", ["term"], confidence=0.8)
        
        # Full lookup with different unknown_count should fail
        full_match = self.db.get_prompt_for_speakers(known_ids, 2)
        self.assertIsNone(full_match)
        
        # Partial lookup should succeed
        partial_match = self.db.get_partial_prompt(known_ids)
        self.assertIsNotNone(partial_match)
    
    def test_cache_hit_tracking(self):
        """Test that cache hits are tracked."""
        known_ids = ["speaker-1"]
        self.db.save_prompt(known_ids, 0, "Prompt", [], confidence=0.9)
        
        cached = self.db.get_prompt_for_speakers(known_ids, 0)
        self.assertEqual(cached.use_count, 1)
        
        # Record a hit
        self.db.record_cache_hit(cached.cache_key)
        
        # Check use_count increased
        cached = self.db.get_prompt_for_speakers(known_ids, 0)
        self.assertEqual(cached.use_count, 2)


class TestSpeakerTerms(unittest.TestCase):
    """Test speaker term management."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
        
        np.random.seed(42)
        self.embedding = np.random.randn(EMBEDDING_DIM).astype(np.float32)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_update_and_get_terms(self):
        """Test updating and retrieving speaker terms."""
        speaker_id = self.db.create_speaker(self.embedding, name="TestUser")
        
        terms = [
            Term(text="project", category="technical", confidence=0.9, source="extract"),
            Term(text="Alice", category="person_name", confidence=0.8, source="extract"),
        ]
        
        self.db.update_speaker_terms(speaker_id, terms)
        
        retrieved = self.db.get_speaker_terms([speaker_id])
        self.assertEqual(len(retrieved), 2)
        
        # Check that terms are there
        term_texts = {t.text for t in retrieved}
        self.assertIn("project", term_texts)
        self.assertIn("Alice", term_texts)
    
    def test_term_frequency_increases(self):
        """Test that term frequency increases on repeated updates."""
        speaker_id = self.db.create_speaker(self.embedding)
        
        term = Term(text="recurring", category="technical", confidence=0.9, source="extract")
        
        # Update multiple times
        self.db.update_speaker_terms(speaker_id, [term])
        self.db.update_speaker_terms(speaker_id, [term])
        self.db.update_speaker_terms(speaker_id, [term])
        
        # Check frequency in database
        cursor = self.db.conn.execute(
            "SELECT frequency FROM speaker_terms WHERE speaker_id = ? AND term = ?",
            (speaker_id, "recurring")
        )
        row = cursor.fetchone()
        self.assertEqual(row['frequency'], 3)


class TestNameSuggestions(unittest.TestCase):
    """Test name suggestion workflow."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
        
        np.random.seed(42)
        self.embedding = np.random.randn(EMBEDDING_DIM).astype(np.float32)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        os.rmdir(self.temp_dir)
    
    def test_suggest_and_confirm_name(self):
        """Test suggesting and confirming a name."""
        speaker_id = self.db.create_speaker(self.embedding)
        
        # Initially unnamed
        speaker = self.db.get_speaker(speaker_id)
        self.assertIsNone(speaker.name)
        
        # Suggest a name
        self.db.suggest_name(
            speaker_id=speaker_id,
            suggested_name="Alice Smith",
            source="transcript",
            confidence=0.7,
            context="Hi, I'm Alice Smith from..."
        )
        
        # Check pending suggestions
        pending = self.db.get_pending_suggestions()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].suggested_name, "Alice Smith")
        
        # Confirm the suggestion
        self.db.confirm_name(pending[0].suggestion_id)
        
        # Check speaker now has name
        speaker = self.db.get_speaker(speaker_id)
        self.assertEqual(speaker.name, "Alice Smith")
        
        # Pending suggestions should be empty (or marked accepted)
        pending = self.db.get_pending_suggestions(status='pending')
        self.assertEqual(len(pending), 0)
    
    def test_reject_name(self):
        """Test rejecting a name suggestion."""
        speaker_id = self.db.create_speaker(self.embedding)
        
        self.db.suggest_name(
            speaker_id=speaker_id,
            suggested_name="Wrong Name",
            source="transcript",
            confidence=0.3
        )
        
        pending = self.db.get_pending_suggestions()
        self.db.reject_name(pending[0].suggestion_id)
        
        # Speaker should still be unnamed
        speaker = self.db.get_speaker(speaker_id)
        self.assertIsNone(speaker.name)
        
        # Check rejected status
        rejected = self.db.get_pending_suggestions(status='rejected')
        self.assertEqual(len(rejected), 1)


class TestDatabaseMaintenance(unittest.TestCase):
    """Test database maintenance operations."""
    
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.temp_dir, "test_speaker.db")
        self.db = SpeakerDatabase(self.db_path)
    
    def tearDown(self):
        self.db.close()
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        for ext in ['-wal', '-shm']:
            path = self.db_path + ext
            if os.path.exists(path):
                os.remove(path)
        # Clean up backups
        backup_dir = Path(self.temp_dir) / 'backups'
        if backup_dir.exists():
            for f in backup_dir.glob('*.db'):
                f.unlink()
            backup_dir.rmdir()
        os.rmdir(self.temp_dir)
    
    def test_check_integrity(self):
        """Test integrity check on a healthy database."""
        issues = self.db.check_integrity()
        self.assertEqual(len(issues), 0)
    
    def test_backup_creation(self):
        """Test backup creation."""
        backup_path = self.db.backup()
        
        self.assertTrue(os.path.exists(backup_path))
        self.assertIn("speaker_", backup_path)
        self.assertTrue(backup_path.endswith(".db"))
    
    def test_get_stats(self):
        """Test statistics retrieval."""
        # Add some data
        np.random.seed(42)
        emb = np.random.randn(EMBEDDING_DIM).astype(np.float32)
        speaker_id = self.db.create_speaker(emb, name="Alice")
        self.db.update_speaker_terms(speaker_id, [
            Term(text="test", category="other", confidence=1.0, source="extract")
        ])
        
        stats = self.db.get_stats()
        
        self.assertEqual(stats['speaker_count'], 1)
        self.assertEqual(stats['named_speaker_count'], 1)
        self.assertEqual(stats['embedding_count'], 1)
        self.assertGreater(stats['db_size_mb'], 0)


if __name__ == '__main__':
    unittest.main()
