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
    # The *physical* path, not bash's logical $PWD: one project reached through
    # a symlink must not look like two, or it gets two memory stores. (On macOS
    # these differ — /var vs /private/var. The PowerShell launcher has always
    # reported the physical path; the two now agree.)
    local here; here=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$here:$here"
    argv_has "claude-config-testuser:/home/agent/.claude"
    argv_has "claude-local-testuser:/home/agent/.local"
    argv_has "--cap-drop=ALL"
    argv_has "--security-opt=no-new-privileges"
}

# --- one mount point would be one project identity -------------------------
# Both agents key their per-project state on the working directory string:
# Claude Code's ~/.claude/projects/<cwd-slug>/ holds the session transcripts
# and memory, and Codex records the cwd in every rollout. Mounting every
# project at a fixed /workspace made them all one project to the agent.

@test "the container's working directory mirrors the host path" {
    cd "$PROJECT"
    # $PROJECT contains a space, so this also proves the path survives as one
    # argument on both the mount and -w (the argv file is one arg per line).
    local here; here=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "-w"
    argv_has "$here"
}

@test "two project directories get two different container paths" {
    local a b
    mkdir -p "$TESTDIR/alpha" "$TESTDIR/beta"
    cd "$TESTDIR/alpha"; a=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$a:$a"

    : > "$FAKE_DOCKER_ARGV"
    cd "$TESTDIR/beta"; b=$(pwd -P)
    run bash "$LAUNCH"
    assert_success
    argv_has "$b:$b"
    [ "$a" != "$b" ] || fail_with "the fixture directories should differ"
    grep -qxF -- "$a:$a" "$FAKE_DOCKER_ARGV" \
        && fail_with "the second launch reused the first project's path"
    return 0
}

@test "SANDBOX_WORKDIR pins the old fixed mount" {
    cd "$PROJECT"
    local here; here=$(pwd -P)
    SANDBOX_WORKDIR=/workspace run bash "$LAUNCH"
    assert_success
    argv_has "$here:/workspace"
    argv_has "/workspace"
}

@test "a directory that cannot be mirrored falls back to /workspace and says so" {
    cd "$PROJECT"
    local p
    # / and the bare system directories would mount the host over the image;
    # /home/agent is the agent's own home, which a host user actually named
    # `agent` would otherwise expose in full.
    for p in / /usr /home /home/agent /home/agent/work; do
        : > "$FAKE_DOCKER_ARGV"
        SANDBOX_FAKE_PWD="$p" run bash "$LAUNCH"
        assert_success
        assert_output_contains "cannot mirror $p inside the container"
        argv_has "$p:/workspace"
    done
}

@test "a directory beneath a system one is still mirrored" {
    cd "$PROJECT"
    # Only the exact system paths are reserved. /opt/proj (or macOS's
    # /var/folders/xx/proj, where the suite's own temp dirs live) just creates
    # a directory inside the container and is safe to mirror.
    SANDBOX_FAKE_PWD=/opt/proj run bash "$LAUNCH"
    assert_success
    refute_output_contains 'cannot mirror'
    argv_has "/opt/proj:/opt/proj"
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

@test "--sandbox-doctor names the mount it will use for this directory" {
    cd "$PROJECT"
    local here; here=$(pwd -P)
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "project mount       $here -> $here"
}

@test "--sandbox-doctor reports state pooled under the old fixed mount" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    refute_output_contains 'legacy state'
    FAKE_DOCKER_LEGACY_PROJECTS=1 run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains 'legacy state        projects/-workspace'
    assert_output_contains 'ls /v/projects'
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

# --- git identity and credentials ------------------------------------------
# All of these run against the fake git and gh in fixtures/fakebin, never the
# real ones: see the git pinning in common_setup for why that matters.

argv_lacks() {
    if grep -qF -- "$1" "$FAKE_DOCKER_ARGV"; then
        printf -- '--- argv ---\n%s\n' "$(cat "$FAKE_DOCKER_ARGV")" >&2
        fail_with "expected NO argument containing: $1"
    fi
    return 0
}

@test "the host git identity is passed through so the agent can commit" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.name"
    argv_has "GIT_CONFIG_VALUE_0=Ada Lovelace"
    argv_has "GIT_CONFIG_KEY_1=user.email"
    argv_has "GIT_CONFIG_VALUE_1=ada@example.com"
    argv_has "GIT_CONFIG_COUNT=2"
}

@test "an email but no name still yields a usable, correctly counted config" {
    cd "$PROJECT"
    export FAKE_GIT_EMAIL=ada@example.com
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.email"
    argv_has "GIT_CONFIG_COUNT=1"
}

@test "no git identity on the host means no git environment at all" {
    cd "$PROJECT"
    run bash "$LAUNCH"
    assert_success
    argv_lacks "GIT_CONFIG_COUNT"
    argv_lacks "GIT_CONFIG_KEY_0"
}

@test "a host without git launches normally rather than failing" {
    cd "$PROJECT"
    PATH="$(path_without git)" run bash "$LAUNCH"
    assert_success
    argv_has "--cap-drop=ALL"
    argv_lacks "GIT_CONFIG_COUNT"
}

