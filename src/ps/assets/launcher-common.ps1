# --- shared launcher machinery (generated; see @@REPO_URL@@) ----------------

function Get-User {
    if ($env:SANDBOX_FAKE_USER) { return $env:SANDBOX_FAKE_USER }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'user'
}

function Get-SandboxHomeDir {
    if ($env:SANDBOX_FAKE_HOME) { return $env:SANDBOX_FAKE_HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $HOME
}

function Get-StateDirPath {
    if ($env:SANDBOX_STATE_DIR) { return $env:SANDBOX_STATE_DIR }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'agent-sandbox') }
    return (Join-Path (Get-SandboxHomeDir) '.agent-sandbox')
}

function Write-Note { param([string]$Text) [Console]::Error.WriteLine("sandbox: $Text") }
function Stop-Launcher { param([string]$Text) Write-Note $Text; exit 1 }

function Compare-SandboxVersion {
    param([string]$A, [string]$B)
    $pa = ($A -replace '^v', '') -split '\.'
    $pb = ($B -replace '^v', '') -split '\.'
    for ($i = 0; $i -lt 4; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [int]::TryParse($pa[$i], [ref]$x) | Out-Null }
        if ($i -lt $pb.Count) { [int]::TryParse($pb[$i], [ref]$y) | Out-Null }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# Docker demands [a-zA-Z0-9][a-zA-Z0-9_.-]* — project directories do not.
function Get-ProjectSlug {
    $leaf = Split-Path -Leaf (Get-Location).Path
    if (-not $leaf) { $leaf = 'root' }
    return ($leaf -replace '[^a-zA-Z0-9_.-]', '-')
}

function Assert-DockerAndImage {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-Launcher "docker is not installed or not on PATH — see $RepoUrl"
    }
    & docker image inspect $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Launcher "cannot reach the docker daemon — is Docker Desktop running?"
    }
    Write-Note "image $Image does not exist."
    Write-Note "install it with:  irm $RawBase/install/$Agent.ps1 | iex"
    exit 1
}

# At most one network call per day, silent when offline, and the timestamp is
# written before the request so a flaky network cannot stall every launch.
function Test-SandboxUpdate {
    if ($env:SANDBOX_NO_UPDATE_CHECK) { return }
    $dir = Get-StateDirPath
    $cache = Join-Path $dir "$Agent.lastcheck"
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if (Test-Path -LiteralPath $cache) {
            $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
            if ($age.TotalHours -lt 24) { return }
        }
        Set-Content -LiteralPath $cache -Value '' -NoNewline
        if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return }
        elseif ($env:SANDBOX_FAKE_UPSTREAM) { $latest = $env:SANDBOX_FAKE_UPSTREAM }
        else { $latest = ("$(Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 2 -ErrorAction Stop)".Trim() -split "`n")[0].Trim() }
        if ($latest -and (Compare-SandboxVersion $latest $SandboxVersion) -gt 0) {
            Write-Note "v$latest of the sandbox is available (you have v$SandboxVersion)"
            Write-Note "upgrade with: $LauncherName --sandbox-upgrade"
        }
    } catch { return }
}

# --- git -------------------------------------------------------------------
# The mirror of git_env_args in the shell launcher; same environment, same
# host-scoped credential helper, no new mounts. See that file for why
# GIT_CONFIG_* is used rather than GIT_AUTHOR_*.

# Single-quoted on purpose: these expand in the container's shell.
$GitCredHelper = '!f(){ test "$1" = get && printf "username=%s\npassword=%s\n" "$SANDBOX_GIT_USER" "$SANDBOX_GIT_TOKEN"; }; f'

