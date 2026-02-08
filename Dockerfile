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
    openssh-client \
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

# Pre-populate GitHub/GitLab/Bitbucket SSH host keys at the system level
# (not /root/.ssh, which gets overwritten by the docker-compose volume mount)
RUN mkdir -p /etc/ssh \
    && ssh-keyscan -t ed25519,rsa github.com gitlab.com bitbucket.org >> /etc/ssh/ssh_known_hosts 2>/dev/null

# Create non-root user (Claude CLI refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up git defaults for the agent user
RUN su - agent -c 'git config --global user.name "claude-agent" && git config --global user.email "claude-agent@harness.local"'

# Copy harness files
COPY scripts/ /harness/scripts/
COPY AGENT_PROMPT.md /harness/AGENT_PROMPT.md
COPY PLANNER_PROMPT.md /harness/PLANNER_PROMPT.md
COPY VALIDATOR_PROMPT.md /harness/VALIDATOR_PROMPT.md
RUN chmod +x /harness/scripts/*.sh

# Working directory for cloned repos
RUN mkdir -p /workspace && chown agent:agent /workspace

ENV AGENT_PROMPT_FILE=/harness/AGENT_PROMPT.md
ENV PLANNER_PROMPT_FILE=/harness/PLANNER_PROMPT.md
ENV VALIDATOR_PROMPT_FILE=/harness/VALIDATOR_PROMPT.md

USER agent
ENTRYPOINT ["/harness/scripts/agent-loop.sh"]
