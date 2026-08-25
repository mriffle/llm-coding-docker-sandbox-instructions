#!/usr/bin/env bash
#
# test.sh — the whole suite, in tiers.
#
#   [build] install/ matches src/
#   [lint]  shellcheck over every shell script; pwsh parse + PSScriptAnalyzer
#   [unit]  src/lib/common.sh functions in isolation
#   [intg]  the built installers and launchers against a scripted fake docker
#   [e2e]   real docker: real images, real UIDs, real volumes
#
# Tiers whose tools are missing are skipped loudly, never silently. Vendor the
# tools first with tools/fetch-tools.sh (no root required).
#
#   tools/test.sh              # everything available
#   tools/test.sh lint unit    # only these tiers
#   tools/test.sh --no-e2e     # skip the slow tier even if docker is up
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/.bin"
export PATH="$BIN:$PATH"
cd "$ROOT" || exit 1

FAILED=0
SKIPPED=''
RUN_TIERS='build lint unit intg e2e'
NO_E2E=''

for arg in "$@"; do
    case "$arg" in
        --no-e2e) NO_E2E=1 ;;
        build|lint|unit|intg|e2e) [ "$RUN_TIERS" = 'build lint unit intg e2e' ] && RUN_TIERS=''; RUN_TIERS="$RUN_TIERS $arg" ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) printf 'test: unknown argument: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

