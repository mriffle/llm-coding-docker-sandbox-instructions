# codex-sandbox.ps1 — run Codex CLI sandboxed in the current directory.
#
# Installed by the agent-sandbox installer (v@@VERSION@@):
#   irm @@RAW_BASE@@/install/codex.ps1 | iex
# Edits here are backed up, not preserved, when you upgrade.
#
# Autonomy comes from ~/.codex/config.toml inside the container, not a flag.
$ErrorActionPreference = 'Stop'

$SandboxVersion = '@@VERSION@@'
$RawBase        = '@@RAW_BASE@@'
$RepoUrl        = '@@REPO_URL@@'
$Agent          = 'codex'
$AgentBin       = 'codex'
$AgentName      = 'Codex CLI'
$LauncherName   = 'codex-sandbox'

# @include ps/assets/launcher-common.ps1

$Image     = "codex-sandbox-$(Get-User)"
$ConfigVol = "codex-config-$(Get-User)"
$Volumes   = @($ConfigVol)
$MountArgs = @('-v', "${ConfigVol}:/home/agent/.codex")

function Get-CodexSrcDir {
    if ($env:CODEX_SANDBOX_SRC) { return $env:CODEX_SANDBOX_SRC }
    $manifest = Join-Path (Get-StateDirPath) 'codex.manifest'
    if (Test-Path -LiteralPath $manifest) {
        foreach ($line in Get-Content -LiteralPath $manifest) {
            if ($line -like 'src_dir=*') { return $line.Substring(8) }
        }
    }
    return (Join-Path (Get-SandboxHomeDir) 'codex-sandbox')
}

# Codex has no self-updater, so the launcher is where updates happen: ask the
# npm registry and rebuild only when the version actually changed, tracked by
# an image label so an up-to-date launch does no work at all.
function Invoke-PreRun {
    $latest = ''
    try {
        if ($env:SANDBOX_FAKE_NPM -eq 'fail') { throw 'npm unreachable' }
        elseif ($env:SANDBOX_FAKE_NPM) { $latest = $env:SANDBOX_FAKE_NPM }
        else { $latest = "$((Invoke-RestMethod -Uri 'https://registry.npmjs.org/@openai/codex/latest' -TimeoutSec 5 -ErrorAction Stop).version)".Trim() }
    } catch {
        Write-Note "npm version check failed; running the existing image"
        return
    }
    if (-not $latest) { return }

    $current = (& docker image inspect -f '{{index .Config.Labels "codex_version"}}' $Image 2>&1 | Out-String).Trim()
    if ($current -eq $latest) { return }

    $src = Get-CodexSrcDir
    if (-not (Test-Path -LiteralPath (Join-Path $src 'Dockerfile'))) {
        Write-Note "Codex $latest is available but no Dockerfile at $src; running the existing image"
        return
    }

    Write-Note "Codex $latest available (have: $(if ($current) { $current } else { 'none' })); rebuilding — this can take a minute..."
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $src 'Dockerfile')).Hash.ToLower()
    & docker build -q `
        --build-arg "CODEX_VERSION=$latest" `
        --label "codex_version=$latest" `
        --label "sandbox.dockerfile_sha=$sha" `
        --label "sandbox.installer_version=$SandboxVersion" `
        -t $Image $src | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Note "now on Codex $latest" }
    else { Write-Note "rebuild failed; running the existing image" }
}

Invoke-LauncherMain @args
