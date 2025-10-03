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
    
    # Install Ansible, Podman and required packages
    sudo dnf install -y ansible-core python3-pip podman podman-compose yq
    
    # Set environment to avoid permission issues
    export ANSIBLE_LOG_PATH=""  # Disable Ansible logging
    export ANSIBLE_HOST_KEY_CHECKING=False
    
    # Install minimal core collections needed for bootstrap
    log "Installing core Ansible collections..."
    sudo -E ansible-galaxy collection install community.general --force
    sudo -E ansible-galaxy collection install ansible.posix --force
    
    # Note: All required collections will be installed from requirements.yml after repo clone
    
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
    
    # Set Ansible environment to avoid permission issues
    export ANSIBLE_LOG_PATH=""  # Disable Ansible logging to avoid permission conflicts
    export ANSIBLE_HOST_KEY_CHECKING=False
    export ANSIBLE_STDOUT_CALLBACK=default
    
    # Create Ansible log directory with proper permissions (optional)
    sudo mkdir -p /var/log/ansible
    sudo chmod 755 /var/log/ansible
    sudo chown root:root /var/log/ansible
    
    # Install any additional requirements from the repo
    if [[ -f "ansible/requirements.yml" ]]; then
        log "Installing Ansible collections from repository requirements..."
        sudo -E ansible-galaxy collection install -r ansible/requirements.yml --force
        
        # Verify critical collections are installed
        log "Verifying required collections installation..."
        for collection in "community.crypto" "containers.podman"; do
            if sudo -E ansible-galaxy collection list | grep -q "$collection"; then
                log "✓ $collection collection installed successfully"
            else
                log "⚠ $collection collection not found after requirements install"
            fi
        done
    elif [[ -f "requirements.yml" ]]; then
        log "Installing Ansible collections from repository..."
        sudo -E ansible-galaxy collection install -r requirements.yml --force
    else
        log "No requirements.yml found - skipping additional collection installation"
    fi
    
    # Run the bootstrap playbook
    log "Running initial Podman bootstrap playbook..."
    if sudo -E ansible-playbook playbooks/bootstrap.yml; then
        log "Initial bootstrap configuration completed successfully"
    else
        log "Initial bootstrap failed - this may be normal for first setup"
        log "You can run 'sudo ansible-playbook playbooks/bootstrap.yml' manually after setup"
    fi
}

setup_ansible_gitops() {
    log "Setting up Pine Ridge GitOps automation chain..."
    
    # Create scripts directory if it doesn't exist
    sudo mkdir -p "$INSTALL_DIR/repo/scripts"
    sudo mkdir -p "$INSTALL_DIR/logs"
    
    # Create configuration file for branch tracking
    sudo tee /etc/pine-ridge-podman.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
MANAGEMENT_USER=$USER
EOF

    # Create git sync script that chains to service deployment
    log "Creating git sync script with service deployment chaining..."

    sudo tee "$INSTALL_DIR/repo/scripts/git-sync.sh" > /dev/null <<'EOF'
#!/bin/bash
# scripts/git-sync.sh - Git sync with service deployment chaining
# Part of Pine Ridge systemd automation architecture

set -euo pipefail

# Source configuration
source /etc/pine-ridge-podman.conf

LOG_FILE="$INSTALL_DIR/logs/git-sync.log"
LOCK_FILE="/var/run/pine-ridge-git-sync.lock"

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
            log "Another git sync process is running (PID: $pid). Exiting."
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

    # Validate ansible directory exists
    if [[ ! -d "ansible" ]]; then
        error "Invalid repository structure: ansible directory not found"
    fi

    log "Repository synchronized successfully on branch $GIT_BRANCH"
}

