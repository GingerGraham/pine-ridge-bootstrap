#!/bin/bash
# linux-setup-bootstrap.sh - Bootstrap Linux/macOS Configuration with Ansible GitOps

set -euo pipefail

REPO_URL="https://github.com/yourusername/linux-config.git"
GIT_BRANCH="main"
INSTALL_DIR="/opt/linux-config"
LOG_FILE="/tmp/linux-setup-bootstrap-$(date +%s).log"

# Ensure log file is writable
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

detect_os() {
    log "Detecting operating system..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
        OS_FAMILY="Darwin"
        PACKAGE_MANAGER="brew"
        USE_SUDO=false
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_TYPE="linux"

        case "$ID" in
            fedora|rhel|centos|rocky|almalinux)
                OS_FAMILY="RedHat"
                PACKAGE_MANAGER="dnf"
                ;;
            ubuntu|debian|linuxmint)
                OS_FAMILY="Debian"
                PACKAGE_MANAGER="apt"
                ;;
            opensuse*|sles)
                OS_FAMILY="Suse"
                PACKAGE_MANAGER="zypper"
                ;;
            arch|manjaro|endeavouros)
                OS_FAMILY="Archlinux"
                PACKAGE_MANAGER="pacman"
                ;;
            *)
                error "Unsupported Linux distribution: $ID"
                ;;
        esac
        USE_SUDO=true
    else
        error "Unable to detect operating system"
    fi

    log "Detected: $OS_TYPE - $OS_FAMILY (Package manager: $PACKAGE_MANAGER)"
}

check_prerequisites() {
    log "Checking prerequisites..."

    if [[ "$OS_TYPE" == "linux" ]]; then
        # Check if running as non-root with sudo
        if [[ $EUID -eq 0 ]]; then
            error "This script should not be run as root. Run as a user with sudo privileges."
        fi

        # Check sudo access
        if ! sudo -n true 2>/dev/null; then
            log "Requesting sudo access..."
            sudo -v || error "This script requires sudo privileges."
        fi
    fi

    # Check if git is installed, install if missing
    if ! command -v git &> /dev/null; then
        log "Git not found, installing..."
        install_package git
    else
        log "Git is already installed"
    fi

    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        log "curl not found, installing..."
        install_package curl
    fi

    log "Prerequisites check completed"
}

install_package() {
    local package=$1
    log "Installing $package..."

    case "$PACKAGE_MANAGER" in
        dnf)
            sudo dnf install -y "$package"
            ;;
        apt)
            sudo apt-get update
            sudo apt-get install -y "$package"
            ;;
        zypper)
            sudo zypper install -y "$package"
            ;;
        pacman)
            sudo pacman -S --noconfirm "$package"
            ;;
        brew)
            brew install "$package"
            ;;
        *)
            error "Unsupported package manager: $PACKAGE_MANAGER"
            ;;
    esac
}

install_homebrew() {
    log "Checking Homebrew installation..."

    # Check common Homebrew locations
    local brew_path=""
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        brew_path="/opt/homebrew/bin/brew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        brew_path="/usr/local/bin/brew"
    elif command -v brew &> /dev/null; then
        brew_path=$(command -v brew)
    fi

    if [[ -n "$brew_path" ]]; then
        log "Homebrew found at: $brew_path"
        # Add to PATH if not already there
        if ! command -v brew &> /dev/null; then
            eval "$("$brew_path" shellenv)"
        fi
        return 0
    fi

    log "Homebrew not found, installing..."
    log "This will use the official Homebrew installation script"

    # Use official Homebrew installation script
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        log "✓ Homebrew installed successfully"

        # Determine Homebrew path and add to current session
        if [[ -x "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -x "/usr/local/bin/brew" ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi

        # Verify installation
        if command -v brew &> /dev/null; then
            local brew_version
            brew_version=$(brew --version | head -n1)
            log "Homebrew version: $brew_version"
        else
            error "Homebrew installation completed but brew command not found in PATH"
        fi
    else
        error "Failed to install Homebrew. Please install manually and re-run this script."
    fi
}

install_ansible() {
    log "Installing Ansible..."

    # For macOS, ensure Homebrew is installed first
    if [[ "$OS_TYPE" == "macos" ]]; then
        install_homebrew
    fi

    if command -v ansible &> /dev/null; then
        local ansible_version
        ansible_version=$(ansible --version | head -n1)
        log "Ansible already installed: $ansible_version"

        # Ask if user wants to reinstall/upgrade
        if [[ "${FORCE_ANSIBLE_INSTALL:-false}" != "true" ]]; then
            if [ -t 0 ]; then
                read -p "Reinstall/upgrade Ansible? (y/N): " -r
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log "Keeping existing Ansible installation"
                    return 0
                fi
            else
                log "Using existing Ansible installation"
                return 0
            fi
        fi
    fi

    case "$PACKAGE_MANAGER" in
        dnf)
            sudo dnf install -y ansible-core python3-pip
            ;;
        apt)
            sudo apt-get update
            sudo apt-get install -y ansible python3-pip
            ;;
        zypper)
            sudo zypper install -y ansible python3-pip
            ;;
        pacman)
            sudo pacman -S --noconfirm ansible python-pip
            ;;
        brew)
            brew install ansible
            ;;
    esac

    # Install required collections
    log "Installing Ansible collections..."
    ansible-galaxy collection install community.general
    ansible-galaxy collection install ansible.posix

    if [[ "$OS_TYPE" == "macos" ]]; then
        ansible-galaxy collection install community.crypto
    fi

    # Verify installation
    if command -v ansible &> /dev/null; then
        local ansible_version
        ansible_version=$(ansible --version | head -n1)
        log "✓ Ansible installed successfully: $ansible_version"
    else
        error "Ansible installation failed"
    fi
}

