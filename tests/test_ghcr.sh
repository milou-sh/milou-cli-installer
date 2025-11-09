#!/bin/bash
# test_ghcr.sh - Tests for GHCR authentication module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "====================================="
echo "GHCR Module Tests"
echo "====================================="
echo ""

# Load modules
source lib/core.sh
source lib/env.sh
source lib/ghcr.sh

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
run_test() {
    local test_name="$1"
    shift

    if "$@"; then
        echo "  ✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "  ✗ $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Create temp directory for tests
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

export SCRIPT_DIR="$TEST_DIR"

# Test 1: GHCR registry constant
test_registry_constant() {
    [[ "$GHCR_REGISTRY" == "ghcr.io" ]]
}

# Test 2: GHCR namespace constant
test_namespace_constant() {
    [[ -n "$GHCR_NAMESPACE" ]]
}

# Test 3: ghcr_validate_token with empty token
test_validate_empty_token() {
    ! ghcr_validate_token "" 2>/dev/null
}

# Test 4: ghcr_validate_token with invalid token
test_validate_invalid_token() {
    ! ghcr_validate_token "invalid_token_12345" 2>/dev/null
}

# Test 5: ghcr_is_authenticated when not authenticated
test_not_authenticated() {
    # Isolate test by using a subshell with clean HOME
    (
        export HOME="$TEST_DIR"
        export GHCR_AUTHENTICATED=""
        ! ghcr_is_authenticated 2>/dev/null
    )
}

# Test 6: ghcr_login without token fails
test_login_without_token() {
    unset GHCR_TOKEN
    ! ghcr_login "" "true" 2>/dev/null
}

# Test 7: GHCR authentication state management
test_auth_state() {
    export GHCR_AUTHENTICATED="true"
    ghcr_is_authenticated
}

echo "[1/7] Testing GHCR constants..."
run_test "GHCR registry constant" test_registry_constant
run_test "GHCR namespace constant" test_namespace_constant
echo ""

echo "[2/7] Testing token validation..."
run_test "Empty token validation fails" test_validate_empty_token
run_test "Invalid token validation fails" test_validate_invalid_token
echo ""

echo "[3/7] Testing authentication state..."
run_test "Not authenticated by default" test_not_authenticated
run_test "Authentication state management" test_auth_state
echo ""

echo "[4/7] Testing login without credentials..."
run_test "Login without token fails" test_login_without_token
echo ""

echo "====================================="
echo "Tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "====================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
