# Claude Agent Harness

A lightweight harness for running multiple Claude coding agents in parallel. You provide a project spec in markdown, and the harness takes care of the rest — planning tasks, setting up the environment, and coordinating agents so they don't step on each other. Each agent runs in a Docker container, and all coordination happens through git.

Inspired by Anthropic's engineering blog posts on [building effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) and [building a C compiler with agents](https://www.anthropic.com/engineering/building-c-compiler).

## How It Works

The harness runs in three phases:

**Phase 1 — Planning.** The first agent to boot reads your `PROJECT_SPEC.md` and generates a `tasks.json` (task breakdown) and an `init.sh` (environment setup script). A git-based lock ensures only one agent plans — the rest wait.

**Phase 2 — Environment Setup.** Every agent runs `init.sh` to install project-specific dependencies (Go, Python, Rust, etc.) on top of the base Ubuntu image.

**Phase 3 — Task Loop.** Each agent repeatedly:
1. Pulls the latest from git
2. Finds the next pending task
3. Claims it by committing a lock file to `current_tasks/`
4. Runs the Claude CLI to work on the task
5. Commits the work, releases the lock, and pushes

If two agents race for the same task, git's push semantics handle it — the second push fails, that agent backs off and picks a different task.

## Project Structure

```
claude-agent-harness/
├── Dockerfile                 # Ubuntu 24.04 + build tools + Claude CLI
├── docker-compose.yml         # Run and scale agents
├── config.env                 # Your configuration (repo URL, model, etc.)
├── AGENT_PROMPT.md            # Instructions given to coding agents
├── PLANNER_PROMPT.md          # Instructions given to the planning agent
├── PROJECT_SPEC.md.example    # Example project specification
└── scripts/
    ├── agent-loop.sh          # Main entrypoint (three-phase orchestrator)
    ├── plan-tasks.sh          # Runs the planner agent with locking
    ├── claim-task.sh          # Claims a task via git lock file
    ├── release-task.sh        # Releases a task and updates status
    └── sync-repo.sh           # Git clone/pull/push helper
```

## Quick Start

### Prerequisites

- Docker and Docker Compose
- An [Anthropic API key](https://console.anthropic.com/)
- A git repo (GitHub, GitLab, etc.) that agents can clone and push to

### 1. Clone this repo

```bash
git clone <this-repo-url> claude-agent-harness
cd claude-agent-harness
```

### 2. Add a project spec to your target repo

Create a `PROJECT_SPEC.md` file in the root of the repo you want agents to work on. This is the only input agents need — they'll read it and figure out the rest. See [Writing a Project Spec](#writing-a-project-spec) below.

### 3. Configure the harness

Edit `config.env`:

```bash
# Point to your target repo
REPO_URL=git@github.com:your-org/your-repo.git

# Branch agents will work on
REPO_BRANCH=main

# Model to use (for both planning and coding)
CLAUDE_MODEL=claude-sonnet-4-20250514
```

### 4. Export your API key

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### 5. Build and run

```bash
# Build the container image
docker compose build

# Run a single agent
docker compose up

# Or run multiple agents in parallel
docker compose up --scale agent=4
```

Agents will automatically:
1. Clone your repo
2. Generate a task plan from your `PROJECT_SPEC.md`
3. Install any project-specific dependencies
4. Start working through tasks, committing and pushing as they go

### 6. Monitor progress

Watch agent logs in your terminal, or check the repo:

```bash
# See what tasks exist and their status
git pull && cat tasks.json | jq '.[] | {id, status}'

# See which tasks are currently being worked on
ls current_tasks/

# See agent commit history
git log --oneline
```

## Configuration Reference

All options go in `config.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REPO_URL` | *(required)* | Git remote URL (SSH or HTTPS) |
| `REPO_BRANCH` | `main` | Branch to work on |
| `CLAUDE_MODEL` | `claude-sonnet-4-20250514` | Claude model for planning and coding |
| `AGENT_PROMPT_FILE` | `AGENT_PROMPT.md` | Path to the coding agent prompt |
| `MAX_ITERATIONS` | `0` | Max task loop iterations per agent (0 = unlimited) |

Additionally, `ANTHROPIC_API_KEY` must be set in your shell environment (not in `config.env`).

## Writing a Project Spec

The `PROJECT_SPEC.md` in your target repo is the single source of truth for agents. It should include:

- **What to build** — clear description of the project
- **Technical constraints** — language, frameworks, storage, ports
- **Feature requirements** — what the system should do
- **Testing expectations** — how to verify things work
- **Project structure** — suggested directory layout (optional but helpful)

See `PROJECT_SPEC.md.example` for a complete example (a Go URL shortener API).

The planner agent reads this spec and produces:
- **`tasks.json`** — ordered list of small, independent tasks
- **`init.sh`** — script to install project-specific tools (Go, Python, etc.)
- **`DECISIONS.md`** — documents any choices made when the spec was ambiguous

## Git Authentication

For **SSH URLs** (`git@github.com:...`), the harness mounts your SSH keys and agent socket:

```bash
# Make sure your SSH agent is running
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Then run as normal
docker compose up --scale agent=4
```

For **HTTPS URLs**, you can configure git credentials in the container or use a personal access token in the URL:

```bash
REPO_URL=https://<token>@github.com/your-org/your-repo.git
```

## Troubleshooting

**Agents can't push (permission denied)**
- Check that your SSH keys are loaded: `ssh-add -l`
- Ensure `SSH_AUTH_SOCK` is set in your shell
- For HTTPS, verify the token has push access

**Agents can't find `PROJECT_SPEC.md`**
- The file must be committed to the target repo's root, on the branch specified in `REPO_BRANCH`

**Planning phase takes too long or fails**
- Check the planner log inside the container: `/tmp/planner_*.log`
- Try a more capable model in `config.env` (e.g., `claude-opus-4-20250514`)

**Two agents claimed the same task**
- This shouldn't happen — the git-based locking prevents it. If you see it, check that agents can push to the remote (lock files must be committed and pushed to work)

**Agent exited immediately**
- If all tasks in `tasks.json` are `done` or `in_progress`, agents exit cleanly. Check `tasks.json` for task statuses.
