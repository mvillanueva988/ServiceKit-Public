# Codebase Structure

**Analysis Date:** 2026-03-10

## Directory Layout

```
Toolkit/                          # Project root
├── main.ps1                      # Entry point: module loader + interactive menu loop
├── Run.bat                       # UAC elevation wrapper; launches main.ps1
├── Launch.ps1                    # Remote launcher: auto-update from GitHub Releases
├── Bootstrap-Tools.ps1           # Downloads optional third-party tools from manifest
├── Release.ps1                   # Packages project into dist/PCTk-YYYY.MM.DD.zip
├── CHANGELOG.md                  # Version history
├── COMPATIBILITY.md              # Windows SKU/version compatibility notes
├── README.md                     # Project documentation
├── core/                         # Async job orchestration
│   └── JobManager.ps1            # Invoke-AsyncToolkitJob, Wait-ToolkitJobs
├── modules/                      # Functional domains (one file per feature area)
│   ├── Apps.ps1                  # Win32 + UWP app listing and silent uninstall
│   ├── Cleanup.ps1               # Temp file scanning and deletion
│   ├── Debloat.ps1               # Bloat service detection and disabling
│   ├── Diagnostics.ps1           # BSOD history, driver backup, PRE/POST snapshots
│   ├── Maintenance.ps1           # DISM + SFC system repair
│   ├── Network.ps1               # NIC power-save disable + TCP/IP global tweaks
│   ├── Performance.ps1           # Visual effects profiles + power plan
│   ├── Privacy.ps1               # Registry privacy profiles (Basic/Medio/Agresivo)
│   ├── RestorePoint.ps1          # System Restore checkpoint creation
│   ├── StartupManager.ps1        # Run/RunOnce registry startup entry management
│   └── Telemetry.ps1             # Windows telemetry service and registry tweaks
├── utils/                        # UX support (not OS operations)
│   └── HelpContent.ps1           # Get-ToolkitHelp — contextual help per topic
├── tools/                        # External tool declarations
│   └── manifest.json             # Tool registry: name, URL, SHA-256, category
├── output/                       # Runtime-generated output (git-ignored)
│   └── driver_backup/            # Exported third-party and network drivers (option 11)
├── dist/                         # Release ZIPs produced by Release.ps1 (git-ignored)
│   └── PCTk-YYYY.MM.DD.zip       # Versioned distribution archive
├── Logs/                         # Development session logs (not shipped in dist)
└── .gsd/                         # GSD project management (not shipped in dist)
```

> **Note:** `tools/bin/` is created at runtime by `Bootstrap-Tools.ps1` and is git-ignored. It holds downloaded third-party executables (Autoruns, ShutUp10++, etc.).

## Directory Purposes

**`core/`:**

- Purpose: Shared async execution primitives used by all heavy-operation modules
- Contains: `JobManager.ps1` with `Invoke-AsyncToolkitJob` and `Wait-ToolkitJobs`
- Key files: `core/JobManager.ps1`
- Rule: Only generic job infrastructure goes here. No feature-specific logic.

**`modules/`:**

- Purpose: One file per functional domain of the toolkit
- Contains: Paired worker + dispatcher functions, plus any supporting private helpers (prefixed with `_`)
- Pattern: Every module that runs heavy work exposes `Start-*Process` (dispatcher) which calls `Invoke-AsyncToolkitJob` from `core/JobManager.ps1`
- Key files: `modules/Debloat.ps1`, `modules/Cleanup.ps1`, `modules/Network.ps1`, `modules/Performance.ps1`, `modules/Diagnostics.ps1`

**`utils/`:**

- Purpose: Non-OS helpers that support UX but do not touch system settings
- Contains: `HelpContent.ps1` with `Get-ToolkitHelp`
- Rule: Nothing in `utils/` should call CIM, Registry, or system commands. Pure display/formatting only.

**`tools/`:**

- Purpose: Declare optional third-party tools that can be downloaded on demand
- Contains: `manifest.json` (declarative registry), `bin/` (runtime binaries, git-ignored)
- Key files: `tools/manifest.json`

**`output/`:**

- Purpose: Runtime artifacts written by the toolkit during user sessions
- Generated: Yes (created at runtime if absent)
- Committed: No (git-ignored)
- Contains: PRE/POST diagnostic snapshots, driver backup exports

**`dist/`:**

- Purpose: Release archives built by `Release.ps1`
- Generated: Yes
- Committed: No (git-ignored)

## Key File Locations

**Entry Points:**

- `Run.bat`: UAC elevation → `main.ps1`
- `main.ps1`: Module loader and menu loop — the single controller for all user interactions
- `Launch.ps1`: Remote/distribution entry point with auto-update

**Async Infrastructure:**

- `core/JobManager.ps1`: `Invoke-AsyncToolkitJob` + `Wait-ToolkitJobs`

**Feature Modules:**

