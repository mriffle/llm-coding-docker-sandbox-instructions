# ---------------------------------------------------------------------------
# lib.ps1 — shared helpers for the native-Windows sandbox installers.
#
# Mirrors src/lib/common.sh. Differences that matter on this route: Docker
# Desktop papers over Linux file ownership for Windows bind mounts, so no
# UID/GID build args; and WSL2 is a hard prerequisite because it is the
# engine Docker Desktop runs Linux containers on.
#
# Test seams: SANDBOX_FAKE_HOME, SANDBOX_FAKE_PLATFORM, SANDBOX_FAKE_USER.
# ---------------------------------------------------------------------------

$script:ExitMissingDocker = 10
$script:ExitDockerUnreachable = 11
$script:ExitNoWsl = 12
$script:ExitUnsupported = 78

# ---- output ---------------------------------------------------------------

function Say  { param([string]$Text = '') if (-not $script:Quiet) { [Console]::Error.WriteLine($Text) } }
function Step { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("==> $Text") } }
function Ok   { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("  $Text") } }
function Info { param([string]$Text) if (-not $script:Quiet) { [Console]::Error.WriteLine("  $Text") } }
function Warn { param([string]$Text) [Console]::Error.WriteLine("warning: $Text") }
function Oops { param([string]$Text) [Console]::Error.WriteLine("error: $Text") }

# Numbered remediation list; an empty string emits a separator.
function Remedy {
    param([string[]]$Steps)
    Say ''
    [Console]::Error.WriteLine('How to fix:')
    $n = 0
    foreach ($s in $Steps) {
        if ([string]::IsNullOrEmpty($s)) { [Console]::Error.WriteLine('') }
        else { $n++; [Console]::Error.WriteLine(("  {0}. {1}" -f $n, $s)) }
    }
    Say ''
}

function Fail { param([string]$Text, [int]$Code = 1) Oops $Text; exit $Code }

function Test-HaveCommand { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ---- identity and paths ---------------------------------------------------

function Get-SandboxHome {
    if ($env:SANDBOX_FAKE_HOME) { return $env:SANDBOX_FAKE_HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return $HOME
}

function Get-SandboxUser {
    if ($env:SANDBOX_FAKE_USER) { return $env:SANDBOX_FAKE_USER }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'user'
}

function Get-StateDir {
    if ($env:SANDBOX_STATE_DIR) { return $env:SANDBOX_STATE_DIR }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'agent-sandbox') }
    return (Join-Path (Get-SandboxHome) '.agent-sandbox')
}

function Get-ManifestPath { Join-Path (Get-StateDir) "$script:Agent.manifest" }

# ---- hashing and atomic writes -------------------------------------------

