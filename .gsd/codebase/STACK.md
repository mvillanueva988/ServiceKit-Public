# Technology Stack

**Analysis Date:** 2026-03-10

## Languages

**Primary:**

- PowerShell 5.1 — All toolkit code: main entry point, modules, core, utils, scripts
  - `#Requires -Version 5.1` enforced at all entry points (`main.ps1`, `Bootstrap-Tools.ps1`, `Launch.ps1`)
  - `Set-StrictMode -Version Latest` declared in every `.ps1` file

**Secondary:**

- JSON — Tool manifest configuration: `tools/manifest.json`

## Runtime

**Environment:**

- Windows PowerShell 5.1 (minimum) — ships with Windows 8.1/2012R2+
- Target OS: Windows 10 (Build 19041+) and Windows 11 (Build 22000+)
- Architecture: x64 and x86 supported (branching in `Apps.ps1` registry paths)

**Package Manager:**

- None — zero external package managers (no NuGet, no PSGallery, no pip)
- Lockfile: Not applicable

## Frameworks

**Core:**

- None — pure PowerShell with zero framework dependencies
- Async orchestration provided by `core/JobManager.ps1` wrapping native `Start-Job`

**Testing:**

- Not detected — no Pester or other test framework present

**Build/Dev:**

- `Release.ps1` — custom ZIP packaging + optional GitHub Releases publisher
- `Bootstrap-Tools.ps1` — on-demand binary downloader for external GUI tools

## Key Dependencies

**None — zero runtime dependencies.** The toolkit uses exclusively:

- **CIM/WMI**: `Get-CimInstance` with `Win32_Processor`, `Win32_VideoController`, `Win32_ComputerSystem`, `Win32_PhysicalMemory`, `Win32_UserProfile`, `Win32_PageFileUsage`, `Win32_SystemEnclosure`, `Win32_Battery`, `Win32_QuickFixEngineering` — `modules/Telemetry.ps1`, `main.ps1`
- **Windows Storage API**: `Get-PhysicalDisk`, `Get-StorageReliabilityCounter` — `modules/Telemetry.ps1`
- **Windows Network API**: `Get-NetAdapter` — `modules/Network.ps1`
- **Windows Event Log**: `Get-WinEvent` — `modules/Diagnostics.ps1`
- **Windows Registry**: `Get-ItemProperty`, `Set-ItemProperty`, `New-Item` on `HKLM:\` and `HKCU:\` — all modules
- **System Restore API**: `Checkpoint-Computer`, `Enable-ComputerRestore` — `modules/RestorePoint.ps1`
- **CLI tools (inbox Windows)**: `netsh`, `DISM`, `sfc`, `ipconfig` — `modules/Network.ps1`, `modules/Maintenance.ps1`
- **.NET BCL types (inline)**: `System.Net.HttpWebRequest`, `System.Net.WebClient`, `System.IO.FileStream`, `System.Collections.Generic.List[T]`, `System.Collections.Generic.HashSet[T]`, `System.Management.Automation.Job` — various files

## Configuration

**Runtime Configuration:**

- None — no `.env` files, no config JSON for the toolkit itself
- OS detection performed at runtime via registry key `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
- x64/x86 branching via `[Environment]::Is64BitOperatingSystem`

**Tool Manifest:**

- `tools/manifest.json` — declares 15 external GUI tools with URL, filename, category, SHA-256 (most empty — points to latest builds), and approx size
- Categories: `arranque`, `privacidad`, `apps`, `procesos`, `disco`, `hardware`, `drivers`, `limpieza`, `setup`
- SHA-256 fields are mostly empty (tools point to "latest" URLs from Sysinternals, SourceForge, etc.)

**Build:**

- `Release.ps1` — configurable via `-Version` and `-Repo` params; reads `$GitHubRepo` from `Launch.ps1` if `-Repo` omitted
- `Launch.ps1` — hardcoded `$GitHubRepo` and `$InstallPath` at top of file (requires manual configuration)

## Platform Requirements

**Development:**

- Windows 10/11 with PowerShell 5.1
- VS Code with PowerShell extension (`.code-workspace` present)
- Git for version control

**Production:**

- Windows 10 (Build 19041+) or Windows 11
- Administrator privileges required for service management, registry writes to `HKLM:\`, DISM/SFC execution, and restore point creation
- Internet access optional — required only for `Bootstrap-Tools.ps1` and `Launch.ps1` auto-update

---

_Stack analysis: 2026-03-10_