function Get-GitConfigValue {
    param([string]$Key)
    # `git config --get` exits 1 for an unset key; that is normal, not an error.
    $v = (& git config --get $Key 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

# The origin's host, https only — an ssh remote never consults a helper.
function Get-GitOriginHost {
    $url = (& git config --get remote.origin.url 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $url) { return '' }
    if ($url -notmatch '^https?://') { return '' }
    $rest = $url -replace '^https?://', ''
    $hostPart = ($rest -split '/')[0]
    return ($hostPart -replace '^.*@', '')
}

# Returns @(user, token), or @() when nothing is available.
function Get-GitCredential {
    param([string]$GitHost)
    $envToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($GitHost -eq 'github.com' -and $envToken) { return @('x-access-token', $envToken) }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = (& gh auth token --hostname $GitHost 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $t) { return @('x-access-token', $t) }
    }

    # The host's own store answers — on Windows that is usually Git Credential
    # Manager. GIT_TERMINAL_PROMPT=0 keeps a missing credential from turning the
    # launch into a hang.
    $prev = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $out = ("protocol=https`nhost=$GitHost`n`n" | & git credential fill 2>$null | Out-String)
    } catch { $out = '' } finally { $env:GIT_TERMINAL_PROMPT = $prev }

    $u = ''; $p = ''
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -like 'username=*') { $u = $line.Substring(9) }
        elseif ($line -like 'password=*') { $p = $line.Substring(9) }
    }
    if ($p) { return @($u, $p) }
    return @()
}

function Get-GitEnvArgs {
    # Always an array, never $null: `@(...) + $null` inserts a phantom element.
    $envArgs = @()
    if ($env:SANDBOX_NO_GIT) { return $envArgs }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $envArgs }

    $n = 0
    foreach ($pair in @(@('user.name', (Get-GitConfigValue 'user.name')),
                        @('user.email', (Get-GitConfigValue 'user.email')))) {
        # An empty value must never reach the array — `-e ''` becomes a real,
        # malformed argv entry.
        if ($pair[1]) {
            $envArgs += @('-e', "GIT_CONFIG_KEY_$n=$($pair[0])", '-e', "GIT_CONFIG_VALUE_$n=$($pair[1])")
            $n++
        }
    }

    if ($script:SandboxGit) {
        $gitHost = Get-GitOriginHost
        if (-not $gitHost) {
            Write-Note "--sandbox-git: no https remote here; nothing to forward"
        } else {
            $cred = Get-GitCredential $gitHost
            if ($cred.Count -eq 2) {
                $envArgs += @('-e', "SANDBOX_GIT_USER=$($cred[0])", '-e', "SANDBOX_GIT_TOKEN=$($cred[1])")
                $envArgs += @('-e', "GIT_CONFIG_KEY_$n=credential.https://$gitHost.helper",
                              '-e', "GIT_CONFIG_VALUE_$n=$GitCredHelper")
                $n++
            } else {
                Write-Note "--sandbox-git: no credential stored for $gitHost; pushing will fail"
            }
        }
    }

    if ($n -gt 0) { $envArgs += @('-e', "GIT_CONFIG_COUNT=$n") }
    return ,$envArgs
}

function Invoke-Container {
    param([string[]]$Passthrough)
    $name = "$Agent-$(Get-User)-$(Get-ProjectSlug)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    $dockerArgs = @(
        'run', '-it', '--rm',
        '--name', $name,
        '-v', "$((Get-Location).Path):/workspace"
    ) + $MountArgs + @(Get-GitEnvArgs) + @(
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        $Image, $AgentBin
    ) + $Passthrough
    & docker @dockerArgs
    exit $LASTEXITCODE
}

# Overridden by codex-sandbox.ps1, which has no self-updater to lean on.
function Invoke-PreRun { }

