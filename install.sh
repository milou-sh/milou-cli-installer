#!/bin/bash
# Milou CLI Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/milou-sh/milou-cli-installer/main/install.sh | bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
REPO="${MILOU_REPO:-https://github.com/milou-sh/milou-cli-installer}"
BRANCH="${MILOU_BRANCH:-main}"
INSTALL_DIR="${MILOU_INSTALL_DIR:-/opt/milou}"

banner() {
    cat <<'BANNER'
 __  __ ___ _     ___  _   _ 
|  \/  |_ _| |   |_ _|| \ | |
| |\/| || || |    | | |  \| |
| |  | || || |___ | | | |\  |
|_|  |_|___|_____|___||_| \_|

  ____ _     ___ 
 / ___| |   |_ _|
| |   | |    | | 
| |___| |___ | | 
 \____|_____|___|
BANNER
}

# Simple logging
log() { echo -e "${BLUE}→${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# Check dependencies
check_deps() {
    log "Checking dependencies..."

    # Check for curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        error "curl or wget is required"
    fi

    # Check for tar
    if ! command -v tar &>/dev/null; then
        error "tar is required"
    fi

    success "Dependencies OK"
}

install_docker_prereqs() {
    log "Installing Docker Engine..."
    if curl -fsSL https://get.docker.com | sh; then
        success "Docker Engine installed"
    else
        error "Failed to install Docker Engine automatically"
    fi

    if systemctl list-units --type=service | grep -q docker.service 2>/dev/null; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        log "Installing docker compose plugin..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            if apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
                success "docker compose plugin installed"
            else
                log "Could not install docker compose plugin automatically. Install manually if needed."
            fi
        else
            log "apt-get not available; install docker compose manually."
        fi
    else
        success "docker compose already available"
    fi
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && \
       { command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; }; then
        success "Docker prerequisites already installed"
        return 0
    fi

    if [[ $EUID -ne 0 ]]; then
        log "Docker is not installed and installer is not running as root."
        log "Please install Docker manually: https://docs.docker.com/get-docker/"
        return 0
    fi

    install_docker_prereqs
}

# Setup user and permissions
setup_user() {
    # Check if we need root for default installation
    if [[ "$INSTALL_DIR" == "/opt/milou" ]] && [[ $EUID -ne 0 ]]; then
        error "Default installation to /opt/milou requires root privileges"
        echo ""
        echo "Options:"
        echo "  1. Run with sudo: sudo bash install.sh"
        echo "  2. Custom location: MILOU_INSTALL_DIR=~/milou ./install.sh"
        exit 1
    fi

    # Create milou user if using default location
    if [[ "$INSTALL_DIR" == "/opt/milou" ]]; then
        log "Setting up milou user..."

        # Create user if doesn't exist
        if ! id -u milou &>/dev/null; then
            useradd -m -s /bin/bash milou
            success "Created milou user"
        else
            success "milou user already exists"
        fi

        # Add milou to docker group
        if command -v docker &>/dev/null; then
            usermod -aG docker milou 2>/dev/null || true
            success "Added milou to docker group"
        fi
    fi
}

# Backup existing installation if present
backup_existing() {
    if [[ -d "$INSTALL_DIR" ]]; then
        log "Existing installation found"

        # Backup important files
        local backup_dir="/tmp/milou_backup_$$"
        mkdir -p "$backup_dir"

        # Backup .env if it exists
        [[ -f "$INSTALL_DIR/.env" ]] && cp "$INSTALL_DIR/.env" "$backup_dir/"

        # Backup SSL certificates if they exist
        [[ -d "$INSTALL_DIR/ssl" ]] && cp -r "$INSTALL_DIR/ssl" "$backup_dir/"

        # Backup any backups
        [[ -d "$INSTALL_DIR/backups" ]] && cp -r "$INSTALL_DIR/backups" "$backup_dir/"

        echo "$backup_dir"
    else
        echo ""
    fi
}

# Restore backed up files
restore_backup() {
    local backup_dir="$1"

    if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
        log "Restoring configuration..."

        # Restore .env
        [[ -f "$backup_dir/.env" ]] && cp "$backup_dir/.env" "$INSTALL_DIR/"

        # Restore SSL certificates
        [[ -d "$backup_dir/ssl" ]] && cp -r "$backup_dir/ssl" "$INSTALL_DIR/"

        # Restore backups
        [[ -d "$backup_dir/backups" ]] && cp -r "$backup_dir/backups" "$INSTALL_DIR/"

        # Clean up temp backup
        rm -rf "$backup_dir"

        success "Configuration restored"
    fi
}

confirm_overwrite() {
    if [[ "${MILOU_INSTALL_FORCE:-false}" == "true" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        read -r -p "Existing installation found at $INSTALL_DIR. Overwrite it? [y/N] " answer
        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            *)
                success "Installation cancelled by user"
                exit 0
                ;;
        esac
    else
        error "Existing installation at $INSTALL_DIR. Re-run with MILOU_INSTALL_FORCE=true to overwrite."
    fi
}

# Download and install
install() {
    log "Installing Milou CLI to $INSTALL_DIR..."

    if [[ -d "$INSTALL_DIR" ]]; then
        confirm_overwrite
    fi

    # Backup existing installation
    local backup_dir=$(backup_existing)

    # Remove old installation
    rm -rf "$INSTALL_DIR"

    # Create directory
    mkdir -p "$INSTALL_DIR"

    # Download and extract
    log "Downloading from $REPO..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$INSTALL_DIR" --strip-components=1
    else
        wget -qO- "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$INSTALL_DIR" --strip-components=1
    fi

    # Make executable
    chmod +x "$INSTALL_DIR/milou"
    chmod +x "$INSTALL_DIR/lib"/*.sh 2>/dev/null || true

    # Set ownership for default installation
    if [[ "$INSTALL_DIR" == "/opt/milou" ]]; then
        chown -R milou:milou "$INSTALL_DIR"
        success "Set ownership to milou user"
    fi

    # Restore backup if exists
    restore_backup "$backup_dir"

    # Preserve ownership on restored files
    if [[ "$INSTALL_DIR" == "/opt/milou" ]] && [[ -n "$backup_dir" ]]; then
        [[ -f "$INSTALL_DIR/.env" ]] && chown milou:milou "$INSTALL_DIR/.env"
        [[ -d "$INSTALL_DIR/ssl" ]] && chown -R milou:milou "$INSTALL_DIR/ssl"
        [[ -d "$INSTALL_DIR/backups" ]] && chown -R milou:milou "$INSTALL_DIR/backups"
    fi

    success "Installation complete!"
}

# Setup PATH or wrapper
setup_access() {
    if [[ "$INSTALL_DIR" == "/opt/milou" ]]; then
        # Create wrapper for system installation
        log "Creating system wrapper..."

        cat > /usr/local/bin/milou << 'EOF'
#!/bin/bash
# Milou CLI wrapper - runs commands as milou user
exec sudo -u milou /opt/milou/milou "$@"
EOF
        chmod 755 /usr/local/bin/milou
        success "Created wrapper at /usr/local/bin/milou"
        log "You can now run: milou"
    else
        # Add to PATH for custom installation
        log "Setting up PATH..."

        local shell_rc=""

        # Detect shell configuration file
        if [[ -f "$HOME/.bashrc" ]]; then
            shell_rc="$HOME/.bashrc"
        elif [[ -f "$HOME/.zshrc" ]]; then
            shell_rc="$HOME/.zshrc"
        else
            shell_rc="$HOME/.profile"
        fi

        # Check if already in PATH
        if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
            echo "" >> "$shell_rc"
            echo "# Milou CLI" >> "$shell_rc"
            echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$shell_rc"
            success "Added to PATH in $shell_rc"
            log "Run: source $shell_rc"
        else
            success "Already in PATH"
        fi
    fi
}

# Main
main() {
    echo ""
    banner
    echo "Milou CLI Installer"
    echo "==================="
    echo ""

    check_deps
    ensure_docker
    setup_user
    install
    setup_access

    echo ""
    success "Installation successful!"
    echo ""

    if [[ "$INSTALL_DIR" == "/opt/milou" ]]; then
        echo "Installation location: /opt/milou"
        echo "Running user: milou"
        echo ""
        echo "Next steps:"
        echo "  1. Run: milou setup"
        echo "  2. Run: milou start"
        echo ""
        echo "Note: Commands will run as 'milou' user via sudo"
    else
        echo "Installation location: $INSTALL_DIR"
        echo ""
        echo "Next steps:"
        echo "  1. source your shell config or restart terminal"
        echo "  2. Run: milou setup"
        echo "  3. Run: milou start"
    fi
    echo ""
    echo "Documentation: https://docs.milou.sh"
    echo ""
}

# Run
main "$@"
