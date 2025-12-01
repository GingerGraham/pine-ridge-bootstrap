# Linux/macOS Setup Bootstrap

Bootstrap script for automated Linux and macOS configuration using Ansible GitOps.

## Overview

This bootstrap script sets up a complete GitOps-based configuration management system for:
- **Linux**: Fedora/RHEL, Ubuntu/Debian, SUSE/openSUSE, Arch Linux
- **macOS**: via Homebrew

The script will:
1. Detect your operating system
2. Install Ansible and dependencies
3. Clone the [linux-config](https://github.com/yourusername/linux-config) repository
4. Set up Git access (read-only or with push access)
5. Run initial configuration
6. Set up automatic sync service (systemd on Linux, launchd on macOS)

## Quick Start

### Lab Machine (Read-Only Consumer)

For machines that will only pull configuration updates:

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/linux-setup/bootstrap.sh | bash -s -- https://github.com/yourusername/linux-config.git
```

### Development Workstation (With Push Access)

For machines that will develop and push configuration changes:

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/linux-setup/bootstrap.sh | bash -s -- --interactive https://github.com/yourusername/linux-config.git
```

### Custom Branch

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/linux-setup/bootstrap.sh | bash -s -- --branch develop https://github.com/yourusername/linux-config.git
```

## Usage

### Command Line Options

```bash
./bootstrap.sh [OPTIONS] [REPO_URL] [BRANCH]
```

**Options:**
- `--interactive, -i` - Enable interactive mode for development workstations (sets up SSH keys for push access)
- `--enable-push` - Enable Git push access without full interactive mode
- `--force-ansible` - Force Ansible reinstall/upgrade even if already installed
- `--repo URL` - Specify repository URL
- `--branch BRANCH` - Specify Git branch (default: main)
- `--help, -h` - Show help message

**Positional Arguments:**
1. `REPO_URL` - The Git repository URL (HTTPS for read-only, converted to SSH for push access)
2. `BRANCH` - The Git branch to use (optional, default: main)

### Examples

**1. Read-only lab machine:**
```bash
./bootstrap.sh https://github.com/yourusername/linux-config.git
```

**2. Development workstation with push access:**
```bash
./bootstrap.sh --interactive https://github.com/yourusername/linux-config.git
```

**3. Custom branch:**
```bash
./bootstrap.sh --repo https://github.com/yourusername/linux-config.git --branch feature-testing
```

**4. Force Ansible upgrade:**
```bash
./bootstrap.sh --force-ansible https://github.com/yourusername/linux-config.git
```

## Installation Modes

### Read-Only Mode (Default)

- Uses HTTPS to clone repository (no authentication needed for public repos)
- Cannot push changes back to repository
- Ideal for lab machines, test systems, production servers
- Automatically syncs from Git every 7 minutes

### Development Mode (--interactive)

- Sets up SSH key for Git authentication
- Can push changes back to repository
- Ideal for development workstations
- Allows iterative development of configurations
- Still auto-syncs but allows manual commits and pushes

## What Gets Installed

### On All Systems
- Git
- Ansible (ansible-core)
- Python 3 and pip
- Ansible collections: community.general, ansible.posix

### On Linux
- Distribution-specific package manager tools
- Systemd services for GitOps automation

### On macOS
- Homebrew (if not already installed)
- Ansible collection: community.crypto
- Launchd agent for GitOps automation

## Directory Structure

The bootstrap creates the following structure:

```
/opt/linux-config/          # Installation directory (Linux)
~/linux-config/             # Installation directory (macOS)
├── repo/                   # Cloned git repository
│   ├── ansible.cfg
│   ├── site.yml
│   ├── bootstrap.yml
│   ├── inventory/
│   ├── roles/
│   └── scripts/
│       └── git-sync.sh    # Generated sync script
└── logs/
    └── git-sync.log       # Sync logs
```

## GitOps Automation

### Linux (systemd)

The bootstrap creates two systemd units:

**Service:** `linux-config-sync.service`
- Syncs repository and runs Ansible configuration
- Runs via timer every 7 minutes

**Timer:** `linux-config-sync.timer`
- Triggers the sync service
- Starts 2 minutes after boot
- Runs every 7 minutes

**Management Commands:**
```bash
# Check timer status
systemctl status linux-config-sync.timer

# View sync logs
journalctl -u linux-config-sync.service -f

# Manual sync
sudo systemctl start linux-config-sync.service

# Disable auto-sync
sudo systemctl stop linux-config-sync.timer
sudo systemctl disable linux-config-sync.timer
```

### macOS (launchd)

The bootstrap creates a launchd agent:

**Agent:** `org.pineridge.linux-config.sync`
- Syncs repository and runs Ansible configuration
- Runs every 7 minutes (420 seconds)

**Management Commands:**
```bash
# Check agent status
launchctl list | grep linux-config

# View logs
tail -f /opt/linux-config/logs/git-sync.log

# Manual sync
launchctl start org.pineridge.linux-config.sync

# Disable auto-sync
launchctl unload ~/Library/LaunchAgents/org.pineridge.linux-config.sync.plist
```

## SSH Key Setup (Development Mode)

When using `--interactive` mode, the bootstrap will:

1. Generate an ED25519 SSH key
2. Display the public key
3. Prompt you to add it to GitHub
4. Wait for confirmation before continuing

**For Linux:**
- SSH key location: `/root/.ssh/linux_config_ed25519`
- Used for system-level Git operations

**For macOS:**
- SSH key location: `~/.ssh/linux_config_ed25519`
- Used for user-level Git operations

**Adding the key to GitHub:**
1. Copy the displayed public key
2. Go to GitHub → Settings → SSH and GPG keys
3. Click "New SSH key"
4. Paste the key and give it a descriptive title
5. Save

## Troubleshooting

### Ansible Not Found After Installation

```bash
# Ensure PATH is updated
hash -r

# Verify installation
which ansible
ansible --version
```

### Git Clone Fails (SSH)

For development mode, ensure:
1. SSH key is added to your GitHub account
2. Test connection: `ssh -T git@github.com`
3. Check SSH config: `cat ~/.ssh/config` (or `/root/.ssh/config`)

### Permission Denied Errors

Ensure your user has sudo access:
```bash
sudo -v
```

### macOS Homebrew Issues

If Homebrew installation fails:
```bash
# Install Homebrew manually
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Re-run bootstrap
./bootstrap.sh https://github.com/yourusername/linux-config.git
```

### Sync Service Not Running

**Linux:**
```bash
# Check service status
systemctl status linux-config-sync.timer
systemctl status linux-config-sync.service

# View logs
journalctl -u linux-config-sync.service -n 50

# Restart
sudo systemctl restart linux-config-sync.timer
```

**macOS:**
```bash
# Check agent
launchctl list | grep linux-config

# View logs
cat /opt/linux-config/logs/git-sync.log

# Reload agent
launchctl unload ~/Library/LaunchAgents/org.pineridge.linux-config.sync.plist
launchctl load ~/Library/LaunchAgents/org.pineridge.linux-config.sync.plist
```

## Configuration Files

The bootstrap creates configuration files:

**Linux:** `/etc/linux-config.conf`
```bash
REPO_URL=git@github.com:yourusername/linux-config.git
GIT_BRANCH=main
INSTALL_DIR=/opt/linux-config
```

**macOS:** `~/.linux-config.conf`
```bash
REPO_URL=git@github.com:yourusername/linux-config.git
GIT_BRANCH=main
INSTALL_DIR=/opt/linux-config
```

## Integration with linux-config Repository

The bootstrap works with the [linux-config](https://github.com/yourusername/linux-config) repository structure:

- `bootstrap.yml` - Initial system setup (minimal packages)
- `site.yml` - Full configuration (all packages and settings)
- `inventory/hosts.yml` - Host definitions
- `roles/` - Ansible roles for different configuration aspects

## Security Considerations

### Read-Only Mode
- No authentication credentials stored
- Cannot modify repository
- Safe for untrusted environments

### Development Mode
- SSH private key stored on system
- Full access to push to repository
- Protect your SSH key with proper file permissions
- Consider using branch protection rules on GitHub

## Branch Protection (Recommended)

For repositories with development workstations, protect the `main` branch:

1. Go to GitHub → Repository → Settings → Branches
2. Add branch protection rule for `main`
3. Enable:
   - Require pull request reviews before merging
   - Require status checks to pass
   - Require branches to be up to date before merging

This ensures changes go through review even from dev machines.

## Uninstallation

### Linux
```bash
# Stop and disable services
sudo systemctl stop linux-config-sync.timer
sudo systemctl disable linux-config-sync.timer
sudo systemctl disable linux-config-sync.service

# Remove service files
sudo rm /etc/systemd/system/linux-config-sync.service
sudo rm /etc/systemd/system/linux-config-sync.timer
sudo systemctl daemon-reload

# Remove configuration and repository
sudo rm -rf /opt/linux-config
sudo rm /etc/linux-config.conf

# Remove SSH key (if in dev mode)
sudo rm /root/.ssh/linux_config_ed25519*
```

### macOS
```bash
# Unload launchd agent
launchctl unload ~/Library/LaunchAgents/org.pineridge.linux-config.sync.plist

# Remove files
rm ~/Library/LaunchAgents/org.pineridge.linux-config.sync.plist
rm -rf /opt/linux-config
rm ~/.linux-config.conf

# Remove SSH key (if in dev mode)
rm ~/.ssh/linux_config_ed25519*
```

## Related Documentation

- [linux-config README](../../linux-config/README.md)
- [pine-ridge-bootstrap Main README](../README.md)
- [WAF Bootstrap](../pine-ridge-waf/pine-ridge-waf-bootstrap.md)
- [Podman Bootstrap](../pine-ridge-podman/pine-ridge-podman-bootstrap.md)

## Support

For issues:
1. Check the bootstrap log: `/tmp/linux-setup-bootstrap-*.log`
2. Check sync logs: `/opt/linux-config/logs/git-sync.log`
3. Review systemd/launchd status
4. Open an issue on GitHub

## License

See main repository [LICENSE](../LICENSE) for details.
