#!/usr/bin/env bats
# The built Claude installer, exercised end to end against a fake docker.

load '../helper'

setup() { common_setup; }
teardown() { common_teardown; }

DF() { printf '%s/claude-sandbox/Dockerfile' "$HOME"; }
LAUNCHER() { printf '%s/.local/bin/claude-sandbox' "$HOME"; }
MANIFEST() { printf '%s/.local/share/agent-sandbox/claude.manifest' "$HOME"; }

# --- a clean install -------------------------------------------------------

@test "fresh install writes the Dockerfile, launcher and manifest" {
    run_install claude
    assert_success
    assert_file_exists "$(DF)"
    assert_file_mode 644 "$(DF)"
    assert_executable "$(LAUNCHER)"
    assert_file_mode 755 "$(LAUNCHER)"
    assert_file_exists "$(MANIFEST)"
    assert_file_contains "$(DF)" 'FROM node:24-slim'
    assert_file_contains "$(LAUNCHER)" 'claude-sandbox — run Claude Code sandboxed'
}

@test "fresh install builds the image with the host UID and the freshness labels" {
    run_install claude
    assert_success
    assert_docker_ran '--build-arg UID=4242'
    assert_docker_ran '--build-arg GID=4343'
    assert_docker_ran '--label sandbox.agent_uid=4242'
    assert_docker_ran '-t claude-sandbox-testuser'
    assert_docker_ran 'sandbox.dockerfile_sha='
    assert_docker_ran 'sandbox.installer_version='
}

@test "fresh install creates both named volumes, namespaced per user" {
    run_install claude
    assert_success
    assert_docker_ran 'volume create claude-config-testuser'
    assert_docker_ran 'volume create claude-local-testuser'
}

@test "fresh install records hashes that match what is on disk" {
    run_install claude
    assert_success
    grep -q "dockerfile_sha=$(file_sha "$(DF)")" "$(MANIFEST)"
    grep -q "launcher_sha=$(file_sha "$(LAUNCHER)")" "$(MANIFEST)"
    grep -q "image_uid=4242" "$(MANIFEST)"
}

@test "fresh install adds the bin directory to PATH exactly once" {
    run_install claude
    assert_success
    assert_file_contains "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
    [ "$(grep -c 'agent-sandbox installer' "$HOME/.bashrc")" -eq 1 ]
}

@test "fresh install prints the login and bypass-dialog next steps" {
    run_install claude
    assert_output_contains 'Log in once'
    assert_output_contains '--dangerously-skip-permissions'
    assert_output_contains '--sandbox-tmux'
}

# --- idempotence -----------------------------------------------------------

@test "re-running changes nothing and does not rebuild" {
    run_install claude
    assert_success
    : > "$FAKE_DOCKER_LOG"
    run_install claude
    assert_success
    assert_output_contains 'is already current'
    assert_output_contains 'is up to date'
    refute_docker_ran 'docker build'
}

@test "re-running does not append a second PATH block" {
    run_install claude
    run_install claude
    run_install claude
    [ "$(grep -c 'agent-sandbox installer' "$HOME/.bashrc")" -eq 1 ]
}

@test "re-running leaves the volumes alone" {
    run_install claude
    : > "$FAKE_DOCKER_LOG"
    run_install claude
    refute_docker_ran 'volume rm'
}

@test "--force rebuilds even when everything is current" {
    run_install claude
    : > "$FAKE_DOCKER_LOG"
    run_install claude --force
    assert_success
    assert_docker_ran 'docker build'
}

# --- upgrade ---------------------------------------------------------------

# A newer release, simulated the way one actually arrives: a new installer
# whose embedded Dockerfile differs.
make_v2_installer() {
    sed -e 's/^INSTALLER_VERSION="[^"]*"/INSTALLER_VERSION="9.9.9"/' \
        -e 's/    jq ripgrep procps/    jq ripgrep procps fd-find/' \
        "$REPO_ROOT/install/claude.sh" > "$TESTDIR/claude-v2.sh"
    grep -q 'fd-find' "$TESTDIR/claude-v2.sh" || fail_with "v2 fixture did not change the Dockerfile"
}

