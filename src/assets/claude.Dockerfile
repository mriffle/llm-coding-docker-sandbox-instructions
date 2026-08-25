# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Philosophy: sandbox skeleton plus everyday toolchains (C, Python, Rust).
# Anything else a project needs gets installed into that project's own
# directory (./.jdk, ./.bin, etc.) — resist adding it here.
#
# Managed by the agent-sandbox installer (v@@VERSION@@). Re-running the
# installer rewrites this file; local edits are backed up first, but the
# supported way to customise is to keep your own copy elsewhere and build
# with --src-dir.
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
# Downloaded to a file rather than piped into sh: a failed `curl | sh` exits 0
# because sh simply reads empty input, so a transient network blip silently
# installs nothing and only surfaces two commands later as a confusing
# "chmod: cannot access /usr/local/rustup". With && the download failure is fatal.
RUN curl -fsSL --retry 3 --retry-connrefused https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
    && rm -f /tmp/rustup-init.sh \
    && chmod -R a+rX ${RUSTUP_HOME} ${CARGO_HOME}

# Non-root user (required: claude rejects --dangerously-skip-permissions as
# root). UID/GID must match the host user so the bind-mounted /workspace is
# writable — pass them at build time; the image is therefore built per user.
#
# node:24-slim already ships a `node` user at UID/GID 1000, which is the first
# non-root UID on most Linux hosts. Take that identity over instead of failing
# the build with "UID 1000 is not unique".
ARG UID=1001
ARG GID=1001
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
        old_group="$(getent group "${GID}" | cut -d: -f1)"; \
        [ "$old_group" = agent ] || groupmod -n agent "$old_group"; \
    else \
        groupadd -g "${GID}" agent; \
    fi; \
    if getent passwd "${UID}" >/dev/null; then \
        old_user="$(getent passwd "${UID}" | cut -d: -f1)"; \
        [ "$old_user" = agent ] || usermod -l agent "$old_user"; \
        usermod -g "${GID}" -s /bin/bash agent; \
        old_home="$(getent passwd agent | cut -d: -f6)"; \
        [ "$old_home" = /home/agent ] || usermod -d /home/agent -m agent; \
    else \
        useradd -m -s /bin/bash -u "${UID}" -g "${GID}" agent; \
    fi
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
