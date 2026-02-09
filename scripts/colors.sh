#!/usr/bin/env bash
# colors.sh — Shared ANSI color definitions for log output.
# Source this from other scripts: source "$(dirname "$0")/colors.sh"

# Colors (using \033 for broad compatibility)
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_PURPLE='\033[0;95m'
_CYAN='\033[0;36m'
_BOLD='\033[1m'
_DIM='\033[2m'
_RESET='\033[0m'
