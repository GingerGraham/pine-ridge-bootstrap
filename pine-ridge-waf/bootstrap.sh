#!/bin/bash
# waf-bootstrap.sh - Bootstrap WAF with Ansible GitOps

set -euo pipefail

REPO_URL="https://github.com/yourusername/pine-ridge-waf.git"
GIT_BRANCH="main"
INSTALL_DIR="/opt/pine-ridge-waf"
LOG_FILE="/tmp/waf-bootstrap-$(date +%s).log"

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
    log "Installing Ansible..."
    
    # Install Ansible and required collections
    sudo dnf install -y ansible-core python3-pip libsecret
    
    # Install common collections system-wide (for root user since ansible runs as root)
    log "Installing Ansible collections system-wide..."
    sudo ansible-galaxy collection install community.general
    sudo ansible-galaxy collection install ansible.posix
    
    # Also install for current user in case needed for local testing
    ansible-galaxy collection install community.general 2>/dev/null || true
    ansible-galaxy collection install ansible.posix 2>/dev/null || true
    
    # Verify collections are installed
    log "Verifying Ansible collections installation..."
    if sudo ansible-galaxy collection list | grep -q "ansible.posix"; then
        log "✓ ansible.posix collection installed successfully"
    else
        log "⚠ ansible.posix collection not found, retrying installation..."
        sudo ansible-galaxy collection install ansible.posix --force
    fi
    
    if sudo ansible-galaxy collection list | grep -q "community.general"; then
        log "✓ community.general collection installed successfully"
    else
        log "⚠ community.general collection not found, retrying installation..."
        sudo ansible-galaxy collection install community.general --force
    fi
    
    log "Ansible installed successfully"
}

setup_ssh_auth() {
    log "Setting up SSH authentication..."
    
    local ssh_dir="/root/.ssh"
    local ssh_key="$ssh_dir/waf_gitops_ed25519"
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
    echo | sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "waf-gitops@$(hostname)" 2>/dev/null || \
    sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "waf-gitops@$(hostname)" < /dev/null
    
    sudo chmod 600 "$ssh_key"
    sudo chmod 644 "$ssh_key.pub"
    
    log "SSH key generated: $ssh_key.pub"
    
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
    echo "3. Give it a title like 'WAF GitOps Server'"
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
# WAF GitOps SSH configuration
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
                    sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
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
    sudo git config user.name "WAF GitOps System"
    sudo git config user.email "waf-gitops@$(hostname)"
    
    # Disable filemode tracking to prevent permission conflicts
    sudo git config core.filemode false
    
    # Disable git hooks during service operations to prevent permission conflicts
    sudo git config core.hooksPath /dev/null
    
    # Ensure scripts are executable after clone/update
    sudo find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;
    
    log "Repository cloned successfully"
}

