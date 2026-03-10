---
phase: "08"
plan: "03"
subsystem: "launcher"
tags: ["security", "webclient", "invoke-webrequest", "validation", "hardening"]

requires:
  - "08-01: Safety & Correctness (admin check, spooler warning, restore point cooldown)"
  - "08-02: UX & Async (CIM caching, async jobs, maintenance output)"

provides:
  - "Launch.ps1 hardened: deprecated WebClient replaced, unconfigured repo detected before any network call"

affects:
  - "End users: clear error on misconfigured Launch.ps1 instead of silent GitHub API failure"

tech-stack:
  added: []
  patterns:
    - "Invoke-WebRequest with -UseBasicParsing -TimeoutSec -ErrorAction Stop for safe HTTP downloads"
    - "Early-exit guard pattern: validate config before executing side effects"

key-files:
  created: []
  modified:
    - "Launch.ps1"

decisions:
  - "Preflight placed at script scope (outside function) so it fires before Invoke-Launch is even called — no way to bypass"
  - "Match pattern is TU_ (not just exact string) to catch TU_USUARIO/TU_REPO or any other placeholder variant"
  - "TimeoutSec 60 (vs context suggestion of 30) per plan instructions — larger ZIP downloads on slow connections"

metrics:
  duration: "< 5 minutes"
  completed: "2026-03-10"
---

# Phase 8 Plan 03: Launch.ps1 Hardening Summary

**One-liner:** Replaced deprecated `[System.Net.WebClient]` with `Invoke-WebRequest` and added a pre-flight guard that exits early if `$GitHubRepo` still holds a placeholder value.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Replace WebClient with Invoke-WebRequest | `d547e8d` | Launch.ps1 |
| 2 | Pre-flight check for placeholder repo | `d60cc14` | Launch.ps1 |

## What Was Implemented

### Task 1 — WebClient → Invoke-WebRequest

Replaced the `[System.Net.WebClient]::new()` + `DownloadFile()` + `Dispose()` pattern with:

```powershell
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipDest -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
```

- `WebClient` is a legacy .NET class; `Invoke-WebRequest` is the idiomatic PowerShell approach
- `-UseBasicParsing` avoids IE DOM dependency (required on Server Core / headless systems)
- `-TimeoutSec 60` adds an explicit network timeout that `WebClient.DownloadFile` lacked
- `-ErrorAction Stop` ensures errors are catchable in the existing `try/catch` block
- The outer error handling and local fallback logic are **unchanged**

### Task 2 — Pre-flight: placeholder repo guard

Added immediately after the `$GitHubRepo` / `$InstallPath` declaration block, before any derived variables or network calls:

```powershell
if ($GitHubRepo -match 'TU_' -or $GitHubRepo -eq '') {
    Write-Host ''
    Write-Host '  [!] Launch.ps1 no esta configurado.' -ForegroundColor Red
    Write-Host '      Edita Launch.ps1 y reemplaza $GitHubRepo con tu repositorio.' -ForegroundColor DarkGray
    Write-Host '      Ejemplo: $GitHubRepo = "tu-usuario/pc-toolkit"' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Presiona Enter para salir'
    exit 1
}
```

- Fires at **script scope** (before `Invoke-Launch` is called) — cannot be bypassed
- Catches both exact `TU_USUARIO/TU_REPO` and any future `TU_`-prefixed placeholders
- Pauses for Enter before exiting so the window doesn't flash and close in Run.bat scenarios

## Deviations from Plan

None — plan executed exactly as written.

## Next Phase Readiness

Phase 8 (Codebase Polish) is now fully complete:
- 08-01: Safety & Correctness ✅
- 08-02: UX & Async ✅  
- 08-03: Launch.ps1 Hardening ✅

Ready to advance to Phase 9.
