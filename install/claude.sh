#!/usr/bin/env bash
#
#  THIS FILE IS GENERATED — do not edit it directly.
#  Source: src/, assembled by tools/build.sh. Edit there and rebuild.
#  Version 1.0.0
#
#
# Claude Code sandbox installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mriffle/llm-coding-docker-sandbox-instructions/main/install/claude.sh | bash
#
# Creates ~/claude-sandbox/Dockerfile, ~/.local/bin/claude-sandbox, a per-user
# image, and the named volumes that hold your login. Re-run it to upgrade.
set -euo pipefail

INSTALLER_VERSION="1.0.0"
RAW_BASE="https://raw.githubusercontent.com/mriffle/llm-coding-docker-sandbox-instructions/main"
REPO_URL="https://github.com/mriffle/llm-coding-docker-sandbox-instructions"

AGENT=claude
AGENT_NAME="Claude Code"
LAUNCHER_NAME=claude-sandbox
IMAGE_BASENAME=claude-sandbox
SRC_DIR_DEFAULT="$HOME/claude-sandbox"
VOLUME_BASENAMES="claude-config claude-local"

# ---------------------------------------------------------------------------
# common.sh — shared helpers for the sandbox installers.
#
# Targets bash 3.2 (macOS still ships it): no associative arrays, no ${v,,},
# no mapfile, no `local -n`. Every external tool with GNU/BSD divergence
# (sha256sum, stat, sed -i, readlink -f) is feature-detected, never assumed.
#
# Test seams: SANDBOX_OS_RELEASE, SANDBOX_PROC_VERSION, SANDBOX_FAKE_UNAME_S,
# SANDBOX_FAKE_UID, SANDBOX_FAKE_GID let the suite drive platform detection
# without pretending to be another machine.
# ---------------------------------------------------------------------------

# ---- output ---------------------------------------------------------------

C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_BOLD=''
setup_colors() {
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
        C_BOLD=$'\033[1m'
    fi
}

# All diagnostics go to stderr so `... | bash` keeps stdout clean for piping.
say()  { [ -n "${QUIET:-}" ] || printf '%s\n' "$*" >&2; }
step() { [ -n "${QUIET:-}" ] || printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
ok()   { [ -n "${QUIET:-}" ] || printf '  %s%s%s\n' "$C_GREEN" "$*" "$C_RESET" >&2; }
info() { [ -n "${QUIET:-}" ] || printf '  %s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
oops() { printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
blank() { [ -n "${QUIET:-}" ] || printf '\n' >&2; }

die() { oops "$*"; exit 1; }

# Numbered remediation list. Callers pass one instruction per argument; a
# lone "" emits a blank separator line.
remedy() {
    local n=0 line
    blank
    printf '%sHow to fix:%s\n' "$C_BOLD" "$C_RESET" >&2
    for line in "$@"; do
        if [ -z "$line" ]; then
            printf '\n' >&2
        else
            n=$((n + 1))
            printf '  %s%d.%s %s\n' "$C_BOLD" "$n" "$C_RESET" "$line" >&2
        fi
    done
    blank
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---- identity -------------------------------------------------------------

host_uid() { printf '%s' "${SANDBOX_FAKE_UID:-$(id -u)}"; }
# Deliberately separate from host_uid: the root check must look at who is
# really running the script, not at the UID we are building an image for.
effective_uid() { printf '%s' "${SANDBOX_FAKE_EUID:-$(id -u)}"; }
host_gid() { printf '%s' "${SANDBOX_FAKE_GID:-$(id -g)}"; }

# $USER is not guaranteed to be exported (cron, some CI shells, `su -c`).
sandbox_user() {
    if [ -n "${SANDBOX_FAKE_USER:-}" ]; then printf '%s' "$SANDBOX_FAKE_USER"
    elif [ -n "${USER:-}" ]; then printf '%s' "$USER"
    else id -un
    fi
}

# ---- hashing --------------------------------------------------------------

sha256_file() {
    [ -f "$1" ] || { printf 'missing'; return 0; }
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif have shasum;    then shasum -a 256 "$1" | cut -d' ' -f1
    elif have openssl;   then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else printf 'nohash'
    fi
}

sha256_stdin() {
    if have sha256sum; then sha256sum | cut -d' ' -f1
    elif have shasum;    then shasum -a 256 | cut -d' ' -f1
    elif have openssl;   then openssl dgst -sha256 | awk '{print $NF}'
    else cat >/dev/null; printf 'nohash'
    fi
}

sha256_string() { printf '%s' "$1" | sha256_stdin; }

# The hash an embedded asset will have *once written*: `$(cat <<EOF)` strips
# trailing newlines and atomic_write puts exactly one back, so comparing the
# raw string against the file on disk would never match.
asset_sha() { printf '%s\n' "$1" | sha256_stdin; }

# ---- filesystem -----------------------------------------------------------

# Write stdin to $1 with mode $2, atomically: a half-written launcher or
# Dockerfile is worse than none at all.
atomic_write() {
    local dest=$1 mode=$2 dir tmp
    dir=$(dirname "$dest")
    [ -d "$dir" ] || mkdir -p "$dir" || die "cannot create directory: $dir"
    [ -w "$dir" ] || die "directory is not writable: $dir"
    tmp=$(mktemp "$dest.tmp.XXXXXX") || die "cannot create a temp file in $dir"
    cat > "$tmp" || { rm -f "$tmp"; die "failed writing $dest"; }
    chmod "$mode" "$tmp" || { rm -f "$tmp"; die "failed to chmod $dest"; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "failed to install $dest"; }
}

# Timestamp for backup filenames. Not locale-dependent.
timestamp() { date -u '+%Y%m%d-%H%M%S'; }

backup_file() {
    local f=$1 bak
    bak="$f.bak.$(timestamp)"
    cp -p "$f" "$bak" 2>/dev/null || cp "$f" "$bak" || die "could not back up $f"
    printf '%s' "$bak"
}

# Free space in whole GB at (or above) a path. Portable across GNU/BSD df.
free_space_gb() {
    local target=$1
    while [ ! -d "$target" ] && [ "$target" != "/" ]; do target=$(dirname "$target"); done
    df -Pk "$target" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }'
}

# ---- platform detection ---------------------------------------------------

uname_s() { printf '%s' "${SANDBOX_FAKE_UNAME_S:-$(uname -s)}"; }

os_kind() {
    case "$(uname_s)" in
        Linux)  printf 'linux' ;;
        Darwin) printf 'darwin' ;;
        *)      printf 'unknown' ;;
    esac
}

