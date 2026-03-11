"""SQLite-based speaker and prompt cache management.

This module provides persistent storage for speaker embeddings, vocabulary caches,
and name associations. It supports speaker matching via cosine similarity,
two-tier prompt caching, and data integrity management.
"""
import hashlib
import json
import logging
import shutil
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np

from term_types import (
    CachedPrompt,
    Contact,
    PendingNameSuggestion,
    Speaker,
    SpeakerDBError,
    SpeakerMatch,
    Term,
)

logger = logging.getLogger(__name__)

# Embedding model configuration
CURRENT_EMBEDDING_MODEL = "speechbrain/spkrec-ecapa-voxceleb"
EMBEDDING_DIM = 192

# Database schema version for migrations
SCHEMA_VERSION = 2

# SQL schema
SCHEMA_SQL = """
-- Database metadata for versioning and model tracking
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- Known speakers with their canonical embeddings
CREATE TABLE IF NOT EXISTS speakers (
    speaker_id TEXT PRIMARY KEY,
    name TEXT,
    name_confidence REAL,
    email TEXT,
    centroid_embedding BLOB,
    embedding_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Individual embedding samples for matching (with recency weighting)
CREATE TABLE IF NOT EXISTS speaker_embeddings (
    embedding_id TEXT PRIMARY KEY,
    speaker_id TEXT REFERENCES speakers(speaker_id) ON DELETE CASCADE,
    embedding BLOB,
    audio_source TEXT,
    quality_score REAL DEFAULT 1.0,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Two-tier prompt cache: full match and partial (known-speakers-only) match
CREATE TABLE IF NOT EXISTS prompt_cache (
    cache_key TEXT PRIMARY KEY,
    known_speakers_key TEXT,
    speaker_ids TEXT,
    unknown_speaker_count INTEGER,
    prompt_text TEXT,
    vocabulary_terms TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    use_count INTEGER DEFAULT 1,
    base_confidence REAL,
    last_quality_score REAL
);

-- Term associations with co-occurrence context and categorization
CREATE TABLE IF NOT EXISTS speaker_terms (
    speaker_id TEXT REFERENCES speakers(speaker_id) ON DELETE CASCADE,
    term TEXT,
    category TEXT DEFAULT 'other',
    frequency INTEGER DEFAULT 1,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (speaker_id, term)
);

-- Co-occurrence tracking: which terms appear with which speaker combinations
CREATE TABLE IF NOT EXISTS speaker_term_cooccurrence (
    speaker_id TEXT REFERENCES speakers(speaker_id) ON DELETE CASCADE,
    term TEXT,
    cooccurring_speaker_id TEXT REFERENCES speakers(speaker_id) ON DELETE CASCADE,
    frequency INTEGER DEFAULT 1,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (speaker_id, term, cooccurring_speaker_id)
);

-- Pending name suggestions (not auto-committed)
CREATE TABLE IF NOT EXISTS pending_name_associations (
    suggestion_id TEXT PRIMARY KEY,
    speaker_id TEXT REFERENCES speakers(speaker_id) ON DELETE CASCADE,
    suggested_name TEXT,
    source TEXT,
    confidence REAL,
    context TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT DEFAULT 'pending'
);

-- Contacts: people metadata linked to speakers via email
CREATE TABLE IF NOT EXISTS contacts (
    email TEXT PRIMARY KEY,
    display_name TEXT,
    preferred_name TEXT,
    pronunciation TEXT,
    aliases TEXT,
    role TEXT,
    team TEXT,
    source TEXT DEFAULT 'manual',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Required indexes for performance
CREATE INDEX IF NOT EXISTS idx_speaker_embeddings_speaker ON speaker_embeddings(speaker_id);
CREATE INDEX IF NOT EXISTS idx_speaker_embeddings_timestamp ON speaker_embeddings(timestamp);
CREATE INDEX IF NOT EXISTS idx_prompt_cache_last_used ON prompt_cache(last_used_at);
CREATE INDEX IF NOT EXISTS idx_prompt_cache_known_speakers ON prompt_cache(known_speakers_key);
CREATE INDEX IF NOT EXISTS idx_speakers_last_seen ON speakers(last_seen_at);
CREATE INDEX IF NOT EXISTS idx_pending_names_status ON pending_name_associations(status);
CREATE INDEX IF NOT EXISTS idx_speaker_terms_speaker ON speaker_terms(speaker_id);
CREATE INDEX IF NOT EXISTS idx_contacts_display_name ON contacts(display_name);
"""


