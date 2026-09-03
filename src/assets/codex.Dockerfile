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

# Docker CLI for --sandbox-docker; see the Claude Dockerfile note. Inert until
# that flag mounts the socket.
COPY --from=docker:29-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
# Downloaded to a file rather than piped into sh: a failed `curl | sh` exits 0
# because sh simply reads empty input, so a transient network blip silently
# installs nothing and only surfaces two commands later as a confusing
# "chmod: cannot access /usr/local/rustup". With && the download failure is fatal.
RUN curl -fsSL --retry 3 --retry-connrefused https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
    && rm -f /tmp/rustup-init.sh \
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
# Only the default, for a container run by hand. The launchers override it with
# `docker run -w`, mounting the project at the same path it has on the host so
# that each project keeps its own agent memory and session history.
WORKDIR /workspace

ENV CARGO_HOME=/home/agent/.cargo

RUN npm config set prefix /home/agent/.npm-global \
    && npm install -g @openai/codex@${CODEX_VERSION}

RUN mkdir -p /home/agent/.codex /home/agent/.cargo

ENV PATH=/home/agent/.npm-global/bin:/home/agent/.cargo/bin:/usr/local/cargo/bin:$PATH
