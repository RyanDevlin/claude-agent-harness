#!/usr/bin/env bash
set -euo pipefail

# validate-project.sh — Run validation after all tasks reach terminal state.
# Uses a git-based lock to ensure only one agent validates at a time.
# Follows the same locking pattern as plan-tasks.sh.
# Exit 0 = validation done (by us or another agent), Exit 1 = error.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="/workspace"
REPO_BRANCH="${REPO_BRANCH:-main}"
AGENT_ID="${HOSTNAME:-agent-$$}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
VALIDATOR_PROMPT_FILE="${VALIDATOR_PROMPT_FILE:-/harness/VALIDATOR_PROMPT.md}"
MAX_VALIDATION_ROUNDS="${MAX_VALIDATION_ROUNDS:-2}"

VALIDATION_LOCK="current_tasks/_validation.lock"
LOCK_STALE_MINUTES="${LOCK_STALE_MINUTES:-30}"

source "$SCRIPT_DIR/colors.sh"

_PREFIX="[validate/$AGENT_ID]"
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

# Wait for another agent to finish validation.
wait_for_validator() {
    local max_checks=60  # 60 * 10s = 10 minutes
    for i in $(seq 1 "$max_checks"); do
        sleep 10
        git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true

        # Validation completed (either passed or added new tasks)
        if [ ! -f "$VALIDATION_LOCK" ]; then
            log "Validation lock released"
            return 0
        fi
        if (( i % 3 == 0 )); then
            log "Waiting for validator agent... ($((i * 10))s elapsed)"
        fi
    done
    log_err "ERROR: timed out waiting for validation (10 min)"
    return 1
}

cd "$WORKSPACE"

# If validation already passed, nothing to do
if [ -f VALIDATION_PASSED ]; then
    log "Validation already passed"
    exit 0
fi

# Check validation round limit
VALIDATION_ROUND=0
if [ -f .validation_round ]; then
    VALIDATION_ROUND=$(cat .validation_round)
fi

if [ "$VALIDATION_ROUND" -ge "$MAX_VALIDATION_ROUNDS" ]; then
    log "Max validation rounds ($MAX_VALIDATION_ROUNDS) already reached"
    exit 0
fi

# Try to claim the validation lock
git pull --rebase origin "$REPO_BRANCH" >/dev/null 2>&1 || true

# Re-check after pull
if [ -f VALIDATION_PASSED ]; then
    log "Validation passed (appeared after pull)"
    exit 0
fi

if [ -f "$VALIDATION_LOCK" ]; then
    LOCK_AGENT=$(jq -r '.agent' "$VALIDATION_LOCK" 2>/dev/null || echo "unknown")
    LOCK_STARTED=$(jq -r '.started // "unknown"' "$VALIDATION_LOCK" 2>/dev/null)

    if ! is_agent_alive "$LOCK_AGENT"; then
        log "Validation lock held by dead agent $LOCK_AGENT (started $LOCK_STARTED) — removing it"
        git rm -f "$VALIDATION_LOCK" --quiet 2>/dev/null || rm -f "$VALIDATION_LOCK"
        git commit -m "[HARNESS] agent($AGENT_ID): remove dead validation lock from $LOCK_AGENT" --quiet 2>/dev/null || true
        git push origin "$REPO_BRANCH" --quiet 2>/dev/null || true
        # Fall through to claim the lock below
    elif is_lock_stale "$VALIDATION_LOCK"; then
        log "Stale validation lock from $LOCK_AGENT (started $LOCK_STARTED) — removing it"
        git rm -f "$VALIDATION_LOCK" --quiet 2>/dev/null || rm -f "$VALIDATION_LOCK"
        git commit -m "[HARNESS] agent($AGENT_ID): remove stale validation lock from $LOCK_AGENT" --quiet 2>/dev/null || true
        git push origin "$REPO_BRANCH" --quiet 2>/dev/null || true
        # Fall through to claim the lock below
    else
        log "Agent $LOCK_AGENT is validating (started $LOCK_STARTED) — waiting..."
        if wait_for_validator; then
            exit 0
        fi
        exit 1
    fi
fi

# Claim the validation lock
mkdir -p current_tasks
cat > "$VALIDATION_LOCK" <<EOF
{
  "agent": "$AGENT_ID",
  "started": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

git add "$VALIDATION_LOCK"
git commit -m "[HARNESS] agent($AGENT_ID): claim validation lock" --quiet

if ! git push origin "$REPO_BRANCH" --quiet 2>/dev/null; then
    log "Failed to claim validation lock (another agent won), waiting..."
    git reset --hard "origin/$REPO_BRANCH" --quiet 2>/dev/null
    if wait_for_validator; then
        exit 0
    fi
    exit 1
fi

log_info "Claimed validation lock — running validator with $CLAUDE_MODEL..."

# Run the validator
LOGFILE="/tmp/validator_${AGENT_ID}.log"

# Stream output to terminal and log file
if claude --dangerously-skip-permissions \
          -p "$(cat "$VALIDATOR_PROMPT_FILE")" \
          --model "$CLAUDE_MODEL" \
          2>&1 | tee "$LOGFILE"; then
    log_ok "Validator completed successfully"
else
    log_err "Validator exited with error (see $LOGFILE)"
fi

# Commit whatever the validator produced
git add -A
git commit -m "[VALIDATION] validation results from agent $AGENT_ID" --quiet || true

# Check outcome and update round counter if new tasks were added
if [ -f VALIDATION_PASSED ]; then
    log_ok "Validation PASSED"
else
    # Validator found gaps — increment round counter
    NEW_ROUND=$((VALIDATION_ROUND + 1))
    echo "$NEW_ROUND" > .validation_round
    git add .validation_round
    git commit -m "[HARNESS] agent($AGENT_ID): validation round $NEW_ROUND — gaps found" --quiet || true

    NEW_TASKS=$(jq '[.[] | select(.status == "pending")] | length' tasks.json 2>/dev/null || echo 0)
    log_warn "Validation round $NEW_ROUND — $NEW_TASKS remediation tasks added"
fi

# Release the validation lock
git rm -f "$VALIDATION_LOCK" --quiet 2>/dev/null || true
git commit -m "[HARNESS] agent($AGENT_ID): release validation lock" --quiet || true

"$SCRIPT_DIR/sync-repo.sh" push || {
    log_err "ERROR: failed to push validation results"
    exit 1
}

exit 0
