#!/bin/bash
# run_tests.sh - Simple test runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$SCRIPT_DIR"

echo "====================================="
echo "Milou CLI - Test Suite"
echo "====================================="
echo ""

# Test 1: Syntax validation
echo "[1/4] Checking syntax..."
for module in lib/*.sh; do
    if bash -n "$module"; then
        echo "  ✓ $module"
    else
        echo "  ✗ $module - syntax error"
        exit 1
    fi
done
echo ""

# Test 2: Module loading
echo "[2/4] Testing module loading..."
if bash -c 'source lib/core.sh 2>&1 && echo OK' | grep -q OK; then
    echo "  ✓ core.sh loads"
else
    echo "  ✗ core.sh failed to load"
    exit 1
fi

if bash -c 'source lib/core.sh && source lib/env.sh >/dev/null 2>&1 && echo OK' | grep -q OK; then
    echo "  ✓ env.sh loads"
else
    echo "  ✗ env.sh failed to load"
    exit 1
fi

if bash -c 'source lib/core.sh && source lib/ssl.sh >/dev/null 2>&1 && echo OK' | grep -q OK; then
    echo "  ✓ ssl.sh loads"
else
    echo "  ✗ ssl.sh failed to load"
    exit 1
fi

if bash -c 'source lib/core.sh && source lib/env.sh && source lib/docker.sh >/dev/null 2>&1 && echo OK' | grep -q OK; then
    echo "  ✓ docker.sh loads"
else
    echo "  ✗ docker.sh failed to load"
    exit 1
fi

if bash -c 'source lib/core.sh && source lib/env.sh && source lib/ssl.sh && source lib/docker.sh && source lib/setup.sh >/dev/null 2>&1 && echo OK' | grep -q OK; then
    echo "  ✓ setup.sh loads"
else
    echo "  ✗ setup.sh failed to load"
    exit 1
fi
echo ""

# Test 3: Main CLI script
echo "[3/4] Testing main CLI..."
if ./milou help > /dev/null; then
    echo "  ✓ milou help works"
else
    echo "  ✗ milou help failed"
    exit 1
fi

if ./milou version > /dev/null; then
    echo "  ✓ milou version works"
else
    echo "  ✗ milou version failed"
    exit 1
fi
echo ""

# Test 4: Core functionality tests
echo "[4/4] Running functionality tests..."

# Create temp directory for tests
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Test atomic_write function
TEST_FILE="$TEST_DIR/test.txt"
if bash -c "
    source lib/core.sh
    atomic_write '$TEST_FILE' 'test content' '600'
    [[ -f '$TEST_FILE' ]] && [[ \$(cat '$TEST_FILE') == 'test content' ]]
"; then
    echo "  ✓ atomic_write works"
else
    echo "  ✗ atomic_write failed"
    exit 1
fi

# Test permission verification
PERMS=$(stat -c %a "$TEST_FILE" 2>/dev/null || stat -f %A "$TEST_FILE" 2>/dev/null)
if [[ "$PERMS" == "600" ]]; then
    echo "  ✓ Permissions correctly set to 600"
else
    echo "  ✗ Permissions are $PERMS, expected 600"
    exit 1
fi

# Test env functions
ENV_FILE="$TEST_DIR/.env"
# Create empty .env file first
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
if bash -c "
    export SCRIPT_DIR='$TEST_DIR'
    source lib/core.sh
    source lib/env.sh
    env_set 'TEST_KEY' 'test_value' '$ENV_FILE'
    [[ \$(env_get 'TEST_KEY' '$ENV_FILE') == 'test_value' ]]
"; then
    echo "  ✓ env_set/env_get work"
else
    echo "  ✗ env functions failed"
    exit 1
fi

# Verify .env permissions
ENV_PERMS=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %A "$ENV_FILE" 2>/dev/null)
if [[ "$ENV_PERMS" == "600" ]]; then
    echo "  ✓ .env has correct permissions (600)"
else
    echo "  ✗ .env permissions are $ENV_PERMS, expected 600"
    exit 1
fi

echo ""
echo "====================================="
echo "All tests passed! ✓"
echo "====================================="
echo ""
echo "Milou CLI is ready to use."
echo ""
