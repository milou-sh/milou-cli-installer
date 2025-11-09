#!/bin/bash
# test_env.sh - Unit tests for env.sh module

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Setup test environment
TEST_DIR=$(mktemp -d)
export SCRIPT_DIR="$TEST_DIR"

# Load modules
source "$(dirname "${BASH_SOURCE[0]}")/../lib/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"

# Test helpers
assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Assertion failed}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$actual" == "$expected" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ $msg"
        log_error "  Expected: $expected"
        log_error "  Actual: $actual"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -f "$file" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ $msg"
        return 1
    fi
}

assert_perms() {
    local file="$1"
    local expected_perms="$2"
    local msg="${3:-Permissions should be $expected_perms}"

    TESTS_RUN=$((TESTS_RUN + 1))

    local actual_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %A "$file" 2>/dev/null)

    if [[ "$actual_perms" == "$expected_perms" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ $msg"
        log_error "  Expected: $expected_perms"
        log_error "  Actual: $actual_perms"
        return 1
    fi
}

# Cleanup
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

#=============================================================================
# Tests
#=============================================================================

log_info "Running env.sh tests..."
echo ""

# Test 1: env_set creates file with correct permissions
test_env_set_permissions() {
    log_info "Test: env_set creates file with 600 permissions"

    local env_file="$TEST_DIR/.env"
    echo "FOO=bar" > "$env_file"
    chmod 644 "$env_file"  # Start with wrong permissions

    env_set "TEST_KEY" "test_value" "$env_file"

    assert_file_exists "$env_file" "File should exist"
    assert_perms "$env_file" "600" "File should have 600 permissions"

    echo ""
}

# Test 2: env_get retrieves correct value
test_env_get() {
    log_info "Test: env_get retrieves correct value"

    local env_file="$TEST_DIR/.env"
    echo "KEY1=value1
KEY2=value2
KEY3=value3" > "$env_file"
    chmod 600 "$env_file"

    local result=$(env_get "KEY2" "$env_file")
    assert_eq "$result" "value2" "env_get should retrieve KEY2=value2"

    echo ""
}

# Test 3: env_set updates existing key
test_env_set_update() {
    log_info "Test: env_set updates existing key"

    local env_file="$TEST_DIR/.env"
    echo "KEY1=old_value
KEY2=value2" > "$env_file"
    chmod 600 "$env_file"

    env_set "KEY1" "new_value" "$env_file"

    local result=$(env_get "KEY1" "$env_file")
    assert_eq "$result" "new_value" "env_set should update KEY1 to new_value"
    assert_perms "$env_file" "600" "Permissions should remain 600 after update"

    echo ""
}

# Test 4: env_set adds new key
test_env_set_add() {
    log_info "Test: env_set adds new key"

    local env_file="$TEST_DIR/.env"
    echo "KEY1=value1" > "$env_file"
    chmod 600 "$env_file"

    env_set "KEY2" "value2" "$env_file"

    local result=$(env_get "KEY2" "$env_file")
    assert_eq "$result" "value2" "env_set should add KEY2=value2"
    assert_perms "$env_file" "600" "Permissions should remain 600 after add"

    echo ""
}

# Test 5: env_migrate adds ENGINE_URL
test_env_migrate() {
    log_info "Test: env_migrate adds ENGINE_URL"

    local env_file="$TEST_DIR/.env"
    echo "NODE_ENV=production
DATABASE_URI=postgresql://localhost
RABBITMQ_PORT=5672" > "$env_file"
    chmod 600 "$env_file"

    env_migrate "$env_file"

    local engine_url=$(env_get "ENGINE_URL" "$env_file")
    assert_eq "$engine_url" "http://engine:8089" "ENGINE_URL should be added with production value"
    assert_perms "$env_file" "600" "Permissions should remain 600 after migration"

    echo ""
}

# Test 6: env_migrate skips if ENGINE_URL exists
test_env_migrate_skip() {
    log_info "Test: env_migrate skips if ENGINE_URL exists"

    local env_file="$TEST_DIR/.env"
    echo "ENGINE_URL=http://custom:9000
NODE_ENV=production" > "$env_file"
    chmod 600 "$env_file"

    env_migrate "$env_file"

    local engine_url=$(env_get "ENGINE_URL" "$env_file")
    assert_eq "$engine_url" "http://custom:9000" "ENGINE_URL should not be changed"

    echo ""
}

# Test 7: Permissions preserved across multiple operations
test_permissions_preserved() {
    log_info "Test: Permissions preserved across multiple operations"

    local env_file="$TEST_DIR/.env"
    echo "KEY1=value1" > "$env_file"
    chmod 600 "$env_file"

    # Multiple operations
    env_set "KEY2" "value2" "$env_file"
    env_set "KEY3" "value3" "$env_file"
    env_set "KEY1" "updated" "$env_file"

    assert_perms "$env_file" "600" "Permissions should be 600 after multiple operations"

    local key1=$(env_get "KEY1" "$env_file")
    local key2=$(env_get "KEY2" "$env_file")
    local key3=$(env_get "KEY3" "$env_file")

    assert_eq "$key1" "updated" "KEY1 should be updated"
    assert_eq "$key2" "value2" "KEY2 should exist"
    assert_eq "$key3" "value3" "KEY3 should exist"

    echo ""
}

# Test 8: env_get handles values containing '='
test_env_get_handles_equals() {
    log_info "Test: env_get handles values containing '=' characters"

    local env_file="$TEST_DIR/.env"
    echo "DATABASE_URI=postgresql://user:pa=ss@localhost:5432/dbname" > "$env_file"
    chmod 600 "$env_file"

    local uri=$(env_get "DATABASE_URI" "$env_file")
    assert_eq "$uri" "postgresql://user:pa=ss@localhost:5432/dbname" "DATABASE_URI should be returned exactly"

    echo ""
}

# Test 9: env_set_many updates multiple keys atomically
test_env_set_many() {
    log_info "Test: env_set_many updates multiple keys"

    local env_file="$TEST_DIR/.env"
    echo "KEY1=value1" > "$env_file"
    chmod 600 "$env_file"

    env_set_many "$env_file" KEY1 "new_value" KEY2 "value2"

    assert_eq "$(env_get "KEY1" "$env_file")" "new_value" "KEY1 should update"
    assert_eq "$(env_get "KEY2" "$env_file")" "value2" "KEY2 should be added"
    assert_perms "$env_file" "600" "Permissions should stay 600"

    echo ""
}

#=============================================================================
# Run all tests
#=============================================================================

test_env_set_permissions
test_env_get
test_env_set_update
test_env_set_add
test_env_migrate
test_env_migrate_skip
test_permissions_preserved
test_env_get_handles_equals
test_env_set_many

#=============================================================================
# Summary
#=============================================================================

echo ""
log_info "========================================="
log_info "Test Summary"
log_info "========================================="
log_info "Total tests: $TESTS_RUN"
log_success "Passed: $TESTS_PASSED"

if [[ $TESTS_FAILED -gt 0 ]]; then
    log_error "Failed: $TESTS_FAILED"
    exit 1
else
    log_success "All tests passed!"
    exit 0
fi
