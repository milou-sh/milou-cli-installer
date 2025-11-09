#!/bin/bash
# ssl.sh - SSL certificate operations
# No silent failures, explicit error handling

source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

#=============================================================================
# SSL Certificate Operations
#=============================================================================

# SSL file paths
SSL_DIR="${SCRIPT_DIR}/ssl"
SSL_CERT_FILE="${SSL_DIR}/cert.pem"
SSL_KEY_FILE="${SSL_DIR}/key.pem"
SSL_CA_FILE="${SSL_DIR}/ca.pem"

# Initialize SSL directory
ssl_init() {
    log_debug "Initializing SSL directory..."

    mkdir -p "$SSL_DIR" || die "Failed to create SSL directory: $SSL_DIR"
    chmod 700 "$SSL_DIR" || die "Failed to set permissions on SSL directory"

    log_debug "SSL directory ready: $SSL_DIR"
    return 0
}

# Validate that certificate and private key match
# Uses openssl pkey which handles all key types automatically
ssl_validate_key_match() {
    local cert_path="$1"
    local key_path="$2"
    
    local cert_pubkey=$(openssl x509 -noout -pubkey -in "$cert_path" 2>/dev/null | openssl md5)
    local key_pubkey=$(openssl pkey -in "$key_path" -pubout 2>/dev/null | openssl md5)
    
    [[ -n "$cert_pubkey" && -n "$key_pubkey" ]] || die "Failed to extract public keys"
    [[ "$cert_pubkey" == "$key_pubkey" ]] || die "Certificate and private key do not match"
    return 0
}

# Generate self-signed certificate
ssl_generate_self_signed() {
    local domain="${1:-localhost}"
    local days="${2:-365}"

    log_info "Generating self-signed SSL certificate for $domain..."

    ssl_init

    # Generate private key and certificate in one command
    openssl req -x509 -nodes -days "$days" -newkey rsa:2048 \
        -keyout "$SSL_KEY_FILE" \
        -out "$SSL_CERT_FILE" \
        -subj "/C=FR/ST=IDF/L=Paris/O=Milou/CN=${domain}" \
        2>/dev/null || die "Failed to generate SSL certificate"

    # Set correct permissions - NO silent failures
    chmod 644 "$SSL_CERT_FILE" || die "Failed to set certificate permissions"
    chmod 600 "$SSL_KEY_FILE" || die "Failed to set private key permissions"

    # Verify permissions (explicit check for generated files)
    verify_perms "$SSL_CERT_FILE" "644"
    verify_perms "$SSL_KEY_FILE" "600"

    log_success "Self-signed certificate generated successfully"
    log_info "Certificate: $SSL_CERT_FILE"
    log_info "Private key: $SSL_KEY_FILE"

    return 0
}

# Import existing certificate
ssl_import() {
    local cert_path="$1"
    local key_path="$2"
    local ca_path="${3:-}"

    log_info "Importing SSL certificate..."

    # Validate inputs
    [[ -z "$cert_path" ]] && die "Certificate path is required"
    [[ -z "$key_path" ]] && die "Private key path is required"
    [[ ! -f "$cert_path" ]] && die "Certificate file not found: $cert_path"
    [[ ! -f "$key_path" ]] && die "Private key file not found: $key_path"

    if [[ -n "$ca_path" ]] && [[ ! -f "$ca_path" ]]; then
        die "CA certificate file not found: $ca_path"
    fi

    ssl_init

    # Validate certificate and key match
    ssl_validate_key_match "$cert_path" "$key_path"

    # Copy with install command (atomic + permissions in one operation)
    install -m 644 "$cert_path" "$SSL_CERT_FILE" || die "Failed to install certificate"
    install -m 600 "$key_path" "$SSL_KEY_FILE" || die "Failed to install private key"

    if [[ -n "$ca_path" ]]; then
        install -m 644 "$ca_path" "$SSL_CA_FILE" || die "Failed to install CA certificate"
        log_info "CA certificate: $SSL_CA_FILE"
    fi

    # Verify permissions (install command sets them, but verify for safety)
    verify_perms "$SSL_CERT_FILE" "644"
    verify_perms "$SSL_KEY_FILE" "600"

    log_success "SSL certificate imported successfully"
    log_info "Certificate: $SSL_CERT_FILE"
    log_info "Private key: $SSL_KEY_FILE"

    return 0
}

