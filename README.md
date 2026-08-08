# Sandboxed Coding Agents on Shared Servers

Docker-based sandbox environments for running **Claude Code** and **OpenAI Codex CLI** in full-autonomy mode on shared Linux servers.

The problem this solves: you want to run a coding agent with permission prompts disabled (`--dangerously-skip-permissions` / `--yolo`), but you don't trust the agent to respect instructions like "don't touch files outside this directory." Instead of trusting the agent, these setups make the boundary physical: the agent runs in a container where **the only host path it can see is the project directory you launched it from**, plus small named volumes for credentials and state.

Design principles:

- **Docker is the sandbox.** No reliance on agent self-restraint or agent-internal sandboxing.
- **Log in once.** Auth tokens persist in per-user named volumes across sessions and rebuilds.
- **Minimal images.** The image is a sandbox skeleton plus everyday toolchains (C, Python, Rust). Anything else a project needs gets installed into that project's own directory (`./.jdk`, `./.bin`, `./.venv`) — resist adding it to the image.
- **Per-user everything.** Volume and container names are namespaced by `$USER` so multiple users on a shared rootful Docker daemon don't collide.

## Repository layout

```
claude-sandbox/Dockerfile      # Claude Code image
codex-sandbox/Dockerfile       # Codex CLI image
bin/claude-sandbox             # Claude launcher
bin/codex-sandbox              # Codex launcher
codex-sandbox/config.toml      # Codex autonomy config (seeded into its volume)
```

These instructions target Linux hosts. **Windows users:** see [WINDOWS.md](WINDOWS.md) — via WSL2 the main instructions apply nearly verbatim, and a native PowerShell route is documented as a fallback.

## Before you start: a bin directory on your PATH

The setups below install small launcher scripts (`claude-sandbox`, `codex-sandbox`) that you'll run by name from any project directory. For that to work, the scripts must live in a directory that's on your **PATH** — the list of directories your shell searches when you type a command. If they're not, you'll get `command not found` even though the file exists.

**Step 1 — check whether you already have one.** The conventional per-user script directory on modern Linux is `~/.local/bin` (some setups use `~/bin`). See if it's already on your PATH:

```bash
echo "$PATH" | tr ':' '\n' | grep "$HOME"
```

If the output includes `/home/<you>/.local/bin` (or `/home/<you>/bin`), you're set — use that directory in the install steps below and skip to the next section.

**Step 2 — if not, create one and add it to your PATH.** These instructions use `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

(If your shell is zsh, use `~/.zshrc` instead of `~/.bashrc`. The `source` command applies the change to your current terminal; new terminals pick it up automatically. Note for Debian/Ubuntu users: the default `~/.profile` already adds `~/.local/bin` to PATH *if the directory exists* — but only at login, so after `mkdir` you'd still need to log out and back in. The `~/.bashrc` line above works immediately and unconditionally.)

**Step 3 — verify:**

```bash
which claude-sandbox   # after installing a launcher below, this should print its path
```

Throughout this README, install commands write to `~/.local/bin`. If you prefer `~/bin` or another PATH directory, substitute it consistently.

---

## Claude Code

### How updates work

Claude Code has a built-in auto-updater. The image's npm install is only a first-run bootstrap: the updater installs new versions into `~/.local/share/claude`, which is backed by the `claude-local-$USER` volume, and `PATH` prefers the updater-managed binary. You essentially never rebuild the image except to change system packages.

### Image

`claude-sandbox/Dockerfile`:

```dockerfile
# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Philosophy: sandbox skeleton plus everyday toolchains (C, Python, Rust).
# Anything else a project needs gets installed into that project's own
# directory (./.jdk, ./.bin, etc.) — resist adding it here.
#
# Rebuild (rare):
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
#     -t claude-sandbox-$USER ./claude-sandbox
#
# Claude Code version is NOT managed here: the npm install is only a
# first-run bootstrap; the auto-updater keeps the real binary current
# in the per-user claude-local volume (mounted at /home/agent/.local).

FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain (read-only at runtime; update = rebuild image)
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rX ${RUSTUP_HOME} ${CARGO_HOME}

# Non-root user (required: claude rejects --dangerously-skip-permissions as
# root). UID/GID must match the host user so the bind-mounted /workspace is
# writable — pass them at build time; the image is therefore built per user.
ARG UID=1001
ARG GID=1001
RUN (getent group ${GID} >/dev/null || groupadd -g ${GID} agent) \
    && useradd -m -s /bin/bash -u ${UID} -g ${GID} agent
