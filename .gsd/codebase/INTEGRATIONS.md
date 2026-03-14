# External Integrations

**Analysis Date:** 2026-03-10

## APIs & External Services

**GitHub REST API:**

- Used by `Release.ps1` to publish releases and `Launch.ps1` to auto-update
  - `GET https://api.github.com/repos/{repo}/releases/latest` — fetch latest release metadata and ZIP asset URL
  - `POST https://api.github.com/repos/{repo}/releases` — create new release tag
  - `POST {upload_url}?name={asset}` — upload ZIP file as release asset
  - Auth: `Authorization: token $env:GITHUB_TOKEN` (read from environment variable)
  - Headers: `Accept: application/vnd.github+json`
  - UserAgent: `PCTk-Launcher` (for `Invoke-RestMethod` calls in `Launch.ps1`)
  - TLS: forced to TLS 1.2 via `[Net.ServicePointManager]::SecurityProtocol` in `Launch.ps1`

## External Tool Download Sources

Binary tools are NOT bundled. `Bootstrap-Tools.ps1` downloads them on demand to `tools/bin/` using `System.Net.HttpWebRequest`. Sources declared in `tools/manifest.json`:

**Sysinternals (Microsoft):**
- `https://live.sysinternals.com/Autoruns.exe` — Autoruns GUI
- `https://live.sysinternals.com/autorunsc.exe` — Autoruns CLI
- `https://live.sysinternals.com/Procmon.exe` — Process Monitor
- `https://live.sysinternals.com/procexp.exe` — Process Explorer
- `https://live.sysinternals.com/Tcpview.exe` — TCP/UDP view

**O&O Software:**
- `https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe` — ShutUp10++ privacy tweaks

**GitHub Releases (third-party):**
- `https://github.com/Klocman/Bulk-Crap-Uninstaller/releases/download/v5.7/BCUninstaller_5.7_portable.zip` — BCUninstaller
- `https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.exe` — WinUtil

**SourceForge:**
- `https://sourceforge.net/projects/crystaldiskinfo/files/latest/download` — CrystalDiskInfo
- `https://sourceforge.net/projects/crystaldiskmark/files/latest/download` — CrystalDiskMark

**Vendor Sites:**
- `https://www.diskanalyzer.com/files/wiztree_portable.zip` — WizTree
- `https://www.hwinfo.com/files/hwi_portable.zip` — HWiNFO64
- `https://download.cpuid.com/cpu-z/cpu-z_portable.zip` — CPU-Z
- `https://www.wagnardsoft.com/DDU/DDU-setup.exe` — DDU (Display Driver Uninstaller)
- `https://download.bleachbit.org/BleachBit-portable.zip` — BleachBit

**Private / Incomplete:**
- `winslop` — URL intentionally blank in manifest; must be set manually before use

## Data Storage

**Databases:**

- None — no database of any kind

**File Storage:**

- Local filesystem only
  - Downloaded binaries: `tools/bin/` (gitignored)
  - Toolkit output/logs: `output/`, `Logs/` directories
  - Release ZIP artifacts: `dist/` (gitignored)
  - Temp files during release: `$env:TEMP\PCTk-release-staging`, `$env:TEMP\PCTk-update.zip`, `$env:TEMP\PCTk-toolsbin-backup`

**Caching:**

- None — no application-level cache

## Authentication & Identity

**Auth Provider:**

- None for the toolkit at runtime — no user login or identity system

**GitHub Token (release workflow only):**
- `$env:GITHUB_TOKEN` environment variable
- Required only when running `Release.ps1 -Publish`
- Not required for `Launch.ps1` read-only GitHub API calls (public repos) or for local toolkit usage

## Monitoring & Observability

**Error Tracking:**

- None — no external error tracking service

**Logs:**

- Console-only (Write-Host with ForegroundColor): structured output in `main.ps1` menus
- Module functions return structured `PSCustomObject` with `.Success`, `.Errors`, `.Applied` properties for caller-side display
- Load errors collected in `$script:_loadErrors` list in `main.ps1`, shown in the main menu header

## CI/CD & Deployment

**Hosting:**

- GitHub (repository hosting + Releases for distribution)
- No cloud hosting — toolkit runs locally on end-user Windows machines

**CI Pipeline:**

- None detected — no GitHub Actions workflows, no Azure Pipelines or similar

**Release Process:**

- Manual: developer runs `Release.ps1 -Version X.Y.Z -Publish` locally
- Produces ZIP in `dist/`, uploads to GitHub Releases via API

## Environment Configuration

**Required env vars (runtime):**

- None — toolkit runs without any environment variables configured

**Required env vars (release workflow only):**

- `GITHUB_TOKEN` — personal access token with `repo` scope for publishing releases

**Secrets location:**

- No secrets stored in files — `GITHUB_TOKEN` injected via shell environment at release time only

## Webhooks & Callbacks

**Incoming:**

- None

**Outgoing:**

- None — the toolkit makes no outbound callbacks; all external communication is user-initiated (bootstrap downloads, auto-update on launch)

## Windows OS Integrations (Internal)

These are not "external" APIs but are essential platform integrations:

**CIM/WMI Provider:**
- `Win32_Processor`, `Win32_VideoController`, `Win32_ComputerSystem`, `Win32_PhysicalMemory`, `Win32_UserProfile`, `Win32_PageFileUsage`, `Win32_SystemEnclosure`, `Win32_Battery`, `Win32_QuickFixEngineering`
- Used in `modules/Telemetry.ps1` and `main.ps1`

**Windows Registry (HKLM/HKCU):**
- Network adapter power properties: `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-...}` — `modules/Network.ps1`
- Visual effects: `HKCU:\Control Panel\Desktop`, `HKCU:\Control Panel\Desktop\WindowMetrics`, `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\...` — `modules/Performance.ps1`
- Privacy/telemetry policies: `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection`, `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo`, and 10+ other keys — `modules/Privacy.ps1`
- Startup entries: `HKLM/HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run|RunOnce` — `modules/StartupManager.ps1`
- Installed apps: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` and WOW6432Node equivalent — `modules/Apps.ps1`

**Windows Event Log:**
- `System` log, Event IDs 41 (Kernel-Power), 1001 (BugCheck), 6008 (EventLog) — `modules/Diagnostics.ps1`

**Windows Storage API:**
- `Get-PhysicalDisk`, `Get-StorageReliabilityCounter` (SMART counters) — `modules/Telemetry.ps1`

**System Restore API:**
- `Checkpoint-Computer`, `Enable-ComputerRestore` — `modules/RestorePoint.ps1`

---

_Integration audit: 2026-03-10_