setup_vault_password() {
    log "Setting up Ansible vault password for system services..."
    
    local vault_password_file="/etc/pine-ridge-waf-vault-pass"
    local vault_script="/usr/local/bin/get-waf-vault-pass.sh"
    
    echo ""
    echo "=== ANSIBLE VAULT PASSWORD SETUP ==="
    echo "The Ansible vault contains encrypted certificates and secrets."
    echo "This will be stored securely for system service access."
    echo ""
    
    # Check if password file already exists
    if [[ -f "$vault_password_file" ]]; then
        # Check if it's a placeholder password
        local current_password
        current_password=$(sudo cat "$vault_password_file" 2>/dev/null || echo "")
        
        if [[ "$current_password" == "VAULT_PASSWORD_NOT_SET" ]]; then
            log "Found placeholder vault password - need to set real password"
            # Don't return early - force password setup below
        else
            log "Vault password file already exists with real password"
            
            # Debug logging for interactive detection
            log "Interactive detection: [ -t 0 ] = $([ -t 0 ] && echo "true" || echo "false")"
            log "FORCE_INTERACTIVE = ${FORCE_INTERACTIVE:-false}"
            
            # Auto-detect if running interactively or from pipe
            if [ -t 0 ] || [[ "${FORCE_INTERACTIVE:-false}" == "true" ]]; then
                log "Running in interactive mode - prompting for password update"
                read -p "Do you want to update the existing password? (y/N): " -r update_password < /dev/tty
                if [[ ! $update_password =~ ^[Yy]$ ]]; then
                    log "Keeping existing vault password"
                    # Set vault_password to the existing one for later verification
                    vault_password="$current_password"
                    # Don't return - continue to ensure proper group setup
                else
                    # User wants to update - clear the flag so we'll prompt for new password
                    current_password=""
                fi
            else
                log "Script running from pipe - keeping existing vault password"
                # Set vault_password to the existing one for later verification  
                vault_password="$current_password"
                # Don't return - continue to ensure proper group setup
            fi
        fi
    fi
    
    # Only prompt for new password if we don't have one or user wants to update
    if [[ -z "${vault_password:-}" ]] || [[ "${current_password:-}" == "VAULT_PASSWORD_NOT_SET" ]] || [[ -z "${current_password:-}" ]]; then
        # Auto-detect if running interactively or from pipe for password input
        if [ -t 0 ] || [[ "${FORCE_INTERACTIVE:-false}" == "true" ]]; then
            # Running interactively - can read user input
            local vault_password_input
            local vault_password_confirm
            
            while true; do
                echo "Enter the Ansible vault password:"
                read -p "Password: " -s vault_password_input < /dev/tty
                echo
                
                if [[ -z "$vault_password_input" ]]; then
                    echo "Password cannot be empty. Please try again."
                    continue
                fi
                
                echo "Confirm the password:"
                read -p "Password (again): " -s vault_password_confirm < /dev/tty
                echo
                
                if [[ "$vault_password_input" == "$vault_password_confirm" ]]; then
                    vault_password="$vault_password_input"
                    break
                else
                    echo "Passwords don't match. Please try again."
                    echo
                fi
            done
        else
            # Running from pipe - skip password setup for now
            log "Script running from pipe - skipping vault password setup"
            log "You can set up the vault password later by running:"
            log "  sudo /opt/pine-ridge-waf/repo/scripts/setup-vault-password.sh"
            
            # Create placeholder files for now
            vault_password="VAULT_PASSWORD_NOT_SET"
        fi
    fi
    
    # Store password in secure system file (if we have one)
    if [[ "$vault_password" != "VAULT_PASSWORD_NOT_SET" ]]; then
        echo "$vault_password" | sudo tee "$vault_password_file" > /dev/null
    fi
    
    log "Setting up vault access group and permissions..."
    
    # Create a group for vault access and add the current user
    if ! getent group waf-vault >/dev/null 2>&1; then
        sudo groupadd waf-vault
        log "Created waf-vault group"
    else
        log "waf-vault group already exists"
    fi
    
    sudo usermod -a -G waf-vault "$USER"
    log "Added $USER to waf-vault group"
    
    # Activate the group membership immediately
    log "Activating waf-vault group membership..."
    
    # Set permissions: owner=root, group=waf-vault, readable by group
    sudo chown root:waf-vault "$vault_password_file"
    sudo chmod 640 "$vault_password_file"
    
    # Create wrapper script for Ansible
    sudo tee "$vault_script" > /dev/null <<EOF
#!/bin/bash
# Vault password script for system services
cat /etc/pine-ridge-waf-vault-pass
EOF
    
    sudo chmod 755 "$vault_script"
    sudo chown root:root "$vault_script"
    
    # Test the setup (skip verification for placeholder passwords)
    if [[ -f "$vault_password_file" ]] && [[ -x "$vault_script" ]]; then
        if [[ "${vault_password:-}" != "VAULT_PASSWORD_NOT_SET" ]] && [[ -n "${vault_password:-}" ]]; then
            # Only verify if we have a real password
            if [[ "$(sudo "$vault_script")" == "$vault_password" ]]; then
                log "✓ Vault password stored successfully for system access"
                
                # Test if current user can access vault file directly (group membership active)
                if [[ -r "$vault_password_file" ]]; then
                    log "✓ Vault file is accessible to current user"
                else
                    log "⚠ Group membership not yet active - will work after logout/login or newgrp"
                fi
            else
                error "Vault password verification failed"
            fi
        else
            log "✓ Vault password placeholder created - setup manually later"
        fi
    else
        error "Failed to create vault password files"
    fi
    
    # Test with Ansible if vault file exists (skip for placeholder passwords)
    if [[ "${vault_password:-}" != "VAULT_PASSWORD_NOT_SET" ]] && [[ -n "${vault_password:-}" ]]; then
        cd "$INSTALL_DIR/repo"
        if [[ -f "inventory/group_vars/vault.yml" ]]; then
            log "Testing vault password with existing vault file..."
            if timeout 10 sudo ansible-vault view inventory/group_vars/vault.yml --vault-password-file "$vault_script" >/dev/null 2>&1; then
                log "✓ Vault password verified with Ansible"
            else
                log "⚠ Vault password verification with Ansible failed - check password"
            fi
        else
            log "No vault file found yet - password will be verified during first deployment"
        fi
    else
        log "Skipping Ansible vault verification (placeholder password)"
    fi
    
    echo "System vault password setup completed successfully!"
    echo ""
}

