#!/usr/bin/env bats
# Unit tests for src/lib/common.sh, sourced directly.

load '../helper'

setup() {
    common_setup
    AGENT=claude
    INSTALLER_VERSION=9.9.9
    RAW_BASE=https://example.invalid
    REPO_URL=https://example.invalid/repo
    SRC_DIR_DEFAULT="$HOME/claude-sandbox"
    IMAGE_BASENAME=claude-sandbox
    LAUNCHER_NAME=claude-sandbox
    VOLUME_BASENAMES="claude-config claude-local"
    BIN_DIR="$HOME/.local/bin"
    SRC_DIR="$SRC_DIR_DEFAULT"
    IMAGE="claude-sandbox-testuser"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/src/lib/common.sh"
}
teardown() { common_teardown; }

@test "version_gt: basic ordering" {
    version_gt 1.2.0 1.1.9
    version_gt 2.0.0 1.99.99
    ! version_gt 1.0.0 1.0.0
    ! version_gt 1.0.0 1.0.1
}

@test "version_gt: tolerates short versions and a v prefix" {
    version_gt 1.2 1.1.9
    ! version_gt v1.0 v1.0.0
    version_gt v1.0.1 v1.0
}

@test "version_gt: an empty or junk version never wins" {
    ! version_gt "" 1.0.0
    version_gt 1.0.0 ""
    ! version_gt "not-a-version" 1.0.0
}

@test "sha256_string and sha256_file agree on identical bytes" {
    printf 'hello' > "$TESTDIR/f"
    [ "$(sha256_string 'hello')" = "$(sha256_file "$TESTDIR/f")" ]
}

@test "asset_sha matches what atomic_write actually puts on disk" {
    # The bug this guards: hashing the raw string while writing string+newline
    # makes every re-run look like a change, so nothing is ever 'unchanged'.
    printf '%s\n' "FROM scratch" | atomic_write "$TESTDIR/df" 644
    [ "$(asset_sha 'FROM scratch')" = "$(sha256_file "$TESTDIR/df")" ]
}

@test "sha256_file reports 'missing' rather than failing" {
    [ "$(sha256_file "$TESTDIR/nope")" = "missing" ]
}

@test "atomic_write creates the file with the requested mode" {
    printf 'content\n' | atomic_write "$TESTDIR/sub/dir/file" 755
    assert_file_exists "$TESTDIR/sub/dir/file"
    assert_file_mode 755 "$TESTDIR/sub/dir/file"
    [ "$(cat "$TESTDIR/sub/dir/file")" = "content" ]
}

@test "atomic_write leaves no temp files behind" {
    printf 'x' | atomic_write "$TESTDIR/f" 644
    [ "$(find "$TESTDIR" -name 'f.tmp.*' | wc -l)" -eq 0 ]
}

@test "backup_file preserves the original contents" {
    printf 'original\n' > "$TESTDIR/f"
    bak=$(backup_file "$TESTDIR/f")
    [ "$(cat "$bak")" = "original" ]
    assert_file_exists "$TESTDIR/f"
}

@test "os_kind maps uname output" {
    [ "$(SANDBOX_FAKE_UNAME_S=Linux  os_kind)" = linux ]
    [ "$(SANDBOX_FAKE_UNAME_S=Darwin os_kind)" = darwin ]
    [ "$(SANDBOX_FAKE_UNAME_S=SunOS  os_kind)" = unknown ]
}

@test "distro_family reads ID and ID_LIKE from os-release fixtures" {
    for pair in "ubuntu debian" "debian debian" "fedora fedora" "rhel fedora" "arch arch" "opensuse suse" "alpine alpine" "weirdos unknown"; do
        set -- $pair
        SANDBOX_OS_RELEASE="$REPO_ROOT/tests/fixtures/osrelease/$1"
        export SANDBOX_OS_RELEASE
        got=$(distro_family)
        [ "$got" = "$2" ] || fail_with "os-release '$1': expected $2, got $got"
    done
}

@test "distro_family is 'unknown' when os-release is absent" {
    SANDBOX_OS_RELEASE="$TESTDIR/nonexistent"
    [ "$(distro_family)" = "unknown" ]
}

@test "is_wsl detects the microsoft marker" {
    printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' > "$TESTDIR/pv"
    SANDBOX_PROC_VERSION="$TESTDIR/pv" is_wsl
    printf 'Linux version 6.1.0-generic\n' > "$TESTDIR/pv2"
    ! SANDBOX_PROC_VERSION="$TESTDIR/pv2" is_wsl
}

