#!/usr/bin/env bash
set -euo pipefail

# agent-loop.sh — Main entrypoint for agent containers.
# Phase 1: Ensure tasks.json exists (run planner if needed)
# Phase 2: Run init.sh if present (install project-specific deps)
# Phase 3: Continuously claim and work on tasks using the Claude CLI

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="/workspace"
AGENT_ID="${HOSTNAME:-agent-$$}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
AGENT_PROMPT_FILE="${AGENT_PROMPT_FILE:-/harness/AGENT_PROMPT.md}"
LOCK_STALE_MINUTES="${LOCK_STALE_MINUTES:-30}"
MAX_TASK_RETRIES="${MAX_TASK_RETRIES:-2}"
ENABLE_VALIDATION="${ENABLE_VALIDATION:-true}"
MAX_VALIDATION_ROUNDS="${MAX_VALIDATION_ROUNDS:-2}"

iteration=0
env_initialized=false

source "$SCRIPT_DIR/colors.sh"

_PREFIX="[agent/$AGENT_ID]"
log()      { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} $*"; }
log_ok()   { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_GREEN}$*${_RESET}"; }
log_err()  { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_RED}$*${_RESET}"; }
log_warn() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_YELLOW}$*${_RESET}"; }
log_task() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_PURPLE}$*${_RESET}"; }
log_info() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_CYAN}$*${_RESET}"; }

# Check if an agent's container is still running via Docker Compose DNS.
# Container hostnames are registered in Docker's internal DNS and removed on stop.
# Returns 0 if alive, 1 if dead.
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

# Check if a lock should be reclaimed: agent is dead OR lock is stale.
is_lock_dead() {
    local lock_file="$1"
    local lock_agent
    lock_agent=$(jq -r '.agent // "unknown"' "$lock_file" 2>/dev/null)

    if ! is_agent_alive "$lock_agent"; then
        return 0  # Agent is dead — lock is dead
    fi
    if is_lock_stale "$lock_file"; then
        return 0  # Agent may be alive but lock is too old — treat as dead
    fi
    return 1  # Agent is alive and lock is fresh
}

