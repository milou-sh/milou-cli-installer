#!/bin/bash
# version.sh - Simple version management using GitHub releases manifest
# Clean approach: local has version number, check manifest for latest

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LIB_DIR}/.." && pwd)"

source "${LIB_DIR}/core.sh"
# env.sh is loaded by main script

#=============================================================================
# Configuration
#=============================================================================

GITHUB_ORG="${GITHUB_ORG:-milou-sh}"
GITHUB_REPO="${GITHUB_REPO:-milou-cli-installer}"

# Default version fallback (used when version cannot be determined)
VERSION_FILE="${ROOT_DIR}/VERSION"
if [[ -f "$VERSION_FILE" ]]; then
    DEFAULT_MILOU_VERSION="$(<"$VERSION_FILE")"
    DEFAULT_CLI_VERSION="$DEFAULT_MILOU_VERSION"
else
    DEFAULT_MILOU_VERSION="${DEFAULT_MILOU_VERSION:-1.0.0}"
    DEFAULT_CLI_VERSION="${DEFAULT_CLI_VERSION:-1.0.0}"
fi

#=============================================================================
# Version Check Functions
#=============================================================================

# Get current version from .env
version_get_current() {
    local version=$(env_get_or_default "MILOU_VERSION" "")
    [[ -z "$version" ]] && version="$DEFAULT_MILOU_VERSION"
    echo "$version"
}

# Resolve "latest" to actual version (no side effects - doesn't update .env)
version_resolve_latest() {
    local current=$(env_get_or_default "MILOU_VERSION" "")
    
    # If version is set and not "latest", return it
    [[ -n "$current" && "$current" != "latest" ]] && echo "$current" && return 0
    
    # Try to get the actual latest version
    local latest=$(version_get_latest)
    [[ -n "$latest" ]] && echo "$latest" && return 0
    
    # Fallback to default
    echo "$DEFAULT_MILOU_VERSION"
}

# Cache for API responses (5 minute TTL)
_VERSION_CACHE_VALUE=""
_VERSION_CACHE_TIME=0
VERSION_CACHE_TTL=300

version_fetch_latest_release() {
    local api="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/releases/latest"
    local curl_opts=(-sS -L -H "Accept: application/vnd.github+json")
    local token="${GITHUB_TOKEN:-}"
    [[ -z "$token" ]] && token=$(env_get_or_default "GHCR_TOKEN" "")

    if [[ -n "$token" ]]; then
        curl_opts+=(-H "Authorization: Bearer $token")
    fi

    local response
    response=$(curl "${curl_opts[@]}" "$api" 2>/dev/null || true)
    [[ -z "$response" ]] && return 1

    local latest=""
    if command -v jq >/dev/null 2>&1; then
        latest=$(echo "$response" | jq -r '.tag_name // empty')
    else
        latest=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4)
    fi

    [[ -n "$latest" ]] || return 1

    echo "$latest"
    return 0
}

