#!/bin/bash
# pine-ridge-waf/bootstrap.sh - Bootstrap Pine Ridge WAF with environment-aware GitOps
#
# Bootstraps a WAF host into one of three deployment modes:
#   dev     - Tracks a configurable branch (default: main). Use switch-branch to change.
#   preprod - Tracks main HEAD. Any commit to main auto-deploys.
#   prod    - Deploys the latest semver-tagged release automatically.
#             Use switch-branch --pin-tag for rollback to a specific tag.
#
# Usage:
#   sudo ./bootstrap.sh --repo <REPO_URL> --environment <dev|preprod|prod> [OPTIONS]
#
# Options:
#   --repo <URL>           Repository URL (HTTPS or SSH).
#   --environment <ENV>    Deployment mode: dev, preprod, or prod. Default: dev.
#   --branch <BRANCH>      Git branch for dev/preprod. Default: main.
#   --interactive          Force interactive mode (prompts for vault password).
#   --help                 Show this help.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

REPO_URL=""
GIT_BRANCH="main"
ENVIRONMENT="dev"
INSTALL_DIR="/opt/pine-ridge-waf"
FORCE_INTERACTIVE=false

LOG_FILE="/tmp/waf-bootstrap-$(date +%s).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 --repo <REPO_URL> --environment <ENV> [OPTIONS]

Bootstrap Pine Ridge WAF with environment-aware GitOps.

Required:
  --repo <URL>              Repository URL (HTTPS or SSH)
  --environment <ENV>       dev, preprod, or prod

Options:
  --branch <BRANCH>         Git branch for dev only (default: main)
                            (preprod is always forced to main)
  --interactive             Force interactive mode for vault password setup
  --help                    Show this help

Environments:
  dev      Tracks a configurable branch (default: main).
           To switch branch on the running host:
             sudo switch-branch <branch>

  preprod  Always tracks main HEAD.
           Any commit merged to main is automatically deployed.

  prod     Deploys the latest semver-tagged release.
           To pin to a specific tag for rollback:
             sudo switch-branch --pin-tag v1.2.3
           To resume auto-latest:
             sudo switch-branch --clear-tag

Examples:
  # Development WAF (Proxmox or local)
  sudo $0 --repo https://github.com/GingerGraham/pine-ridge-waf.git --environment dev

  # Pre-production WAF
  sudo $0 --repo https://github.com/GingerGraham/pine-ridge-waf.git --environment preprod

  # Production WAF
  sudo $0 --repo https://github.com/GingerGraham/pine-ridge-waf.git --environment prod

  # Dev WAF tracking a specific feature branch
  sudo $0 --repo https://github.com/GingerGraham/pine-ridge-waf.git \\
          --environment dev --branch feat/my-feature

  # Preprod always tracks main (custom branch values are ignored)
  sudo $0 --repo https://github.com/GingerGraham/pine-ridge-waf.git \\
          --environment preprod --branch anything

EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_URL="${2:-}"
            [[ -n "$REPO_URL" ]] || error "--repo requires a URL"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="${2:-}"
            [[ -n "$ENVIRONMENT" ]] || error "--environment requires a value"
            shift 2
            ;;
        --branch)
            GIT_BRANCH="${2:-}"
            [[ -n "$GIT_BRANCH" ]] || error "--branch requires a value"
            shift 2
            ;;
        --interactive|-i)
            FORCE_INTERACTIVE=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        # Legacy positional: ./bootstrap.sh <REPO_URL> [BRANCH]
        http*|git@*)
            [[ -z "$REPO_URL" ]] && { REPO_URL="$1"; shift; } || error "Unexpected argument: $1"
            ;;
        *)
            [[ -n "$REPO_URL" && -z "${POSITIONAL_BRANCH:-}" ]] \
                && { POSITIONAL_BRANCH="$1"; GIT_BRANCH="$1"; shift; } \
                || error "Unknown argument: $1 (use --help)"
            ;;
    esac
done

[[ -n "$REPO_URL" ]]      || error "Missing required argument: --repo"
[[ "$ENVIRONMENT" =~ ^(dev|preprod|prod)$ ]] \
    || error "Invalid environment '${ENVIRONMENT}'. Must be dev, preprod, or prod."
[[ $EUID -eq 0 ]]         || error "This script must be run as root (sudo)"

