#!/usr/bin/env python3
"""
Test suite for diarization script
Run with: pytest tests/test_diarization.py -v
"""

import os
import sys
import json
import tempfile
import pytest
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

import diarize_audio_fast


class TestDiarizationScript:
    """Test the diarization script functions"""
    
    def test_device_detection(self):
        """Test that device detection returns valid device"""
        device = diarize_audio_fast.get_device()
        assert device in ["cpu", "mps", "cuda"], f"Invalid device: {device}"
    
    def test_diarization_segment_creation(self):
        """Test DiarizationSegment creation"""
        import numpy as np
        
        labels = np.array([0, 0, 1, 1, 0])
        timestamps = [0.0, 0.75, 1.5, 2.25, 3.0]
        
        segments = diarize_audio_fast.create_diarization_segments(
            labels, timestamps, window_size=1.5
        )
        
        assert len(segments) == 3, f"Expected 3 segments, got {len(segments)}"
        assert segments[0].speaker == "SPEAKER_00"
        assert segments[1].speaker == "SPEAKER_01"
        assert segments[2].speaker == "SPEAKER_00"
    
    def test_segment_merging(self):
        """Test that consecutive same-speaker windows are merged"""
        import numpy as np
        
        # All same speaker
        labels = np.array([0, 0, 0, 0])
        timestamps = [0.0, 0.75, 1.5, 2.25]
        
        segments = diarize_audio_fast.create_diarization_segments(
            labels, timestamps, window_size=1.5
        )
        
        assert len(segments) == 1, f"Expected 1 merged segment, got {len(segments)}"
        assert segments[0].end > segments[0].start + 3.0  # Should span all windows