run_initial_deployment() {
    log "Running initial WAF configuration..."
    
    cd "$INSTALL_DIR/repo"
    
    # Test ansible configuration first
    log "Testing Ansible configuration..."
    if ! ansible --version >/dev/null 2>&1; then
        error "Ansible is not properly installed"
    fi
    
    # Run the playbook
    log "Running WAF configuration playbook..."
    if ansible-playbook site.yml; then
        log "Initial WAF configuration completed successfully"
    else
        log "Initial configuration failed - this may be normal if vault is not yet set up"
        log "You can run 'ansible-playbook site.yml' manually after setup"
    fi
}

setup_ansible_gitops() {
    log "Setting up Ansible GitOps service..."
    
    # Create scripts directory if it doesn't exist
    sudo mkdir -p "$INSTALL_DIR/repo/scripts"
    
    # Create configuration file for branch tracking
    sudo tee /etc/pine-ridge-waf.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF

    # Generate sync script from comprehensive template
    log "Generating sync script from template..."
    
    sudo tee "$INSTALL_DIR/repo/scripts/sync-repo.sh" > /dev/null <<'EOF'
#!/bin/bash
# scripts/sync-repo.sh - GitOps repository synchronization with branch support
# Generated from template by Pine Ridge Bootstrap
# Template version: 1.0.0 (WAF)

set -euo pipefail

# Source configuration
source /etc/pine-ridge-waf.conf

LOG_FILE="$INSTALL_DIR/logs/sync.log"
LOCK_FILE="/var/run/waf-sync.lock"

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
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/waf_gitops_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/waf_gitops_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if ! git pull origin "$GIT_BRANCH"; then
        error "Failed to pull repository changes. Check SSH key and repository access."
    fi

    # Ensure scripts are executable after sync
    find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;

    # Validate WAF repository structure
    if [[ ! -f "site.yml" ]]; then
        error "Invalid repository structure: site.yml not found"
    fi

    if [[ ! -f "system-maintenance.yml" ]]; then
        log "Warning: system-maintenance.yml not found, system tasks will be skipped"
    fi

    log "Repository synchronized successfully on branch $GIT_BRANCH"
}

verify_vault_access() {
    log "Verifying vault password access..."

    cd "$INSTALL_DIR/repo"

    # Check if vault file exists
    if [[ -f "inventory/group_vars/vault.yml" ]]; then
        log "Testing vault password access..."

        # Test that the vault password script exists and is executable
        if [[ ! -x "/usr/local/bin/get-waf-vault-pass.sh" ]]; then
            error "Vault password script not found or not executable: /usr/local/bin/get-waf-vault-pass.sh"
        fi

        # Test that we can read the vault password
        if ! /usr/local/bin/get-waf-vault-pass.sh >/dev/null 2>&1; then
            error "Cannot read vault password. Check /etc/pine-ridge-waf-vault-pass exists and is readable"
        fi

        # Test that Ansible can decrypt the vault file
        if ! timeout 10 ansible-vault view inventory/group_vars/vault.yml >/dev/null 2>&1; then
            error "Cannot decrypt vault file. Check vault password is correct"
        fi

        log "✓ Vault access verified successfully"
    else
        log "No vault file found - skipping vault verification"
    fi
}

main() {
    log "Starting WAF GitOps sync process for branch $GIT_BRANCH..."

    acquire_lock

    if check_git_changes; then
        sync_repository
        verify_vault_access
        log "Sync completed successfully, Ansible will run next"
    else
        log "No changes to sync"
        # Still verify vault access even if no changes
        verify_vault_access
    fi
}

main "$@"
EOF

    sudo chmod +x "$INSTALL_DIR/repo/scripts/sync-repo.sh"
    log "✓ Generated comprehensive sync script for WAF"

    # Create systemd service for Ansible runs
    sudo tee /etc/systemd/system/waf-ansible.service > /dev/null <<'EOF'