# Preprod must always track main; ignore custom branch input there.
if [[ "$ENVIRONMENT" == "preprod" && "$GIT_BRANCH" != "main" ]]; then
    log "Preprod is fixed to main; overriding requested branch '${GIT_BRANCH}' -> 'main'"
    GIT_BRANCH="main"
fi

# ── Validate ──────────────────────────────────────────────────────────────────

log "Starting Pine Ridge WAF bootstrap"
log "Repository  : ${REPO_URL}"
log "Environment : ${ENVIRONMENT}"
if [[ "$ENVIRONMENT" != "prod" ]]; then
    log "Branch      : ${GIT_BRANCH}"
fi

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

check_prerequisites() {
    log "Checking prerequisites..."

    command -v git &>/dev/null || { log "Installing git..."; dnf install -y git; }
    command -v curl &>/dev/null || { log "Installing curl..."; dnf install -y curl; }

    log "Prerequisites OK"
}

# ── Step 2: Ansible ───────────────────────────────────────────────────────────

install_ansible() {
    log "Installing Ansible..."
    dnf install -y ansible-core python3-pip libsecret

    log "Installing Ansible collections system-wide..."
    ansible-galaxy collection install community.general
    ansible-galaxy collection install ansible.posix

    # Verify
    ansible-galaxy collection list | grep -q "ansible.posix" \
        || { log "Retrying ansible.posix install..."; ansible-galaxy collection install ansible.posix --force; }
    ansible-galaxy collection list | grep -q "community.general" \
        || { log "Retrying community.general install..."; ansible-galaxy collection install community.general --force; }

    log "Ansible installed"
}

# ── Step 3: SSH deploy key ────────────────────────────────────────────────────

setup_ssh_key() {
    log "Setting up SSH deploy key..."

    local ssh_key="/root/.ssh/waf_gitops_ed25519"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    rm -f "$ssh_key" "${ssh_key}.pub"
    echo | ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "waf-gitops@$(hostname)" 2>/dev/null \
        || ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "waf-gitops@$(hostname)" < /dev/null

    chmod 600 "$ssh_key"
    chmod 644 "${ssh_key}.pub"

    cat > /root/.ssh/config <<EOF
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
    chmod 600 /root/.ssh/config

    echo
    echo "=========================================="
    echo "ADD THIS DEPLOY KEY TO GITHUB:"
    echo "  Repo -> Settings -> Deploy keys -> Add deploy key"
    echo "  Title: waf-$(hostname)"
    echo "  Key (read-only access is sufficient):"
    echo "=========================================="
    cat "${ssh_key}.pub"
    echo "=========================================="
    echo

    if [[ -t 0 ]] || [[ "$FORCE_INTERACTIVE" == "true" ]]; then
        read -p "Press Enter after adding the deploy key to GitHub..." < /dev/tty
    else
        log "Non-interactive mode: waiting 90 seconds for deploy key to be added..."
        for i in {90..1}; do
            [[ $((i % 15)) -eq 0 ]] && log "Waiting... ${i}s remaining"
            sleep 1
        done
    fi

    # Verify SSH connection - explicitly use the deploy key so that we test
    # the correct identity regardless of the HOME env var (important when the
    # script is invoked via 'curl | sudo bash' where HOME may not be /root).
    local ssh_test
    ssh_test=$(ssh -i "$ssh_key" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -T git@github.com 2>&1 || true)
    if echo "$ssh_test" | grep -q "successfully authenticated"; then
        log "SSH connection to GitHub verified"
    else
        log "WARNING: SSH connection test inconclusive - continuing anyway"
        log "SSH test output: ${ssh_test}"
    fi

    # Export GIT_SSH_COMMAND so all subsequent git operations in this script
    # use the deploy key explicitly, rather than relying on ~/.ssh/config
    # (which may not resolve to /root/.ssh/config when HOME != /root).
    export GIT_SSH_COMMAND="ssh -i ${ssh_key} -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    log "GIT_SSH_COMMAND set to use deploy key: ${ssh_key}"
}

# ── Step 4: Convert URL to SSH ────────────────────────────────────────────────