is_wsl() {
    local pv="${SANDBOX_PROC_VERSION:-/proc/version}"
    [ -r "$pv" ] && grep -qi 'microsoft' "$pv" 2>/dev/null
}

# One field out of os-release, unquoted. Deliberately does not source the
# file — a stray command in there is not our problem to execute.
os_release_field() {
    local key=$1 file="${SANDBOX_OS_RELEASE:-/etc/os-release}" val
    [ -r "$file" ] || return 1
    val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-) || return 1
    [ -n "$val" ] || return 1
    val=${val%\"}; val=${val#\"}
    val=${val%\'}; val=${val#\'}
    printf '%s' "$val"
}

# debian | fedora | arch | suse | alpine | unknown  (ID, then ID_LIKE)
distro_family() {
    local id like
    id=$(os_release_field ID 2>/dev/null || printf '')
    like=$(os_release_field ID_LIKE 2>/dev/null || printf '')
    case " $id $like " in
        *" debian "*|*" ubuntu "*)         printf 'debian' ;;
        *" fedora "*|*" rhel "*|*" centos "*) printf 'fedora' ;;
        *" arch "*)                        printf 'arch' ;;
        *" suse "*|*" opensuse "*)         printf 'suse' ;;
        *" alpine "*)                      printf 'alpine' ;;
        *)                                 printf 'unknown' ;;
    esac
}

# ---- version comparison ---------------------------------------------------

# version_gt A B -> true when A is strictly newer than B. Numeric per part,
# tolerant of "1.2" vs "1.2.0" and of a leading "v".
version_gt() {
    local a=${1#v} b=${2#v} i a_i b_i
    [ -n "$a" ] || return 1
    [ -n "$b" ] || return 0
    a=$(printf '%s' "$a" | tr -c '0-9.' ' '); a=${a%% *}
    b=$(printf '%s' "$b" | tr -c '0-9.' ' '); b=${b%% *}
    i=1
    while [ "$i" -le 4 ]; do
        a_i=$(printf '%s' "$a" | cut -d. -f"$i"); a_i=${a_i:-0}
        b_i=$(printf '%s' "$b" | cut -d. -f"$i"); b_i=${b_i:-0}
        case "$a_i" in ''|*[!0-9]*) a_i=0 ;; esac
        case "$b_i" in ''|*[!0-9]*) b_i=0 ;; esac
        [ "$a_i" -gt "$b_i" ] && return 0
        [ "$a_i" -lt "$b_i" ] && return 1
        i=$((i + 1))
    done
    return 1
}

# ---- interaction ----------------------------------------------------------

