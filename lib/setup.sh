#!/bin/bash
# setup.sh - Interactive setup wizard for fresh installations
# Guides users through initial configuration

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
# ssl.sh, docker.sh, env.sh, ghcr.sh, version.sh are loaded by main script

#=============================================================================
# Helpers
#=============================================================================

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

setup_auto_yes() {
    [[ "${MILOU_SETUP_ASSUME_YES:-false}" == "true" ]]
}

setup_usage() {
    cat <<EOF
Usage: milou setup [options] [command]

Commands:
    env                 Run environment configuration only
    ssl                 Run SSL configuration only

Options:
    -y, --yes           Run non-interactively using defaults (or env overrides)
    --no-pull           Skip pulling Docker images during setup
    -h, --help          Show this help message
EOF
}

setup_prompt_value() {
    local env_var="$1"
    local question="$2"
    local default="$3"
    local validator="${4:-}"
    local error_message="${5:-Invalid value provided}"

    local provided="${!env_var:-}"
    if [[ -n "$provided" ]]; then
        if [[ -n "$validator" ]] && ! "$validator" "$provided"; then
            die "$error_message"
        fi
        log_info "Using ${env_var} from environment"
        echo "$provided"
        return 0
    fi

    while true; do
        local value
        value=$(prompt "$question" "$default")
        if [[ -z "$validator" ]] || "$validator" "$value"; then
            echo "$value"
            return 0
        fi
        log_warn "$error_message"
    done
}

#=============================================================================
# Setup Wizard
#=============================================================================

# Interactive prompt with default value (with tab completion for paths)
prompt() {
    local question="$1"
    local default="${2:-}"  # Fix: Handle unbound variable
    local response

    if setup_auto_yes; then
        if [[ -n "$default" ]]; then
            log_debug "Auto-selecting default for '$question': $default"
            echo "$default"
            return 0
        fi
        die "Cannot auto-answer '$question' without a default. Provide environment overrides or rerun interactively."
    fi

    if [[ -n "$default" ]]; then
        read -e -p "$(log_color "$BLUE" "?") $question [$default]: " response
        echo "${response:-$default}"
    else
        read -e -p "$(log_color "$BLUE" "?") $question: " response
        echo "$response"
    fi
}

# Yes/no prompt
prompt_yn() {
    local question="$1"
    local default="${2:-n}"
    if setup_auto_yes; then
        if [[ "${default,,}" == "y" ]]; then
            log_debug "Auto-selecting 'yes' for: $question"
            return 0
        fi
        log_debug "Auto-selecting 'no' for: $question"
        return 1
    fi

    confirm "$question" "${default^^}"
}

