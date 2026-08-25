#!/usr/bin/env bats
# The built Codex installer. Covers what differs from Claude: a pinned npm
# version, the user-editable config.toml, and the volume seeding that this
# repo has historically got wrong.

load '../helper'

setup() { common_setup; }
teardown() { common_teardown; }

DF() { printf '%s/codex-sandbox/Dockerfile' "$HOME"; }
CFG() { printf '%s/codex-sandbox/config.toml' "$HOME"; }
LAUNCHER() { printf '%s/.local/bin/codex-sandbox' "$HOME"; }
MANIFEST() { printf '%s/.local/share/agent-sandbox/codex.manifest' "$HOME"; }

@test "fresh install writes the Dockerfile, config.toml and launcher" {
    run_install codex
    assert_success
    assert_file_exists "$(DF)"
    assert_file_exists "$(CFG)"
    assert_executable "$(LAUNCHER)"
    assert_file_contains "$(CFG)" 'approval_policy = "never"'
    assert_file_contains "$(CFG)" 'sandbox_mode = "danger-full-access"'
}

@test "only the single codex-config volume is created" {
    run_install codex
    assert_docker_ran 'volume create codex-config-testuser'
    refute_docker_ran 'codex-local'
    refute_docker_ran 'claude-'
}

@test "the current Codex release is pinned into the image at build time" {
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    assert_success
    assert_output_contains 'pinning Codex 0.44.0'
    assert_docker_ran '--build-arg CODEX_VERSION=0.44.0'
    assert_docker_ran '--label codex_version=0.44.0'
}

@test "an unreachable npm registry warns but still installs" {
    FAKE_NPM_FAIL=1 run_install codex
    assert_success
    assert_output_contains 'could not reach the npm registry'
    assert_docker_ran 'docker build'
    assert_file_exists "$(MANIFEST)"
    refute_docker_ran '--build-arg CODEX_VERSION='
}

@test "config.toml is seeded into the volume and the volume is chowned" {
    run_install codex
    assert_success
    assert_output_contains 'seeded config.toml'
    grep -q 'config.toml' "$FAKE_DOCKER_STATE/volumes/codex-config-testuser.files"
    [ "$(cat "$FAKE_DOCKER_STATE/volumes/codex-config-testuser.owner")" = 4242 ]
}

@test "a root-owned volume is normalised during seeding" {
    FAKE_DOCKER_NEW_VOL_UID=0 run_install codex
    assert_success
    [ "$(cat "$FAKE_DOCKER_STATE/volumes/codex-config-testuser.owner")" = 4242 ]
}

@test "seeding runs as root, since that is what the ownership fix requires" {
    run_install codex
    assert_docker_ran '--user 0:0'
    assert_docker_ran 'codex-config-testuser:/cfg'
}

@test "a config.toml the user edited is never overwritten" {
    run_install codex
    printf 'approval_policy = "on-request"\n' > "$(CFG)"
    run_install codex
    assert_success
    assert_output_contains 'keeping your config.toml'
    assert_file_contains "$(CFG)" 'on-request'
}

@test "an existing config.toml inside the volume is left alone" {
    run_install codex
    : > "$FAKE_DOCKER_LOG"
    run_install codex
    assert_output_contains 'config.toml already present in the volume'
}

@test "--force does restore the shipped config.toml" {
    run_install codex
    printf 'approval_policy = "on-request"\n' > "$(CFG)"
    run_install codex --force
    assert_file_contains "$(CFG)" 'approval_policy = "never"'
}

@test "re-running is a no-op for the image" {
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    assert_success
    refute_docker_ran 'docker build'
}

@test "--check reports the pinned codex version and the config file" {
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    run_install codex --check
    assert_output_contains 'config.toml         present'
    assert_output_contains 'codex in image      0.44.0'
}

@test "--uninstall removes config.toml along with the rest" {
    run_install codex
    run_install codex --uninstall
    assert_success
    assert_file_missing "$(CFG)"
    assert_file_missing "$(DF)"
    refute_docker_ran 'volume rm'
}

@test "the launcher carries the codex autonomy explanation, not a flag" {
    run_install codex
    assert_file_contains "$(LAUNCHER)" 'not from a command-line flag'
    assert_output_contains 'no flag needed'
}

@test "codex install never touches claude's files" {
    run_install codex
    assert_file_missing "$HOME/claude-sandbox/Dockerfile"
    assert_file_missing "$HOME/.local/bin/claude-sandbox"
    assert_file_missing "$HOME/.local/share/agent-sandbox/claude.manifest"
}

@test "both agents can be installed side by side" {
    run_install claude
    assert_success
    run_install codex
    assert_success
    assert_file_exists "$HOME/.local/bin/claude-sandbox"
    assert_file_exists "$HOME/.local/bin/codex-sandbox"
    assert_file_exists "$HOME/.local/share/agent-sandbox/claude.manifest"
    assert_file_exists "$HOME/.local/share/agent-sandbox/codex.manifest"
    [ "$(grep -c 'agent-sandbox installer' "$HOME/.bashrc")" -eq 1 ]
}

# The second agent finds the rc file already edited and writes nothing — but
# the launcher is still un-runnable in this shell, and saying nothing there is
# exactly the gap that made the first install look like it had worked and the
# second like it had not.
@test "installing the second agent still explains how to run it now" {
    PATH=$(path_excluding "$HOME/.local/bin")
    run_install claude
    assert_success
    run_install codex
    assert_success
    assert_output_contains 'Make codex-sandbox runnable in this terminal'
    assert_output_contains 'export PATH="$HOME/.local/bin:$PATH"'
}

@test "re-running the installer picks up a new Codex release" {
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    assert_success
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=0.45.0 run_install codex
    assert_success
    assert_output_contains 'Codex 0.44.0 -> 0.45.0'
    assert_docker_ran '--build-arg CODEX_VERSION=0.45.0'
    assert_docker_ran '--label codex_version=0.45.0'
}

@test "re-running with the same Codex release rebuilds nothing" {
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    : > "$FAKE_DOCKER_LOG"
    FAKE_CODEX_VERSION=0.44.0 run_install codex
    assert_success
    refute_docker_ran 'docker build'
}

@test "claude is unaffected by the codex version-forcing path" {
    run_install claude
    : > "$FAKE_DOCKER_LOG"
    run_install claude
    assert_success
    refute_docker_ran 'docker build'
}