# Stdin is the script itself under `curl | bash`, so prompts must read from
# the terminal explicitly or not at all.
confirm() {
    local prompt=$1 reply
    [ -z "${ASSUME_YES:-}" ] || return 0
    if [ ! -r /dev/tty ]; then
        oops "$prompt"
        info "Not running interactively — re-run with --yes to confirm."
        return 1
    fi
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply < /dev/tty || return 1
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---- docker: presence, reachability, and honest diagnostics ---------------

docker_missing_help() {
    local family
    oops "Docker is not installed (no \`docker\` on PATH)."
    if is_wsl; then
        say ''
        say "You are inside WSL. Docker must either be exposed from Docker Desktop"
        say "or installed as Docker Engine inside this distro."
        remedy \
            "Docker Desktop route: install Docker Desktop for Windows, then enable" \
            "   Settings -> Resources -> WSL integration for this distro." \
            "" \
            "Docker Engine route (no Docker Desktop, no licensing question):" \
            "   curl -fsSL https://get.docker.com | sh" \
            "   sudo usermod -aG docker \"\$USER\" && newgrp docker" \
            "" \
            "See WINDOWS.md (Route A) in $REPO_URL"
        return
    fi
    if [ "$(os_kind)" = "darwin" ]; then
        remedy \
            "Install Docker Desktop:  brew install --cask docker    (then launch it)" \
            "Or a lighter alternative:  brew install colima docker && colima start" \
            "Or OrbStack:  brew install --cask orbstack" \
            "Then re-run this installer."
        return
    fi
    family=$(distro_family)
    case "$family" in
        debian)
            remedy \
                "sudo apt-get update && sudo apt-get install -y docker.io" \
                "   (or follow https://docs.docker.com/engine/install/ubuntu/ for the official repo)" \
                "sudo systemctl enable --now docker" \
                "sudo usermod -aG docker \"\$USER\"" \
                "Log out and back in (or run: newgrp docker), then re-run this installer." ;;
        fedora)
            remedy \
                "sudo dnf install -y docker  (or follow https://docs.docker.com/engine/install/fedora/)" \
                "sudo systemctl enable --now docker" \
                "sudo usermod -aG docker \"\$USER\"" \
                "Log out and back in (or run: newgrp docker), then re-run this installer." ;;
        arch)
            remedy \
                "sudo pacman -S --needed docker" \
                "sudo systemctl enable --now docker" \
                "sudo usermod -aG docker \"\$USER\"" \
                "Log out and back in (or run: newgrp docker), then re-run this installer." ;;
        suse)
            remedy \
                "sudo zypper install -y docker" \
                "sudo systemctl enable --now docker" \
                "sudo usermod -aG docker \"\$USER\"" \
                "Log out and back in (or run: newgrp docker), then re-run this installer." ;;
        *)
            remedy \
                "Install Docker Engine: https://docs.docker.com/engine/install/" \
                "   or, for a quick generic install:  curl -fsSL https://get.docker.com | sh" \
                "sudo systemctl enable --now docker" \
                "sudo usermod -aG docker \"\$USER\"" \
                "Log out and back in (or run: newgrp docker), then re-run this installer." ;;
    esac
    say "Note: membership in the \`docker\` group on a rootful daemon is root-equivalent."
    say "On a shared machine where users are not mutually trusted, prefer rootless Docker:"
    say "  https://docs.docker.com/engine/security/rootless/"
}

# `docker info` failed. Say *why* rather than dumping the raw error.
docker_unreachable_help() {
    local out=$1
    case "$out" in
        *"could not be found in this WSL"*|*"not be found in this WSL 2 distro"*)
            oops "Docker Desktop is installed on Windows but not exposed to this WSL distro."
            remedy \
                "Open Docker Desktop -> Settings -> Resources -> WSL integration" \
                "Enable integration for this distro, then Apply & Restart" \
                "Re-open this terminal and re-run the installer"
            return ;;
        *"permission denied"*|*"Permission denied"*)
            oops "Docker is installed but this user cannot talk to the daemon."
            remedy \
                "sudo usermod -aG docker \"\$USER\"" \
                "Apply it to the current shell:  newgrp docker" \
                "   (or log out and back in, which is more reliable)" \
                "Verify with:  docker info" \
                "Re-run this installer"
            return ;;
        *"Cannot connect to the Docker daemon"*|*"daemon is not running"*|*"Is the docker daemon running"*)
            oops "Docker is installed but the daemon is not running."
            if [ "$(os_kind)" = "darwin" ]; then
                remedy "Start Docker Desktop (or: colima start), wait for it to report ready" \
                       "Verify with:  docker info" "Re-run this installer"
            else
                remedy "sudo systemctl start docker    (and: sudo systemctl enable docker)" \
                       "Verify with:  docker info" "Re-run this installer"
            fi
            return ;;
    esac
    oops "Docker is installed but \`docker info\` failed."
    say ''
    say "$C_DIM$(printf '%s' "$out" | tail -n 6)$C_RESET"
    remedy "Fix the error above, verify with:  docker info" "Re-run this installer"
}

# 0 = usable, 2 = missing, 3 = unreachable. Never exits: callers decide.
docker_check() {
    local out
    if ! have docker; then docker_missing_help; return 2; fi
    if out=$(docker info 2>&1); then return 0; fi
    docker_unreachable_help "$out"
    return 3
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

image_label() {
    docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || printf ''
}

volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }

ensure_volume() {
    volume_exists "$1" && return 0
    docker volume create "$1" >/dev/null || die "could not create docker volume: $1"
    ok "created volume $1"
}

# UID owning a volume's contents, via a throwaway root container. Empty when
# it cannot be determined (no helper image, daemon hiccup) — callers treat
# "unknown" as "leave it alone".
volume_owner_uid() {
    local vol=$1 helper=$2
    docker run --rm --user 0:0 -v "$vol:/v" "$helper" \
        sh -c 'stat -c %u /v 2>/dev/null || stat -f %u /v 2>/dev/null' 2>/dev/null | tr -d '\r\n '
}

# The repo's most-reported failure: volumes owned by a UID the image's agent
# user does not have. Non-destructive, preserves the auth tokens inside.
repair_volume_owner() {
    local vol=$1 helper=$2 want owner
    want=$(host_uid)
    owner=$(volume_owner_uid "$vol" "$helper")
    [ -n "$owner" ] || return 0
    [ "$owner" != "$want" ] || return 0
    warn "volume $vol is owned by UID $owner but this user is UID $want — repairing"
    if docker run --rm --user 0:0 -v "$vol:/v" "$helper" \
         chown -R "$want:$(host_gid)" /v >/dev/null 2>&1; then
        ok "chowned $vol to $want:$(host_gid) (auth preserved)"
    else
        warn "could not chown $vol; see the troubleshooting section in MANUAL.md"
    fi
}

