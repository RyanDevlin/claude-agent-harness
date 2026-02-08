#!/usr/bin/env bash
set -euo pipefail

# claim-task.sh — Attempt to claim a task via git-based locking.
# Usage: claim-task.sh <task-id>
# Exit 0 = claimed successfully, Exit 1 = failed (already claimed or conflict)

WORKSPACE="/workspace"
REPO_BRANCH="${REPO_BRANCH:-main}"
AGENT_ID="${HOSTNAME:-agent-$$}"

TASK_ID="${1:?Usage: claim-task.sh <task-id>}"
LOCK_FILE="current_tasks/${TASK_ID}.lock"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/colors.sh"

_PREFIX="[claim/$AGENT_ID]"
log()      { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} $*"; }
log_ok()   { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_GREEN}$*${_RESET}"; }
log_err()  { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_RED}$*${_RESET}"; }
log_warn() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_YELLOW}$*${_RESET}"; }

cd "$WORKSPACE"

# Pull latest to see if someone else already claimed it
git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true

# Check if lock file already exists
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGENT=$(jq -r '.agent' "$LOCK_FILE" 2>/dev/null || echo "unknown")
    log "Task $TASK_ID already claimed by $LOCK_AGENT"
    exit 1
fi

# Create the lock file
mkdir -p current_tasks
cat > "$LOCK_FILE" <<EOF
{
  "agent": "$AGENT_ID",
  "task_id": "$TASK_ID",
  "started": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# Update task status to in_progress in tasks.json
if [ -f tasks.json ]; then
    jq --arg id "$TASK_ID" \
       'map(if .id == $id then .status = "in_progress" else . end)' \
       tasks.json > tasks.json.tmp && mv tasks.json.tmp tasks.json
fi

# Commit and push
git add "$LOCK_FILE" tasks.json
git commit -m "[HARNESS] agent($AGENT_ID): claim task $TASK_ID" --quiet

if ! git push origin "$REPO_BRANCH" --quiet 2>/dev/null; then
    log_warn "Push conflict claiming $TASK_ID — another agent may have got it"

    # Pull and check if someone else got the lock
    git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || {
        git rebase --abort 2>/dev/null || true
        git reset --hard "origin/$REPO_BRANCH" --quiet 2>/dev/null
        log "Task $TASK_ID: conflict during claim, backing off"
        exit 1
    }

    # After rebase, check if the lock file is ours
    if [ -f "$LOCK_FILE" ]; then
        LOCK_AGENT=$(jq -r '.agent' "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if [ "$LOCK_AGENT" != "$AGENT_ID" ]; then
            log "Task $TASK_ID claimed by $LOCK_AGENT, not us"
            exit 1
        fi
    fi

    # Try pushing again
    if ! git push origin "$REPO_BRANCH" --quiet 2>/dev/null; then
        log_err "ERROR: second push attempt failed for task $TASK_ID"
        exit 1
    fi
fi

log_ok "Claimed task $TASK_ID"
exit 0