# Setup environment file
setup_env() {
    log_info "Configuring environment variables..."

    local env_file="${SCRIPT_DIR}/.env"

    # Check if .env already exists FIRST before prompting
    if [[ -f "$env_file" ]]; then
        log_warn "Configuration file already exists: $env_file"
        echo ""
        log_info "Your existing credentials and settings are preserved"
        log_info "To reconfigure: delete .env and run setup again, or edit .env directly"
        echo ""

        # Migrate in case new variables are needed
        env_migrate "$env_file"
        verify_perms "$env_file" "600"

        log_success "Using existing configuration"
        return 0
    fi

    # Get environment type (allow override via MILOU_SETUP_NODE_ENV)
    local node_env="${MILOU_SETUP_NODE_ENV:-}"
    if [[ -n "$node_env" ]]; then
        case "${node_env,,}" in
            dev|development)
                node_env="development"
                ;;
            prod|production)
                node_env="production"
                ;;
            *)
                die "Invalid MILOU_SETUP_NODE_ENV value: $node_env (use development or production)"
                ;;
        esac
        log_info "Using NODE_ENV from MILOU_SETUP_NODE_ENV: $node_env"
    else
        node_env="production"
        if prompt_yn "Is this a development environment?" "n"; then
            node_env="development"
        fi
    fi

    # Get domain
    local domain
    domain=$(setup_prompt_value \
        "MILOU_SETUP_DOMAIN" \
        "Enter domain name" \
        "localhost" \
        validate_domain \
        "Invalid domain name. Use alphanumeric characters, dots, and hyphens only.")

    # Generate all secure credentials automatically
    log_info "Generating secure credentials for all services..."

    # Get admin user configuration
    echo ""
    log_info "Admin User Configuration..."
    log_info "Creating the first administrator account for Milou"
    echo ""

    local admin_email
    admin_email=$(setup_prompt_value \
        "MILOU_SETUP_ADMIN_EMAIL" \
        "Admin email address" \
        "admin@localhost" \
        validate_email \
        "Invalid email format. Please enter a valid email address.")

    local admin_password=$(random_string 16 alphanumeric)
    log_info "Generated secure admin password"

    # Get GHCR token for image pulling
    echo ""
    log_info "GitHub Container Registry (GHCR) Authentication..."
    log_info "A token is required to pull Milou images from ghcr.io"
    echo ""

    local ghcr_token="${MILOU_SETUP_GHCR_TOKEN:-}"
    if [[ -n "$ghcr_token" ]]; then
        log_info "Using GHCR token provided via environment variable"
        if ! ghcr_validate_token "$ghcr_token"; then
            die "Provided GHCR token is invalid. Check MILOU_SETUP_GHCR_TOKEN."
        fi
    else
        if setup_auto_yes; then
            log_warn "Skipping GHCR authentication (non-interactive and no token provided)"
        elif prompt_yn "Do you have a GHCR token?" "y"; then
            while true; do
                read -s -p "$(log_color "$BLUE" "Enter GHCR token: ")" ghcr_token || true
                echo ""

                if [[ -z "$ghcr_token" ]]; then
                    log_warn "No token provided - you'll need to login manually later"
                    break
                fi

                if ghcr_validate_token "$ghcr_token"; then
                    log_success "Token validated"
                    break
                fi

                log_error "Invalid token"
                if ! prompt_yn "Try again?" "y"; then
                    ghcr_token=""
                    break
                fi
            done
        else
            log_warn "Skipping GHCR authentication - you can set it up later with 'milou ghcr setup'"
        fi
    fi

    # Generate base file from template (random secrets handled there)
    env_generate "$env_file"

    # Determine ENGINE_URL based on environment
    local engine_url="$ENGINE_URL_PRODUCTION"
    [[ "$node_env" == "development" ]] && engine_url="$ENGINE_URL_DEVELOPMENT"

    # Compute actual DATABASE_URI using generated credentials
    local db_user=$(env_get_or_default "DB_USER" "milou" "$env_file")
    local db_pass=$(env_get_or_default "DB_PASSWORD" "" "$env_file")
    local db_host=$(env_get_or_default "DB_HOST" "database" "$env_file")
    local db_port=$(env_get_or_default "DB_PORT" "5432" "$env_file")
    local db_name=$(env_get_or_default "DB_NAME" "milou" "$env_file")
    local database_uri="postgresql://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}"

    local server_name="$domain"
    local scheme="https"
    [[ "$node_env" == "development" ]] && scheme="http"
    local domain_url="${scheme}://${domain}"

    env_set_many "$env_file" \
        NODE_ENV "$node_env" \
        DOMAIN "$domain" \
        SERVER_NAME "$server_name" \
        CORS_ORIGIN "$domain_url" \
        APP_URL "$domain_url" \
        ENGINE_URL "$engine_url" \
        ADMIN_EMAIL "$admin_email" \
        DATABASE_URI "$database_uri"

    # Ensure admin password matches the one we generated for display
    env_set "ADMIN_PASSWORD" "$admin_password" "$env_file"
    env_set "ADMIN_USERNAME" "admin" "$env_file"

    # Login to GHCR if token was provided
    if [[ -n "$ghcr_token" ]]; then
        echo ""
        if env_set "GHCR_TOKEN" "$ghcr_token" "$env_file"; then
            log_success "Stored GHCR token for future version checks"
        fi

        if ghcr_login "$ghcr_token" "false"; then
            log_success "GHCR authentication successful"

            log_info "Determining latest version..."
            local selected_version
            selected_version=$(version_get_latest)

            if [[ -z "$selected_version" ]]; then
                selected_version="latest"
                log_info "Using 'latest' tag (Docker will pull newest)"
            fi

            env_set "MILOU_VERSION" "$selected_version" "$env_file"
            log_success "Set MILOU_VERSION=$selected_version"
        else
            log_warn "GHCR authentication failed - you can retry with 'milou ghcr login'"
            env_set "MILOU_VERSION" "latest" "$env_file"
            log_success "Set MILOU_VERSION=latest"
        fi
    else
        log_info "No GitHub token provided, using 'latest' tag"
        env_set "MILOU_VERSION" "latest" "$env_file"
        log_success "Set MILOU_VERSION=latest"
    fi

    log_success "Environment file created: $env_file"
    log_warn "Credentials have been generated. Keep .env secure (600 permissions)."

    return 0
}