# ---- manifest -------------------------------------------------------------
# Flat key=value. Parsed without eval and without jq: the installer must not
# acquire a dependency the launchers were careful to avoid.

manifest_dir() { printf '%s' "${SANDBOX_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox}"; }
manifest_path() { printf '%s/%s.manifest' "$(manifest_dir)" "$AGENT"; }

manifest_get() {
    local key=$1 file line
    file=$(manifest_path)
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$file"
    return 1
}

manifest_get_or() { manifest_get "$1" 2>/dev/null || printf '%s' "$2"; }

is_installed() { [ -r "$(manifest_path)" ]; }

manifest_write() {
    local file dir
    dir=$(manifest_dir); file=$(manifest_path)
    mkdir -p "$dir" || die "cannot create state directory: $dir"
    atomic_write "$file" 644 <<EOF
schema=1
agent=$AGENT
installer_version=$INSTALLER_VERSION
installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
src_dir=$SRC_DIR
dockerfile=$SRC_DIR/Dockerfile
dockerfile_sha=$(sha256_file "$SRC_DIR/Dockerfile")
launcher=$BIN_DIR/$LAUNCHER_NAME
launcher_sha=$(sha256_file "$BIN_DIR/$LAUNCHER_NAME")
bin_dir=$BIN_DIR
image=$IMAGE
image_uid=$(host_uid)
rc_file=${RC_FILE_EDITED:-}
extra_sha=${EXTRA_SHA:-}
EOF
}

# ---- PATH -----------------------------------------------------------------

path_has_dir() {
    case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

rc_file_for_shell() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    case "$shell_name" in
        zsh)  printf '%s/.zshrc' "$HOME" ;;
        bash) printf '%s/.bashrc' "$HOME" ;;
        *)    printf '%s/.profile' "$HOME" ;;
    esac
}

PATH_MARKER='# added by the agent-sandbox installer'

# Idempotent: guarded by a marker, and skipped entirely when the directory is
# already on PATH. Re-running the installer must never grow your rc file.
ensure_on_path() {
    local dir=$1 rc literal
    if path_has_dir "$dir"; then
        info "$dir is already on PATH"
        return 0
    fi
    if [ -n "${NO_PATH_EDIT:-}" ]; then
        warn "$dir is not on PATH and --no-path-edit was given; add it yourself"
        return 0
    fi
    rc=$(rc_file_for_shell)
    if [ -f "$rc" ] && grep -qF "$PATH_MARKER" "$rc" 2>/dev/null; then
        info "PATH entry already present in $rc"
        RC_FILE_EDITED=$rc
        return 0
    fi
    case "$dir" in
        "$HOME/"*) literal="\$HOME/${dir#"$HOME"/}" ;;
        *)         literal=$dir ;;
    esac
    # shellcheck disable=SC2016  # $PATH must reach the rc file unexpanded
    { printf '\n%s\n' "$PATH_MARKER"
      printf 'export PATH="%s:$PATH"\n' "$literal"
    } >> "$rc" || die "could not append to $rc"
    RC_FILE_EDITED=$rc
    ok "added $dir to PATH in $rc"
    # shellcheck disable=SC2034  # read by the agent's print_next_steps
    PATH_NEEDS_RELOAD=$rc
}

# ---- argument parsing -----------------------------------------------------

usage() {
    cat >&2 <<USAGE
${C_BOLD}$AGENT_NAME sandbox installer${C_RESET} (v$INSTALLER_VERSION)

Installs a Docker sandbox for running $AGENT_NAME in full-autonomy mode, where
the only host path the agent can see is the directory you launch it from.

${C_BOLD}Usage${C_RESET}
  curl -fsSL $RAW_BASE/install/$AGENT.sh | bash
  curl -fsSL $RAW_BASE/install/$AGENT.sh | bash -s -- [options]

${C_BOLD}Options${C_RESET}
  --check          Report what is installed and whether it is current; change nothing
  --force          Reinstall/rebuild even when everything looks current
  --uninstall      Remove the launcher, Dockerfile and image (volumes/auth survive)
  --purge          With --uninstall, also delete the named volumes (destroys auth)
  --prefix DIR     Directory for the launcher script (default: \$HOME/.local/bin)
  --src-dir DIR    Directory for the Dockerfile (default: $SRC_DIR_DEFAULT)
  --no-build       Install files but skip the docker build
  --no-path-edit   Never touch your shell rc file
  --yes            Assume yes for confirmations (non-interactive use)
  --quiet          Only warnings and errors
  --allow-root     Permit running as root (not recommended)
  --version        Print the installer version and exit
  --help           This message

Re-running the install command is the upgrade path: it rewrites only what
changed and rebuilds the image only when the Dockerfile changed.
USAGE
}

MODE=install
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)        MODE=check ;;
            --uninstall)    MODE=uninstall ;;
            --purge)        PURGE=1 ;;
            --force)        FORCE=1 ;;
            --no-build)     NO_BUILD=1 ;;
            --no-path-edit) NO_PATH_EDIT=1 ;;
            --yes|-y)       ASSUME_YES=1 ;;
            --quiet|-q)     QUIET=1 ;;
            --allow-root)   ALLOW_ROOT=1 ;;
            --version|-V)   MODE=version ;;
            --help|-h)      MODE=help ;;
            --prefix)       shift; [ $# -gt 0 ] || die "--prefix needs a directory"; BIN_DIR=$1 ;;
            --prefix=*)     BIN_DIR=${1#*=} ;;
            --src-dir)      shift; [ $# -gt 0 ] || die "--src-dir needs a directory"; SRC_DIR=$1 ;;
            --src-dir=*)    SRC_DIR=${1#*=} ;;
            -*)             oops "unknown option: $1"; say "Try --help."; exit 64 ;;
            *)              oops "unexpected argument: $1"; say "Try --help."; exit 64 ;;
        esac
        shift
    done
}

