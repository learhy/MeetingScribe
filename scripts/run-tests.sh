#!/bin/bash

# Comprehensive test runner for MeetingScribe
# Tests Swift code, Python scripts, bundled environment, and integration

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  MeetingScribe Test Suite${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Track test results
FAILED_TESTS=()

# Function to run a test section
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -e "${YELLOW}→${NC} Running: $test_name"
    
    if eval "$test_command"; then
        echo -e "${GREEN}✓${NC} $test_name passed"
        echo ""
        return 0
    else
        echo -e "${RED}✗${NC} $test_name failed"
        echo ""
        FAILED_TESTS+=("$test_name")
        return 1
    fi
}

# 1. Swift Build Test
run_test "Swift Build" "swift build"

# 2. Swift Unit Tests
run_test "Swift Unit Tests" "swift test"

# 3. Check if Python bundle exists
if [ -f "build/python-bundle/bin/python3" ]; then
    BUNDLE_PYTHON="build/python-bundle/bin/python3"
    
    # 4. Bundle Python Version Check
    run_test "Bundled Python Version" "$BUNDLE_PYTHON --version"
    
    # 5. Bundle Dependencies Check
    echo -e "${YELLOW}→${NC} Testing bundled Python dependencies..."
    DEPS_FAILED=0
    for dep in torch torchaudio whisper speechbrain sklearn soundfile; do
        if ! $BUNDLE_PYTHON -c "import $dep" 2>/dev/null; then
            echo -e "${RED}  ✗${NC} $dep import failed"
            DEPS_FAILED=1
        else
            echo -e "${GREEN}  ✓${NC} $dep imports successfully"
        fi
    done
    
    if [ $DEPS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✓${NC} All bundled dependencies working"
        echo ""
    else
        echo -e "${RED}✗${NC} Some bundled dependencies failed"
        echo ""
        FAILED_TESTS+=("Bundled Dependencies")
    fi
else
    echo -e "${YELLOW}⚠${NC}  Python bundle not found - skipping bundle tests"
    echo "   Run: ./scripts/bundle-python-env.sh"
    echo ""
fi

# 6. Python Unit Tests (if pytest is available)
if command -v pytest &> /dev/null; then
    if [ -f "tests/test_diarization.py" ]; then
        run_test "Python Unit Tests" "pytest tests/test_diarization.py -v --tb=short" || true
    fi
else
    echo -e "${YELLOW}⚠${NC}  pytest not installed - skipping Python unit tests"
    echo "   Install: pip install pytest soundfile"
    echo ""
fi

# 7. Integration Test: Build App Bundle
if [ -f "build/python-bundle/bin/python3" ]; then
    run_test "Build App Bundle" "./scripts/build-and-sign.sh > /dev/null 2>&1"
    
    # 8. Verify App Bundle Structure
    echo -e "${YELLOW}→${NC} Verifying app bundle structure..."
    BUNDLE_OK=1
    
    if [ ! -d "build/MeetingScribe.app" ]; then
        echo -e "${RED}  ✗${NC} App bundle not found"
        BUNDLE_OK=0
    else
        echo -e "${GREEN}  ✓${NC} App bundle exists"
    fi
    
    if [ ! -f "build/MeetingScribe.app/Contents/MacOS/meetingscribe" ]; then
        echo -e "${RED}  ✗${NC} Swift binary not found in bundle"
        BUNDLE_OK=0
    else
        echo -e "${GREEN}  ✓${NC} Swift binary in bundle"
    fi
    
    if [ ! -f "build/MeetingScribe.app/Contents/Resources/python/bin/python3" ]; then
        echo -e "${RED}  ✗${NC} Bundled Python not found in app"
        BUNDLE_OK=0
    else
        echo -e "${GREEN}  ✓${NC} Bundled Python in app"
    fi
    
    if [ ! -f "build/MeetingScribe.app/Contents/Resources/scripts/diarize_audio_fast.py" ]; then
        echo -e "${RED}  ✗${NC} Diarization script not found in app"
        BUNDLE_OK=0
    else
        echo -e "${GREEN}  ✓${NC} Diarization script in app"
    fi
    
    if [ $BUNDLE_OK -eq 1 ]; then
        echo -e "${GREEN}✓${NC} App bundle structure valid"
        echo ""
    else
        echo -e "${RED}✗${NC} App bundle structure invalid"
        echo ""
        FAILED_TESTS+=("App Bundle Structure")
    fi
    
    # 9. Test Bundled Python in App
    run_test "App Bundled Python" "build/MeetingScribe.app/Contents/Resources/python/bin/python3 --version"
fi

# Summary
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}✗ ${#FAILED_TESTS[@]} test(s) failed:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "${RED}  - $test${NC}"
    done
    echo ""
    exit 1
fi
