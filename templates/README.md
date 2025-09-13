# Pine Ridge Bootstrap Templates

This directory contains template files and configurations for generating standardized sync scripts across Pine Ridge projects.

## 🎯 Purpose

The template system provides:
- **Standardized sync functionality** across all Pine Ridge projects
- **Project-specific customization** through configuration files
- **Single source of truth** for sync script logic
- **Easy addition of new projects** without duplicating code

## 📁 Directory Structure

```
templates/
├── README.md                      # This file
├── sync-repo-template.sh          # Master template for sync scripts
├── generate-sync-script.sh        # Template generator utility
└── project-configs/
    ├── waf.conf                   # WAF-specific configuration
    ├── podman.conf                # Podman-specific configuration
    └── example-project.conf       # Template for new projects
```

## 🚀 How It Works

### 1. Master Template (`sync-repo-template.sh`)
Contains all the common sync functionality with placeholder variables:
- Git operations (fetch, pull, reset, branch switching)
- SSH key management
- Lock file management to prevent concurrent runs
- Comprehensive logging and error handling
- Branch support (including pathed branches like `feat/something`)

### 2. Project Configurations (`project-configs/*.conf`)
Define project-specific values and functions:
- Configuration file paths
- SSH key names  
- Lock file locations
- Repository validation logic
- Post-sync actions (vault verification, deployment triggers, etc.)

### 3. Template Generation
During bootstrap, the template is processed with project-specific values to create a customized sync script for each project.

## ✅ Template Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `{{PROJECT_NAME}}` | Human-readable project name | `WAF`, `Podman` |
| `{{CONFIG_FILE}}` | Path to project config file | `/etc/pine-ridge-waf.conf` |
| `{{SSH_KEY_NAME}}` | SSH key filename | `waf_gitops_ed25519` |
| `{{LOCK_FILE}}` | Lock file for concurrent execution | `/var/run/waf-sync.lock` |
| `{{VALIDATION_CHECK}}` | Repository structure validation | Check for `site.yml` or `quadlets/` |
| `{{POST_SYNC_ACTIONS}}` | Project-specific post-sync functions | Vault verification, deployment triggers |

## 🆕 Adding a New Project

To add support for a new Pine Ridge project, create a new configuration file:

### 1. Create Project Configuration

Create `templates/project-configs/your-project.conf`:

```bash
# Your Project Configuration for Sync Script Template
# This file defines project-specific variables and functions

# Basic project identification
PROJECT_NAME="YourProject"
CONFIG_FILE="/etc/pine-ridge-yourproject.conf"
SSH_KEY_NAME="yourproject_gitops_ed25519"
LOCK_FILE="/var/run/yourproject-sync.lock"

# Repository validation function
VALIDATION_CHECK='# Validate your project repository structure
    if [[ ! -f "your-required-file.yml" ]]; then
        error "Invalid repository structure: your-required-file.yml not found"
    fi

    if [[ ! -d "your-required-directory" ]]; then
        log "Warning: your-required-directory not found, some features may be unavailable"
    fi'

# Post-sync actions function  
POST_SYNC_ACTIONS='your_post_sync_function() {
    log "Running your project specific post-sync actions..."
    
    # Add your project-specific logic here
    # Examples:
    # - Reload services
    # - Validate configurations  
    # - Trigger deployments
    # - Send notifications
    
    log "Your project post-sync actions completed"
}

post_sync_actions() {
    your_post_sync_function
}

post_sync_verification() {
    # Add any verification that should run even when no changes are detected
    log "Post-sync verification: Add your checks here"
}'
```

### 2. Update Bootstrap Script

In your new bootstrap script, use the template system:

```bash
# Generate sync script from comprehensive template
log "Generating sync script from template..."

sudo tee "$INSTALL_DIR/repo/scripts/sync-repo.sh" > /dev/null <<'EOF'
#!/bin/bash
# scripts/sync-repo.sh - GitOps repository synchronization with branch support
# Generated from template by Pine Ridge Bootstrap
# Template version: 1.0.0 (YourProject)

# ... (copy and customize the template content with your project-specific values)
EOF

sudo chmod +x "$INSTALL_DIR/repo/scripts/sync-repo.sh"
log "✓ Generated comprehensive sync script for YourProject"
```

### 3. Update Documentation

Add your project to the main bootstrap README and create project-specific documentation.

## 🔧 Current Projects

### WAF (Web Application Firewall)
- **Config**: `project-configs/waf.conf`  
- **Features**: Ansible vault verification, SSL certificate management
- **Validation**: Checks for `site.yml` and `system-maintenance.yml`
- **Post-sync**: Vault password verification and accessibility testing

### Podman (Container Management)
- **Config**: `project-configs/podman.conf`
- **Features**: Container deployment triggers, quadlet management  
- **Validation**: Checks for `quadlets/` directory and `ansible/` directory
- **Post-sync**: Triggers quadlet deployment service if available

## 📝 Template Best Practices

### Configuration Files Should:
- ✅ Use clear, descriptive variable names
- ✅ Include comprehensive validation logic
- ✅ Handle missing optional components gracefully
- ✅ Provide meaningful log messages
- ✅ Include error handling for post-sync actions

### Validation Checks Should:
- ✅ Verify required files/directories exist
- ✅ Warn about missing optional components (don't fail)
- ✅ Be specific about what's missing and why it's needed

### Post-Sync Actions Should:
- ✅ Be idempotent (safe to run multiple times)
- ✅ Handle service unavailability gracefully
- ✅ Log their progress and results
- ✅ Not cause sync failure for non-critical errors

## 🔄 Template Versioning

Template versions are tracked in the generated scripts for troubleshooting:
- `Template version: 1.0.0` - Initial standardized template
- Future versions will be documented here as the template evolves

## 🚨 Important Notes

### For Bootstrap Maintainers:
- **Always test new project configurations** before committing
- **Update this documentation** when adding new projects
- **Consider backward compatibility** when updating the master template
- **Use semantic versioning** for template changes

### For Project Users:
- **Generated sync scripts are overwritten** during bootstrap re-runs
- **Customizations should go in project configuration files**, not the generated scripts
- **Repository-specific logic** should be implemented through the template system
- **Manual sync script modifications will be lost** on next bootstrap run

## 🆘 Troubleshooting

### Template Generation Issues
```bash
# Check if template files exist
ls -la /path/to/bootstrap/templates/
ls -la /path/to/bootstrap/templates/project-configs/

# Verify configuration syntax
bash -n templates/project-configs/your-project.conf

# Test template variable substitution
# (Check generated sync script for correct values)
```

### Sync Script Issues
```bash
# Test generated sync script manually
sudo /opt/pine-ridge-project/repo/scripts/sync-repo.sh

# Check sync script logs
tail -f /opt/pine-ridge-project/logs/sync.log

# Verify configuration file exists
cat /etc/pine-ridge-project.conf
```

This template system ensures consistency while allowing for project-specific needs and makes adding new Pine Ridge projects straightforward and maintainable.