# ---- preflight ------------------------------------------------------------

preflight() {
    local kind rc space

    kind=$(os_kind)
    if [ "$kind" = "unknown" ]; then
        oops "Unsupported platform: $(uname_s)"
        remedy \
            "This installer supports Linux and macOS." \
            "On Windows, use the PowerShell installer instead:" \
            "   irm $RAW_BASE/install/$AGENT.ps1 | iex" \
            "Or install WSL2 and run this script inside it (see WINDOWS.md)."
        exit 78
    fi

    if [ "$(effective_uid)" = "0" ] && [ -z "${ALLOW_ROOT:-}" ]; then
        oops "Refusing to run as root."
        remedy \
            "This installs into your home directory and builds a per-user image;" \
            "   running it as root would put the launcher in root's PATH and build" \
            "   an image whose agent user is UID 0." \
            "Re-run as your normal user." \
            "If you really mean it, pass --allow-root."
        exit 77
    fi

    # `docker_check; rc=$?` would never be reached under `set -e`: the
    # non-zero return aborts the script before the assignment.
    if docker_check; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then exit $((rc + 8)); fi

    if ! have curl && ! have wget; then
        warn "neither curl nor wget found — update checks will be skipped"
    fi

    space=$(free_space_gb "${HOME:-/}")
    if [ -n "$space" ] && [ "$space" -lt 3 ] 2>/dev/null; then
        warn "only ${space}GB free on $HOME — the image needs roughly 2GB"
    fi
}

# ---- file installation ----------------------------------------------------

# Writes $3 to $1 with mode $2, but never silently destroys local edits:
# a file whose hash differs from what the manifest recorded is backed up
# first. Sets FILE_ACTION to unchanged|created|updated|replaced.
install_asset() {
    local dest=$1 mode=$2 content=$3 recorded_key=$4
    local cur new recorded bak
    new=$(asset_sha "$content")

    if [ -f "$dest" ]; then
        cur=$(sha256_file "$dest")
        if [ "$cur" = "$new" ] && [ -z "${FORCE:-}" ]; then
            FILE_ACTION=unchanged
            info "$(basename "$dest") is already current"
            return 0
        fi
        recorded=$(manifest_get_or "$recorded_key" '')
        if [ -n "$recorded" ] && [ "$recorded" != "$cur" ]; then
            bak=$(backup_file "$dest")
            warn "$dest was modified locally — your version is saved as $(basename "$bak")"
            FILE_ACTION=replaced
        else
            FILE_ACTION=updated
        fi
    else
        FILE_ACTION=created
    fi

    printf '%s\n' "$content" | atomic_write "$dest" "$mode"
    case "$FILE_ACTION" in
        created) ok "wrote $dest" ;;
        *)       ok "updated $dest" ;;
    esac
}

# ---- image build ----------------------------------------------------------

BUILD_EXTRA_ARGS=()

LABEL_SHA='sandbox.dockerfile_sha'
LABEL_UID='sandbox.agent_uid'
LABEL_VER='sandbox.installer_version'

image_is_current() {
    local want_sha=$1
    image_exists "$IMAGE" || return 1
    [ "$(image_label "$IMAGE" "$LABEL_SHA")" = "$want_sha" ] || return 1
    [ "$(image_label "$IMAGE" "$LABEL_UID")" = "$(host_uid)" ] || return 1
    return 0
}

build_image() {
    local want_sha reason log rc
    want_sha=$(sha256_file "$SRC_DIR/Dockerfile")

    if [ -n "${NO_BUILD:-}" ]; then
        warn "--no-build given; skipping docker build"
        return 0
    fi

    if image_is_current "$want_sha" && [ -z "${FORCE:-}" ] && [ -z "${FORCE_BUILD:-}" ]; then
        info "image $IMAGE is up to date"
        return 0
    fi

    if ! image_exists "$IMAGE"; then
        reason="building $IMAGE for the first time"
    elif [ -n "${FORCE_BUILD:-}" ]; then
        reason="rebuilding $IMAGE: ${FORCE_BUILD_REASON:-the pinned agent version changed}"
    elif [ "$(image_label "$IMAGE" "$LABEL_UID")" != "$(host_uid)" ]; then
        reason="rebuilding $IMAGE: its agent UID ($(image_label "$IMAGE" "$LABEL_UID")) does not match yours ($(host_uid))"
    elif [ "$(image_label "$IMAGE" "$LABEL_SHA")" != "$want_sha" ]; then
        reason="rebuilding $IMAGE: the Dockerfile changed"
    else
        reason="rebuilding $IMAGE (--force)"
    fi
    step "$reason — this can take a few minutes"

    log=$(mktemp "${TMPDIR:-/tmp}/sandbox-build.XXXXXX")
    local args
    args=(
        --build-arg "UID=$(host_uid)"
        --build-arg "GID=$(host_gid)"
        --label "$LABEL_SHA=$want_sha"
        --label "$LABEL_UID=$(host_uid)"
        --label "$LABEL_VER=$INSTALLER_VERSION"
    )
    # Agent hooks (Codex pins its npm version) append here.
    if [ "${#BUILD_EXTRA_ARGS[@]}" -gt 0 ]; then args+=("${BUILD_EXTRA_ARGS[@]}"); fi
    args+=(-t "$IMAGE" "$SRC_DIR")

    set +e
    if [ -n "${QUIET:-}" ]; then
        docker build "${args[@]}" >"$log" 2>&1; rc=$?
    else
        docker build "${args[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    fi
    set -e

    if [ "$rc" -ne 0 ]; then
        oops "docker build failed (exit $rc)"
        say ''
        say "$C_DIM--- last 20 lines of the build log ---$C_RESET"
        tail -n 20 "$log" >&2
        say "$C_DIM(full log: $log)$C_RESET"
        remedy \
            "Read the error above — it is usually a transient network failure" \
            "   while fetching packages, or a full disk." \
            "Re-run the installer to try again." \
            "If it persists, open an issue at $REPO_URL/issues with that log."
        exit 1
    fi
    rm -f "$log"
    ok "built $IMAGE"
}