setup_git_access() {
    log "Setting up Git access..."

    local ssh_dir git_user_dir ssh_key ssh_config

    if [[ "$OS_TYPE" == "macos" ]]; then
        # On macOS, use current user's SSH directory
        git_user_dir="$HOME"
        ssh_dir="$git_user_dir/.ssh"
        ssh_key="$ssh_dir/linux_config_ed25519"
    else
        # On Linux, use root's SSH directory for system-level access
        git_user_dir="/root"
        ssh_dir="$git_user_dir/.ssh"
        ssh_key="$ssh_dir/linux_config_ed25519"
    fi

    ssh_config="$ssh_dir/config"

    # Create SSH directory if it doesn't exist
    if [[ "$USE_SUDO" == true ]]; then
        sudo mkdir -p "$ssh_dir"
        sudo chmod 700 "$ssh_dir"
    else
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi

    # Check if we're in read-only mode or dev mode
    local readonly_mode=true
    if [[ "${ENABLE_GIT_PUSH:-false}" == "true" ]] || [[ "${INTERACTIVE_MODE:-false}" == "true" ]]; then
        readonly_mode=false
        log "Git push access will be configured"
    else
        log "Read-only Git access (public repo clone)"
    fi

    # For public repos, we can just use HTTPS without SSH keys
    if [[ "$readonly_mode" == true ]]; then
        log "Using HTTPS for read-only access (no SSH key needed)"
        # Keep REPO_URL as HTTPS
        return 0
    fi

    # For dev machines, set up SSH key for push access
    log "Setting up SSH key for Git push access..."

    # Check if SSH key already exists
    if [[ "$USE_SUDO" == true ]]; then
        if sudo test -f "$ssh_key"; then
            log "SSH key already exists: $ssh_key"
            return 0
        fi
    else
        if [[ -f "$ssh_key" ]]; then
            log "SSH key already exists: $ssh_key"
            return 0
        fi
    fi

    # Generate new SSH key
    log "Generating SSH key for GitOps..."
    if [[ "$USE_SUDO" == true ]]; then
        echo | sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "linux-config@$(hostname)" 2>/dev/null || \
        sudo ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "linux-config@$(hostname)" < /dev/null

        sudo chmod 600 "$ssh_key"
        sudo chmod 644 "$ssh_key.pub"
    else
        echo | ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "linux-config@$(hostname)" 2>/dev/null || \
        ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "linux-config@$(hostname)" < /dev/null

        chmod 600 "$ssh_key"
        chmod 644 "$ssh_key.pub"
    fi

    log "SSH key generated: $ssh_key.pub"

    # Show the SSH key
    echo
    echo "=== SSH KEY FOR GITHUB (DEV MODE) ==="
    echo "Add this SSH public key to your GitHub account:"
    echo
    if [[ "$USE_SUDO" == true ]]; then
        sudo cat "$ssh_key.pub"
    else
        cat "$ssh_key.pub"
    fi
    echo
    echo "Steps:"
    echo "1. Go to GitHub → Settings → SSH and GPG keys"
    echo "2. Click 'New SSH key'"
    echo "3. Give it a title like 'Linux Config - $(hostname)'"
    echo "4. Paste the above public key"
    echo "5. Click 'Add SSH key'"
    echo

    if [ -t 0 ]; then
        read -p "Press Enter after adding the SSH key to GitHub..."
    else
        echo "Waiting 60 seconds to add SSH key..."
        sleep 60
    fi

    # Create/update SSH config for GitHub
    local ssh_config_entry
    read -r -d '' ssh_config_entry <<EOF || true
# Linux Config GitOps SSH configuration
Host github.com
    HostName github.com
    User git
    IdentityFile $ssh_key
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF

    if [[ "$USE_SUDO" == true ]]; then
        if sudo test -f "$ssh_config"; then
            if ! sudo grep -q "# Linux Config GitOps SSH configuration" "$ssh_config"; then
                echo "$ssh_config_entry" | sudo tee -a "$ssh_config" > /dev/null
            fi
        else
            echo "$ssh_config_entry" | sudo tee "$ssh_config" > /dev/null
        fi
        sudo chmod 600 "$ssh_config"
    else
        if [[ -f "$ssh_config" ]]; then
            if ! grep -q "# Linux Config GitOps SSH configuration" "$ssh_config"; then
                echo "$ssh_config_entry" >> "$ssh_config"
            fi
        else
            echo "$ssh_config_entry" > "$ssh_config"
        fi
        chmod 600 "$ssh_config"
    fi
}

