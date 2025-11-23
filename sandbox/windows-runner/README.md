# Windows Sandbox CI Runner

This folder contains scripts to spin up a **throwaway Windows GitHub Actions runner** inside **Windows Sandbox**, and to hook it up to this repo’s CI.

## Prerequisites

- Windows 10/11 Pro or Enterprise with **Windows Sandbox** enabled.
`Start-Process dism -ArgumentList '/online /enable-Feature /FeatureName:Containers-DisposableClientVM' -verb runas` [needs reboot]
- GitHub CLI (`gh`) installed and authenticated on the **host**.

## Files

- `start-sandbox-runner.ps1` – host-side helper that:
  - Uses `gh` to request a short‑lived registration token for the repo.
  - Generates a `.wsb` config under `sandbox/windows-runner/` that maps the repo into Sandbox.
  - Starts Windows Sandbox and auto-runs `start-runner.ps1` inside it.

- `start-runner.ps1` – in‑Sandbox bootstrap that:
  - Ensures core tools via `winget` when available (git, Node LTS, Python 3.11, curl/wget).
  - Downloads the GitHub Actions runner into `C:\actions-runner` and configures it.
  - Starts the runner and keeps the window open so you can see logs/errors.

## Usage

On the **host**, from the repo root:

```powershell
pwsh .\sandbox\windows-runner\start-sandbox-runner.ps1
```

This will:

1. Create/update `sandbox/windows-runner/cp-windows-runner.wsb`.
2. Launch Windows Sandbox.
3. Inside Sandbox, locate this repo on the desktop and run `start-runner.ps1` elevated.
4. Register a self‑hosted runner for `tyeth/wmerkens_vscode-circuitpython` with labels `self-hosted,windows,cp-sandbox`.

Leave the runner window open; it will pick up any GitHub Actions job that targets:

```yaml
runs-on: [self-hosted, windows, cp-sandbox]
```

Close Windows Sandbox when you are done to discard the environment.

## Customisation

The host script `start-sandbox-runner.ps1` accepts optional parameters so you can reuse this setup for other repos or labels, for example:

```powershell
pwsh .\sandbox\windows-runner\start-sandbox-runner.ps1 `
  -RepoOwner someuser `
  -RepoName some-repo `
  -RunnerLabels "self-hosted,windows,custom-label"
```

`start-runner.ps1` also has parameters (`RepoUrl`, `RunnerVersion`, `RunnerLabels`) that you can override if you want to experiment directly inside Sandbox.
