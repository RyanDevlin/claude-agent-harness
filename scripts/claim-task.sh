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

log() {
    echo "[claim-task] $(date '+%H:%M:%S') $*"
}

cd "$WORKSPACE"

# Pull latest to see if someone else already claimed it
git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || true

# Check if lock file already exists
if [ -f "$LOCK_FILE" ]; then
    log "Task $TASK_ID already claimed by another agent"
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
git commit -m "[HARNESS] agent($AGENT_ID): claim task $TASK_ID"

if ! git push origin "$REPO_BRANCH"; then
    log "Push failed — another agent may have claimed this task"

    # Pull and check if someone else got the lock
    git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || {
        git rebase --abort 2>/dev/null || true
        git reset --hard "origin/$REPO_BRANCH"
        log "Task $TASK_ID: conflict during claim, aborting"
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
    if ! git push origin "$REPO_BRANCH"; then
        log "ERROR: second push attempt failed for task $TASK_ID"
        exit 1
    fi
fi

log "Successfully claimed task $TASK_ID"
exit 0
