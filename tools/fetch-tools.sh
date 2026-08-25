#!/usr/bin/env bash
#
# fetch-tools.sh — vendor the test toolchain into ./.bin without root.
#
# Deliberately mirrors the convention this repo recommends to its own users:
# occasional-use tools live in the project directory, never in the image and
# never behind `sudo apt-get`. Everything here is optional — tools/test.sh
# skips the tiers whose tools are missing and says so.
#
#   tools/fetch-tools.sh            # shellcheck + bats (+ pwsh if asked)
#   tools/fetch-tools.sh --with-pwsh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/.bin"
TMP="$ROOT/.tmp/fetch"

SHELLCHECK_VERSION=0.10.0
BATS_VERSION=1.11.0
PWSH_VERSION=7.4.6

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'fetch-tools: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Trust-on-first-use is not a security model. Pins live in tools/tool-pins.txt
# ("<sha256>  <basename>"); a downloaded file whose hash is absent from that
# file is reported so it can be reviewed and pinned, and a file whose hash
# *disagrees* is a hard failure.
PINS="$ROOT/tools/tool-pins.txt"
verify_pin() {
    local file=$1 base sum want
    base=$(basename "$file")
    sum=$(sha256_of "$file")
    if [ -f "$PINS" ] && want=$(grep -E "  $base\$" "$PINS" 2>/dev/null | head -1 | cut -d' ' -f1) && [ -n "$want" ]; then
        [ "$sum" = "$want" ] || die "checksum mismatch for $base
  expected $want
  got      $sum"
        say "  verified $base"
    else
        say "  WARNING: $base is not pinned. Add this line to tools/tool-pins.txt:"
        say "    $sum  $base"
    fi
}

fetch() {
    local url=$1 dest=$2
    say "  downloading $(basename "$dest")"
    if have curl; then curl -fsSL --retry 2 -o "$dest" "$url"
    elif have wget; then wget -qO "$dest" "$url"
    else die "need curl or wget"; fi
}

platform() {
    local os arch
    os=$(uname -s); arch=$(uname -m)
    case "$os" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "unsupported OS: $os" ;; esac
    case "$arch" in x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=aarch64 ;; *) die "unsupported arch: $arch" ;; esac
    printf '%s %s' "$os" "$arch"
}

install_shellcheck() {
    local os arch url tar
    read -r os arch <<<"$(platform)"
    if [ -x "$BIN/shellcheck" ] && "$BIN/shellcheck" --version 2>/dev/null | grep -q "$SHELLCHECK_VERSION"; then
        say "  shellcheck $SHELLCHECK_VERSION already vendored"; return 0
    fi
    url="https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.$os.$arch.tar.xz"
    tar="$TMP/shellcheck-v$SHELLCHECK_VERSION.$os.$arch.tar.xz"
    fetch "$url" "$tar"
    verify_pin "$tar"
    tar -xJf "$tar" -C "$TMP"
    install -m 755 "$TMP/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$BIN/shellcheck"
    say "  shellcheck -> .bin/shellcheck"
}

install_bats() {
    local url tar
    if [ -x "$BIN/bats" ] && "$BIN/bats" --version 2>/dev/null | grep -q "$BATS_VERSION"; then
        say "  bats $BATS_VERSION already vendored"; return 0
    fi
    url="https://github.com/bats-core/bats-core/archive/refs/tags/v$BATS_VERSION.tar.gz"
    tar="$TMP/bats-core-$BATS_VERSION.tar.gz"
    fetch "$url" "$tar"
    verify_pin "$tar"
    tar -xzf "$tar" -C "$TMP"
    rm -rf "$BIN/bats-core"
    mv "$TMP/bats-core-$BATS_VERSION" "$BIN/bats-core"
    ln -sf "bats-core/bin/bats" "$BIN/bats"
    say "  bats -> .bin/bats"
}

# PSScriptAnalyzer comes from the PowerShell Gallery, so it needs pwsh first.
install_pssa() {
    local dest="$BIN/psmodules"
    if [ -d "$dest/PSScriptAnalyzer" ]; then say "  PSScriptAnalyzer already vendored"; return 0; fi
    local pwsh_bin="$BIN/pwsh"
    have "$pwsh_bin" || pwsh_bin=$(command -v pwsh 2>/dev/null || true)
    if [ -z "$pwsh_bin" ] || [ ! -x "$pwsh_bin" ]; then
        say "  skipping PSScriptAnalyzer (no pwsh)"; return 0
    fi
    mkdir -p "$dest"
    if "$pwsh_bin" -NoProfile -Command "Save-Module -Name PSScriptAnalyzer -Path '$dest' -Repository PSGallery -ErrorAction Stop" 2>/dev/null; then
        say "  PSScriptAnalyzer -> .bin/psmodules"
    else
        say "  WARNING: could not fetch PSScriptAnalyzer; that lint tier will be skipped"
    fi
}

install_pwsh() {
    local os arch url tar dir
    read -r os arch <<<"$(platform)"
    if [ -x "$BIN/pwsh" ]; then say "  pwsh already vendored"; return 0; fi
    case "$os-$arch" in
        linux-x86_64)  dir=linux-x64 ;;
        linux-aarch64) dir=linux-arm64 ;;
        darwin-x86_64) dir=osx-x64 ;;
        darwin-aarch64) dir=osx-arm64 ;;
        *) die "no pwsh build for $os-$arch" ;;
    esac
    url="https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-$dir.tar.gz"
    tar="$TMP/powershell-$PWSH_VERSION-$dir.tar.gz"
    fetch "$url" "$tar"
    verify_pin "$tar"
    rm -rf "$BIN/powershell"; mkdir -p "$BIN/powershell"
    tar -xzf "$tar" -C "$BIN/powershell"
    chmod +x "$BIN/powershell/pwsh"
    ln -sf "powershell/pwsh" "$BIN/pwsh"
    say "  pwsh -> .bin/pwsh"
}

mkdir -p "$BIN" "$TMP"
say "vendoring test tools into .bin/"
install_shellcheck
install_bats
case "${1:-}" in --with-pwsh) install_pwsh; install_pssa ;; esac
rm -rf "$TMP"
say "done. Add to PATH for this shell:  export PATH=\"$BIN:\$PATH\""
