#!/usr/bin/env bash
set -euo pipefail

# sync-repo.sh — Clone/pull and push helper for agent containers.
# Usage:
#   sync-repo.sh pull   — Clone the repo if missing, otherwise pull latest
#   sync-repo.sh push   — Push changes to remote, retry once on failure

WORKSPACE="/workspace"
REPO_URL="${REPO_URL:?REPO_URL must be set}"
REPO_BRANCH="${REPO_BRANCH:-main}"

log() {
    echo "[sync-repo] $(date '+%H:%M:%S') $*"
}

do_pull() {
    if [ ! -d "$WORKSPACE/.git" ]; then
        log "Cloning $REPO_URL (branch: $REPO_BRANCH) into $WORKSPACE"
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$WORKSPACE"
    else
        log "Pulling latest from origin/$REPO_BRANCH"
        cd "$WORKSPACE"
        git fetch origin
        git rebase "origin/$REPO_BRANCH" || {
            log "Rebase failed, resetting to origin/$REPO_BRANCH"
            git rebase --abort 2>/dev/null || true
            git reset --hard "origin/$REPO_BRANCH"
        }
    fi

    cd "$WORKSPACE"
    # Ensure the current_tasks directory exists
    mkdir -p current_tasks
}

do_push() {
    cd "$WORKSPACE"
    log "Pushing to origin/$REPO_BRANCH"

    if ! git push origin "$REPO_BRANCH"; then
        log "Push failed, pulling and retrying..."
        git pull --rebase origin "$REPO_BRANCH" || {
            git rebase --abort 2>/dev/null || true
            log "ERROR: rebase failed during push retry"
            return 1
        }
        git push origin "$REPO_BRANCH" || {
            log "ERROR: push failed after retry"
            return 1
        }
    fi

    log "Push successful"
}

case "${1:-}" in
    pull)  do_pull ;;
    push)  do_push ;;
    *)
        echo "Usage: sync-repo.sh {pull|push}" >&2
        exit 1
        ;;
esac
