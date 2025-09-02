# Pine Ridge Podman Bootstrap

This bootsrap script is used to configure a Podman container host to deploy Podman quadlets in a gitops style.

The design intention here is that the deployment repo itself is a private GitHub repo and this bootstrap script generates a deploy key for the host to use to pull the repo. The deploy key is then added to the repo as a deploy key manually.

This bootstrap script is highly opinionated to the design requirements of the Pine Ridge Podman project and may not be suitable for other use cases.

# Usage

# Pine Ridge Podman Bootstrap

Bootstrap script for setting up the Pine Ridge Podman GitOps system using Ansible.

## Features

- **Ansible-based Configuration**: Uses Ansible for idempotent setup and management
- **GitOps Automation**: Automatically syncs configuration from GitHub repository
- **Container Management**: Full Podman and quadlet support
- **SSH Deploy Keys**: Secure read-only repository access
- **Systemd Integration**: Automated timers for continuous deployment

## Quick Start

### One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/yourusername/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh | bash -s -- --repo https://github.com/yourusername/pine-ridge-podman.git
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
2. **Automatic sync** every 5 minutes via systemd timer
3. **Ansible execution** applies configuration changes
4. **Container deployment** through quadlets and systemd

## Usage Examples

### Custom Repository
```bash
./bootstrap.sh --repo https://github.com/yourusername/my-podman-config.git
```

### Different Branch
```bash
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --branch develop
```

### Legacy Format (still supported)
```bash
./bootstrap.sh https://github.com/yourusername/pine-ridge-podman.git main
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
systemctl is-active podman-ansible.timer

# Manual sync test
sudo /opt/pine-ridge-podman/repo/scripts/sync-repo-ansible.sh

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
