param(
  [string]$RepoOwner = "tyeth",
  [string]$RepoName = "wmerkens_vscode-circuitpython",
  # Default .wsb lives alongside this script inside the repo
  [string]$SandboxConfigPath = "sandbox/windows-runner/cp-windows-runner.wsb",
  # Optional: extra labels applied to the self-hosted runner
  [string]$RunnerLabels = "self-hosted,windows,cp-sandbox"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[host] Detecting repository root from script location..."
$scriptPath = $PSCommandPath
if (-not $scriptPath) {
    throw "Unable to determine script path via PSCommandPath."
}
$scriptDir = Split-Path -Path $scriptPath -Parent

function Get-RepoRootFromPath {
    param([Parameter(Mandatory)] [string]$StartPath)

    $current = Get-Item -Path $StartPath -ErrorAction Stop
    while ($current) {
        $gitDir = Join-Path -Path $current.FullName -ChildPath ".git"
        if (Test-Path -Path $gitDir) {
            return $current.FullName
        }
        $current = $current.Parent
    }
    return $null
}

$repoPath = Get-RepoRootFromPath -StartPath $scriptDir
if ($repoPath) {
    Write-Host "[host] Repository root detected at '$repoPath'."
} else {
    Write-Warning "[host] Could not locate a .git directory; defaulting to script directory '$scriptDir'."
    $repoPath = $scriptDir
}

$repoPath = (Resolve-Path -Path $repoPath).Path

Write-Host "[host] Ensuring sandbox config directory exists..."

# Resolve repo root and sandbox paths relative to detected repo directory
$fullSandboxConfigPath = Join-Path -Path $repoPath -ChildPath $SandboxConfigPath
$configDir = [System.IO.Path]::GetDirectoryName($fullSandboxConfigPath)
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

Write-Host "[host] Fetching transient runner token via gh..."
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI 'gh' is required on the host to obtain a runner token."
}

# Uses gh REST API to create a repo-level registration token
$tokenJson = gh api `
    -X POST `
    repos/$RepoOwner/$RepoName/actions/runners/registration-token

$tokenObj = $tokenJson | ConvertFrom-Json
if (-not $tokenObj.token) {
    throw "Failed to obtain runner registration token from GitHub. Response: $tokenJson"
}

$runnerToken = $tokenObj.token
Write-Host "[host] Obtained short-lived runner token from GitHub."

Write-Host "[host] Writing Sandbox configuration to '$fullSandboxConfigPath'..."

$wsbContent = @"
<Configuration>
  <VGpu>Default</VGpu>
  <Networking>Default</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$repoPath</HostFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; `$desk = Join-Path `$env:USERPROFILE 'Desktop'; `$candidates = Get-ChildItem -Path `$desk -Directory; foreach (`$c in `$candidates) { `$scriptPath = Join-Path `$c.FullName 'sandbox\\windows-runner\\start-runner.ps1'; if (Test-Path `$scriptPath) { Start-Process powershell.exe -WindowStyle Normal -ArgumentList '-NoExit','-ExecutionPolicy Bypass','-File', `$scriptPath, '-RepoUrl', 'https://github.com/$RepoOwner/$RepoName', '-RunnerToken', '$runnerToken', '-RunnerLabels', '$RunnerLabels' -Verb RunAs; break } }"</Command>
  </LogonCommand>
</Configuration>
"@

Set-Content -LiteralPath $fullSandboxConfigPath -Value $wsbContent -Encoding UTF8

Write-Host "[host] Launching Windows Sandbox..."
Start-Process -FilePath "WindowsSandbox.exe" -ArgumentList "`"$fullSandboxConfigPath`"" | Out-Null

Write-Host "[host] Sandbox started. The runner will auto-configure and wait for jobs."
