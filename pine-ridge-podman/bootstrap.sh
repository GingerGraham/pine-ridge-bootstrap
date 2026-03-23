#!/bin/bash
# podman-bootstrap.sh - Bootstrap Podman with environment-aware GitOps
#
# Bootstraps a Podman host into one of three deployment modes:
#   dev     - Tracks a configurable branch (default: main). Use switch-branch to change.
#   preprod - Tracks main HEAD. Any commit to main auto-deploys.
#   prod    - Deploys the latest stable semver-tagged release.
#             Use switch-branch --pin-tag for rollback to a specific tag.

set -euo pipefail

SCRIPT_VERSION="3.0.0"
REPO_URL="https://github.com/yourusername/pine-ridge-podman.git"
ENVIRONMENT="dev"
GIT_BRANCH="main"
INSTALL_DIR="/opt/pine-ridge-podman"
LOG_FILE="/tmp/podman-bootstrap-$(date +%s).log"
FORCE_INTERACTIVE=false
ROTATE_SSH_KEY=false
DEBUG=false

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

NONINTERACTIVE_STDIN=false
[[ ! -t 0 ]] && NONINTERACTIVE_STDIN=true

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        log "DEBUG: $1"
    fi
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

run_maybe_detached_stdin() {
    if [[ "$NONINTERACTIVE_STDIN" == "true" ]]; then
        "$@" < /dev/null
    else
        "$@"
    fi
}

wait_for_github_ssh_auth() {
    local ssh_key="$1"
    local max_wait_seconds="${2:-90}"
    local poll_interval_seconds="${3:-5}"
    local elapsed=0
    local ssh_test_output=""

    while (( elapsed <= max_wait_seconds )); do
        ssh_test_output=$(sudo ssh -i "$ssh_key" -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -T git@github.com < /dev/null 2>&1 || true)

        if echo "$ssh_test_output" | grep -q "successfully authenticated"; then
            log "SSH connection to GitHub verified successfully"
            export GIT_SSH_COMMAND="ssh -i ${ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
            return 0
        fi

        if (( elapsed == 0 )); then
            log "Waiting for GitHub deploy key activation..."
        elif (( elapsed % 10 == 0 )); then
            log "Still waiting for GitHub deploy key activation... ${elapsed}s elapsed"
        fi

        sleep "$poll_interval_seconds"
        elapsed=$((elapsed + poll_interval_seconds))
    done

    log "SSH connection to GitHub could not be verified yet. Continuing anyway."
    log "Last SSH test output: ${ssh_test_output}"
    export GIT_SSH_COMMAND="ssh -i ${ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    return 1
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [REPO_URL] [BRANCH]

Bootstrap Pine Ridge Podman with environment-aware GitOps.

Options:
  --repo <URL>              Repository URL (required)
  --environment <ENV>       dev, preprod, or prod (default: dev)
  --branch <BRANCH>         Git branch for dev only (default: main)
  --interactive, -i         Force interactive mode for vault password setup
  --rotate-ssh-key          Force SSH key rotation
  --debug, --verbose        Enable verbose troubleshooting output
  --help, -h                Show this help

Environments:
  dev      Tracks a configurable branch (default: main).
           To switch branch on the running host:
             sudo switch-branch <branch>

  preprod  Always tracks main HEAD.
           Any commit merged to main is automatically deployed.

  prod     Deploys the latest stable semver-tagged release.
           To pin to a specific tag for rollback:
             sudo switch-branch --pin-tag v1.2.3
           To resume auto-latest:
             sudo switch-branch --clear-tag

Legacy positional arguments are still supported:
  $0 [REPO_URL] [BRANCH]
EOF
}

