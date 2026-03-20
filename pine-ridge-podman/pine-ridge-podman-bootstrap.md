# Pine Ridge Podman Bootstrap

This bootsrap script is used to configure a Podman container host to deploy Podman quadlets in a gitops style.

The design intention here is that the deployment repo itself is a private GitHub repo and this bootstrap script generates a deploy key for the host to use to pull the repo. The deploy key is then added to the repo as a deploy key manually.

This bootstrap script is highly opinionated to the design requirements of the Pine Ridge Podman project and may not be suitable for other use cases.

# Usage

# Pine Ridge Podman Bootstrap

Bootstrap script for setting up the Pine Ridge Podman GitOps system using Ansible.

## Features

- **Ansible-based Configuration**: Uses Ansible for idempotent setup and management
- **Environment-Aware GitOps**: Supports dev branch tracking, preprod main tracking, and prod tagged releases
- **Container Management**: Full Podman and quadlet support
- **SSH Deploy Keys**: Secure read-only repository access
- **Systemd Integration**: Automated timers for continuous deployment

## Quick Start

### One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh | bash -s -- --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev
```

### Interactive Mode (for SSH sessions)

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh | bash -s -- --interactive --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev
```

### Environment Modes

```bash
# Dev - branch tracking (default branch: main)
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev

# Preprod - always tracks main
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment preprod

# Prod - always deploys the latest stable semver release tag
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment prod
```

### Manual Install

1. **Download and run the bootstrap script:**

   ```bash
   wget https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh
   chmod +x bootstrap.sh
   ./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git
   ```

2. **Add the displayed SSH key to your repository** as a deploy key (read-only)

3. **Monitor the initial setup:**
   ```bash
   journalctl -u podman-ansible.service -f
   ```

## What Gets Installed

### System Packages

- **Ansible** with core collections (community.general, ansible.posix, containers.podman)
- **Podman** and podman-compose
- **Git** for repository management
- **yq** for YAML processing

### Directory Structure

```
/opt/pine-ridge-podman/
├── repo/                    # Git repository clone
│   ├── ansible/            # Ansible playbooks and roles
│   ├── quadlets/           # Container definitions
│   └── scripts/            # Management scripts
├── logs/                   # Service logs
├── secrets/                # Encrypted secrets
├── backups/                # Configuration backups
└── data/                   # Application data volumes
```

### Services

- **podman-ansible.service**: Runs Ansible configuration
- **podman-ansible.timer**: Triggers updates every 5 minutes
- **podman.socket**: Container management service

## GitOps Workflow

1. **Push changes** to your pine-ridge-podman repository
2. **Automatic sync** every 5 minutes via systemd timer (faster than WAF due to container nature)
3. **Ansible execution** applies configuration changes
4. **Container deployment** through quadlets and systemd

## Usage Examples

### Custom Repository

```bash
./bootstrap.sh --repo https://github.com/yourusername/my-podman-config.git
```

### Different Branch (dev only, including pathed branches)

```bash
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev --branch develop
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev --branch feat/moving-to-ansible
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev --branch bugfix/container-issue
```

### Legacy Format (still supported)

```bash
./bootstrap.sh https://github.com/yourusername/pine-ridge-podman.git main
./bootstrap.sh https://github.com/yourusername/pine-ridge-podman.git feat/moving-to-ansible
```

### Command Line Options

```bash
Usage: ./bootstrap.sh [OPTIONS] [--repo REPO_URL] [--environment ENV] [--branch BRANCH]

Options:
  --interactive, -i          Force interactive mode (for SSH sessions or troubleshooting)
  --repo REPO_URL           Repository URL (required)
  --environment ENV         Deployment mode: dev, preprod, or prod
  --branch BRANCH           Git branch to use for dev only (default: main)
  --debug, --verbose        Enable verbose troubleshooting output
  --help, -h                Show help message

Examples:
  ./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev
  ./bootstrap.sh --interactive --repo https://github.com/yourusername/pine-ridge-podman.git --environment dev --branch feat/moving-to-ansible
  ./bootstrap.sh https://github.com/yourusername/pine-ridge-podman.git develop  # legacy format
```

## Monitoring and Management

### Check Service Status

```bash
# Timer status
systemctl list-timers podman-ansible.timer

# Service logs
journalctl -u podman-ansible.service -f

# Manual deployment
cd /opt/pine-ridge-podman/repo/ansible
sudo ansible-playbook site.yml
```

### Container Management

```bash
# List running containers
podman ps

# Check quadlet services
systemctl list-units --type=service | grep -E "\.(service)$"
```

## Integration with Pine Ridge Bootstrap

This bootstrap script is designed to work with the [Pine Ridge Bootstrap](https://github.com/yourusername/pine-ridge-bootstrap) system:

- **Consistent SSH key management** across all Pine Ridge components
- **Standardized GitOps patterns** following the WAF approach
- **Ansible-first configuration** for maintainability and consistency
- **Templated sync scripts** generated from common template with Podman-specific customizations

### Repo-Managed Sync Scripts

The bootstrap now validates and uses the scripts provided by the `pine-ridge-podman` repository itself:

- `scripts/sync-repo.sh` handles branch or tag synchronization
- `scripts/switch-branch.sh` manages dev branch switching and prod tag pinning
- `/usr/local/bin/switch-branch` is installed by Ansible as a stable wrapper

## Security Features

- **SSH Deploy Keys**: Read-only repository access
- **Root Privilege Management**: Secure systemd service execution
- **Secrets Management**: Encrypted secrets handling via Ansible
- **Network Isolation**: Podman provides container isolation

## Troubleshooting

### SSH Key Issues

```bash
# Test SSH connection
sudo ssh -T git@github.com

# Check key permissions
ls -la /root/.ssh/podman_gitops_ed25519*
```

### Service Issues

```bash
# Check timer is active
systemctl is-active pine-ridge-git-sync.timer

# Manual sync test
sudo /opt/pine-ridge-podman/repo/scripts/sync-repo.sh

# Ansible syntax check
cd /opt/pine-ridge-podman/repo/ansible
ansible-playbook site.yml --syntax-check
```

### Repository Issues

```bash
# Check repository status
cd /opt/pine-ridge-podman/repo
git status
git remote -v
```

## Differences from Script-Based Approach

This Ansible-based bootstrap provides several advantages over the previous script-based approach:

- **Idempotency**: Safe to run multiple times
- **Declarative**: Describes desired state vs imperative steps
- **Modularity**: Reusable roles for different components
- **Consistency**: Same patterns as pine-ridge-waf
- **Better Error Handling**: Built-in Ansible error management

## Requirements

- **Fedora/RHEL/CentOS** server
- **sudo privileges** for the user running the bootstrap
- **Internet connectivity** for package installation and Git access
- **GitHub repository** with pine-ridge-podman configuration

## Support

For issues with this bootstrap script:

1. Check the bootstrap log: `/tmp/podman-bootstrap-<timestamp>.log`
2. Verify prerequisites and permissions
3. Test SSH connectivity to GitHub
4. Check systemd service status and logs
