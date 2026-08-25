# claude-sandbox.ps1 — run Claude Code sandboxed in the current directory.
#
# Installed by the agent-sandbox installer (v@@VERSION@@):
#   irm @@RAW_BASE@@/install/claude.ps1 | iex
# Edits here are backed up, not preserved, when you upgrade.
$ErrorActionPreference = 'Stop'

$SandboxVersion = '@@VERSION@@'
$RawBase        = '@@RAW_BASE@@'
$RepoUrl        = '@@REPO_URL@@'
$Agent          = 'claude'
$AgentBin       = 'claude'
$AgentName      = 'Claude Code'
$LauncherName   = 'claude-sandbox'

# @include ps/assets/launcher-common.ps1

$Image     = "claude-sandbox-$(Get-User)"
$ConfigVol = "claude-config-$(Get-User)"
$LocalVol  = "claude-local-$(Get-User)"
$Volumes   = @($ConfigVol, $LocalVol)
$MountArgs = @('-v', "${ConfigVol}:/home/agent/.claude", '-v', "${LocalVol}:/home/agent/.local")

Invoke-LauncherMain @args
