#!/bin/bash
# Template generator for sync scripts
# This function generates project-specific sync scripts from the common template

generate_sync_script() {
    local project_type="$1"
    local output_file="$2"
    
    local template_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
    local template_file="$template_dir/sync-repo-template.sh"
    local config_file="$template_dir/project-configs/${project_type}.conf"
    
    # Verify template exists
    if [[ ! -f "$template_file" ]]; then
        error "Template file not found: $template_file"
    fi
    
    # Verify project config exists
    if [[ ! -f "$config_file" ]]; then
        error "Project configuration not found: $config_file. Create this file to define project-specific settings."
    fi
    
    # Source the project configuration
    source "$config_file"
    
    # Read the template
    local template_content
    template_content=$(cat "$template_file")
    
    # Substitute variables
    template_content=${template_content//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}
    template_content=${template_content//\{\{CONFIG_FILE\}\}/$CONFIG_FILE}
    template_content=${template_content//\{\{SSH_KEY_NAME\}\}/$SSH_KEY_NAME}
    template_content=${template_content//\{\{LOCK_FILE\}\}/$LOCK_FILE}
    template_content=${template_content//\{\{VALIDATION_CHECK\}\}/$VALIDATION_CHECK}
    template_content=${template_content//\{\{POST_SYNC_ACTIONS\}\}/$POST_SYNC_ACTIONS}
    
    # Write the generated script
    echo "$template_content" > "$output_file"
    chmod +x "$output_file"
    
    log "✓ Generated sync script for $PROJECT_NAME at $output_file"
}
