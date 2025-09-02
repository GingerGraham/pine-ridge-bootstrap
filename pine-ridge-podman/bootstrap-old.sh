#!/bin/bash
# podman-bootstrap.sh - Bootstrap Podman with Ansible GitOps

set -euo pipefail

REPO_URL="https://github.com/yourusername/pine-ridge-podman.git"
GIT_BRANCH="main"
INSTALL_DIR="/opt/pine-ridge-podman"
LOG_FILE="/tmp/podman-bootstrap-$(date +%s).log"

# Ensure log file is writable
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as non-root with sudo
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root. Run as a user with sudo privileges."
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges. Please run with a user in the wheel group."
    fi
    
    # Check if podman is installed
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed. Please install podman first: sudo dnf install podman"
    fi
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        log_info "Installing git..."
        sudo dnf install -y git
    fi
    
    log_info "Prerequisites check completed"
}

setup_directories() {
    log_info "Setting up directory structure..."
    
    sudo mkdir -p "$INSTALL_DIR"/{logs,secrets,backups}
    sudo mkdir -p "$QUADLET_DIR"
    
    # Set ownership for the main install directory
    sudo chown -R "$USER:$USER" "$INSTALL_DIR"
    
    # Set permissions
    chmod 755 "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR/secrets"
    chmod 755 "$INSTALL_DIR/logs"
    chmod 755 "$INSTALL_DIR/backups"
    
    log_info "Directory structure created (repo directory will be created during git clone)"
}

setup_ssh_authentication() {
    log_info "Setting up SSH authentication for Git..."
    
    local ssh_dir="/root/.ssh"
    local ssh_key="$ssh_dir/gitops_ed25519"
    local ssh_config="$ssh_dir/config"
    
    # Create SSH directory if it doesn't exist
    sudo mkdir -p "$ssh_dir"
    sudo chmod 700 "$ssh_dir"
    
    # Generate SSH key if it doesn't exist
    if [[ ! -f "$ssh_key" ]]; then
        log_info "Generating SSH key for GitOps..."
        sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "gitops@$(hostname)"
        sudo chmod 600 "$ssh_key"
        sudo chmod 644 "$ssh_key.pub"
        
        log_info "SSH key generated: $ssh_key.pub"
    else
        log_info "SSH key already exists: $ssh_key"
        log_info "Removing existing key and generating new one..."
        sudo rm -f "$ssh_key" "$ssh_key.pub"
        sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "gitops@$(hostname)"
        sudo chmod 600 "$ssh_key"
        sudo chmod 644 "$ssh_key.pub"
        log_info "New SSH key generated: $ssh_key.pub"
    fi
    # Always show the SSH key and setup instructions (whether new or existing)
    echo
    echo "=== SSH KEY FOR GITHUB ==="
    echo "Add this SSH public key to your GitHub repository as a deploy key:"
    echo
    sudo cat "$ssh_key.pub"
    echo
    echo "Steps:"
    echo "1. Go to your GitHub repo → Settings → Deploy keys"
    echo "2. Click 'Add deploy key'"
    echo "3. Give it a title like 'GitOps Server'"
    echo "4. Paste the above public key"
    echo "5. Do NOT check 'Allow write access' (read-only is safer)"
    echo "6. Click 'Add key'"
    echo
    
    # Auto-detect if running interactively or from pipe
    if [ -t 0 ]; then
        # Running interactively - can read user input
        read -p "Press Enter after adding the deploy key to GitHub..."
    else
        # Running from pipe (curl | bash) - use simple approach
        echo "Script is running from pipe. Waiting 90 seconds for you to add the SSH key..."
        echo "This should be enough time to add the key to GitHub."
        echo
        
        # Count down so user knows what's happening
        for i in {90..1}; do
            if [ $((i % 10)) -eq 0 ]; then
                echo "Waiting... $i seconds remaining"
            fi
            sleep 1
        done
        
        echo "Continuing with setup..."
    fi
    
    # Create/update SSH config for GitHub
    sudo tee "$ssh_config" > /dev/null <<EOF
# GitOps SSH configuration
Host github.com
    HostName github.com
    User git
    IdentityFile $ssh_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    
    sudo chmod 600 "$ssh_config"
}