# ---- volumes --------------------------------------------------------------

# Small root-capable image for chown/stat work inside volumes. Prefer the
# sandbox image we just built (already local, no extra pull); fall back to
# alpine only if it is missing.
helper_image() {
    if image_exists "$IMAGE"; then printf '%s' "$IMAGE"
    else printf 'alpine'
    fi
}

setup_volumes() {
    local helper vol
    helper=$(helper_image)
    for vol in $VOLUME_BASENAMES; do
        ensure_volume "$vol-$(sandbox_user)"
    done
    if [ -n "${NO_BUILD:-}" ] && ! image_exists "$IMAGE"; then
        info "skipping volume ownership check (no image to inspect with)"
        return 0
    fi
    for vol in $VOLUME_BASENAMES; do
        repair_volume_owner "$vol-$(sandbox_user)" "$helper"
    done
}

# ---- network --------------------------------------------------------------

download() {
    if have curl; then curl -fsSL --max-time "${2:-10}" "$1" 2>/dev/null
    elif have wget; then wget -qO- --timeout="${2:-10}" "$1" 2>/dev/null
    else return 1
    fi
}

latest_version() { download "$RAW_BASE/VERSION" 5 | head -1 | tr -d ' \r\n'; }

# ---- modes ----------------------------------------------------------------

do_install() {
    preflight

    step "Installing the $AGENT_NAME sandbox (v$INSTALLER_VERSION)"
    if is_installed; then
        local prev
        WAS_INSTALLED=1
        prev=$(manifest_get_or installer_version 'unknown')
        if [ "$prev" = "$INSTALLER_VERSION" ]; then
            info "already at v$INSTALLER_VERSION — checking that everything matches"
        else
            info "upgrading from v$prev to v$INSTALLER_VERSION"
        fi
    fi

    mkdir -p "$SRC_DIR" || die "cannot create $SRC_DIR"
    install_asset "$SRC_DIR/Dockerfile" 644 "$ASSET_DOCKERFILE" dockerfile_sha

    mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
    install_asset "$BIN_DIR/$LAUNCHER_NAME" 755 "$ASSET_LAUNCHER" launcher_sha

    ensure_on_path "$BIN_DIR"

    agent_pre_build
    build_image
    setup_volumes
    agent_post_build

    manifest_write
    blank
    step "Done."
    # First-run instructions are for a first run; an upgrade already has a
    # logged-in user who does not need to be told how to log in.
    if [ -n "${WAS_INSTALLED:-}" ]; then
        say "  $AGENT_NAME sandbox is at v$INSTALLER_VERSION."
        say "  $LAUNCHER_NAME --sandbox-doctor    to confirm image, volumes and versions"
    else
        print_next_steps
    fi
}

