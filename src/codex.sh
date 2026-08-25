#!/usr/bin/env bash
#
# Codex CLI sandbox installer.
#
#   curl -fsSL @@RAW_BASE@@/install/codex.sh | bash
#
# Creates ~/codex-sandbox/{Dockerfile,config.toml}, ~/.local/bin/codex-sandbox,
# a per-user image, and the named volume that holds your login. Re-run to upgrade.
set -euo pipefail

INSTALLER_VERSION="@@VERSION@@"
RAW_BASE="@@RAW_BASE@@"
REPO_URL="@@REPO_URL@@"

AGENT=codex
AGENT_NAME="Codex CLI"
LAUNCHER_NAME=codex-sandbox
IMAGE_BASENAME=codex-sandbox
SRC_DIR_DEFAULT="$HOME/codex-sandbox"
VOLUME_BASENAMES="codex-config"

# @include lib/common.sh

# @embed assets/codex.Dockerfile AS ASSET_DOCKERFILE
# @embed assets/codex-sandbox AS ASSET_LAUNCHER
# @embed assets/codex.config.toml AS ASSET_CONFIG_TOML

# Bake the current Codex release into the first build, so the very first
# launch does not immediately rebuild. A registry that will not answer is not
# fatal: the Dockerfile defaults to `latest`.
agent_pre_build() {
    local latest
    install_asset_if_absent "$SRC_DIR/config.toml" 644 "$ASSET_CONFIG_TOML"
    EXTRA_SHA=$(sha256_file "$SRC_DIR/config.toml")

    latest=$(download https://registry.npmjs.org/@openai/codex/latest 10 \
        | { jq -r .version 2>/dev/null || grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4; } \
        | tr -d ' \r\n') || latest=''
    if [ -n "$latest" ] && [ "$latest" != "null" ]; then
        info "pinning Codex $latest into the image"
        BUILD_EXTRA_ARGS=(--build-arg "CODEX_VERSION=$latest" --label "codex_version=$latest")
        # Re-running the installer is documented as the upgrade path, so it has
        # to cover the Codex release too — not just the Dockerfile. Without
        # this, only the launcher would ever pick up a new version.
        if image_exists "$IMAGE"; then
            local current
            current=$(image_label "$IMAGE" codex_version)
            if [ -n "$current" ] && [ "$current" != "$latest" ]; then
                FORCE_BUILD=1
                FORCE_BUILD_REASON="Codex $current -> $latest"
            fi
        fi
    else
        warn "could not reach the npm registry; building with CODEX_VERSION=latest"
    fi
}

# The failure this repo has hit most: a config.toml (or a whole volume) left
# root-owned, after which Codex cannot open its state DB. The decision about
# whether to seed is made here rather than inside the container, so that what
# gets reported is what actually happened.
volume_has_config() {
    docker run --rm --user 0:0 -v "$1:/cfg" "$2" test -f /cfg/config.toml >/dev/null 2>&1
}

agent_post_build() {
    local vol helper
    vol="codex-config-$(sandbox_user)"
    helper=$(helper_image)

    if [ -n "${NO_BUILD:-}" ] && ! image_exists "$IMAGE"; then
        warn "skipping config.toml seeding (no image available)"
        return 0
    fi

    step "Seeding config.toml into $vol"
    if [ -n "${FORCE:-}" ] || ! volume_has_config "$vol" "$helper"; then
        if docker run --rm --user 0:0 \
            -v "$vol:/cfg" \
            -v "$SRC_DIR/config.toml:/src/config.toml:ro" \
            "$helper" cp /src/config.toml /cfg/config.toml >/dev/null 2>&1; then
            ok "seeded config.toml"
        else
            warn "could not seed config.toml into $vol — Codex may prompt for approvals"
            info "retry with:  $LAUNCHER_NAME --sandbox-doctor"
            return 0
        fi
    else
        info "config.toml already present in the volume — left alone"
    fi

    # Unconditional: this is the step whose absence broke Codex's state DB.
    if docker run --rm --user 0:0 -v "$vol:/cfg" \
        "$helper" chown -R "$(host_uid):$(host_gid)" /cfg >/dev/null 2>&1; then
        ok "volume contents owned by $(host_uid):$(host_gid)"
    else
        warn "could not set ownership on $vol; see the troubleshooting notes in MANUAL.md"
    fi
}

agent_check_extra() {
    local codex_version
    if [ -f "$SRC_DIR/config.toml" ]; then
        printf '  config.toml         present (%s)\n' "$SRC_DIR/config.toml"
    else
        printf '  config.toml         %smissing%s\n' "$C_YELLOW" "$C_RESET"
    fi
    if image_exists "$IMAGE"; then
        codex_version=$(image_label "$IMAGE" codex_version)
        printf '  codex in image      %s\n' "${codex_version:-unknown (built without a pin)}"
    fi
}

agent_uninstall_extra() {
    if [ -f "$SRC_DIR/config.toml" ]; then
        rm -f "$SRC_DIR/config.toml"
        ok "removed $SRC_DIR/config.toml"
    fi
    return 0
}

print_next_steps() {
    say ""
    say "${C_BOLD}Next steps${C_RESET}"
    print_path_step
    say "  1. Log in once — device code, approve at chatgpt.com from any device:"
    say "       cd ~/some-project && codex-sandbox login --device-auth"
    say ""
    say "  2. Daily use, from any project directory (no flag needed — autonomy"
    say "     comes from config.toml):"
    say "       codex-sandbox"
    say "       codex-sandbox --sandbox-tmux      # survives SSH drops"
    say ""
    say "  codex-sandbox --sandbox-help    for the sandbox-specific flags"
    say "  $REPO_URL"
}

main "$@"