# Verify certificate is valid
ssl_verify() {
    log_info "Verifying SSL certificate..."

    [[ -f "$SSL_CERT_FILE" ]] || die "Certificate not found: $SSL_CERT_FILE"
    [[ -f "$SSL_KEY_FILE" ]] || die "Private key not found: $SSL_KEY_FILE"

    # Verify permissions
    verify_perms "$SSL_CERT_FILE" "644"
    verify_perms "$SSL_KEY_FILE" "600"

    # Check certificate validity
    local not_after=$(openssl x509 -enddate -noout -in "$SSL_CERT_FILE" 2>/dev/null | cut -d= -f2)
    local expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null)
    local now_epoch=$(date +%s)

    [[ -n "$expiry_epoch" ]] || die "Failed to parse certificate expiry date"

    if [[ $expiry_epoch -lt $now_epoch ]]; then
        log_error "Certificate has expired: $not_after"
        return 1
    fi

    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_left -lt 30 ]]; then
        log_warn "Certificate expires soon: $days_left days remaining"
    else
        log_success "Certificate is valid: $days_left days remaining"
    fi

    # Verify certificate and key match
    ssl_validate_key_match "$SSL_CERT_FILE" "$SSL_KEY_FILE"

    log_success "Certificate verification passed"
    return 0
}

# Show certificate information
ssl_info() {
    [[ -f "$SSL_CERT_FILE" ]] || die "Certificate not found: $SSL_CERT_FILE"

    log_info "SSL Certificate Information:"
    echo ""

    openssl x509 -in "$SSL_CERT_FILE" -noout -subject -issuer -dates -fingerprint 2>/dev/null || \
        die "Failed to read certificate information"

    echo ""
    log_info "Certificate file: $SSL_CERT_FILE"
    log_info "Private key file: $SSL_KEY_FILE"

    if [[ -f "$SSL_CA_FILE" ]]; then
        log_info "CA certificate file: $SSL_CA_FILE"
    fi

    return 0
}

# Renew certificate (re-generate self-signed)
ssl_renew() {
    local domain="${1:-localhost}"
    local days="${2:-365}"

    log_info "Renewing SSL certificate..."

    # Backup existing certificates
    if [[ -f "$SSL_CERT_FILE" ]]; then
        local backup_dir="${SSL_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir" || die "Failed to create backup directory"

        cp -p "$SSL_CERT_FILE" "$backup_dir/" || die "Failed to backup certificate"
        cp -p "$SSL_KEY_FILE" "$backup_dir/" || die "Failed to backup private key"

        [[ -f "$SSL_CA_FILE" ]] && cp -p "$SSL_CA_FILE" "$backup_dir/"

        log_info "Backed up existing certificates to: $backup_dir"
    fi

    # Generate new certificate
    ssl_generate_self_signed "$domain" "$days"

    log_success "Certificate renewed successfully"
    return 0
}

# Remove certificates
ssl_remove() {
    log_warn "Removing SSL certificates..."

    if [[ -d "$SSL_DIR" ]]; then
        # Backup before removing
        local backup_dir="${SCRIPT_DIR}/ssl_backup_$(date +%Y%m%d_%H%M%S)"
        cp -rp "$SSL_DIR" "$backup_dir" || log_warn "Failed to backup SSL directory"
        [[ -d "$backup_dir" ]] && log_info "Backed up to: $backup_dir"

        rm -rf "$SSL_DIR" || die "Failed to remove SSL directory"
        log_success "SSL certificates removed"
    else
        log_info "No SSL directory found"
    fi

    return 0
}

# Command handler for 'milou ssl' operations
ssl_manage() {
    local action="${1:-}"
    shift

    case "$action" in
        generate)
            ssl_generate_self_signed "$@"
            ;;
        import)
            ssl_import "$@"
            ;;
        verify)
            ssl_verify "$@"
            ;;
        info)
            ssl_info "$@"
            ;;
        renew)
            ssl_renew "$@"
            ;;
        remove)
            ssl_remove "$@"
            ;;
        *)
            die "Invalid SSL action: $action. Use: generate, import, verify, info, renew, remove"
            ;;
    esac
}

#=============================================================================
# Module loaded successfully
#=============================================================================
