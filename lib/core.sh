#!/bin/bash
# core.sh - Core utilities for the Milou CLI
# Logging, colors, error handling, common functions

#=============================================================================
# Colors & Formatting
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'  # No Color

#=============================================================================
# Logging Functions
#=============================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $*" >&2
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo -e "${DIM}DEBUG:${NC} $*" >&2
    fi
    return 0
}

log_color() {
    local color="$1"
    shift
    echo -e "${color}$*${NC}"
}

#=============================================================================
# Error Handling
#=============================================================================

# Die with error message
die() {
    log_error "$*"
    exit 1
}

# Require command exists
require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

# Require file exists
require_file() {
    local file="$1"
    [[ -f "$file" ]] || die "Required file not found: $file"
}

#=============================================================================
# File Operations (Atomic & Secure)
#=============================================================================

# Atomic write with permission control
atomic_write() {
    local file="$1"
    local content="$2"
    local perms="${3:-600}"

    local tmp=$(mktemp) || die "Failed to create temp file"

    echo "$content" > "$tmp" || {
        rm -f "$tmp"
        die "Failed to write to temp file"
    }

    chmod "$perms" "$tmp" || {
        rm -f "$tmp"
        die "Failed to set permissions on temp file"
    }

    mv "$tmp" "$file" || {
        rm -f "$tmp"
        die "Failed to move temp file to $file"
    }

    # Verify permissions stuck
    local actual_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %A "$file" 2>/dev/null)
    [[ "$actual_perms" == "$perms" ]] || {
        log_warn "Permission verification: expected $perms, got $actual_perms"
        chmod "$perms" "$file" || die "Failed to fix permissions"
    }

    log_debug "Atomic write complete: $file (perms: $perms)"
    return 0
}

# Verify file permissions
verify_perms() {
    local file="$1"
    local expected_perms="$2"

    [[ -f "$file" ]] || die "Cannot verify permissions: $file not found"

    local actual_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %A "$file" 2>/dev/null)

    if [[ "$actual_perms" != "$expected_perms" ]]; then
        log_warn "$file has permissions $actual_perms (expected $expected_perms)"
        chmod "$expected_perms" "$file" || die "Failed to fix permissions on $file"
        log_success "Fixed permissions: $file now $expected_perms"
    fi

    return 0
}

#=============================================================================
# Progress Indicators
#=============================================================================

# Display step progress
log_step() {
    local current="$1"
    local total="$2"
    local message="$3"

    # Calculate percentage
    local percent=$((current * 100 / total))

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}Step ${current} of ${total}${NC} (${percent}%) - ${message}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

#=============================================================================
# Utility Functions
#=============================================================================

# Generate random string
random_string() {
    local length="${1:-32}"
    local charset="${2:-hex}"  # hex, alphanumeric, safe

    case "$charset" in
        hex)
            openssl rand -hex "$((length / 2))" 2>/dev/null || \
                cat /dev/urandom | tr -dc 'a-f0-9' | head -c "$length"
            ;;
        alphanumeric)
            openssl rand -base64 "$length" 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$length" || \
                cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"
            ;;
        safe)
            # Safe for bash variables (no quotes needed)
            openssl rand -base64 "$length" 2>/dev/null | tr -dc 'A-Za-z0-9_-' | head -c "$length" || \
                cat /dev/urandom | tr -dc 'A-Za-z0-9_-' | head -c "$length"
            ;;
        *)
            die "Invalid charset: $charset"
            ;;
    esac
}

# Confirm action
confirm() {
    local message="$1"
    local default="${2:-N}"  # Y or N

    local prompt="[y/N]"
    [[ "$default" == "Y" ]] && prompt="[Y/n]"

    read -p "$message $prompt " response
    response="${response:-$default}"

    [[ "${response,,}" == "y" ]] && return 0 || return 1
}

# Validate domain name (basic check)
validate_domain() {
    local domain="$1"
    # Basic validation: alphanumeric, dots, hyphens, localhost
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    # Check not empty
    [[ -n "$domain" ]] || return 1
    return 0
}

# Validate port number
validate_port() {
    local port="$1"
    # Check if numeric
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # Check range
    [[ $port -gt 0 && $port -le 65535 ]] || return 1
    return 0
}

# Validate file path (exists and readable)
validate_file() {
    local file="$1"
    [[ -f "$file" ]] && [[ -r "$file" ]]
}

# Validate required argument (helper for consistent validation)
validate_required() {
    local var="$1"
    local name="${2:-argument}"
    [[ -z "$var" ]] && {
        log_error "$name is required"
        return 1
    }
    return 0
}

#=============================================================================
# Module loaded successfully
#=============================================================================
