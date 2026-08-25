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

function Invoke-Container {
    param([string[]]$Passthrough)
    $name = "$Agent-$(Get-User)-$(Get-ProjectSlug)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    $dockerArgs = @(
        'run', '-it', '--rm',
        '--name', $name,
        '-v', "$((Get-Location).Path):/workspace"
    ) + $MountArgs + @(
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

  --sandbox-doctor                   report on image, volumes and versions
  --sandbox-upgrade [installer opts] re-run the installer to update
  --sandbox-version                  print the sandbox version
  --sandbox-help                     this message

There is no --sandbox-tmux on native Windows; for detachable sessions, run
the sandbox from WSL instead (see WINDOWS.md, Route A).

Environment:
  SANDBOX_NO_UPDATE_CHECK=1   never check upstream for a newer sandbox
"@
}

function Invoke-LauncherMain {
    $rest = @($args)
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