USER agent
WORKDIR /workspace

# Cargo runtime writes (registry cache, `cargo install`) go to writable
# (ephemeral) home; the toolchain itself stays read-only in the image.
ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @anthropic-ai/claude-code

# Pre-create dirs that back named volumes so they're agent-owned on first mount
RUN mkdir -p /home/agent/.claude /home/agent/.local/bin /home/agent/.local/share \
    /home/agent/.cargo

# Order matters: updater-managed claude (~/.local/bin) shadows the npm bootstrap
ENV PATH=/home/agent/.local/bin:/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
```

### Launcher

`bin/claude-sandbox` (place on your `PATH`, `chmod +x`):

```bash
#!/bin/bash
# claude-sandbox — run Claude Code sandboxed in the current directory.
# Shared rootful Docker: volumes are namespaced per host user to avoid
# collisions in the daemon's global volume namespace.

CONFIG_VOL="claude-config-$USER"
LOCAL_VOL="claude-local-$USER"
docker volume create "$CONFIG_VOL" >/dev/null
docker volume create "$LOCAL_VOL" >/dev/null

exec docker run -it --rm \
  --name "claude-$USER-$(basename "$PWD")-$(date +%s)" \
  -v "$PWD:/workspace" \
  -v "$CONFIG_VOL:/home/agent/.claude" \
  -v "$LOCAL_VOL:/home/agent/.local" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  claude-sandbox-$USER claude "$@"
```

Notes:

- `docker volume create` is idempotent — it does real work exactly once per user, then no-ops. Named volumes are **not** deleted by `--rm`; they persist until `docker volume rm`.
- The container name includes user, project, and timestamp so concurrent sessions (and concurrent users) don't collide.
- No resource limits are set. If runaway sessions on a shared box ever become a problem, add `--memory`, `--cpus`, and `--pids-limit` here.

### Setup (per user)

```bash
# 1. Build the image — per user, so the container UID matches yours and the
#    bind-mounted project is writable
docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  -t claude-sandbox-$USER ./claude-sandbox

# 2. Install the launcher
# (copies the script into your PATH directory and marks it executable;
#  -D creates ~/.local/bin if it doesn't exist yet — see "Before you start")
install -D -m 755 bin/claude-sandbox ~/.local/bin/claude-sandbox

# 3. First run: authenticate
cd ~/some-project
claude-sandbox
# Headless login: open the printed URL in a browser on another machine,
# sign in, paste the code back at the prompt. One-time — the token
# persists in the claude-config-$USER volume.

# 4. Accept the bypass-permissions dialog once, interactively
claude-sandbox --dangerously-skip-permissions
# (The acceptance persists in the config volume; after this, detached
# and scripted starts work cleanly.)
```

### Daily use

```bash
cd ~/some-project
claude-sandbox --dangerously-skip-permissions
```

Detached in tmux:

```bash
tmux new-session -d -s "claude-$(basename "$PWD")" -c "$PWD" \
  'claude-sandbox --dangerously-skip-permissions; read'
```

Attach with `tmux attach -t <name>`, detach with `Ctrl-b d`. Sessions survive SSH disconnects; attach from a phone SSH client to steer remotely.

**Remote Control:** Claude Code's Remote Control (steer sessions from the Claude app / claude.ai) currently cannot be combined with `--dangerously-skip-permissions` — the flags are mutually exclusive and the mobile UI re-prompts for approvals regardless (see [anthropics/claude-code#31908](https://github.com/anthropics/claude-code/issues/31908)). Pick per session: autonomous (flag, monitor via tmux) or remote-steerable (type `/remote-control` in a session, approve from the app).

### What persists where

| Path in container | Backing | Lifetime |
| --- | --- | --- |
| `/workspace` | bind mount of `$PWD` | your repo — permanent |
| `~/.claude` | `claude-config-$USER` volume | auth, settings, plugins, session history — permanent |
| `~/.local` | `claude-local-$USER` volume | auto-updated Claude binary — permanent |
| everything else (`~/.cargo`, `~/.npm-global`, …) | container layer | discarded at session exit |

Plugins installed via `/plugin install` live in the config volume, so they persist and are shared across all of that user's projects.

---

## Codex CLI

Same architecture, three differences:

1. **No auto-updater.** Codex must be updated via npm reinstall, so the version is baked at image build time and the launcher rebuilds the image when a new version ships (a cached no-op otherwise).
2. **Autonomy is config, not a flag.** Codex has two dials — approval policy and its own OS-level sandbox. Inside Docker, the container is the boundary and Codex's sandbox generally can't function anyway, so the standard container config is `approval_policy = "never"` + `sandbox_mode = "danger-full-access"`, persisted in `config.toml`. (Per-session equivalent: `codex --dangerously-bypass-approvals-and-sandbox`, alias `--yolo`.)
3. **Auth is device-code based.** `codex login --device-auth` prints a code you approve at chatgpt.com from any device — no localhost callback. Tokens land in `~/.codex` (volume-backed).

### Image

`codex-sandbox/Dockerfile`:

```dockerfile
# Codex CLI sandbox. Same philosophy as claude-sandbox.
# NOTE: Codex has no auto-updater — version is baked at build time.
# The launcher rebuilds when a new version ships.