@test "upgrade rewrites the Dockerfile and rebuilds the image" {
    run_install claude
    assert_success
    make_v2_installer
    : > "$FAKE_DOCKER_LOG"
    run bash "$TESTDIR/claude-v2.sh"
    assert_success
    assert_output_contains 'upgrading from v'
    assert_output_contains 'the Dockerfile changed'
    assert_file_contains "$(DF)" 'fd-find'
    assert_docker_ran 'docker build'
    grep -q 'installer_version=9.9.9' "$(MANIFEST)"
}

@test "upgrade updates the launcher when only the launcher changed" {
    run_install claude
    sed -e 's/^INSTALLER_VERSION="[^"]*"/INSTALLER_VERSION="9.9.9"/' \
        -e 's/^SANDBOX_VERSION="[^"]*"/SANDBOX_VERSION="9.9.9"/' \
        "$REPO_ROOT/install/claude.sh" > "$TESTDIR/v2.sh"
    : > "$FAKE_DOCKER_LOG"
    run bash "$TESTDIR/v2.sh"
    assert_success
    assert_file_contains "$(LAUNCHER)" 'SANDBOX_VERSION="9.9.9"'
    refute_docker_ran 'docker build'
}

@test "upgrade never deletes the volumes that hold your login" {
    run_install claude
    make_v2_installer
    : > "$FAKE_DOCKER_LOG"
    run bash "$TESTDIR/claude-v2.sh"
    assert_success
    refute_docker_ran 'volume rm'
}

@test "a hand-edited Dockerfile is backed up, never silently discarded" {
    run_install claude
    printf 'FROM my-own-base\n# my careful edits\n' > "$(DF)"
    make_v2_installer
    run bash "$TESTDIR/claude-v2.sh"
    assert_success
    assert_output_contains 'was modified locally'
    assert_file_contains "$(DF)" 'fd-find'
    [ "$(cat "$HOME"/claude-sandbox/Dockerfile.bak.*)" = "$(printf 'FROM my-own-base\n# my careful edits')" ]
}

# --- the repo's own historical footguns ------------------------------------

@test "a volume owned by the wrong UID is repaired in place" {
    FAKE_DOCKER_NEW_VOL_UID=1001 run_install claude
    assert_success
    assert_output_contains 'owned by UID 1001'
    assert_output_contains 'chowned'
    [ "$(cat "$FAKE_DOCKER_STATE/volumes/claude-config-testuser.owner")" = 4242 ]
    [ "$(cat "$FAKE_DOCKER_STATE/volumes/claude-local-testuser.owner")" = 4242 ]
}

@test "an image whose agent UID does not match the host is rebuilt" {
    run_install claude
    printf 'sandbox.dockerfile_sha=%s\nsandbox.agent_uid=1001\n' \
        "$(file_sha "$(DF)")" \
        > "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    : > "$FAKE_DOCKER_LOG"
    run_install claude
    assert_success
    assert_output_contains 'does not match yours'
    assert_docker_ran 'docker build'
}

# --- preflight failures ----------------------------------------------------

@test "docker missing on Debian gives apt instructions and exit 10" {
    SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/ubuntu" \
      PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'Docker is not installed'
    assert_output_contains 'apt-get install -y docker.io'
    assert_output_contains 'usermod -aG docker'
    assert_output_contains 'rootless'
}

@test "docker missing on Fedora gives dnf instructions" {
    SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/fedora" \
      PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'dnf install -y docker'
}

@test "docker missing on Arch gives pacman instructions" {
    SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/arch" \
      PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'pacman -S --needed docker'
}

@test "docker missing on an unknown distro falls back to the generic guide" {
    SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/weirdos" \
      PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'docs.docker.com/engine/install'
}

@test "docker missing inside WSL points at Docker Desktop integration" {
    printf 'Linux version 5.15-microsoft-standard-WSL2\n' > "$TESTDIR/pv"
    SANDBOX_PROC_VERSION="$TESTDIR/pv" PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'WSL integration'
    assert_output_contains 'WINDOWS.md'
}

@test "docker missing on macOS points at Docker Desktop, colima and OrbStack" {
    SANDBOX_FAKE_UNAME_S=Darwin PATH="$(path_without docker)" run bash "$(installer claude)"
    assert_status 10
    assert_output_contains 'brew install --cask docker'
    assert_output_contains 'colima'
}

