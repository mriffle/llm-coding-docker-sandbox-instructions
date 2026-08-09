# Windows Setup

How to set up the Claude Code and Codex CLI Docker sandboxes from these instructions on a Windows machine. Like the main README, this is a read-along guide — you create the files on your system; nothing needs to be cloned.

The good news up front: because both agents run **inside Linux containers**, Windows only has to play host — you never install Claude Code or Codex natively on Windows at all. The images, launchers, volumes, auth flows, and security model from the main [README](README.md) apply unchanged. What this page covers is the Windows-specific plumbing: getting Docker, choosing where your files live, and two ways to run the launchers.

There are two routes. **Route A (WSL2) is strongly recommended**: you get a real Linux environment where the main README applies almost verbatim, including tmux. Route B (native PowerShell) exists if you can't or won't use WSL, at the cost of translated launcher scripts and no tmux.

---

## Route A: WSL2 (recommended)

WSL2 (Windows Subsystem for Linux) runs a genuine Linux distribution inside Windows. Docker, bash, tmux, and every command in the main README work exactly as written.

### 1. Install WSL2

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
```

This installs WSL2 with Ubuntu by default. Reboot when prompted, then open "Ubuntu" from the Start menu; on first launch it asks you to create a Linux username and password. If you installed WSL long ago, make sure you're on WSL2, not WSL1: `wsl -l -v` should show `VERSION 2` (upgrade with `wsl --set-version <distro> 2`).

### 2. Install Docker

Two options:

- **Docker Desktop for Windows** (easiest): install from docker.com, and in *Settings → Resources → WSL integration*, enable integration for your Ubuntu distro. The `docker` command then works inside your WSL terminal. Note Docker Desktop requires a paid subscription for larger companies (250+ employees or $10M+ revenue) — check your organization's licensing.
- **Docker Engine inside WSL2** (no Docker Desktop, no licensing question): install Docker's Linux packages directly in Ubuntu following the standard [Docker Engine install docs](https://docs.docker.com/engine/install/ubuntu/) for Ubuntu. Recent WSL2 supports systemd (enable via `/etc/wsl.conf` with `[boot]\nsystemd=true` if needed), so the service management works normally. Add yourself to the `docker` group: `sudo usermod -aG docker $USER`, then close and reopen the terminal.

Verify from your Ubuntu terminal:

```bash
docker run --rm hello-world
```

### 3. Keep your projects in the Linux filesystem

This is the single most important Windows-specific tip. WSL2 can see your Windows drives at `/mnt/c/...`, and it's tempting to keep projects there — **don't**. Cross-filesystem access is dramatically slower (git operations and builds can be 5–20× slower), and bind-mounting `/mnt/c` paths into containers compounds it, along with occasional file-permission and file-watching oddities.

Instead, keep repos in your WSL home directory:

```bash
cd ~
git clone <your-project>
```

You can still open these files from Windows apps: VS Code's WSL integration does this natively, and Explorer can browse to `\\wsl$\Ubuntu\home\<you>\`.

### 4. Follow the main README

From here, everything proceeds exactly as documented — you're on Linux now. Work through the main [README](README.md) from the top ("Before you start" for PATH setup, then each agent's section), creating the Dockerfiles and launcher scripts in your WSL home (`~/claude-sandbox/`, `~/codex-sandbox/`, `~/.local/bin/`) exactly as it describes.

tmux works, device-code auth flows work (open the URL in your Windows browser — same machine, no "another device" needed), and per-user volume namespacing behaves as on any Linux host. One nuance: WSL is typically single-user, so the `$USER` suffixes are less load-bearing than on a shared server — harmless to keep for consistency with the shared setup.

### WSL-specific gotchas

- **Line endings.** Create the bash scripts *inside* WSL (nano/vim in the Ubuntu terminal, or VS Code's WSL mode). If you paste them via a Windows editor that saves CRLF line endings, they break with confusing errors like `/bin/bash^M: bad interpreter` or `$'\r': command not found`. Fix an affected file with `sed -i 's/\r$//' ~/.local/bin/claude-sandbox`.
- **WSL shutdown.** WSL2 (and any tmux sessions and containers inside it) stops when Windows reboots, and WSL may auto-suspend when no terminal is open. For long-running agent sessions, keep a terminal window open, or configure `wsl.exe` keep-alive approaches; a laptop that sleeps will pause sessions regardless, same as native Linux.
- **Memory.** WSL2's VM can grow large with heavy builds. Cap it if needed with a `%UserProfile%\.wslconfig` file:
  ```ini
  [wsl2]
  memory=8GB
  ```

---

## Route B: Native Windows (PowerShell, no WSL)

Workable, but you give up tmux and the bash launchers. Docker Desktop is required (with its WSL2 *backend*, which it manages invisibly — you still don't use WSL directly in this route). Containers, volumes, and auth behave identically; only the launcher script changes.

### 1. Install Docker Desktop

Install from docker.com with default settings (WSL2 backend). Verify in PowerShell:

```powershell
docker run --rm hello-world
```

### 2. Create the Dockerfiles and build the images

Create `$HOME\claude-sandbox\Dockerfile` and `$HOME\codex-sandbox\Dockerfile` with the contents from the main README (any Windows editor is fine here — Dockerfiles are line-ending tolerant, and the bash launchers aren't used in this route). Also save the Codex `config.toml` from the README as `$HOME\codex-sandbox\config.toml`. Then:

```powershell
docker build -t claude-sandbox "$HOME\claude-sandbox"
docker build -t codex-sandbox "$HOME\codex-sandbox"
```

### 3. PowerShell launchers

Save as `claude-sandbox.ps1` somewhere convenient:

```powershell
# claude-sandbox.ps1 — run Claude Code sandboxed in the current directory.
$ErrorActionPreference = "Stop"