do_check() {
    local rc=0 want_sha cur_sha latest vol owner helper

    printf '%s%s sandbox — status%s\n' "$C_BOLD" "$AGENT_NAME" "$C_RESET"
    printf '  installer version   %s\n' "$INSTALLER_VERSION"

    if ! is_installed; then
        printf '  state               %snot installed%s\n' "$C_YELLOW" "$C_RESET"
        printf '\nInstall with:\n  curl -fsSL %s/install/%s.sh | bash\n' "$RAW_BASE" "$AGENT"
        return 1
    fi
    printf '  installed version   %s\n' "$(manifest_get_or installer_version unknown)"
    printf '  installed at        %s\n' "$(manifest_get_or installed_at unknown)"

    if [ -f "$SRC_DIR/Dockerfile" ]; then
        cur_sha=$(sha256_file "$SRC_DIR/Dockerfile")
        want_sha=$(asset_sha "$ASSET_DOCKERFILE")
        if [ "$cur_sha" = "$want_sha" ]; then
            printf '  Dockerfile          %scurrent%s (%s)\n' "$C_GREEN" "$C_RESET" "$SRC_DIR/Dockerfile"
        elif [ "$cur_sha" = "$(manifest_get_or dockerfile_sha '')" ]; then
            printf '  Dockerfile          %sstale%s — re-run the installer to upgrade\n' "$C_YELLOW" "$C_RESET"; rc=1
        else
            printf '  Dockerfile          %slocally modified%s (%s)\n' "$C_YELLOW" "$C_RESET" "$SRC_DIR/Dockerfile"; rc=1
        fi
    else
        printf '  Dockerfile          %smissing%s\n' "$C_RED" "$C_RESET"; rc=1
    fi

    if [ -x "$BIN_DIR/$LAUNCHER_NAME" ]; then
        if [ "$(sha256_file "$BIN_DIR/$LAUNCHER_NAME")" = "$(asset_sha "$ASSET_LAUNCHER")" ]; then
            printf '  launcher            %scurrent%s (%s)\n' "$C_GREEN" "$C_RESET" "$BIN_DIR/$LAUNCHER_NAME"
        else
            printf '  launcher            %sout of date%s (%s)\n' "$C_YELLOW" "$C_RESET" "$BIN_DIR/$LAUNCHER_NAME"; rc=1
        fi
    else
        printf '  launcher            %smissing%s\n' "$C_RED" "$C_RESET"; rc=1
    fi

    if path_has_dir "$BIN_DIR"; then
        printf '  PATH                %sok%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '  PATH                %s%s is not on PATH%s\n' "$C_YELLOW" "$BIN_DIR" "$C_RESET"; rc=1
    fi

    if ! have docker; then
        printf '  docker              %snot installed%s\n' "$C_RED" "$C_RESET"
        return 1
    elif ! docker info >/dev/null 2>&1; then
        printf '  docker              %sinstalled but unreachable%s\n' "$C_RED" "$C_RESET"
        return 1
    fi
    printf '  docker              %sok%s\n' "$C_GREEN" "$C_RESET"

    if image_exists "$IMAGE"; then
        if image_is_current "$(sha256_file "$SRC_DIR/Dockerfile")"; then
            printf '  image               %scurrent%s (%s)\n' "$C_GREEN" "$C_RESET" "$IMAGE"
        else
            printf '  image               %sneeds rebuild%s (%s)\n' "$C_YELLOW" "$C_RESET" "$IMAGE"; rc=1
        fi
        printf '  image agent UID     %s (you are %s)\n' "$(image_label "$IMAGE" "$LABEL_UID")" "$(host_uid)"
    else
        printf '  image               %smissing%s (%s)\n' "$C_RED" "$C_RESET" "$IMAGE"; rc=1
    fi

    helper=$(helper_image)
    for vol in $VOLUME_BASENAMES; do
        vol="$vol-$(sandbox_user)"
        if volume_exists "$vol"; then
            owner=$(volume_owner_uid "$vol" "$helper")
            if [ -n "$owner" ] && [ "$owner" != "$(host_uid)" ]; then
                printf '  volume %-13s %sowned by UID %s, expected %s%s\n' "$vol" "$C_YELLOW" "$owner" "$(host_uid)" "$C_RESET"; rc=1
            else
                printf '  volume %-13s %spresent%s\n' "$vol" "$C_GREEN" "$C_RESET"
            fi
        else
            printf '  volume %-13s %smissing%s\n' "$vol" "$C_YELLOW" "$C_RESET"; rc=1
        fi
    done

    agent_check_extra

    latest=$(latest_version || printf '')
    if [ -n "$latest" ]; then
        if version_gt "$latest" "$INSTALLER_VERSION"; then
            printf '  upstream            %sv%s available%s\n' "$C_YELLOW" "$latest" "$C_RESET"; rc=1
        else
            printf '  upstream            %slatest%s\n' "$C_GREEN" "$C_RESET"
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        printf '\nRe-run the installer to bring everything up to date:\n'
        printf '  curl -fsSL %s/install/%s.sh | bash\n' "$RAW_BASE" "$AGENT"
    fi
    return $rc
}

do_uninstall() {
    local vol launcher dockerfile

    if ! is_installed; then
        say "$AGENT_NAME sandbox is not installed (no manifest at $(manifest_path))."
        say "Nothing to do."
        return 0
    fi

    step "Removing the $AGENT_NAME sandbox"

    launcher=$(manifest_get_or launcher "$BIN_DIR/$LAUNCHER_NAME")
    if [ -f "$launcher" ]; then rm -f "$launcher" && ok "removed $launcher"; fi

    dockerfile=$(manifest_get_or dockerfile "$SRC_DIR/Dockerfile")
    if [ -f "$dockerfile" ]; then rm -f "$dockerfile" && ok "removed $dockerfile"; fi
    agent_uninstall_extra
    if rmdir "$SRC_DIR" 2>/dev/null; then ok "removed $SRC_DIR"; fi

    if have docker && docker info >/dev/null 2>&1 && image_exists "$IMAGE"; then
        if docker image rm "$IMAGE" >/dev/null 2>&1; then
            ok "removed image $IMAGE"
        else
            warn "could not remove image $IMAGE (a container may still be using it)"
        fi
    fi

    if [ -n "${PURGE:-}" ]; then
        blank
        warn "--purge will delete these volumes, including your $AGENT_NAME login:"
        for vol in $VOLUME_BASENAMES; do say "    $vol-$(sandbox_user)"; done
        if confirm "Delete them?"; then
            for vol in $VOLUME_BASENAMES; do
                vol="$vol-$(sandbox_user)"
                volume_exists "$vol" || continue
                if docker volume rm "$vol" >/dev/null 2>&1; then
                    ok "removed volume $vol"
                else
                    warn "could not remove volume $vol"
                fi
            done
        else
            say "Volumes kept."
        fi
    else
        info "volumes kept (your login survives); pass --purge to delete them"
    fi

    rm -f "$(manifest_path)" && ok "removed $(manifest_path)"
    if [ -n "$(manifest_get_or rc_file '')" ]; then
        blank
        info "The PATH line in $(manifest_get_or rc_file '') was left alone; remove it by hand if you want."
    fi
}

