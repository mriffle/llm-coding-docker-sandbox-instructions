#!/usr/bin/env bats
# The installed launchers: argument forwarding, the sandbox-* flags, the tmux
# modes, the update nudge, and the doctor report.

load '../helper'

setup() {
    common_setup
    # The launchers use the real `id -u` (no test seams in a user-facing
    # script), so line the fake identity up with it.
    export SANDBOX_FAKE_UID; SANDBOX_FAKE_UID=$(id -u)
    export SANDBOX_FAKE_GID; SANDBOX_FAKE_GID=$(id -g)
    export FAKE_DOCKER_NEW_VOL_UID="$SANDBOX_FAKE_UID"
    export FAKE_TMUX_STATE="$TESTDIR/tmux"
    export FAKE_TMUX_LOG="$TESTDIR/tmux.log"
    export FAKE_DOCKER_ARGV="$TESTDIR/docker.argv"
    export FAKE_CURL_LOG="$TESTDIR/curl.log"
    export FAKE_INSTALLER_DIR="$REPO_ROOT/install"
    mkdir -p "$FAKE_TMUX_STATE"
    : > "$FAKE_TMUX_LOG"; : > "$FAKE_DOCKER_ARGV"; : > "$FAKE_CURL_LOG"
    bash "$(installer claude)" >/dev/null 2>&1
    LAUNCH="$HOME/.local/bin/claude-sandbox"
    PROJECT="$TESTDIR/my project"
    mkdir -p "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
}
teardown() { common_teardown; }

argv_has() {
    grep -qxF -- "$1" "$FAKE_DOCKER_ARGV" \
        || { printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
             fail_with "expected an exact argument: $1"; }
}
tmux_log_has() {
    grep -qF -- "$1" "$FAKE_TMUX_LOG" \
        || { printf -- '--- tmux ---\n%s\n' "$(cat "$FAKE_TMUX_LOG")" >&2
             fail_with "expected a tmux call containing: $1"; }
}
refute_tmux_log() {
    if grep -qF -- "$1" "$FAKE_TMUX_LOG"; then
        printf -- '--- tmux ---\n%s\n' "$(cat "$FAKE_TMUX_LOG")" >&2
        fail_with "expected NO tmux call containing: $1"
    fi
    return 0
}

# --- the normal path -------------------------------------------------------

@test "launcher mounts the current directory and nothing else" {
    cd "$PROJECT"
    local here; here=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$here:/workspace"
    argv_has "claude-config-testuser:/home/agent/.claude"
    argv_has "claude-local-testuser:/home/agent/.local"
    argv_has "--cap-drop=ALL"
    argv_has "--security-opt=no-new-privileges"
}

@test "launcher forwards arguments verbatim, spaces and all" {
    cd "$PROJECT"
    run bash "$LAUNCH" --dangerously-skip-permissions -p "two words here"
    assert_success
    argv_has "claude"
    argv_has "--dangerously-skip-permissions"
    argv_has "-p"
    argv_has "two words here"
}

@test "launcher sanitises the container name but keeps it recognisable" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_success
    grep -qE '^claude-testuser-my-project-[0-9]+$' "$FAKE_DOCKER_ARGV"
}

@test "launcher refuses clearly when the image is missing" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_failure
    assert_output_contains 'does not exist'
    assert_output_contains 'install/claude.sh | bash'
}

@test "launcher reports an unreachable daemon rather than a docker stack trace" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    FAKE_DOCKER_INFO_RC=1 run bash "$LAUNCH"
    assert_failure
    assert_output_contains 'cannot reach the docker daemon'
}

# --- sandbox flags ---------------------------------------------------------

@test "--sandbox-version and --sandbox-help do not start a container" {
    run bash "$LAUNCH" --sandbox-version
    assert_success
    [ "$output" = "$(cat "$REPO_ROOT/VERSION")" ]
    run bash "$LAUNCH" --sandbox-help
    assert_success
    assert_output_contains '--sandbox-tmux'
    refute_docker_ran 'docker run'
}

@test "sandbox flags are only intercepted in first position" {
    cd "$PROJECT"
    run bash "$LAUNCH" --print --sandbox-version
    assert_success
    argv_has "--sandbox-version"
    argv_has "--print"
}

@test "--sandbox-doctor reports image, volumes and UIDs" {
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'claude-sandbox-testuser'
    assert_output_contains 'volume claude-config-testuser ok'
    assert_output_contains 'volume claude-local-testuser ok'
    assert_output_contains "image agent UID     $(id -u)"
}

@test "--sandbox-doctor flags a UID mismatch instead of hiding it" {
    printf 'sandbox.agent_uid=99999\n' > "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run bash "$LAUNCH" --sandbox-doctor
    assert_output_contains 'MISMATCH'
    assert_output_contains 're-run the installer'
}

@test "--sandbox-doctor reports a missing image without crashing" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'image               MISSING'
}

@test "--sandbox-upgrade re-runs the installer" {
    : > "$FAKE_DOCKER_LOG"
    run bash "$LAUNCH" --sandbox-upgrade --force
    assert_success
    grep -q 'install/claude.sh' "$FAKE_CURL_LOG"
    assert_docker_ran 'docker build'
}

