#!/bin/bash
# env.sh - Atomic .env file operations
# Always preserves 600 permissions, no silent failures

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

#=============================================================================
# Constants
#=============================================================================

ENGINE_URL_PRODUCTION="http://engine:8089"
ENGINE_URL_DEVELOPMENT="http://localhost:8089"

#=============================================================================
# Environment File Operations
#=============================================================================

# Get value from .env file
env_get() {
    local key="$1"
    local env_file="${2:-${SCRIPT_DIR}/.env}"

    [[ -f "$env_file" ]] || die "Environment file not found: $env_file"
    [[ -n "$key" ]] || die "Key cannot be empty"

    local value
    value=$(awk -v key="$key" '
        BEGIN { FS="=" }
        {
            line=$0
            trimmed=line
            sub(/^[[:space:]]+/, "", trimmed)

            if (trimmed ~ /^[#;]/ || trimmed == "") {
                next
            }

            if (index(trimmed, "=") == 0) {
                next
            }

            split(trimmed, parts, "=")
            current=parts[1]
            sub(/[[:space:]]+$/, "", current)

            if (current == key) {
                sub(/^[^=]+= */, "", trimmed)
                print trimmed
                exit
            }
        }
    ' "$env_file")

    echo "$value"
}

# Get value from .env file with default value
env_get_or_default() {
    local key="$1"
    local default="${2:-}"
    local env_file="${3:-${SCRIPT_DIR}/.env}"

    local value
    value=$(env_get "$key" "$env_file" 2>/dev/null || true)

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Set value in .env file atomically (preserves comments/ordering)
env_set() {
    local key="$1"
    local value="$2"
    local env_file="${3:-${SCRIPT_DIR}/.env}"

    [[ -f "$env_file" ]] || die "Environment file not found: $env_file"
    [[ -n "$key" ]] || die "Key cannot be empty"

    log_debug "Setting $key in $env_file"

    local tmp_file
    tmp_file=$(mktemp) || die "Failed to create temp file"

    if ! awk -v key="$key" -v val="$value" '
        BEGIN { updated=0 }
        {
            line=$0
            trimmed=line
            sub(/^[[:space:]]+/, "", trimmed)

            if (trimmed ~ /^[#;]/ || trimmed == "") {
                print line
                next
            }

            if (index(trimmed, "=") == 0) {
                print line
                next
            }

            split(trimmed, parts, "=")
            current=parts[1]
            sub(/[[:space:]]+$/, "", current)

            if (current == key) {
                print key "=" val
                updated=1
            } else {
                print line
            }
        }
        END {
            if (!updated) {
                print key "=" val
            }
        }
    ' "$env_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        die "Failed to update environment file"
    fi

    chmod 600 "$tmp_file" || {
        rm -f "$tmp_file"
        die "Failed to set permissions on temp file"
    }

    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        die "Failed to update environment file"
    }

    verify_perms "$env_file" "600"

    log_debug "Set $key successfully"
    return 0
}

# Set multiple values atomically (single pass to avoid partial writes)
env_set_many() {
    local env_file="${1:-${SCRIPT_DIR}/.env}"
    shift

    [[ -f "$env_file" ]] || die "Environment file not found: $env_file"

    local remaining="$#"
    (( remaining % 2 == 0 )) || die "env_set_many requires key/value pairs"

    local pair_delim=$'\034'
    local -a pairs=()

    while [[ $# -gt 0 ]]; do
        local key="$1"
        local value="$2"
        [[ -n "$key" ]] || die "Key cannot be empty"
        pairs+=("$key${pair_delim}$value")
        shift 2
    done

    if [[ ${#pairs[@]} -eq 0 ]]; then
        log_debug "env_set_many called with no key/value pairs"
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp) || die "Failed to create temp file"

    if ! awk -v pair_delim="$pair_delim" '
        BEGIN {
            for (i = 2; i < ARGC; i++) {
                split(ARGV[i], parts, pair_delim)
                updates[parts[1]] = parts[2]
                delete ARGV[i]
            }
        }
        {
            line = $0
            trimmed = line
            sub(/^[[:space:]]+/, "", trimmed)

            if (trimmed ~ /^[#;]/ || trimmed == "" || index(trimmed, "=") == 0) {
                print line
                next
            }

            split(trimmed, parts, "=")
            current = parts[1]
            sub(/[[:space:]]+$/, "", current)

            if (current in updates) {
                print current "=" updates[current]
                processed[current] = 1
            } else {
                print line
            }
        }
        END {
            for (key in updates) {
                if (!(key in processed)) {
                    print key "=" updates[key]
                }
            }
        }
    ' "$env_file" "${pairs[@]}" > "$tmp_file"; then
        rm -f "$tmp_file"
        die "Failed to update environment file"
    fi

    chmod 600 "$tmp_file" || {
        rm -f "$tmp_file"
        die "Failed to set permissions on temp file"
    }

    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        die "Failed to update environment file"
    }

    verify_perms "$env_file" "600"
    log_debug "Updated ${#pairs[@]} values in $env_file"
    return 0
}

# Generate .env from template with secure defaults
env_generate() {
    local env_file="${1:-${SCRIPT_DIR}/.env}"
    local template_file="${2:-${SCRIPT_DIR}/.env.template}"

    log_info "Generating environment file..."

    # Check template exists
    [[ -f "$template_file" ]] || die "Template file not found: $template_file"

    # Read template
    local content=$(cat "$template_file")

    # Generate secure random values for secrets
    local jwt_secret=$(random_string 64 hex)
    local session_secret=$(random_string 64 hex)
    local encryption_key=$(random_string 64 hex)
    local db_password=$(random_string 32 alphanumeric)
    local redis_password=$(random_string 32 alphanumeric)
    local rabbitmq_password=$(random_string 32 alphanumeric)
    local rabbitmq_erlang_cookie=$(random_string 32 alphanumeric)
    local pgadmin_password=$(random_string 32 alphanumeric)
    local admin_password=$(random_string 16 alphanumeric)

    # Build RABBITMQ_URL with concrete values
    # Extract default values from template
    local rabbitmq_user=$(grep "^RABBITMQ_USER=" "$template_file" | cut -d= -f2 | tr -d ' ')
    local rabbitmq_host=$(grep "^RABBITMQ_HOST=" "$template_file" | cut -d= -f2 | tr -d ' ')
    local rabbitmq_port=$(grep "^RABBITMQ_PORT=" "$template_file" | cut -d= -f2 | tr -d ' ')
    local rabbitmq_url="amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}"

    # Replace placeholders
    content=$(echo "$content" | sed \
        -e "s|REPLACE_JWT_SECRET|${jwt_secret}|g" \
        -e "s|REPLACE_SESSION_SECRET|${session_secret}|g" \
        -e "s|REPLACE_ENCRYPTION_KEY|${encryption_key}|g" \
        -e "s|REPLACE_DB_PASSWORD|${db_password}|g" \
        -e "s|REPLACE_REDIS_PASSWORD|${redis_password}|g" \
        -e "s|REPLACE_RABBITMQ_PASSWORD|${rabbitmq_password}|g" \
        -e "s|REPLACE_ERLANG_COOKIE|${rabbitmq_erlang_cookie}|g" \
        -e "s|REPLACE_PGADMIN_PASSWORD|${pgadmin_password}|g" \
        -e "s|REPLACE_ADMIN_PASSWORD|${admin_password}|g" \
        -e "s|REPLACE_RABBITMQ_URL|${rabbitmq_url}|g")

    # Set ENGINE_URL based on environment
    if [[ "${NODE_ENV:-development}" == "production" ]]; then
        content=$(echo "$content" | sed "s|REPLACE_ENGINE_URL|${ENGINE_URL_PRODUCTION}|g")
    else
        content=$(echo "$content" | sed "s|REPLACE_ENGINE_URL|${ENGINE_URL_DEVELOPMENT}|g")
    fi

    # Write atomically with 600 permissions
    atomic_write "$env_file" "$content" "600"

    log_success "Environment file generated: $env_file"
    log_warn "Secrets have been generated. Keep this file secure (600 permissions)."

    return 0
}

# Validate .env file
env_validate() {
    local env_file="${1:-${SCRIPT_DIR}/.env}"

    log_info "Validating environment file..."

    [[ -f "$env_file" ]] || die "Environment file not found: $env_file"

    # Verify permissions (atomic_write sets them, but verify for safety)
    verify_perms "$env_file" "600"

    # Check required keys
    local required_keys=(
        "DATABASE_URI"
        "REDIS_HOST"
        "REDIS_PORT"
        "SESSION_SECRET"
        "ENCRYPTION_KEY"
        "ENGINE_URL"
    )

    local missing=()
    for key in "${required_keys[@]}"; do
        local value=$(env_get "$key" "$env_file")
        [[ -z "$value" ]] && missing+=("$key")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        for key in "${missing[@]}"; do
            log_error "  - $key"
        done
        die "Environment validation failed"
    fi

    # Check optional but recommended keys
    local ghcr_token=$(env_get "GHCR_TOKEN" "$env_file")
    if [[ -z "$ghcr_token" ]]; then
        log_warn "GHCR_TOKEN not set - image pulling may fail"
        log_info "Set with: milou ghcr setup"
    fi

    log_success "Environment file validated successfully"
    return 0
}

# Migrate old .env to new format (adds missing variables)
env_migrate() {
    local env_file="${1:-${SCRIPT_DIR}/.env}"

    [[ -f "$env_file" ]] || die "Environment file not found: $env_file"

    log_info "Migrating environment file..."

    local content=$(cat "$env_file")
    local updated=false

    # Check if ENGINE_URL exists
    local engine_url=$(env_get "ENGINE_URL" "$env_file")
    if [[ -z "$engine_url" ]]; then
        log_info "Adding ENGINE_URL to environment file..."

        # Determine value based on NODE_ENV
        local default_engine_url="$ENGINE_URL_PRODUCTION"
        local node_env=$(env_get "NODE_ENV" "$env_file")

        if [[ "$node_env" == "development" ]]; then
            default_engine_url="$ENGINE_URL_DEVELOPMENT"
        fi

        # Add ENGINE_URL after RABBITMQ section
        if grep -q "^RABBITMQ_PORT=" "$env_file"; then
            content=$(echo "$content" | sed "/^RABBITMQ_PORT=/a\\
\\
# Engine Configuration\\
# ----------------------------------------\\
ENGINE_URL=${default_engine_url}")
        else
            # Append at end if RABBITMQ_PORT not found
            content="${content}

# Engine Configuration
# ----------------------------------------
ENGINE_URL=${default_engine_url}"
        fi
        updated=true
        log_success "Added ENGINE_URL=${default_engine_url}"
    fi

    # Check if POSTGRES_ variables exist (needed for postgres container)
    if ! grep -q "^POSTGRES_USER=" "$env_file"; then
        log_info "Adding PostgreSQL container variables..."

        # Get existing DB values
        local db_user=$(env_get "DB_USER" "$env_file")
        local db_pass=$(env_get "DB_PASSWORD" "$env_file")
        local db_name=$(env_get "DB_NAME" "$env_file")

        if [[ -n "$db_user" && -n "$db_pass" && -n "$db_name" ]]; then
            # Add after DB_PASSWORD line
            content=$(echo "$content" | sed "/^DB_PASSWORD=/a\\
\\
# PostgreSQL Container Configuration\\
POSTGRES_USER=${db_user}\\
POSTGRES_PASSWORD=${db_pass}\\
POSTGRES_DB=${db_name}")
            updated=true
            log_success "Added POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB"
        fi
    fi

    # Write atomically if any changes were made
    if [[ "$updated" == "true" ]]; then
        atomic_write "$env_file" "$content" "600"
    else
        log_info "No migration needed - all required variables present"
    fi

    # Verify permissions
    verify_perms "$env_file" "600"

    log_success "Migration completed successfully"
    return 0
}

# Command handler for 'milou config' operations
env_manage() {
    local action="${1:-}"
    shift

    case "$action" in
        get)
            local key="${1:-}"
            [[ -z "$key" ]] && die "Usage: milou config get <key>"
            local value=$(env_get "$key")
            [[ -z "$value" ]] && die "Key not found: $key"
            echo "$value"
            ;;
        set)
            local key="${1:-}"
            local value="${2:-}"
            [[ -z "$key" ]] && die "Usage: milou config set <key> <value>"
            [[ -z "$value" ]] && die "Value cannot be empty"
            env_set "$key" "$value"
            log_success "Set $key successfully"
            ;;
        generate)
            env_generate "$@"
            ;;
        validate)
            env_validate "$@"
            ;;
        migrate)
            env_migrate "$@"
            ;;
        show)
            local env_file="${SCRIPT_DIR}/.env"
            [[ -f "$env_file" ]] || die "Environment file not found: $env_file"
            verify_perms "$env_file" "600"
            cat "$env_file"
            ;;
        *)
            die "Invalid config action: $action. Use: get, set, generate, validate, migrate, show"
            ;;
    esac
}

#=============================================================================
# Module loaded successfully
#=============================================================================