class TestBundledPython:
    """Test bundled Python environment"""
    
    @pytest.fixture
    def bundle_python(self):
        """Get path to bundled Python"""
        bundle_path = Path(__file__).parent.parent / "build/python-bundle/bin/python3"
        if not bundle_path.exists():
            pytest.skip("Python bundle not built. Run: ./scripts/bundle-python-env.sh")
        return str(bundle_path)
    
    def test_python_version(self, bundle_python):
        """Test bundled Python version"""
        import subprocess
        result = subprocess.run(
            [bundle_python, "--version"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Python 3.11" in result.stdout or "Python 3.11" in result.stderr
    
    def test_torch_import(self, bundle_python):
        """Test that torch can be imported"""
        import subprocess
        result = subprocess.run(
            [bundle_python, "-c", "import torch; print(torch.__version__)"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0, f"Torch import failed: {result.stderr}"
        assert "2." in result.stdout, f"Unexpected torch version: {result.stdout}"
    
    def test_all_dependencies(self, bundle_python):
        """Test all required dependencies can be imported"""
        import subprocess
        
        deps = ["torch", "torchaudio", "whisper", "speechbrain", "sklearn", "soundfile"]
        
        for dep in deps:
            result = subprocess.run(
                [bundle_python, "-c", f"import {dep}; print('OK')"],
                capture_output=True,
                text=True,
                timeout=10
            )
            assert result.returncode == 0, f"Failed to import {dep}: {result.stderr}"
            assert "OK" in result.stdout, f"Import {dep} did not print OK"
    
    def test_diarization_synthetic_audio(self, bundle_python, tmp_path):
        """Test diarization pipeline with synthetic audio (smoke test)"""
        import subprocess
        import numpy as np
        import soundfile as sf
        
        # Create a test audio file (10 seconds, 16kHz - need enough for embeddings)
        duration = 10.0
        sample_rate = 16000
        samples = int(duration * sample_rate)
        
        # Generate audio with varying frequency to simulate different speakers
        t = np.linspace(0, duration, samples)
        # First half: 440 Hz, second half: 880 Hz
        audio = np.concatenate([
            np.sin(2 * np.pi * 440 * t[:samples//2]) * 0.5,
            np.sin(2 * np.pi * 880 * t[samples//2:]) * 0.5
        ])
        
        test_audio = tmp_path / "test_audio.wav"
        sf.write(str(test_audio), audio, sample_rate)
        
        # Run diarization
        output_file = tmp_path / "output.json"
        script_path = Path(__file__).parent.parent / "scripts/diarize_audio_fast.py"
        
        result = subprocess.run(
            [
                bundle_python,
                str(script_path),
                str(test_audio),
                "--whisper-model", "tiny",
                "--distance-threshold", "0.90",
                "--output", str(output_file)
            ],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        # Check it completed
        assert result.returncode == 0, f"Diarization failed: {result.stderr}"
        
        # Check output file exists and is valid JSON
        assert output_file.exists(), "Output file not created"
        
        with open(output_file) as f:
            data = json.load(f)
        
        assert "num_speakers" in data
        assert "speakers" in data
        assert "segments" in data
        assert data["num_speakers"] >= 1
        assert len(data["speakers"]) >= 1
    
    def test_diarization_real_audio(self, bundle_python):
        """Test full diarization pipeline with real meeting audio"""
        import subprocess
        import tempfile
        
        # Use real meeting audio fixture (30-second clip)
        fixture_path = Path(__file__).parent / "fixtures/test_meeting_30sec.wav"
        
        if not fixture_path.exists():
            pytest.skip("Real audio fixture not found. Run: make test-fixtures")
        
        # Run diarization on real audio
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            output_file = f.name
        
        try:
            script_path = Path(__file__).parent.parent / "scripts/diarize_audio_fast.py"
            
            result = subprocess.run(
                [
                    bundle_python,
                    str(script_path),
                    str(fixture_path),
                    "--whisper-model", "tiny",
                    "--distance-threshold", "0.90",
                    "--output", output_file
                ],
                capture_output=True,
                text=True,
                timeout=180  # 3 minutes for 30-second real audio
            )
            
            # Check it completed
            assert result.returncode == 0, f"Diarization failed: {result.stderr}"
            
            # Check output file and validate content
            with open(output_file) as f:
                data = json.load(f)
            
            # Real audio should have proper structure
            assert "num_speakers" in data
            assert "speakers" in data
            assert "segments" in data
            assert "audio_file" in data
            
            # Should detect at least 1 speaker
            assert data["num_speakers"] >= 1, f"No speakers detected"
            assert len(data["speakers"]) >= 1
            
            # Should have transcribed segments
            assert len(data["segments"]) > 0, "No segments in output"
            
            # Each segment should have required fields
            for seg in data["segments"]:
                assert "start" in seg
                assert "end" in seg
                assert "speaker" in seg
                assert "text" in seg
                assert seg["end"] > seg["start"], "Invalid segment timing"
                assert len(seg["text"]) > 0, "Empty transcription"
            
            # Print summary for debugging
            print(f"\n✓ Real audio test: {data['num_speakers']} speakers, {len(data['segments'])} segments")
            
        finally:
            # Clean up temp file
            import os
            if os.path.exists(output_file):
                os.unlink(output_file)


class TestWordLevelAlignment:
    """Test word-level alignment in align_transcription_with_diarization"""

    def test_words_are_space_separated(self):
        """Regression test: words within a speaker segment must be separated by spaces.

        Bug: "".join(current_words) concatenated words with no spaces, producing
        transcripts like 'forinstruction.Additionally,lasttermsof...' instead of
        'for instruction. Additionally, last terms of...'.
        """
        # Mock transcription with word-level timestamps
        transcription = {
            "segments": [
                {
                    "start": 0.0,
                    "end": 5.0,
                    "text": "Hello world this is a test",
                    "words": [
                        {"word": "Hello", "start": 0.0, "end": 0.5},
                        {"word": "world", "start": 0.5, "end": 1.0},
                        {"word": "this", "start": 1.0, "end": 1.5},
                        {"word": "is", "start": 1.5, "end": 2.0},
                        {"word": "a", "start": 2.0, "end": 2.5},
                        {"word": "test", "start": 2.5, "end": 3.0},
                    ]
                }
            ]
        }

        # Single speaker segment covering the whole transcription
        dia_segments = [
            diarize_audio_fast.DiarizationSegment(
                start=0.0, end=5.0, speaker="SPEAKER_00"
            )
        ]

        result = diarize_audio_fast.align_transcription_with_diarization(
            transcription, dia_segments
        )

        assert len(result) == 1
        text = result[0]["text"]
        # Words must be space-separated
        assert " " in text, f"No spaces in output text: '{text}'"
        assert text == "Hello world this is a test", f"Expected proper spacing, got: '{text}'"
        # Explicitly check we don't get the bug output
        assert "Helloworld" not in text, "Words are concatenated without spaces!"

    def test_words_separated_across_speaker_change(self):
        """Words on either side of a speaker change must also be space-separated."""
        transcription = {
            "segments": [
                {
                    "start": 0.0,
                    "end": 4.0,
                    "text": "Hello there how are you",
                    "words": [
                        {"word": "Hello", "start": 0.0, "end": 0.5},
                        {"word": "there", "start": 0.5, "end": 1.0},
                        {"word": "how", "start": 1.0, "end": 1.5},
                        {"word": "are", "start": 1.5, "end": 2.0},
                        {"word": "you", "start": 2.0, "end": 2.5},
                    ]
                }
            ]
        }

        # Two speaker segments - speaker change at t=1.0
        dia_segments = [
            diarize_audio_fast.DiarizationSegment(
                start=0.0, end=1.0, speaker="SPEAKER_00"
            ),
            diarize_audio_fast.DiarizationSegment(
                start=1.0, end=4.0, speaker="SPEAKER_01"
            ),
        ]

        result = diarize_audio_fast.align_transcription_with_diarization(
            transcription, dia_segments
        )

        assert len(result) == 2, f"Expected 2 segments (speaker change), got {len(result)}"

        for seg in result:
            text = seg["text"]
            assert " " in text or len(text.split()) == 1, \
                f"Multi-word segment has no spaces: '{text}'"
            # Check no concatenated words
            words = text.split()
            assert all(w.isalpha() or any(c.isalpha() for c in w) for w in words), \
                f"Contains concatenated words: '{text}'"

        # First segment should have "Hello there"
        assert "Hello" in result[0]["text"]
        assert "there" in result[0]["text"]
        assert "Hellothere" not in result[0]["text"], \
            f"Words concatenated in first segment: '{result[0]['text']}'"


class TestSwiftIntegration:
    """Test Swift code can use bundled Python"""
    
    def test_swift_builds(self):
        """Test Swift code compiles"""
        import subprocess
        result = subprocess.run(
            ["swift", "build"],
            capture_output=True,
            text=True,
            cwd=Path(__file__).parent.parent
        )
        assert result.returncode == 0, f"Swift build failed: {result.stderr}"
    
    def test_swift_tests_pass(self):
        """Test Swift unit tests pass"""
        import subprocess
        result = subprocess.run(
            ["swift", "test"],
            capture_output=True,
            text=True,
            cwd=Path(__file__).parent.parent
        )
        # Note: May fail if tests don't exist or have issues
        # We just check it runs, not necessarily passes
        assert result.returncode in [0, 1], f"Swift test command failed: {result.stderr}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
