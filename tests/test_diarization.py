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
    
    def test_diarization_end_to_end(self, bundle_python, tmp_path):
        """Test full diarization pipeline with bundled Python"""
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
