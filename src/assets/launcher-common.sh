# --- shared launcher machinery (generated; see @@REPO_URL@@) ----------------
SANDBOX_VERSION="@@VERSION@@"
RAW_BASE="@@RAW_BASE@@"
REPO_URL="@@REPO_URL@@"

have() { command -v "$1" >/dev/null 2>&1; }
ldie() { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
lwarn() { printf 'sandbox: %s\n' "$*" >&2; }

sandbox_user() {
    if [ -n "${SANDBOX_FAKE_USER:-}" ]; then printf '%s' "$SANDBOX_FAKE_USER"
    elif [ -n "${USER:-}" ]; then printf '%s' "$USER"
    else id -un
    fi
}

version_gt() {
    local a=${1#v} b=${2#v} i a_i b_i
    [ -n "$a" ] || return 1
    [ -n "$b" ] || return 0
    i=1
    while [ "$i" -le 4 ]; do
        a_i=$(printf '%s' "$a" | cut -d. -f"$i"); b_i=$(printf '%s' "$b" | cut -d. -f"$i")
        case "$a_i" in ''|*[!0-9]*) a_i=0 ;; esac
        case "$b_i" in ''|*[!0-9]*) b_i=0 ;; esac
        [ "$a_i" -gt "$b_i" ] && return 0
        [ "$a_i" -lt "$b_i" ] && return 1
        i=$((i + 1))
    done
    return 1
}

cache_dir() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/agent-sandbox"; }
state_dir() { printf '%s' "${SANDBOX_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox}"; }

# Absolute path to this launcher, so tmux can re-invoke it from any cwd.
launcher_self() {
    case "$0" in
        /*) printf '%s' "$0" ;;
        */*) printf '%s' "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;;
        *) command -v "$0" 2>/dev/null || printf '%s' "$0" ;;
    esac
}

# At most one network call per day, 2s ceiling, silent when offline, and the
# timestamp is written *before* the request so a flaky network cannot turn
# every launch into a stalled one.
update_check() {
    [ -z "${SANDBOX_NO_UPDATE_CHECK:-}" ] || return 0
    have curl || return 0
    local cache latest
    cache="$(cache_dir)/$AGENT.lastcheck"
    mkdir -p "$(cache_dir)" 2>/dev/null || return 0
    if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin -1440 2>/dev/null)" ]; then
        return 0
    fi
    : > "$cache" 2>/dev/null || true
    latest=$(curl -fsSL --max-time 2 "$RAW_BASE/VERSION" 2>/dev/null | head -1 | tr -d ' \r\n')
    [ -n "$latest" ] || return 0
    if version_gt "$latest" "$SANDBOX_VERSION"; then
        lwarn "v$latest of the sandbox is available (you have v$SANDBOX_VERSION)"
        lwarn "upgrade with: $LAUNCHER_NAME --sandbox-upgrade   (or SANDBOX_NO_UPDATE_CHECK=1 to silence)"
    fi
}

ensure_docker_and_image() {
    have docker || ldie "docker is not installed or not on PATH — see $REPO_URL"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then return 0; fi
    if ! docker info >/dev/null 2>&1; then
        ldie "cannot reach the docker daemon (is it running, and are you in the docker group?)"
    fi
    printf 'sandbox: image %s does not exist.\n' "$IMAGE" >&2
    printf 'sandbox: install it with:\n  curl -fsSL %s/install/%s.sh | bash\n' "$RAW_BASE" "$AGENT" >&2
    exit 1
}

