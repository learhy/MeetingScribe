# MeetingScribe Test Suite

**For Integration/QA Team**

This document explains how to run automated tests for MeetingScribe.

## Quick Start

Run all tests from the project root:

```bash
./scripts/run-tests.sh
```

This runs the complete test suite including:
- Swift compilation and unit tests
- Python bundle verification
- End-to-end diarization tests (synthetic + real audio)
- App bundle integration tests

Expected runtime: ~30-60 seconds

## Prerequisites

### Required
- macOS 13.0+
- Python bundle built (run once): `./scripts/bundle-python-env.sh`
- Swift toolchain (comes with Xcode Command Line Tools)

### Optional (for Python unit tests)
```bash
pip install pytest soundfile numpy
```

## Test Types

### 1. Full Test Suite (Recommended)
```bash
./scripts/run-tests.sh
```

Runs everything. Exit code 0 = pass, non-zero = fail.

### 2. Swift Tests Only
```bash
swift build          # Verify compilation
swift test           # Run Swift unit tests
```

### 3. Python Tests Only
```bash
pytest tests/test_diarization.py -v
```

Runs 10 Python tests:
- Device detection
- Segment creation/merging
- Python bundle verification
- Dependency checks
- Synthetic audio smoke test (~5s)
- Real audio integration test (~8s)

### 4. Specific Test
```bash
# Test just the real audio pipeline
pytest tests/test_diarization.py::TestBundledPython::test_diarization_real_audio -v

# Test just synthetic audio (smoke test)
pytest tests/test_diarization.py::TestBundledPython::test_diarization_synthetic_audio -v

# Test bundled dependencies
pytest tests/test_diarization.py::TestBundledPython::test_all_dependencies -v
```

## Test Fixtures

Real audio fixtures are in `tests/fixtures/`:
- `test_meeting_30sec.wav` - 30-second real meeting audio (5.5MB)

These files should be committed to the repository.

## Expected Results

### Passing Test Output
```
✓ Swift Build passed
✓ Swift Unit Tests passed
✓ Bundled Python Version passed
✓ All bundled dependencies working
✓ Python Unit Tests passed
✓ Build App Bundle passed
✓ App bundle structure valid
✓ App Bundled Python passed

✓ All tests passed!
```

### Failed Test Output
```
✗ Python Unit Tests failed
✗ 1 test(s) failed:
  - Python Unit Tests
```

Check test output for details.

## Continuous Integration

### Before Merging PRs
```bash
# Switch to feature branch
git checkout feature/your-branch

# Run full test suite
./scripts/run-tests.sh

# If exit code is 0, safe to merge
echo $?
```

### Pre-Release Checklist
- [ ] Run `./scripts/run-tests.sh` - all pass
- [ ] Test with real 5+ minute recording
- [ ] Build DMG: `./scripts/package-for-distribution.sh 1.0`
- [ ] Install DMG on clean Mac (no Homebrew Python)
- [ ] Run actual meeting transcription
- [ ] Verify speaker diarization works

## Troubleshooting

### "Python bundle not found"
Build it first:
```bash
./scripts/bundle-python-env.sh
```
This takes 5-10 minutes the first time.

### "pytest not found"
Install pytest:
```bash
pip install pytest soundfile numpy
```

### Swift build fails
Clean and rebuild:
```bash
swift package clean
swift build
```

### Test failures after changes
1. Check which test failed in output
2. Run that specific test for details:
   ```bash
   pytest tests/test_diarization.py::TestName::test_name -v -s
   ```
3. Check logs: `~/Library/Logs/MeetingScribe/`

### Real audio test fails
The fixture might be corrupted. Regenerate:
```bash
# Extract new 30-second clip from a recording
ffmpeg -i ~/Documents/MeetingScribe/recordings/some_meeting.wav \
    -t 30 -acodec pcm_s16le \
    tests/fixtures/test_meeting_30sec.wav -y
```

## Performance Benchmarks

Track these metrics:

| Metric | Target | Command |
|--------|--------|---------|
| Full test suite | <60s | `time ./scripts/run-tests.sh` |
| Python tests | <15s | `time pytest tests/test_diarization.py` |
| Real audio test | <10s | `pytest tests/...::test_diarization_real_audio` |
| Bundle size | <1GB | `du -sh build/python-bundle` |
| App bundle size | <2GB | `du -sh build/MeetingScribe.app` |

## Test Coverage

### What's Tested ✅
- Swift code compiles
- Swift unit tests pass
- Bundled Python imports all dependencies
- Diarization pipeline runs end-to-end
- Real audio produces valid transcription
- App bundle has correct structure
- Bundled Python works inside app

### What's NOT Tested ⚠️
- Full app launch (requires GUI)
- Daemon installation
- Menu bar functionality
- Bear.app integration
- LaunchAgent behavior
- Permission prompts
- >30 second audio files

Manual testing required for these.

## Adding New Tests

### Python Tests
Edit `tests/test_diarization.py`:

```python
class TestYourFeature:
    def test_something(self, bundle_python):
        # Your test here
        assert True
```

### Swift Tests
Edit `tests/MeetingScribeTests.swift`:

```swift
func testYourFeature() throws {
    // Your test here
    XCTAssertTrue(true)
}
```

Then run the test suite to verify.

## CI/CD Integration

For automated builds (GitHub Actions, Jenkins, etc.):

```yaml
# Example GitHub Actions workflow
- name: Run Tests
  run: ./scripts/run-tests.sh
  
- name: Check Exit Code
  run: |
    if [ $? -ne 0 ]; then
      echo "Tests failed!"
      exit 1
    fi
```

## Getting Help

1. Check test output carefully
2. Run individual test with `-v -s` flags for details
3. Check `build/python-bundle/` exists and has deps
4. Verify Python version: `build/python-bundle/bin/python3 --version`
5. Check logs: `~/Library/Logs/MeetingScribe/`
6. Contact dev team with:
   - Full test output
   - macOS version
   - Branch name
   - Recent changes

## Test Maintenance

### Weekly
- Run full test suite on main branch
- Check performance hasn't regressed

### Before Release
- Full test suite
- Manual testing on clean Mac
- Performance benchmarks

### After Major Changes
- Update test fixtures if needed
- Add new tests for new features
- Update this README

## FAQ

**Q: Can I skip tests?**  
A: No. All tests must pass before merging.

**Q: Why does real audio test take 8 seconds?**  
A: It's actually running the full diarization pipeline on 30 seconds of real meeting audio.

**Q: What if I don't have pytest?**  
A: The shell script will skip Python unit tests but run everything else.

**Q: Can I test on longer audio?**  
A: Yes, but not in automated tests. Use manual testing for long recordings.

**Q: Why is there a 30-second fixture instead of full meetings?**  
A: Balance between thorough testing and fast CI. Full meetings tested manually.
