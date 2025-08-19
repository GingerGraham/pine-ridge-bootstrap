#!/bin/bash
# waf-bootstrap.sh - Bootstrap WAF with Ansible GitOps

set -euo pipefail

REPO_URL="${1:-https://github.com/yourusername/pine-ridge-waf.git}"
GIT_BRANCH="${2:-main}"
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
    
    # Install common collections we'll need
    ansible-galaxy collection install community.general
    ansible-galaxy collection install ansible.posix
    
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
    
    if [[ -d "$INSTALL_DIR/repo/.git" ]]; then
        log "Repository directory exists, updating..."
        cd "$INSTALL_DIR/repo"
        # Ensure proper ownership before git operations
        sudo chown -R root:root "$INSTALL_DIR/repo"
        sudo git pull origin main || sudo git pull origin master
    else
        log "Cloning repository: $REPO_URL"
        # Remove any existing directory that's not a git repo
        if [[ -d "$INSTALL_DIR/repo" ]]; then
            sudo rm -rf "$INSTALL_DIR/repo"
        fi
        sudo git clone "$REPO_URL" "$INSTALL_DIR/repo"
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
        log "Vault password file already exists"
        
        read -p "Do you want to update the existing password? (y/N): " -r update_password
        if [[ ! $update_password =~ ^[Yy]$ ]]; then
            log "Keeping existing vault password"
            return 0
        fi
    fi
    
    # Prompt for password
    local vault_password
    local vault_password_confirm
    
    while true; do
        echo "Enter the Ansible vault password:"
        read -p "Password: " -s vault_password
        echo
        
        if [[ -z "$vault_password" ]]; then
            echo "Password cannot be empty. Please try again."
            continue
        fi
        
        echo "Confirm the password:"
        read -p "Password (again): " -s vault_password_confirm
        echo
        
        if [[ "$vault_password" == "$vault_password_confirm" ]]; then
            break
        else
            echo "Passwords don't match. Please try again."
            echo
        fi
    done
    
    # Store password in secure system file
    echo "$vault_password" | sudo tee "$vault_password_file" > /dev/null
    
    # Set very restrictive permissions
    sudo chmod 600 "$vault_password_file"
    sudo chown root:root "$vault_password_file"
    
    # Create wrapper script for Ansible
    sudo tee "$vault_script" > /dev/null <<EOF
#!/bin/bash
# Vault password script for system services
cat /etc/pine-ridge-waf-vault-pass
EOF
    
    sudo chmod 755 "$vault_script"
    sudo chown root:root "$vault_script"
    
    # Test the setup
    if [[ -f "$vault_password_file" ]] && [[ -x "$vault_script" ]]; then
        if [[ "$($vault_script)" == "$vault_password" ]]; then
            log "✓ Vault password stored successfully for system access"
        else
            error "Vault password verification failed"
        fi
    else
        error "Failed to create vault password files"
    fi
    
    # Test with Ansible if vault file exists
    cd "$INSTALL_DIR/repo"
    if [[ -f "inventory/group_vars/vault.yml" ]]; then
        log "Testing vault password with existing vault file..."
        if timeout 10 ansible-vault view inventory/group_vars/vault.yml --vault-password-file "$vault_script" >/dev/null 2>&1; then
            log "✓ Vault password verified with Ansible"
        else
            error "Vault password verification with Ansible failed"
        fi
    else
        log "No vault file found yet - password will be verified during first deployment"
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
    if ansible-playbook -i localhost, --connection=local site.yml; then
        log "Initial WAF configuration completed successfully"
    else
        log "Initial configuration failed - this may be normal if vault is not yet set up"
        log "You can run 'ansible-playbook site.yml' manually after setup"
    fi
}

setup_ansible_gitops() {
    log "Setting up Ansible GitOps service..."
    
    # Create configuration file for branch tracking
    sudo tee /etc/pine-ridge-waf.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF

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
ExecStart=/usr/bin/ansible-playbook -i localhost, --connection=local site.yml
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
    echo "=== NEXT STEPS ==="
    echo "1. Your WAF is now running and will auto-update from Git"
    echo "2. Monitor services: journalctl -u waf-ansible.service -f"
    echo "3. Check timer status: systemctl list-timers waf-ansible.timer"
    echo "4. Manual deployment: cd $INSTALL_DIR/repo && ansible-playbook site.yml"
    echo ""
    echo "=== SERVICE STATUS ==="
    sudo systemctl status waf-ansible.timer --no-pager --lines=5 || true
    echo ""
}

main() {
    log "Starting WAF Ansible bootstrap..."
    log "Repository: $REPO_URL"
    log "Branch: $GIT_BRANCH"
    
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

main "$@"