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

log() {
    echo "[plan-tasks/$AGENT_ID] $(date '+%H:%M:%S') $*"
}

cd "$WORKSPACE"

# If tasks.json already exists, nothing to do
if [ -f tasks.json ]; then
    log "tasks.json already exists, skipping planning"
    exit 0
fi

# Check for PROJECT_SPEC.md
if [ ! -f PROJECT_SPEC.md ]; then
    log "ERROR: no PROJECT_SPEC.md found in repo — nothing to plan from"
    exit 1
fi

# Try to claim the planning lock
git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || true

# Re-check after pull — maybe another agent already generated tasks
if [ -f tasks.json ]; then
    log "tasks.json appeared after pull, skipping planning"
    exit 0
fi

if [ -f "$PLAN_LOCK" ]; then
    log "Another agent is already planning, waiting..."
    # Wait for the other agent to finish planning
    for i in $(seq 1 60); do
        sleep 10
        git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || true
        if [ -f tasks.json ]; then
            log "tasks.json is now available"
            exit 0
        fi
        if [ ! -f "$PLAN_LOCK" ]; then
            log "Planning lock released but no tasks.json — retrying"
            break
        fi
    done

    # If we waited 10 minutes and still no tasks.json, something went wrong
    if [ ! -f tasks.json ]; then
        log "ERROR: timed out waiting for planning to complete"
        exit 1
    fi
    exit 0
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
git commit -m "[HARNESS] agent($AGENT_ID): claim planning lock"

if ! git push origin "$REPO_BRANCH"; then
    log "Failed to claim planning lock (conflict), waiting for other planner"
    git reset --hard "origin/$REPO_BRANCH"
    # Fall back to waiting
    for i in $(seq 1 60); do
        sleep 10
        git pull --rebase origin "$REPO_BRANCH" 2>/dev/null || true
        if [ -f tasks.json ]; then
            log "tasks.json is now available"
            exit 0
        fi
    done
    exit 1
fi

log "Claimed planning lock — running planner agent..."

# Run the planner
LOGFILE="/tmp/planner_${AGENT_ID}.log"

if claude --dangerously-skip-permissions \
          -p "$(cat "$PLANNER_PROMPT_FILE")" \
          --model "$CLAUDE_MODEL" \
          &> "$LOGFILE"; then
    log "Planner agent completed"
else
    log "Planner agent exited with error (see $LOGFILE)"
fi

# Commit whatever the planner produced
if [ -f tasks.json ]; then
    git add -A
    git commit -m "[PLAN] generate tasks and init script from project spec" || true

    # Remove the planning lock
    git rm -f "$PLAN_LOCK" 2>/dev/null || true
    git commit -m "[HARNESS] agent($AGENT_ID): release planning lock" || true

    "$SCRIPT_DIR/sync-repo.sh" push || {
        log "ERROR: failed to push planning results"
        exit 1
    }

    log "Planning complete — tasks.json committed"
    exit 0
else
    log "ERROR: planner did not produce tasks.json"
    # Clean up the lock so others can retry
    git rm -f "$PLAN_LOCK" 2>/dev/null || true
    git commit -m "[HARNESS] agent($AGENT_ID): release planning lock (failed)" || true
    git push origin "$REPO_BRANCH" 2>/dev/null || true
    exit 1
fi
