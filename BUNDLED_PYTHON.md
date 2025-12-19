# Bundled Python Environment

This document explains how MeetingScribe bundles Python and ML dependencies for zero-configuration distribution.

## Architecture

MeetingScribe includes a complete Python 3.11 environment inside the app bundle:

```
MeetingScribe.app/
├── Contents/
│   ├── MacOS/
│   │   └── meetingscribe          (Swift binary)
│   ├── Resources/
│   │   ├── python/                (Bundled Python 3.11 + dependencies)
│   │   │   ├── bin/
│   │   │   │   └── python3
│   │   │   └── lib/
│   │   │       └── python3.11/site-packages/
│   │   │           ├── torch/
│   │   │           ├── torchaudio/
│   │   │           ├── whisper/
│   │   │           ├── speechbrain/
│   │   │           └── sklearn/
│   │   └── scripts/
│   │       └── diarize_audio_fast.py
│   └── Info.plist
```

## How It Works

### 1. Build Time
When building MeetingScribe:
- `scripts/bundle-python-env.sh` creates a Python virtual environment in `build/python-bundle/`
- Installs all ML dependencies via pip
- Optimizes size by removing tests, CUDA files, debug symbols
- `scripts/build-and-sign.sh` copies the bundle to `MeetingScribe.app/Contents/Resources/python/`

### 2. Runtime
When MeetingScribe runs:
- Swift code checks for bundled Python at `Bundle.main.resourcePath/python/bin/python3`
- If found, uses bundled Python (prioritized over system Python)
- Falls back to config-specified `pythonPath` if bundled not available
- Python script downloads ML models to `~/.meetingscribe/cache/models/` on first use

### 3. Model Caching
- ML models (~500MB) are NOT included in the bundle (keeps app size reasonable)
- Downloaded on first transcription with diarization
- Cached in user directory: `~/.meetingscribe/cache/models/spkrec-ecapa-voxceleb/`
- Subsequent runs reuse cached models

## Bundle Size

Typical sizes:
- Python environment: ~1.5GB
- App bundle (with Python): ~1.8-2.2GB
- ML models (cached separately): ~500MB
- Total disk usage: ~2.5GB

## Rebuilding the Python Bundle

### For Developers

If you need to rebuild the Python bundle (e.g., to update dependencies):

```bash
cd ~/My\ Drive/software_projects/meeting-scribe

# Remove old bundle
rm -rf build/python-bundle

# Create fresh bundle
./scripts/bundle-python-env.sh

# Rebuild app with new bundle
./scripts/build-and-sign.sh
```

### Updating Dependencies

Edit `scripts/requirements-diarization.txt`:

```txt
torch>=2.0.0
torchaudio>=2.0.0
openai-whisper>=20231117
speechbrain>=1.0.0
scikit-learn>=1.0.0
numpy>=1.20.0
```

Then rebuild:

```bash
./scripts/bundle-python-env.sh
./scripts/build-and-sign.sh
```

## Optimization

The bundling script automatically:
- Removes `__pycache__` directories (regenerate on first run)
- Removes `.pyc` bytecode files
- Removes test directories
- Removes CUDA files (macOS doesn't need them)
- Strips debug symbols from `.so` and `.dylib` files

For additional optimization, see `scripts/optimize-python-bundle.sh`.

## Troubleshooting

### Bundle Not Found

If the app can't find bundled Python:

```bash
# Verify bundle exists
ls -lh build/MeetingScribe.app/Contents/Resources/python/bin/python3

# Check logs
tail -f ~/Library/Logs/MeetingScribe/stderr.log
```

You should see:
```
Using bundled Python at: /path/to/MeetingScribe.app/Contents/Resources/python/bin/python3
```

### Import Errors

If Python can't import dependencies:

```bash
# Test bundled Python directly
build/MeetingScribe.app/Contents/Resources/python/bin/python3 -c "import torch; import whisper; import speechbrain; print('OK')"
```

If this fails, rebuild the bundle:
```bash
rm -rf build/python-bundle
./scripts/bundle-python-env.sh
```

### Model Download Failures

If model download fails on first run:

1. Check internet connection
2. Try manual download:
   ```bash
   mkdir -p ~/.meetingscribe/cache/models
   cd ~/.meetingscribe/cache/models
   
   # Python will download models here automatically
   # Or manually clone from HuggingFace
   git clone https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb
   ```

3. Check disk space (models need ~500MB)

### Code Signing Issues

If code signing fails with bundled Python:

```bash
# Sign Python executable
codesign --force --sign "Your Developer ID" \
    --options runtime \
    build/MeetingScribe.app/Contents/Resources/python/bin/python3

# Sign all .so files
find build/MeetingScribe.app/Contents/Resources/python -name "*.so" \
    -exec codesign --force --sign "Your Developer ID" --options runtime {} \;

# Sign app bundle
./scripts/build-and-sign.sh
```

### Large App Size

If the bundle is too large (>2.5GB):

1. Remove unnecessary torch backends:
   ```bash
   ./scripts/optimize-python-bundle.sh
   ```

2. Consider CPU-only torch (loses MPS acceleration):
   ```bash
   # Edit scripts/bundle-python-env.sh
   # Change pip install line to:
   pip install --no-cache-dir torch torchaudio \
       --index-url https://download.pytorch.org/whl/cpu
   ```

## Backward Compatibility

The bundled Python approach is fully backward compatible:

- **Development builds**: Can use system Python by not bundling
- **Custom Python**: Users can override by setting `pythonPath` in config
- **Priority**: Bundled Python → Config Python → System Python

Example config override:
```json
{
  "transcription": {
    "diarization": {
      "enabled": true,
      "pythonPath": "/usr/local/bin/python3",
      "scriptPath": "~/custom/diarize.py"
    }
  }
}
```

## Distribution

When creating distribution packages:

```bash
# Build with bundled Python
./scripts/build-and-sign.sh

# Create DMG/ZIP
./scripts/package-for-distribution.sh 1.0

# Result: dist/MeetingScribe-1.0.dmg (~2GB)
```

The DMG includes everything users need - no manual Python setup required!

## Future Improvements

Potential optimizations for future versions:

1. **Lazy Model Loading**: Download models only when diarization first used
2. **Differential Updates**: Separate Python bundle from app updates
3. **ONNX Runtime**: Use lighter inference engine instead of full torch
4. **Multi-arch Bundles**: Separate Intel vs Apple Silicon builds for smaller size
5. **Model Quantization**: Use smaller quantized models to reduce cache size

## Support

For issues with bundled Python:

1. Check logs: `~/Library/Logs/MeetingScribe/stderr.log`
2. Verify bundle: `ls build/MeetingScribe.app/Contents/Resources/python/`
3. Test Python: `build/MeetingScribe.app/Contents/Resources/python/bin/python3 --version`
4. Rebuild bundle: `./scripts/bundle-python-env.sh`
5. File issue on GitHub with logs
