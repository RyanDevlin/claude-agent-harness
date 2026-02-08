FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base system dependencies + common build tools
# init.sh can install project-specific tools on top of this
RUN apt-get update && apt-get install -y \
    git \
    jq \
    curl \
    wget \
    ca-certificates \
    build-essential \
    sudo \
    unzip \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS) for Claude CLI
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude CLI
RUN npm install -g @anthropic-ai/claude-code

# Set up git defaults (agents will commit as this identity)
RUN git config --global user.name "claude-agent" \
    && git config --global user.email "claude-agent@harness.local"

# Copy harness files
COPY scripts/ /harness/scripts/
COPY AGENT_PROMPT.md /harness/AGENT_PROMPT.md
COPY PLANNER_PROMPT.md /harness/PLANNER_PROMPT.md
RUN chmod +x /harness/scripts/*.sh

# Working directory for cloned repos
RUN mkdir -p /workspace

ENV AGENT_PROMPT_FILE=/harness/AGENT_PROMPT.md
ENV PLANNER_PROMPT_FILE=/harness/PLANNER_PROMPT.md

ENTRYPOINT ["/harness/scripts/agent-loop.sh"]