@test "manifest round-trips values with slashes and spaces" {
    mkdir -p "$SRC_DIR" "$BIN_DIR"
    printf 'FROM scratch\n' > "$SRC_DIR/Dockerfile"
    printf '#!/bin/sh\n' > "$BIN_DIR/claude-sandbox"
    SRC_DIR="$TESTDIR/dir with spaces"
    mkdir -p "$SRC_DIR"; printf 'FROM scratch\n' > "$SRC_DIR/Dockerfile"
    manifest_write
    [ "$(manifest_get src_dir)" = "$TESTDIR/dir with spaces" ]
    [ "$(manifest_get agent)" = "claude" ]
    [ "$(manifest_get installer_version)" = "9.9.9" ]
}

@test "manifest_get fails cleanly for a missing key and a missing file" {
    run manifest_get anything
    [ "$status" -ne 0 ]
    mkdir -p "$(manifest_dir)"
    printf 'a=1\n' > "$(manifest_path)"
    run manifest_get b
    [ "$status" -ne 0 ]
    [ "$(manifest_get_or b fallback)" = "fallback" ]
}

@test "is_installed reflects the manifest" {
    ! is_installed
    mkdir -p "$(manifest_dir)"; printf 'schema=1\n' > "$(manifest_path)"
    is_installed
}

@test "ensure_on_path appends exactly one guarded block, and only once" {
    PATH="/usr/bin:/bin"
    ensure_on_path "$HOME/.local/bin"
    assert_file_contains "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
    ensure_on_path "$HOME/.local/bin"
    [ "$(grep -c 'agent-sandbox installer' "$HOME/.bashrc")" -eq 1 ]
}

@test "ensure_on_path picks the rc file from \$SHELL" {
    PATH="/usr/bin:/bin"
    SHELL=/usr/bin/zsh ensure_on_path "$HOME/.local/bin"
    assert_file_exists "$HOME/.zshrc"
    assert_file_missing "$HOME/.bashrc"
}

@test "ensure_on_path does nothing when the directory is already on PATH" {
    PATH="$HOME/.local/bin:/usr/bin"
    ensure_on_path "$HOME/.local/bin"
    assert_file_missing "$HOME/.bashrc"
}

@test "ensure_on_path honours --no-path-edit" {
    PATH="/usr/bin:/bin"
    NO_PATH_EDIT=1 ensure_on_path "$HOME/.local/bin"
    assert_file_missing "$HOME/.bashrc"
}

@test "install_asset creates, then reports unchanged, then updates" {
    mkdir -p "$SRC_DIR"
    install_asset "$SRC_DIR/Dockerfile" 644 "FROM one" dockerfile_sha
    [ "$FILE_ACTION" = created ]
    install_asset "$SRC_DIR/Dockerfile" 644 "FROM one" dockerfile_sha
    [ "$FILE_ACTION" = unchanged ]
    install_asset "$SRC_DIR/Dockerfile" 644 "FROM two" dockerfile_sha
    [ "$FILE_ACTION" = updated ]
    [ "$(cat "$SRC_DIR/Dockerfile")" = "FROM two" ]
}

@test "install_asset backs up a locally modified file instead of losing it" {
    mkdir -p "$SRC_DIR" "$BIN_DIR"
    install_asset "$SRC_DIR/Dockerfile" 644 "FROM one" dockerfile_sha
    printf '#!/bin/sh\n' > "$BIN_DIR/claude-sandbox"
    manifest_write
    printf 'FROM hand-edited\n' > "$SRC_DIR/Dockerfile"
    install_asset "$SRC_DIR/Dockerfile" 644 "FROM two" dockerfile_sha
    [ "$FILE_ACTION" = replaced ]
    [ "$(cat "$SRC_DIR/Dockerfile")" = "FROM two" ]
    [ "$(cat "$SRC_DIR"/Dockerfile.bak.*)" = "FROM hand-edited" ]
}

@test "install_asset_if_absent never overwrites without --force" {
    mkdir -p "$SRC_DIR"
    install_asset_if_absent "$SRC_DIR/config.toml" 644 "first = true"
    printf 'user = "edited"\n' > "$SRC_DIR/config.toml"
    install_asset_if_absent "$SRC_DIR/config.toml" 644 "first = true"
    [ "$FILE_ACTION" = kept ]
    assert_file_contains "$SRC_DIR/config.toml" 'user = "edited"'
    FORCE=1 install_asset_if_absent "$SRC_DIR/config.toml" 644 "first = true"
    assert_file_contains "$SRC_DIR/config.toml" 'first = true'
}

@test "free_space_gb returns a number for an existing and a missing path" {
    [ -n "$(free_space_gb "$HOME")" ]
    [ -n "$(free_space_gb "$HOME/does/not/exist/yet")" ]
}

@test "sandbox_user prefers the override, then \$USER" {
    [ "$(sandbox_user)" = testuser ]
    unset SANDBOX_FAKE_USER
    USER=realuser
    [ "$(sandbox_user)" = realuser ]
}
