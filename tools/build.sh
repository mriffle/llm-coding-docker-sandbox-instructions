#!/usr/bin/env bash
#
# build.sh — assemble the single-file installers in install/ from src/.
#
# A script delivered by `curl … | bash` cannot source a sibling file, so the
# shared library and the embedded assets are inlined here instead. Two
# directives, both valid comments in their host language:
#
#   # @include <path>            splice the file in verbatim (recursive)
#   # @embed <path> AS <NAME>    define NAME as the file's contents
#
# @@VERSION@@ / @@RAW_BASE@@ / @@REPO_URL@@ are substituted everywhere.
#
#   tools/build.sh          rebuild install/
#   tools/build.sh --check  fail if install/ is stale (what CI runs)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/src"
OUT="$ROOT/install"
VERSION=$(tr -d ' \r\n' < "$ROOT/VERSION")
REPO_URL=${REPO_URL:-https://github.com/mriffle/llm-coding-docker-sandbox-instructions}
RAW_BASE=${RAW_BASE:-https://raw.githubusercontent.com/mriffle/llm-coding-docker-sandbox-instructions/main}

BASH_EOF_TAG='__SANDBOX_ASSET_EOF__'
LANG_KIND="sh"

die() { printf 'build: %s\n' "$*" >&2; exit 1; }

emit_embed_sh() {
    local name=$1 body=$2
    case "$body" in
        *"$BASH_EOF_TAG"*) die "asset for $name contains the heredoc delimiter $BASH_EOF_TAG" ;;
    esac
    # shellcheck disable=SC2016  # emitting a literal command substitution
    printf '%s=$(cat <<%s%s%s\n' "$name" "'" "$BASH_EOF_TAG" "'"
    printf '%s\n' "$body"
    printf '%s\n)\n' "$BASH_EOF_TAG"
}

emit_embed_ps() {
    local name=$1 body=$2
    # A single-quoted PowerShell here-string ends at a line that begins with '@
    if printf '%s\n' "$body" | grep -q "^'@"; then
        die "asset for $name contains a line starting with '@, which closes a here-string"
    fi
    printf "$%s = @'\n" "$name"
    printf '%s\n' "$body"
    printf "'@\n"
}

# Recursively expand directives in $1.
expand() {
    local file=$1 line path name body
    [ -f "$file" ] || die "no such file: $file"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '# @include '*)
                path=${line#\# @include }
                expand "$SRC/${path% }"
                ;;
            '# @embed '*)
                path=${line#\# @embed }
                name=${path##* AS }
                path=${path%% AS *}
                body=$(expand "$SRC/$path")
                if [ "$LANG_KIND" = ps ]; then emit_embed_ps "$name" "$body"
                else emit_embed_sh "$name" "$body"; fi
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done < "$file"
}

banner() {
    local comment=$1
    cat <<BANNER
$comment
$comment  THIS FILE IS GENERATED — do not edit it directly.
$comment  Source: src/, assembled by tools/build.sh. Edit there and rebuild.
$comment  Version $VERSION
$comment
BANNER
}

substitute() {
    sed -e "s|@@VERSION@@|$VERSION|g" \
        -e "s|@@RAW_BASE@@|$RAW_BASE|g" \
        -e "s|@@REPO_URL@@|$REPO_URL|g"
}

build_one() {
    local in=$1 out=$2 comment mode first rest
    case "$out" in
        *.ps1) LANG_KIND="ps"; comment='#'; mode=644 ;;
        *)     LANG_KIND="sh"; comment='#'; mode=755 ;;
    esac
    first=$(head -1 "$in")
    rest=$(mktemp)
    {
        printf '%s\n' "$first"
        banner "$comment"
        expand "$in" | tail -n +2
    } | substitute > "$rest"
    mkdir -p "$(dirname "$out")"
    install -m "$mode" "$rest" "$out" 2>/dev/null || { cp "$rest" "$out"; chmod "$mode" "$out"; }
    rm -f "$rest"
    printf '  %-24s %5s lines\n' "${out#"$ROOT"/}" "$(wc -l < "$out" | tr -d ' ')"
}

build_all() {
    printf 'building v%s -> %s\n' "$VERSION" "${1:-$OUT}"
    local dest=${1:-$OUT}
    build_one "$SRC/claude.sh" "$dest/claude.sh"
    build_one "$SRC/codex.sh"  "$dest/codex.sh"
    if [ -f "$SRC/ps/claude.ps1" ]; then
        build_one "$SRC/ps/claude.ps1" "$dest/claude.ps1"
        build_one "$SRC/ps/codex.ps1"  "$dest/codex.ps1"
    fi
}

if [ "${1:-}" = "--check" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    build_all "$tmp" >/dev/null
    rc=0
    for f in "$tmp"/*; do
        base=$(basename "$f")
        if ! cmp -s "$f" "$OUT/$base"; then
            printf 'build: install/%s is stale — run tools/build.sh\n' "$base" >&2
            rc=1
        fi
    done
    [ "$rc" -eq 0 ] && printf 'build: install/ is up to date\n'
    exit $rc
fi

build_all
