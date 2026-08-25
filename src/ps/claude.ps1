# Claude Code sandbox installer for native Windows (Route B).
#
#   irm @@RAW_BASE@@/install/claude.ps1 | iex
#
# Creates <home>\claude-sandbox\Dockerfile, launcher scripts in <home>\bin,
# a per-user image, and the named volumes that hold your login. Re-run to upgrade.
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$NoBuild,
    [switch]$NoPathEdit,
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
$script:Agent            = 'claude'
$script:AgentName        = 'Claude Code'
$script:LauncherName     = 'claude-sandbox'
$script:ImageBasename    = 'claude-sandbox'
$script:VolumeBasenames  = @('claude-config', 'claude-local')

# @include ps/lib.ps1

# @embed assets/claude.Dockerfile AS AssetDockerfile
# @embed ps/assets/claude-sandbox.ps1 AS AssetLauncher
# @embed ps/assets/claude-sandbox.cmd AS AssetShim

function Show-NextSteps {
    Say ''
    Say 'Next steps'
    if ($script:PathWasEdited) {
        Say '  0. Open a new terminal so the PATH change takes effect.'
    }
    Say "  1. Log in once — the token persists in claude-config-$(Get-SandboxUser):"
    Say '       cd C:\code\some-project'
    Say '       claude-sandbox'
    Say ''
    Say '  2. Accept the bypass-permissions dialog once, interactively:'
    Say '       claude-sandbox --dangerously-skip-permissions'
    Say ''
    Say '  3. Daily use, from any project directory:'
    Say '       claude-sandbox --dangerously-skip-permissions'
    Say ''
    Say '  claude-sandbox --sandbox-help    for the sandbox-specific flags'
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
    $script:ForceBuild = $false
    $script:ForceBuildReason = ''

    $home_ = Get-SandboxHome
    $script:BinDirPath = if ($Prefix) { $Prefix } else { Join-Path $home_ 'bin' }
    $script:SrcDirPath = if ($SrcDir) { $SrcDir } else { Join-Path $home_ 'claude-sandbox' }
    $script:Image      = "$script:ImageBasename-$(Get-SandboxUser)"

    if ($Check)     { exit (Invoke-Check) }
    if ($Uninstall) { Invoke-Uninstall; exit 0 }
    Invoke-Install
}

Invoke-Main