# --- the update nudge ------------------------------------------------------

@test "a newer upstream version produces one nudge, not a launch failure" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    assert_success
    assert_output_contains 'of the sandbox is available'
    assert_output_contains '--sandbox-upgrade'
}

@test "an up-to-date upstream version says nothing" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=0.0.1 run bash "$LAUNCH"
    assert_success
    refute_output_contains 'is available'
}

@test "the version check runs at most once a day" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    [ "$(grep -c 'VERSION' "$FAKE_CURL_LOG")" -eq 1 ]
}

@test "a failing version check is silent and never blocks the launch" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK= FAKE_VERSION_FETCH_FAIL=1 run bash "$LAUNCH"
    assert_success
    refute_output_contains 'is available'
    assert_docker_ran 'docker run'
}

@test "SANDBOX_NO_UPDATE_CHECK stops the network call entirely" {
    cd "$PROJECT"
    SANDBOX_NO_UPDATE_CHECK=1 FAKE_UPSTREAM_VERSION=99.0.0 run bash "$LAUNCH"
    assert_success
    [ ! -s "$FAKE_CURL_LOG" ]
}

# --- tmux ------------------------------------------------------------------

@test "--sandbox-tmux creates a session named for the project and attaches" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux --dangerously-skip-permissions
    assert_success
    tmux_log_has 'new-session -d -s claude-my-project'
    tmux_log_has 'attach-session'
    tmux_log_has 'set-environment'
}

@test "--sandbox-tmux passes the agent arguments into the session command" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux --dangerously-skip-permissions
    assert_success
    tmux_log_has '--dangerously-skip-permissions'
    tmux_log_has 'press Enter to close'
}

@test "--sandbox-tmux attaches to an existing session for the same directory" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux
    : > "$FAKE_TMUX_LOG"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    assert_output_contains 'attaching to the existing session'
    refute_tmux_log 'new-session'
}

@test "two projects with the same basename get separate sessions" {
    mkdir -p "$TESTDIR/a/shared" "$TESTDIR/b/shared"
    cd "$TESTDIR/a/shared"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    : > "$FAKE_TMUX_LOG"
    cd "$TESTDIR/b/shared"
    run bash "$LAUNCH" --sandbox-tmux
    assert_success
    tmux_log_has 'new-session'
    [ "$(find "$FAKE_TMUX_STATE/sessions" -type f | wc -l)" -eq 2 ]
    grep -qE 'new-session -d -s claude-shared-[0-9a-f]{6}' "$FAKE_TMUX_LOG"
}

@test "--sandbox-tmux-detached does not attach" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux-detached
    assert_success
    tmux_log_has 'new-session'
    refute_tmux_log 'attach-session'
    assert_output_contains 'in the background'
}

@test "--sandbox-tmux-detached on a running session just says where it is" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux-detached
    : > "$FAKE_TMUX_LOG"
    run bash "$LAUNCH" --sandbox-tmux-detached
    assert_success
    assert_output_contains 'already running'
    refute_tmux_log 'new-session'
}

@test "inside tmux, --sandbox-tmux runs directly instead of nesting" {
    cd "$PROJECT"
    TMUX=/tmp/fake-tmux-socket,123,0 run bash "$LAUNCH" --sandbox-tmux
    assert_success
    assert_output_contains 'already inside tmux'
    refute_tmux_log 'new-session'
    assert_docker_ran 'docker run'
}

@test "--sandbox-tmux without tmux installed says how to install it" {
    cd "$PROJECT"
    PATH="$(path_without tmux)" run bash "$LAUNCH" --sandbox-tmux
    assert_failure
    assert_output_contains 'tmux is not installed'
    assert_output_contains 'brew install tmux'
}

@test "--sandbox-tmux checks the image before creating a session" {
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-tmux
    assert_failure
    refute_tmux_log 'new-session'
}

# --- codex launcher --------------------------------------------------------

@test "the codex launcher rebuilds only when npm reports a new version" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=1.2.3 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    refute_docker_ran 'docker build'
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=9.9.9 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    assert_output_contains 'Codex 9.9.9 available'
    assert_docker_ran '--build-arg CODEX_VERSION=9.9.9'
    assert_docker_ran '--label sandbox.agent_uid='
}

@test "the codex launcher survives an unreachable npm registry" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_LOG"
    FAKE_NPM_FAIL=1 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    assert_output_contains 'npm version check failed'
    assert_docker_ran 'docker run'
}

@test "the codex launcher mounts only its own volume" {
    bash "$(installer codex)" >/dev/null 2>&1
    cd "$PROJECT"
    : > "$FAKE_DOCKER_ARGV"
    FAKE_CODEX_VERSION=1.2.3 run bash "$HOME/.local/bin/codex-sandbox"
    assert_success
    argv_has "codex-config-testuser:/home/agent/.codex"
    argv_has "codex"
    refute_output_contains 'claude'
}