normalize_repo_url() {
    local original_url="$REPO_URL"
    local repo_path=""

    if [[ "$REPO_URL" =~ ^https://github\.com/(.+)$ ]]; then
        repo_path="${BASH_REMATCH[1]}"
        while [[ "$repo_path" == *.git ]]; do
            repo_path="${repo_path%.git}"
        done
        REPO_URL="git@github.com:${repo_path}.git"
    elif [[ "$REPO_URL" =~ ^git@github\.com:(.+)$ ]]; then
        repo_path="${BASH_REMATCH[1]}"
        while [[ "$repo_path" == *.git ]]; do
            repo_path="${repo_path%.git}"
        done
        REPO_URL="git@github.com:${repo_path}.git"
    fi

    if [[ "$REPO_URL" != "$original_url" ]]; then
        debug "Normalized repo URL: '${original_url}' -> '${REPO_URL}'"
    fi
}

check_prerequisites() {
    log "Checking prerequisites..."

    [[ $EUID -ne 0 ]] || error "This script should not be run as root. Run as a user with sudo privileges."

    if ! sudo -n true 2>/dev/null; then
        error "This script requires sudo privileges. Please run with a user in the wheel group."
    fi

    if ! command -v git >/dev/null 2>&1; then
        log "Git not found, installing..."
        sudo dnf install -y git
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "curl not found, installing..."
        sudo dnf install -y curl
    fi

    log "Prerequisites check completed"
}

install_ansible() {
    log "Installing Ansible and Podman..."

    sudo dnf install -y ansible-core python3-pip podman podman-compose yq

    export ANSIBLE_LOG_PATH="/dev/null"
    export ANSIBLE_HOST_KEY_CHECKING=False

    log "Installing core Ansible collections..."
    sudo -E ansible-galaxy collection install community.general --force
    sudo -E ansible-galaxy collection install ansible.posix --force

    log "Enabling podman socket..."
    sudo systemctl enable --now podman.socket

    log "Ansible and Podman installed successfully"
}

setup_ssh_auth() {
    log "Setting up SSH authentication..."

    local ssh_dir="/root/.ssh"
    local ssh_key="${ssh_dir}/podman_gitops_ed25519"
    local ssh_config="${ssh_dir}/config"
    local should_generate=false

    sudo mkdir -p "$ssh_dir"
    sudo chmod 700 "$ssh_dir"

    if [[ "$ROTATE_SSH_KEY" == "true" ]]; then
        log "Force SSH key rotation requested - removing existing keys..."
        sudo rm -f "$ssh_key" "$ssh_key.pub"
        should_generate=true
    elif ! sudo test -f "$ssh_key"; then
        log "SSH key does not exist - will generate new key"
        should_generate=true
    else
        log "SSH key already exists: $ssh_key"
    fi

    if [[ "$should_generate" == "true" ]]; then
        log "Generating SSH key for GitOps..."
        echo | sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "podman-gitops@$(hostname)" 2>/dev/null || \
            sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "podman-gitops@$(hostname)" < /dev/null

        sudo chmod 600 "$ssh_key"
        sudo chmod 644 "$ssh_key.pub"

        echo
        echo "=== SSH KEY FOR GITHUB ==="
        echo "Add this SSH public key to your GitHub repository as a deploy key:"
        echo
        sudo cat "$ssh_key.pub"
        echo
        echo "Steps:"
        echo "1. Go to your GitHub repo -> Settings -> Deploy keys"
        echo "2. Click 'Add deploy key'"
        echo "3. Give it a title like 'Podman GitOps Server'"
        echo "4. Paste the above public key"
        echo "5. Do NOT check 'Allow write access'"
        echo "6. Click 'Add key'"
        echo

        if [ -t 0 ]; then
            read -p "Press Enter after adding the deploy key to GitHub..."
        else
            echo "Script is running from pipe. Polling GitHub for deploy key activation for up to 90 seconds..."
        fi
    else
        log "Using existing SSH key - no GitHub deploy key update needed"
    fi

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

    wait_for_github_ssh_auth "$ssh_key" 90 5 || true
}

reclone_repository() {
    local branch_arg="${1:-}"

    sudo rm -rf "${INSTALL_DIR}/repo"
    debug "Re-cloning repository. branch='${branch_arg:-<default>}' url='${REPO_URL}'"

    if [[ -n "$branch_arg" ]]; then
        run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git clone -b "$branch_arg" "$REPO_URL" "${INSTALL_DIR}/repo"
    else
        run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git clone "$REPO_URL" "${INSTALL_DIR}/repo"
    fi
}

clone_branch() {
    local branch="$1"

    if [[ -d "${INSTALL_DIR}/repo/.git" ]]; then
        log "Existing repository found - updating to branch ${branch}..."
        cd "${INSTALL_DIR}/repo"
        sudo chown -R root:root "${INSTALL_DIR}/repo"

        local current_remote
        current_remote=$(sudo git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$current_remote" && "$current_remote" != "$REPO_URL" ]]; then
            log "Remote URL mismatch detected. Re-cloning repository for safety."
            log "Current remote: ${current_remote}"
            log "Expected remote: ${REPO_URL}"
            cd /
            reclone_repository "$branch"
            return
        fi

        run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git fetch origin "$branch"
        sudo git checkout "$branch" 2>/dev/null || sudo git checkout -b "$branch" "origin/${branch}"
        sudo git reset --hard "origin/${branch}"
    else
        reclone_repository "$branch"
    fi
}

clone_prod() {
    local latest_tag

    if [[ -d "${INSTALL_DIR}/repo/.git" ]]; then
        log "Existing repository found - fetching tags..."
        cd "${INSTALL_DIR}/repo"
        sudo chown -R root:root "${INSTALL_DIR}/repo"

        local current_remote
        current_remote=$(sudo git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$current_remote" && "$current_remote" != "$REPO_URL" ]]; then
            log "Remote URL mismatch detected. Re-cloning repository for safety."
            log "Current remote: ${current_remote}"
            log "Expected remote: ${REPO_URL}"
            cd /
            reclone_repository
            cd "${INSTALL_DIR}/repo"
        fi

        run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git fetch --all --tags
    else
        reclone_repository
        cd "${INSTALL_DIR}/repo"
        run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git fetch --all --tags
    fi

    latest_tag=$(run_maybe_detached_stdin sudo env GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git ls-remote --tags --refs origin \
        | grep -E 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
        | awk '{print $2}' \
        | sed 's|refs/tags/||' \
        | sort -V \
        | tail -n1)

    if [[ -z "$latest_tag" ]]; then
        error "No stable semver release tags found in the repository. Create a release first."
    fi

    log "Checking out latest stable release tag: ${latest_tag}"
    sudo git checkout "tags/${latest_tag}"
    log "Deployed: $(sudo git describe --tags)"
}

clone_repository() {
    log "Cloning repository..."

    local ssh_test_result
    ssh_test_result=$(sudo ssh -i /root/.ssh/podman_gitops_ed25519 -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -T git@github.com < /dev/null 2>&1 || true)
    if echo "$ssh_test_result" | grep -q "successfully authenticated"; then
        log "SSH connection to GitHub verified successfully"
    else
        log "SSH connection to GitHub failed. Please verify deploy key access."
        echo "$ssh_test_result"
        if [ -t 0 ]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || error "SSH authentication failed. Please fix the issue and try again."
        else
            log "Continuing despite SSH warning because script is running non-interactively"
        fi
    fi

    sudo mkdir -p "$INSTALL_DIR"

    if [[ "$ENVIRONMENT" == "prod" ]]; then
        clone_prod
    else
        clone_branch "$GIT_BRANCH"
    fi

    cd "${INSTALL_DIR}/repo"
    sudo git config user.name "Podman GitOps System"
    sudo git config user.email "podman-gitops@$(hostname)"
    sudo git config core.filemode false
    sudo git config core.hooksPath /dev/null
    sudo git config --global --add safe.directory "${INSTALL_DIR}/repo"
    sudo find "${INSTALL_DIR}/repo" -name "*.sh" -type f -exec chmod +x {} \;
    log "Repository ready"
}

setup_vault_password() {
    log "Setting up Ansible vault password..."

    local vault_pass_file="/etc/pine-ridge-podman-vault-pass"
    local vault_script="/usr/local/bin/get-podman-vault-pass.sh"
    local vault_group="podman-vault"
    local current_password=""
    local vault_password=""

    if ! getent group "$vault_group" > /dev/null 2>&1; then
        sudo groupadd "$vault_group"
        log "Created $vault_group group"
    fi

    sudo usermod -a -G "$vault_group" "$USER"
    log "Added $USER to $vault_group group"

    if [[ -f "$vault_pass_file" ]]; then
        current_password=$(sudo cat "$vault_pass_file" 2>/dev/null || echo "")
    fi

    if [[ -z "$current_password" || "$current_password" == "VAULT_PASSWORD_NOT_SET" ]]; then
        if [ -t 0 ] || [[ "$FORCE_INTERACTIVE" == "true" ]]; then
            local vault_password_input
            local vault_password_confirm

            while true; do
                echo "Enter the Ansible vault password:"
                read -p "Password: " -s vault_password_input < /dev/tty
                echo
                [[ -n "$vault_password_input" ]] || { echo "Password cannot be empty."; continue; }

                echo "Confirm the password:"
                read -p "Password (again): " -s vault_password_confirm < /dev/tty
                echo

                if [[ "$vault_password_input" == "$vault_password_confirm" ]]; then
                    vault_password="$vault_password_input"
                    break
                fi
                echo "Passwords do not match. Please try again."
            done
        else
            log "Non-interactive mode detected. Using placeholder vault password."
            vault_password="VAULT_PASSWORD_NOT_SET"
        fi
    else
        vault_password="$current_password"
    fi

    echo "$vault_password" | sudo tee "$vault_pass_file" > /dev/null
    sudo chmod 640 "$vault_pass_file"
    sudo chown root:"$vault_group" "$vault_pass_file"

    sudo tee "$vault_script" > /dev/null <<'EOF'
#!/bin/bash
cat /etc/pine-ridge-podman-vault-pass
EOF

    sudo chmod 750 "$vault_script"
    sudo chown root:"$vault_group" "$vault_script"
}

write_config() {
    log "Writing /etc/pine-ridge-podman.conf..."

    local pinned_line=""
    if [[ "$ENVIRONMENT" == "prod" ]]; then
        pinned_line="# PINNED_TAG=            # Uncomment to force a specific release tag"
    fi

    sudo tee /etc/pine-ridge-podman.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
ENVIRONMENT=$ENVIRONMENT
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
MANAGEMENT_USER=$USER
$pinned_line
EOF
}

run_initial_deployment() {
    log "Running initial Podman configuration..."
    cd "$INSTALL_DIR/repo/ansible"

    export ANSIBLE_LOG_PATH="/dev/null"
    export ANSIBLE_HOST_KEY_CHECKING=False
    export ANSIBLE_STDOUT_CALLBACK=default

    sudo mkdir -p /var/log/ansible
    sudo chmod 755 /var/log/ansible
    sudo chown root:root /var/log/ansible

    cat > /tmp/bootstrap-ansible.cfg <<EOF
[defaults]
inventory = $INSTALL_DIR/repo/ansible/inventory/hosts.yml
roles_path = roles
host_key_checking = False
timeout = 30
gathering = smart
fact_caching = memory
stdout_callback = ansible.builtin.default
bin_ansible_callbacks = True

[callback_default]
result_format = yaml
EOF

    export ANSIBLE_CONFIG="/tmp/bootstrap-ansible.cfg"

    if [[ -f "requirements.yml" ]]; then
        log "Installing Ansible collections from repository..."
        sudo -E ansible-galaxy collection install -r requirements.yml --force
    fi

    local current_hostname
    current_hostname=$(hostname -f)
    log "Running initial bootstrap playbook for host: ${current_hostname}"
    if sudo -E ansible-playbook bootstrap.yml --limit "$current_hostname"; then
        log "Initial bootstrap configuration completed successfully"
        if sudo ansible-playbook service-deployment.yml --limit "$current_hostname"; then
            log "Initial service deployment completed successfully"
        else
            log "Initial service deployment failed - services may need manual deployment"
        fi
    else
        log "Initial bootstrap failed - you may need to rerun bootstrap.yml manually"
    fi

    rm -f /tmp/bootstrap-ansible.cfg
    unset ANSIBLE_CONFIG
}

setup_ansible_gitops() {
    log "Setting up Pine Ridge GitOps automation chain..."

    sudo mkdir -p "$INSTALL_DIR/logs"

    local sync_script="${INSTALL_DIR}/repo/scripts/sync-repo.sh"
    local switch_script="${INSTALL_DIR}/repo/scripts/switch-branch.sh"

    [[ -f "$sync_script" ]] || error "Required GitOps script missing: $sync_script"
    sudo chmod +x "$sync_script"

    if [[ -f "$switch_script" ]]; then
        sudo chmod +x "$switch_script"
    else
        log "WARNING: switch-branch.sh not found; source-switch helper will be unavailable until repo provides it"
    fi

    sudo tee /etc/systemd/system/pine-ridge-git-sync.service > /dev/null <<EOF
[Unit]
Description=Pine Ridge Git Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/pine-ridge-podman.conf
ExecStart=${INSTALL_DIR}/repo/scripts/sync-repo.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

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
    log "Pine Ridge Podman bootstrap completed successfully"

    echo
    echo "=== SETUP COMPLETE ==="
    echo "Bootstrap version : ${SCRIPT_VERSION}"
    echo "Environment       : ${ENVIRONMENT}"
    if [[ "$ENVIRONMENT" == "prod" ]]; then
        echo "Tracking mode     : latest stable release tag"
        echo "Rollback helper   : sudo switch-branch --pin-tag v1.2.3"
        echo "Auto-latest       : sudo switch-branch --clear-tag"
    else
        echo "Tracking branch   : ${GIT_BRANCH}"
        echo "Switch branch     : sudo switch-branch <branch>"
    fi
    echo "Show state        : switch-branch --status"
    echo
    echo "=== MONITORING COMMANDS ==="
    echo "• Git sync status: journalctl -u pine-ridge-git-sync.service -f"
    echo "• Service deployment: journalctl -u pine-ridge-service-deployment.service -f"
    echo "• Timer status: systemctl list-timers pine-ridge-*"
    echo
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --interactive|-i)
            FORCE_INTERACTIVE=true
            shift
            ;;
        --rotate-ssh-key)
            ROTATE_SSH_KEY=true
            shift
            ;;
        --debug|--verbose)
            DEBUG=true
            shift
            ;;
        --repo)
            [[ -n "${2:-}" ]] || error "--repo requires a repository URL"
            REPO_URL="$2"
            shift 2
            ;;
        --environment)
            [[ -n "${2:-}" ]] || error "--environment requires a value"
            ENVIRONMENT="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || error "--branch requires a branch name"
            GIT_BRANCH="$2"
            shift 2
            ;;
        --*)
            error "Unknown option: $1"
            ;;
        *)
            if [[ -z "${REPO_URL_SET:-}" ]]; then
                REPO_URL="$1"
                REPO_URL_SET=true
            elif [[ -z "${GIT_BRANCH_SET:-}" ]]; then
                GIT_BRANCH="$1"
                GIT_BRANCH_SET=true
            else
                error "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ "$ENVIRONMENT" =~ ^(dev|preprod|prod)$ ]] || error "Invalid environment '${ENVIRONMENT}'. Must be dev, preprod, or prod."

normalize_repo_url

if [[ "$ENVIRONMENT" == "preprod" && "$GIT_BRANCH" != "main" ]]; then
    log "Preprod is fixed to main; overriding requested branch '${GIT_BRANCH}' -> 'main'"
    GIT_BRANCH="main"
fi

if [[ "$ENVIRONMENT" == "prod" ]]; then
    GIT_BRANCH="main"
fi

log "Starting Podman bootstrap version ${SCRIPT_VERSION}"
log "Repository: $REPO_URL"
log "Environment: $ENVIRONMENT"
debug "Branch: $GIT_BRANCH"
debug "FORCE_INTERACTIVE: ${FORCE_INTERACTIVE}"
debug "ROTATE_SSH_KEY: ${ROTATE_SSH_KEY}"

check_prerequisites
install_ansible
setup_ssh_auth
clone_repository
setup_vault_password
write_config
run_initial_deployment
setup_ansible_gitops
show_completion_status

log "Podman bootstrap completed successfully"
echo "Bootstrap log saved to: $LOG_FILE"
