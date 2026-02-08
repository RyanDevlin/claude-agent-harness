#!/usr/bin/env bash
set -euo pipefail

# setup.sh — One-time setup script for the Claude Agent Harness.
# Generates a deploy key, helps you add it to GitHub, and configures the harness.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_NAME="harness_deploy_key"
KEY_PATH="$HOME/.ssh/$KEY_NAME"
CONFIG_ENV="$SCRIPT_DIR/config.env"
DOT_ENV="$SCRIPT_DIR/.env"

# ── Helpers ────────────────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[1;32m%s\033[0m" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m" "$*"; }
red()   { printf "\033[1;31m%s\033[0m" "$*"; }

step() {
    echo ""
    echo "$(bold "[$1]") $2"
    echo "────────────────────────────────────────────"
}

# ── Parse repo info from config.env ────────────────────────────────────────────

REPO_URL=$(grep -E '^REPO_URL=' "$CONFIG_ENV" | cut -d= -f2-)

if [ -z "$REPO_URL" ]; then
    echo "$(red "Error:") REPO_URL not set in config.env"
    echo "Please edit config.env and set REPO_URL first."
    exit 1
fi

# Extract owner/repo from SSH or HTTPS URL
if [[ "$REPO_URL" == git@github.com:* ]]; then
    REPO_SLUG="${REPO_URL#git@github.com:}"
    REPO_SLUG="${REPO_SLUG%.git}"
elif [[ "$REPO_URL" == https://github.com/* ]]; then
    REPO_SLUG="${REPO_URL#https://github.com/}"
    REPO_SLUG="${REPO_SLUG%.git}"
else
    echo "$(red "Error:") Could not parse GitHub owner/repo from REPO_URL: $REPO_URL"
    echo "Expected format: git@github.com:owner/repo.git or https://github.com/owner/repo.git"
    exit 1
fi

REPO_OWNER="${REPO_SLUG%/*}"
REPO_NAME="${REPO_SLUG#*/}"

echo ""
echo "$(bold "Claude Agent Harness — Setup")"
echo ""
echo "  Repo:  $(bold "$REPO_OWNER/$REPO_NAME")"
echo "  Key:   $(bold "$KEY_PATH")"
echo ""

# ── Step 1: Generate deploy key ───────────────────────────────────────────────

step "1/4" "Generate SSH deploy key"

if [ -f "$KEY_PATH" ]; then
    echo "Deploy key already exists at $KEY_PATH"
    read -rp "Overwrite it? [y/N] " answer
    if [[ "$answer" != [yY] ]]; then
        echo "Keeping existing key."
    else
        rm -f "$KEY_PATH" "${KEY_PATH}.pub"
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "claude-agent-harness:$REPO_SLUG"
        echo "$(green "Key generated.")"
    fi
else
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "claude-agent-harness:$REPO_SLUG"
    echo "$(green "Key generated.")"
fi

# ── Step 2: Add deploy key to GitHub ──────────────────────────────────────────

step "2/4" "Add deploy key to GitHub"

PUBLIC_KEY=$(cat "${KEY_PATH}.pub")
DEPLOY_KEY_URL="https://github.com/$REPO_OWNER/$REPO_NAME/settings/keys/new"

echo ""
echo "$(bold "Your public key:")"
echo ""
echo "  $PUBLIC_KEY"
echo ""
echo "Add this as a deploy key on GitHub with $(bold "write access") enabled."
echo ""
echo "  URL: $(bold "$DEPLOY_KEY_URL")"
echo ""

# Try to open the browser automatically
if command -v xdg-open &>/dev/null; then
    xdg-open "$DEPLOY_KEY_URL" 2>/dev/null || true
elif command -v open &>/dev/null; then
    open "$DEPLOY_KEY_URL" 2>/dev/null || true
fi

echo "Steps:"
echo "  1. The browser should open to the deploy key page (or open the URL above)"
echo "  2. Set the title to: $(bold "claude-agent-harness")"
echo "  3. Paste the public key shown above"
echo "  4. Check $(bold "Allow write access")"
echo "  5. Click $(bold "Add key")"
echo ""
read -rp "Press Enter once you've added the deploy key on GitHub... "

# ── Step 3: Test connection ───────────────────────────────────────────────────

step "3/4" "Test SSH connection"

echo "Testing git clone with the deploy key..."

TEST_DIR=$(mktemp -d)
GIT_SSH_COMMAND="ssh -i $KEY_PATH -o IdentitiesOnly=yes" git clone --depth 1 "$REPO_URL" "$TEST_DIR/test-clone" 2>&1 && {
    echo "$(green "Connection successful!")"
    rm -rf "$TEST_DIR"
} || {
    rm -rf "$TEST_DIR"
    echo ""
    echo "$(red "Connection failed.")"
    echo "Please verify:"
    echo "  - The deploy key was added to the correct repo ($REPO_OWNER/$REPO_NAME)"
    echo "  - Write access was enabled"
    echo "  - The repo URL in config.env is correct"
    echo ""
    read -rp "Retry? [Y/n] " retry
    if [[ "$retry" == [nN] ]]; then
        echo "You can re-run this script later to try again."
        exit 1
    fi
    echo "Retrying..."
    TEST_DIR=$(mktemp -d)
    GIT_SSH_COMMAND="ssh -i $KEY_PATH -o IdentitiesOnly=yes" git clone --depth 1 "$REPO_URL" "$TEST_DIR/test-clone" 2>&1 && {
        echo "$(green "Connection successful!")"
        rm -rf "$TEST_DIR"
    } || {
        rm -rf "$TEST_DIR"
        echo "$(red "Still failing. Please check the deploy key and try again later.")"
        exit 1
    }
}

# ── Step 4: Update harness config ─────────────────────────────────────────────

step "4/4" "Configure harness"

# Update config.env
sed -i "s|^SSH_KEY_FILE=.*|SSH_KEY_FILE=$KEY_NAME|" "$CONFIG_ENV"
echo "  Updated config.env: SSH_KEY_FILE=$KEY_NAME"

# Update .env (for docker compose volume interpolation)
# Use absolute path to avoid issues with Snap Docker's HOME override
cat > "$DOT_ENV" <<EOF
# Docker Compose interpolation variables (used for volume mounts)
# These must be here (not in config.env) because compose reads .env for file-level substitution
# Use absolute path to avoid issues with Snap Docker's HOME override
SSH_KEY_PATH=$KEY_PATH
EOF
echo "  Updated .env: SSH_KEY_PATH=$KEY_PATH"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "$(green "Setup complete!")"
echo ""
echo "To run the harness:"
echo ""
echo "  $(bold "export ANTHROPIC_API_KEY=sk-ant-...")"
echo "  $(bold "docker compose build")"
echo "  $(bold "docker compose up --scale agent=4")"
echo ""
