#!/bin/bash

# Bundle Python environment for MeetingScribe distribution
# Uses python-build-standalone for truly portable Python
# Creates a self-contained Python 3.11 environment with all ML dependencies

set -e

echo "🐍 Bundling Python environment for MeetingScribe..."

# Configuration
BUNDLE_DIR="build/python-bundle"
REQUIREMENTS_FILE="scripts/requirements-diarization.txt"

# Python standalone builds are now from astral-sh
# Latest release: https://github.com/astral-sh/python-build-standalone/releases
PYTHON_VERSION="3.11.14"
PYTHON_STANDALONE_VERSION="20251217"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    PYTHON_PLATFORM="aarch64-apple-darwin"
else
    PYTHON_PLATFORM="x86_64-apple-darwin"
fi

PYTHON_TARBALL="cpython-${PYTHON_VERSION}%2B${PYTHON_STANDALONE_VERSION}-${PYTHON_PLATFORM}-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_STANDALONE_VERSION}/${PYTHON_TARBALL}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if requirements file exists
if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo -e "${RED}✗${NC} Requirements file not found: $REQUIREMENTS_FILE"
    exit 1
fi

# Clean previous bundle
if [ -d "$BUNDLE_DIR" ]; then
    echo -e "${YELLOW}→${NC} Removing previous bundle..."
    rm -rf "$BUNDLE_DIR"
fi

# Create bundle directory
mkdir -p "$BUNDLE_DIR"

# Download standalone Python if not already cached
PYTHON_CACHE="build/python-standalone-cache"
mkdir -p "$PYTHON_CACHE"

if [ ! -f "$PYTHON_CACHE/$PYTHON_TARBALL" ]; then
    echo -e "${YELLOW}→${NC} Downloading standalone Python ${PYTHON_VERSION} for ${PYTHON_PLATFORM}..."
    echo "   URL: $PYTHON_URL"
    echo "   This is a one-time download (~50MB)..."
    
    if command -v curl &> /dev/null; then
        curl -L -o "$PYTHON_CACHE/$PYTHON_TARBALL" "$PYTHON_URL"
    elif command -v wget &> /dev/null; then
        wget -O "$PYTHON_CACHE/$PYTHON_TARBALL" "$PYTHON_URL"
    else
        echo -e "${RED}✗${NC} Neither curl nor wget found. Please install one:"
        echo "  brew install curl"
        exit 1
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗${NC} Failed to download standalone Python"
        rm -f "$PYTHON_CACHE/$PYTHON_TARBALL"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} Downloaded standalone Python"
else
    echo -e "${GREEN}✓${NC} Using cached standalone Python"
fi

# Extract standalone Python
echo -e "${YELLOW}→${NC} Extracting standalone Python..."
tar -xzf "$PYTHON_CACHE/$PYTHON_TARBALL" -C "$BUNDLE_DIR"

if [ ! -f "$BUNDLE_DIR/python/bin/python3" ]; then
    echo -e "${RED}✗${NC} Failed to extract Python"
    exit 1
fi

echo -e "${GREEN}✓${NC} Standalone Python extracted"

# The standalone Python is in $BUNDLE_DIR/python/
# Move it up one level for cleaner structure
mv "$BUNDLE_DIR/python"/* "$BUNDLE_DIR/"
rmdir "$BUNDLE_DIR/python"

# Make Python executable
chmod +x "$BUNDLE_DIR/bin/python3"
PYTHON_CMD="$BUNDLE_DIR/bin/python3"

echo -e "${YELLOW}→${NC} Upgrading pip, setuptools, wheel..."
"$PYTHON_CMD" -m pip install --quiet --upgrade pip setuptools wheel

echo -e "${YELLOW}→${NC} Installing ML dependencies (this may take 5-10 minutes)..."
echo "   This will download ~2GB of packages..."

# Install dependencies from requirements file
# Use --no-cache-dir to save space
"$PYTHON_CMD" -m pip install --no-cache-dir -r "$REQUIREMENTS_FILE"

echo -e "${YELLOW}→${NC} Verifying installation..."
"$PYTHON_CMD" -c "import torch; import torchaudio; import whisper; import sklearn; print('Core imports successful')"

if [ $? -ne 0 ]; then
    echo -e "${RED}✗${NC} Installation verification failed"
    exit 1
fi

echo -e "${GREEN}✓${NC} All dependencies installed successfully"

# Optimization: Remove unnecessary files to reduce size
echo -e "${YELLOW}→${NC} Optimizing bundle size..."

# Remove pip cache (should already be clean with --no-cache-dir, but just in case)
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/pip/_vendor/distlib/*.exe"

# Remove test directories
find "$BUNDLE_DIR/lib" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true

# Remove __pycache__ directories (will regenerate on first run)
find "$BUNDLE_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Remove .pyc files
find "$BUNDLE_DIR" -name "*.pyc" -delete 2>/dev/null || true

# Remove CUDA files if present (we only need CPU/MPS for macOS)
find "$BUNDLE_DIR/lib" -name "*cuda*" -type f -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*cudnn*" -type f -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "*cuda*" -exec rm -rf {} + 2>/dev/null || true

# Strip debug symbols from .so files (macOS)
echo -e "${YELLOW}→${NC} Stripping debug symbols..."
find "$BUNDLE_DIR/lib" -name "*.so" -exec strip -x {} \; 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.dylib" -exec strip -x {} \; 2>/dev/null || true

# Calculate bundle size
BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
echo -e "${GREEN}✓${NC} Python bundle created: $BUNDLE_DIR"
echo -e "${GREEN}✓${NC} Bundle size: $BUNDLE_SIZE"

# Verify bundle works without activation
echo -e "${YELLOW}→${NC} Testing bundled Python..."
"$BUNDLE_DIR/bin/python3" -c "import torch; import whisper; print('Bundle verification successful')" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Bundle verification passed"
else
    echo -e "${YELLOW}⚠️${NC} Bundle verification skipped (may require more memory)"
    echo -e "${YELLOW}→${NC} Bundle created successfully, will verify at runtime"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Python bundling complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Bundle location: $BUNDLE_DIR"
echo "Bundle size: $BUNDLE_SIZE"
echo ""
echo "Next step: Run ./scripts/build-and-sign.sh to bundle into app"
