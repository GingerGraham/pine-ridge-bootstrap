# Pine Ridge WAF Bootstrap

This bootstrap script configures a Linux server to deploy and manage a Web Application Firewall (WAF) using Ansible in a GitOps style. The script sets up automated deployment of WAF configurations, SSL certificates, and security policies from a private GitHub repository.

The design intention here is that the WAF configuration repo is a private GitHub repository and this bootstrap script generates a deploy key for the host to use to pull the repo. The deploy key is then added to the repo as a deploy key manually for secure, automated access.

This bootstrap script is highly opinionated to the design requirements of the Pine Ridge WAF project and may not be suitable for other use cases.

## What This Script Does

The bootstrap script performs the following operations:

1. **Ansible Installation**: Installs Ansible Core and required collections for system management
2. **SSH Authentication Setup**: Generates an SSH deploy key for secure GitHub repository access
3. **Repository Cloning**: Clones the WAF configuration repository to `/opt/pine-ridge-waf`
4. **Vault Password Configuration**: Securely stores the Ansible vault password for encrypted secrets
5. **Initial Deployment**: Runs the initial WAF configuration playbook
6. **GitOps Services**: Sets up systemd services and timers for automated configuration updates
7. **Security Configuration**: Configures proper permissions and secure access

## Prerequisites

- **Operating System**: Red Hat Enterprise Linux, CentOS, or Fedora (uses `dnf` package manager)
- **User Access**: Non-root user with sudo privileges
- **Network Access**: Internet connectivity for package installation and GitHub access
- **GitHub Repository**: A private repository containing your WAF Ansible configuration

## Usage

### Basic Usage (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-waf.git
```

### Advanced Usage with Custom Branch

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-waf.git develop
```

### Local Execution

```bash
# Download the script
wget https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh

# Make it executable
chmod +x bootstrap.sh

# Run with your repository URL
./bootstrap.sh https://github.com/GingerGraham/pine-ridge-waf.git
```

## Setup Process

### 1. SSH Key Generation and GitHub Setup

During the bootstrap process, the script will:

1. Generate an SSH deploy key (`/root/.ssh/waf_gitops_ed25519`)
2. Display the public key for you to copy
3. Pause for you to add the deploy key to your GitHub repository

**To add the deploy key to GitHub:**

1. Go to your GitHub repository → **Settings** → **Deploy keys**
2. Click **"Add deploy key"**
3. Give it a title like **"WAF GitOps Server"**
4. Paste the public key displayed by the script
5. **Do NOT** check "Allow write access" (read-only is safer for security)
6. Click **"Add key"**
7. Press Enter in the terminal to continue

### 2. Ansible Vault Password Setup

The script will prompt you to enter the Ansible vault password:

- This password is used to decrypt sensitive configuration files
- It's stored securely in `/etc/pine-ridge-waf-vault-pass` with root-only access
- The password is used by automated services for unattended deployments

### 3. Automated Services Configuration

The script creates systemd services for GitOps automation:

- **`waf-ansible.service`**: Runs Ansible playbooks to apply WAF configuration
- **`waf-ansible.timer`**: Triggers configuration updates every 10 minutes
- **Configuration**: Stored in `/etc/pine-ridge-waf.conf`

## Post-Installation

### Monitoring and Management

**Check service status:**
```bash
sudo systemctl status waf-ansible.timer
sudo systemctl list-timers waf-ansible.timer
```

**View logs:**
```bash
# Real-time logs
sudo journalctl -u waf-ansible.service -f

# Recent logs
sudo journalctl -u waf-ansible.service --since "1 hour ago"
```

**Manual deployment:**
```bash
cd /opt/pine-ridge-waf/repo
sudo ansible-playbook site.yml
```

### File Locations

- **Installation Directory**: `/opt/pine-ridge-waf/`
- **Repository Clone**: `/opt/pine-ridge-waf/repo/`
- **Configuration File**: `/etc/pine-ridge-waf.conf`
- **Vault Password**: `/etc/pine-ridge-waf-vault-pass`
- **SSH Deploy Key**: `/root/.ssh/waf_gitops_ed25519`
- **Bootstrap Log**: `/tmp/waf-bootstrap.log`

### Troubleshooting

**SSH Connection Issues:**
```bash
# Test SSH connection to GitHub
sudo ssh -T git@github.com
```

**Ansible Vault Issues:**
```bash
# Test vault password
sudo ansible-vault view /opt/pine-ridge-waf/repo/inventory/group_vars/vault.yml
```

**Service Debugging:**
```bash
# Check service status
sudo systemctl status waf-ansible.service

# View service logs
sudo journalctl -u waf-ansible.service --no-pager
```

## Security Considerations

- The SSH deploy key provides read-only access to your repository
- Vault passwords are stored with root-only permissions
- All services run as root for system-level configuration management
- Network security policies are applied automatically through the WAF configuration

## Repository Structure Requirements

Your WAF repository should contain:

- `site.yml` - Main Ansible playbook
- `inventory/` - Ansible inventory configuration
- `inventory/group_vars/vault.yml` - Encrypted secrets (optional)
- `scripts/sync-repo.sh` - Repository synchronization script
- Ansible roles for WAF components (firewall, nginx, etc.)

## Support

This bootstrap script is designed specifically for the Pine Ridge WAF project architecture. For issues or customizations, refer to the main project documentation or repository issues.