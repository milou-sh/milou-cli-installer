#!/bin/bash
# docker.sh - Docker operations and management
# Handles docker-compose operations with proper error handling

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
# env.sh and ghcr.sh are loaded by main script, functions are available

#=============================================================================
# Constants
#=============================================================================

DB_HEALTHCHECK_MAX_ATTEMPTS=30
DB_HEALTHCHECK_SLEEP=1
MILOU_PROJECT_NAME="${MILOU_PROJECT_NAME:-milou}"

_COMPOSE_SUPPORTS_WAIT=""

#=============================================================================
# Helper Functions
#=============================================================================

# Run docker compose command with v2/v1 compatibility
docker_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

# Cache for compose file and args (per command execution)
_COMPOSE_FILE_CACHE=""
_COMPOSE_ARGS_CACHE=()

# Determine which compose file to use based on environment (cached)
docker_get_compose_file() {
    # Return cached value if available
    [[ -n "$_COMPOSE_FILE_CACHE" ]] && echo "$_COMPOSE_FILE_CACHE" && return

    local env="${MILOU_ENV:-}"

    # If no environment specified, auto-detect from NODE_ENV
    if [[ -z "$env" ]]; then
        local node_env=$(env_get_or_default "NODE_ENV" "production")
        [[ "$node_env" == "development" ]] && env="dev" || env="prod"
    fi

    # Simplified compose file detection
    local compose_file="docker-compose.yml"
    
    case "$env" in
        dev|development)
            [[ -f "${SCRIPT_DIR}/docker-compose.dev.yml" ]] && compose_file="docker-compose.dev.yml"
            ;;
        prod|production)
            # Check for production.yml first (legacy), then docker-compose.prod.yml
            if [[ -f "${SCRIPT_DIR}/production.yml" ]]; then
                compose_file="production.yml"
            elif [[ -f "${SCRIPT_DIR}/docker-compose.prod.yml" ]]; then
                compose_file="docker-compose.prod.yml"
            fi
            ;;
    esac

    _COMPOSE_FILE_CACHE="${SCRIPT_DIR}/$compose_file"
    echo "$_COMPOSE_FILE_CACHE"
}

