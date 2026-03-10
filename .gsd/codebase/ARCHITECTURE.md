# Architecture

**Analysis Date:** 2026-03-10

## Pattern Overview

**Overall:** Layered Plugin Architecture with Async Job Dispatch

**Key Characteristics:**

- Three strictly separated layers: core orchestration, functional modules, and OS-integration utilities
- All heavy operations run in isolated PowerShell background jobs (`Start-Job`) to keep the main console responsive
- `main.ps1` acts as both the bootstrapper (dot-source loader) and the UI controller (menu loop)
- Modules follow a consistent two-function contract: one pure worker function + one async dispatcher wrapper
- No external dependencies at runtime — all functionality uses native PowerShell cmdlets, CIM/WMI, `netsh`, and Windows Registry access

## Layers

**Entry & UI Layer (`main.ps1`):**

- Purpose: Load all modules, render the interactive console menu, dispatch user selections to module functions
- Location: `main.ps1`
- Contains: Module loader loop, `Show-MainMenu` function, all switch/case user-interaction handlers
- Depends on: Everything in `core/`, `utils/`, `modules/`
- Used by: `Run.bat` (UAC elevation), `Launch.ps1` (auto-update launcher)

**Core Layer (`core/`):**

- Purpose: Async job lifecycle management — launch jobs and block-wait with a visual spinner
- Location: `core/JobManager.ps1`
- Contains: `Invoke-AsyncToolkitJob`, `Wait-ToolkitJobs`
- Depends on: Nothing (no imports; consumed by modules and main.ps1)
- Used by: Module async dispatcher functions (e.g., `Start-DebloatProcess`, `Start-CleanupProcess`)

**Modules Layer (`modules/`):**

- Purpose: Each file owns one functional domain of the toolkit (network, cleanup, debloat, etc.)
- Location: `modules/*.ps1`
- Contains: One pure worker function + one async dispatcher per domain (see Abstractions section)
- Depends on: `core/JobManager.ps1` for async dispatch
- Used by: `main.ps1` user-selection handlers

**Utils Layer (`utils/`):**

- Purpose: Contextual help content and UX support — not OS operations
- Location: `utils/HelpContent.ps1`
- Contains: `Get-ToolkitHelp` with `ValidateSet` tab-completion for topics
- Depends on: Nothing
- Used by: `main.ps1` help sub-menus

**Tools Infrastructure (`tools/`, `Bootstrap-Tools.ps1`):**

- Purpose: Declare, download, and verify optional third-party GUI tools (Autoruns, ShutUp10++, etc.)
- Location: `tools/manifest.json` (declarations), `Bootstrap-Tools.ps1` (downloader), `tools/bin/` (binaries, git-ignored)
- Contains: JSON manifest with name, URL, SHA-256, category; download script with progress bar
- Depends on: `System.Net.HttpWebRequest`, native PowerShell zip extraction
- Used by: `main.ps1` Tools submenu (`[T]`)

## Data Flow

**Standard Async Operation (e.g., Cleanup, Debloat, Maintenance):**

1. User selects a menu option in `main.ps1`
2. `main.ps1` calls the module's `Get-*Preview` or confirmation prompt (synchronous)
3. User confirms → `main.ps1` calls the module's `Start-*Process` dispatcher
4. Dispatcher serializes the worker function body into a string, embeds it in a `[scriptblock]` that re-defines the function, then calls `Invoke-AsyncToolkitJob` with that scriptblock
5. `Invoke-AsyncToolkitJob` calls `Start-Job` and returns a `[System.Management.Automation.Job]` object
6. `main.ps1` passes the job to `Wait-ToolkitJobs`, which polls with a spinner (120ms intervals)
7. On completion, `Wait-ToolkitJobs` calls `Receive-Job -AutoRemoveJob -Wait` and returns the result object
8. `main.ps1` reads typed properties from the result (`PSCustomObject`) and prints the outcome

**Synchronous Read Operations (e.g., BSOD History, App List, Startup Manager):**

1. User selects option
2. `main.ps1` calls the module function directly (no async wrapper needed)
3. Function uses CIM/WMI, Registry, or Event Log queries
4. Returns `PSCustomObject[]` with typed properties
5. `main.ps1` iterates and renders the table

**External Tool Launch (Tools submenu):**

1. User selects `[T]` → `main.ps1` reads `tools/manifest.json`
2. Checks for binary in `tools/bin/`; if missing, prompts to run `Bootstrap-Tools.ps1`
3. If present, launches with `Start-Process`

**State Management:**

- No persistent in-memory state between menu selections
- Diagnostic snapshots (PRE/POST) are written to `output/` as JSON or structured text files
- Driver backups written to `output/driver_backup/`
- Script-scope variables in `main.ps1` (`$script:_loadErrors`) used only for load-time error accumulation