@test "a stopped daemon is distinguished from a missing docker" {
    FAKE_DOCKER_INFO_RC=1 run_install claude
    assert_status 11
    assert_output_contains 'daemon is not running'
    assert_output_contains 'systemctl start docker'
}

@test "a permission-denied socket gives docker-group instructions" {
    FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_OUT='Got permission denied while trying to connect to the Docker daemon socket' \
      run_install claude
    assert_status 11
    assert_output_contains 'cannot talk to the daemon'
    assert_output_contains 'newgrp docker'
}

@test "Docker Desktop without WSL integration is named exactly" {
    FAKE_DOCKER_INFO_RC=1 \
    FAKE_DOCKER_INFO_OUT="The command 'docker' could not be found in this WSL 2 distro." \
      run_install claude
    assert_status 11
    assert_output_contains 'not exposed to this WSL distro'
    assert_output_contains 'Apply & Restart'
}

@test "an unsupported platform refuses with the PowerShell pointer" {
    SANDBOX_FAKE_UNAME_S=SunOS run_install claude
    assert_status 78
    assert_output_contains 'Unsupported platform'
    assert_output_contains 'install/claude.ps1'
}

@test "running as root is refused with an explanation" {
    SANDBOX_FAKE_EUID=0 run_install claude
    assert_status 77
    assert_output_contains 'Refusing to run as root'
    assert_output_contains '--allow-root'
}

@test "--allow-root overrides the root refusal" {
    SANDBOX_FAKE_EUID=0 run_install claude --allow-root
    assert_success
}

@test "an unknown flag exits 64 without touching anything" {
    run_install claude --frobnicate
    assert_status 64
    assert_output_contains 'unknown option'
    assert_file_missing "$(DF)"
}

# --- build failure ---------------------------------------------------------

@test "a failed build exits non-zero, shows the log tail, and records no install" {
    FAKE_DOCKER_BUILD_RC=3 FAKE_DOCKER_BUILD_OUT='E: Unable to fetch some archives' \
      run_install claude
    assert_failure
    assert_output_contains 'docker build failed'
    assert_output_contains 'Unable to fetch some archives'
    assert_file_missing "$(MANIFEST)"
}

@test "a failed build still leaves the files it wrote, so a retry is cheap" {
    FAKE_DOCKER_BUILD_RC=3 run_install claude
    assert_file_exists "$(DF)"
    FAKE_DOCKER_BUILD_RC=0 run_install claude
    assert_success
    assert_file_exists "$(MANIFEST)"
}

# --- --check ---------------------------------------------------------------

@test "--check on a clean machine reports not installed and exits 1" {
    run_install claude --check
    assert_status 1
    assert_output_contains 'not installed'
    assert_file_missing "$(DF)"
}

@test "--check after a good install reports everything current and exits 0" {
    run_install claude
    PATH="$HOME/.local/bin:$PATH" run_install claude --check
    assert_success
    assert_output_contains 'Dockerfile          current'
    assert_output_contains 'launcher            current'
    assert_output_contains 'image               current'
}

@test "--check notices a locally modified Dockerfile" {
    run_install claude
    printf 'FROM something-else\n' > "$(DF)"
    run_install claude --check
    assert_failure
    assert_output_contains 'locally modified'
}

@test "--check notices a missing image" {
    run_install claude
    rm -f "$FAKE_DOCKER_STATE/images/claude-sandbox-testuser.labels"
    run_install claude --check
    assert_failure
    assert_output_contains 'image               missing'
}

@test "--check reports an available upgrade" {
    run_install claude
    SANDBOX_NO_UPDATE_CHECK= FAKE_UPSTREAM_VERSION=99.0.0 run_install claude --check
    assert_failure
    assert_output_contains 'v99.0.0 available'
}

# --- uninstall -------------------------------------------------------------

@test "--uninstall removes the files and image but keeps the volumes" {
    run_install claude
    run_install claude --uninstall
    assert_success
    assert_file_missing "$(DF)"
    assert_file_missing "$(LAUNCHER)"
    assert_file_missing "$(MANIFEST)"
    assert_docker_ran 'image rm claude-sandbox-testuser'
    refute_docker_ran 'volume rm'
    assert_output_contains 'volumes kept'
    [ -f "$FAKE_DOCKER_STATE/volumes/claude-config-testuser.owner" ]
}

