# Codex CLI sandbox. Same philosophy as claude-sandbox.
# NOTE: Codex has no auto-updater — version is baked at build time.
# The launcher rebuilds when a new version ships.
#
# Managed by the agent-sandbox installer (v@@VERSION@@). Re-running the
# installer rewrites this file; local edits are backed up first.

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

# UID/GID must match the host user (see the Claude Dockerfile note, including
# why an already-taken UID is renamed rather than treated as an error)
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

ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @openai/codex@${CODEX_VERSION}

RUN mkdir -p /home/agent/.codex /home/agent/.cargo

ENV PATH=/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