trigger_service_deployment() {
    log "Triggering service deployment via systemd..."

    # Check if emergency mode is active
    if [[ -f "$INSTALL_DIR/.emergency-mode" ]]; then
        log "Emergency mode active - skipping service deployment"
        return 0
    fi

    # Chain to service deployment
    if systemctl is-active --quiet pine-ridge-service-deployment.service 2>/dev/null; then
        log "Service deployment already running, skipping trigger"
        return 0
    fi

    # Trigger service deployment
    local deploy_timeout=60  # 60 seconds for service deployment

    if timeout "$deploy_timeout" systemctl start pine-ridge-service-deployment.service 2>/dev/null; then
        log "Service deployment triggered successfully"
        
        # Wait a bit to see if deployment starts properly
        sleep 2
        if systemctl is-active --quiet pine-ridge-service-deployment.service 2>/dev/null; then
            log "Service deployment is running"
        else
            log "Service deployment completed quickly"
        fi
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log "Warning: Service deployment timeout after ${deploy_timeout}s"
        else
            log "Warning: Failed to trigger service deployment (exit code: $exit_code)"
        fi
        return 1
    fi
}

main() {
    log "Starting Pine Ridge git sync process for branch $GIT_BRANCH..."

    acquire_lock

    if check_git_changes; then
        sync_repository
        
        # Chain to service deployment
        if trigger_service_deployment; then
            log "Service deployment chain completed successfully"
        else
            log "Warning: Service deployment chain failed - will retry on next sync"
        fi
        
        log "Git sync with service deployment chain completed"
    else
        log "No changes to sync"
    fi
}

main "$@"
EOF

    sudo chmod +x "$INSTALL_DIR/repo/scripts/git-sync.sh"
    log "✓ Created git sync script with service deployment chaining"

    # Create systemd service for git sync (triggered externally, e.g., by webhook or timer)
    sudo tee /etc/systemd/system/pine-ridge-git-sync.service > /dev/null <<'EOF'
[Unit]
Description=Pine Ridge Git Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-podman.conf
ExecStart=/opt/pine-ridge-podman/repo/scripts/git-sync.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

    # Create timer for regular git sync (every 5-10 minutes)
    sudo tee /etc/systemd/system/pine-ridge-git-sync.timer > /dev/null <<'EOF'
[Unit]
Description=Pine Ridge Git Sync Timer
Requires=pine-ridge-git-sync.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=7min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now pine-ridge-git-sync.timer
    
    log "Pine Ridge GitOps automation chain configured and started"
}

show_completion_status() {
    log "Pine Ridge Podman bootstrap completed successfully!"
    
    echo ""
    echo "=== SETUP COMPLETE ==="
    echo "✓ Ansible and Podman installed and configured"
    echo "✓ Repository cloned and configured"
    echo "✓ Pine Ridge automation chain enabled"
    echo "✓ Systemd services and timers configured"
    echo ""
    
    echo "=== AUTOMATION ARCHITECTURE ==="
    echo "🔄 Git Sync: Every 7 minutes (pine-ridge-git-sync.timer)"
    echo "⚡ Service Deployment: Triggered by git changes (pine-ridge-service-deployment.service)"  
    echo "🔧 Infrastructure Check: Daily maintenance (pine-ridge-infrastructure-check.timer)"
    echo ""
    
    echo "=== MONITORING COMMANDS ==="
    echo "• Git sync status: journalctl -u pine-ridge-git-sync.service -f"
    echo "• Service deployment: journalctl -u pine-ridge-service-deployment.service -f"
    echo "• Infrastructure check: journalctl -u pine-ridge-infrastructure-check.service -f"
    echo "• Timer status: systemctl list-timers pine-ridge-*"
    echo "• Manual deployment: cd $INSTALL_DIR/repo/ansible && sudo ansible-playbook playbooks/service-deployment.yml"
    echo ""
    
    echo "=== MANAGEMENT COMMANDS ==="
    echo "• Central management: sudo $INSTALL_DIR/repo/scripts/pine-ridge-manage.sh [status|deploy|stop|emergency]"
    echo "• Full rebuild: sudo ansible-playbook playbooks/full-deployment.yml"
    echo "• Emergency stop: sudo ansible-playbook playbooks/emergency-stop.yml"
    echo ""
    
    echo "=== SERVICE STATUS ==="
    sudo systemctl status pine-ridge-git-sync.timer --no-pager --lines=3 || true
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