function Show-Doctor {
    Write-Host "$AgentName sandbox — doctor"
    Write-Host "  launcher version    $SandboxVersion"
    Write-Host "  user                $(Get-User)"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "  docker              NOT INSTALLED"; return
    }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  docker              UNREACHABLE"; return }
    Write-Host "  docker              ok"

    & docker image inspect $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $built = (& docker image inspect -f '{{index .Config.Labels "sandbox.installer_version"}}' $Image 2>&1 | Out-String).Trim()
        Write-Host "  image               $Image"
        Write-Host "  image built by      installer v$built"
    } else {
        Write-Host "  image               MISSING ($Image)"
    }

    foreach ($v in $Volumes) {
        & docker volume inspect $v 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  volume $v ok" }
        else { Write-Host "  volume $v MISSING" }
    }

    $manifest = Join-Path (Get-StateDirPath) "$Agent.manifest"
    if (Test-Path -LiteralPath $manifest) { Write-Host "  manifest            $manifest" }
    else { Write-Host "  manifest            missing (installed by hand?)" }

    # Availability only — the credential itself is never printed.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "  git                 NOT INSTALLED on this host"
    } else {
        $n = Get-GitConfigValue 'user.name'
        $e = Get-GitConfigValue 'user.email'
        if ($n -or $e) {
            $nn = if ($n) { $n } else { '?' }
            $ee = if ($e) { $e } else { '?' }
            Write-Host "  git identity        $nn <$ee>"
        } else {
            Write-Host "  git identity        NONE configured — commits will fail"
        }
        $gitHost = Get-GitOriginHost
        if (-not $gitHost) {
            Write-Host "  git credential      no https remote here"
        } elseif ((Get-GitCredential $gitHost).Count -eq 2) {
            Write-Host "  git credential      available for $gitHost — forward with --sandbox-git"
        } else {
            Write-Host "  git credential      none stored for $gitHost"
        }
    }

    try {
        if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return }
        $latest = if ($env:SANDBOX_FAKE_UPSTREAM) { $env:SANDBOX_FAKE_UPSTREAM }
                  else { ("$(Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 3 -ErrorAction Stop)".Trim() -split "`n")[0].Trim() }
        if ($latest -and (Compare-SandboxVersion $latest $SandboxVersion) -gt 0) {
            Write-Host "  upstream            v$latest available — $LauncherName --sandbox-upgrade"
        } elseif ($latest) {
            Write-Host "  upstream            up to date"
        }
    } catch { }
}

function Invoke-Upgrade {
    param([string[]]$Passthrough)
    Write-Note "fetching the latest installer from $RawBase"
    $script = Invoke-RestMethod -Uri "$RawBase/install/$Agent.ps1"
    & ([scriptblock]::Create($script)) @Passthrough
    exit $LASTEXITCODE
}

function Show-LauncherUsage {
    Write-Host @"
$LauncherName — run $AgentName sandboxed in the current directory (v$SandboxVersion)

  $LauncherName [agent arguments...]

Everything is passed through to $AgentBin untouched, except these flags,
which are only recognised in first position:

  --sandbox-git [args...]            also forward a git credential (see below)
  --sandbox-doctor                   report on image, volumes and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

Your git name and email are always passed through, so the agent can commit.
--sandbox-git additionally forwards a credential for the origin remote's host,
so it can push. That credential is scoped to that one host, but within it the
token's own permissions apply — prefer a fine-grained one.

There is no --sandbox-tmux on native Windows; for detachable sessions, run
the sandbox from WSL instead (see WINDOWS.md, Route A).

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
  SANDBOX_NO_GIT=1            pass no git identity or credential at all
  SANDBOX_GIT=1               same as --sandbox-git
"@
}

function Invoke-LauncherMain {
    $rest = @($args)
    # Consumed before the dispatch below, so --sandbox-git composes with the
    # other flags and still only counts in first position.
    $script:SandboxGit = [bool]$env:SANDBOX_GIT
    if ($rest.Count -gt 0 -and $rest[0] -eq '--sandbox-git') {
        $script:SandboxGit = $true
        $rest = @($rest | Select-Object -Skip 1)
    }
    $first = if ($rest.Count -gt 0) { $rest[0] } else { '' }
    switch ($first) {
        '--sandbox-help'    { Show-LauncherUsage; exit 0 }
        '--sandbox-version' { Write-Host $SandboxVersion; exit 0 }
        '--sandbox-doctor'  { Show-Doctor; exit 0 }
        '--sandbox-upgrade' { Invoke-Upgrade -Passthrough @($rest | Select-Object -Skip 1) }
    }
    Assert-DockerAndImage
    Test-SandboxUpdate
    Invoke-PreRun
    Invoke-Container -Passthrough $rest
}
