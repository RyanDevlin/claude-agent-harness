#!/usr/bin/env bash
set -euo pipefail

# plan-tasks.sh — Run the planner agent to generate tasks.json from PROJECT_SPEC.md.
# Uses a git-based lock to ensure only one agent plans at a time.
# Exit 0 = planning done (by us or another agent), Exit 1 = error.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="/workspace"
REPO_BRANCH="${REPO_BRANCH:-main}"
AGENT_ID="${HOSTNAME:-agent-$$}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
PLANNER_PROMPT_FILE="${PLANNER_PROMPT_FILE:-/harness/PLANNER_PROMPT.md}"

PLAN_LOCK="current_tasks/_planning.lock"
LOCK_STALE_MINUTES="${LOCK_STALE_MINUTES:-30}"

source "$SCRIPT_DIR/colors.sh"

_PREFIX="[plan/$AGENT_ID]"
log()      { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} $*"; }
log_ok()   { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_GREEN}$*${_RESET}"; }
log_err()  { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_RED}$*${_RESET}"; }
log_warn() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_YELLOW}$*${_RESET}"; }
log_info() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_CYAN}$*${_RESET}"; }

# Check if an agent's container is still running via Docker Compose DNS.
is_agent_alive() {
    local agent_id="$1"
    [ -n "$agent_id" ] && [ "$agent_id" != "unknown" ] || return 1
    getent hosts "$agent_id" >/dev/null 2>&1
}

# Check if a lock file is stale (older than LOCK_STALE_MINUTES).
is_lock_stale() {
    local lock_file="$1"
    local started
    started=$(jq -r '.started // empty' "$lock_file" 2>/dev/null) || return 1
    [ -n "$started" ] || return 1

    local lock_epoch now_epoch age_minutes
    lock_epoch=$(date -d "$started" +%s 2>/dev/null) || return 1
    now_epoch=$(date -u +%s)
    age_minutes=$(( (now_epoch - lock_epoch) / 60 ))

    [ "$age_minutes" -ge "$LOCK_STALE_MINUTES" ]
}

# Wait for another agent to finish planning. Returns 0 if tasks.json appears.
wait_for_planner() {
    local max_checks=60  # 60 * 10s = 10 minutes
    for i in $(seq 1 "$max_checks"); do
        sleep 10
        git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true
        if [ -f tasks.json ]; then
            log "tasks.json is now available (planner finished)"
            return 0
        fi
        if [ ! -f "$PLAN_LOCK" ]; then
            log "Planning lock released but no tasks.json"
            return 1
        fi
        # Log progress every 30 seconds
        if (( i % 3 == 0 )); then
            log "Waiting for planner agent... ($((i * 10))s elapsed)"
        fi
    done
    log_err "ERROR: timed out waiting for planning to complete (10 min)"
    return 1
}

cd "$WORKSPACE"

# If tasks.json already exists, nothing to do
if [ -f tasks.json ]; then
    log "tasks.json already exists, skipping planning"
    exit 0
fi

# Check for PROJECT_SPEC.md
if [ ! -f PROJECT_SPEC.md ]; then
    log_err "ERROR: no PROJECT_SPEC.md found in repo — nothing to plan from"
    exit 1
fi

# Try to claim the planning lock
git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true

# Re-check after pull — maybe another agent already generated tasks
if [ -f tasks.json ]; then
    log "tasks.json appeared after pull, skipping planning"
    exit 0
fi

if [ -f "$PLAN_LOCK" ]; then
    LOCK_AGENT=$(jq -r '.agent' "$PLAN_LOCK" 2>/dev/null || echo "unknown")
    LOCK_STARTED=$(jq -r '.started // "unknown"' "$PLAN_LOCK" 2>/dev/null)

    if ! is_agent_alive "$LOCK_AGENT"; then
        log "Planning lock held by dead agent $LOCK_AGENT (started $LOCK_STARTED) — removing it"
        git rm -f "$PLAN_LOCK" --quiet 2>/dev/null || rm -f "$PLAN_LOCK"
        git commit -m "[HARNESS] agent($AGENT_ID): remove dead planning lock from $LOCK_AGENT" --quiet 2>/dev/null || true
        git push origin "$REPO_BRANCH" --quiet 2>/dev/null || true
        # Fall through to claim the lock below
    elif is_lock_stale "$PLAN_LOCK"; then
        log "Stale planning lock from $LOCK_AGENT (started $LOCK_STARTED) — removing it"
        git rm -f "$PLAN_LOCK" --quiet 2>/dev/null || rm -f "$PLAN_LOCK"
        git commit -m "[HARNESS] agent($AGENT_ID): remove stale planning lock from $LOCK_AGENT" --quiet 2>/dev/null || true
        git push origin "$REPO_BRANCH" --quiet 2>/dev/null || true
        # Fall through to claim the lock below
    else
        log "Agent $LOCK_AGENT is planning (started $LOCK_STARTED) — waiting..."
        if wait_for_planner; then
            exit 0
        fi
        exit 1
    fi
fi

# Claim the planning lock
mkdir -p current_tasks
cat > "$PLAN_LOCK" <<EOF
{
  "agent": "$AGENT_ID",
  "started": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

git add "$PLAN_LOCK"
git commit -m "[HARNESS] agent($AGENT_ID): claim planning lock" --quiet

if ! git push origin "$REPO_BRANCH" --quiet 2>/dev/null; then
    log "Failed to claim planning lock (another agent won), waiting..."
    git reset --hard "origin/$REPO_BRANCH" --quiet 2>/dev/null
    if wait_for_planner; then
        exit 0
    fi
    exit 1
fi

log_info "Claimed planning lock — running planner agent with $CLAUDE_MODEL..."

# Run the planner
LOGFILE="/tmp/planner_${AGENT_ID}.log"

# Stream output to both terminal and log file so the user can see planning progress.
# pipefail ensures we capture claude's exit code, not tee's.
if claude --dangerously-skip-permissions \
          -p "$(cat "$PLANNER_PROMPT_FILE")" \
          --model "$CLAUDE_MODEL" \
          2>&1 | tee "$LOGFILE"; then
    log_ok "Planner agent completed successfully"
else
    log_err "Planner agent exited with error (see $LOGFILE for full output)"
fi

# Commit whatever the planner produced
if [ -f tasks.json ]; then
    TASK_COUNT=$(jq 'length' tasks.json 2>/dev/null || echo "?")
    log_ok "Planner generated tasks.json with $TASK_COUNT tasks"

    git add -A
    git commit -m "[PLAN] generate tasks and init script from project spec" --quiet || true

    # Remove the planning lock
    git rm -f "$PLAN_LOCK" --quiet 2>/dev/null || true
    git commit -m "[HARNESS] agent($AGENT_ID): release planning lock" --quiet || true

    "$SCRIPT_DIR/sync-repo.sh" push || {
        log_err "ERROR: failed to push planning results"
        exit 1
    }

    log_ok "Planning complete — $TASK_COUNT tasks committed and pushed"
    exit 0
else
    log_err "ERROR: planner did not produce tasks.json"
    # Clean up the lock so others can retry
    git rm -f "$PLAN_LOCK" --quiet 2>/dev/null || true
    git commit -m "[HARNESS] agent($AGENT_ID): release planning lock (failed)" --quiet || true
    git push origin "$REPO_BRANCH" --quiet 2>/dev/null || true
    exit 1
fi