convert_repo_url_to_ssh() {
    # Convert HTTPS GitHub URLs to SSH format if in dev mode
    if [[ "${ENABLE_GIT_PUSH:-false}" == "true" ]] || [[ "${INTERACTIVE_MODE:-false}" == "true" ]]; then
        if [[ "$REPO_URL" =~ ^https://github\.com/(.+)\.git$ ]]; then
            REPO_URL="git@github.com:${BASH_REMATCH[1]}.git"
            log "Converted repository URL to SSH format: $REPO_URL"
        elif [[ "$REPO_URL" =~ ^https://github\.com/(.+)$ ]]; then
            REPO_URL="git@github.com:${BASH_REMATCH[1]}.git"
            log "Converted repository URL to SSH format: $REPO_URL"
        fi
    else
        log "Using HTTPS URL for read-only access: $REPO_URL"
    fi
}

clone_repository() {
    log "Cloning repository..."

    # Create install directory
    if [[ "$USE_SUDO" == true ]]; then
        sudo mkdir -p "$INSTALL_DIR"

        # Handle existing repository
        if sudo test -d "$INSTALL_DIR/repo"; then
            if sudo test -d "$INSTALL_DIR/repo/.git"; then
                log "Repository already exists, updating..."
                cd "$INSTALL_DIR/repo"

                sudo git fetch origin
                sudo git reset --hard "origin/$GIT_BRANCH" 2>/dev/null || {
                    log "Failed to reset, re-cloning..."
                    cd /
                    sudo rm -rf "$INSTALL_DIR/repo"
                    sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
                }
            else
                log "Directory exists but is not a git repository, re-cloning..."
                sudo rm -rf "$INSTALL_DIR/repo"
                sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
            fi
        else
            log "Cloning repository: $REPO_URL"
            sudo git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
        fi

        cd "$INSTALL_DIR/repo"
        sudo git config user.name "Linux Config GitOps"
        sudo git config user.email "linux-config@$(hostname)"
        sudo git config core.filemode false
        sudo find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;
    else
        mkdir -p "$INSTALL_DIR"

        if [[ -d "$INSTALL_DIR/repo" ]]; then
            log "Repository already exists, updating..."
            cd "$INSTALL_DIR/repo"
            git fetch origin
            git reset --hard "origin/$GIT_BRANCH"
        else
            log "Cloning repository: $REPO_URL"
            git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR/repo"
        fi

        cd "$INSTALL_DIR/repo"
        git config user.name "Linux Config GitOps"
        git config user.email "linux-config@$(hostname)"
        git config core.filemode false
        find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;
    fi

    log "Repository cloned successfully"
}

run_bootstrap() {
    log "Running Ansible bootstrap playbook..."

    cd "$INSTALL_DIR/repo"

    # Install collections from requirements
    log "Installing Ansible collections from requirements..."
    ansible-galaxy collection install -r requirements.yml

    # Run bootstrap playbook
    log "Running bootstrap.yml..."
    if ansible-playbook bootstrap.yml; then
        log "✓ Bootstrap playbook completed successfully"
    else
        log "⚠ Bootstrap playbook failed - may need manual intervention"
    fi

    # Run initial configuration
    log "Running initial configuration (site.yml)..."
    if ansible-playbook site.yml; then
        log "✓ Initial configuration completed successfully"
    else
        log "⚠ Initial configuration failed - will retry on next sync"
    fi
}

setup_gitops_automation() {
    log "Setting up GitOps automation..."

    if [[ "$OS_TYPE" == "linux" ]]; then
        setup_systemd_services
    else
        setup_launchd_services
    fi
}

setup_systemd_services() {
    log "Creating systemd services for GitOps automation..."

    # Create configuration file
    sudo tee /etc/linux-config.conf > /dev/null <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF

    # Create scripts directory
    sudo mkdir -p "$INSTALL_DIR/repo/scripts"
    sudo mkdir -p "$INSTALL_DIR/logs"

    # Create git sync script
    sudo tee "$INSTALL_DIR/repo/scripts/git-sync.sh" > /dev/null <<'EOFSCRIPT'
#!/bin/bash
# scripts/git-sync.sh - Git sync for Linux Config GitOps

set -euo pipefail

source /etc/linux-config.conf

LOG_FILE="$INSTALL_DIR/logs/git-sync.log"
LOCK_FILE="/var/run/linux-config-sync.lock"

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
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

check_git_changes() {
    cd "$INSTALL_DIR/repo"

    git config --global --add safe.directory "$INSTALL_DIR/repo"

    if ! git fetch origin "$GIT_BRANCH"; then
        error "Failed to fetch repository changes"
    fi

    local local_hash remote_hash
    local_hash=$(git rev-parse HEAD)
    remote_hash=$(git rev-parse "origin/$GIT_BRANCH")

    if [[ "$local_hash" == "$remote_hash" ]]; then
        log "Repository is up to date"
        return 1
    else
        log "New changes detected: $local_hash -> $remote_hash"
        return 0
    fi
}

sync_repository() {
    cd "$INSTALL_DIR/repo"

    log "Pulling latest changes from $GIT_BRANCH..."

    if ! git pull origin "$GIT_BRANCH"; then
        error "Failed to pull repository changes"
    fi

    find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;

    log "Repository synchronized successfully"
}

run_ansible() {
    cd "$INSTALL_DIR/repo"

    log "Running Ansible configuration..."

    if ansible-playbook site.yml; then
        log "✓ Ansible configuration completed successfully"
    else
        log "⚠ Ansible configuration failed"
        return 1
    fi
}

main() {
    log "Starting Linux Config GitOps sync..."

    acquire_lock

    if check_git_changes; then
        sync_repository
        run_ansible
        log "Sync and configuration completed"
    else
        log "No changes to sync"
    fi
}

main "$@"
EOFSCRIPT

    sudo chmod +x "$INSTALL_DIR/repo/scripts/git-sync.sh"

    # Create systemd service
    sudo tee /etc/systemd/system/linux-config-sync.service > /dev/null <<'EOF'
[Unit]
Description=Linux Config GitOps Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/linux-config.conf
ExecStart=/opt/linux-config/repo/scripts/git-sync.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer
    sudo tee /etc/systemd/system/linux-config-sync.timer > /dev/null <<'EOF'
[Unit]
Description=Linux Config GitOps Sync Timer
Requires=linux-config-sync.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=7min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now linux-config-sync.timer

    log "✓ Systemd services configured and started"
}

setup_launchd_services() {
    log "Creating launchd service for GitOps automation (macOS)..."

    # Create configuration file
    cat > "$HOME/.linux-config.conf" <<EOF
REPO_URL=$REPO_URL
GIT_BRANCH=$GIT_BRANCH
INSTALL_DIR=$INSTALL_DIR
EOF

    # Create scripts directory
    mkdir -p "$INSTALL_DIR/repo/scripts"
    mkdir -p "$INSTALL_DIR/logs"

    # Create git sync script (similar to Linux but without sudo)
    cat > "$INSTALL_DIR/repo/scripts/git-sync.sh" <<'EOFSCRIPT'
#!/bin/bash
# scripts/git-sync.sh - Git sync for Linux Config GitOps (macOS)

set -euo pipefail

source "$HOME/.linux-config.conf"

LOG_FILE="$INSTALL_DIR/logs/git-sync.log"
LOCK_FILE="/tmp/linux-config-sync.lock"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ... (same content as Linux version but without sudo)

main() {
    log "Starting Linux Config GitOps sync (macOS)..."

    cd "$INSTALL_DIR/repo"

    if git fetch origin "$GIT_BRANCH"; then
        local local_hash remote_hash
        local_hash=$(git rev-parse HEAD)
        remote_hash=$(git rev-parse "origin/$GIT_BRANCH")

        if [[ "$local_hash" != "$remote_hash" ]]; then
            log "New changes detected, pulling..."
            git pull origin "$GIT_BRANCH"

            log "Running Ansible configuration..."
            ansible-playbook site.yml
        else
            log "No changes to sync"
        fi
    fi
}

main "$@"
EOFSCRIPT

    chmod +x "$INSTALL_DIR/repo/scripts/git-sync.sh"

    # Create launchd plist
    local plist_file="$HOME/Library/LaunchAgents/org.pineridge.linux-config.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.pineridge.linux-config.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/repo/scripts/git-sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>420</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/logs/git-sync.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/logs/git-sync-error.log</string>
</dict>
</plist>
EOF

    # Load launchd agent
    launchctl load "$plist_file"

    log "✓ Launchd service configured and started"
}

show_completion() {
    log "Linux/macOS Configuration bootstrap completed successfully!"

    echo
    echo "=== SETUP COMPLETE ==="
    echo "✓ Operating System: $OS_TYPE - $OS_FAMILY"
    echo "✓ Ansible installed and configured"
    echo "✓ Repository cloned: $REPO_URL"
    echo "✓ Branch: $GIT_BRANCH"
    echo "✓ GitOps automation enabled"
    echo

    if [[ "$OS_TYPE" == "linux" ]]; then
        echo "=== SYSTEMD SERVICES ==="
        echo "• Sync timer: systemctl status linux-config-sync.timer"
        echo "• View logs: journalctl -u linux-config-sync.service -f"
        echo "• Manual sync: sudo systemctl start linux-config-sync.service"
    else
        echo "=== LAUNCHD SERVICE ==="
        echo "• Service: launchctl list | grep linux-config"
        echo "• View logs: tail -f $INSTALL_DIR/logs/git-sync.log"
        echo "• Manual sync: launchctl start org.pineridge.linux-config.sync"
    fi

    echo
    echo "=== MANUAL OPERATIONS ==="
    echo "• Run configuration: cd $INSTALL_DIR/repo && ansible-playbook site.yml"
    echo "• Run bootstrap: cd $INSTALL_DIR/repo && ansible-playbook bootstrap.yml"
    echo "• Check mode: ansible-playbook site.yml --check"
    echo
    echo "Bootstrap log: $LOG_FILE"
    echo
}

main() {
    log "Starting Linux/macOS Configuration bootstrap..."

    detect_os
    check_prerequisites
    install_ansible
    setup_git_access
    convert_repo_url_to_ssh
    clone_repository
    run_bootstrap
    setup_gitops_automation
    show_completion

    log "Bootstrap completed successfully"
}

# Parse command-line arguments
INTERACTIVE_MODE=false
ENABLE_GIT_PUSH=false
FORCE_ANSIBLE_INSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS] [REPO_URL] [BRANCH]"
            echo
            echo "Options:"
            echo "  --interactive, -i         Enable interactive mode (dev workstation with push access)"
            echo "  --enable-push            Enable Git push access (requires SSH key setup)"
            echo "  --force-ansible          Force Ansible reinstall/upgrade"
            echo "  --repo URL               Repository URL"
            echo "  --branch BRANCH          Git branch (default: main)"
            echo "  --help, -h               Show this help"
            echo
            echo "Examples:"
            echo "  # Read-only installation (lab machine)"
            echo "  $0 https://github.com/yourusername/linux-config.git"
            echo
            echo "  # Development workstation with push access"
            echo "  $0 --interactive https://github.com/yourusername/linux-config.git"
            echo
            echo "  # Custom branch"
            echo "  $0 --branch develop https://github.com/yourusername/linux-config.git"
            exit 0
            ;;
        --interactive|-i)
            INTERACTIVE_MODE=true
            ENABLE_GIT_PUSH=true
            shift
            ;;
        --enable-push)
            ENABLE_GIT_PUSH=true
            shift
            ;;
        --force-ansible)
            FORCE_ANSIBLE_INSTALL=true
            shift
            ;;
        --repo)
            REPO_URL="$2"
            shift 2
            ;;
        --branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        *)
            # Legacy positional arguments
            if [[ -n "${1:-}" ]] && [[ -z "${REPO_URL_SET:-}" ]]; then
                REPO_URL="$1"
                REPO_URL_SET=true
                shift
            elif [[ -n "${1:-}" ]] && [[ -z "${GIT_BRANCH_SET:-}" ]]; then
                GIT_BRANCH="$1"
                GIT_BRANCH_SET=true
                shift
            else
                echo "Unknown argument: $1"
                exit 1
            fi
            ;;
    esac
done

export INTERACTIVE_MODE
export ENABLE_GIT_PUSH
export FORCE_ANSIBLE_INSTALL

main "$@"