version_fetch_latest_from_ghcr() {
    local token="${1:-}"

    [[ -z "$token" ]] && token=$(env_get_or_default "GHCR_TOKEN" "")
    [[ -z "$token" ]] && return 1

    local ghcr_url="https://api.github.com/orgs/${GITHUB_ORG}/packages/container/milou%2Fbackend/versions"
    local response=$(curl -s -H "Authorization: Bearer $token" "$ghcr_url" 2>/dev/null || true)

    if [[ -z "$response" ]]; then
        log_debug "No response from GHCR API"
        return 1
    fi

    if echo "$response" | grep -q '"message".*"Not Found"'; then
        log_debug "GHCR package not accessible"
        return 1
    fi

    local latest=""
    if command -v jq >/dev/null 2>&1; then
        latest=$(echo "$response" | jq -r '.[].metadata.container.tags[]' 2>/dev/null | \
                 grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
                 sort -V | tail -1)
    else
        latest=$(echo "$response" | grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+"' | \
                 tr -d '"' | sort -V | tail -1)
    fi

    [[ -n "$latest" ]] || return 1

    echo "$latest"
    return 0
}

# Get latest version (prefers GitHub releases, falls back to GHCR tags)
# Uses caching to reduce API calls
version_get_latest() {
    local now=$(date +%s)

    if [[ -n "$_VERSION_CACHE_VALUE" ]] && [[ $((now - _VERSION_CACHE_TIME)) -lt $VERSION_CACHE_TTL ]]; then
        log_debug "Using cached version: $_VERSION_CACHE_VALUE"
        echo "$_VERSION_CACHE_VALUE"
        return 0
    fi

    local latest=""
    if latest=$(version_fetch_latest_release); then
        log_debug "Resolved latest version via releases: $latest"
    else
        latest=$(version_fetch_latest_from_ghcr) || latest=""
        [[ -n "$latest" ]] && log_debug "Resolved latest version via GHCR: $latest"
    fi

    if [[ -z "$latest" ]]; then
        echo ""
        return 1
    fi

    _VERSION_CACHE_VALUE="$latest"
    _VERSION_CACHE_TIME=$now

    echo "$latest"
}

# Compare two semantic versions
# Returns: 0 if v1 < v2, 1 if v1 >= v2
version_needs_update() {
    local current="$1"
    local latest="$2"

    # Remove v prefix if present
    current="${current#v}"
    latest="${latest#v}"

    # Simple string comparison using sort -V
    if [[ "$current" == "$latest" ]]; then
        return 1  # No update needed
    fi

    # Check if current is less than latest
    local sorted=$(echo -e "$current\n$latest" | sort -V | head -1)

    if [[ "$sorted" == "$current" ]]; then
        return 0  # Update needed
    else
        return 1  # Current is newer (shouldn't happen but handle it)
    fi
}

#=============================================================================
# Main Functions
#=============================================================================

# Check for updates
version_check_updates() {
    local quiet="${1:-false}"

    [[ "$quiet" != "true" ]] && log_info "Checking for updates..."

    local current=$(version_get_current)
    # Resolve "latest" if needed, but don't update .env
    if [[ "$current" == "latest" ]] || [[ -z "$current" ]]; then
        current=$(version_resolve_latest)
    fi
    local latest=$(version_get_latest)

    if [[ -z "$latest" ]]; then
        [[ "$quiet" != "true" ]] && log_warn "Could not check for updates (no internet or GitHub API issue)"
        return 2
    fi

    if version_needs_update "$current" "$latest"; then
        [[ "$quiet" != "true" ]] && {
            log_success "Update available: v$current → v$latest"
            echo ""
            log_info "To update, run:"
            echo "  1. milou config set MILOU_VERSION $latest"
            echo "  2. milou update"
        }
        return 0
    else
        [[ "$quiet" != "true" ]] && log_success "You are running the latest version (v$current)"
        return 1
    fi
}

# Show version information
version_show() {
    local current=$(version_get_current)
    # Resolve "latest" if needed for display, but don't update .env
    if [[ "$current" == "latest" ]] || [[ -z "$current" ]]; then
        current=$(version_resolve_latest)
    fi
    local latest=$(version_get_latest)
    local cli_version="${CLI_VERSION:-$DEFAULT_CLI_VERSION}"

    echo "Milou Version Information"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "CLI Version:     v$cli_version"
    echo "Current Images:  v$current"

    if [[ -n "$latest" ]]; then
        echo "Latest Available: v$latest"

        if version_needs_update "$current" "$latest"; then
            echo "Status:          Update available!"
        else
            echo "Status:          Up to date"
        fi
    else
        echo "Latest Available: (could not check)"
        echo "Status:          Unknown"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#=============================================================================
# Command Handler
#=============================================================================

version_manage() {
    local action="${1:-show}"

    case "$action" in
        check|check-updates)
            version_check_updates "false"
            ;;
        current)
            version_get_current
            ;;
        latest)
            local latest=$(version_get_latest)
            if [[ -n "$latest" ]]; then
                echo "$latest"
            else
                log_error "Could not fetch latest version"
                return 1
            fi
            ;;
        show|"")
            version_show
            ;;
        *)
            log_error "Unknown version command: $action"
            echo "Usage: milou version [check|current|latest|show]"
            return 1
            ;;
    esac
}
