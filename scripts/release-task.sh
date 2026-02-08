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
MAX_TASK_RETRIES="${MAX_TASK_RETRIES:-2}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/colors.sh"

_PREFIX="[release/$AGENT_ID]"
log()      { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} $*"; }
log_ok()   { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_GREEN}$*${_RESET}"; }
log_err()  { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_RED}$*${_RESET}"; }
log_warn() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_YELLOW}$*${_RESET}"; }

cd "$WORKSPACE"

# Update task status in tasks.json, with retry logic for failures
if [ -f tasks.json ]; then
    if [ "$FINAL_STATUS" = "failed" ]; then
        RETRY_COUNT=$(jq -r --arg id "$TASK_ID" \
            '.[] | select(.id == $id) | .retry_count // 0' tasks.json)

        if [ "$RETRY_COUNT" -lt "$MAX_TASK_RETRIES" ]; then
            NEW_RETRY=$((RETRY_COUNT + 1))
            log_warn "Task $TASK_ID failed (attempt $((RETRY_COUNT + 1))/$((MAX_TASK_RETRIES + 1))) — requeueing for retry #$NEW_RETRY"
            jq --arg id "$TASK_ID" --argjson retry "$NEW_RETRY" \
               'map(if .id == $id then .status = "pending" | .retry_count = $retry else . end)' \
               tasks.json > tasks.json.tmp && mv tasks.json.tmp tasks.json
            FINAL_STATUS="pending (retry $NEW_RETRY)"
        else
            log_err "Task $TASK_ID failed after $((MAX_TASK_RETRIES + 1)) attempts — permanently failed"
            jq --arg id "$TASK_ID" --arg status "failed" \
               'map(if .id == $id then .status = $status else . end)' \
               tasks.json > tasks.json.tmp && mv tasks.json.tmp tasks.json
        fi
    else
        jq --arg id "$TASK_ID" --arg status "$FINAL_STATUS" \
           'map(if .id == $id then .status = $status else . end)' \
           tasks.json > tasks.json.tmp && mv tasks.json.tmp tasks.json
    fi
fi

# Remove the lock file
if [ -f "$LOCK_FILE" ]; then
    git rm "$LOCK_FILE" --quiet
else
    log_warn "Warning: lock file $LOCK_FILE not found"
fi

# Commit the release
git add tasks.json
git commit -m "[HARNESS] agent($AGENT_ID): release task $TASK_ID ($FINAL_STATUS)" --quiet || {
    log "Warning: nothing to commit during release"
}

log "Released task $TASK_ID — $FINAL_STATUS"