# Get complete docker-compose arguments (includes override file if present)
# Sets COMPOSE_ARGS array for safe argument passing (cached)
docker_get_compose_args() {
    # Return cached args if available
    if [[ ${#_COMPOSE_ARGS_CACHE[@]} -gt 0 ]]; then
        COMPOSE_ARGS=("${_COMPOSE_ARGS_CACHE[@]}")
        return
    fi

    local compose_file=$(docker_get_compose_file)
    COMPOSE_ARGS=(-f "$compose_file")
    
    if [[ -f "${SCRIPT_DIR}/docker-compose.override.yml" ]]; then
        COMPOSE_ARGS+=(-f "${SCRIPT_DIR}/docker-compose.override.yml")
    fi

    # Cache the args
    _COMPOSE_ARGS_CACHE=("${COMPOSE_ARGS[@]}")
}

# Centralized compose runner (ensures consistent flags)
docker_compose_run() {
    docker_get_compose_args

    (
        cd "$SCRIPT_DIR" || exit 1
        COMPOSE_PROJECT_NAME="$MILOU_PROJECT_NAME" docker_compose "${COMPOSE_ARGS[@]}" "$@"
    )

    return $?
}

docker_compose_supports_wait() {
    if [[ "${_COMPOSE_SUPPORTS_WAIT:-}" == "true" ]]; then
        return 0
    elif [[ "${_COMPOSE_SUPPORTS_WAIT:-}" == "false" ]]; then
        return 1
    fi

    local help_output=""

    if docker compose version >/dev/null 2>&1; then
        help_output=$(docker compose up --help 2>&1 || true)
    elif command -v docker-compose >/dev/null 2>&1; then
        help_output=$(docker-compose up --help 2>&1 || true)
    fi

    if [[ -n "$help_output" ]] && echo "$help_output" | grep -q -- "--wait"; then
        _COMPOSE_SUPPORTS_WAIT="true"
        return 0
    fi

    _COMPOSE_SUPPORTS_WAIT="false"
    return 1
}

docker_wait_for_health() {
    local service="$1"
    local attempts="${2:-$DB_HEALTHCHECK_MAX_ATTEMPTS}"
    local sleep_seconds="${3:-$DB_HEALTHCHECK_SLEEP}"

    local attempt=1
    while (( attempt <= attempts )); do
        local container_id
        container_id=$(docker_compose_run ps -q "$service" 2>/dev/null | tail -n1)

        if [[ -n "$container_id" ]]; then
            local health
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || echo "unknown")

            if [[ "$health" == "healthy" || "$health" == "running" ]]; then
                log_debug "$service reported $health state"
                return 0
            fi

            log_debug "$service health is $health (attempt $attempt/$attempts)"
        else
            log_debug "Waiting for $service container to appear (attempt $attempt/$attempts)"
        fi

        sleep "$sleep_seconds"
        ((attempt++))
    done

    return 1
}

# Check if Docker is installed and running
docker_check() {
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed. Install: https://docs.docker.com/get-docker/"
    fi

    # Check for docker compose (v2) or docker-compose (v1)
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        die "docker-compose is not installed. Install: apt install docker-compose-plugin"
    fi

    # Check if Docker daemon is running
    if ! docker info &>/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_info "Start: sudo systemctl start docker"
        log_info "Enable: sudo systemctl enable docker"
        die "Docker must be running"
    fi

    return 0
}

# Unified prerequisite checker
docker_ensure_prerequisites() {
    docker_check || die "Docker is not available"
    
    [[ -f "${SCRIPT_DIR}/.env" ]] || die ".env file not found. Run 'milou setup' first."
    env_validate || die "Environment validation failed"
}

# Unified GHCR authentication wrapper
docker_ensure_ghcr_auth() {
    local quiet="${1:-false}"
    
    if ! ghcr_is_authenticated; then
        ghcr_ensure_auth "" "$quiet" || {
            [[ "$quiet" != "true" ]] && log_warn "GHCR authentication failed - some images may not be accessible"
            return 1
        }
    fi
    return 0
}

# Start Milou services
docker_start() {
    log_info "Starting Milou services..."

    docker_ensure_prerequisites

    docker_get_compose_args
    local compose_file="${COMPOSE_ARGS[1]}"  # First -f argument is the compose file
    log_debug "Using compose file: $compose_file"
    [[ -f "$compose_file" ]] || die "Compose file not found: $compose_file"

    # Verify .env has ENGINE_URL
    local engine_url=$(env_get "ENGINE_URL")
    [[ -z "$engine_url" ]] && {
        log_warn "ENGINE_URL not found in .env, running migration..."
        env_migrate
    }

    # Ensure GHCR authentication (unified function)
    docker_ensure_ghcr_auth "true"  # Quiet mode, don't fail if no token

    log_info "Starting database..."
    if docker_compose_supports_wait; then
        if ! docker_compose_run up -d --wait database; then
            log_warn "docker compose --wait failed, falling back to manual health checks"
            docker_compose_run up -d database || die "Failed to start database"
            docker_wait_for_health "database" || die "Database did not become healthy in time"
        fi
    else
        docker_compose_run up -d database || die "Failed to start database"
        docker_wait_for_health "database" || die "Database did not become healthy in time"
    fi

    if [[ "${RUN_MIGRATIONS_ON_START:-false}" == "true" ]]; then
        log_info "Running database migrations..."
        if ! db_migrate >/dev/null 2>&1; then
            log_warn "Database migrations reported issues (check logs)"
        fi
    else
        log_debug "Skipping migrations (set RUN_MIGRATIONS_ON_START=true to enable)"
    fi

    log_info "Starting remaining services..."
    docker_compose_run up -d --remove-orphans || die "Failed to start services"

    log_success "Milou services started successfully"
    docker_status

    return 0
}

# Stop Milou services
docker_stop() {
    log_info "Stopping Milou services..."

    docker_check
    docker_get_compose_args

    docker_compose_run down --remove-orphans || die "Failed to stop services"

    log_success "Milou services stopped successfully"
    return 0
}

# Restart Milou services
docker_restart() {
    log_info "Restarting Milou services..."

    docker_stop
    sleep 2
    docker_start

    return 0
}

# Show service status
docker_status() {
    docker_check
    docker_get_compose_args

    docker_compose_run ps || log_warn "Could not get service status"

    return 0
}

# Show service logs
docker_logs() {
    local service="${1:-}"
    docker_check
    docker_get_compose_args

    if [[ -z "$service" ]]; then
        docker_compose_run logs --tail=100 -f
    else
        docker_compose_run logs --tail=100 -f "$service"
    fi

    return 0
}

# Pull images with optional version selection
docker_pull() {
    local target_version="${1:-}"
    
    docker_check
    docker_get_compose_args

    # Ensure GHCR authentication (unified function)
    docker_ensure_ghcr_auth "false"

    # Get current version once
    local current_version=$(env_get_or_default "MILOU_VERSION" "latest")

    if [[ -n "$target_version" && "$current_version" != "$target_version" ]]; then
        log_info "Updating MILOU_VERSION: $current_version → $target_version"
        env_set "MILOU_VERSION" "$target_version"
        current_version="$target_version"
    fi

    log_info "Pulling Docker images for version: $current_version"

    docker_compose_run pull || die "Failed to pull images"

    log_success "Docker images updated successfully"
    return 0
}

# Rebuild services
docker_build() {
    log_info "Building Docker images..."

    docker_check
    docker_get_compose_args

    docker_compose_run build || die "Failed to build images"

    log_success "Docker images built successfully"
    return 0
}

# Clean up Docker resources
docker_clean() {
    log_warn "Cleaning up Docker resources..."

    docker_check

    # Stop services first
    docker_stop 2>/dev/null || log_warn "Services may not be running"

    # Remove stopped containers
    log_info "Removing stopped containers..."
    docker container prune -f || log_warn "Failed to remove containers"

    # Remove unused images
    log_info "Removing unused images..."
    docker image prune -f || log_warn "Failed to remove images"

    # Remove unused volumes
    log_info "Removing unused volumes..."
    docker volume prune -f || log_warn "Failed to remove volumes"

    # Remove unused networks
    log_info "Removing unused networks..."
    docker network prune -f || log_warn "Failed to remove networks"

    log_success "Docker cleanup completed"
    return 0
}

# Update Milou (pull images and restart)
docker_update() {
    local skip_backup="${1:-false}"
    local target_version="${2:-}"

    log_info "Updating Milou..."

    docker_ensure_prerequisites

    # Check for updates first
    if [[ -z "$target_version" ]]; then
        # Check if update is available
        if version_check_updates "true"; then
            local latest=$(version_get_latest 2>/dev/null || echo "")
            if [[ -n "$latest" ]]; then
                target_version="$latest"
                log_info "Updating to latest version: $target_version"
            fi
        else
            log_info "Already running latest version"
        fi
    fi

    # Ensure ENGINE_URL exists
    local engine_url=$(env_get_or_default "ENGINE_URL" "")
    [[ -z "$engine_url" ]] && {
        log_info "Migrating .env to include ENGINE_URL..."
        env_migrate
    }

    # Create backup before update (unless skipped)
    if [[ "$skip_backup" != "true" ]] && [[ "$skip_backup" != "--no-backup" ]]; then
        log_info "Creating pre-update backup..."
        # backup.sh is loaded by main script, backup_create is available
        backup_create "pre_update_$(date +%Y%m%d_%H%M%S)" || \
            log_warn "Backup failed, but continuing with update"
    else
        log_warn "Skipping backup (--no-backup flag used)"
    fi

    # Pull images (with version if specified)
    docker_pull "$target_version"

    # Stop services before running migrations
    docker_stop

    # Run migrations during update (database is auto-started via depends_on)
    log_info "Running database migrations as part of update..."
    if ! db_migrate; then
        die "Database migrations failed during update"
    fi

    # Start services (no migrations on start by default)
    docker_start

    log_success "Milou updated successfully"
    if [[ -n "$target_version" ]]; then
        log_info "Now running version: $target_version"
    fi
    log_info "Backup available in: ${SCRIPT_DIR}/backups/"
    return 0
}

# Run database migrations
db_migrate() {
    log_info "Running database migrations..."

    docker_check
    docker_get_compose_args
    
    [[ -f "${SCRIPT_DIR}/.env" ]] || die ".env file not found. Run 'milou setup' first."

    # Run the database-migrations service with the profile
    if docker_compose_run --profile database-migrations up database-migrations --remove-orphans --abort-on-container-exit --exit-code-from database-migrations; then
        log_success "Database migrations completed successfully"
        # Bring down the migration service
        docker_compose_run --profile database-migrations down --remove-orphans 2>/dev/null || log_debug "Migration service cleanup completed"
        return 0
    else
        log_error "Database migrations failed"
        # Bring down the migration service even on failure
        docker_compose_run --profile database-migrations down --remove-orphans 2>/dev/null || log_debug "Migration service cleanup completed"
        return 1
    fi
}

# Command handler for 'milou db' operations
db_manage() {
    local action="${1:-}"
    shift

    case "$action" in
        migrate)
            db_migrate "$@"
            ;;
        *)
            die "Invalid db action: $action. Use: migrate"
            ;;
    esac
}

# Command handler for 'milou docker' operations
docker_manage() {
    local action="${1:-}"
    shift

    case "$action" in
        start)
            docker_start "$@"
            ;;
        stop)
            docker_stop "$@"
            ;;
        restart)
            docker_restart "$@"
            ;;
        status)
            docker_status "$@"
            ;;
        logs)
            docker_logs "$@"
            ;;
        pull)
            docker_pull "$@"
            ;;
        build)
            docker_build "$@"
            ;;
        clean)
            docker_clean "$@"
            ;;
        update)
            docker_update "$@"
            ;;
        *)
            die "Invalid docker action: $action. Use: start, stop, restart, status, logs, pull, build, clean, update"
            ;;
    esac
}

#=============================================================================
# Module loaded successfully
#=============================================================================
