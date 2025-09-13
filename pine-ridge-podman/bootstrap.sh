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
    log "Checking prerequisites..."
    
    # Check if running as non-root with sudo
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Run as a user with sudo privileges."
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        error "This script requires sudo privileges. Please run with a user in the wheel group."
    fi
    
    # Check if git is installed, install if missing
    if ! command -v git &> /dev/null; then
        log "Git not found, installing..."
        sudo dnf install -y git
    else
        log "Git is already installed"
    fi
    
    # Check if curl is installed (usually present but good to verify)
    if ! command -v curl &> /dev/null; then
        log "curl not found, installing..."
        sudo dnf install -y curl
    fi
    
    log "Prerequisites check completed"
}

install_ansible() {
    log "Installing Ansible and Podman..."
    
    # Install Ansible, Podman and required collections
    sudo dnf install -y ansible-core python3-pip podman podman-compose yq
    
    # Install common collections system-wide (for root user since ansible runs as root)
    log "Installing Ansible collections system-wide..."
    sudo ansible-galaxy collection install community.general
    sudo ansible-galaxy collection install ansible.posix
    sudo ansible-galaxy collection install containers.podman
    
    # Also install for current user in case needed for local testing
    ansible-galaxy collection install community.general 2>/dev/null || true
    ansible-galaxy collection install ansible.posix 2>/dev/null || true
    ansible-galaxy collection install containers.podman 2>/dev/null || true
    
    # Verify collections are installed
    log "Verifying Ansible collections installation..."
    for collection in "ansible.posix" "community.general" "containers.podman"; do
        if sudo ansible-galaxy collection list | grep -q "$collection"; then
            log "✓ $collection collection installed successfully"
        else
            log "⚠ $collection collection not found, retrying installation..."
            sudo ansible-galaxy collection install "$collection" --force
        fi
    done
    
    # Enable podman socket
    log "Enabling podman socket..."
    sudo systemctl enable --now podman.socket
    
    log "Ansible and Podman installed successfully"
}

