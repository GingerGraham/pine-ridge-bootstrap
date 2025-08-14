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
    sudo dnf install -y ansible-core python3-pip
    
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

    # Create separate timer for system maintenance (runs less frequently)
    sudo tee /etc/systemd/system/waf-system-maintenance.service > /dev/null <<'EOF'
[Unit]
Description=WAF System Maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-waf.conf
WorkingDirectory=/opt/pine-ridge-waf/repo
ExecStart=/usr/bin/ansible-playbook -i localhost, --connection=local system-maintenance.yml
StandardOutput=journal
StandardError=journal
TimeoutSec=1800

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

    # Create timer for system maintenance (daily)
    sudo tee /etc/systemd/system/waf-system-maintenance.timer > /dev/null <<'EOF'
[Unit]
Description=WAF System Maintenance Timer
Requires=waf-system-maintenance.service

[Timer]
OnBootSec=30min
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now waf-ansible.timer
    sudo systemctl enable --now waf-system-maintenance.timer
}

clone_and_run() {
    log "Cloning repository and running initial configuration..."
    
    sudo mkdir -p "$INSTALL_DIR"
    sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
    
    cd "$INSTALL_DIR/repo"
    
    # Set git configuration for branch tracking
    sudo git config user.name "WAF GitOps System"
    sudo git config user.email "waf-gitops@$(hostname)"
    
    # Run initial Ansible playbooks
    log "Running WAF configuration playbook..."
    ansible-playbook -i localhost, --connection=local site.yml
    
    log "Running system maintenance playbook..."
    ansible-playbook -i localhost, --connection=local system-maintenance.yml
    
    log "Initial configuration completed"
}

main() {
    log "Starting WAF Ansible bootstrap..."
    log "Repository: $REPO_URL"
    log "Branch: $GIT_BRANCH"
    
    install_ansible
    setup_ssh_auth
    clone_and_run
    setup_ansible_gitops
    
    log "WAF bootstrap completed successfully"
    echo "Usage: $0 <repo_url> [branch_name]"
    echo "Branch switching: Edit /etc/pine-ridge-waf.conf and restart timers"
}

main "$@"