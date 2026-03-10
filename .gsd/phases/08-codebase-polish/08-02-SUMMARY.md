---
phase: "08"
plan: "02"
subsystem: ux-async
tags: [cim-caching, async, job-manager, maintenance, cleanup, apps]

dependency-graph:
  requires:
    - "08-01: Safety & Correctness (admin check, spooler warning, restore cooldown)"
    - "Core async pattern (Invoke-AsyncToolkitJob, Wait-ToolkitJobs)"
  provides:
    - "CIM hardware cached — no per-iteration CIM queries in menu header"
    - "Job failures visible — red error shown instead of silent empty result"
    - "Win32/UWP app lists loaded async with spinner"
    - "Cleanup preview scan async with spinner"
    - "DISM/SFC output captured, key lines surfaced, exit code 87 handled"
  affects:
    - "08-03: Launch.ps1 Hardening (unrelated, parallel plan)"

tech-stack:
  added: []
  patterns:
    - "Script-scoped lazy-init cache ($script:hwCached flag pattern)"
    - "Job failure surfacing via ChildJobs.Error before Receive-Job"
    - "Async job launcher pattern extended to Apps module"
    - "External process output capture via 2>&1 into string array"

key-files:
  created: []
  modified:
    - main.ps1
    - core/JobManager.ps1
    - modules/Apps.ps1
    - modules/Cleanup.ps1
    - modules/Maintenance.ps1

decisions:
  - "UWP filter applied in-memory after async load (not re-queried per filter change)"
  - "Failed jobs: show error + still call Receive-Job with SilentlyContinue to preserve return contract"
  - "DismOutput/SfcOutput captured as [string[]] via & exe 2>&1 (external process — no ErrorRecord mix)"

metrics:
  duration: "~30 min"
  completed: "2026-03-10"
---

# Phase 8 Plan 02: UX & Async Improvements Summary

**One-liner:** CIM caching + job error surfacing + async Apps/Cleanup/Maintenance output capture

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | CIM hardware caching | 82c8c00 | main.ps1 |
| 2 | Wait-ToolkitJobs error surfacing | ff87980 | core/JobManager.ps1 |
| 3 | Apps Win32 + UWP listing → async | ccde4c0 | modules/Apps.ps1, main.ps1 |
| 4 | Cleanup preview scan → async | 49dca97 | modules/Cleanup.ps1, main.ps1 |
| 5 | Maintenance DISM/SFC output capture | 835beab | modules/Maintenance.ps1, main.ps1 |

## What Was Implemented

### Task 1: CIM Hardware Info Caching
- Added `$script:hwCached`, `$script:hwComputer`, `$script:hwGPU` at script level before `Show-MainMenu`
- Inside `Show-MainMenu` menu loop, wrapped CIM queries in `if (-not $script:hwCached)` guard
- `Win32_ComputerSystem` and `Win32_VideoController` now queried exactly once per session
- Subsequent menu iterations use `$csHw = $script:hwComputer` / `[object[]] $allGpus = @($script:hwGPU)` from cache

### Task 2: Wait-ToolkitJobs Error Surfacing
- In `Wait-ToolkitJobs`, before `Receive-Job`, checks `$job.State -eq 'Failed'`
- If failed: extracts error from `$job.ChildJobs[].Error`, shows `[!] Trabajo '...' fallo: <message>` in Red
- Still calls `Receive-Job -AutoRemoveJob -Wait -ErrorAction SilentlyContinue` for cleanup (preserves return contract)
- Succeeds silently for normal jobs (original behavior unchanged)

### Task 3: Apps Win32 + UWP Listing → Async
- Added `Start-Win32AppsJob` and `Start-UwpAppsJob` to `modules/Apps.ps1`
- Both serialize the respective `Get-Installed*` function body into a job scriptblock
- In `main.ps1`, Win32 handler: calls `Start-Win32AppsJob`, waits with spinner into `$allWin32Apps`
- UWP handler: same pattern with `Start-UwpAppsJob` → `$allUwpApps`
- Filter applied in-memory per loop iteration via `Where-Object` on cached array
- No re-query on filter change — filter is fast in-memory operation after initial async load

### Task 4: Cleanup Preview Scan → Async
- Added `Start-CleanupPreviewJob` to `modules/Cleanup.ps1`
- Serializes `_Get-CleanupPaths` + `Get-CleanupPreview` into job scriptblock (same pattern as `Start-CleanupProcess`)
- `main.ps1` cleanup handler `'2'` now calls `Wait-ToolkitJobs -Jobs @(Start-CleanupPreviewJob)` instead of `Get-CleanupPreview` directly
- Spinner shows "Ejecutando trabajos... (1 activos)" while scan runs

### Task 5: Maintenance DISM/SFC Output Capture
- `Repair-WindowsSystem` changed from `DISM ... *> $null` to `& dism.exe ... 2>&1` captured in `[string[]] $dismOutput`
- Same for SFC: `& sfc.exe /scannow 2>&1` → `[string[]] $sfcOutput`
- Result object now includes `DismOutput` and `SfcOutput` alongside exit codes
- `main.ps1` handler `'3'` updated:
  - Exit code 87 gets specific message: "parametro invalido (puede requerir fuente de actualizacion de Windows)"
  - Non-zero exit: filters `DismOutput`/`SfcOutput` for lines matching `Error|Warning` (up to 5 lines)
  - Always shows `C:\Windows\Logs\CBS\CBS.log` as reference for detailed log

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Failed job Receive-Job cleanup**

- **Found during:** Task 2
- **Issue:** The plan said to use `Remove-Job -Force` for failed jobs, but this would break the return contract — callers expecting a result would get `$null` in the same way as before, but existing `Receive-Job` for failed jobs already silently returns nothing
- **Fix:** Keep calling `Receive-Job -AutoRemoveJob -Wait -ErrorAction SilentlyContinue` for failed jobs so cleanup happens correctly and return contract is minimally changed
- **Impact:** Same observable behavior for all callers (result is $null/empty on failure), but now error is visibly surfaced

None — plan executed as written except the deviation above.

## Next Phase Readiness

- 08-03 (Launch.ps1 Hardening) is independent — no blockers from this plan
- All changes are backward-compatible with existing callers
- `$script:hwCached` flag means hardware info won't update if hardware changes mid-session (acceptable: toolkit is single-session)