setup_ssh_auth() {
    log "Setting up SSH authentication..."
    
    local ssh_dir="/root/.ssh"
    local ssh_key="$ssh_dir/podman_gitops_ed25519"
    local ssh_config="$ssh_dir/config"
    
    # Create SSH directory if it doesn't exist
    sudo mkdir -p "$ssh_dir"
    sudo chmod 700 "$ssh_dir"
    
    # Always remove existing SSH keys to ensure clean generation
    log "Removing any existing SSH keys..."
    sudo rm -f "$ssh_key" "$ssh_key.pub"
    
    # Verify removal worked
    if [[ -f "$ssh_key" ]]; then
        log "Warning: SSH key file still exists after removal attempt"
        sudo chmod 666 "$ssh_key" 2>/dev/null || true
        sudo rm -f "$ssh_key"
    fi
    
    log "Generating SSH key for GitOps..."
    # Use yes to automatically answer prompts and redirect to avoid issues
    echo | sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "podman-gitops@$(hostname)" 2>/dev/null || \
    sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "podman-gitops@$(hostname)" < /dev/null
    
    sudo chmod 600 "$ssh_key"
    sudo chmod 644 "$ssh_key.pub"
    
    log "SSH key generated: $ssh_key.pub"
    
    # Always show the SSH key and setup instructions
    echo
    echo "=== SSH KEY FOR GITHUB ==="
    echo "Add this SSH public key to your GitHub repository as a deploy key:"
    echo
    sudo cat "$ssh_key.pub"
    echo
    echo "Steps:"
    echo "1. Go to your GitHub repo → Settings → Deploy keys"
    echo "2. Click 'Add deploy key'"
    echo "3. Give it a title like 'Podman GitOps Server'"
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
# Podman GitOps SSH configuration
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
        log "Converted repository URL to SSH format: $REPO_URL"
    elif [[ "$REPO_URL" =~ ^https://github\.com/(.+)$ ]]; then
        REPO_URL="git@github.com:${BASH_REMATCH[1]}.git"
        log "Converted repository URL to SSH format: $REPO_URL"
    fi
}

clone_and_run() {
    log "Cloning repository..."
    
    # Test SSH connection first
    local ssh_test_result
    ssh_test_result=$(sudo ssh -T git@github.com 2>&1 || true)
    
    if echo "$ssh_test_result" | grep -q "You've successfully authenticated, but GitHub does not provide shell access"; then
        log "SSH connection to GitHub verified successfully"
    else
        log "SSH connection to GitHub failed. Please verify:"
        log "1. The deploy key is added to your repository"
        log "2. Your repository URL is correct"
        log "3. The repository exists and is accessible"
        echo
        echo "Testing SSH connection manually:"
        echo "$ssh_test_result"
        echo
        
        # Auto-detect if running interactively or from pipe for error handling
        if [ -t 0 ]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error "SSH authentication failed. Please fix the issue and try again."
            fi
        else
            log "Script running from pipe - continuing despite SSH warning..."
            log "If deployment fails, verify SSH key setup and try again"
        fi
    fi
    
    # Create install directory if it doesn't exist
    sudo mkdir -p "$INSTALL_DIR"
    
    # Handle existing repository more robustly
    if [[ -d "$INSTALL_DIR/repo" ]]; then
        if [[ -d "$INSTALL_DIR/repo/.git" ]]; then
            log "Repository directory exists, updating..."
            cd "$INSTALL_DIR/repo"
            
            # Ensure proper ownership before git operations
            sudo chown -R root:root "$INSTALL_DIR/repo"
            
            # Check if we can access the remote
            if sudo git remote get-url origin >/dev/null 2>&1; then
                current_remote=$(sudo git remote get-url origin)
                if [[ "$current_remote" == "$REPO_URL" ]]; then
                    log "Updating existing repository..."
                    sudo git fetch origin
                    sudo git reset --hard "origin/$GIT_BRANCH" 2>/dev/null || {
                        log "Failed to reset to remote branch $GIT_BRANCH, re-cloning..."
                        cd /
                        sudo rm -rf "$INSTALL_DIR/repo"
                        sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
                    }
                else
                    log "Repository URL mismatch, re-cloning..."
                    log "Current: $current_remote"
                    log "Expected: $REPO_URL"
                    cd /
                    sudo rm -rf "$INSTALL_DIR/repo"
                    sudo git clone "$REPO_URL" "$INSTALL_DIR/repo"
                fi
            else
                log "Cannot access remote, re-cloning..."
                cd /
                sudo rm -rf "$INSTALL_DIR/repo"
                sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
            fi
        else
            log "Directory exists but is not a git repository, removing and cloning..."
            sudo rm -rf "$INSTALL_DIR/repo"
            sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
        fi
    else
        log "Cloning repository: $REPO_URL"
        sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
    fi
    
    cd "$INSTALL_DIR/repo"
    
    # Set git configuration for branch tracking
    sudo git config user.name "Podman GitOps System"
    sudo git config user.email "podman-gitops@$(hostname)"
    
    # Disable filemode tracking to prevent permission conflicts
    sudo git config core.filemode false
    
    # Disable git hooks during service operations to prevent permission conflicts
    sudo git config core.hooksPath /dev/null
    
    # Ensure scripts are executable after clone/update
    sudo find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;
    
    log "Repository cloned successfully"
}

run_initial_deployment() {
    log "Running initial Podman configuration..."
    
    cd "$INSTALL_DIR/repo/ansible"
    
    # Test ansible configuration first
    log "Testing Ansible configuration..."
    if ! ansible --version >/dev/null 2>&1; then
        error "Ansible is not properly installed"
    fi
    
    # Install any additional requirements from the repo
    if [[ -f "ansible/requirements.yml" ]]; then
        log "Installing Ansible collections from repository requirements..."
        sudo ansible-galaxy collection install -r ansible/requirements.yml
    elif [[ -f "requirements.yml" ]]; then
        log "Installing Ansible requirements from repository..."
        sudo ansible-galaxy install -r requirements.yml
    fi
    
    # Run the playbook
    log "Running Podman configuration playbook..."
    if sudo ansible-playbook site.yml; then
        log "Initial Podman configuration completed successfully"
    else
        log "Initial configuration failed - this may be normal for first setup"
        log "You can run 'sudo ansible-playbook site.yml' manually after setup"
    fi
}

setup_ansible_gitops() {
    log "Setting up Ansible GitOps service..."
    
    # Create scripts directory if it doesn't exist
    sudo mkdir -p "$INSTALL_DIR/repo/scripts"
    
    # Create configuration file for branch tracking
    sudo tee /etc/pine-ridge-podman.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
QUADLET_DIR=/etc/containers/systemd
MANAGEMENT_USER=$USER
EOF

    # Generate sync script from comprehensive template
    log "Generating sync script from template..."

    sudo tee "$INSTALL_DIR/repo/scripts/sync-repo-ansible.sh" > /dev/null <<'EOF'
#!/bin/bash
# scripts/sync-repo-ansible.sh - GitOps repository synchronization with branch support
# Generated from template by Pine Ridge Bootstrap
# Template version: 1.0.0 (Podman)

set -euo pipefail

# Source configuration
source /etc/pine-ridge-podman.conf

LOG_FILE="$INSTALL_DIR/logs/sync.log"
LOCK_FILE="/var/run/podman-sync.lock"

# Create logs directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Another sync process is running (PID: $pid). Exiting."
            exit 0
        else
            log "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

check_git_changes() {
    cd "$INSTALL_DIR/repo"

    # Fix git dubious ownership issue
    git config --global --add safe.directory "$INSTALL_DIR/repo"

    # Set SSH environment for git operations
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/podman_gitops_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    # Check current branch
    local current_branch
    current_branch=$(git branch --show-current)

    if [[ "$current_branch" != "$GIT_BRANCH" ]]; then
        log "Branch change detected: $current_branch -> $GIT_BRANCH"
        git fetch origin "$GIT_BRANCH"
        git checkout "$GIT_BRANCH"
        git reset --hard "origin/$GIT_BRANCH"
        return 0
    fi

    # Fetch latest changes for current branch
    if ! git fetch origin "$GIT_BRANCH"; then
        error "Failed to fetch repository changes. Check SSH key and repository access."
    fi

    # Check if there are new commits
    local local_hash
    local remote_hash

    local_hash=$(git rev-parse HEAD)
    remote_hash=$(git rev-parse "origin/$GIT_BRANCH")

    if [[ "$local_hash" == "$remote_hash" ]]; then
        log "Repository is up to date on branch $GIT_BRANCH"
        return 1
    else
        log "New changes detected on $GIT_BRANCH: $local_hash -> $remote_hash"
        return 0
    fi
}

sync_repository() {
    cd "$INSTALL_DIR/repo"

    log "Pulling latest changes from branch $GIT_BRANCH..."

    # Set SSH environment for git operations
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/podman_gitops_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if ! git pull origin "$GIT_BRANCH"; then
        error "Failed to pull repository changes. Check SSH key and repository access."
    fi

    # Ensure scripts are executable after sync
    find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;

    # Validate Podman repository structure
    if [[ ! -d "quadlets" ]]; then
        error "Invalid repository structure: quadlets directory not found"
    fi

    if [[ ! -d "ansible" ]]; then
        log "Warning: ansible directory not found, some automation may be unavailable"
    fi

    log "Repository synchronized successfully on branch $GIT_BRANCH"
}

trigger_deployment() {
    log "Triggering quadlet deployment..."

    if systemctl is-active --quiet quadlet-deploy.service 2>/dev/null; then
        log "Deployment service is already running, skipping trigger"
        return 0
    fi

    # Check if deployment service exists
    if ! systemctl list-unit-files quadlet-deploy.service >/dev/null 2>&1; then
        log "Deployment service not found, skipping deployment trigger"
        return 0
    fi

    # Add better error handling for deployment trigger with timeout
    local deploy_timeout=30  # 30 seconds to start the service

    if timeout "$deploy_timeout" systemctl start quadlet-deploy.service 2>/dev/null; then
        log "Deployment triggered successfully"

        # Optional: Wait a bit to see if deployment starts properly
        sleep 2
        if systemctl is-active --quiet quadlet-deploy.service 2>/dev/null; then
            log "Deployment service is running"
        else
            log "Warning: Deployment service started but is no longer active"
        fi
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log "Warning: Failed to trigger deployment service (timeout after ${deploy_timeout}s)"
        else
            log "Warning: Failed to trigger deployment service (exit code: $exit_code)"
        fi
        # Don't exit here - this shouldn't cause the sync to fail completely
        return 1
    fi
}

main() {
    log "Starting Podman GitOps sync process for branch $GIT_BRANCH..."

    acquire_lock

    if check_git_changes; then
        sync_repository
        
        # Execute Podman-specific post-sync actions
        if trigger_deployment; then
            log "Deployment trigger completed successfully"
        else
            log "Warning: Deployment trigger failed - this will be retried on next sync"
        fi
        
        log "Sync completed successfully, Ansible will run next"
    else
        log "No changes to sync"
    fi
}

main "$@"
EOF

    sudo chmod +x "$INSTALL_DIR/repo/scripts/sync-repo-ansible.sh"
    log "✓ Generated comprehensive sync script for Podman"

    # Create systemd service for Ansible runs
    sudo tee /etc/systemd/system/podman-ansible.service > /dev/null <<'EOF'
[Unit]
Description=Podman Ansible Configuration
After=network-online.target podman.socket
Wants=network-online.target
Requires=podman.socket

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-podman.conf
WorkingDirectory=/opt/pine-ridge-podman/repo/ansible
ExecStartPre=/opt/pine-ridge-podman/repo/scripts/sync-repo-ansible.sh
ExecStart=/usr/bin/ansible-playbook site.yml
StandardOutput=journal
StandardError=journal
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

    # Create timer for Podman config (less frequent than WAF)
    sudo tee /etc/systemd/system/podman-ansible.timer > /dev/null <<'EOF'
[Unit]
Description=Podman Ansible Configuration Timer
Requires=podman-ansible.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now podman-ansible.timer
    
    log "GitOps services configured and started"
}

show_completion_status() {
    log "Podman bootstrap completed successfully!"
    
    echo ""
    echo "=== SETUP COMPLETE ==="
    echo "✓ Ansible and Podman installed and configured"
    echo "✓ Repository cloned and configured"
    echo "✓ GitOps services enabled"
    echo "✓ Podman socket enabled"
    echo ""
    
    echo "=== NEXT STEPS ==="
    echo "1. Your Podman setup will auto-update from Git every 5 minutes"
    echo "2. Monitor services: journalctl -u podman-ansible.service -f"
    echo "3. Check timer status: systemctl list-timers podman-ansible.timer"
    echo "4. Manual deployment: cd $INSTALL_DIR/repo/ansible && sudo ansible-playbook site.yml"
    echo "5. Add quadlets to $INSTALL_DIR/repo/quadlets/ and push to Git"
    echo ""
    echo "=== SERVICE STATUS ==="
    sudo systemctl status podman-ansible.timer --no-pager --lines=5 || true
    echo ""
}

main() {
    log "Starting Podman Ansible bootstrap..."
    log "Repository: $REPO_URL"
    log "Branch: $GIT_BRANCH"
    log "FORCE_INTERACTIVE: ${FORCE_INTERACTIVE:-false}"
    
    check_prerequisites
    install_ansible
    convert_repo_url_to_ssh
    setup_ssh_auth
    clone_and_run
    run_initial_deployment      # Test deployment
    setup_ansible_gitops       # Enable ongoing automation
    show_completion_status
    
    log "Podman bootstrap completed successfully"
    echo "Bootstrap log saved to: $LOG_FILE"
}

# Handle command line arguments
FORCE_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS] [--repo REPO_URL] [--branch BRANCH]"
            echo "Options:"
            echo "  --interactive, -i          Force interactive mode (for compatibility)"
            echo "  --repo REPO_URL           Repository URL (default: https://github.com/yourusername/pine-ridge-podman.git)"
            echo "  --branch BRANCH           Git branch to use (default: main)"
            echo "  --help, -h                Show this help message"
            echo ""
            echo "Legacy positional arguments are still supported:"
            echo "  $0 [REPO_URL] [BRANCH]"
            echo ""
            echo "Examples:"
            echo "  $0 --repo https://github.com/yourusername/pine-ridge-podman.git"
            echo "  $0 --repo https://github.com/yourusername/pine-ridge-podman.git --branch feat/moving-to-ansible"
            echo "  $0 https://github.com/yourusername/pine-ridge-podman.git develop  # legacy format"
            exit 0
            ;;
        --interactive|-i)
            FORCE_INTERACTIVE=true
            shift
            ;;
        --repo)
            if [[ -n "${2:-}" ]]; then
                REPO_URL="$2"
                shift 2
            else
                echo "Error: --repo requires a repository URL"
                exit 1
            fi
            ;;
        --branch)
            if [[ -n "${2:-}" ]]; then
                GIT_BRANCH="$2"
                shift 2
            else
                echo "Error: --branch requires a branch name"
                exit 1
            fi
            ;;
        --*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            # Handle legacy positional arguments
            if [[ -n "${1:-}" ]] && [[ -z "${REPO_URL_SET:-}" ]]; then
                REPO_URL="$1"
                REPO_URL_SET=true
                shift
            elif [[ -n "${1:-}" ]] && [[ -z "${GIT_BRANCH_SET:-}" ]]; then
                GIT_BRANCH="$1"
                GIT_BRANCH_SET=true
                shift
            else
                echo "Unexpected argument: $1"
                exit 1
            fi
            ;;
    esac
done

main "$@"
