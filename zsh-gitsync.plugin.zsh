# git sync plugin for zsh
# send and receive git patches between machines via tailscale
# dependencies: git, jq, tailscale

_validate_git_sync() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: not in a git repository" >&2
    return 1
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    return 1
  fi
  
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "error: tailscale cli is required" >&2
    return 1
  fi
  
  return 0
}

_get_repo_info() {
  REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
  COMMIT_HASH=$(git rev-parse --short HEAD)
  TIMESTAMP=$(date +%s)
  MACHINE_HOSTNAME=$(hostname)
}

_has_uncommitted_changes() {
  ! git diff --quiet HEAD || ! git diff --quiet --cached
}

_create_metadata() {
  local has_staged=false
  local has_unstaged=false
  
  if ! git diff --quiet --cached; then
    has_staged=true
  fi
  
  if ! git diff --quiet HEAD; then
    has_unstaged=true
  fi
  
  jq -n \
    --arg repo_name "$REPO_NAME" \
    --arg commit_hash "$COMMIT_HASH" \
    --arg timestamp "$TIMESTAMP" \
    --arg created_at "$(date -Iseconds)" \
    --arg machine "$MACHINE_HOSTNAME" \
    --argjson has_staged "$has_staged" \
    --argjson has_unstaged "$has_unstaged" \
    '{
      repo_name: $repo_name,
      commit_hash: $commit_hash,
      timestamp: ($timestamp | tonumber),
      created_at: $created_at,
      machine: $machine,
      has_staged: $has_staged,
      has_unstaged: $has_unstaged
    }'
}

_create_patch() {
  echo "# Git patch for $REPO_NAME at commit $COMMIT_HASH"
  echo "# Generated at $(date -Iseconds)"
  echo "# Machine: $MACHINE_HOSTNAME"
  echo ""
  
  if ! git diff --quiet --cached; then
    echo "# === STAGED CHANGES ==="
    git diff --cached --binary
    echo ""
  fi
  
  if ! git diff --quiet HEAD; then
    echo "# === UNSTAGED CHANGES ==="
    git diff HEAD --binary
    echo ""
  fi
}

gitsend() {
  local machine_name="$1"
  
  if [[ -z "$machine_name" ]]; then
    echo "usage: gitsend <tailscale-machine-name>" >&2
    return 1
  fi
  
  _validate_git_sync || return 1
  _get_repo_info
  
  if ! _has_uncommitted_changes; then
    echo "no changes to send"
    return 1
  fi
  
  echo "creating patch for $REPO_NAME at commit $COMMIT_HASH..."
  
  local metadata
  metadata=$(_create_metadata)
  
  echo "sending metadata to $machine_name..."
  if ! echo "$metadata" | tailscale file cp --name "gitsync-$TIMESTAMP.json" - "$machine_name:"; then
    echo "failed to send metadata to $machine_name" >&2
    return 1
  fi
  
  echo "sending patch to $machine_name..."
  if _create_patch | tailscale file cp --name "gitsync-$TIMESTAMP.patch" - "$machine_name:"; then
    echo "✓ changes sent to $machine_name"
    echo "  repository: $REPO_NAME"
    echo "  commit: $COMMIT_HASH"
    echo "  files: gitsync-$TIMESTAMP.patch, gitsync-$TIMESTAMP.json"
  else
    echo "failed to send patch to $machine_name" >&2
    return 1
  fi
}

_find_latest_metadata() {
  local recv_dir="$1"
  ls "$recv_dir"/gitsync-*.json 2>/dev/null | sort -r | head -1
}

_parse_metadata() {
  local metadata_file="$1"
  
  repo_name=$(jq -r '.repo_name' "$metadata_file")
  commit_hash=$(jq -r '.commit_hash' "$metadata_file")
  timestamp=$(jq -r '.timestamp' "$metadata_file")
  created_at=$(jq -r '.created_at' "$metadata_file")
  sender_machine=$(jq -r '.machine' "$metadata_file")
  has_staged=$(jq -r '.has_staged' "$metadata_file")
  has_unstaged=$(jq -r '.has_unstaged' "$metadata_file")
}

