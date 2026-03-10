# Roadmap: PC Optimizacion Toolkit

## Overview

El toolkit arrancó con un motor asíncrono y fue creciendo módulo a módulo durante 5 sesiones. La fase 1 está completa (13 de 14 opciones de menú funcionales). La fase actual (Fase 2) termina el único módulo pendiente: Privacy con perfiles nativos. La fase 3 cierra remanentes de baja prioridad antes de cierre del proyecto.

## Phases

- [x] **Phase 1: Core Toolkit** — Motor asíncrono + todos los módulos funcionales (sesiones 1-5)
- [x] **Phase 2: Privacy Module** — Lanzador GUI de ShutUp10++ con check de disponibilidad
- [ ] **Phase 3: Polish & Production** — SHA-256 en manifest, Restore-SystemTweaks, limpieza de oldscripts

---

## Phase Details

### Phase 1: Core Toolkit ✅ COMPLETE

**Goal**: Toolkit funcional con todas las opciones de menú operativas, motor asíncrono, herramientas externas y auditoría PRE/POST.
**Depends on**: Nothing
**Completed**: 2026-03-10 (sesiones 1-5)

**What was built:**

- `core/JobManager.ps1` — `Invoke-AsyncToolkitJob` + `Wait-ToolkitJobs` (spinner visual)
- `modules/Debloat.ps1` — 12 servicios bloat, selección granular
- `modules/Cleanup.ps1` — 12 rutas, preview MB/GB antes de confirmar
- `modules/Maintenance.ps1` — DISM RestoreHealth + SFC /scannow
- `modules/RestorePoint.ps1` — System Restore checkpoint automático
- `modules/Network.ps1` — NICs power-saving + TCP Auto-Tuning + DNS flush
- `modules/Performance.ps1` — 4 perfiles visuales + Ultimate Power Plan + System Tweaks
- `modules/Telemetry.ps1` — Snapshot PRE/POST + Compare con score 0/6
- `modules/Diagnostics.ps1` — BSOD history con stop-code lookup + Driver backup
- `modules/Apps.ps1` — Win32 (3 hives, filtro regex) + UWP + Uninstall prioritario
- `modules/StartupManager.ps1` — Run keys + carpetas, toggle via StartupApproved
- `utils/HelpContent.ps1` — Contenido educativo en sub-menú [i]
- `Bootstrap-Tools.ps1` — Descarga con barra de progreso chunk 64KB, soporte ZIP
- `tools/manifest.json` v2 — 7 herramientas con `launchExe`
- `main.ps1` — Menú completo opciones 1-14 + [T] con descripciones DarkGray

Plans: (ejecutados org��nicamente, sin GSD)

- [x] 01-01: Motor asíncrono + módulos base (Debloat, Cleanup, Maintenance, RestorePoint, Network)
- [x] 01-02: Sistema de auditoría PRE/POST (Telemetry)
- [x] 01-03: Rendimiento y Diagnóstico (Performance, Diagnostics)
- [x] 01-04: Apps, Startup, Herramientas externas y redesign de menú

---

### Phase 2: Privacy Module ✅ COMPLETE

**Goal**: Opción [13] lanza ShutUp10++ GUI con check de disponibilidad. El técnico puede abrir la herramienta directamente desde el menú o ver un error claro con instrucción de descarga si no está instalada.
**Depends on**: Phase 1
**Completed**: 2026-03-10

**Decision**: Approach de perfiles `.cfg` descartado — el formato no tiene especificación pública estable y ShutUp10++ maneja sus propios perfiles internamente. Lanzador GUI directo es la implementación final.

**What was built:**
- `modules/Privacy.ps1` — `Test-ShutUp10Available` + `Open-ShutUp10` (lanzador GUI con check)
- `main.ps1 [13]` — check de disponibilidad + launch, error claro con instrucción `[T] Herramientas`

**Plans**: 1 plan

Plans:

- [x] 02-01: Privacy.ps1 lanzador GUI con check de disponibilidad

---

### Phase 3: Polish & Production

**Goal**: Cerrar remanentes técnicos de baja prioridad antes de dar el proyecto por completo.
**Depends on**: Phase 2

**Success Criteria** (what must be TRUE):

1. `manifest.json` tiene SHA-256 definidos (o la decisión de no incluirlos está documentada)
2. `Restore-SystemTweaks` existe en Performance.ps1 o está explícitamente fuera de scope
3. `/oldscripts` eliminado (o archivado/ignorado en git)

**Plans**: 1 plan

Plans:

- [ ] 03-01: Cleanup de producción (SHA-256, Restore-SystemTweaks decision, oldscripts)

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|---------------|--------|-----------|
| 1. Core Toolkit | 4/4 | ✅ Complete | 2026-03-10 |
| 2. Privacy Module | 0/1 | 🔄 In progress | — |
| 3. Polish & Production | 0/1 | Not started | — |

**Overall:** 4/6 plans complete (67%)