## Key Abstractions

**Two-Function Module Contract:**

- Every module that performs heavy work exposes exactly two public functions:
  - Worker: Pure function, directly testable, returns a typed `PSCustomObject`
    - Examples: `Disable-BloatServices`, `Invoke-CleanupJob`, `Optimize-Network`, `Invoke-MaintenanceJob`
  - Dispatcher: Serializes the worker into a `Start-Job`-safe scriptblock, calls `Invoke-AsyncToolkitJob`
    - Examples: `Start-DebloatProcess` (`modules/Debloat.ps1`), `Start-CleanupProcess` (`modules/Cleanup.ps1`), `Start-MaintenanceProcess` (`modules/Maintenance.ps1`)
- This contract is necessary because `Start-Job` runs in an isolated runspace — functions defined in the parent session are not available unless explicitly serialized

**Job Isolation Serialization Pattern:**

- Dispatcher captures the worker function body with `${Function:WorkerFunctionName}.ToString()`
- Embeds it in a `[scriptblock]::Create(@"... param(...) $fnBody ..."@)` heredoc
- This re-defines the function inside the job's runspace, making it self-contained

**Typed Return Objects:**

- All module worker functions return `[PSCustomObject]` with named, typed properties
- Example from `Disable-BloatServices`: `@{ Disabled=[int]; Failed=[int]; Errors=[string[]] }`
- Example from `Optimize-Network`: `@{ AdaptersOptimized=[string[]]; Success=[bool] }`
- Enables `Set-StrictMode -Version Latest` compliance throughout

**OS Context Detection (main.ps1):**

- Windows version, edition, build, and architecture resolved at menu render time via `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
- `$isWin11`, `$isHome`, `$isLtsc` boolean flags used to conditionally show/hide menu items

## Entry Points

**`Run.bat`:**

- Location: `Run.bat`
- Triggers: Double-click or shortcut in Explorer
- Responsibilities: Detects admin rights via `net session`; if not elevated, re-launches itself with `Start-Process -Verb RunAs` (UAC prompt); then calls `main.ps1` via `powershell.exe -ExecutionPolicy Bypass`

**`main.ps1`:**

- Location: `main.ps1`
- Triggers: Invoked by `Run.bat` or directly from an elevated PowerShell console
- Responsibilities: Dot-sources all scripts in `core/`, `utils/`, `modules/`; collects load errors; runs the `Show-MainMenu` loop

**`Launch.ps1`:**

- Location: `Launch.ps1`
- Triggers: Remote deployment / distribution scenario
- Responsibilities: Hits GitHub Releases API to get latest ZIP asset, downloads it, preserves `tools/bin/`, extracts to `$InstallPath` (`C:\PCTk`), then launches `main.ps1`; falls back to local copy if network is unavailable

**`Bootstrap-Tools.ps1`:**

- Location: `Bootstrap-Tools.ps1`
- Triggers: Manual or called from the Tools submenu in `main.ps1`
- Responsibilities: Reads `tools/manifest.json`, downloads binaries to `tools/bin/`, optionally verifies SHA-256

## Error Handling

**Strategy:** Fail-silent on known-absent items; surface errors as structured return data; load errors collected and displayed in menu header

**Patterns:**

- Module functions use `try/catch` with typed exception filters (e.g., `[Microsoft.PowerShell.Commands.ServiceCommandException]`) to silently skip services that don't exist on a given Windows SKU
- Load errors from dot-sourcing are accumulated in `$script:_loadErrors` (a `[System.Collections.Generic.List[string]]`) and displayed at the top of the main menu
- Job errors are captured in the worker's return object (e.g., `Errors=[string[]]`) rather than thrown, so `Wait-ToolkitJobs` can always return a usable result
- `ErrorAction SilentlyContinue` used extensively for CIM/WMI queries that may not apply to all Windows editions

## Cross-Cutting Concerns

**Logging:** No persistent log file for operations. Results printed to console. Diagnostic snapshots written to `output/`.

**Validation:** User input validated inline in `main.ps1` selection handlers (regex, range checks, `[q]` cancellation paths).

**Elevation:** Enforced at the `Run.bat` boundary. All PowerShell code assumes it is already running as Administrator.

**StrictMode:** `Set-StrictMode -Version Latest` declared in every `.ps1` file individually (not inherited from parent scope due to dot-sourcing).

**Compatibility:** Windows 10 (build 10240+) and Windows 11. SKU-specific behavior gated by `$isWin11`, `$isHome`, `$isLtsc` flags. `#Requires -Version 5.1` in entry points.

---

_Architecture analysis: 2026-03-10_
