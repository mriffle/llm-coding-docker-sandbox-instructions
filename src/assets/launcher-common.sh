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

run_container() {
    exec docker run -it --rm \
        --name "$(container_name)" \
        -v "$PWD:/workspace" \
        "${MOUNT_ARGS[@]}" \
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
    cmd="SANDBOX_IN_TMUX=1 $cmd; ec=\$?; if [ \$ec -ne 0 ]; then printf 'exited with status %s — press Enter to close\\n' \"\$ec\"; read -r _; fi"

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
    local manifest vol owner latest label_uid
    printf '%s sandbox — doctor\n' "$AGENT_NAME"
    printf '  launcher version    %s (%s)\n' "$SANDBOX_VERSION" "$(launcher_self)"
    printf '  user / uid          %s / %s\n' "$(sandbox_user)" "$(id -u)"

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

    manifest="$(state_dir)/$AGENT.manifest"
    if [ -r "$manifest" ]; then
        printf '  manifest            %s\n' "$manifest"
    else
        printf '  manifest            missing (installed by hand?)\n'
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

  --sandbox-tmux [args...]           run inside a tmux session for this project
  --sandbox-tmux-detached [args...]  same, but do not attach
  --sandbox-doctor                   report on image, volumes, UIDs and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
USAGE
}

launcher_main() {
    IMAGE="$IMAGE_BASENAME-$(sandbox_user)"
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