@test "SANDBOX_NO_GIT suppresses identity and credentials entirely" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    export SANDBOX_NO_GIT=1
    run bash "$LAUNCH"
    assert_success
    argv_lacks "GIT_CONFIG_COUNT"
}

@test "no credential is forwarded unless --sandbox-git is given" {
    cd "$PROJECT"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH"
    assert_success
    argv_has "GIT_CONFIG_KEY_0=user.name"
    argv_lacks "SANDBOX_GIT_TOKEN"
    argv_lacks "s3cret"
    argv_lacks "credential."
}

@test "--sandbox-git forwards a credential scoped to the origin's host" {
    cd "$PROJECT"
    export FAKE_GIT_NAME=Ada FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_USER=ada"
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    argv_has "GIT_CONFIG_KEY_2=credential.https://github.com.helper"
    argv_has "GIT_CONFIG_COUNT=3"
    # The helper must name the container's variables, not expand them here.
    grep -qF 'SANDBOX_GIT_TOKEN"' "$FAKE_DOCKER_ARGV" \
        || fail_with "the credential helper did not reach the container intact"
}

@test "--sandbox-git strips the flag rather than passing it to the agent" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-git --dangerously-skip-permissions
    assert_success
    argv_has "--dangerously-skip-permissions"
    argv_lacks "--sandbox-git"
}

@test "--sandbox-git on an ssh remote says so instead of forwarding nothing quietly" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=git@github.com:ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    assert_output_contains "no https remote"
    argv_lacks "SANDBOX_GIT_TOKEN"
}

@test "--sandbox-git with nothing in the credential store warns and still launches" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    run bash "$LAUNCH" --sandbox-git
    assert_success
    assert_output_contains "no credential stored"
    argv_lacks "SANDBOX_GIT_TOKEN"
    argv_has "--cap-drop=ALL"
}

@test "GH_TOKEN is preferred over the credential store for github.com" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=from-store
    export GH_TOKEN=from-env
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=from-env"
    argv_lacks "from-store"
}

@test "gh supplies the token when the credential store has none" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GH_TOKEN=from-gh
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=from-gh"
    argv_has "SANDBOX_GIT_USER=x-access-token"
}

@test "--sandbox-git authenticates the image's gh with the same token" {
    # gh consults no git credential helper, so the helper alone would leave a
    # working `git push` beside a gh insisting it is not logged in.
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GH_TOKEN=s3cret"
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
}

@test "no GH_TOKEN reaches the container without --sandbox-git" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH"
    assert_success
    argv_lacks "GH_TOKEN"
}

@test "a stored credential for a non-GitHub host configures no gh" {
    # gitlab.example.org might be GitHub Enterprise and might be GitLab; the
    # hostname does not say, so gh is left unset rather than aimed at a server
    # that does not speak its API. Pushing still works.
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://gitlab.example.org/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "SANDBOX_GIT_TOKEN=s3cret"
    argv_lacks "GH_TOKEN"
    argv_lacks "GH_HOST"
    argv_lacks "GH_ENTERPRISE_TOKEN"
}

@test "a host the local gh is logged in to is configured as Enterprise" {
    # gh answering for the host is the only evidence available that it is a
    # GitHub instance at all.
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://ghe.corp.example/ada/looms.git
    export FAKE_GH_TOKEN=from-gh
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GH_HOST=ghe.corp.example"
    argv_has "GH_ENTERPRISE_TOKEN=from-gh"
    # GH_TOKEN would send gh to github.com carrying an Enterprise token.
    argv_lacks "GH_TOKEN="
}

@test "a non-github https remote still gets its own scoped helper" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://gitlab.example.org/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GIT_CONFIG_KEY_0=credential.https://gitlab.example.org.helper"
}

@test "userinfo in the remote URL does not confuse the host scoping" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://ada@github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git
    assert_success
    argv_has "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
}

@test "--sandbox-git composes with --sandbox-tmux by way of the session env" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-git --sandbox-tmux
    assert_success
    tmux_log_has "SANDBOX_GIT=1"
}

@test "--sandbox-git is only honoured in first position" {
    cd "$PROJECT"
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --print --sandbox-git
    assert_success
    argv_has "--sandbox-git"
    argv_lacks "SANDBOX_GIT_TOKEN"
}

@test "--sandbox-doctor reports git state without ever printing the token" {
    cd "$PROJECT"
    export FAKE_GIT_NAME="Ada Lovelace" FAKE_GIT_EMAIL=ada@example.com
    export FAKE_GIT_ORIGIN=https://github.com/ada/looms.git
    export FAKE_GIT_CRED_USER=ada FAKE_GIT_CRED_PASS=s3cret
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "Ada Lovelace <ada@example.com>"
    assert_output_contains "available for github.com"
    assert_output_contains "gh cli"
    refute_output_contains "s3cret"
}

@test "--sandbox-doctor names a missing identity as the reason commits fail" {
    cd "$PROJECT"
    run bash "$LAUNCH" --sandbox-doctor
    assert_success
    assert_output_contains "NONE configured"
}
