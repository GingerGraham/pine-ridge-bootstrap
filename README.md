# Pine Ridge Bootstrap

This repository contains bootstrap scripts designed to launch and configure other Pine Ridge projects that may be hosted in private repositories. The intention is to provide a simple way to get a project started from a public repository while keeping the actual project configuration and secrets private.

## Available Bootstrap Scripts

The following Pine Ridge projects are currently supported:

### 🔥 [Pine Ridge WAF](/pine-ridge-waf/pine-ridge-waf-bootstrap.md)
Bootstrap script for deploying a Web Application Firewall (WAF) using Ansible GitOps automation.

**Quick Start:**
```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-waf/bootstrap.sh | bash -s -- --repo https://github.com/yourusername/pine-ridge-waf.git
```

### 🐳 [Pine Ridge Podman](/pine-ridge-podman/pine-ridge-podman-bootstrap.md)
Bootstrap script for configuring a Podman container host to deploy containers using quadlets in a GitOps style.

**Quick Start:**
```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh | bash -s -- --repo https://github.com/yourusername/pine-ridge-podman.git
```

## Key Features

### 🔒 **Secure GitOps Deployment**
- SSH deploy keys for secure, read-only repository access
- Automated GitHub integration with manual key approval
- Encrypted secrets management with Ansible Vault

### 🚀 **Automated Configuration Management**
- Ansible-based infrastructure as code
- Systemd timers for automatic updates from Git
- Branch support including pathed branches (`feat/branch-name`)

### 🛡️ **Production-Ready Security**
- Root privilege management for system services
- Encrypted password storage with group-based access
- Network security policies and firewall management

### 🔧 **Developer-Friendly**
- Interactive and non-interactive modes
- Support for feature branches and testing
- Comprehensive logging and troubleshooting tools

## Branch Support

Both bootstrap scripts fully support:
- **Standard branches**: `main`, `develop`, `staging`
- **Pathed branches**: `feat/moving-to-ansible`, `bugfix/issue-123`, `release/v1.2.3`

**Examples:**
```bash
# Use a feature branch for testing
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-waf.git --branch feat/moving-to-ansible

# Use a development branch
./bootstrap.sh --repo https://github.com/yourusername/pine-ridge-podman.git --branch develop
```

## Update Frequencies

- **WAF**: Updates every 10 minutes (infrastructure changes less frequently)
- **Podman**: Updates every 5 minutes (container deployments change more frequently)

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   GitHub Repo   │    │  Bootstrap      │    │   Target        │
│   (Private)     │───▶│  Script         │───▶│   Server        │
│                 │    │  (Public)       │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   SSH Deploy    │    │   Ansible       │    │   GitOps        │
│   Key           │    │   Installation  │    │   Services      │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Getting Started

1. **Choose your project** (WAF or Podman)
2. **Prepare your private repository** with the project configuration
3. **Run the bootstrap script** on your target server
4. **Add the SSH deploy key** to your GitHub repository
5. **Configure secrets** (if using Ansible Vault)
6. **Monitor deployment** through systemd services

## 🎯 Templated Sync Script System

Pine Ridge Bootstrap uses a **standardized template system** for generating sync scripts across all projects:

### **Benefits:**
- ✅ **Consistent functionality** across all projects
- ✅ **Comprehensive features** (logging, locking, error handling, branch support)
- ✅ **Easy project addition** through configuration files
- ✅ **Single source of truth** for sync logic

### **Template Structure:**
```
templates/
├── sync-repo-template.sh          # Master template with common logic
├── project-configs/
│   ├── waf.conf                   # WAF-specific configuration
│   ├── podman.conf                # Podman-specific configuration
│   └── example-project.conf       # Template for new projects
└── README.md                      # Template system documentation
```

### **Adding New Projects:**

To add support for a new Pine Ridge project:

1. **📝 Create Project Configuration**: Copy `templates/project-configs/example-project.conf` and customize it
2. **🔧 Update Bootstrap Script**: Use the template system in your bootstrap script
3. **📚 Update Documentation**: Add project documentation and examples

**⚠️ Important**: Each new project **must have a configuration file** in `templates/project-configs/` or the bootstrap will fail.

For detailed instructions, see [`templates/README.md`](templates/README.md).

## Support

Each bootstrap script includes comprehensive documentation and troubleshooting guides. See the individual project documentation for detailed setup instructions and support information.

For template system support and adding new projects, see the [Template System Documentation](templates/README.md).
