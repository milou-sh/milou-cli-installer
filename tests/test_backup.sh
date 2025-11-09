#!/bin/bash
# test_backup.sh - Tests for backup/restore module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "====================================="
echo "Backup Module Tests"
echo "====================================="
echo ""

# Load modules
source lib/core.sh
source lib/env.sh
source lib/docker.sh
source lib/backup.sh

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
export BACKUP_DIR="$TEST_DIR/backups"

# Setup test environment
mkdir -p "$TEST_DIR/ssl"
echo "test_env=value" > "$TEST_DIR/.env"
chmod 600 "$TEST_DIR/.env"
echo "test_cert" > "$TEST_DIR/ssl/cert.pem"
echo "test_key" > "$TEST_DIR/ssl/key.pem"
chmod 600 "$TEST_DIR/ssl/key.pem"

# Test 1: Backup directory creation
test_backup_dir() {
    backup_create "test_backup" >/dev/null 2>&1
    [[ -d "$BACKUP_DIR" ]]
}

# Test 2: Backup file created
test_backup_file() {
    [[ -f "$BACKUP_DIR/test_backup.tar.gz" ]]
}

# Test 3: Backup contains .env
test_backup_contains_env() {
    tar -tzf "$BACKUP_DIR/test_backup.tar.gz" | grep -q "\\.env"
}

# Test 4: Backup contains manifest
test_backup_manifest() {
    tar -tzf "$BACKUP_DIR/test_backup.tar.gz" | grep -q "MANIFEST"
}

# Test 5: Backup list shows backup
test_backup_list() {
    backup_list 2>/dev/null | grep -q "test_backup"
}

# Test 6: Create second backup
test_second_backup() {
    backup_create "test_backup2" >/dev/null 2>&1
    [[ -f "$BACKUP_DIR/test_backup2.tar.gz" ]]
}

# Test 7: Backup clean keeps recent backups
test_backup_clean() {
    backup_create "test_backup3" >/dev/null 2>&1
    backup_clean 2 >/dev/null 2>&1
    local count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    [[ $count -eq 2 ]]
}

echo "[1/7] Testing backup creation..."
run_test "Backup directory created" test_backup_dir
run_test "Backup file created" test_backup_file
echo ""

echo "[2/7] Testing backup contents..."
run_test "Backup contains .env" test_backup_contains_env
run_test "Backup contains manifest" test_backup_manifest
echo ""

echo "[3/7] Testing backup listing..."
run_test "Backup list shows backups" test_backup_list
echo ""

echo "[4/7] Testing multiple backups..."
run_test "Second backup created" test_second_backup
echo ""

echo "[5/7] Testing backup cleanup..."
run_test "Backup clean keeps recent" test_backup_clean
echo ""

echo "====================================="
echo "Tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "====================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