_show_patch_info() {
  echo ""
  echo "patch information:"
  echo "  repository: $repo_name"
  echo "  from commit: $commit_hash" 
  echo "  created: $created_at"
  echo "  sender: $sender_machine"
  echo "  has staged: $has_staged"
  echo "  has unstaged: $has_unstaged"
}

_confirm() {
  local message="$1"
  echo ""
  echo "warning: $message"
  echo -n "Continue anyway? (y/N): "
  read -r REPLY
  [[ $REPLY =~ ^[Yy]$ ]]
}

_validate_patch() {
  local current_repo="$1"
  local current_commit="$2"
  local continue_anyway=false
  
  if [[ "$repo_name" != "$current_repo" ]]; then
    if ! _confirm "repository mismatch! patch is for '$repo_name', current repo is '$current_repo'"; then
      echo "aborted" >&2
      return 1
    fi
    continue_anyway=true
  fi
  
  if [[ "$commit_hash" != "$current_commit" ]]; then
    if ! _confirm "commit mismatch! patch from commit $commit_hash, current commit $current_commit"; then
      echo "aborted" >&2
      return 1
    fi
    continue_anyway=true
  fi
  
  # 15 minutes = 900 seconds
  local current_time age minutes hours
  current_time=$(date +%s)
  age=$((current_time - timestamp))
  
  if [[ $age -gt 900 ]]; then
    minutes=$((age / 60))
    hours=$((minutes / 60))
    
    local age_msg
    if [[ $hours -gt 0 ]]; then
      age_msg="this patch is $hours hours and $((minutes % 60)) minutes old!"
    else
      age_msg="this patch is $minutes minutes old!"
    fi
    
    if ! _confirm "$age_msg older patches may not apply cleanly"; then
      echo "aborted" >&2
      return 1
    fi
    continue_anyway=true
  fi
  
  if _has_uncommitted_changes; then
    echo ""
    echo "warning: you have uncommitted changes in your working directory!"
    echo "current status:"
    git status --short
    echo ""
    if ! _confirm "applying this patch may cause conflicts or overwrite your changes"; then
      echo "aborted - commit or stash your changes first" >&2
      return 1
    fi
    continue_anyway=true
  fi
  
  CREATE_BACKUP=$continue_anyway
}

_apply_patch() {
  local patch_file="$1"
  
  if [[ ! -f "$patch_file" ]]; then
    echo "patch file not found: $patch_file" >&2
    return 1
  fi
  
  if [[ "$CREATE_BACKUP" == true ]] || _has_uncommitted_changes; then
    echo "creating backup stash..."
    git stash push -u -m "Backup before applying patch from $sender_machine at $(date)" >/dev/null 2>&1
  fi
  
  local temp_staged temp_unstaged
  temp_staged=$(mktemp)
  temp_unstaged=$(mktemp)
  
  # split patch into staged and unstaged parts
  awk '
  /^# === STAGED CHANGES ===$/ {stage="staged"; next}
  /^# === UNSTAGED CHANGES ===$/ {stage="unstaged"; next}
  /^#/ {next}
  stage=="staged" {print > "'$temp_staged'"}
  stage=="unstaged" {print > "'$temp_unstaged'"}
  ' "$patch_file"
  
  local success=true
  
  if [[ "$has_staged" == "true" ]] && [[ -s "$temp_staged" ]]; then
    echo "applying staged changes..."
    if ! git apply --cached "$temp_staged"; then
      echo "failed to apply staged changes" >&2
      success=false
    fi
  fi
  
  if [[ "$has_unstaged" == "true" ]] && [[ -s "$temp_unstaged" ]]; then
    echo "applying unstaged changes..."
    if ! git apply "$temp_unstaged"; then
      echo "failed to apply unstaged changes" >&2
      success=false
    fi
  fi
  
  rm -f "$temp_staged" "$temp_unstaged"
  
  return $([[ "$success" == true ]])
}