FROM node:24-slim

ARG CODEX_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    build-essential pkg-config \
    python3 python3-pip python3-venv \
    jq ripgrep procps \
    && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rX ${RUSTUP_HOME} ${CARGO_HOME}

# UID/GID must match the host user (see Claude Dockerfile note)
ARG UID=1001
ARG GID=1001
RUN (getent group ${GID} >/dev/null || groupadd -g ${GID} agent) \
    && useradd -m -s /bin/bash -u ${UID} -g ${GID} agent
USER agent
WORKDIR /workspace

ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @openai/codex@${CODEX_VERSION}

RUN mkdir -p /home/agent/.codex /home/agent/.cargo

ENV PATH=/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
```

### Autonomy config

`codex-sandbox/config.toml` (seeded into the volume during setup):

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

### Launcher

`bin/codex-sandbox`:

```bash
#!/bin/bash
# codex-sandbox — run Codex CLI sandboxed in the current directory.
# Codex has no self-updater: check the npm registry for a newer version
# and rebuild the image if one exists (cached no-op otherwise).
# Uses curl+jq so no host-side Node/npm is required.

CONFIG_VOL="codex-config-$USER"
docker volume create "$CONFIG_VOL" >/dev/null

LATEST=$(curl -fsSL https://registry.npmjs.org/@openai/codex/latest 2>/dev/null | jq -r .version)
if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
  docker build -q --build-arg CODEX_VERSION="$LATEST" \
    --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
    -t codex-sandbox-$USER ./codex-sandbox >/dev/null 2>&1 \
    || docker build -q --build-arg CODEX_VERSION="$LATEST" \
       --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
       -t codex-sandbox-$USER ~/codex-sandbox >/dev/null
fi

exec docker run -it --rm \
  --name "codex-$USER-$(basename "$PWD")-$(date +%s)" \
  -v "$PWD:/workspace" \
  -v "$CONFIG_VOL:/home/agent/.codex" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  codex-sandbox-$USER codex "$@"
```

> Adjust the Dockerfile path in the build commands to wherever you keep this
> repo checked out (the example tries `./codex-sandbox` then `~/codex-sandbox`).
> If launch-time version checks annoy you, move the check-and-rebuild block
> into a nightly cron and let the launcher just `docker run`.

### Setup (per user)

```bash
# 1. Initial build — per user, matching your UID (deliberate first build,
#    so the first login doesn't hide a slow image compile)
docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  -t codex-sandbox-$USER ./codex-sandbox

# 2. Install the launcher
install -D -m 755 bin/codex-sandbox ~/.local/bin/codex-sandbox

# 3. Authenticate (one-time; device code, approve at chatgpt.com)
cd ~/some-project
codex-sandbox login --device-auth

# 4. Seed the autonomy config into the volume
docker run --rm -v "codex-config-$USER:/cfg" \
  -v "$PWD/codex-sandbox/config.toml:/src/config.toml:ro" \
  node:24-slim cp /src/config.toml /cfg/config.toml
```

### Daily use

```bash
cd ~/some-project
codex-sandbox            # full autonomy via config.toml; no flag needed
```

tmux wrapping is identical to the Claude section. There is no Remote Control
equivalent for Codex — remote steering is SSH + tmux.

---

## Per-project toolchains

The images deliberately omit occasional-use toolchains (Java, Go, etc.). Projects self-provision into their own directories — no root needed, persists with the repo via the bind mount. Document the conventions in `CLAUDE.md` (Claude) / `AGENTS.md` (Codex) so autonomous sessions follow them instead of attempting `apt-get`:

```markdown
## Toolchain conventions
- Python: use a venv (`python3 -m venv .venv`); bare pip installs hit PEP 668.
- Java: no system JVM. Install Temurin into ./.jdk:
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" | tar -xz -C .jdk --strip-components=1
  then export JAVA_HOME="$PWD/.jdk", PATH="$JAVA_HOME/bin:$PATH". Reuse existing ./.jdk.
- Other tools: static binaries go in ./.bin.
- Gitignore all of: .venv/ .jdk/ .bin/
- No root/sudo available; never attempt apt-get install.
```

## Multiple sessions and multiple users

- **Concurrent sessions (one user):** fully supported. Containers are independent; the shared volumes tolerate concurrency (this is the same as running the agent in several terminal tabs). The only real hazard is two sessions editing the *same checkout* — use `git worktree` for parallel work on one repo.
- **Multiple users (shared rootful Docker):** the `$USER`-namespaced volumes prevent *accidental* cross-user interference. They do **not** prevent deliberate access: anyone in the `docker` group can mount anyone's volume, because docker-group membership on a rootful daemon is root-equivalent. Treat this configuration as *collision-proof, not confidential*. If users on the box aren't mutually trusted with each other's agent credentials, use [rootless Docker](https://docs.docker.com/engine/security/rootless/) per user instead — every user gets an isolated daemon and truly private volumes, and everything in this repo works identically (drop the `$USER` suffixes if you like).
- **Why images are per-user too:** the container's `agent` user must have *your* UID, or the bind-mounted `/workspace` (owned by you on the host) isn't writable from inside — the agent will report something like "couldn't save, /workspace is owned by UID 1003 but this session runs as UID 1001." That's why every build command passes `--build-arg UID=$(id -u) --build-arg GID=$(id -g)` and tags the image `*-$USER`. Docker layer caching keeps this cheap: users with identical Dockerfiles share all layers up to the `useradd`.
- **Troubleshooting UID mismatches on existing volumes:** if you built an image before setting the UID args (or your UID changed), your volumes may contain files owned by the old UID and the agent can't write its own config. Fix in place without losing auth by chowning via a throwaway root container:
  ```bash
  docker run --rm -v "claude-config-$USER:/v" alpine chown -R "$(id -u):$(id -g)" /v
  docker run --rm -v "claude-local-$USER:/v"  alpine chown -R "$(id -u):$(id -g)" /v
  docker run --rm -v "codex-config-$USER:/v"  alpine chown -R "$(id -u):$(id -g)" /v
  ```

## Security notes

- **The container is the entire boundary.** In bypass/yolo mode, a prompt-injected or misbehaving session can do anything *inside* it: modify the mounted project, read the agent credentials in its volume, and reach the open network. Only run against repositories you trust.
- **Never mount host secrets** (`~/.ssh`, cloud credential files, `~/.gitconfig` with tokens) into the container. Prefer repo-scoped or short-lived tokens passed per session (`-e GH_TOKEN=...`) when needed.
- **Egress is unrestricted by default** in these launchers. For defense against exfiltration, adapt the default-deny firewall from Anthropic's [reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) (`init-firewall.sh` + `NET_ADMIN`/`NET_RAW` caps) — and be prepared to maintain a domain allowlist for package registries your projects use.
- **No Docker socket, no privileged flags.** The images contain no Docker client; if you ever add one, mounting the host Docker socket into an autonomous agent's container is a sandbox escape (root-equivalent on rootful daemons). Keep it out, or make it a conscious opt-in.
- **Non-root inside the container** (`agent` user) is required by Claude Code's bypass flag and is good hygiene for both agents regardless.

## References

- Claude Code dev container docs: https://code.claude.com/docs/en/devcontainer
- Anthropic reference devcontainer (firewall, hardened example): https://github.com/anthropics/claude-code/tree/main/.devcontainer
- Claude Code permission modes: https://code.claude.com/docs/en/permission-modes
- Codex CLI: https://github.com/openai/codex
- Remote Control + bypass incompatibility: https://github.com/anthropics/claude-code/issues/31908
