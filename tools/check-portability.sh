#!/usr/bin/env bash
#
# check-portability.sh — guard against constructs macOS's bash 3.2 (and the
# BSD userland) cannot handle. The macOS CI job runs the real suite under
# /bin/bash; this catches the same class of problem locally, where no bash 3.2
# is available to run against.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rc=0

# Each entry: <name>|<ERE>|<why it breaks>
CHECKS='
associative arrays|declare[[:space:]]+-A|bash 4.0+ only
lowercase expansion|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|bash 4.0+ only
mapfile/readarray|\b(mapfile|readarray)\b|bash 4.0+ only
nameref locals|local[[:space:]]+-n\b|bash 4.3+ only
append-both redirect|&>>|bash 4.0+ only
sed in place|sed[[:space:]]+-i[[:space:]]|GNU and BSD sed disagree on -i
readlink -f|readlink[[:space:]]+-f|not available on macOS
GNU stat|stat[[:space:]]+-c|BSD stat uses -f
sha256sum without fallback|sha256sum|must be feature-detected against shasum
'

targets() {
    printf '%s\n' "$ROOT/install/claude.sh" "$ROOT/install/codex.sh"
    printf '%s\n' "$ROOT/src/lib/common.sh" "$ROOT/src/assets/launcher-common.sh"
    printf '%s\n' "$ROOT/src/assets/claude-sandbox" "$ROOT/src/assets/codex-sandbox"
    # The harness runs on macOS in CI too — a GNU-only call here fails the job
    # just as surely as one in the product.
    printf '%s\n' "$ROOT/tests/helper.bash"
    find "$ROOT/tests" -name '*.bats' 2>/dev/null
}

printf 'portability: checking for bash 4 / GNU-only constructs\n'
while IFS='|' read -r name pattern why; do
    [ -n "${name:-}" ] || continue
    hits=''
    while IFS= read -r f; do
        # Lines that already feature-detect (`have sha256sum`, `stat -c ... || stat -f`)
        # and comments are not findings.
        # A line is fine when it already feature-detects (pairs the GNU form
        # with the BSD one, or guards on `command -v` / `have`), when the call
        # runs *inside a container* (always Linux, whatever the host is), or
        # when it merely names both tools — e.g. a list of binaries to link.
        found=$(grep -nE "$pattern" "$f" 2>/dev/null \
                | grep -vE '^\s*[0-9]+:\s*#' \
                | grep -vE 'have (sha256sum|shasum)|command -v (sha256sum|shasum)' \
                | grep -vE 'stat -c[^|]*\|\|[^|]*stat -f' \
                | grep -v 'docker run' \
                | grep -vE 'shasum' || true)
        [ -n "$found" ] && hits="$hits
  ${f#"$ROOT"/}: $found"
    done <<< "$(targets)"
    if [ -n "$hits" ]; then
        printf '  FAIL %s (%s)%s\n' "$name" "$why" "$hits"
        rc=1
    else
        printf '  ok   no %s\n' "$name"
    fi
done <<< "$CHECKS"

# The grep rules above are heuristics. This is the real thing: parse the
# generated installers with an actual bash 3.2, the version macOS still ships.
# It is what caught `$(cat <<EOF ...)` — a here-document nested in command
# substitution, which bash 3.2 mis-parses and which no pattern above would flag.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for f in "$ROOT"/install/*.sh; do
        rel=${f#"$ROOT"/}
        if out=$(docker run --rm -v "$ROOT:/work:ro" bash:3.2 bash -n "/work/$rel" 2>&1); then
            printf '  ok   %s parses under bash 3.2\n' "$rel"
        else
            printf '  FAIL %s does not parse under bash 3.2\n%s\n' "$rel" "$out"
            rc=1
        fi
    done
else
    printf '  skip bash 3.2 parse check (needs a reachable docker daemon)\n'
fi

exit $rc
