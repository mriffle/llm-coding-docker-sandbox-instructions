#!/usr/bin/env bash
#
# Claude Code sandbox installer.
#
#   curl -fsSL @@RAW_BASE@@/install/claude.sh | bash
#
# Creates ~/claude-sandbox/Dockerfile, ~/.local/bin/claude-sandbox, a per-user
# image, and the named volumes that hold your login. Re-run it to upgrade.
set -euo pipefail

INSTALLER_VERSION="@@VERSION@@"
RAW_BASE="@@RAW_BASE@@"
REPO_URL="@@REPO_URL@@"

AGENT=claude
AGENT_NAME="Claude Code"
LAUNCHER_NAME=claude-sandbox
IMAGE_BASENAME=claude-sandbox
SRC_DIR_DEFAULT="$HOME/claude-sandbox"
VOLUME_BASENAMES="claude-config claude-local"

# @include lib/common.sh

# @embed assets/claude.Dockerfile AS ASSET_DOCKERFILE
# @embed assets/claude-sandbox AS ASSET_LAUNCHER

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
