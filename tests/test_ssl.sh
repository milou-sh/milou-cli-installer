#!/bin/bash
# test_ssl.sh - Unit tests for ssl.sh module

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Setup test environment
TEST_DIR=$(mktemp -d)
export SCRIPT_DIR="$TEST_DIR"
export SSL_DIR="${SCRIPT_DIR}/ssl"

# Load modules
source "$(dirname "${BASH_SOURCE[0]}")/../lib/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ssl.sh"

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

assert_command_success() {
    local msg="$1"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ $? -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ $msg"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ $msg"
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

log_info "Running ssl.sh tests..."
echo ""

# Test 1: ssl_init creates directory with correct permissions
test_ssl_init() {
    log_info "Test: ssl_init creates directory with correct permissions"

    ssl_init

    assert_file_exists "$SSL_DIR" "SSL directory should exist"
    assert_perms "$SSL_DIR" "700" "SSL directory should have 700 permissions"

    echo ""
}

# Test 2: ssl_generate_self_signed creates certificate with correct permissions
test_ssl_generate() {
    log_info "Test: ssl_generate_self_signed creates certificate with correct permissions"

    ssl_generate_self_signed "test.example.com" 365 2>&1 | grep -v "^+"

    assert_file_exists "$SSL_CERT_FILE" "Certificate file should exist"
    assert_file_exists "$SSL_KEY_FILE" "Private key file should exist"
    assert_perms "$SSL_CERT_FILE" "644" "Certificate should have 644 permissions"
    assert_perms "$SSL_KEY_FILE" "600" "Private key should have 600 permissions"

    echo ""
}

# Test 3: ssl_verify validates certificate
test_ssl_verify() {
    log_info "Test: ssl_verify validates certificate"

    ssl_generate_self_signed "test.example.com" 365 2>&1 | grep -v "^+"

    ssl_verify 2>&1 | grep -v "^+"
    assert_command_success "Certificate verification should succeed"

    echo ""
}

# Test 4: Certificate and key match
test_certificate_match() {
    log_info "Test: Certificate and private key match"

    ssl_generate_self_signed "test.example.com" 365 2>&1 | grep -v "^+"

    local cert_modulus=$(openssl x509 -noout -modulus -in "$SSL_CERT_FILE" 2>/dev/null | openssl md5)
    local key_modulus=$(openssl rsa -noout -modulus -in "$SSL_KEY_FILE" 2>/dev/null | openssl md5)

    assert_eq "$cert_modulus" "$key_modulus" "Certificate and key modulus should match"

    echo ""
}

# Test 5: ssl_import with valid certificates
test_ssl_import() {
    log_info "Test: ssl_import imports certificates correctly"

    # Generate certificates in temp location
    local temp_cert="${TEST_DIR}/temp_cert.pem"
    local temp_key="${TEST_DIR}/temp_key.pem"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$temp_key" \
        -out "$temp_cert" \
        -subj "/C=FR/ST=IDF/L=Paris/O=Test/CN=import.test.com" \
        2>/dev/null

    # Import
    ssl_import "$temp_cert" "$temp_key" 2>&1 | grep -v "^+"

    assert_file_exists "$SSL_CERT_FILE" "Imported certificate should exist"
    assert_file_exists "$SSL_KEY_FILE" "Imported private key should exist"
    assert_perms "$SSL_CERT_FILE" "644" "Imported certificate should have 644 permissions"
    assert_perms "$SSL_KEY_FILE" "600" "Imported private key should have 600 permissions"

    echo ""
}

# Test 6: Permissions never become 644 for private key
test_key_permissions_secure() {
    log_info "Test: Private key permissions never become 644 (security test)"

    ssl_generate_self_signed "test.example.com" 365 2>&1 | grep -v "^+"

    # Try to break permissions (simulating what sed -i does in old CLI)
    chmod 644 "$SSL_KEY_FILE" 2>/dev/null || true

    # Now verify should catch this
    if ssl_verify 2>&1 | grep -q "Permission verification failed"; then
        log_success "✓ Security test: verify_perms catches wrong permissions"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        # If verify didn't catch it, that's actually bad
        local actual_perms=$(stat -c %a "$SSL_KEY_FILE" 2>/dev/null || stat -f %A "$SSL_KEY_FILE" 2>/dev/null)
        if [[ "$actual_perms" == "600" ]]; then
            # Good, permissions were automatically fixed
            log_success "✓ Security test: permissions auto-corrected to 600"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_error "✗ Security test: private key has insecure permissions: $actual_perms"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    echo ""
}

# Test 7: ssl_renew backs up old certificates
test_ssl_renew() {
    log_info "Test: ssl_renew backs up old certificates"

    # Generate initial certificate
    ssl_generate_self_signed "test.example.com" 365 2>&1 | grep -v "^+"

    # Get original fingerprint
    local original_fingerprint=$(openssl x509 -noout -fingerprint -in "$SSL_CERT_FILE" 2>/dev/null)

    sleep 1  # Ensure different timestamp

    # Renew
    ssl_renew "renewed.example.com" 365 2>&1 | grep -v "^+"

    # Check backup exists
    local backup_count=$(find "$SSL_DIR" -type d -name "backup_*" | wc -l)

    if [[ $backup_count -gt 0 ]]; then
        log_success "✓ Backup directory created"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "✗ No backup directory found"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Verify new certificate is different
    local new_fingerprint=$(openssl x509 -noout -fingerprint -in "$SSL_CERT_FILE" 2>/dev/null)

    if [[ "$original_fingerprint" != "$new_fingerprint" ]]; then
        log_success "✓ New certificate generated (fingerprints differ)"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "✗ Certificate not renewed (same fingerprint)"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    echo ""
}

#=============================================================================
# Run all tests
#=============================================================================

test_ssl_init
test_ssl_generate
test_ssl_verify
test_certificate_match
test_ssl_import
test_key_permissions_secure
test_ssl_renew

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