- `modules/Debloat.ps1`: `Disable-BloatServices` (worker), `Start-DebloatProcess` (dispatcher)
- `modules/Cleanup.ps1`: `_Get-CleanupPaths`, `Get-CleanupPreview`, `Start-CleanupProcess`
- `modules/Network.ps1`: `Optimize-Network` (worker + sync — no dispatcher needed)
- `modules/Maintenance.ps1`: `Start-MaintenanceProcess` (dispatcher)
- `modules/Performance.ps1`: `Set-BalancedVisuals`, `Set-MaxPerformanceVisuals`, `Restore-DefaultVisuals`
- `modules/Diagnostics.ps1`: `Get-BsodHistory`, `Get-DriverBackup`, `Get-SystemSnapshot`
- `modules/Apps.ps1`: `Get-InstalledWin32Apps`, `Get-InstalledUwpApps`, `Invoke-SilentUninstall`
- `modules/Privacy.ps1`: `Set-PrivacyProfile` with `-Level Basic|Medio|Agresivo`
- `modules/StartupManager.ps1`: `Get-StartupEntries`, `Set-StartupEntryState`
- `modules/RestorePoint.ps1`: `New-ToolkitRestorePoint`

**Configuration:**

- `tools/manifest.json`: Tool declarations (name, URL, SHA-256, category, filename)

**Distribution:**

- `Release.ps1`: Packages `dist/PCTk-YYYY.MM.DD.zip` excluding `.git`, `.gsd`, `.github`, `Logs`, `output`, `dist`, `tools/bin`, `Release.ps1`, `GSD-STYLE.md`, `CHANGELOG.md`, `*.code-workspace`

## Naming Conventions

**Files:**

- Modules: `PascalCase.ps1` matching the domain noun (e.g., `Cleanup.ps1`, `StartupManager.ps1`)
- Entry scripts: `PascalCase.ps1` matching the action verb (e.g., `Bootstrap-Tools.ps1`, `Release.ps1`)
- Launchers: Noun-only PascalCase (`Launch.ps1`, `main.ps1` is the exception — lowercase)

**Functions:**

- Public: `Verb-Noun` following PowerShell approved verbs (`Get-`, `Set-`, `Invoke-`, `Start-`, `New-`, `Wait-`, `Disable-`, `Optimize-`)
- Private helpers: Prefixed with underscore `_` and still `Verb-Noun` (`_Get-CleanupPaths`)
- Async dispatchers: Always `Start-[DomainName]Process` pattern

**Variables:**

- Script-scope: `$script:CamelCase` (e.g., `$script:_loadErrors`, `$script:DesktopPath`)
- Local: `$camelCase` for working variables, `$PascalCase` for parameters
- Type annotations: Explicit `[type]` declarations on all significant variables (`[string]`, `[int]`, `[bool]`, `[object[]]`)

**Parameters:**

- All public functions declare explicit `[Parameter()]` attributes and `[type]` annotations
- Optional parameters use `$PSBoundParameters.ContainsKey()` to distinguish omitted from default

## Where to Add New Code

**New feature module (e.g., a new optimization category):**

- Implementation: Create `modules/NewFeature.ps1`
- Follow the two-function contract: one pure worker + one `Start-NewFeatureProcess` dispatcher
- Add `Set-StrictMode -Version Latest` at the top
- Register the menu entry in `main.ps1` `Show-MainMenu` function and add a handler case in the `switch`

**New utility function:**

- If it displays help/info with no OS calls: add to `utils/HelpContent.ps1`
- If it's a shared OS helper used by multiple modules: consider `utils/` with a new file

**New async operation in an existing module:**

- Add the worker function directly in the existing module file
- Add a dispatcher following the serialization pattern (serialize with `${Function:WorkerName}.ToString()`, embed in `[scriptblock]::Create`)
- Call `Invoke-AsyncToolkitJob` from `core/JobManager.ps1`

**New external tool:**

- Add an entry to `tools/manifest.json` with `name`, `filename`, `launchExe`, `url`, `sha256`, `category`, `approxSizeMB`
- Add launch logic in `main.ps1` Tools submenu handler

## Special Directories

**`tools/bin/`:**

- Purpose: Downloaded third-party executables (Autoruns.exe, OOSU10.exe, etc.)
- Generated: Yes (by `Bootstrap-Tools.ps1`)
- Committed: No (git-ignored)

**`output/`:**

- Purpose: User-facing outputs — snapshots, backups
- Generated: Yes (at runtime)
- Committed: No (git-ignored)

**`dist/`:**

- Purpose: Release distribution ZIPs
- Generated: Yes (by `Release.ps1`)
- Committed: No (git-ignored)

**`.gsd/`:**

- Purpose: GSD project management files (plans, phases, roadmap, codebase docs)
- Committed: Yes (dev/planning artifacts)
- Shipped in dist: No (excluded by `Release.ps1`)

---

_Structure analysis: 2026-03-10_
