# Codex CLI sandbox installer for native Windows (Route B).
#
#   irm @@RAW_BASE@@/install/codex.ps1 | iex
#
# Creates <home>\codex-sandbox\{Dockerfile,config.toml}, launcher scripts in
# <home>\bin, a per-user image, and the volume that holds your login.
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$NoBuild,
    [switch]$NoPathEdit,
    [switch]$PrintPath,
    [switch]$Quiet,
    [switch]$Version,
    [switch]$Help,
    [string]$Prefix,
    [string]$SrcDir
)
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '@@VERSION@@'
$script:RawBase          = '@@RAW_BASE@@'
$script:RepoUrl          = '@@REPO_URL@@'
$script:Agent            = 'codex'
$script:AgentName        = 'Codex CLI'
$script:LauncherName     = 'codex-sandbox'
$script:ImageBasename    = 'codex-sandbox'
$script:VolumeBasenames  = @('codex-config')

# @include ps/lib.ps1

# @embed assets/codex.Dockerfile AS AssetDockerfile
# @embed ps/assets/codex-sandbox.ps1 AS AssetLauncher
# @embed ps/assets/codex-sandbox.cmd AS AssetShim
# @embed assets/codex.config.toml AS AssetConfigToml

$script:CodexVersion = ''

function Invoke-AgentPreBuild {
    Install-AssetIfAbsent (Join-Path $script:SrcDirPath 'config.toml') $AssetConfigToml | Out-Null
    try {
        if ($env:SANDBOX_FAKE_NPM -eq 'fail') { throw 'npm unreachable' }
        elseif ($env:SANDBOX_FAKE_NPM) { $script:CodexVersion = $env:SANDBOX_FAKE_NPM }
        else {
            $script:CodexVersion = "$((Invoke-RestMethod -Uri 'https://registry.npmjs.org/@openai/codex/latest' -TimeoutSec 10 -ErrorAction Stop).version)".Trim()
        }
    } catch {
        Warn 'could not reach the npm registry; building with CODEX_VERSION=latest'
        $script:CodexVersion = ''
    }
    if (-not $script:CodexVersion) { return }
    Info "pinning Codex $script:CodexVersion into the image"
    # Re-running the installer is the documented upgrade path, so it has to
    # cover the Codex release too — not just the Dockerfile.
    if (Test-DockerImage $script:Image) {
        $current = Get-ImageLabel $script:Image 'codex_version'
        if ($current -and $current -ne $script:CodexVersion) {
            $script:ForceBuild = $true
            $script:ForceBuildReason = "Codex $current -> $script:CodexVersion"
        }
    }
}

function Get-AgentBuildArgs {
    if (-not $script:CodexVersion) { return @() }
    return @('--build-arg', "CODEX_VERSION=$script:CodexVersion", '--label', "codex_version=$script:CodexVersion")
}

# The failure this repo has hit most: a config.toml (or a whole volume) left
# root-owned, after which Codex cannot open its state DB. Docker Desktop hides
# ownership for Windows bind mounts, but named volumes are real Linux
# filesystems, so this still matters on this route.
function Invoke-AgentPostBuild {
    $vol = "codex-config-$(Get-SandboxUser)"
    if ($script:NoBuild -and -not (Test-DockerImage $script:Image)) {
        Warn 'skipping config.toml seeding (no image available)'
        return
    }
    $uid = Get-ImageAgentUid $script:Image
    $cfg = Join-Path $script:SrcDirPath 'config.toml'

    Step "Seeding config.toml into $vol"
    & docker run --rm --user 0:0 -v "${vol}:/cfg" $script:Image test -f /cfg/config.toml 2>&1 | Out-Null
    $present = ($LASTEXITCODE -eq 0)

    if ($script:Force -or -not $present) {
        & docker run --rm --user 0:0 -v "${vol}:/cfg" -v "${cfg}:/src/config.toml:ro" `
            $script:Image cp /src/config.toml /cfg/config.toml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn "could not seed config.toml into $vol — Codex may prompt for approvals"
            return
        }
        Ok 'seeded config.toml'
    } else {
        Info 'config.toml already present in the volume — left alone'
    }

    & docker run --rm --user 0:0 -v "${vol}:/cfg" $script:Image chown -R "${uid}:${uid}" /cfg 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "volume contents owned by $uid (the image's agent user)" }
    else { Warn "could not set ownership on $vol; see the troubleshooting notes in MANUAL.md" }
}

function Show-AgentCheckExtra {
    $cfg = Join-Path $script:SrcDirPath 'config.toml'
    if (Test-Path -LiteralPath $cfg) { Write-Host "  config.toml         present ($cfg)" }
    else { Write-Host "  config.toml         missing" }
    if (Test-DockerImage $script:Image) {
        $v = Get-ImageLabel $script:Image 'codex_version'
        if (-not $v) { $v = 'unknown (built without a pin)' }
        Write-Host "  codex in image      $v"
    }
}

function Remove-AgentExtra {
    $cfg = Join-Path $script:SrcDirPath 'config.toml'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force; Ok "removed $cfg" }
}

function Show-NextSteps {
    Say ''
    Say 'Next steps'
    Write-PathStep
    Say '  1. Log in once — device code, approve at chatgpt.com from any device:'
    Say '       cd C:\code\some-project'
    Say '       codex-sandbox login --device-auth'
    Say ''
    Say '  2. Daily use, from any project directory (no flag needed — autonomy'
    Say '     comes from config.toml):'
    Say '       codex-sandbox'
    Say ''
    Say '  codex-sandbox --sandbox-help    for the sandbox-specific flags'
    Say "  $script:RepoUrl"
}

function Invoke-Main {
    if ($Help)    { Show-Usage; exit 0 }
    if ($Version) { Write-Host $script:InstallerVersion; exit 0 }

    $script:Force      = [bool]$Force
    $script:Yes        = [bool]$Yes
    $script:Purge      = [bool]$Purge
    $script:NoBuild    = [bool]$NoBuild
    $script:NoPathEdit = [bool]$NoPathEdit
    $script:Quiet      = [bool]$Quiet
    $script:PathWasEdited = $false
    $script:PrintPath = [bool]$PrintPath
    $script:PathNeedsReload = $false
    $script:PathExportLine = ''
    $script:ForceBuild = $false
    $script:ForceBuildReason = ''

    $home_ = Get-SandboxHome
    $script:BinDirPath = if ($Prefix) { $Prefix } else { Join-Path $home_ 'bin' }
    $script:SrcDirPath = if ($SrcDir) { $SrcDir } else { Join-Path $home_ 'codex-sandbox' }
    $script:Image      = "$script:ImageBasename-$(Get-SandboxUser)"

    if ($Check)     { exit (Invoke-Check) }
    if ($Uninstall) { Invoke-Uninstall; exit 0 }
    Invoke-Install
}

Invoke-Main
