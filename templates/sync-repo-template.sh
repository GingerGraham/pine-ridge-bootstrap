#!/bin/bash
# scripts/sync-repo.sh - GitOps repository synchronization with branch support
# Generated from template by Pine Ridge Bootstrap
# Template version: 1.0.0

set -euo pipefail

# Source configuration - PROJECT SPECIFIC
source {{CONFIG_FILE}}

LOG_FILE="$INSTALL_DIR/logs/sync.log"
LOCK_FILE="{{LOCK_FILE}}"

# Create logs directory if it doesn't exist
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
            log "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

check_git_changes() {
    cd "$INSTALL_DIR/repo"

    # Fix git dubious ownership issue
    git config --global --add safe.directory "$INSTALL_DIR/repo"

    # Set SSH environment for git operations - PROJECT SPECIFIC
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/{{SSH_KEY_NAME}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    # Check current branch
    local current_branch
    current_branch=$(git branch --show-current)

    if [[ "$current_branch" != "$GIT_BRANCH" ]]; then
        log "Branch change detected: $current_branch -> $GIT_BRANCH"
        git fetch origin "$GIT_BRANCH"
        git checkout "$GIT_BRANCH"
        git reset --hard "origin/$GIT_BRANCH"
        return 0
    fi

    # Fetch latest changes for current branch
    if ! git fetch origin "$GIT_BRANCH"; then
        error "Failed to fetch repository changes. Check SSH key and repository access."
    fi

    # Check if there are new commits
    local local_hash
    local remote_hash

    local_hash=$(git rev-parse HEAD)
    remote_hash=$(git rev-parse "origin/$GIT_BRANCH")

    if [[ "$local_hash" == "$remote_hash" ]]; then
        log "Repository is up to date on branch $GIT_BRANCH"
        return 1
    else
        log "New changes detected on $GIT_BRANCH: $local_hash -> $remote_hash"
        return 0
    fi
}

sync_repository() {
    cd "$INSTALL_DIR/repo"

    log "Pulling latest changes from branch $GIT_BRANCH..."

    # Set SSH environment for git operations - PROJECT SPECIFIC
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/{{SSH_KEY_NAME}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if ! git pull origin "$GIT_BRANCH"; then
        error "Failed to pull repository changes. Check SSH key and repository access."
    fi

    # Ensure scripts are executable after sync
    find "$INSTALL_DIR/repo" -name "*.sh" -type f -exec chmod +x {} \;

    # PROJECT SPECIFIC VALIDATION
    {{VALIDATION_CHECK}}

    log "Repository synchronized successfully on branch $GIT_BRANCH"
}

# PROJECT SPECIFIC POST-SYNC ACTIONS
{{POST_SYNC_ACTIONS}}

main() {
    log "Starting {{PROJECT_NAME}} GitOps sync process for branch $GIT_BRANCH..."

    acquire_lock

    if check_git_changes; then
        sync_repository
        
        # Execute project-specific post-sync actions
        if declare -f post_sync_actions >/dev/null 2>&1; then
            post_sync_actions
            log "Post-sync actions completed"
        fi
        
        log "Sync completed successfully, Ansible will run next"
    else
        log "No changes to sync"
        
        # Still run verification even if no changes (for health checks)
        if declare -f post_sync_verification >/dev/null 2>&1; then
            post_sync_verification
        fi
    fi
}

main "$@"
