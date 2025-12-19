#!/bin/bash

# Optimize Python bundle size for distribution
# Run this after bundle-python-env.sh to further reduce bundle size

set -e

BUNDLE_DIR="build/python-bundle"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -d "$BUNDLE_DIR" ]; then
    echo -e "${RED}✗${NC} Python bundle not found at $BUNDLE_DIR"
    echo "Run ./scripts/bundle-python-env.sh first"
    exit 1
fi

echo -e "${YELLOW}→${NC} Optimizing Python bundle..."

# Get initial size
INITIAL_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
echo "Initial size: $INITIAL_SIZE"

# Remove additional test files
echo -e "${YELLOW}→${NC} Removing test files..."
find "$BUNDLE_DIR/lib" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "testing" -exec rm -rf {} + 2>/dev/null || true

# Remove documentation
echo -e "${YELLOW}→${NC} Removing documentation..."
find "$BUNDLE_DIR/lib" -type d -name "docs" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.md" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.rst" -delete 2>/dev/null || true

# Remove examples
echo -e "${YELLOW}→${NC} Removing examples..."
find "$BUNDLE_DIR/lib" -type d -name "examples" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "samples" -exec rm -rf {} + 2>/dev/null || true

# Remove benchmarks
echo -e "${YELLOW}→${NC} Removing benchmarks..."
find "$BUNDLE_DIR/lib" -type d -name "benchmarks" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -type d -name "bench" -exec rm -rf {} + 2>/dev/null || true

# Remove .git directories (if any)
echo -e "${YELLOW}→${NC} Removing version control files..."
find "$BUNDLE_DIR/lib" -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name ".gitignore" -delete 2>/dev/null || true

# Remove Python wheel/dist-info if not needed
echo -e "${YELLOW}→${NC} Cleaning package metadata..."
find "$BUNDLE_DIR/lib" -name "*.dist-info/RECORD" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.dist-info/METADATA" -delete 2>/dev/null || true

# Remove .pyx Cython source files (compiled .so already present)
echo -e "${YELLOW}→${NC} Removing Cython source files..."
find "$BUNDLE_DIR/lib" -name "*.pyx" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.pxd" -delete 2>/dev/null || true

# Remove .c source files from compiled extensions
echo -e "${YELLOW}→${NC} Removing C source files..."
find "$BUNDLE_DIR/lib" -name "*.c" -type f -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.cpp" -type f -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.h" -type f -delete 2>/dev/null || true

# Aggressively remove CUDA/CUDNN files
echo -e "${YELLOW}→${NC} Removing CUDA files..."
find "$BUNDLE_DIR/lib" -path "*torch/lib*" -name "*cuda*" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -path "*torch/lib*" -name "*cudnn*" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -path "*torch/lib*" -name "*nvrtc*" -delete 2>/dev/null || true
find "$BUNDLE_DIR/lib" -path "*torch/lib*" -name "*nv*" -delete 2>/dev/null || true

# Remove large unused torch backends
echo -e "${YELLOW}→${NC} Removing unused torch backends..."
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/torch/test" 2>/dev/null || true
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/torch/include" 2>/dev/null || true
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/torch/share" 2>/dev/null || true

# Remove IPython/Jupyter if accidentally installed
echo -e "${YELLOW}→${NC} Removing IPython/Jupyter (if present)..."
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/IPython" 2>/dev/null || true
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/jupyter*" 2>/dev/null || true
rm -rf "$BUNDLE_DIR/lib/python*/site-packages/notebook" 2>/dev/null || true

# Re-strip binaries (belt and suspenders)
echo -e "${YELLOW}→${NC} Re-stripping binaries..."
find "$BUNDLE_DIR/lib" -name "*.so" -exec strip -x {} \; 2>/dev/null || true
find "$BUNDLE_DIR/lib" -name "*.dylib" -exec strip -x {} \; 2>/dev/null || true

# Remove __pycache__ again
echo -e "${YELLOW}→${NC} Removing bytecode cache..."
find "$BUNDLE_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$BUNDLE_DIR" -name "*.pyo" -delete 2>/dev/null || true

# Get final size
FINAL_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Optimization complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Initial size: $INITIAL_SIZE"
echo "Final size:   $FINAL_SIZE"
echo ""
echo "Next: ./scripts/build-and-sign.sh"
