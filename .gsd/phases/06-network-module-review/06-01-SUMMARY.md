---
phase: 06-network-module-review
plan: 01
subsystem: network
tags: [network, diagnostics, async, powershell]

requires:
  - phase: 05-portable-executable
    provides: Invoke-AsyncToolkitJob + Wait-ToolkitJobs (patron async base)

provides:
  - Get-NetworkDiagnostics en Network.ps1 (TCP AutoTuning, adaptadores activos, DNS IPv4, ping latencia)
  - Start-NetworkDiagnosticsProcess wrapper async en Network.ps1
  - Opcion [d] Diagnosticos de Red en networkLoop de main.ps1

affects: [06-02-network-verify]

tech-stack:
  added: []
  patterns:
    - "Función Get-NetworkDiagnostics retorna PSCustomObject estructurado + wrapper Start-*Process sigue patron Invoke-AsyncToolkitJob"
    - "Null-guards en main.ps1 para colecciones deserializadas de Background Job"

key-files:
  created: []
  modified:
    - modules/Network.ps1
    - main.ps1

key-decisions:
  - "Null-guard ($null -ne .Adapters) agregado en main.ps1 para robustez contra deserialización de job vacío"
  - "Fallback a netsh si Get-NetTCPSetting no está disponible"

patterns-established:
  - "Get-NetworkDiagnostics: patron de recolección de estado de red para diagnóstico"

duration: 5min
completed: 2026-03-10
---

# Phase 6 Plan 01: Diagnóstico de Red Summary

**Get-NetworkDiagnostics expone TCP AutoTuning, adaptadores activos, DNS IPv4 y latencia desde opción [d] del sub-menú de red — antes de optimizar, el técnico puede ver el estado real.**

## Performance

- **Duration:** ~5 min
- **Completed:** 2026-03-10
- **Tasks:** 2/2
- **Files modified:** 2

## Accomplishments

- `Get-NetworkDiagnostics` recopila TCP AutoTuning (con fallback a netsh), adaptadores Up, DNS IPv4 agrupado por interfaz, y latencia a 8.8.8.8
- `Start-NetworkDiagnosticsProcess` serializa y lanza async vía `Invoke-AsyncToolkitJob` siguiendo el patrón existente
- Sub-menú de red tiene `[d]` que ejecuta el diagnóstico y muestra resultados tabulados antes de volver al loop

## Task Commits

1. **Task 1: Get-NetworkDiagnostics + Start-NetworkDiagnosticsProcess** - `cca5457` (feat)
2. **Task 2: Opción [d] en networkLoop** - `4da617d` (feat)

## Files Created/Modified

- `modules/Network.ps1` — Funciones Get-NetworkDiagnostics y Start-NetworkDiagnosticsProcess agregadas al final
- `main.ps1` — [d] Write-Host + handler completo con TCP/DNS/ping display en networkLoop

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Null-guards en colecciones deserializadas**

- **Found during:** Task 2
- **Issue:** `$diagResult.Adapters.Count` puede fallar si el background job devuelve null para colecciones vacías al deserializar
- **Fix:** `if ($null -ne $diagResult.Adapters -and $diagResult.Adapters.Count -gt 0)` en ambas secciones (Adapters y DnsServers)
- **Files modified:** main.ps1
