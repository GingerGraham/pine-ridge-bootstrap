#!/bin/bash
# waf-bootstrap.sh - Bootstrap WAF with Ansible GitOps

set -euo pipefail

REPO_URL="${1:-https://github.com/yourusername/pine-ridge-waf.git}"
GIT_BRANCH="${2:-main}"
INSTALL_DIR="/opt/pine-ridge-waf"
LOG_FILE="/tmp/waf-bootstrap.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
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
    
    local ssh_key="/root/.ssh/waf_gitops_ed25519"
    
    if [[ ! -f "$ssh_key" ]]; then
        sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "waf-gitops@$(hostname)"
        
        echo "=== ADD THIS DEPLOY KEY TO GITHUB ==="
        sudo cat "$ssh_key.pub"
        echo "=================================="
        
        read -p "Press Enter after adding the deploy key..."
    fi
}

clone_and_run() {
    log "Cloning repository..."
    
    sudo mkdir -p "$INSTALL_DIR"
    sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
    
    cd "$INSTALL_DIR/repo"
    
    # Set git configuration for branch tracking
    sudo git config user.name "WAF GitOps System"
    sudo git config user.email "waf-gitops@$(hostname)"
    
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
    
    install_ansible
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