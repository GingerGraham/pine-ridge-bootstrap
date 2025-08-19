# Pine Ridge WAF Bootstrap <!-- omit in toc -->

This bootstrap script configures a Linux server to deploy and manage a Web Application Firewall (WAF) using Ansible in a GitOps style. The script sets up automated deployment of WAF configurations, SSL certificates, and security policies from a private GitHub repository.

The design intention here is that the WAF configuration repo is a private GitHub repository and this bootstrap script generates a deploy key for the host to use to pull the repo. The deploy key is then added to the repo as a deploy key manually for secure, automated access.

This bootstrap script is highly opinionated to the design requirements of the Pine Ridge WAF project and may not be suitable for other use cases.

## Table Of Contents <!-- omit in toc -->

- [What This Script Does](#what-this-script-does)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Basic Usage (Recommended)](#basic-usage-recommended)
  - [Interactive Mode for SSH Sessions](#interactive-mode-for-ssh-sessions)
  - [Advanced Usage with Custom Branch](#advanced-usage-with-custom-branch)
  - [Interactive Mode with Custom Branch](#interactive-mode-with-custom-branch)
  - [Local Execution](#local-execution)
  - [Command Line Options](#command-line-options)
- [When to Use Each Method](#when-to-use-each-method)
  - [🖥️ **IP KVM Console (Production Servers)**](#️-ip-kvm-console-production-servers)
  - [🔐 **SSH Sessions (Remote Management)**](#-ssh-sessions-remote-management)
  - [🤖 **Automated Deployment (CI/CD, Scripts)**](#-automated-deployment-cicd-scripts)
  - [🔧 **Development/Testing**](#-developmenttesting)
  - [🔄 **Re-running After Partial Setup**](#-re-running-after-partial-setup)
- [Setup Process](#setup-process)
  - [1. SSH Key Generation and GitHub Setup](#1-ssh-key-generation-and-github-setup)
  - [2. Ansible Vault Password Setup](#2-ansible-vault-password-setup)
  - [3. Automated Services Configuration](#3-automated-services-configuration)
- [Post-Installation](#post-installation)
  - [Monitoring and Management](#monitoring-and-management)
  - [File Locations](#file-locations)
  - [Important Notes](#important-notes)
  - [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Repository Structure Requirements](#repository-structure-requirements)
- [Support](#support)


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

### Interactive Mode for SSH Sessions

When running the script via SSH or when you need to ensure interactive prompts work:

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git
```

### Advanced Usage with Custom Branch

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-waf.git develop
```

### Interactive Mode with Custom Branch

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git develop
```

### Local Execution

```bash
# Download the script
wget https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh

# Make it executable
chmod +x bootstrap.sh

# Run with your repository URL
./bootstrap.sh https://github.com/GingerGraham/pine-ridge-waf.git

# Or with interactive mode
./bootstrap.sh --interactive https://github.com/GingerGraham/pine-ridge-waf.git
```

### Command Line Options

```bash
# Show help
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --help

# Available options:
#   --interactive, -i    Force interactive mode for vault password setup
#   --help, -h          Show help message
```

## When to Use Each Method

### 🖥️ **IP KVM Console (Production Servers)**
Use the basic method - the script will automatically detect console interaction:
```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-waf.git
```

### 🔐 **SSH Sessions (Remote Management)**
Use interactive mode to ensure vault password prompts work correctly:
```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git
```

### 🤖 **Automated Deployment (CI/CD, Scripts)**
Use basic mode - vault password setup will be skipped and can be configured later:
```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-waf.git
```

### 🔧 **Development/Testing**
Download and run locally for easier debugging:
```bash
wget https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh --interactive https://github.com/GingerGraham/pine-ridge-waf.git
```

### 🔄 **Re-running After Partial Setup**
The script intelligently handles partial completions:
- **Existing SSH keys**: Automatically regenerated
- **Existing repository**: Updated or re-cloned as needed
- **Placeholder vault password**: Will prompt for real password in interactive mode
- **Real vault password**: Will ask if you want to update it

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

The script handles vault password setup differently depending on how it's executed:

**Interactive Mode (Console, SSH with --interactive flag):**
- Prompts you to enter the Ansible vault password interactively
- Confirms the password to prevent typos
- Stores it securely in `/etc/pine-ridge-waf-vault-pass` with group-based access
- Creates a `waf-vault` group and adds the current user to it
- Automatically tests if group membership is immediately active
- **Note**: If group access isn't immediately active, you can run `newgrp waf-vault` or log out/in

**Non-Interactive Mode (curl | bash without --interactive):**
- Skips interactive password prompts to avoid hanging
- Creates a placeholder password file
- Provides instructions for setting up the password later

**Re-running the Script:**
- Detects if a placeholder password exists and prompts for a real one (when interactive)
- Asks if you want to update an existing real password
- Automatically handles existing vault configurations

**Manual Setup Later:**
If the script ran in non-interactive mode, you can set up the vault password later by:
```bash
# Re-run with interactive mode
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git

# Or use a setup script (if available in your repository)
sudo /opt/pine-ridge-waf/repo/scripts/setup-vault-password.sh
```

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
- **Bootstrap Log**: `/tmp/waf-bootstrap-<timestamp>.log`

### Important Notes

- **Script Re-execution**: The script can be safely run multiple times and will handle existing installations intelligently
- **Vault Password**: If the script runs in non-interactive mode, it creates a placeholder password that needs to be updated later
- **SSH Keys**: Deploy keys are automatically regenerated on each run to ensure consistency
- **Repository Updates**: Existing repository clones are updated rather than replaced when possible

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

# Check if vault password is set properly
sudo cat /etc/pine-ridge-waf-vault-pass

# Check vault file permissions and group membership
ls -la /etc/pine-ridge-waf-vault-pass
groups

# If you see "VAULT_PASSWORD_NOT_SET", run the script in interactive mode:
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git

# If you get permission denied errors:
# 1. Check if you're in the waf-vault group: groups
# 2. If not in the group, log out and back in, or run: newgrp waf-vault
# 3. If still having issues, check file permissions: ls -la /etc/pine-ridge-waf-vault-pass
```

**Interactive Mode Not Working:**
```bash
# If running via SSH and prompts don't appear, try:
# 1. Download and run locally
wget https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh --interactive https://github.com/GingerGraham/pine-ridge-waf.git

# 2. Or use explicit interactive flag with curl
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --interactive https://github.com/GingerGraham/pine-ridge-waf.git
```

**Re-running After Failures:**
```bash
# The script handles partial completions gracefully and can be re-run safely
# It will detect existing components and update or recreate them as needed

# To force a complete fresh start, remove the installation directory:
sudo rm -rf /opt/pine-ridge-waf
sudo rm -f /etc/pine-ridge-waf*
sudo rm -f /root/.ssh/waf_gitops_ed25519*
```

**Service Debugging:**
```bash
# Check service status
sudo systemctl status waf-ansible.service

# View service logs
sudo journalctl -u waf-ansible.service --no-pager

# Check timer status
sudo systemctl list-timers waf-ansible.timer
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