wants() { case " $RUN_TIERS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
head_of() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; SKIPPED="$SKIPPED
  - $*"; }

have() { command -v "$1" >/dev/null 2>&1; }
pwsh_bin() { if [ -x "$BIN/pwsh" ]; then printf '%s' "$BIN/pwsh"; elif have pwsh; then printf 'pwsh'; fi; }

# The launchers live inside the installers as embedded strings; extract them
# so shellcheck sees the same text a user ends up running.
extract_launchers() {
    mkdir -p "$ROOT/.tmp/lint"
    local agent
    for agent in claude codex; do
        # Assets are embedded as `__asset_NAME() { cat <<EOF ... EOF }` — a
        # function body, because bash 3.2 cannot parse a heredoc inside $( ).
        sed -n "/^__asset_ASSET_LAUNCHER() {\$/,/^__SANDBOX_ASSET_EOF__\$/p" \
            "$ROOT/install/$agent.sh" | sed '1,2d;$d' > "$ROOT/.tmp/lint/$agent-sandbox"
        [ -s "$ROOT/.tmp/lint/$agent-sandbox" ] || return 1
    done
}

# --- build -----------------------------------------------------------------

if wants build; then
    head_of build "install/ is generated from src/"
    if "$ROOT/tools/build.sh" --check >/dev/null 2>&1; then
        pass "install/ matches a fresh build"
    else
        bad "install/ is stale — run tools/build.sh and commit the result"
    fi
fi

# --- lint ------------------------------------------------------------------

if wants lint; then
    head_of lint "static analysis"

    for f in "$ROOT"/install/*.sh "$ROOT"/tools/*.sh "$ROOT"/tests/fixtures/fakebin/*; do
        [ -f "$f" ] || continue
        case "$f" in *.ps1) continue ;; esac
        if bash -n "$f" 2>/dev/null; then :; else bad "bash -n: ${f#"$ROOT"/}"; fi
    done
    pass "bash -n over every shell script"

    if have shellcheck; then
        if extract_launchers; then
            if shellcheck --severity=style \
                 "$ROOT"/install/*.sh "$ROOT"/tools/*.sh \
                 "$ROOT"/tests/fixtures/fakebin/docker \
                 "$ROOT"/tests/fixtures/fakebin/curl \
                 "$ROOT"/tests/fixtures/fakebin/tmux \
                 "$ROOT"/tests/fixtures/fakebin/wsl.exe \
                 "$ROOT"/tests/fixtures/fakebin/git \
                 "$ROOT"/tests/fixtures/fakebin/gh \
                 "$ROOT"/.tmp/lint/claude-sandbox "$ROOT"/.tmp/lint/codex-sandbox; then
                pass "shellcheck (installers, launchers, tools, fixtures)"
            else
                bad "shellcheck reported findings"
            fi
            if shellcheck --severity=style --shell=bash \
                 "$ROOT"/src/lib/common.sh "$ROOT"/src/assets/launcher-common.sh; then
                pass "shellcheck (shared fragments)"
            else
                bad "shellcheck reported findings in src/"
            fi
        else
            bad "could not extract the embedded launchers for linting"
        fi
    else
        skip "shellcheck not vendored (tools/fetch-tools.sh)"
    fi

    if "$ROOT/tools/check-portability.sh" >/dev/null 2>&1; then
        pass "portability (bash 3.2 / BSD userland)"
    else
        "$ROOT/tools/check-portability.sh" || true
        bad "portability check reported findings"
    fi

    PWSH=$(pwsh_bin)
    if [ -n "$PWSH" ]; then
        # shellcheck disable=SC2016  # PowerShell variables, not shell ones
        if "$PWSH" -NoProfile -Command '
            $bad = 0
            foreach ($f in Get-ChildItem -Path install,src -Recurse -Filter *.ps1) {
                $errs = $null
                [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
                if ($errs) { $bad = 1; Write-Host "$($f.FullName):"; $errs | ForEach-Object { Write-Host "  $($_.Message)" } }
            }
            exit $bad' ; then
            pass "pwsh parses every .ps1"
        else
            bad "PowerShell parse errors"
        fi

        "$PWSH" -NoProfile -Command "
            \$env:PSModulePath = '$BIN/psmodules' + [IO.Path]::PathSeparator + \$env:PSModulePath
            if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 99 }
            Import-Module PSScriptAnalyzer
            \$r = Invoke-ScriptAnalyzer -Path '$ROOT/install' -Recurse -Settings '$ROOT/tools/pssa-settings.psd1'
            if (\$r) { \$r | Format-Table RuleName,Line,ScriptName,Message -AutoSize | Out-String -Width 200; exit 1 }
            exit 0"
        pssa_rc=$?
        case "$pssa_rc" in
            0)  pass "PSScriptAnalyzer" ;;
            99) skip "PSScriptAnalyzer not installed (see tools/fetch-tools.sh)" ;;
            *)  bad "PSScriptAnalyzer reported findings" ;;
        esac
    else
        skip "pwsh not vendored (tools/fetch-tools.sh --with-pwsh)"
    fi
fi

# --- unit / integration / e2e ----------------------------------------------

run_bats() {
    local label=$1 dir=$2
    if ! have bats; then skip "$label: bats not vendored (tools/fetch-tools.sh)"; return; fi
    # Two guards, both learned the hard way:
    #   </dev/null  — with stdin left as an inherited pipe, bats can finish every
    #                 test and then block instead of exiting.
    #   timeout     — and when it does block, an unguarded run wedges a CI job
    #                 until the six-hour limit. Fail loudly instead. `timeout`
    #                 is GNU-only, so fall back to a plain run where it is absent.
    local limit=${SANDBOX_TEST_TIMEOUT:-1800}
    local rc
    if have timeout; then
        timeout --foreground -k 30 "$limit" bats "$dir" </dev/null
        rc=$?
        if [ "$rc" -eq 124 ]; then
            bad "$label: no result after ${limit}s — treating as failure"
            return
        fi
    else
        bats "$dir" </dev/null
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then pass "$label"; else bad "$label"; fi
}

if wants unit; then
    head_of unit "src/lib/common.sh in isolation"
    run_bats "unit tests" "$ROOT/tests/unit"
fi

if wants intg; then
    head_of intg "installers and launchers against a fake docker"
    run_bats "integration tests" "$ROOT/tests/integration"
fi

if wants e2e; then
    head_of e2e "real docker"
    if [ -n "$NO_E2E" ]; then
        skip "e2e: --no-e2e given"
    elif ! have docker; then
        skip "e2e: docker is not installed"
    elif ! docker info >/dev/null 2>&1; then
        skip "e2e: no reachable docker daemon (on WSL, enable Docker Desktop's WSL integration)"
    else
        run_bats "e2e tests" "$ROOT/tests/e2e"
    fi
fi

# --- summary ---------------------------------------------------------------

printf '\n'
if [ -n "$SKIPPED" ]; then
    printf '\033[33mSkipped:\033[0m%s\n\n' "$SKIPPED"
fi
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mAll executed tiers passed.\033[0m\n'
    exit 0
fi
printf '\033[31mSome tiers failed.\033[0m\n'
exit 1