class SpeakerDatabase:
    """SQLite database for speaker management and prompt caching."""
    
    def __init__(self, db_path: str):
        """Initialize database connection.
        
        Args:
            db_path: Path to SQLite database file. Created if it doesn't exist.
        """
        self.db_path = Path(db_path).expanduser()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn: Optional[sqlite3.Connection] = None
        self._connect()
        self._init_schema()
        self._validate_or_migrate()
    
    def _connect(self):
        """Establish database connection with optimal settings."""
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")  # Concurrent read/write
        self.conn.execute("PRAGMA busy_timeout=5000")  # 5s wait on locks
        self.conn.execute("PRAGMA foreign_keys=ON")
    
    def _init_schema(self):
        """Create tables if they don't exist."""
        self.conn.executescript(SCHEMA_SQL)
        self.conn.commit()
        
        # Set initial metadata if not present
        cursor = self.conn.execute("SELECT value FROM metadata WHERE key = 'schema_version'")
        if cursor.fetchone() is None:
            now = datetime.utcnow().isoformat()
            self.conn.executemany(
                "INSERT OR IGNORE INTO metadata (key, value) VALUES (?, ?)",
                [
                    ('schema_version', str(SCHEMA_VERSION)),
                    ('embedding_model', CURRENT_EMBEDDING_MODEL),
                    ('embedding_dim', str(EMBEDDING_DIM)),
                    ('created_at', now),
                ]
            )
            self.conn.commit()
    
    def _get_metadata(self, key: str) -> Optional[str]:
        """Get metadata value by key."""
        cursor = self.conn.execute("SELECT value FROM metadata WHERE key = ?", (key,))
        row = cursor.fetchone()
        return row['value'] if row else None
    
    def _set_metadata(self, key: str, value: str):
        """Set metadata value."""
        self.conn.execute(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
            (key, value)
        )
        self.conn.commit()
    
    def _validate_or_migrate(self):
        """Check embedding model compatibility and run schema migrations."""
        stored_model = self._get_metadata('embedding_model')
        stored_dim = self._get_metadata('embedding_dim')
        
        if stored_model and stored_model != CURRENT_EMBEDDING_MODEL:
            logger.warning(
                f"Embedding model mismatch: DB has {stored_model}, "
                f"current is {CURRENT_EMBEDDING_MODEL}. "
                f"Speaker matching may be unreliable. Consider resetting DB."
            )
        
        if stored_dim and int(stored_dim) != EMBEDDING_DIM:
            raise SpeakerDBError(
                f"Embedding dimension mismatch: DB has {stored_dim}, "
                f"current is {EMBEDDING_DIM}. Database reset required."
            )
        
        # Run schema migrations
        stored_version = int(self._get_metadata('schema_version') or '1')
        if stored_version < SCHEMA_VERSION:
            self._run_migrations(stored_version)
    
    def _run_migrations(self, from_version: int):
        """Run schema migrations from from_version to SCHEMA_VERSION."""
        logger.info(f"Migrating database schema from v{from_version} to v{SCHEMA_VERSION}")
        
        if from_version < 2:
            # v1 → v2: Add contacts table
            self.conn.executescript("""
                CREATE TABLE IF NOT EXISTS contacts (
                    email TEXT PRIMARY KEY,
                    display_name TEXT,
                    preferred_name TEXT,
                    pronunciation TEXT,
                    aliases TEXT,
                    role TEXT,
                    team TEXT,
                    source TEXT DEFAULT 'manual',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS idx_contacts_display_name ON contacts(display_name);
            """)
            logger.info("Migration v1→v2: Added contacts table")
        
        self._set_metadata('schema_version', str(SCHEMA_VERSION))
        self.conn.commit()
        logger.info(f"Database schema migrated to v{SCHEMA_VERSION}")
    
    def close(self):
        """Close database connection."""
        if self.conn:
            self.conn.close()
            self.conn = None
    
    # =========================================================================
    # Speaker Management
    # =========================================================================
    
    def create_speaker(self, centroid: np.ndarray, name: Optional[str] = None) -> str:
        """Create a new speaker entry.
        
        Args:
            centroid: Initial embedding centroid (192-dim float32)
            name: Optional speaker name (requires confirmation for auto-detected names)
        
        Returns:
            New speaker ID (UUID)
        """
        speaker_id = str(uuid.uuid4())
        now = datetime.utcnow().isoformat()
        
        self.conn.execute(
            """
            INSERT INTO speakers (speaker_id, name, centroid_embedding, embedding_count, created_at, last_seen_at)
            VALUES (?, ?, ?, 1, ?, ?)
            """,
            (speaker_id, name, centroid.astype(np.float32).tobytes(), now, now)
        )
        
        # Also store the initial embedding
        self.conn.execute(
            """
            INSERT INTO speaker_embeddings (embedding_id, speaker_id, embedding, audio_source, quality_score, timestamp)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (str(uuid.uuid4()), speaker_id, centroid.astype(np.float32).tobytes(), 'initial', 1.0, now)
        )
        
        self.conn.commit()
        return speaker_id
    
    def get_speaker(self, speaker_id: str) -> Optional[Speaker]:
        """Get speaker by ID."""
        cursor = self.conn.execute(
            "SELECT * FROM speakers WHERE speaker_id = ?",
            (speaker_id,)
        )
        row = cursor.fetchone()
        if not row:
            return None
        
        return Speaker(
            speaker_id=row['speaker_id'],
            name=row['name'],
            name_confidence=row['name_confidence'],
            email=row['email'],
            embedding_count=row['embedding_count'] or 0,
            created_at=row['created_at'],
            last_seen_at=row['last_seen_at']
        )
    
    def get_all_speakers(self, include_unnamed: bool = True) -> list[Speaker]:
        """Get all speakers."""
        if include_unnamed:
            cursor = self.conn.execute("SELECT * FROM speakers ORDER BY last_seen_at DESC")
        else:
            cursor = self.conn.execute("SELECT * FROM speakers WHERE name IS NOT NULL ORDER BY last_seen_at DESC")
        
        return [
            Speaker(
                speaker_id=row['speaker_id'],
                name=row['name'],
                name_confidence=row['name_confidence'],
                email=row['email'],
                embedding_count=row['embedding_count'] or 0,
                created_at=row['created_at'],
                last_seen_at=row['last_seen_at']
            )
            for row in cursor.fetchall()
        ]
    
    def add_embedding(
        self,
        speaker_id: str,
        embedding: np.ndarray,
        audio_source: str,
        quality_score: float = 1.0
    ):
        """Add an embedding sample and update centroid.
        
        Args:
            speaker_id: Speaker to add embedding to
            embedding: 192-dim float32 embedding
            audio_source: Path or identifier of source audio
            quality_score: Quality metric (0-1), lower for noisy/short segments
        """
        now = datetime.utcnow().isoformat()
        
        # Add embedding
        self.conn.execute(
            """
            INSERT INTO speaker_embeddings (embedding_id, speaker_id, embedding, audio_source, quality_score, timestamp)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (str(uuid.uuid4()), speaker_id, embedding.astype(np.float32).tobytes(), audio_source, quality_score, now)
        )
        
        # Update centroid with weighted average
        self._update_centroid(speaker_id)
        
        # Update last_seen_at
        self.conn.execute(
            "UPDATE speakers SET last_seen_at = ? WHERE speaker_id = ?",
            (now, speaker_id)
        )
        
        self.conn.commit()
    
    def _update_centroid(self, speaker_id: str):
        """Recalculate centroid as quality-weighted average of embeddings."""
        cursor = self.conn.execute(
            "SELECT embedding, quality_score FROM speaker_embeddings WHERE speaker_id = ?",
            (speaker_id,)
        )
        rows = cursor.fetchall()
        
        if not rows:
            return
        
        embeddings = []
        weights = []
        for row in rows:
            emb = np.frombuffer(row['embedding'], dtype=np.float32)
            embeddings.append(emb)
            weights.append(row['quality_score'] or 1.0)
        
        # Weighted average
        weights = np.array(weights)
        weights = weights / weights.sum()
        centroid = np.average(embeddings, axis=0, weights=weights)
        
        self.conn.execute(
            "UPDATE speakers SET centroid_embedding = ?, embedding_count = ? WHERE speaker_id = ?",
            (centroid.astype(np.float32).tobytes(), len(rows), speaker_id)
        )
    
    def _recalculate_all_centroids(self):
        """Recalculate centroids for all speakers (used after pruning)."""
        cursor = self.conn.execute("SELECT speaker_id FROM speakers")
        for row in cursor.fetchall():
            self._update_centroid(row['speaker_id'])
    
    def delete_speaker(self, speaker_id: str, cascade: bool = True):
        """Permanently delete a speaker and all associated data.
        
        Args:
            speaker_id: Speaker to delete
            cascade: If True, also delete embeddings, terms, suggestions
        """
        if cascade:
            self.conn.execute("DELETE FROM speaker_embeddings WHERE speaker_id = ?", (speaker_id,))
            self.conn.execute("DELETE FROM speaker_terms WHERE speaker_id = ?", (speaker_id,))
            self.conn.execute(
                "DELETE FROM speaker_term_cooccurrence WHERE speaker_id = ? OR cooccurring_speaker_id = ?",
                (speaker_id, speaker_id)
            )
            self.conn.execute("DELETE FROM pending_name_associations WHERE speaker_id = ?", (speaker_id,))
        
        self.conn.execute("DELETE FROM speakers WHERE speaker_id = ?", (speaker_id,))
        
        # Invalidate related cache entries
        self._invalidate_caches_for_speaker(speaker_id)
        
        self.conn.commit()
        logger.info(f"Deleted speaker {speaker_id} and all associated data")
    
    def _invalidate_caches_for_speaker(self, speaker_id: str):
        """Remove cache entries that reference a speaker."""
        # Find cache entries containing this speaker
        cursor = self.conn.execute("SELECT cache_key, speaker_ids FROM prompt_cache")
        for row in cursor.fetchall():
            speaker_ids = json.loads(row['speaker_ids'])
            if speaker_id in speaker_ids:
                self.conn.execute("DELETE FROM prompt_cache WHERE cache_key = ?", (row['cache_key'],))
    
    def merge_speakers(self, keep_id: str, merge_id: str):
        """Merge two speaker entries (combine embeddings, terms, etc.).
        
        Args:
            keep_id: Speaker ID to keep
            merge_id: Speaker ID to merge into keep_id (will be deleted)
        """
        # Move embeddings
        self.conn.execute(
            "UPDATE speaker_embeddings SET speaker_id = ? WHERE speaker_id = ?",
            (keep_id, merge_id)
        )
        
        # Merge terms (combine frequencies)
        cursor = self.conn.execute(
            "SELECT term, category, frequency, last_seen_at FROM speaker_terms WHERE speaker_id = ?",
            (merge_id,)
        )
        for row in cursor.fetchall():
            self.conn.execute(
                """
                INSERT INTO speaker_terms (speaker_id, term, category, frequency, last_seen_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(speaker_id, term) DO UPDATE SET
                    frequency = frequency + excluded.frequency,
                    last_seen_at = MAX(last_seen_at, excluded.last_seen_at)
                """,
                (keep_id, row['term'], row['category'], row['frequency'], row['last_seen_at'])
            )
        
        # Update co-occurrences
        self.conn.execute(
            "UPDATE speaker_term_cooccurrence SET speaker_id = ? WHERE speaker_id = ?",
            (keep_id, merge_id)
        )
        self.conn.execute(
            "UPDATE speaker_term_cooccurrence SET cooccurring_speaker_id = ? WHERE cooccurring_speaker_id = ?",
            (keep_id, merge_id)
        )
        
        # Move pending suggestions
        self.conn.execute(
            "UPDATE pending_name_associations SET speaker_id = ? WHERE speaker_id = ?",
            (keep_id, merge_id)
        )
        
        # Delete merged speaker
        self.conn.execute("DELETE FROM speaker_terms WHERE speaker_id = ?", (merge_id,))
        self.conn.execute("DELETE FROM speakers WHERE speaker_id = ?", (merge_id,))
        
        # Recalculate centroid
        self._update_centroid(keep_id)
        
        self.conn.commit()
        logger.info(f"Merged speaker {merge_id} into {keep_id}")
    
    def split_speaker(self, speaker_id: str, embedding_ids: list[str]) -> str:
        """Split incorrectly merged speaker.
        
        Args:
            speaker_id: Speaker to split
            embedding_ids: Embedding IDs to move to new speaker
        
        Returns:
            New speaker ID
        """
        if not embedding_ids:
            raise ValueError("Must specify embedding_ids to split")
        
        # Get first embedding for new centroid
        cursor = self.conn.execute(
            "SELECT embedding FROM speaker_embeddings WHERE embedding_id = ?",
            (embedding_ids[0],)
        )
        row = cursor.fetchone()
        if not row:
            raise ValueError(f"Embedding {embedding_ids[0]} not found")
        
        initial_emb = np.frombuffer(row['embedding'], dtype=np.float32)
        
        # Create new speaker
        new_id = self.create_speaker(initial_emb)
        
        # Move embeddings
        for emb_id in embedding_ids:
            self.conn.execute(
                "UPDATE speaker_embeddings SET speaker_id = ? WHERE embedding_id = ?",
                (new_id, emb_id)
            )
        
        # Recalculate both centroids
        self._update_centroid(speaker_id)
        self._update_centroid(new_id)
        
        self.conn.commit()
        return new_id
    
    # =========================================================================
    # Speaker Matching
    # =========================================================================
    
    def match_embedding(self, embedding: np.ndarray, limit: int = 3) -> list[SpeakerMatch]:
        """Match an embedding against known speakers.
        
        Uses cosine similarity against centroids with relative threshold.
        
        Args:
            embedding: 192-dim float32 embedding to match
            limit: Maximum number of matches to return
        
        Returns:
            Ranked list of SpeakerMatch results
        """
        cursor = self.conn.execute("SELECT speaker_id, centroid_embedding FROM speakers")
        
        candidates = []
        for row in cursor.fetchall():
            if row['centroid_embedding'] is None:
                continue
            
            centroid = np.frombuffer(row['centroid_embedding'], dtype=np.float32)
            similarity = self._cosine_similarity(embedding, centroid)
            candidates.append((row['speaker_id'], similarity))
        
        if not candidates:
            return []
        
        # Sort by similarity descending
        candidates.sort(key=lambda x: x[1], reverse=True)
        
        # Calculate confidence gaps
        results = []
        for i, (speaker_id, similarity) in enumerate(candidates[:limit]):
            second_best = candidates[i + 1][1] if i + 1 < len(candidates) else 0.0
            gap = similarity - second_best
            
            # Confident match: large gap OR very high absolute similarity
            is_confident = gap > 0.15 or similarity > 0.92
            
            results.append(SpeakerMatch(
                speaker_id=speaker_id,
                similarity=similarity,
                confidence_gap=gap,
                is_confident=is_confident
            ))
        
        return results
    
    def get_top_matches(self, embedding: np.ndarray, limit: int = 3) -> list[SpeakerMatch]:
        """Alias for match_embedding for interface compatibility."""
        return self.match_embedding(embedding, limit)
    
    @staticmethod
    def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
        """Compute cosine similarity between two vectors."""
        norm_a = np.linalg.norm(a)
        norm_b = np.linalg.norm(b)
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return float(np.dot(a, b) / (norm_a * norm_b))
    
    # =========================================================================
    # Prompt Cache
    # =========================================================================
    
    @staticmethod
    def _compute_full_cache_key(known_ids: list[str], unknown_count: int) -> str:
        """Compute cache key for full match."""
        sorted_ids = sorted(known_ids)
        data = json.dumps({'ids': sorted_ids, 'unknown': unknown_count})
        return hashlib.sha256(data.encode()).hexdigest()[:32]
    
    @staticmethod
    def _compute_partial_cache_key(known_ids: list[str]) -> str:
        """Compute cache key for partial match (ignores unknowns)."""
        sorted_ids = sorted(known_ids)
        data = json.dumps({'ids': sorted_ids})
        return hashlib.sha256(data.encode()).hexdigest()[:32]
    
    def get_prompt_for_speakers(
        self,
        known_ids: list[str],
        unknown_count: int
    ) -> Optional[CachedPrompt]:
        """Full cache lookup (exact match on known + unknown count)."""
        cache_key = self._compute_full_cache_key(known_ids, unknown_count)
        return self.get_prompt_by_key(cache_key)
    
    def get_partial_prompt(self, known_ids: list[str]) -> Optional[CachedPrompt]:
        """Partial cache lookup (match on known speakers only)."""
        partial_key = self._compute_partial_cache_key(known_ids)
        return self.get_prompt_by_partial_key(partial_key)
    
    def get_prompt_by_key(self, cache_key: str) -> Optional[CachedPrompt]:
        """Get cached prompt by full cache key."""
        cursor = self.conn.execute(
            "SELECT * FROM prompt_cache WHERE cache_key = ?",
            (cache_key,)
        )
        row = cursor.fetchone()
        if not row:
            return None
        
        return self._row_to_cached_prompt(row)
    
    def get_prompt_by_partial_key(self, partial_key: str) -> Optional[CachedPrompt]:
        """Get cached prompt by partial (known speakers) key."""
        cursor = self.conn.execute(
            "SELECT * FROM prompt_cache WHERE known_speakers_key = ?",
            (partial_key,)
        )
        row = cursor.fetchone()
        if not row:
            return None
        
        return self._row_to_cached_prompt(row)
    
    def _row_to_cached_prompt(self, row: sqlite3.Row) -> CachedPrompt:
        """Convert database row to CachedPrompt."""
        vocab_terms = json.loads(row['vocabulary_terms']) if row['vocabulary_terms'] else []
        speaker_ids = json.loads(row['speaker_ids']) if row['speaker_ids'] else []
        
        effective_confidence = self._compute_effective_confidence(
            row['base_confidence'],
            row['last_used_at'],
            row['last_quality_score']
        )
        
        return CachedPrompt(
            cache_key=row['cache_key'],
            known_speakers_key=row['known_speakers_key'],
            speaker_ids=speaker_ids,
            unknown_speaker_count=row['unknown_speaker_count'],
            prompt_text=row['prompt_text'],
            vocabulary_terms=vocab_terms,
            created_at=row['created_at'],
            last_used_at=row['last_used_at'],
            use_count=row['use_count'],
            base_confidence=row['base_confidence'],
            last_quality_score=row['last_quality_score'],
            effective_confidence=effective_confidence
        )
    
    def _compute_effective_confidence(
        self,
        base_confidence: float,
        last_used_at: str,
        last_quality_score: Optional[float]
    ) -> float:
        """Compute confidence using evidence-based decay."""
        try:
            last_used = datetime.fromisoformat(last_used_at)
            days_since_use = (datetime.utcnow() - last_used).days
        except (ValueError, TypeError):
            days_since_use = 0
        
        # Time decay (slow)
        time_factor = 0.995 ** days_since_use  # ~83% after 100 days
        
        # Quality decay (fast if cache produced poor results)
        if last_quality_score is not None:
            quality_factor = 0.5 + (0.5 * last_quality_score)
        else:
            quality_factor = 1.0
        
        return base_confidence * time_factor * quality_factor
    
    def save_prompt(
        self,
        known_ids: list[str],
        unknown_count: int,
        prompt: str,
        vocabulary: list[str],
        confidence: float
    ):
        """Save prompt to cache with both full and partial keys."""
        cache_key = self._compute_full_cache_key(known_ids, unknown_count)
        partial_key = self._compute_partial_cache_key(known_ids)
        now = datetime.utcnow().isoformat()
        
        self.conn.execute(
            """
            INSERT OR REPLACE INTO prompt_cache 
            (cache_key, known_speakers_key, speaker_ids, unknown_speaker_count, 
             prompt_text, vocabulary_terms, created_at, last_used_at, use_count, base_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            """,
            (
                cache_key, partial_key, json.dumps(known_ids), unknown_count,
                prompt, json.dumps(vocabulary), now, now, confidence
            )
        )
        self.conn.commit()
    
    def record_cache_hit(self, cache_key: str):
        """Update cache entry on hit (increment use_count, update last_used_at)."""
        now = datetime.utcnow().isoformat()
        self.conn.execute(
            """
            UPDATE prompt_cache 
            SET use_count = use_count + 1, last_used_at = ?
            WHERE cache_key = ?
            """,
            (now, cache_key)
        )
        self.conn.commit()
    
    def update_cache_quality(self, cache_key: str, quality_score: float):
        """Update quality score after transcription."""
        self.conn.execute(
            "UPDATE prompt_cache SET last_quality_score = ? WHERE cache_key = ?",
            (quality_score, cache_key)
        )
        self.conn.commit()
    
    # =========================================================================
    # Speaker Terms
    # =========================================================================
    
    def update_speaker_terms(
        self,
        speaker_id: str,
        terms: list[Term],
        cooccurring_speaker_ids: Optional[list[str]] = None
    ):
        """Update vocabulary terms associated with a speaker.
        
        Args:
            speaker_id: Speaker to update
            terms: List of Term objects to associate
            cooccurring_speaker_ids: Other speakers in same meeting (for co-occurrence)
        """
        now = datetime.utcnow().isoformat()
        
        for term in terms:
            # Update speaker_terms
            self.conn.execute(
                """
                INSERT INTO speaker_terms (speaker_id, term, category, frequency, last_seen_at)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(speaker_id, term) DO UPDATE SET
                    frequency = frequency + 1,
                    last_seen_at = excluded.last_seen_at
                """,
                (speaker_id, term.text, term.category, now)
            )
            
            # Update co-occurrences
            if cooccurring_speaker_ids:
                for cooccur_id in cooccurring_speaker_ids:
                    if cooccur_id != speaker_id:
                        self.conn.execute(
                            """
                            INSERT INTO speaker_term_cooccurrence 
                            (speaker_id, term, cooccurring_speaker_id, frequency, last_seen_at)
                            VALUES (?, ?, ?, 1, ?)
                            ON CONFLICT(speaker_id, term, cooccurring_speaker_id) DO UPDATE SET
                                frequency = frequency + 1,
                                last_seen_at = excluded.last_seen_at
                            """,
                            (speaker_id, term.text, cooccur_id, now)
                        )
        
        self.conn.commit()
    
    def get_speaker_terms(
        self,
        speaker_ids: list[str],
        cooccurring_ids: Optional[list[str]] = None,
        limit: int = 100
    ) -> list[Term]:
        """Get vocabulary terms for speakers, weighted by relevance.
        
        Args:
            speaker_ids: Speaker IDs to get terms for
            cooccurring_ids: Boost terms that co-occur with these speakers
            limit: Maximum terms to return
        
        Returns:
            List of Term objects sorted by weighted relevance
        """
        if not speaker_ids:
            return []
        
        placeholders = ','.join('?' * len(speaker_ids))
        
        # Get base terms with frequency
        cursor = self.conn.execute(
            f"""
            SELECT term, category, SUM(frequency) as total_freq
            FROM speaker_terms
            WHERE speaker_id IN ({placeholders})
            GROUP BY term
            ORDER BY total_freq DESC
            LIMIT ?
            """,
            (*speaker_ids, limit * 2)  # Get extra for co-occurrence filtering
        )
        
        base_terms = {row['term']: (row['category'], row['total_freq']) for row in cursor.fetchall()}
        
        # Boost by co-occurrence if provided
        cooccur_boost = {}
        if cooccurring_ids:
            cooccur_placeholders = ','.join('?' * len(cooccurring_ids))
            cursor = self.conn.execute(
                f"""
                SELECT term, SUM(frequency) as cooccur_freq
                FROM speaker_term_cooccurrence
                WHERE speaker_id IN ({placeholders})
                  AND cooccurring_speaker_id IN ({cooccur_placeholders})
                GROUP BY term
                """,
                (*speaker_ids, *cooccurring_ids)
            )
            cooccur_boost = {row['term']: row['cooccur_freq'] for row in cursor.fetchall()}
        
        # Compute weighted scores
        results = []
        for term_text, (category, freq) in base_terms.items():
            # Base confidence from frequency (log scale)
            base_conf = min(1.0, 0.3 + 0.1 * np.log1p(freq))
            
            # Boost for co-occurrence
            cooccur_freq = cooccur_boost.get(term_text, 0)
            cooccur_factor = 1.0 + 0.5 * min(1.0, cooccur_freq / 10)
            
            confidence = min(1.0, base_conf * cooccur_factor)
            
            results.append(Term(
                text=term_text,
                category=category,
                confidence=confidence,
                source='speaker_history'
            ))
        
        # Sort by confidence and limit
        results.sort(key=lambda t: t.confidence, reverse=True)
        return results[:limit]
    
    # =========================================================================
    # Name Suggestions
    # =========================================================================
    
    def suggest_name(
        self,
        speaker_id: str,
        suggested_name: str,
        source: str,
        confidence: float,
        context: Optional[str] = None
    ):
        """Queue a name suggestion (requires explicit confirmation).
        
        Args:
            speaker_id: Speaker to name
            suggested_name: Proposed name
            source: How name was detected ('transcript', 'calendar', 'manual')
            confidence: Confidence in suggestion (0-1)
            context: Snippet showing where name was found
        """
        suggestion_id = str(uuid.uuid4())
        now = datetime.utcnow().isoformat()
        
        self.conn.execute(
            """
            INSERT INTO pending_name_associations 
            (suggestion_id, speaker_id, suggested_name, source, confidence, context, created_at, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
            """,
            (suggestion_id, speaker_id, suggested_name, source, confidence, context, now)
        )
        self.conn.commit()
    
    def get_pending_suggestions(self, status: str = 'pending') -> list[PendingNameSuggestion]:
        """Get pending name suggestions."""
        cursor = self.conn.execute(
            "SELECT * FROM pending_name_associations WHERE status = ? ORDER BY created_at DESC",
            (status,)
        )
        
        return [
            PendingNameSuggestion(
                suggestion_id=row['suggestion_id'],
                speaker_id=row['speaker_id'],
                suggested_name=row['suggested_name'],
                source=row['source'],
                confidence=row['confidence'],
                context=row['context'],
                created_at=row['created_at'],
                status=row['status']
            )
            for row in cursor.fetchall()
        ]
    
    def confirm_name(self, suggestion_id: str):
        """Accept a name suggestion."""
        cursor = self.conn.execute(
            "SELECT speaker_id, suggested_name, confidence FROM pending_name_associations WHERE suggestion_id = ?",
            (suggestion_id,)
        )
        row = cursor.fetchone()
        if not row:
            raise ValueError(f"Suggestion {suggestion_id} not found")
        
        # Update speaker name
        self.conn.execute(
            "UPDATE speakers SET name = ?, name_confidence = ? WHERE speaker_id = ?",
            (row['suggested_name'], row['confidence'], row['speaker_id'])
        )
        
        # Update suggestion status
        self.conn.execute(
            "UPDATE pending_name_associations SET status = 'accepted' WHERE suggestion_id = ?",
            (suggestion_id,)
        )
        
        self.conn.commit()
    
    def reject_name(self, suggestion_id: str):
        """Reject a name suggestion."""
        cursor = self.conn.execute(
            "SELECT suggestion_id FROM pending_name_associations WHERE suggestion_id = ?",
            (suggestion_id,)
        )
        if not cursor.fetchone():
            raise ValueError(f"Suggestion {suggestion_id} not found")
        
        self.conn.execute(
            "UPDATE pending_name_associations SET status = 'rejected' WHERE suggestion_id = ?",
            (suggestion_id,)
        )
        self.conn.commit()
    
    def set_speaker_name(
        self,
        speaker_id: str,
        name: str,
        confidence: float = 1.0,
        source: str = 'manual'
    ):
        """Manually set a speaker's name.
        
        Args:
            speaker_id: Speaker to rename
            name: New name to set
            confidence: Confidence in the name (default 1.0 for manual)
            source: Source of the name ('manual', 'calendar', etc.)
        
        Raises:
            ValueError: If speaker not found
        """
        # Verify speaker exists
        cursor = self.conn.execute(
            "SELECT speaker_id FROM speakers WHERE speaker_id = ?",
            (speaker_id,)
        )
        if not cursor.fetchone():
            raise ValueError(f"Speaker {speaker_id} not found")
        
        self.conn.execute(
            "UPDATE speakers SET name = ?, name_confidence = ? WHERE speaker_id = ?",
            (name, confidence, speaker_id)
        )
        self.conn.commit()
        logger.info(f"Set name for speaker {speaker_id}: {name} (source={source}, confidence={confidence})")
    
    def associate_email(self, speaker_id: str, email: str):
        """Associate an email address with a speaker.
        
        Args:
            speaker_id: Speaker to associate email with
            email: Email address to associate
        
        Raises:
            ValueError: If speaker not found
        """
        cursor = self.conn.execute(
            "SELECT speaker_id FROM speakers WHERE speaker_id = ?",
            (speaker_id,)
        )
        if not cursor.fetchone():
            raise ValueError(f"Speaker {speaker_id} not found")
        
        self.conn.execute(
            "UPDATE speakers SET email = ? WHERE speaker_id = ?",
            (email, speaker_id)
        )
        self.conn.commit()
        logger.info(f"Associated email {email} with speaker {speaker_id}")
    
    def get_embeddings(self, speaker_id: str) -> list[dict]:
        """Get all embeddings for a speaker.
        
        Args:
            speaker_id: Speaker to get embeddings for
        
        Returns:
            List of embedding dicts with embedding_id, audio_source, quality_score, timestamp
        """
        cursor = self.conn.execute(
            """
            SELECT embedding_id, audio_source, quality_score, timestamp
            FROM speaker_embeddings
            WHERE speaker_id = ?
            ORDER BY timestamp DESC
            """,
            (speaker_id,)
        )
        return [
            {
                'embedding_id': row['embedding_id'],
                'audio_source': row['audio_source'],
                'quality_score': row['quality_score'],
                'created_at': row['timestamp']
            }
            for row in cursor.fetchall()
        ]
    
    # =========================================================================
    # Contacts
    # =========================================================================
    
    def upsert_contact(
        self,
        email: str,
        display_name: Optional[str] = None,
        preferred_name: Optional[str] = None,
        pronunciation: Optional[str] = None,
        aliases: Optional[list[str]] = None,
        role: Optional[str] = None,
        team: Optional[str] = None,
        source: str = 'manual'
    ):
        """Insert or update a contact.
        
        Calendar-sourced contacts never overwrite manual entries.
        
        Args:
            email: Contact email (primary key)
            display_name: Full name
            preferred_name: First name or nickname
            pronunciation: Phonetic guide
            aliases: List of misspellings/variations
            role: Job title
            team: Department
            source: 'manual', 'calendar', or 'auto'
        """
        now = datetime.utcnow().isoformat()
        aliases_json = json.dumps(aliases) if aliases else None
        
        # Check if contact exists and its source
        cursor = self.conn.execute(
            "SELECT source FROM contacts WHERE email = ?",
            (email,)
        )
        existing = cursor.fetchone()
        
        if existing:
            # Never overwrite manual entries with calendar data
            if existing['source'] == 'manual' and source == 'calendar':
                logger.debug(f"Skipping calendar update for manual contact {email}")
                return
            
            # Update existing contact (only non-None fields)
            updates = []
            params = []
            if display_name is not None:
                updates.append("display_name = ?")
                params.append(display_name)
            if preferred_name is not None:
                updates.append("preferred_name = ?")
                params.append(preferred_name)
            if pronunciation is not None:
                updates.append("pronunciation = ?")
                params.append(pronunciation)
            if aliases_json is not None:
                updates.append("aliases = ?")
                params.append(aliases_json)
            if role is not None:
                updates.append("role = ?")
                params.append(role)
            if team is not None:
                updates.append("team = ?")
                params.append(team)
            
            updates.append("updated_at = ?")
            params.append(now)
            params.append(email)
            
            if updates:
                self.conn.execute(
                    f"UPDATE contacts SET {', '.join(updates)} WHERE email = ?",
                    params
                )
        else:
            # Insert new contact
            self.conn.execute(
                """
                INSERT INTO contacts (email, display_name, preferred_name, pronunciation,
                    aliases, role, team, source, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (email, display_name, preferred_name, pronunciation,
                 aliases_json, role, team, source, now, now)
            )
        
        self.conn.commit()
    
    def get_contact(self, email: str) -> Optional[Contact]:
        """Get a contact by email."""
        cursor = self.conn.execute(
            "SELECT * FROM contacts WHERE email = ?",
            (email,)
        )
        row = cursor.fetchone()
        if not row:
            return None
        return self._row_to_contact(row)
    
    def get_all_contacts(self) -> list[Contact]:
        """Get all contacts."""
        cursor = self.conn.execute(
            "SELECT * FROM contacts ORDER BY display_name, email"
        )
        return [self._row_to_contact(row) for row in cursor.fetchall()]
    
    def delete_contact(self, email: str):
        """Delete a contact by email."""
        cursor = self.conn.execute(
            "SELECT email FROM contacts WHERE email = ?",
            (email,)
        )
        if not cursor.fetchone():
            raise ValueError(f"Contact {email} not found")
        
        self.conn.execute("DELETE FROM contacts WHERE email = ?", (email,))
        self.conn.commit()
    
    def get_contacts_by_emails(self, emails: list[str]) -> list[Contact]:
        """Get contacts for a list of emails (for meeting participant lookup)."""
        if not emails:
            return []
        placeholders = ','.join('?' * len(emails))
        cursor = self.conn.execute(
            f"SELECT * FROM contacts WHERE email IN ({placeholders})",
            emails
        )
        return [self._row_to_contact(row) for row in cursor.fetchall()]
    
    def _row_to_contact(self, row: sqlite3.Row) -> Contact:
        """Convert database row to Contact."""
        aliases_raw = row['aliases']
        aliases = json.loads(aliases_raw) if aliases_raw else None
        return Contact(
            email=row['email'],
            display_name=row['display_name'],
            preferred_name=row['preferred_name'],
            pronunciation=row['pronunciation'],
            aliases=aliases,
            role=row['role'],
            team=row['team'],
            source=row['source'],
            created_at=row['created_at'],
            updated_at=row['updated_at']
        )
    
    # =========================================================================
    # Statistics and Maintenance
    # =========================================================================
    
    def get_stats(self) -> dict:
        """Get database statistics."""
        stats = {}
        
        # Speaker counts
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM speakers")
        stats['speaker_count'] = cursor.fetchone()['cnt']
        
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM speakers WHERE name IS NOT NULL")
        stats['named_speaker_count'] = cursor.fetchone()['cnt']
        
        # Embedding count
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM speaker_embeddings")
        stats['embedding_count'] = cursor.fetchone()['cnt']
        
        # Cache count
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM prompt_cache")
        stats['cache_count'] = cursor.fetchone()['cnt']
        
        # Term count
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM speaker_terms")
        stats['term_count'] = cursor.fetchone()['cnt']
        
        # Pending suggestions
        cursor = self.conn.execute("SELECT COUNT(*) as cnt FROM pending_name_associations WHERE status = 'pending'")
        stats['pending_count'] = cursor.fetchone()['cnt']
        
        # Database size
        stats['db_size_mb'] = self.db_path.stat().st_size / (1024 * 1024)
        
        return stats
    
    def check_integrity(self) -> list[str]:
        """Run integrity checks, return list of issues."""
        issues = []
        
        # Check SQLite integrity
        result = self.conn.execute("PRAGMA integrity_check").fetchone()
        if result[0] != 'ok':
            issues.append(f"SQLite integrity check failed: {result[0]}")
        
        # Check for orphaned embeddings
        orphans = self.conn.execute("""
            SELECT COUNT(*) FROM speaker_embeddings 
            WHERE speaker_id NOT IN (SELECT speaker_id FROM speakers)
        """).fetchone()[0]
        if orphans > 0:
            issues.append(f"Found {orphans} orphaned embeddings")
        
        # Check for centroid drift (embedding_count doesn't match actual count)
        mismatches = self.conn.execute("""
            SELECT s.speaker_id, s.embedding_count, COUNT(e.embedding_id) as actual
            FROM speakers s
            LEFT JOIN speaker_embeddings e ON s.speaker_id = e.speaker_id
            GROUP BY s.speaker_id
            HAVING COALESCE(s.embedding_count, 0) != COUNT(e.embedding_id)
        """).fetchall()
        for row in mismatches:
            issues.append(f"Speaker {row['speaker_id']}: count mismatch (stored={row['embedding_count']}, actual={row['actual']})")
        
        return issues
    
    def backup(self) -> str:
        """Create timestamped backup, return backup path."""
        backup_dir = self.db_path.parent / 'backups'
        backup_dir.mkdir(exist_ok=True)
        
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        backup_path = backup_dir / f'speaker_{timestamp}.db'
        
        # Use SQLite backup API for safe copy
        backup_conn = sqlite3.connect(str(backup_path))
        self.conn.backup(backup_conn)
        backup_conn.close()
        
        # Keep only last 5 backups (race-safe)
        backups = sorted(backup_dir.glob('speaker_*.db'))
        for old_backup in backups[:-5]:
            try:
                old_backup.unlink()
            except FileNotFoundError:
                pass  # Already deleted by another process
        
        return str(backup_path)
    
    def recover_from_backup(self, backup_path: str):
        """Restore from backup after corruption detected."""
        self.close()
        shutil.copy(backup_path, self.db_path)
        self._connect()
        logger.info(f"Recovered database from {backup_path}")
    
    def export_speaker_data(self, speaker_id: str) -> dict:
        """Export all data associated with a speaker (GDPR data portability)."""
        speaker = self.get_speaker(speaker_id)
        if not speaker:
            raise ValueError(f"Speaker {speaker_id} not found")
        
        # Get embeddings
        cursor = self.conn.execute(
            "SELECT embedding_id, audio_source, quality_score, timestamp FROM speaker_embeddings WHERE speaker_id = ?",
            (speaker_id,)
        )
        embeddings = [dict(row) for row in cursor.fetchall()]
        
        # Get terms
        terms = self.get_speaker_terms([speaker_id])
        
        # Get pending names
        cursor = self.conn.execute(
            "SELECT * FROM pending_name_associations WHERE speaker_id = ?",
            (speaker_id,)
        )
        pending = [dict(row) for row in cursor.fetchall()]
        
        return {
            'speaker': {
                'speaker_id': speaker.speaker_id,
                'name': speaker.name,
                'name_confidence': speaker.name_confidence,
                'email': speaker.email,
                'embedding_count': speaker.embedding_count,
                'created_at': speaker.created_at,
                'last_seen_at': speaker.last_seen_at,
            },
            'embeddings': embeddings,
            'terms': [{'text': t.text, 'category': t.category, 'confidence': t.confidence} for t in terms],
            'pending_names': pending
        }