$ConfigVol = "claude-config-$env:USERNAME"
$LocalVol  = "claude-local-$env:USERNAME"
docker volume create $ConfigVol | Out-Null
docker volume create $LocalVol  | Out-Null

$Name = "claude-$env:USERNAME-$(Split-Path -Leaf $PWD)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"

docker run -it --rm `
  --name $Name `
  -v "${PWD}:/workspace" `
  -v "${ConfigVol}:/home/agent/.claude" `
  -v "${LocalVol}:/home/agent/.local" `
  --cap-drop=ALL `
  --security-opt=no-new-privileges `
  claude-sandbox claude @args
```

And `codex-sandbox.ps1`:

```powershell
# codex-sandbox.ps1 — run Codex CLI sandboxed in the current directory.
$ErrorActionPreference = "Stop"

$ConfigVol = "codex-config-$env:USERNAME"
docker volume create $ConfigVol | Out-Null

# Codex has no self-updater: rebuild image if npm has a newer version
# (cached no-op otherwise). Path matches the $HOME\codex-sandbox convention.
try {
  $Latest = (Invoke-RestMethod "https://registry.npmjs.org/@openai/codex/latest").version
  if ($Latest) {
    docker build -q --build-arg CODEX_VERSION=$Latest `
      -t codex-sandbox "$HOME\codex-sandbox" | Out-Null
  }
} catch { }

$Name = "codex-$env:USERNAME-$(Split-Path -Leaf $PWD)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"

docker run -it --rm `
  --name $Name `
  -v "${PWD}:/workspace" `
  -v "${ConfigVol}:/home/agent/.codex" `
  --cap-drop=ALL `
  --security-opt=no-new-privileges `
  codex-sandbox codex @args
```

To run them by name from any directory, put them in a folder on your PowerShell PATH — the Windows analogue of the README's "Before you start" section:

```powershell
mkdir "$HOME\bin" -Force
Move-Item .\claude-sandbox.ps1, .\codex-sandbox.ps1 "$HOME\bin\"
# Add to PATH permanently (takes effect in new terminals):
[Environment]::SetEnvironmentVariable("Path",
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$HOME\bin", "User")
```

You may also need to allow local scripts once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 4. Authenticate and use

Same one-time flows as the README, via the PowerShell launchers:

```powershell
cd C:\code\some-project
.\claude-sandbox.ps1                    # or just claude-sandbox.ps1 if on PATH
# follow the URL + paste-code login; then once:
claude-sandbox.ps1 --dangerously-skip-permissions   # accept the dialog

codex-sandbox.ps1 login --device-auth
docker run --rm -v "codex-config-$env:USERNAME:/cfg" `
  -v "$HOME\codex-sandbox\config.toml:/src/config.toml:ro" `
  node:24-slim sh -c "cp /src/config.toml /cfg/ && chown -R 1001:1001 /cfg"
# (the chown prevents root-owned volume contents, which break Codex's state DB;
#  1001 is the image's default agent UID — named volumes have real Linux
#  ownership even on Docker Desktop, unlike Windows bind mounts)
```

Daily use: `claude-sandbox.ps1 --dangerously-skip-permissions` / `codex-sandbox.ps1` from a project directory.

### Native-route caveats

- **Bind-mount performance.** Mounting Windows directories (`C:\...`) into Linux containers goes through a filesystem translation layer and is noticeably slower than Linux-native mounts — the same tax as `/mnt/c` in WSL, because under the hood it *is* the same mechanism. Heavy npm/cargo workloads feel it. This is the main reason Route A is recommended.
- **File ownership.** Docker Desktop papers over Linux UID/GID for Windows-mounted paths, so the README's UID-matching notes don't apply in this route — you can omit the `--build-arg UID/GID` flags and per-user image tags when building (the defaults are fine), and files created by the agent appear owned by you on the Windows side. (In Route A, follow the README's build commands as written — WSL2 is real Linux and the UID matching matters there.) Line endings in agent-created files will be LF, which modern Windows tools handle fine.
- **No tmux.** For detached long-running sessions, use Windows Terminal tabs left open, or run the session under WSL after all. There's no clean native detach/reattach equivalent.
- **`--cap-drop`/`no-new-privileges`** work as on Linux — they apply to the Linux container, which lives in Docker Desktop's VM regardless of host OS.

---

## Which route, in one sentence

If you can install WSL2, use Route A and follow the main README as if you were on Linux — it's less to maintain (no translated scripts), faster (native filesystem), and keeps tmux; use Route B only when WSL is unavailable to you (e.g., organizational restrictions on enabling it).