convert_repo_url_to_ssh() {
    # Convert HTTPS GitHub URLs to SSH format
    if [[ "$REPO_URL" =~ ^https://github\.com/(.+)\.git$ ]]; then
        REPO_URL="git@github.com:${BASH_REMATCH[1]}.git"
        log_info "Converted repository URL to SSH format: $REPO_URL"
    elif [[ "$REPO_URL" =~ ^https://github\.com/(.+)$ ]]; then
        REPO_URL="git@github.com:${BASH_REMATCH[1]}.git"
        log_info "Converted repository URL to SSH format: $REPO_URL"
    fi
}

clone_repository() {
    log_info "Cloning repository..."
    
    # Test SSH connection first
    local ssh_test_result
    ssh_test_result=$(sudo ssh -T git@github.com 2>&1 || true)
    
    if echo "$ssh_test_result" | grep -q "You've successfully authenticated, but GitHub does not provide shell access"; then
        log_info "SSH connection to GitHub verified successfully"
    else
        log_warn "SSH connection to GitHub failed. Please verify:"
        log_warn "1. The deploy key is added to your repository"
        log_warn "2. Your repository URL is correct"
        log_warn "3. The repository exists and is accessible"
        echo
        echo "Testing SSH connection manually:"
        echo "$ssh_test_result"
        echo
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "SSH authentication failed. Please fix the issue and try again."
        fi
    fi
    
    if [[ -d "$INSTALL_DIR/repo/.git" ]]; then
        log_info "Repository directory exists, updating..."
        cd "$INSTALL_DIR/repo"
        # Ensure proper ownership before git operations
        sudo chown -R root:root "$INSTALL_DIR/repo"
        sudo git pull origin main
    else
        log_info "Cloning repository: $REPO_URL"
        # Remove any existing directory that's not a git repo
        if [[ -d "$INSTALL_DIR/repo" ]]; then
            sudo rm -rf "$INSTALL_DIR/repo"
        fi
        sudo git clone "$REPO_URL" "$INSTALL_DIR/repo"
    fi
    
    # Set proper ownership for the repo directory to root (service user)
    sudo chown -R root:root "$INSTALL_DIR/repo"
    sudo chmod 755 "$INSTALL_DIR/repo"
    
    # Set git configuration for the system service
    cd "$INSTALL_DIR/repo"
    sudo git config user.name "GitOps System"
    sudo git config user.email "gitops@$(hostname)"
    
    # Disable filemode tracking to prevent permission conflicts
    # Scripts will get execute permissions from git hooks and explicit chmod
    sudo git config core.filemode false
    
    # Disable git hooks during service operations to prevent permission conflicts
    # Hooks are designed for development workflow, not production sync
    sudo git config core.hooksPath /dev/null
    
    # Ensure scripts are executable after clone/update
    sudo find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;
    
    log_info "Repository cloned/updated"
}

enable_podman_socket() {
    log_info "Enabling Podman socket for system services..."
    
    # Enable podman socket for root (system services)
    sudo systemctl enable --now podman.socket
    
    # Enable user lingering for the management user
    sudo loginctl enable-linger "$USER"
    
    log_info "Podman socket enabled"
}

install_management_services() {
    log_info "Installing management services..."
    
    # Copy service files
    sudo cp "$INSTALL_DIR/repo/services/"*.service "$SYSTEMD_DIR/"
    sudo cp "$INSTALL_DIR/repo/services/"*.timer "$SYSTEMD_DIR/"
    
    # Create configuration file
    sudo tee /etc/pine-ridge-podman.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
INSTALL_DIR=$INSTALL_DIR
QUADLET_DIR=$QUADLET_DIR
MANAGEMENT_USER=$USER
EOF
    
    # Reload systemd and enable services
    sudo systemctl daemon-reload
    
    # Enable services for boot
    sudo systemctl enable --now gitops-sync.timer
    sudo systemctl enable quadlet-deploy.service
    
    # Verify services are enabled
    if sudo systemctl is-enabled --quiet gitops-sync.timer; then
        log_info "GitOps sync timer enabled successfully"
    else
        log_warn "Failed to enable GitOps sync timer"
    fi
    
    if sudo systemctl is-enabled --quiet quadlet-deploy.service; then
        log_info "Quadlet deploy service enabled successfully"  
    else
        log_warn "Failed to enable quadlet deploy service"
    fi
    
    log_info "Management services installed"
}

configure_selinux() {
    log_info "Configuring SELinux contexts..."
    
    # Set appropriate SELinux contexts
    sudo restorecon -R "$INSTALL_DIR"
    sudo setsebool -P container_manage_cgroup true
    
    log_info "SELinux configured"
}

initial_deployment() {
    log_info "Performing initial quadlet deployment..."
    
    if [[ -x "$INSTALL_DIR/repo/scripts/deploy-quadlets.sh" ]]; then
        sudo "$INSTALL_DIR/repo/scripts/deploy-quadlets.sh"
    else
        log_warn "Deploy script not found, skipping initial deployment"
    fi
}

start_services() {
    log_info "Verifying management services..."
    
    # Verify timer status
    if sudo systemctl is-active --quiet gitops-sync.timer; then
        log_info "GitOps sync timer is running successfully"
        sudo systemctl status gitops-sync.timer --no-pager --lines=5
    else
        log_warn "GitOps sync timer is not running, attempting to start..."
        sudo systemctl start gitops-sync.timer
    fi
    
    # Show timer schedule
    sudo systemctl list-timers gitops-sync.timer --no-pager
    
    log_info "Services verification completed"
}

show_status() {
    log_info "Installation completed successfully!"
    echo
    echo "=== Status ==="
    echo "Install directory: $INSTALL_DIR"
    echo "Quadlet directory: $QUADLET_DIR"
    echo "Repository: $REPO_URL"
    echo
    echo "=== Active Services ==="
    sudo systemctl list-timers gitops-sync.timer --no-pager
    echo
    echo "=== Next Steps ==="
    echo "1. Review configuration in /etc/podman-gitops.conf"
    echo "2. Add secrets to $INSTALL_DIR/secrets/ if needed"
    echo "3. Monitor logs: journalctl -u gitops-sync.service -f"
    echo "4. Check quadlet status: systemctl --user status"
}

main() {
    log_info "Starting Podman GitOps bootstrap setup..."
    
    check_prerequisites
    setup_directories
    convert_repo_url_to_ssh
    setup_ssh_authentication
    clone_repository
    enable_podman_socket
    install_management_services
    configure_selinux
    initial_deployment
    start_services
    show_status
    
    log_info "Bootstrap setup completed successfully"
    echo
    echo "Setup log_info saved to: $LOG_FILE"
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [REPO_URL]"
        echo "Example: $0 https://github.com/yourusername/pine-ridge-podman.git"
        exit 0
        ;;
    *)
        if [[ -n "${1:-}" ]]; then
            REPO_URL="$1"
        fi
        ;;
esac

main "$@"