gitrecv() {
  _validate_git_sync || return 1
  _get_repo_info
  
  local current_repo="$REPO_NAME"
  local current_commit="$COMMIT_HASH"
  local recv_dir="$HOME/.git-patches/received"
  
  mkdir -p "$recv_dir"
  
  # check downloads folder first for auto-downloaded files
  echo "checking Downloads folder for auto-downloaded patch files..."
  local downloads_dir="$HOME/Downloads"
  local found_in_downloads=false
  
  if [[ -d "$downloads_dir" ]]; then
    local recent_patches
    recent_patches=($(find "$downloads_dir" -name "gitsync-*.patch" -mtime -1 2>/dev/null | sort -r))
    
    if [[ ${#recent_patches[@]} -gt 0 ]]; then
      echo "found patch files in Downloads, moving to receive directory..."
      for patch_file in "${recent_patches[@]}"; do
        local base_name=$(basename "$patch_file")
        local timestamp="${base_name#gitsync-}"
        timestamp="${timestamp%.patch}"
        
        mv "$patch_file" "$recv_dir/" 2>/dev/null
        if [[ -f "$downloads_dir/gitsync-$timestamp.json" ]]; then
          mv "$downloads_dir/gitsync-$timestamp.json" "$recv_dir/" 2>/dev/null
        fi
      done
      found_in_downloads=true
      echo "moved files from Downloads to receive directory"
    fi
  fi
  
  # fallback to inbox if nothing in downloads
  if [[ "$found_in_downloads" == false ]]; then
    echo "checking inbox for patch files..."
    if ! tailscale file get --verbose "$recv_dir" >/dev/null 2>&1; then
      echo "no files in inbox, waiting for new files..."
      if ! tailscale file get --wait --verbose "$recv_dir" >/dev/null 2>&1; then
        echo "failed to receive files" >&2
        return 1
      fi
    else
      echo "retrieved files from inbox"
    fi
  fi
  
  local metadata_file
  metadata_file=$(_find_latest_metadata "$recv_dir")
  
  if [[ ! -f "$metadata_file" ]]; then
    echo "no metadata file found in received files" >&2
    echo "files in $recv_dir:"
    ls -la "$recv_dir" 2>/dev/null || true
    return 1
  fi
  
  echo "found metadata file: $(basename "$metadata_file")"
  
  _parse_metadata "$metadata_file"
  _show_patch_info
  
  _validate_patch "$current_repo" "$current_commit" || return 1
  
  local patch_file="$recv_dir/gitsync-$timestamp.patch"
  
  echo ""
  echo "applying patch..."
  
  if _apply_patch "$patch_file"; then
    echo ""
    echo "patch applied successfully!"
    echo "  from: $repo_name at $commit_hash"
    echo "  sender: $sender_machine"
    echo "  created: $created_at"
    
    if _has_uncommitted_changes; then
      echo ""
      echo "current status:"
      git status --short
    fi
    
    rm -f "$metadata_file" "$patch_file"
    
    if [[ "$CREATE_BACKUP" == true ]] || git stash list | grep -q "Backup before applying patch"; then
      echo ""
      echo "removing backup stash..."
      git stash drop >/dev/null 2>&1 || true
    fi
  else
    echo ""
    echo "patch application failed!" >&2
    echo "files preserved in $recv_dir for manual inspection."
    echo "your backup stash is preserved. use 'git stash pop' to restore if needed."
    return 1
  fi
}

_gitsend_get_machines() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null | 
      jq -r '.Peer[] | select(.Online == true) | .DNSName' 2>/dev/null | 
      sed 's/\..*$//' | sort
  fi
}

_gitsend_completion() {
  local -a machines
  machines=($(_gitsend_get_machines))
  _describe 'tailscale machines' machines
}

compdef _gitsend_completion gitsend
