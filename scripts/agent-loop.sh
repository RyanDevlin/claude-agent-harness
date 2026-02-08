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

iteration=0
env_initialized=false

log() {
    echo "[agent-loop/$AGENT_ID] $(date '+%H:%M:%S') $*"
}

# Find the next pending task from tasks.json. Prints the task ID or empty string.
next_pending_task() {
    if [ ! -f "$WORKSPACE/tasks.json" ]; then
        echo ""
        return
    fi
    jq -r '[.[] | select(.status == "pending")] | .[0].id // empty' "$WORKSPACE/tasks.json"
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

    cat <<EOF
$base_prompt
$spec_section
---

## Your Current Task

**Task ID:** $task_id
**Description:** $description

**Steps:**
$steps

Work on this task now. Commit your changes frequently with clear messages.
EOF
}

# Run init.sh if it exists and we haven't already run it this session.
run_init() {
    if [ "$env_initialized" = true ]; then
        return
    fi

    if [ -f "$WORKSPACE/init.sh" ]; then
        log "Running init.sh to set up project environment..."
        chmod +x "$WORKSPACE/init.sh"
        if (cd "$WORKSPACE" && bash init.sh); then
            log "init.sh completed successfully"
        else
            log "WARNING: init.sh exited with error (continuing anyway)"
        fi
    fi

    env_initialized=true
}

log "Starting agent loop (id: $AGENT_ID)"

# ── Phase 1: Planning ─────────────────────────────────────────────────────────

log "Phase 1: Ensuring tasks.json exists..."
"$SCRIPT_DIR/sync-repo.sh" pull

cd "$WORKSPACE"

if [ ! -f tasks.json ]; then
    log "No tasks.json found — running planner agent..."
    "$SCRIPT_DIR/plan-tasks.sh" || {
        log "ERROR: planning failed, exiting"
        exit 1
    }
    # Re-pull to get the planning results
    "$SCRIPT_DIR/sync-repo.sh" pull
fi

cd "$WORKSPACE"
if [ ! -f tasks.json ]; then
    log "ERROR: tasks.json still missing after planning phase"
    exit 1
fi

log "Phase 1 complete — tasks.json ready"

# ── Phase 2: Environment Setup ────────────────────────────────────────────────

log "Phase 2: Setting up environment..."
run_init
log "Phase 2 complete"

# ── Phase 3: Task Loop ────────────────────────────────────────────────────────

log "Phase 3: Starting task loop..."

while true; do
    # Check iteration limit
    if [ "$MAX_ITERATIONS" -gt 0 ]; then
        iteration=$((iteration + 1))
        if [ "$iteration" -gt "$MAX_ITERATIONS" ]; then
            log "Reached max iterations ($MAX_ITERATIONS), exiting"
            exit 0
        fi
        log "── Iteration $iteration/$MAX_ITERATIONS ──"
    fi

    # Step 1: Sync — pull the latest
    log "Syncing repository..."
    "$SCRIPT_DIR/sync-repo.sh" pull

    cd "$WORKSPACE"

    # Re-run init.sh if it changed (e.g., another agent updated it)
    run_init

    # Step 2: Find next pending task
    TASK_ID="$(next_pending_task)"

    if [ -z "$TASK_ID" ]; then
        log "No pending tasks remaining. Agent done."
        exit 0
    fi

    log "Found pending task: $TASK_ID"

    # Step 3: Try to claim it
    if ! "$SCRIPT_DIR/claim-task.sh" "$TASK_ID"; then
        log "Failed to claim $TASK_ID, will retry with a different task"
        sleep $((RANDOM % 3 + 1))  # Small random backoff to reduce collisions
        continue
    fi

    # Step 4: Run Claude on the task
    log "Running Claude on task $TASK_ID..."
    PROMPT="$(build_prompt "$TASK_ID")"
    COMMIT_BEFORE="$(git rev-parse --short=8 HEAD)"
    LOGFILE="/tmp/claude_${TASK_ID}_${COMMIT_BEFORE}.log"

    cd "$WORKSPACE"
    if claude --dangerously-skip-permissions \
              -p "$PROMPT" \
              --model "$CLAUDE_MODEL" \
              &> "$LOGFILE"; then
        log "Claude completed task $TASK_ID successfully"
        TASK_STATUS="done"
    else
        log "Claude exited with error on task $TASK_ID (see $LOGFILE)"
        TASK_STATUS="failed"
    fi

    # Step 5: Commit any uncommitted work Claude left behind
    cd "$WORKSPACE"
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git add -A
        git commit -m "agent($AGENT_ID): work on task $TASK_ID" || true
    fi

    # Step 6: Release the task
    "$SCRIPT_DIR/release-task.sh" "$TASK_ID" "$TASK_STATUS"

    # Step 7: Push everything
    "$SCRIPT_DIR/sync-repo.sh" push || {
        log "ERROR: failed to push after completing task $TASK_ID"
    }

    log "Task $TASK_ID completed with status: $TASK_STATUS"
    log "──────────────────────────────────────────"
done
