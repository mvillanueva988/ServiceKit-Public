---
phase: 07-auto-cleanup
plan: 01
subsystem: core-ux
tags: [self-removal, menu, ux, cleanup, powershell]

requires:
  - phase: 01-core-toolkit
    provides: main.ps1 menu structure and switch pattern

provides:
  - "[X] Limpiar y salir option in main menu with explicit confirmation and deferred self-deletion"

affects: []

tech-stack:
  added: []
  patterns:
    - "Deferred self-deletion via detached cmd.exe (Start-Process /c timeout && rmdir) to avoid deleting the directory while the script is still running"

key-files:
  created: []
  modified:
    - main.ps1

key-decisions:
  - "Use Start-Process cmd.exe with /c timeout /t 1 && rmdir /s /q to schedule deletion AFTER exit 0 — script cannot delete its own parent directory while running"
  - "Show PSScriptRoot path in confirmation prompt so technician knows exactly what will be deleted"
  - "exit 0 after farewell message — bypasses the Read-Host at the bottom of the main loop"

patterns-established:
  - "Deferred-delete pattern: schedule destructive OS operation via detached cmd process, then exit immediately"

duration: 5min
completed: 2026-03-10
---

# Phase 7 Plan 01: Auto-Cleanup / Self-Removal Summary

**[X] Limpiar y salir borrar el directorio completo del toolkit de la PC del cliente — confirmación explícita, mensaje de despedida y proceso secundario hace el rmdir después del exit.**

## Performance

- **Duration:** ~5 min
- **Completed:** 2026-03-10
- **Tasks:** 1/1
- **Files modified:** 1

## Accomplishments

- `[X] Limpiar y salir` visible en el menú principal con color DarkRed y descripción en DarkGray
- Al seleccionar, muestra la ruta (`$PSScriptRoot`) y pide confirmación explícita ("Esta seguro? Esta accion es irreversible. [s] Si [q] Cancelar")
- Si el técnico cancela (`q` o cualquier cosa que no sea `s`), imprime "Cancelado." y vuelve al menú
- Si confirma, muestra "Toolkit eliminado. Hasta la proxima.", lanza un `cmd.exe` desacoplado con `timeout /t 1 && rmdir /s /q` y llama `exit 0`
- El `cmd.exe` espera 1 segundo para que PowerShell termine, luego borra el directorio completo recursivamente

## Task Commits

1. **Task 1: [X] Limpiar y salir — menu display + switch handler** - `2176d57` (feat)

## Files Created/Modified

- `main.ps1` — Líneas de menú `[X]` + bloque `'x'` en switch con confirmation prompt, deferred-delete y exit 0

## Deviations from Plan

None — plan executed exactly as written.