# Docker demands [a-zA-Z0-9][a-zA-Z0-9_.-]* — project directories do not.
# Note the printf: piping `basename` into tr would turn its trailing newline
# into another separator and leave every name with a stray dash.
project_slug() {
    local base=${PWD##*/}
    [ -n "$base" ] || base=root
    printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-'
}

container_name() {
    printf '%s-%s-%s-%s' "$AGENT" "$(sandbox_user)" "$(project_slug)" "$(date +%s)"
}

short_hash() {
    if have sha256sum; then printf '%s' "$1" | sha256sum | cut -c1-6
    elif have shasum; then printf '%s' "$1" | shasum -a 256 | cut -c1-6
    else printf '%s' "$1" | cksum | cut -d' ' -f1 | cut -c1-6
    fi
}

# --- where the project lives inside the container --------------------------
# Both agents key their per-project state on the *working directory string*:
# Claude Code stores session transcripts and memory under
# ~/.claude/projects/<cwd-slugified>/, records per-project approvals and trust
# under that path in .claude.json, and Codex writes the cwd into every rollout
# for `codex resume`. Mount every project at a fixed /workspace and all of them
# are one project to the agent — one shared memory store, one mixed resume
# list, approvals leaking between repositories. Mirroring the host path keeps
# each project distinct, and has the side benefit that paths the agent prints
# are paths that resolve on the host.

# Physical, not bash's logical $PWD. Reaching one project through a symlink
# must not look like a second project, or it acquires a second memory store.
host_workdir() {
    if [ -n "${SANDBOX_FAKE_PWD:-}" ]; then printf '%s' "$SANDBOX_FAKE_PWD"; return; fi
    pwd -P 2>/dev/null || printf '%s' "$PWD"
}

# The host path, unless mirroring it would land the mount *on* the container's
# own filesystem instead of in a fresh directory. Mounting under a system
# directory (/opt/proj, /tmp/proj, macOS's /var/folders/x/proj) is fine —
# docker just creates it — so only these exact paths fall back:
#   /, /home and the bare top-level directories, which the image needs, and
#   /home/agent, which is the agent's own home: a host user actually named
#   `agent` would otherwise expose their entire home directory to a session
#   that is supposed to see nothing but the project.
# The fallback warns. A silent one would rebuild the collision invisibly.
container_workdir() {
    local p
    if [ -n "${SANDBOX_WORKDIR:-}" ]; then printf '%s' "$SANDBOX_WORKDIR"; return; fi
    p=$(host_workdir)
    case "$p" in
        /home/agent|/home/agent/*) p='' ;;
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt) p='' ;;
        /proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) p='' ;;
        /*) ;;
        *) p='' ;;
    esac
    if [ -z "$p" ]; then
        lwarn "cannot mirror $(host_workdir) inside the container; using /workspace"
        lwarn "(the agent's memory and session history there are shared with other such projects)"
        p=/workspace
    fi
    printf '%s' "$p"
}

# --- git -------------------------------------------------------------------
# Identity always, a credential only on request. Both travel as environment;
# no new host path is ever mounted.
#
# GIT_CONFIG_COUNT/KEY/VALUE is real git config, so `git config --get
# user.email` reads back correctly inside the container. GIT_AUTHOR_* would set
# the commit but leave the config empty, and hooks read the config.
#
# Every probe here is best-effort. No git on the host, no identity configured,
# a directory that is not a repository — each must leave the launch untouched.
GIT_ENV_ARGS=()
GIT_ENV_COUNT=0

# Single quotes are deliberate: these variables expand in the container's shell,
# from the environment passed alongside — not here, and not at build time.
# shellcheck disable=SC2016  # the $VARs belong to the container, not this shell
GIT_CRED_HELPER='!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'

git_env_add() {
    GIT_ENV_ARGS+=(-e "GIT_CONFIG_KEY_$GIT_ENV_COUNT=$1" \
                   -e "GIT_CONFIG_VALUE_$GIT_ENV_COUNT=$2")
    GIT_ENV_COUNT=$((GIT_ENV_COUNT + 1))
}

# `git config --get` exits 1 for an unset key. That is the normal case, not a
# failure worth reporting.
git_config_get() { git config --get "$1" 2>/dev/null || printf ''; }

# The origin's host, and only for https — an ssh or scp-style remote never
# consults a credential helper, so there is nothing useful to forward.
git_origin_host() {
    local url
    url=$(git config --get remote.origin.url 2>/dev/null) || return 1
    case "$url" in
        https://*|http://*) ;;
        *) return 1 ;;
    esac
    url=${url#*://}
    url=${url%%/*}
    printf '%s' "${url#*@}"
}

GIT_CRED_USER=''
GIT_CRED_TOKEN=''
# Set when the credential is known to belong to a GitHub instance: github.com
# itself, or a host the *host's* gh is logged in to. A token pulled from the
# credential store for anything else might be GitHub Enterprise and might be
# GitLab — the hostname does not say which — so gh is left unconfigured rather
# than pointed at a server that does not speak its API.
GIT_CRED_IS_GITHUB=''
git_resolve_cred() {
    local host=$1 line out
    GIT_CRED_USER=''; GIT_CRED_TOKEN=''; GIT_CRED_IS_GITHUB=''
    [ "$host" != github.com ] || GIT_CRED_IS_GITHUB=1

    if [ "$host" = github.com ] && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        GIT_CRED_USER=x-access-token
        GIT_CRED_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
        return 0
    fi

    if have gh; then
        out=$(gh auth token --hostname "$host" 2>/dev/null | head -1 | tr -d ' \r\n')
        if [ -n "$out" ]; then
            GIT_CRED_USER=x-access-token
            GIT_CRED_TOKEN=$out
            GIT_CRED_IS_GITHUB=1
            return 0
        fi
    fi

    # The host's own credential store answers here — keychain, GCM, libsecret or
    # a plain file — so the container never learns which backend is in use.
    # GIT_TERMINAL_PROMPT=0 is load-bearing: without it git prompts on /dev/tty
    # and the launch hangs instead of quietly declining.
    out=$(printf 'protocol=https\nhost=%s\n\n' "$host" \
        | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            username=*) GIT_CRED_USER=${line#*=} ;;
            password=*) GIT_CRED_TOKEN=${line#*=} ;;
        esac
    done <<EOF
$out
EOF
    [ -n "$GIT_CRED_TOKEN" ]
}

# The same credential again, in the form the GitHub CLI reads. gh never
# consults a git credential helper — the integration runs the other way, with
# `gh auth setup-git` teaching git to call gh — so without this the container
# would hold a working `git push` beside a gh that claims it is not logged in.
#
# This grants nothing new: SANDBOX_GIT_TOKEN is already in the same
# environment, readable by anything the agent runs. It only spares the agent
# from hand-rolling curl against api.github.com.
#
# GH_HOST is what makes an Enterprise remote work at all: gh talks to
# github.com regardless of the token's origin unless told otherwise.
gh_env_add() {
    local host=$1
    [ -n "$GIT_CRED_IS_GITHUB" ] || return 0
    if [ "$host" = github.com ]; then
        GIT_ENV_ARGS+=(-e "GH_TOKEN=$GIT_CRED_TOKEN")
    else
        GIT_ENV_ARGS+=(-e "GH_HOST=$host" \
                       -e "GH_ENTERPRISE_TOKEN=$GIT_CRED_TOKEN")
    fi
}

git_env_args() {
    local name email host
    GIT_ENV_ARGS=()
    GIT_ENV_COUNT=0
    [ -z "${SANDBOX_NO_GIT:-}" ] || return 0
    have git || return 0

    name=$(git_config_get user.name)
    email=$(git_config_get user.email)
    [ -z "$name" ]  || git_env_add user.name "$name"
    [ -z "$email" ] || git_env_add user.email "$email"

    if [ -n "${SANDBOX_GIT:-}" ]; then
        host=$(git_origin_host) || host=''
        if [ -z "$host" ]; then
            lwarn "--sandbox-git: no https remote here; nothing to forward"
        elif git_resolve_cred "$host"; then
            GIT_ENV_ARGS+=(-e "SANDBOX_GIT_USER=$GIT_CRED_USER" \
                           -e "SANDBOX_GIT_TOKEN=$GIT_CRED_TOKEN")
            git_env_add "credential.https://$host.helper" "$GIT_CRED_HELPER"
            gh_env_add "$host"
        else
            lwarn "--sandbox-git: no credential stored for $host; pushing will fail"
        fi
    fi

    [ "$GIT_ENV_COUNT" -eq 0 ] || GIT_ENV_ARGS+=(-e "GIT_CONFIG_COUNT=$GIT_ENV_COUNT")
}

run_container() {
    local src dst
    src=$(host_workdir)
    dst=$(container_workdir)
    git_env_args
    # The ${a[@]+"${a[@]}"} form, not a bare "${a[@]}": expanding an *empty*
    # array under `set -u` is fatal on bash 3.2, which is still macOS /bin/bash.
    exec docker run -it --rm \
        --name "$(container_name)" \
        -v "$src:$dst" \
        -w "$dst" \
        "${MOUNT_ARGS[@]}" \
        ${GIT_ENV_ARGS[@]+"${GIT_ENV_ARGS[@]}"} \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$IMAGE" "$AGENT_BIN" "$@"
}

# Overridden by codex-sandbox, which has no self-updater to lean on.
# shellcheck disable=SC2317
pre_run_hook() { :; }

# --- tmux ------------------------------------------------------------------
# A session per project directory. Two directories with the same basename get
# distinct sessions (the second is suffixed with a hash of its path) rather
# than one silently hijacking the other's session.
tmux_session_for_pwd() {
    local base session stored
    base="$AGENT-$(project_slug)"
    if ! tmux has-session -t "=$base" 2>/dev/null; then
        printf '%s' "$base"; return 0
    fi
    stored=$(tmux show-environment -t "=$base" SANDBOX_PWD 2>/dev/null | cut -d= -f2-)
    if [ "$stored" = "$PWD" ]; then printf '%s' "$base"; return 0; fi
    session="$base-$(short_hash "$PWD")"
    printf '%s' "$session"
}

tmux_launch() {
    local mode=$1; shift
    have tmux || ldie "tmux is not installed (try: sudo apt-get install tmux, or brew install tmux)"

    if [ -n "${TMUX:-}" ]; then
        lwarn "already inside tmux — running directly instead of nesting a session"
        ensure_docker_and_image
        update_check
        pre_run_hook
        run_container "$@"
        return $?
    fi

    local session self cmd
    session=$(tmux_session_for_pwd)

    if tmux has-session -t "=$session" 2>/dev/null; then
        if [ "$mode" = "detach" ]; then
            printf 'sandbox: session %s is already running; attach with: tmux attach -t %s\n' "$session" "$session" >&2
            return 0
        fi
        printf 'sandbox: attaching to the existing session %s\n' "$session" >&2
        exec tmux attach-session -t "=$session"
    fi

    ensure_docker_and_image
    self=$(launcher_self)
    # %q keeps arguments with spaces intact through tmux's shell.
    cmd=$(printf '%q ' "$self" "$@")
    # --sandbox-git was consumed before the dispatch, so it is no longer in "$@";
    # carry the decision into the session as environment instead.
    cmd="SANDBOX_IN_TMUX=1 ${SANDBOX_GIT:+SANDBOX_GIT=1 }$cmd; ec=\$?; if [ \$ec -ne 0 ]; then printf 'exited with status %s — press Enter to close\\n' \"\$ec\"; read -r _; fi"

    tmux new-session -d -s "$session" -c "$PWD" "$cmd" \
        || ldie "could not create the tmux session $session"
    tmux set-environment -t "=$session" SANDBOX_PWD "$PWD" 2>/dev/null || true

    if [ "$mode" = "detach" ]; then
        printf 'sandbox: started %s in the background; attach with: tmux attach -t %s\n' "$session" "$session" >&2
        return 0
    fi
    exec tmux attach-session -t "=$session"
}

# --- doctor ----------------------------------------------------------------
doctor() {
    local manifest vol owner latest label_uid name email host
    printf '%s sandbox — doctor\n' "$AGENT_NAME"
    printf '  launcher version    %s (%s)\n' "$SANDBOX_VERSION" "$(launcher_self)"
    printf '  user / uid          %s / %s\n' "$(sandbox_user)" "$(id -u)"
    printf '  project mount       %s -> %s\n' "$(host_workdir)" "$(container_workdir)"

    if ! have docker; then printf '  docker              NOT INSTALLED\n'; return 1; fi
    if ! docker info >/dev/null 2>&1; then printf '  docker              UNREACHABLE\n'; return 1; fi
    printf '  docker              ok (%s)\n' "$(docker version -f '{{.Server.Version}}' 2>/dev/null || printf 'unknown')"

    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        label_uid=$(docker image inspect -f '{{index .Config.Labels "sandbox.agent_uid"}}' "$IMAGE" 2>/dev/null)
        printf '  image               %s\n' "$IMAGE"
        printf '  image built by      installer v%s\n' \
            "$(docker image inspect -f '{{index .Config.Labels "sandbox.installer_version"}}' "$IMAGE" 2>/dev/null)"
        if [ -n "$label_uid" ] && [ "$label_uid" != "$(id -u)" ]; then
            printf '  image agent UID     %s  MISMATCH (you are %s) — re-run the installer\n' "$label_uid" "$(id -u)"
        else
            printf '  image agent UID     %s\n' "${label_uid:-unknown}"
        fi
    else
        printf '  image               MISSING (%s)\n' "$IMAGE"
    fi

    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            owner=$(docker run --rm --user 0:0 -v "$vol:/v" "$IMAGE" \
                sh -c 'stat -c %u /v 2>/dev/null || stat -f %u /v 2>/dev/null' 2>/dev/null | tr -d '\r\n ')
            if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
                printf '  volume %-12s owned by UID %s, expected %s — re-run the installer\n' "$vol" "$owner" "$(id -u)"
            else
                printf '  volume %-12s ok\n' "$vol"
            fi
        else
            printf '  volume %-12s MISSING\n' "$vol"
        fi
    done

    # State recorded before the mount mirrored the host path is pooled under one
    # directory named for the old fixed mount. Nothing can attribute any of it
    # back to a project, so it is reported, never migrated.
    if [ "$AGENT" = claude ] \
        && docker image inspect "$IMAGE" >/dev/null 2>&1 \
        && docker volume inspect "$CONFIG_VOL" >/dev/null 2>&1 \
        && docker run --rm --user 0:0 -v "$CONFIG_VOL:/v" "$IMAGE" \
            sh -c 'test -d /v/projects/-workspace' >/dev/null 2>&1; then
        printf '  legacy state        projects/-workspace holds sessions and memory recorded\n'
        printf '                      before the mount mirrored the host path, pooled across\n'
        printf '                      every project. Nothing is lost; list it with:\n'
        printf '                        docker run --rm -v %s:/v %s ls /v/projects\n' "$CONFIG_VOL" "$IMAGE"
    fi

    manifest="$(state_dir)/$AGENT.manifest"
    if [ -r "$manifest" ]; then
        printf '  manifest            %s\n' "$manifest"
    else
        printf '  manifest            missing (installed by hand?)\n'
    fi

    # Availability only — the credential itself is never printed.
    if ! have git; then
        printf '  git                 NOT INSTALLED on this host\n'
    else
        name=$(git_config_get user.name)
        email=$(git_config_get user.email)
        if [ -n "$name" ] || [ -n "$email" ]; then
            printf '  git identity        %s <%s>\n' "${name:-?}" "${email:-?}"
        else
            printf '  git identity        NONE configured — commits will fail\n'
        fi
        host=$(git_origin_host) || host=''
        if [ -z "$host" ]; then
            printf '  git credential      no https remote here\n'
        elif git_resolve_cred "$host"; then
            printf '  git credential      available for %s — forward with --sandbox-git\n' "$host"
            [ -z "$GIT_CRED_IS_GITHUB" ] \
                || printf '  gh cli              the same flag authenticates it for %s\n' "$host"
        else
            printf '  git credential      none stored for %s\n' "$host"
        fi
    fi

    if have curl; then
        latest=$(curl -fsSL --max-time 3 "$RAW_BASE/VERSION" 2>/dev/null | head -1 | tr -d ' \r\n')
        if [ -n "$latest" ] && version_gt "$latest" "$SANDBOX_VERSION"; then
            printf '  upstream            v%s available — %s --sandbox-upgrade\n' "$latest" "$LAUNCHER_NAME"
        elif [ -n "$latest" ]; then
            printf '  upstream            up to date\n'
        fi
    fi
}

do_upgrade() {
    have curl || ldie "curl is required to upgrade"
    printf 'sandbox: fetching the latest installer from %s\n' "$RAW_BASE" >&2
    curl -fsSL "$RAW_BASE/install/$AGENT.sh" | bash -s -- "$@"
}

launcher_usage() {
    cat >&2 <<USAGE
$LAUNCHER_NAME — run $AGENT_NAME sandboxed in the current directory (v$SANDBOX_VERSION)

  $LAUNCHER_NAME [agent arguments...]

Everything is passed through to $AGENT_BIN untouched, except these flags,
which are only recognised in first position:

  --sandbox-git [args...]            also forward a git credential (see below)
  --sandbox-tmux [args...]           run inside a tmux session for this project
  --sandbox-tmux-detached [args...]  same, but do not attach
  --sandbox-doctor                   report on image, volumes, UIDs and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

Your git name and email are always passed through, so the agent can commit.
--sandbox-git additionally forwards a credential for the origin remote's host,
so it can push. On a GitHub remote the same token also authenticates the gh
CLI that ships in the image, so the agent can work issues and pull requests.
The credential is scoped to that one host, but within it the token's own
permissions apply — prefer a fine-grained one.

The project is mounted inside the container at the same path it has on the
host, so each project keeps its own agent memory, session history and
approvals. SANDBOX_WORKDIR overrides that if you need the old fixed path.

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
  SANDBOX_NO_GIT=1            pass no git identity or credential at all
  SANDBOX_GIT=1               same as --sandbox-git
  SANDBOX_WORKDIR=/workspace  mount the project at this fixed path instead
                              (its agent state is then shared with every
                              other project run the same way)
USAGE
}

launcher_main() {
    IMAGE="$IMAGE_BASENAME-$(sandbox_user)"
    # Consumed before the dispatch below, so it composes: --sandbox-git
    # --sandbox-tmux works, and the flag still only counts in first position.
    case "${1:-}" in
        --sandbox-git) SANDBOX_GIT=1; shift ;;
    esac
    case "${1:-}" in
        --sandbox-help)           launcher_usage; exit 0 ;;
        --sandbox-version)        printf '%s\n' "$SANDBOX_VERSION"; exit 0 ;;
        --sandbox-doctor)         doctor; exit $? ;;
        --sandbox-upgrade)        shift; do_upgrade "$@"; exit $? ;;
        --sandbox-tmux)           shift; tmux_launch attach "$@"; exit $? ;;
        --sandbox-tmux-detached)  shift; tmux_launch detach "$@"; exit $? ;;
    esac
    ensure_docker_and_image
    update_check
    pre_run_hook
    run_container "$@"
}
