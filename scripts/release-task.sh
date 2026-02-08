#!/usr/bin/env bash
set -euo pipefail

# release-task.sh — Release a task lock and mark it done.
# Usage: release-task.sh <task-id> [status]
# status: "done" (default) or "failed"

WORKSPACE="/workspace"
REPO_BRANCH="${REPO_BRANCH:-main}"
AGENT_ID="${HOSTNAME:-agent-$$}"

TASK_ID="${1:?Usage: release-task.sh <task-id> [done|failed]}"
FINAL_STATUS="${2:-done}"
LOCK_FILE="current_tasks/${TASK_ID}.lock"

log() {
    echo "[release-task] $(date '+%H:%M:%S') $*"
}

cd "$WORKSPACE"

# Update task status in tasks.json
if [ -f tasks.json ]; then
    jq --arg id "$TASK_ID" --arg status "$FINAL_STATUS" \
       'map(if .id == $id then .status = $status else . end)' \
       tasks.json > tasks.json.tmp && mv tasks.json.tmp tasks.json
    log "Marked task $TASK_ID as $FINAL_STATUS"
fi

# Remove the lock file
if [ -f "$LOCK_FILE" ]; then
    git rm "$LOCK_FILE"
else
    log "Warning: lock file $LOCK_FILE not found"
fi

# Commit the release
git add tasks.json
git commit -m "[HARNESS] agent($AGENT_ID): release task $TASK_ID ($FINAL_STATUS)" || {
    log "Warning: nothing to commit during release"
}

log "Released task $TASK_ID with status $FINAL_STATUS"
