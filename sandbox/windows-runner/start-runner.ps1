param(
    # URL of the GitHub repository this runner should attach to.
    [string]$RepoUrl = "https://github.com/tyeth/wmerkens_vscode-circuitpython",
    # GitHub Actions runner version; keep in sync with GitHub guidance.
    [string]$RunnerVersion = "2.319.1",
    # Comma-separated list of labels; can be overridden per repo.
    [string]$RunnerLabels = "self-hosted,windows,cp-sandbox",
    # Short-lived registration token; always passed in from host script.
    [Parameter(Mandatory = $true)]
    [string]$RunnerToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[sandbox] Setting execution policy for this process..."
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
    # install provider nuget powershellget if needed
    Install-PackageProvider -Name NuGet -Force
} catch {
    Write-Warning "[sandbox] Failed to set execution policy: $($_.Exception.Message)"
}

Write-Host "[sandbox] Ensuring core tools are available (git/node/python/curl/wget) via winget if present..."

try {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $packages = @(
            @{ Id = 'Git.Git' },
            @{ Id = 'OpenJS.NodeJS.LTS' },
            @{ Id = 'Python.Python.3.11' },
            @{ Id = 'GnuWin32.curl' },
            @{ Id = 'GnuWin32.wget' },
            # Newer PowerShell that includes Microsoft.PowerShell.Archive on some images
            @{ Id = 'Microsoft.PowerShell' }
        )
        foreach ($pkg in $packages) {
            try {
                winget install --id $($pkg.Id) -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
            } catch {
                Write-Warning "[sandbox] winget failed for $($pkg.Id): $($_.Exception.Message)"
            }
        }
    }
} catch {
    Write-Warning "[sandbox] winget bootstrap phase failed: $($_.Exception.Message)"
}

Write-Host "[sandbox] Ensuring Microsoft.PowerShell.Archive / Expand-Archive is available..."
try {
    $archiveCmd = Get-Command -Name Expand-Archive -ErrorAction Ignore
    if (-not $archiveCmd) {
        # Prefer built-in module if present
        try {
            Import-Module Microsoft.PowerShell.Archive -ErrorAction Stop
        } catch {
            if (Get-Command Install-Module -ErrorAction Ignore) {
                try {
                    Install-Module -Name Microsoft.PowerShell.Archive -Force -Scope AllUsers -AllowClobber -ErrorAction Stop -Confirm:$false
                } catch {
                    Write-Warning "[sandbox] Install-Module for Microsoft.PowerShell.Archive failed: $($_.Exception.Message)"
                }
            } else {
                Write-Warning "[sandbox] Install-Module not available; Expand-Archive may still be missing. actions/checkout might fall back to ZipFile."
            }
        }
    }
} catch {
    Write-Warning "[sandbox] Failed to ensure Microsoft.PowerShell.Archive: $($_.Exception.Message)"
}

New-Item -ItemType Directory -Path "C:\actions-runner" -Force | Out-Null
Set-Location "C:\actions-runner"

$zipName = "actions-runner-win-x64-$RunnerVersion.zip"
$zipPath = Join-Path $PWD $zipName
$runnerUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$zipName"

Write-Host "[sandbox] Downloading runner $RunnerVersion from $runnerUrl"

# Prefer curl.exe if available, fall back to wget, then Invoke-WebRequest.
try {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        # NOTE: For faster downloads we use curl.exe rather than Invoke-WebRequest.
        # Possible future improvement: cache the downloaded zip in a mapped host folder
        # so subsequent Sandbox sessions can reuse it instead of re-downloading.
        & curl.exe -L "$runnerUrl" -o "$zipPath"
    } elseif (Get-Command wget -ErrorAction SilentlyContinue) {
        & wget "$runnerUrl" -O "$zipPath"
    } else {
        Invoke-WebRequest -Uri "$runnerUrl" -OutFile "$zipPath"
    }
} catch {
    Write-Error "[sandbox] Exception during runner download: $($_.Exception.Message)"
    Read-Host "[sandbox] Error during bootstrap (download). Press Enter to close this window"
    exit 1
}

if (-not (Test-Path $zipPath)) {
    Write-Error "[sandbox] Runner download appears to have failed; '$zipPath' not found."
    Read-Host "[sandbox] Error during bootstrap (missing zip). Press Enter to close this window"
    exit 1
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $PWD)
} catch {
    Write-Error "[sandbox] Failed to extract runner zip: $($_.Exception.Message)"
    Read-Host "[sandbox] Error during bootstrap (extract). Press Enter to close this window"
    exit 1
}

Write-Host "[sandbox] Removing any existing local runner configuration (to force fresh registration)..."
try {
    if (Test-Path ".\.runner" -PathType Leaf) {
        Remove-Item -Path ".\.runner" -Force -ErrorAction Stop
    }
} catch {
    Write-Warning "[sandbox] Failed to remove existing .runner file: $($_.Exception.Message)"
}

Write-Host "[sandbox] Generating unique runner name..."
$machineName = $env:COMPUTERNAME
$uniqueSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runnerName = "$machineName-$uniqueSuffix"
Write-Host "[sandbox] Using runner name: $runnerName"

Write-Host "[sandbox] Configuring runner for $RepoUrl ..."
$configExit = 0
try {
    & .\config.cmd --url $RepoUrl --token $RunnerToken --unattended --name "$runnerName" --labels "$RunnerLabels"
    $configExit = $LASTEXITCODE
} catch {
    Write-Error "[sandbox] Runner configuration threw: $($_.Exception.Message)"
    $configExit = 1
}

if ($configExit -ne 0) {
    Write-Error "[sandbox] Runner configuration failed with exit code $configExit"
    Read-Host "[sandbox] Press Enter to close this window"
    exit $configExit
}

Write-Host "[sandbox] Starting runner..."
try {
    & .\run.cmd
} catch {
    Write-Error "[sandbox] Runner exited with error: $($_.Exception.Message)"
} finally {
    Read-Host "[sandbox] Runner finished. Press Enter to close this window"
}

choice