@test "--uninstall --purge --yes deletes the volumes too" {
    run_install claude
    run_install claude --uninstall --purge --yes
    assert_success
    assert_docker_ran 'volume rm claude-config-testuser'
    assert_docker_ran 'volume rm claude-local-testuser'
}

@test "--purge without a tty and without --yes keeps the volumes" {
    run_install claude
    run_install claude --uninstall --purge
    refute_docker_ran 'volume rm'
    assert_output_contains 'Volumes kept'
}

@test "--uninstall on a clean machine is a harmless no-op" {
    run_install claude --uninstall
    assert_success
    assert_output_contains 'not installed'
}

# --- placement options -----------------------------------------------------

@test "--prefix and --src-dir are honoured everywhere" {
    run_install claude --prefix "$TESTDIR/bin" --src-dir "$TESTDIR/src"
    assert_success
    assert_executable "$TESTDIR/bin/claude-sandbox"
    assert_file_exists "$TESTDIR/src/Dockerfile"
    assert_file_missing "$(DF)"
    grep -q "bin_dir=$TESTDIR/bin" "$(MANIFEST)"
    assert_docker_ran "$TESTDIR/src"
}

@test "--no-build installs the files but skips docker build" {
    run_install claude --no-build
    assert_success
    assert_file_exists "$(DF)"
    refute_docker_ran 'docker build'
    assert_output_contains 'skipping docker build'
}

@test "--no-path-edit leaves the rc file untouched" {
    run_install claude --no-path-edit
    assert_success
    assert_file_missing "$HOME/.bashrc"
}

@test "a non-writable bin directory fails cleanly instead of half-installing" {
    mkdir -p "$TESTDIR/ro"
    chmod 500 "$TESTDIR/ro"
    run_install claude --prefix "$TESTDIR/ro/bin"
    assert_failure
    assert_output_contains 'cannot create'
    assert_file_missing "$(MANIFEST)"
    chmod 700 "$TESTDIR/ro"
}

# --- delivery safety -------------------------------------------------------

@test "a truncated download never installs anything, at any cut point" {
    # The reason the script ends with `main "$@"` and defines only functions
    # before it: a connection that drops mid-transfer must leave the machine
    # untouched. It may fail loudly — it may not half-install.
    local total pct
    total=$(wc -l < "$(installer claude)")
    for pct in 10 25 50 75 90 99; do
        rm -rf "$HOME" "$FAKE_DOCKER_STATE"; mkdir -p "$HOME" "$FAKE_DOCKER_STATE"
        : > "$FAKE_DOCKER_LOG"
        head -n $(( total * pct / 100 )) "$(installer claude)" > "$TESTDIR/truncated.sh"
        run bash "$TESTDIR/truncated.sh"
        assert_file_missing "$(DF)"
        assert_file_missing "$(LAUNCHER)"
        assert_file_missing "$(MANIFEST)"
        refute_docker_ran 'docker build'
        refute_docker_ran 'volume create'
    done
}

@test "a truncated download piped to bash also installs nothing" {
    local total
    total=$(wc -l < "$(installer claude)")
    head -n $(( total / 2 )) "$(installer claude)" > "$TESTDIR/truncated.sh"
    run bash -c "cat '$TESTDIR/truncated.sh' | bash"
    assert_file_missing "$(DF)"
    assert_file_missing "$(MANIFEST)"
    refute_docker_ran 'docker build'
}

@test "--help and --version work over a pipe and touch nothing" {
    run bash -c "cat '$(installer claude)' | bash -s -- --help"
    assert_success
    assert_output_contains 'sandbox installer'
    run bash -c "cat '$(installer claude)' | bash -s -- --version"
    assert_success
    [ "$output" = "$(cat "$REPO_ROOT/VERSION")" ]
    assert_file_missing "$(DF)"
}

@test "first-run instructions appear on a first run and not on a re-run" {
    run_install claude
    assert_output_contains 'Log in once'
    run_install claude
    assert_success
    refute_output_contains 'Log in once'
    assert_output_contains '--sandbox-doctor'
}