function Get-StringSha256 {
    param([string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

# The hash an embedded asset will have once written: Write-AtomicText appends
# exactly one newline, so the raw string would never match the file.
function Get-AssetSha { param([string]$Content) Get-StringSha256 ($Content + "`n") }

function Get-FileSha {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# LF endings and no BOM: these files are read by Linux containers.
function Write-AtomicText {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Path.tmp$([System.IO.Path]::GetRandomFileName())"
    $text = ($Content -replace "`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllBytes($tmp, [System.Text.UTF8Encoding]::new($false).GetBytes($text))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Backup-File {
    param([string]$Path)
    $bak = "$Path.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    return $bak
}

# ---- platform preflight ---------------------------------------------------

function Test-IsWindows {
    if ($env:SANDBOX_FAKE_PLATFORM) { return $env:SANDBOX_FAKE_PLATFORM -eq 'windows' }
    if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { return $IsWindows }
    return $true   # Windows PowerShell 5.1 has no $IsWindows
}

function Assert-Windows {
    if (Test-IsWindows) { return }
    Oops "This installer is for native Windows."
    Remedy @(
        "On Linux, macOS or inside WSL, use the shell installer instead:",
        "   curl -fsSL $script:RawBase/install/$script:Agent.sh | bash"
    )
    exit $script:ExitUnsupported
}

# Docker Desktop runs Linux containers on WSL2, so a missing or v1-only WSL
# is worth naming precisely rather than letting `docker build` fail obscurely.
function Assert-Wsl2 {
    if (-not (Test-HaveCommand 'wsl.exe')) {
        Oops "WSL2 is not installed, and Docker Desktop needs it to run Linux containers."
        Remedy @(
            "Open PowerShell as Administrator and run:  wsl --install",
            "Reboot when prompted, then finish the Ubuntu first-run setup",
            "Re-run this installer in a normal (non-admin) PowerShell"
        )
        exit $script:ExitNoWsl
    }

    $listing = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listing)) {
        Warn "could not query WSL distributions; continuing"
        return
    }
    # A distro line ends in its version column. Any '2' means we are fine.
    $versions = [regex]::Matches($listing, '(?m)\s(\d)\s*$') | ForEach-Object { $_.Groups[1].Value }
    if ($versions.Count -gt 0 -and ($versions -notcontains '2')) {
        Oops "WSL is installed, but every distribution is still on WSL1."
        Remedy @(
            "List your distributions:  wsl -l -v",
            "Upgrade one:  wsl --set-version <distro> 2",
            "Make it the default for new installs:  wsl --set-default-version 2",
            "Re-run this installer"
        )
        exit $script:ExitNoWsl
    }
}

function Assert-Docker {
    if (-not (Test-HaveCommand 'docker')) {
        Oops "Docker Desktop is not installed (no ``docker`` on PATH)."
        Remedy @(
            "Install it:  winget install -e --id Docker.DockerDesktop",
            "   (or download from https://www.docker.com/products/docker-desktop/)",
            "Note: Docker Desktop requires a paid subscription for larger",
            "   organisations (250+ employees or `$10M+ revenue) — check yours.",
            "Launch Docker Desktop once and let it finish starting",
            "In Settings -> General, keep 'Use the WSL 2 based engine' enabled",
            "Re-run this installer"
        )
        exit $script:ExitMissingDocker
    }

    $info = (& docker info 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Oops "Docker is installed but not responding."
        Say ''
        Say ($info.Trim() -split "`n" | Select-Object -Last 5 | Out-String).Trim()
        Remedy @(
            "Start Docker Desktop and wait for the whale icon to stop animating",
            "Verify with:  docker info",
            "Re-run this installer"
        )
        exit $script:ExitDockerUnreachable
    }

    $osType = (& docker info -f '{{.OSType}}' 2>&1 | Out-String).Trim()
    if ($osType -and $osType -ne 'linux') {
        Oops "Docker is in Windows-container mode; these images are Linux images."
        Remedy @(
            "Right-click the Docker Desktop tray icon",
            "Choose 'Switch to Linux containers...'",
            "Re-run this installer"
        )
        exit $script:ExitDockerUnreachable
    }
}

# ---- docker helpers -------------------------------------------------------

function Test-DockerImage { param([string]$Image) & docker image inspect $Image 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 }
function Test-DockerVolume { param([string]$Volume) & docker volume inspect $Volume 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 }

function Get-ImageLabel {
    param([string]$Image, [string]$Label)
    $v = (& docker image inspect -f "{{index .Config.Labels `"$Label`"}}" $Image 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

function New-DockerVolume {
    param([string]$Volume)
    if (Test-DockerVolume $Volume) { return }
    & docker volume create $Volume | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "could not create docker volume: $Volume" }
    Ok "created volume $Volume"
}

# The image's agent user, asked of the image rather than assumed. Windows
# builds do not pass UID args, so this is whatever the Dockerfile defaulted to.
function Get-ImageAgentUid {
    param([string]$Image)
    $uid = (& docker run --rm --entrypoint id $Image -u 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $uid -notmatch '^\d+$') { return '1001' }
    return $uid
}

# ---- manifest -------------------------------------------------------------

function Read-Manifest {
    $path = Get-ManifestPath
    $map = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    foreach ($line in Get-Content -LiteralPath $path) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $map[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
    return $map
}

function Get-ManifestValue {
    param([string]$Key, [string]$Default = '')
    $m = Read-Manifest
    if ($m.ContainsKey($Key)) { return $m[$Key] }
    return $Default
}

function Test-Installed { Test-Path -LiteralPath (Get-ManifestPath) -PathType Leaf }

function Write-Manifest {
    param([hashtable]$Extra = @{})
    $lines = @(
        "schema=1"
        "agent=$script:Agent"
        "installer_version=$script:InstallerVersion"
        "installed_at=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
        "src_dir=$script:SrcDirPath"
        "dockerfile=$(Join-Path $script:SrcDirPath 'Dockerfile')"
        "dockerfile_sha=$(Get-FileSha (Join-Path $script:SrcDirPath 'Dockerfile'))"
        "launcher=$(Join-Path $script:BinDirPath ($script:LauncherName + '.ps1'))"
        "launcher_sha=$(Get-FileSha (Join-Path $script:BinDirPath ($script:LauncherName + '.ps1')))"
        "bin_dir=$script:BinDirPath"
        "image=$script:Image"
    )
    foreach ($k in $Extra.Keys) { $lines += "$k=$($Extra[$k])" }
    Write-AtomicText (Get-ManifestPath) ($lines -join "`n")
}

# ---- PATH -----------------------------------------------------------------

function Get-UserPath {
    if ($env:SANDBOX_FAKE_USERPATH_FILE) {
        if (Test-Path -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE) {
            return (Get-Content -Raw -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE).Trim()
        }
        return ''
    }
    try { return [Environment]::GetEnvironmentVariable('Path', 'User') } catch { return '' }
}

function Set-UserPath {
    param([string]$Value)
    if ($env:SANDBOX_FAKE_USERPATH_FILE) {
        Set-Content -LiteralPath $env:SANDBOX_FAKE_USERPATH_FILE -Value $Value -NoNewline
        return $true
    }
    try { [Environment]::SetEnvironmentVariable('Path', $Value, 'User'); return $true }
    catch { return $false }
}

function Add-ToUserPath {
    param([string]$Dir)

    # Whether the launcher is runnable by name in THIS session is a separate
    # question from whether the persisted user PATH already lists it — and it is
    # the one that decides if the caller needs telling. Installing the second
    # agent finds the persisted PATH already correct, writes nothing, and used
    # to say nothing, leaving the launcher un-runnable with no explanation.
    if ((($env:Path -split ';') -notcontains $Dir)) {
        $script:PathNeedsReload = $true
        $script:PathExportLine  = '$env:Path = "$env:Path;' + $Dir + '"'
    }

    $current = Get-UserPath
    if ($null -eq $current) { $current = '' }
    $entries = $current -split ';' | Where-Object { $_ -ne '' }
    if ($entries -contains $Dir) { Info "$Dir is already on your PATH"; return }
    if ($script:NoPathEdit) { Warn "$Dir is not on PATH and -NoPathEdit was given"; return }
    $new = if ($current.TrimEnd(';') -eq '') { $Dir } else { $current.TrimEnd(';') + ';' + $Dir }
    if (-not (Set-UserPath $new)) {
        Warn "could not update your user PATH automatically; add $Dir by hand"
        return
    }
    $env:Path = "$env:Path;$Dir"
    Ok "added $Dir to your user PATH (new terminals pick it up automatically)"
    $script:PathWasEdited = $true
}

# ---- asset installation ---------------------------------------------------

# Never destroys local edits: a file whose hash differs from what the manifest
# recorded is backed up before being replaced.
function Install-Asset {
    param([string]$Path, [string]$Content, [string]$RecordedKey)
    $new = Get-AssetSha $Content
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $cur = Get-FileSha $Path
        if ($cur -eq $new -and -not $script:Force) {
            Info "$(Split-Path -Leaf $Path) is already current"
            return 'unchanged'
        }
        $recorded = Get-ManifestValue $RecordedKey ''
        if ($recorded -and $recorded -ne $cur) {
            $bak = Backup-File $Path
            Warn "$Path was modified locally — your version is saved as $(Split-Path -Leaf $bak)"
            Write-AtomicText $Path $Content
            Ok "updated $Path"
            return 'replaced'
        }
        Write-AtomicText $Path $Content
        Ok "updated $Path"
        return 'updated'
    }
    Write-AtomicText $Path $Content
    Ok "wrote $Path"
    return 'created'
}

function Install-AssetIfAbsent {
    param([string]$Path, [string]$Content)
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $script:Force) {
        Info "keeping your $(Split-Path -Leaf $Path)"
        return 'kept'
    }
    Write-AtomicText $Path $Content
    Ok "wrote $Path"
    return 'created'
}

# ---- build ----------------------------------------------------------------

function Test-ImageCurrent {
    param([string]$WantSha)
    if (-not (Test-DockerImage $script:Image)) { return $false }
    return (Get-ImageLabel $script:Image 'sandbox.dockerfile_sha') -eq $WantSha
}

function Invoke-Build {
    param([string[]]$ExtraArgs = @())
    $wantSha = Get-FileSha (Join-Path $script:SrcDirPath 'Dockerfile')

    if ($script:NoBuild) { Warn "-NoBuild given; skipping docker build"; return }
    if ((Test-ImageCurrent $wantSha) -and -not $script:Force -and -not $script:ForceBuild) {
        Info "image $script:Image is up to date"
        return
    }
    if (-not (Test-DockerImage $script:Image)) {
        Step "Building $script:Image for the first time — this can take a few minutes"
    } elseif ($script:ForceBuild) {
        Step "Rebuilding $script:Image`: $script:ForceBuildReason — this can take a few minutes"
    } else {
        Step "Rebuilding $script:Image — this can take a few minutes"
    }

    $buildArgs = @(
        'build',
        '--label', "sandbox.dockerfile_sha=$wantSha",
        '--label', "sandbox.installer_version=$script:InstallerVersion"
    ) + $ExtraArgs + @('-t', $script:Image, $script:SrcDirPath)

    # The build stream is progress, not data: routed to stderr like every other
    # diagnostic here, so the success stream stays free for -PrintPath. Write-Host
    # would not do — with stdout redirected the host writes it there anyway.
    & docker @buildArgs | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($LASTEXITCODE -ne 0) {
        Oops "docker build failed (exit $LASTEXITCODE)"
        Remedy @(
            "Read the error above — usually a transient network failure or a full disk",
            "Re-run this installer to try again",
            "If it persists, open an issue at $script:RepoUrl/issues"
        )
        exit 1
    }
    Ok "built $script:Image"
}

# ---- confirmation ---------------------------------------------------------

function Confirm-Action {
    param([string]$Prompt)
    if ($script:Yes) { return $true }
    if ([Console]::IsInputRedirected) {
        Oops $Prompt
        Info "Not running interactively — re-run with -Yes to confirm."
        return $false
    }
    $reply = Read-Host "$Prompt [y/N]"
    return $reply -match '^(y|yes)$'
}

# ---- update check ---------------------------------------------------------

function Get-LatestVersion {
    if ($env:SANDBOX_FAKE_UPSTREAM -eq 'fail') { return '' }
    if ($env:SANDBOX_FAKE_UPSTREAM) { return $env:SANDBOX_FAKE_UPSTREAM }
    try {
        $v = (Invoke-RestMethod -Uri "$script:RawBase/VERSION" -TimeoutSec 5 -ErrorAction Stop)
        return ("$v".Trim() -split "`n")[0].Trim()
    } catch { return '' }
}

function Compare-Version {
    param([string]$A, [string]$B)   # 1 when A is newer than B
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

# ---- agent hooks (no-ops; the agent section below replaces what it needs) --

function Invoke-AgentPreBuild { }
function Invoke-AgentPostBuild { }
function Show-AgentCheckExtra { }
function Remove-AgentExtra { }
function Get-AgentBuildArgs { return @() }

# Step 0 of every agent's next-steps block: printed whenever the launcher is
# not runnable by name in the session that ran the installer.
function Write-PathStep {
    if (-not $script:PathNeedsReload) { return }
    Say "  0. Make $script:LauncherName runnable in this terminal:"
    Say "       $script:PathExportLine"
    if ($script:PathWasEdited) { Say '     New terminals pick it up automatically.' }
    Say ''
}

# The success stream's only job. Every diagnostic here goes to Write-Host or
# the error stream, so -PrintPath can hand the caller a line to apply to its
# own session:
#
#   & ([scriptblock]::Create((irm .../claude.ps1))) -PrintPath | iex
#
# Unlike the shell installers this needs an explicit switch: PowerShell's
# success stream reaches `| iex` without the process's stdout ever being
# redirected, so there is no "am I being captured" test to key off.
function Write-PathCommand {
    if (-not $script:PrintPath) { return }
    if (-not $script:PathExportLine) { return }
    Write-Output $script:PathExportLine
}

# ---- usage ----------------------------------------------------------------

function Show-Usage {
    Write-Host @"
$script:AgentName sandbox installer (v$script:InstallerVersion)

Installs a Docker sandbox for running $script:AgentName in full-autonomy mode,
where the only host path the agent can see is the directory you launch it from.

Usage
  irm $script:RawBase/install/$script:Agent.ps1 | iex

  # with options, since a piped script cannot take arguments directly:
  & ([scriptblock]::Create((irm $script:RawBase/install/$script:Agent.ps1))) -Check

Options
  -Check         Report what is installed and whether it is current; change nothing
  -Force         Reinstall/rebuild even when everything looks current
  -Uninstall     Remove the launcher, Dockerfile and image (volumes/auth survive)
  -Purge         With -Uninstall, also delete the named volumes (destroys auth)
  -Prefix DIR    Directory for the launcher (default: <home>\bin)
  -SrcDir DIR    Directory for the Dockerfile (default: <home>\$script:Agent-sandbox)
  -NoBuild       Install the files but skip the docker build
  -NoPathEdit    Never touch your user PATH
  -PrintPath     Print this session's PATH command to the success stream, so
                 piping the installer into iex makes the launcher runnable now
  -Yes           Assume yes for confirmations
  -Quiet         Only warnings and errors
  -Version       Print the installer version
  -Help          This message

Re-running the install command is the upgrade path: it rewrites only what
changed and rebuilds the image only when the Dockerfile changed.
"@
}

# ---- modes ----------------------------------------------------------------

function Invoke-Install {
    Assert-Windows
    Assert-Wsl2
    Assert-Docker

    Step "Installing the $script:AgentName sandbox (v$script:InstallerVersion)"
    $wasInstalled = Test-Installed
    if ($wasInstalled) {
        $prev = Get-ManifestValue 'installer_version' 'unknown'
        if ($prev -eq $script:InstallerVersion) { Info "already at v$prev — checking that everything matches" }
        else { Info "upgrading from v$prev to v$script:InstallerVersion" }
    }

    Install-Asset (Join-Path $script:SrcDirPath 'Dockerfile') $AssetDockerfile 'dockerfile_sha' | Out-Null
    Install-Asset (Join-Path $script:BinDirPath "$script:LauncherName.ps1") $AssetLauncher 'launcher_sha' | Out-Null
    Install-Asset (Join-Path $script:BinDirPath "$script:LauncherName.cmd") $AssetShim 'shim_sha' | Out-Null
    Add-ToUserPath $script:BinDirPath

    Invoke-AgentPreBuild
    Invoke-Build -ExtraArgs (Get-AgentBuildArgs)
    foreach ($v in $script:VolumeBasenames) { New-DockerVolume "$v-$(Get-SandboxUser)" }
    Invoke-AgentPostBuild

    Write-Manifest @{ shim_sha = (Get-FileSha (Join-Path $script:BinDirPath "$script:LauncherName.cmd")) }
    Say ''
    Step 'Done.'
    # First-run instructions are for a first run.
    if ($wasInstalled) {
        Say "  $script:AgentName sandbox is at v$script:InstallerVersion."
        Say "  $script:LauncherName --sandbox-doctor    to confirm image, volumes and versions"
        Say ''
        Write-PathStep
    } else {
        Show-NextSteps
    }
    Write-PathCommand
}

function Invoke-Check {
    $rc = 0
    Write-Host "$script:AgentName sandbox — status"
    Write-Host "  installer version   $script:InstallerVersion"
    if (-not (Test-Installed)) {
        Write-Host "  state               not installed"
        Write-Host ''
        Write-Host "Install with:  irm $script:RawBase/install/$script:Agent.ps1 | iex"
        return 1
    }
    Write-Host "  installed version   $(Get-ManifestValue 'installer_version' 'unknown')"
    Write-Host "  installed at        $(Get-ManifestValue 'installed_at' 'unknown')"

    $df = Join-Path $script:SrcDirPath 'Dockerfile'
    if (Test-Path -LiteralPath $df) {
        $cur = Get-FileSha $df
        if ($cur -eq (Get-AssetSha $AssetDockerfile)) { Write-Host "  Dockerfile          current ($df)" }
        elseif ($cur -eq (Get-ManifestValue 'dockerfile_sha' '')) { Write-Host "  Dockerfile          stale — re-run the installer"; $rc = 1 }
        else { Write-Host "  Dockerfile          locally modified ($df)"; $rc = 1 }
    } else { Write-Host "  Dockerfile          missing"; $rc = 1 }

    $lp = Join-Path $script:BinDirPath "$script:LauncherName.ps1"
    if (Test-Path -LiteralPath $lp) {
        if ((Get-FileSha $lp) -eq (Get-AssetSha $AssetLauncher)) { Write-Host "  launcher            current ($lp)" }
        else { Write-Host "  launcher            out of date ($lp)"; $rc = 1 }
    } else { Write-Host "  launcher            missing"; $rc = 1 }

    $shim = Join-Path $script:BinDirPath "$script:LauncherName.cmd"
    if (Test-Path -LiteralPath $shim) { Write-Host "  cmd shim            present" }
    else { Write-Host "  cmd shim            missing"; $rc = 1 }

    $userPath = Get-UserPath
    if ($userPath -and (($userPath -split ';') -contains $script:BinDirPath)) { Write-Host "  PATH                ok" }
    else { Write-Host "  PATH                $script:BinDirPath is not on your user PATH"; $rc = 1 }

    if (-not (Test-HaveCommand 'docker')) { Write-Host "  docker              not installed"; return 1 }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  docker              installed but unreachable"; return 1 }
    Write-Host "  docker              ok"

    if (Test-DockerImage $script:Image) {
        if (Test-ImageCurrent (Get-FileSha $df)) { Write-Host "  image               current ($script:Image)" }
        else { Write-Host "  image               needs rebuild ($script:Image)"; $rc = 1 }
    } else { Write-Host "  image               missing ($script:Image)"; $rc = 1 }

    foreach ($v in $script:VolumeBasenames) {
        $vol = "$v-$(Get-SandboxUser)"
        if (Test-DockerVolume $vol) { Write-Host "  volume $vol present" }
        else { Write-Host "  volume $vol missing"; $rc = 1 }
    }

    Show-AgentCheckExtra

    $latest = Get-LatestVersion
    if ($latest) {
        if ((Compare-Version $latest $script:InstallerVersion) -gt 0) { Write-Host "  upstream            v$latest available"; $rc = 1 }
        else { Write-Host "  upstream            latest" }
    }

    if ($rc -ne 0) {
        Write-Host ''
        Write-Host "Re-run the installer to bring everything up to date:"
        Write-Host "  irm $script:RawBase/install/$script:Agent.ps1 | iex"
    }
    return $rc
}

function Invoke-Uninstall {
    if (-not (Test-Installed)) {
        Say "$script:AgentName sandbox is not installed. Nothing to do."
        return
    }
    Step "Removing the $script:AgentName sandbox"

    foreach ($f in @((Join-Path $script:BinDirPath "$script:LauncherName.ps1"),
                     (Join-Path $script:BinDirPath "$script:LauncherName.cmd"),
                     (Join-Path $script:SrcDirPath 'Dockerfile'))) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Ok "removed $f" }
    }
    Remove-AgentExtra

    if ((Test-HaveCommand 'docker') -and (Test-DockerImage $script:Image)) {
        & docker image rm $script:Image 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "removed image $script:Image" }
        else { Warn "could not remove image $script:Image (a container may still be using it)" }
    }

    if ($script:Purge) {
        Say ''
        Warn "-Purge will delete these volumes, including your $script:AgentName login:"
        foreach ($v in $script:VolumeBasenames) { Say "    $v-$(Get-SandboxUser)" }
        if (Confirm-Action 'Delete them?') {
            foreach ($v in $script:VolumeBasenames) {
                $vol = "$v-$(Get-SandboxUser)"
                if (-not (Test-DockerVolume $vol)) { continue }
                & docker volume rm $vol 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Ok "removed volume $vol" } else { Warn "could not remove volume $vol" }
            }
        } else { Say 'Volumes kept.' }
    } else {
        Info 'volumes kept (your login survives); pass -Purge to delete them'
    }

    Remove-Item -LiteralPath (Get-ManifestPath) -Force
    Ok "removed $(Get-ManifestPath)"
}