convert_repo_url() {
    log "DEBUG: REPO_URL before conversion: '${REPO_URL}'"
    if [[ "$REPO_URL" =~ ^https://github\.com/(.+)$ ]]; then
        local repo_path="${BASH_REMATCH[1]}"
        repo_path="${repo_path%.git}"
        REPO_URL="git@github.com:${repo_path}.git"
        log "Converted repo URL to SSH: ${REPO_URL}"
    else
        log "DEBUG: URL did not match HTTPS pattern - using as-is: '${REPO_URL}'"
    fi
}

# ── Step 5: Clone repository ──────────────────────────────────────────────────

clone_repository() {
    log "Cloning repository..."
    log "DEBUG: REPO_URL at clone time: '${REPO_URL}'"
    log "DEBUG: GIT_SSH_COMMAND: '${GIT_SSH_COMMAND:-not set}'"
    log "DEBUG: ENVIRONMENT: '${ENVIRONMENT}', GIT_BRANCH: '${GIT_BRANCH}'"
    # Quick connectivity check with verbose SSH before attempting git clone
    local ssh_check
    ssh_check=$(GIT_SSH_COMMAND="ssh -i /root/.ssh/waf_gitops_ed25519 -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -v" \
        git ls-remote "${REPO_URL}" HEAD 2>&1 | head -30 || true)
    log "DEBUG: git ls-remote output: ${ssh_check}"

    mkdir -p "${INSTALL_DIR}/logs"

    if [[ "$ENVIRONMENT" == "prod" ]]; then
        # For prod: clone default branch, then checkout latest tag
        _clone_prod
    else
        # For dev/preprod: clone the configured branch
        _clone_branch "$GIT_BRANCH"
    fi

    cd "${INSTALL_DIR}/repo"
    git config user.name "WAF GitOps"
    git config user.email "waf-gitops@$(hostname)"
    git config core.filemode false
    git config core.hooksPath /dev/null
    git config --global --add safe.directory "${INSTALL_DIR}/repo"

    find "${INSTALL_DIR}/repo" -name "*.sh" -type f -exec chmod +x {} \;
    log "Repository ready"
}

reclone_repository() {
    local branch_arg="${1:-}"

    rm -rf "${INSTALL_DIR}/repo"
    log "DEBUG: reclone_repository - REPO_URL='${REPO_URL}' branch_arg='${branch_arg}'"
    log "DEBUG: reclone_repository - GIT_SSH_COMMAND='${GIT_SSH_COMMAND:-not set}'"
    if [[ -n "$branch_arg" ]]; then
        log "DEBUG: running: git clone -b '${branch_arg}' '${REPO_URL}' '${INSTALL_DIR}/repo'"
        git clone -b "$branch_arg" "$REPO_URL" "${INSTALL_DIR}/repo"
    else
        log "DEBUG: running: git clone '${REPO_URL}' '${INSTALL_DIR}/repo'"
        git clone "$REPO_URL" "${INSTALL_DIR}/repo"
    fi
}

_clone_branch() {
    local branch="$1"

    if [[ -d "${INSTALL_DIR}/repo/.git" ]]; then
        log "Existing repository found - updating to branch ${branch}..."
        cd "${INSTALL_DIR}/repo"
        chown -R root:root "${INSTALL_DIR}/repo"

        # Ensure the expected remote is configured
        local current_remote
        current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$current_remote" && "$current_remote" != "$REPO_URL" ]]; then
            log "Remote URL mismatch detected. Re-cloning repository for safety."
            log "Current remote: ${current_remote}"
            log "Expected remote: ${REPO_URL}"
            cd /
            reclone_repository "$branch"
            return
        fi

        git fetch origin
        git checkout "$branch" 2>/dev/null || git checkout -b "$branch" "origin/${branch}"
        git reset --hard "origin/${branch}"
    else
        reclone_repository "$branch"
    fi
}

_clone_prod() {
    local latest_tag

    # Clone default branch first so we can fetch tags
    if [[ -d "${INSTALL_DIR}/repo/.git" ]]; then
        log "Existing repository found - fetching tags..."
        cd "${INSTALL_DIR}/repo"
        chown -R root:root "${INSTALL_DIR}/repo"

        local current_remote
        current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$current_remote" && "$current_remote" != "$REPO_URL" ]]; then
            log "Remote URL mismatch detected. Re-cloning repository for safety."
            log "Current remote: ${current_remote}"
            log "Expected remote: ${REPO_URL}"
            cd /
            reclone_repository
            cd "${INSTALL_DIR}/repo"
        fi

        git fetch --all --tags
    else
        reclone_repository
        cd "${INSTALL_DIR}/repo"
        git fetch --all --tags
    fi

    # Find the latest semver tag
    latest_tag=$(git ls-remote --tags --refs origin \
        | grep -E 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
        | awk '{print $2}' \
        | sed 's|refs/tags/||' \
        | sort -V \
        | tail -n1)

    if [[ -z "$latest_tag" ]]; then
        error "No semver release tags found in the repository. Create a release first."
    fi

    log "Checking out latest release tag: ${latest_tag}"
    git checkout "tags/${latest_tag}"
    log "Deployed: $(git describe --tags)"
}

# ── Step 6: Write config file ─────────────────────────────────────────────────

create_config() {
    log "Writing /etc/pine-ridge-waf.conf..."

    local branch_line=""
    local pinned_line=""

    if [[ "$ENVIRONMENT" == "prod" ]]; then
        # GIT_BRANCH kept as main for informational purposes; sync uses tags
        branch_line="GIT_BRANCH=main"
        pinned_line="# PINNED_TAG=            # Uncomment to force a specific release tag (rollback)"
    else
        branch_line="GIT_BRANCH=${GIT_BRANCH}"
    fi

    tee /etc/pine-ridge-waf.conf > /dev/null <<EOF
# Pine Ridge WAF GitOps Configuration
# Managed by: pine-ridge-bootstrap/pine-ridge-waf/bootstrap.sh
# To change source branch/tag: sudo switch-branch [--status|<branch>|--pin-tag <tag>|--clear-tag]

REPO_URL=${REPO_URL}
ENVIRONMENT=${ENVIRONMENT}
${branch_line}
INSTALL_DIR=${INSTALL_DIR}
${pinned_line:-}
EOF

    chmod 644 /etc/pine-ridge-waf.conf
    log "Config written: ENVIRONMENT=${ENVIRONMENT}"
}

# ── Step 7: Vault password ────────────────────────────────────────────────────

setup_vault_password() {
    log "Setting up Ansible vault password..."

    local vault_password_file="/etc/pine-ridge-waf-vault-pass"
    local vault_script="/usr/local/bin/get-waf-vault-pass.sh"
    local vault_password=""

    # Reuse existing password if present and real
    if [[ -f "$vault_password_file" ]]; then
        local current
        current=$(cat "$vault_password_file" 2>/dev/null || echo "")
        if [[ "$current" == "VAULT_PASSWORD_NOT_SET" || -z "$current" ]]; then
            log "Placeholder password found - will prompt for real password"
        else
            log "Existing vault password found"
            if [[ -t 0 ]] || [[ "$FORCE_INTERACTIVE" == "true" ]]; then
                read -p "Update the existing vault password? (y/N): " -r update < /dev/tty
                if [[ ! "${update:-N}" =~ ^[Yy]$ ]]; then
                    log "Keeping existing vault password"
                    vault_password="$current"
                fi
            else
                log "Non-interactive mode: keeping existing vault password"
                vault_password="$current"
            fi
        fi
    fi

    # Prompt for password if we don't have one
    if [[ -z "$vault_password" ]]; then
        if [[ -t 0 ]] || [[ "$FORCE_INTERACTIVE" == "true" ]]; then
            echo
            echo "=== ANSIBLE VAULT PASSWORD ==="
            while true; do
                read -p "Enter vault password: " -s vault_password < /dev/tty; echo
                [[ -n "$vault_password" ]] || { echo "Password cannot be empty"; continue; }
                read -p "Confirm vault password: " -s confirm < /dev/tty; echo
                [[ "$vault_password" == "$confirm" ]] && break
                echo "Passwords do not match. Please try again."
            done
        else
            log "Non-interactive: creating vault password placeholder"
            log "Run with --interactive or set password manually later:"
            log "  echo '<password>' | sudo tee /etc/pine-ridge-waf-vault-pass"
            vault_password="VAULT_PASSWORD_NOT_SET"
        fi
    fi

    echo "$vault_password" | tee "$vault_password_file" > /dev/null

    # Create the vault script Ansible uses
    tee "$vault_script" > /dev/null <<'VAULTEOF'
#!/bin/bash
cat /etc/pine-ridge-waf-vault-pass
VAULTEOF
    chmod 755 "$vault_script"

    # Group for vault access
    getent group waf-vault >/dev/null 2>&1 || groupadd waf-vault
    usermod -a -G waf-vault "${SUDO_USER:-root}" 2>/dev/null || true

    chown root:waf-vault "$vault_password_file"
    chmod 640 "$vault_password_file"

    # Verify wrapper script can read the vault file
    if ! "$vault_script" >/dev/null 2>&1; then
        error "Vault password wrapper script failed: $vault_script"
    fi

    # Verify Ansible can decrypt vault if one is present and password is real
    if [[ -f "${INSTALL_DIR}/repo/inventory/group_vars/vault.yml" ]] && [[ "$vault_password" != "VAULT_PASSWORD_NOT_SET" ]]; then
        if timeout 10 ansible-vault view "${INSTALL_DIR}/repo/inventory/group_vars/vault.yml" \
            --vault-password-file "$vault_script" >/dev/null 2>&1; then
            log "Vault decryption check passed"
        else
            log "WARNING: Vault decryption check failed. Verify vault password before first scheduled run."
        fi
    fi

    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] && ! id -nG "${SUDO_USER}" | grep -q "\bwaf-vault\b"; then
        log "NOTE: ${SUDO_USER} may need to re-login or run 'newgrp waf-vault' to get immediate vault group access"
    fi

    log "Vault password configured"
}

# ── Step 8: Initial deployment ────────────────────────────────────────────────

run_initial_deployment() {
    log "Running initial WAF configuration playbook..."
    cd "${INSTALL_DIR}/repo"

    if ansible-playbook site.yml; then
        log "Initial configuration completed"
    else
        log "Initial configuration playbook exited with errors"
        log "This may be normal if vault is not yet fully configured."
        log "Re-run manually: cd ${INSTALL_DIR}/repo && ansible-playbook site.yml"
    fi
}

# ── Step 9: Systemd GitOps services ──────────────────────────────────────────

setup_gitops_services() {
    log "Creating systemd GitOps services..."

    local sync_script="${INSTALL_DIR}/repo/scripts/sync-repo.sh"
    local switch_script="${INSTALL_DIR}/repo/scripts/switch-branch.sh"

    if [[ ! -f "$sync_script" ]]; then
        error "Required GitOps script missing: $sync_script"
    fi

    chmod +x "$sync_script"

    if [[ -f "$switch_script" ]]; then
        chmod +x "$switch_script"
    else
        log "WARNING: switch-branch.sh not found; source-switch helper will be unavailable until repo provides it"
    fi

    # Sync + apply service (calls repo's sync-repo.sh then ansible-playbook)
    tee /etc/systemd/system/waf-ansible.service > /dev/null <<EOF
[Unit]
Description=Pine Ridge WAF - Sync and Apply Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-waf.conf
WorkingDirectory=${INSTALL_DIR}/repo
ExecStartPre=${INSTALL_DIR}/repo/scripts/sync-repo.sh
ExecStart=/usr/bin/ansible-playbook site.yml
StandardOutput=journal
StandardError=journal
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

    # Timer: how often to check for updates
    tee /etc/systemd/system/waf-ansible.timer > /dev/null <<'EOF'
[Unit]
Description=Pine Ridge WAF - Sync Timer
Requires=waf-ansible.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now waf-ansible.timer

    log "GitOps timer enabled: waf-ansible.timer"
}

# ── Step 10: Summary ──────────────────────────────────────────────────────────

show_summary() {
    echo
    echo "=========================================="
    echo "  Pine Ridge WAF Bootstrap Complete"
    echo "=========================================="
    echo "  Environment  : ${ENVIRONMENT}"

    if [[ "$ENVIRONMENT" == "prod" ]]; then
        echo "  Source       : latest semver release tag"
        echo "  Rollback     : sudo switch-branch --pin-tag v1.2.3"
        echo "  Auto-latest  : sudo switch-branch --clear-tag"
    else
        echo "  Branch       : ${GIT_BRANCH}"
        echo "  Switch branch: sudo switch-branch <branch>"
    fi

    echo
    echo "  Monitor      : journalctl -u waf-ansible.service -f"
    echo "  Status       : systemctl list-timers waf-ansible.timer"
    echo "  Manual run   : systemctl start waf-ansible.service"
    echo "  Show state   : switch-branch --status"
    echo "  Recurring    : waf-ansible.timer runs every 10 minutes"
    echo "=========================================="
    echo
    echo "Bootstrap log: ${LOG_FILE}"
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    check_prerequisites
    install_ansible
    convert_repo_url
    setup_ssh_key
    clone_repository
    create_config
    setup_vault_password
    run_initial_deployment
    setup_gitops_services
    show_summary
}

main