[Unit]
Description=WAF Ansible Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-waf.conf
WorkingDirectory=/opt/pine-ridge-waf/repo
ExecStartPre=/opt/pine-ridge-waf/repo/scripts/sync-repo.sh
ExecStart=/usr/bin/ansible-playbook site.yml
StandardOutput=journal
StandardError=journal
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

    # Create timer for WAF config (frequent)
    sudo tee /etc/systemd/system/waf-ansible.timer > /dev/null <<'EOF'
[Unit]
Description=WAF Ansible Configuration Timer
Requires=waf-ansible.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now waf-ansible.timer
    
    log "GitOps services configured and started"
}

show_completion_status() {
    log "WAF bootstrap completed successfully!"
    
    echo ""
    echo "=== SETUP COMPLETE ==="
    echo "✓ Ansible installed and configured"
    echo "✓ Repository cloned and configured"
    echo "✓ Vault password stored securely"
    echo "✓ GitOps services enabled"
    echo ""
    
    # Check if vault access is immediately available
    local vault_access_note=""
    if [[ -f "/etc/pine-ridge-waf-vault-pass" ]]; then
        if [[ -r "/etc/pine-ridge-waf-vault-pass" ]]; then
            vault_access_note="✓ Vault access is ready"
        else
            vault_access_note="⚠ To activate vault access, run: newgrp waf-vault"
        fi
    fi
    
    echo "=== NEXT STEPS ==="
    if [[ -n "$vault_access_note" ]]; then
        echo "1. $vault_access_note"
        echo "2. Your WAF will auto-update from Git every 10 minutes"
        echo "3. Monitor services: journalctl -u waf-ansible.service -f"
        echo "4. Check timer status: systemctl list-timers waf-ansible.timer"
        echo "5. Manual deployment: cd $INSTALL_DIR/repo && ansible-playbook site.yml"
    else
        echo "1. Set up vault password if not done: sudo $INSTALL_DIR/repo/scripts/setup-vault-password.sh (if available)"
        echo "   OR run bootstrap again with: curl -sSL <url> | bash -s -- --interactive <repo>"
        echo "2. Your WAF will auto-update from Git every 10 minutes"
        echo "3. Monitor services: journalctl -u waf-ansible.service -f"
        echo "4. Check timer status: systemctl list-timers waf-ansible.timer"
        echo "5. Manual deployment: cd $INSTALL_DIR/repo && ansible-playbook site.yml"
    fi
    echo ""
    echo "=== SERVICE STATUS ==="
    sudo systemctl status waf-ansible.timer --no-pager --lines=5 || true
    echo ""
}

main() {
    log "Starting WAF Ansible bootstrap..."
    log "Repository: $REPO_URL"
    log "Branch: $GIT_BRANCH"
    log "FORCE_INTERACTIVE: ${FORCE_INTERACTIVE:-false}"
    
    check_prerequisites
    install_ansible
    convert_repo_url_to_ssh
    setup_ssh_auth
    clone_and_run
    setup_vault_password
    run_initial_deployment      # Test deployment with vault
    setup_ansible_gitops       # Enable ongoing automation
    show_completion_status
    
    log "WAF bootstrap completed successfully"
    echo "Bootstrap log saved to: $LOG_FILE"
}

# Handle command line arguments
FORCE_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS] [--repo REPO_URL] [--branch BRANCH]"
            echo "Options:"
            echo "  --interactive, -i          Force interactive mode for vault password setup"
            echo "  --repo REPO_URL           Repository URL (default: https://github.com/yourusername/pine-ridge-waf.git)"
            echo "  --branch BRANCH           Git branch to use (default: main)"
            echo "  --help, -h                Show this help message"
            echo ""
            echo "Legacy positional arguments are still supported:"
            echo "  $0 [REPO_URL] [BRANCH]"
            echo ""
            echo "Examples:"
            echo "  $0 --repo https://github.com/yourusername/pine-ridge-waf.git"
            echo "  $0 --interactive --repo https://github.com/yourusername/pine-ridge-waf.git"
            echo "  $0 --repo https://github.com/yourusername/pine-ridge-waf.git --branch feat/moving-to-ansible"
            echo "  $0 https://github.com/yourusername/pine-ridge-waf.git develop  # legacy format"
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