main() {
    setup_colors
    : "${BIN_DIR:=$HOME/.local/bin}"
    : "${SRC_DIR:=$SRC_DIR_DEFAULT}"
    parse_args "$@"
    IMAGE="$IMAGE_BASENAME-$(sandbox_user)"
    case "$MODE" in
        help)      usage ;;
        version)   printf '%s\n' "$INSTALLER_VERSION" ;;
        check)     do_check ;;
        uninstall) do_uninstall ;;
        install)   do_install ;;
    esac
}

# ---- agent hooks (default no-ops; agents override after the include) ------

# Each is a no-op unless the agent section below replaces it.
# shellcheck disable=SC2317
agent_pre_build()      { :; }
# shellcheck disable=SC2317
agent_post_build()     { :; }
# shellcheck disable=SC2317
agent_check_extra()    { :; }
# shellcheck disable=SC2317
agent_uninstall_extra() { :; }

# For files the user is *expected* to edit (Codex's config.toml): create it
# once, then never touch it again unless --force.
install_asset_if_absent() {
    local dest=$1 mode=$2 content=$3
    if [ -f "$dest" ] && [ -z "${FORCE:-}" ]; then
        info "keeping your $(basename "$dest")"
        FILE_ACTION=kept
        return 0
    fi
    printf '%s\n' "$content" | atomic_write "$dest" "$mode"
    FILE_ACTION=created
    ok "wrote $dest"
}

__asset_ASSET_DOCKERFILE() {
cat <<'__SANDBOX_ASSET_EOF__'
# Sandbox image for running Claude Code with --dangerously-skip-permissions.
# Philosophy: sandbox skeleton plus everyday toolchains (C, Python, Rust).
# Anything else a project needs gets installed into that project's own
# directory (./.jdk, ./.bin, etc.) — resist adding it here.
#
# Managed by the agent-sandbox installer (v1.0.0). Re-running the
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
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
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
__SANDBOX_ASSET_EOF__
}
ASSET_DOCKERFILE=$(__asset_ASSET_DOCKERFILE)
__asset_ASSET_LAUNCHER() {
cat <<'__SANDBOX_ASSET_EOF__'
#!/usr/bin/env bash
# claude-sandbox — run Claude Code sandboxed in the current directory.
#
# Installed by the agent-sandbox installer (v1.0.0):
#   curl -fsSL https://raw.githubusercontent.com/mriffle/llm-coding-docker-sandbox-instructions/main/install/claude.sh | bash
# Edits here are backed up, not preserved, when you upgrade.
#
# The only host path the container can see is $PWD. Auth and the
# self-updated claude binary live in per-user named volumes, so they
# survive every rebuild.
set -uo pipefail

AGENT=claude
AGENT_BIN=claude
AGENT_NAME="Claude Code"
IMAGE_BASENAME=claude-sandbox
LAUNCHER_NAME=claude-sandbox

# --- shared launcher machinery (generated; see https://github.com/mriffle/llm-coding-docker-sandbox-instructions) ----------------
SANDBOX_VERSION="1.0.0"
RAW_BASE="https://raw.githubusercontent.com/mriffle/llm-coding-docker-sandbox-instructions/main"
REPO_URL="https://github.com/mriffle/llm-coding-docker-sandbox-instructions"

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

CONFIG_VOL="claude-config-$(sandbox_user)"
LOCAL_VOL="claude-local-$(sandbox_user)"
VOLUMES=("$CONFIG_VOL" "$LOCAL_VOL")
MOUNT_ARGS=(
    -v "$CONFIG_VOL:/home/agent/.claude"
    -v "$LOCAL_VOL:/home/agent/.local"
)

launcher_main "$@"
__SANDBOX_ASSET_EOF__
}
ASSET_LAUNCHER=$(__asset_ASSET_LAUNCHER)

print_next_steps() {
    say ""
    say "${C_BOLD}Next steps${C_RESET}"
    if [ -n "${PATH_NEEDS_RELOAD:-}" ]; then
        say "  0. Pick up the new PATH:  source $PATH_NEEDS_RELOAD"
        say "     (new terminals get it automatically)"
    fi
    say "  1. Log in once — the token persists in claude-config-$(sandbox_user):"
    say "       cd ~/some-project && claude-sandbox"
    say "     On a headless server, open the printed URL in a browser anywhere,"
    say "     sign in, and paste the code back at the prompt."
    say ""
    say "  2. Accept the bypass-permissions dialog once, interactively:"
    say "       claude-sandbox --dangerously-skip-permissions"
    say ""
    say "  3. Daily use, from any project directory:"
    say "       claude-sandbox --dangerously-skip-permissions"
    say "       claude-sandbox --sandbox-tmux --dangerously-skip-permissions   # survives SSH drops"
    say ""
    say "  claude-sandbox --sandbox-help    for the sandbox-specific flags"
    say "  $REPO_URL"
}

main "$@"