# Setup SSL certificates
setup_ssl() {
    log_info "Configuring SSL certificates..."

    if prompt_yn "Do you have existing SSL certificates?" "n"; then
        local cert_path
        while true; do
            cert_path=$(prompt "Path to certificate file (.crt or .pem)")
            if validate_file "$cert_path"; then
                break
            else
                log_warn "File not found or not readable: $cert_path"
            fi
        done

        local key_path
        while true; do
            key_path=$(prompt "Path to private key file (.key or .pem)")
            if validate_file "$key_path"; then
                break
            else
                log_warn "File not found or not readable: $key_path"
            fi
        done

        local ca_path=""
        if prompt_yn "Do you have a CA certificate?" "n"; then
            while true; do
                ca_path=$(prompt "Path to CA certificate file")
                if [[ -z "$ca_path" ]] || validate_file "$ca_path"; then
                    break
                else
                    log_warn "File not found or not readable: $ca_path"
                fi
            done
        fi

        ssl_import "$cert_path" "$key_path" "$ca_path"
    else
        local domain=$(env_get_or_default "DOMAIN" "localhost")
        log_info "Generating self-signed certificate for $domain..."
        ssl_generate_self_signed "$domain" 365
        log_warn "Using self-signed certificate. Consider obtaining a proper SSL certificate for production."
    fi

    return 0
}

# Minimal Docker installation (no over-engineering)
install_docker_minimal() {
    log_info "Installing Docker..."

    # Check if curl is available
    if ! command -v curl &>/dev/null; then
        log_error "curl is required for Docker installation"
        return 1
    fi

    # Use Docker's official installation script
    log_info "Running Docker installation script..."
    if curl -fsSL https://get.docker.com | sh; then
        log_success "Docker installed successfully"

        # Start Docker
        log_info "Starting Docker service..."
        systemctl start docker 2>/dev/null || log_warn "Could not start Docker service"
        systemctl enable docker 2>/dev/null || log_warn "Could not enable Docker service"

        # Install docker-compose plugin
        log_info "Installing Docker Compose plugin..."
        apt-get update -qq 2>/dev/null
        apt-get install -y docker-compose-plugin 2>/dev/null || {
            log_warn "Could not install docker-compose-plugin automatically"
            log_info "Please install it manually: apt install docker-compose-plugin"
        }

        return 0
    else
        log_error "Docker installation failed"
        return 1
    fi
}

# Check prerequisites before setup
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()
    local issues=()

    # Check: Docker installed
    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    else
        # Check: Docker daemon running
        if ! docker info &>/dev/null 2>&1; then
            issues+=("docker_not_running")
        fi

        # Check: Current user can access Docker
        if ! docker ps &>/dev/null 2>&1; then
            issues+=("docker_permission")
        fi
    fi

    # Check: docker-compose or docker compose
    if ! command -v docker-compose &>/dev/null 2>&1; then
        if ! docker compose version &>/dev/null 2>&1; then
            missing+=("docker-compose")
        fi
    fi

    # Report missing prerequisites
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required software:"
        echo ""

        for tool in "${missing[@]}"; do
            case "$tool" in
                docker)
                    log_color "$RED" "  ✗ Docker Engine"
                    log_info "    Install: https://docs.docker.com/get-docker/"
                    log_info "    Ubuntu/Debian: curl -fsSL https://get.docker.com | sh"
                    ;;
                docker-compose)
                    log_color "$RED" "  ✗ Docker Compose"
                    log_info "    Install: apt install docker-compose-plugin"
                    log_info "    Or: https://docs.docker.com/compose/install/"
                    ;;
            esac
            echo ""
        done

        # Offer to install automatically
        echo ""
        if [[ $EUID -eq 0 ]]; then
            # Running as root, can install directly
            if prompt_yn "Would you like to install Docker automatically?" "y"; then
                install_docker_minimal
                # Re-check after installation
                check_prerequisites
                return $?
            fi
        else
            # Not root, provide instructions
            log_warn "Not running as root - cannot install automatically"
            log_info "To install automatically, run: sudo ./milou setup"
            echo ""
        fi

        die "Please install missing software and try again"
    fi

    # Report issues
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_error "Configuration issues detected:"
        echo ""

        for issue in "${issues[@]}"; do
            case "$issue" in
                docker_not_running)
                    log_color "$RED" "  ✗ Docker daemon is not running"
                    log_info "    Start: sudo systemctl start docker"
                    log_info "    Enable at boot: sudo systemctl enable docker"
                    ;;
                docker_permission)
                    log_color "$RED" "  ✗ Current user cannot access Docker"
                    log_info "    Add user to docker group: sudo usermod -aG docker \$USER"
                    log_info "    Then logout and login again"
                    log_info "    Or run as root: sudo ./milou setup"
                    ;;
            esac
            echo ""
        done

        die "Please fix issues above and try again"
    fi

    log_success "All prerequisites are available"
    return 0
}