# Clean up dead/stale task locks from crashed agents.
# Resets their tasks back to "pending" so they can be picked up again.
cleanup_stale_locks() {
    local lock_file task_id lock_agent reason cleaned=0

    for lock_file in "$WORKSPACE"/current_tasks/*.lock; do
        [ -f "$lock_file" ] || continue
        # Skip planning/validation locks (handled by their own scripts)
        [[ "$(basename "$lock_file")" == "_planning.lock" ]] && continue
        [[ "$(basename "$lock_file")" == "_validation.lock" ]] && continue

        lock_agent=$(jq -r '.agent // "unknown"' "$lock_file" 2>/dev/null)
        task_id=$(jq -r '.task_id // empty' "$lock_file" 2>/dev/null)

        # Check if this is our own abandoned lock. This happens when:
        # 1. We completed a task and committed the release locally
        # 2. Push failed (merge conflict)
        # 3. Next pull did git reset --hard, discarding our release commit
        # 4. The lock is back from remote, still owned by us
        # Since we're in cleanup (not actively working), this lock is abandoned.
        if [ "$lock_agent" = "$AGENT_ID" ]; then
            log_warn "Found our own abandoned lock for task $task_id — push must have failed, resetting to pending"
            if [ -n "$task_id" ] && [ -f "$WORKSPACE/tasks.json" ]; then
                jq --arg id "$task_id" \
                   'map(if .id == $id then .status = "pending" else . end)' \
                   "$WORKSPACE/tasks.json" > "$WORKSPACE/tasks.json.tmp" \
                   && mv "$WORKSPACE/tasks.json.tmp" "$WORKSPACE/tasks.json"
            fi
            git rm -f "$lock_file" --quiet 2>/dev/null || rm -f "$lock_file"
            cleaned=$((cleaned + 1))
            continue
        fi

        if is_lock_dead "$lock_file"; then
            # Determine reason for logging
            if ! is_agent_alive "$lock_agent"; then
                reason="agent $lock_agent is dead"
            else
                reason="lock is stale"
            fi
            log "Reclaiming lock: task $task_id ($reason) — resetting to pending"

            # Reset task status back to pending
            if [ -n "$task_id" ] && [ -f "$WORKSPACE/tasks.json" ]; then
                jq --arg id "$task_id" \
                   'map(if .id == $id then .status = "pending" else . end)' \
                   "$WORKSPACE/tasks.json" > "$WORKSPACE/tasks.json.tmp" \
                   && mv "$WORKSPACE/tasks.json.tmp" "$WORKSPACE/tasks.json"
            fi

            git rm -f "$lock_file" --quiet 2>/dev/null || rm -f "$lock_file"
            cleaned=$((cleaned + 1))
        fi
    done

    # Also find orphaned tasks: in_progress in tasks.json but no corresponding lock file.
    # This happens when an agent's release/push failed or was interrupted.
    if [ -f "$WORKSPACE/tasks.json" ]; then
        local orphan_ids
        orphan_ids=$(jq -r '.[] | select(.status == "in_progress") | .id' "$WORKSPACE/tasks.json" 2>/dev/null)
        local orphan_id
        for orphan_id in $orphan_ids; do
            [ -n "$orphan_id" ] || continue
            if [ ! -f "$WORKSPACE/current_tasks/${orphan_id}.lock" ]; then
                log "Orphaned task $orphan_id is in_progress with no lock file — resetting to pending"
                jq --arg id "$orphan_id" \
                   'map(if .id == $id then .status = "pending" else . end)' \
                   "$WORKSPACE/tasks.json" > "$WORKSPACE/tasks.json.tmp" \
                   && mv "$WORKSPACE/tasks.json.tmp" "$WORKSPACE/tasks.json"
                cleaned=$((cleaned + 1))
            fi
        done
    fi

    # Reset retriable failed tasks: tasks marked "failed" that haven't exhausted MAX_TASK_RETRIES.
    # This handles tasks that failed before the retry feature was added (no retry_count field).
    if [ -f "$WORKSPACE/tasks.json" ] && [ "$MAX_TASK_RETRIES" -gt 0 ]; then
        local failed_ids
        failed_ids=$(jq -r --argjson max "$MAX_TASK_RETRIES" \
            '.[] | select(.status == "failed" and ((.retry_count // 0) < $max)) | .id' \
            "$WORKSPACE/tasks.json" 2>/dev/null)
        local failed_id
        for failed_id in $failed_ids; do
            [ -n "$failed_id" ] || continue
            local current_retry
            current_retry=$(jq -r --arg id "$failed_id" '.[] | select(.id == $id) | .retry_count // 0' "$WORKSPACE/tasks.json")
            local new_retry=$((current_retry + 1))
            log_warn "Failed task $failed_id has retry_count=$current_retry (max=$MAX_TASK_RETRIES) — requeueing as pending (retry #$new_retry)"
            jq --arg id "$failed_id" --argjson retry "$new_retry" \
               'map(if .id == $id then .status = "pending" | .retry_count = $retry else . end)' \
               "$WORKSPACE/tasks.json" > "$WORKSPACE/tasks.json.tmp" \
               && mv "$WORKSPACE/tasks.json.tmp" "$WORKSPACE/tasks.json"
            cleaned=$((cleaned + 1))
        done
    fi

    if [ "$cleaned" -gt 0 ]; then
        git add -A
        git commit -m "[HARNESS] agent($AGENT_ID): reclaimed $cleaned dead/orphaned lock(s)" --quiet 2>/dev/null || true
        "$SCRIPT_DIR/sync-repo.sh" push 2>/dev/null || true
        log "Reclaimed $cleaned dead/orphaned lock(s)"
    fi
}

# ── SSH Setup ──────────────────────────────────────────────────────────────────
# The SSH private key is mounted at /run/ssh_key (read-only, from docker-compose).
# Configure git to use it for all SSH operations.
setup_ssh() {
    if [ -f /run/ssh_key ]; then
        # SSH requires strict permissions on key files; copy to writable location
        # Use install with sudo fallback to handle UID mismatches between host and container
        install -m 600 /run/ssh_key /tmp/ssh_key 2>/dev/null \
            || sudo install -m 600 -o "$(id -u)" -g "$(id -g)" /run/ssh_key /tmp/ssh_key
        export GIT_SSH_COMMAND="ssh -i /tmp/ssh_key -o IdentitiesOnly=yes"
        log "SSH key configured"
    else
        log_warn "WARNING: no SSH key at /run/ssh_key — git push/pull will fail"
    fi
}

setup_ssh

# ── Task helpers ──────────────────────────────────────────────────────────────

# Find the next pending task from tasks.json. Prints the task ID or empty string.
# Defers "final-*" tasks until all other tasks (pending + in_progress) are done,
# so that final validation/integration tasks only run after all regular work completes.
next_pending_task() {
    if [ ! -f "$WORKSPACE/tasks.json" ]; then
        echo ""
        return
    fi

    # Try non-final pending tasks first
    local next
    next=$(jq -r '[.[] | select(.status == "pending" and (.id | startswith("final-") | not))] | .[0].id // empty' "$WORKSPACE/tasks.json")
    if [ -n "$next" ]; then
        echo "$next"
        return
    fi

    # Only final-* tasks remain pending. Check if any non-final tasks are still in progress.
    local non_final_active
    non_final_active=$(jq '[.[] | select((.status == "pending" or .status == "in_progress") and (.id | startswith("final-") | not))] | length' "$WORKSPACE/tasks.json")
    if [ "$non_final_active" -gt 0 ]; then
        # Other work is still running — don't start final tasks yet
        echo ""
        return
    fi

    # All non-final work is done — release final tasks
    jq -r '[.[] | select(.status == "pending")] | .[0].id // empty' "$WORKSPACE/tasks.json"
}

# Count remaining pending tasks.
pending_task_count() {
    if [ ! -f "$WORKSPACE/tasks.json" ]; then
        echo "0"
        return
    fi
    jq '[.[] | select(.status == "pending")] | length' "$WORKSPACE/tasks.json"
}

# Get the task description for a given task ID.
get_task_description() {
    local task_id="$1"
    jq -r --arg id "$task_id" '.[] | select(.id == $id) | .description' "$WORKSPACE/tasks.json"
}

# Get the task steps as a numbered list.
get_task_steps() {
    local task_id="$1"
    jq -r --arg id "$task_id" '
        .[] | select(.id == $id) | .steps // [] |
        to_entries | map("\(.key + 1). \(.value)") | join("\n")
    ' "$WORKSPACE/tasks.json"
}

# Build the full prompt for Claude, injecting task context into the agent prompt.
build_prompt() {
    local task_id="$1"
    local description
    local steps
    description="$(get_task_description "$task_id")"
    steps="$(get_task_steps "$task_id")"

    local base_prompt
    base_prompt="$(cat "$AGENT_PROMPT_FILE")"

    # Include PROJECT_SPEC.md content if it exists
    local spec_section=""
    if [ -f "$WORKSPACE/PROJECT_SPEC.md" ]; then
        spec_section="
---

## Project Specification

$(cat "$WORKSPACE/PROJECT_SPEC.md")
"
    fi

    # Include retry context if this is a retry attempt
    local retry_count
    retry_count=$(jq -r --arg id "$task_id" '.[] | select(.id == $id) | .retry_count // 0' "$WORKSPACE/tasks.json")
    local retry_section=""
    if [ "$retry_count" -gt 0 ]; then
        retry_section="
**NOTE: This is retry attempt #${retry_count}.** A previous agent attempted this task and failed.
Check the git log for what was tried before. Review the current state of the code and adapt your approach.
Do not repeat the same failing strategy."
    fi

    cat <<EOF
$base_prompt
$spec_section
---

## Your Current Task

**Task ID:** $task_id
**Description:** $description
$retry_section

**Steps:**
$steps

Work on this task now. Commit your changes frequently with clear messages.
EOF
}

# Run init.sh if it exists and we haven't already run it this session.
# If init.sh fails, runs Claude to diagnose and fix it, then retries.
run_init() {
    if [ "$env_initialized" = true ]; then
        return
    fi

    if [ -f "$WORKSPACE/init.sh" ]; then
        log "Running init.sh..."
        chmod +x "$WORKSPACE/init.sh"

        local init_log="/tmp/init_${AGENT_ID}.log"
        if (cd "$WORKSPACE" && bash init.sh) > "$init_log" 2>&1; then
            log_ok "init.sh completed"
            env_initialized=true
            return
        fi

        log_warn "init.sh failed — checking if another agent already fixed it..."

        # Pull latest in case another agent already pushed a fix
        "$SCRIPT_DIR/sync-repo.sh" pull 2>/dev/null || true
        cd "$WORKSPACE"
        chmod +x "$WORKSPACE/init.sh"
        if (cd "$WORKSPACE" && bash init.sh) > "$init_log" 2>&1; then
            log_ok "init.sh completed (fixed by another agent)"
            env_initialized=true
            return
        fi

        log_warn "init.sh still failing — attempting to fix it with Claude..."
        local init_error
        init_error=$(tail -30 "$init_log" 2>/dev/null)

        local fix_prompt
        fix_prompt="$(cat <<FIXEOF
The environment setup script init.sh failed. Your job is to fix init.sh so it runs successfully.

## Error output (last 30 lines):
$init_error

## Current init.sh contents:
$(cat "$WORKSPACE/init.sh")

## Instructions:
1. Read the error output carefully to understand what went wrong.
2. Fix init.sh so it runs without errors on Ubuntu 24.04.
3. Common issues: wrong package names, missing repositories, incorrect download URLs, permission errors.
4. Make sure to use non-interactive flags (e.g. apt-get install -y).
5. Save the fixed init.sh and commit it with a clear message.
6. Do NOT run init.sh yourself — just fix the script.
FIXEOF
)"

        local fix_log="/tmp/init_fix_${AGENT_ID}.log"
        cd "$WORKSPACE"
        if claude --dangerously-skip-permissions \
                  -p "$fix_prompt" \
                  --model "$CLAUDE_MODEL" \
                  &> "$fix_log"; then
            log "Claude finished fixing init.sh"

            # Commit and push the fix so other agents benefit
            git add -A
            git commit -m "[HARNESS] agent($AGENT_ID): fix init.sh" --quiet 2>/dev/null || true
            "$SCRIPT_DIR/sync-repo.sh" push 2>/dev/null || true

            # Retry init.sh with the fix
            log "Retrying init.sh after fix..."
            chmod +x "$WORKSPACE/init.sh"
            if (cd "$WORKSPACE" && bash init.sh) > "$init_log" 2>&1; then
                log_ok "init.sh completed (after fix)"
            else
                log_err "WARNING: init.sh still failing after fix (continuing anyway)"
            fi
        else
            log_err "WARNING: Claude could not fix init.sh (continuing anyway)"
        fi
    fi

    env_initialized=true
}

# Check if all tasks are in a terminal state (done or failed, none pending or in_progress).
all_tasks_terminal() {
    if [ ! -f "$WORKSPACE/tasks.json" ]; then
        return 1
    fi
    local non_terminal
    non_terminal=$(jq '[.[] | select(.status == "pending" or .status == "in_progress")] | length' "$WORKSPACE/tasks.json")
    [ "$non_terminal" -eq 0 ]
}

# Check if validation has passed (VALIDATION_PASSED file exists in repo).
validation_has_passed() {
    [ -f "$WORKSPACE/VALIDATION_PASSED" ]
}

# Get the current validation round from .validation_round file.
get_validation_round() {
    if [ -f "$WORKSPACE/.validation_round" ]; then
        cat "$WORKSPACE/.validation_round"
    else
        echo "0"
    fi
}

log_info "Starting (model: $CLAUDE_MODEL)"

# ── Phase 1: Planning ────────────────────────────────────────────────────────

log_info "Phase 1: Checking for tasks.json..."
"$SCRIPT_DIR/sync-repo.sh" pull

cd "$WORKSPACE"

if [ ! -f tasks.json ]; then
    log "No tasks.json — entering planning phase"
    "$SCRIPT_DIR/plan-tasks.sh" || {
        log_err "ERROR: planning failed, exiting"
        exit 1
    }
    # Re-pull to get the planning results
    "$SCRIPT_DIR/sync-repo.sh" pull
fi

cd "$WORKSPACE"
if [ ! -f tasks.json ]; then
    log_err "ERROR: tasks.json still missing after planning"
    exit 1
fi

TOTAL_TASKS=$(jq 'length' tasks.json 2>/dev/null || echo "?")
DONE_COUNT=$(jq '[.[] | select(.status == "done")] | length' tasks.json 2>/dev/null || echo 0)
PENDING_COUNT=$(jq '[.[] | select(.status == "pending")] | length' tasks.json 2>/dev/null || echo 0)
IN_PROGRESS_COUNT=$(jq '[.[] | select(.status == "in_progress")] | length' tasks.json 2>/dev/null || echo 0)
FAILED_COUNT=$(jq '[.[] | select(.status == "failed")] | length' tasks.json 2>/dev/null || echo 0)
RETRIABLE_COUNT=$(jq --argjson max "${MAX_TASK_RETRIES:-2}" '[.[] | select(.status == "failed" and ((.retry_count // 0) < $max))] | length' tasks.json 2>/dev/null || echo 0)

log_ok "Phase 1 complete — $TOTAL_TASKS total tasks:"
log "  ${_GREEN}done: $DONE_COUNT${_RESET}  |  pending: $PENDING_COUNT  |  ${_YELLOW}in_progress: $IN_PROGRESS_COUNT${_RESET}  |  ${_RED}failed: $FAILED_COUNT${_RESET}"

WILL_RETRY=$((IN_PROGRESS_COUNT + RETRIABLE_COUNT))
if [ "$WILL_RETRY" -gt 0 ]; then
    log_warn "Will reschedule $WILL_RETRY incomplete tasks ($IN_PROGRESS_COUNT orphaned + $RETRIABLE_COUNT retriable failures)"
fi

# ── Phase 2: Environment Setup ────────────────────────────────────────────────

log_info "Phase 2: Environment setup"
run_init

# ── Phase 3: Task Loop ────────────────────────────────────────────────────────

log_info "Phase 3: Starting task loop"

while true; do
    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ]; then
        iteration=$((iteration + 1))
        if [ "$iteration" -gt "$MAX_ITERATIONS" ]; then
            log "Reached max iterations ($MAX_ITERATIONS), exiting"
            exit 0
        fi
    fi

    # Step 1: Sync and clean up stale locks from crashed agents
    "$SCRIPT_DIR/sync-repo.sh" pull
    cd "$WORKSPACE"
    cleanup_stale_locks

    # Re-run init.sh if it changed (e.g., another agent updated it)
    run_init

    # Step 2: Find next pending task
    TASK_ID="$(next_pending_task)"

    if [ -z "$TASK_ID" ]; then
        # No pending tasks — decide what to do

        if validation_has_passed; then
            log_ok "All tasks complete and validation passed — exiting"
            exit 0
        fi

        if [ "$ENABLE_VALIDATION" != "true" ]; then
            log_ok "All tasks complete — exiting"
            exit 0
        fi

        # If some tasks are still in_progress (other agents working), wait
        if ! all_tasks_terminal; then
            local active_count
            active_count=$(jq '[.[] | select(.status == "in_progress")] | length' "$WORKSPACE/tasks.json" 2>/dev/null || echo "?")
            log "No pending tasks but $active_count still in progress — waiting 15s..."
            sleep 15
            continue
        fi

        # All tasks are terminal — run validation
        VALIDATION_ROUND=$(get_validation_round)
        if [ "$VALIDATION_ROUND" -ge "$MAX_VALIDATION_ROUNDS" ]; then
            log "Max validation rounds ($MAX_VALIDATION_ROUNDS) reached — exiting"
            exit 0
        fi

        log_info "All tasks terminal — entering validation (round $((VALIDATION_ROUND + 1))/$MAX_VALIDATION_ROUNDS)"

        "$SCRIPT_DIR/validate-project.sh" || {
            log_warn "WARNING: validation script failed"
        }

        # After validation, pull and loop back — there may be new remediation tasks
        "$SCRIPT_DIR/sync-repo.sh" pull
        cd "$WORKSPACE"
        continue
    fi

    PENDING=$(pending_task_count)
    TASK_DESC="$(get_task_description "$TASK_ID")"
    log_task "Starting task: $TASK_ID — $TASK_DESC ($PENDING pending)"

    # Step 3: Try to claim it
    if ! "$SCRIPT_DIR/claim-task.sh" "$TASK_ID"; then
        sleep $((RANDOM % 3 + 1))  # Small random backoff to reduce collisions
        continue
    fi

    # Step 4: Run Claude on the task
    log "Running Claude on task $TASK_ID..."
    PROMPT="$(build_prompt "$TASK_ID")"
    LOGFILE="/tmp/claude_${TASK_ID}.log"

    cd "$WORKSPACE"
    if claude --dangerously-skip-permissions \
              -p "$PROMPT" \
              --model "$CLAUDE_MODEL" \
              &> "$LOGFILE"; then
        log_ok "Claude completed task $TASK_ID"
        TASK_STATUS="done"
    else
        log_err "Claude failed on task $TASK_ID"
        # Show tail of log for debugging
        tail -3 "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
            log "  $line"
        done
        TASK_STATUS="failed"
    fi

    # Step 5: Commit any uncommitted work Claude left behind
    cd "$WORKSPACE"
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git add -A
        git commit -m "[FEATURE] agent($AGENT_ID): work on task $TASK_ID" --quiet || true
    fi

    # Step 6: Release the task
    "$SCRIPT_DIR/release-task.sh" "$TASK_ID" "$TASK_STATUS"

    # Step 7: Push everything (sync-repo.sh retries internally with backoff)
    if ! "$SCRIPT_DIR/sync-repo.sh" push; then
        log_err "ERROR: failed to push after task $TASK_ID — local commits will be retried on next sync"
        # Don't exit; the orphan detection in cleanup_stale_locks will handle it
        # if our local commits get lost on the next pull.
    fi

    if [ "$TASK_STATUS" = "done" ]; then
        log_ok "Task $TASK_ID — $TASK_STATUS"
    else
        log_err "Task $TASK_ID — $TASK_STATUS"
    fi
    log "${_DIM}────────────────────────────────────────${_RESET}"
done
