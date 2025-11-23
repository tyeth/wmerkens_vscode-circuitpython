param(
    # URL of the GitHub repository this runner should attach to.
    [string]$RepoUrl = "https://github.com/tyeth/wmerkens_vscode-circuitpython",
    # GitHub Actions runner version; keep in sync with GitHub guidance.
    [string]$RunnerVersion = "2.330.0",
    # Comma-separated list of labels; can be overridden per repo.
    [string]$RunnerLabels = "self-hosted,windows,cp-sandbox",
    # Short-lived registration token; always passed in from host script.
    [Parameter(Mandatory = $true)]
    [string]$RunnerToken,
    # Internal switch used when the script re-executes itself after installing tools.
    [switch]$SkipBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SkipBootstrap) {
    Write-Host "[sandbox] Initial bootstrap: setting execution policy and NuGet provider..."
    try {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
        Install-PackageProvider -Name NuGet -Force
    } catch {
        Write-Warning "[sandbox] Bootstrap execution policy/NuGet failed: $($_.Exception.Message)"
    }

    Write-Host "[sandbox] Initial bootstrap: ensuring winget and core tools via winget (git/node22/python/curl/wget/PowerShell) if present..."
    try {
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue

        if (-not $wingetCmd) {
            Write-Host "[sandbox] winget not found; attempting Repair-WinGetPackageManager (IncludePrerelease)..."

            try {
                $winGetModule = Get-Module -ListAvailable -Name Microsoft.WinGet.Client
                if (-not $winGetModule) {
                    if (Get-Command Install-Module -ErrorAction SilentlyContinue) {
                        try {
                            Install-Module -Name Microsoft.WinGet.Client -Force -Scope AllUsers -AllowClobber -Confirm:$false
                        } catch {
                            Write-Warning "[sandbox] Install-Module Microsoft.WinGet.Client failed: $($_.Exception.Message)"
                        }
                    } else {
                        Write-Warning "[sandbox] Install-Module not available; cannot install Microsoft.WinGet.Client."
                    }
                }

                Import-Module Microsoft.WinGet.Client -ErrorAction SilentlyContinue

                if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
                    Repair-WinGetPackageManager -IncludePrerelease -ErrorAction SilentlyContinue
                } else {
                    Write-Warning "[sandbox] Repair-WinGetPackageManager cmdlet not available even after importing Microsoft.WinGet.Client."
                }
            } catch {
                Write-Warning "[sandbox] Failed to repair/install winget: $($_.Exception.Message)"
            }

            # Re-check after attempted repair/install
            $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        }

        if ($wingetCmd) {
            $packages = @(
                @{ Id = 'Git.Git' },
                @{ Id = 'OpenJS.NodeJS' },      # Node.js (we'll pin major version below)
                @{ Id = 'Python.Python.3.11' },
                @{ Id = 'GnuWin32.curl' },
                @{ Id = 'GnuWin32.wget' },
                @{ Id = 'GitHub.cli' },
                @{ Id = 'Microsoft.PowerShell' },
                @{ Id = 'Microsoft.VisualStudio.2019.BuildTools' },
                @{ Id = 'Microsoft.VisualStudio.2022.BuildTools' }
            )
            foreach ($pkg in $packages) {
                try {
                    Write-Host "[sandbox] Installing or updating $($pkg.Id) via winget..."
                    winget install --id $($pkg.Id) -e --accept-package-agreements --accept-source-agreements --source winget | Out-Null
                } catch {
                    Write-Warning "[sandbox] winget failed for $($pkg.Id): $($_.Exception.Message)"
                }
            }

            # Ensure Node 22 specifically
            try {
                Write-Host "[sandbox] Installing or updating OpenJS.NodeJS version 22 via winget..."
                winget install --id OpenJS.NodeJS -e --version 22 --accept-package-agreements --accept-source-agreements | Out-Null
            } catch {
                Write-Warning "[sandbox] winget failed to install Node 22 explicitly: $($_.Exception.Message)"
            }
        } else {
            Write-Host "[sandbox] winget still not available; skipping tool installation."
        }
    } catch {
        Write-Warning "[sandbox] winget bootstrap phase failed: $($_.Exception.Message)"
    }

    Write-Host "[sandbox] Initial bootstrap: ensuring Microsoft.PowerShell.Archive / Expand-Archive is available..."
    try {
        $archiveCmd = Get-Command -Name Expand-Archive -ErrorAction Ignore
        if (-not $archiveCmd) {
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

    Write-Host "[sandbox] Initial bootstrap: ensuring Visual Studio Build Tools are installed..."
    try {
        Install-Module -Name VSSetup -Force -Scope AllUsers -AllowClobber -ErrorAction SilentlyContinue -Confirm:$false
        Import-Module VSSetup -ErrorAction SilentlyContinue
        $vsInstallPath = "C:\BuildTools"
        $vsMarkerFile  = Join-Path $vsInstallPath ".install-complete"

        if (-not (Test-Path $vsMarkerFile)) {
            $vsUrl = "https://aka.ms/vs/17/release/vs_BuildTools.exe"
            $vsExe = Join-Path $env:TEMP "vs_BuildTools.exe"

            Write-Host "[sandbox] Downloading VS Build Tools bootstrapper from $vsUrl ..."

            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -L "$vsUrl" -o "$vsExe"
            } elseif (Get-Command wget -ErrorAction SilentlyContinue) {
                & wget "$vsUrl" -O "$vsExe"
            } else {
                throw "Neither curl.exe nor wget is available to download VS Build Tools."
            }

            if (-not (Test-Path $vsExe)) {
                throw "VS Build Tools bootstrapper download failed; '$vsExe' not found."
            }

            Write-Host "[sandbox] Installing VS Build Tools silently to $vsInstallPath ... (this can take several minutes)"

            & $vsExe `
                --quiet --wait --norestart `
                --installPath "$vsInstallPath" `
                --add Microsoft.VisualStudio.Workload.VCTools `
                --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools `
                --add Microsoft.VisualStudio.Workload.MSBuildTools

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[sandbox] VS Build Tools installer exited with code $LASTEXITCODE."
            } else {
                New-Item -ItemType Directory -Path $vsInstallPath -Force | Out-Null
                New-Item -ItemType File -Path $vsMarkerFile -Force | Out-Null
                Write-Host "[sandbox] VS Build Tools installation completed."
            }
        } else {
            Write-Host "[sandbox] VS Build Tools already marked as installed at $vsInstallPath."
        }
    } catch {
        Write-Warning "[sandbox] Failed to ensure VS Build Tools: $($_.Exception.Message)"
    }

    Write-Host "[sandbox] Restarting start-runner.ps1 under updated environment..."
    $scriptPath = $MyInvocation.MyCommand.Path
    try {
        if (-not $scriptPath) {
            throw "Script path not available from MyInvocation.MyCommand.Path"
        }

        $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($pwshCmd) {
            $pwsh = $pwshCmd.Source
        } else {
            $pwsh = 'powershell.exe'
        }

        $args = @(
            '-File', $scriptPath,
            '-RepoUrl', $RepoUrl,
            '-RunnerVersion', $RunnerVersion,
            '-RunnerLabels', $RunnerLabels,
            '-RunnerToken', $RunnerToken,
            '-SkipBootstrap'
        )

        Write-Host "[sandbox] About to run: $pwsh $($args -join ' ')"

        # Use a single argument string for widest compatibility with older PowerShell
        $argString = $args -join ' '
        Start-Process -FilePath $pwsh -ArgumentList $argString -NoNewWindow
    } catch {
        Write-Error "[sandbox] Failed to restart start-runner.ps1 under updated environment: $($_.Exception.Message)"
        Read-Host "[sandbox] Error during bootstrap (restart). Press Enter to close this window"
    }

    exit 0
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