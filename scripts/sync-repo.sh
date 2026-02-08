#!/usr/bin/env bash
set -euo pipefail

# sync-repo.sh — Clone/pull and push helper for agent containers.
# Usage:
#   sync-repo.sh pull   — Clone the repo if missing, otherwise pull latest
#   sync-repo.sh push   — Push changes to remote, retry up to 5 times with backoff

WORKSPACE="/workspace"
REPO_URL="${REPO_URL:?REPO_URL must be set}"
REPO_BRANCH="${REPO_BRANCH:-main}"
AGENT_ID="${HOSTNAME:-agent-$$}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/colors.sh"

_PREFIX="[sync/$AGENT_ID]"
log()      { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} $*"; }
log_ok()   { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_GREEN}$*${_RESET}"; }
log_err()  { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_RED}$*${_RESET}"; }
log_warn() { echo -e "${_DIM}${_PREFIX} $(date '+%H:%M:%S')${_RESET} ${_YELLOW}$*${_RESET}"; }

do_pull() {
    if [ ! -d "$WORKSPACE/.git" ]; then
        log "Cloning $REPO_URL (branch: $REPO_BRANCH)"
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$WORKSPACE" 2>&1 | grep -v "^$" || true
        log "Clone complete"
    else
        cd "$WORKSPACE"
        git fetch origin --quiet 2>/dev/null
        git rebase "origin/$REPO_BRANCH" --quiet 2>/dev/null || {
            log_warn "Rebase conflict, resetting to origin/$REPO_BRANCH"
            git rebase --abort 2>/dev/null || true
            git reset --hard "origin/$REPO_BRANCH" --quiet 2>/dev/null
        }
    fi

    cd "$WORKSPACE"
    # Ensure the current_tasks directory exists
    mkdir -p current_tasks
}

do_push() {
    cd "$WORKSPACE"
    local max_attempts=5

    for attempt in $(seq 1 "$max_attempts"); do
        if git push origin "$REPO_BRANCH" --quiet 2>/dev/null; then
            log "Push successful"
            return 0
        fi

        if [ "$attempt" -eq "$max_attempts" ]; then
            log_err "ERROR: push failed after $max_attempts attempts"
            return 1
        fi

        # Random backoff: 2-6s, scaling with attempt number
        local backoff=$(( (RANDOM % 5 + 2) * attempt ))
        log_warn "Push conflict (attempt $attempt/$max_attempts), rebasing and retrying in ${backoff}s..."
        sleep "$backoff"

        git pull --rebase origin "$REPO_BRANCH" --quiet 2>/dev/null || {
            git rebase --abort 2>/dev/null || true
            log_warn "Rebase failed during push retry, resetting and retrying..."
            git fetch origin --quiet 2>/dev/null || true
            git rebase "origin/$REPO_BRANCH" --quiet 2>/dev/null || {
                git rebase --abort 2>/dev/null || true
                log_err "ERROR: rebase failed after fetch, cannot push"
                return 1
            }
        }
    done
}

case "${1:-}" in
    pull)  do_pull ;;
    push)  do_push ;;
    *)
        echo "Usage: sync-repo.sh {pull|push}" >&2
        exit 1
        ;;
esac