# Main setup - interactive, prompts user for inputs
setup() {
    local total_steps=5

    log_info "Welcome to Milou Setup"
    echo ""

    log_step 1 $total_steps "Prerequisites Check"
    check_prerequisites

    log_step 2 $total_steps "Environment Configuration"
    setup_env

    # Save admin credentials for later display
    local admin_email=$(env_get_or_default "ADMIN_EMAIL" "")
    local admin_password=$(env_get_or_default "ADMIN_PASSWORD" "")

    log_step 3 $total_steps "SSL Certificate Setup"
    setup_ssl

    log_step 4 $total_steps "Pulling Docker Images"
    if docker_check 2>/dev/null; then
        if [[ "${MILOU_SETUP_SKIP_PULL:-false}" == "true" ]]; then
            log_info "Skipping Docker image pull (--no-pull)"
        else
            local pull_now="true"
            if ! setup_auto_yes; then
                if ! prompt_yn "Pull Docker images now?" "y"; then
                    pull_now="false"
                fi
            fi

            if [[ "$pull_now" == "true" ]]; then
                log_info "Pulling Docker images..."
                echo ""
                if docker_pull; then
                    echo ""
                    log_success "Docker images pulled successfully"
                else
                    echo ""
                    log_warn "Could not pull images - will pull on first start"
                fi
            else
                log_info "Skipping Docker image pull (will pull on first start)"
            fi
        fi
    else
        log_warn "Docker not available - images will be pulled on first start"
    fi

    log_step 5 $total_steps "Final Setup"
    log_success "All services configured"

    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}✓ Setup Completed Successfully!${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Show admin credentials if available
    if [[ -n "$admin_email" && -n "$admin_password" ]]; then
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${YELLOW}⚠️  ADMIN CREDENTIALS - SAVE THESE!${NC}"
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${CYAN}Email:${NC}    ${GREEN}$admin_email${NC}"
        echo -e "  ${CYAN}Password:${NC} ${GREEN}$admin_password${NC}"
        echo ""
        echo -e "  ${YELLOW}⚠️  Change your password after first login!${NC}"
        echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    # Prompt to start services
    echo ""
    if prompt_yn "Would you like to start Milou services now?" "y"; then
        echo ""

        # Run database migrations first (required for fresh install)
        log_info "Running database migrations..."
        if db_migrate; then
            log_success "Database migrations completed"
        else
            log_warn "Database migrations failed - continuing anyway"
        fi

        echo ""
        log_info "Starting Milou services..."

        # Get domain from env for display
        local domain=$(env_get_or_default "DOMAIN" "localhost" "${SCRIPT_DIR}/.env")

        if docker_start; then
            echo ""
            log_success "Milou services started successfully!"
            echo ""
            log_info "Access your instance at:"
            log_info "  ${CYAN}https://${domain}${NC}"
            echo ""
            log_info "Monitor services:"
            log_info "  Status: ${CYAN}milou status${NC}"
            log_info "  Logs:   ${CYAN}milou logs${NC}"
        else
            echo ""
            log_warn "Failed to start services. Try manually:"
            log_info "  ${CYAN}milou start${NC}"
        fi
    else
        echo ""
        log_info "Start Milou when ready:"
        log_info "  1. Start services: ${CYAN}milou start${NC}"
        log_info "  2. Check status:   ${CYAN}milou status${NC}"
        log_info "  3. View logs:      ${CYAN}milou logs${NC}"
    fi
    echo ""

    return 0
}

# Command handler for 'milou setup' operations
setup_manage() {
    local assume_yes="${MILOU_SETUP_ASSUME_YES:-false}"
    local skip_pull="${MILOU_SETUP_SKIP_PULL:-false}"
    local action=""
    local -a action_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                assume_yes="true"
                shift
                ;;
            --no-pull)
                skip_pull="true"
                shift
                ;;
            -h|--help)
                setup_usage
                return 0
                ;;
            env|ssl)
                action="$1"
                shift
                action_args=("$@")
                break
                ;;
            -*)
                die "Unknown setup option: $1"
                ;;
            *)
                log_warn "Unknown setup argument: '$1' - ignoring"
                shift
                ;;
        esac
    done

    export MILOU_SETUP_ASSUME_YES="$assume_yes"
    export MILOU_SETUP_SKIP_PULL="$skip_pull"

    case "$action" in
        env)
            setup_env "${action_args[@]}"
            ;;
        ssl)
            setup_ssl "${action_args[@]}"
            ;;
        "")
            setup
            ;;
        *)
            log_warn "Unknown setup option: '$action' - running main setup"
            setup
            ;;
    esac
}

#=============================================================================
# Module loaded successfully
#=============================================================================
