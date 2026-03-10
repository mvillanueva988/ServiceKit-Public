# Roadmap: PC Optimizacion Toolkit

## Overview

El toolkit arrancó con un motor asíncrono y fue creciendo módulo a módulo durante 5 sesiones. **Proyecto completo.** Fase 1 (Core Toolkit), Fase 2 (Privacy Module con 3 perfiles nativos via registro) y Fase 3 (Polish & Production) cerradas.

## Phases

- [x] **Phase 1: Core Toolkit** — Motor asíncrono + todos los módulos funcionales (sesiones 1-5)
- [x] **Phase 2: Privacy Module** — 3 perfiles nativos (Basic/Medium/Aggressive) via registro Windows
- [x] **Phase 3: Polish & Production** — manifest v3 (15 herramientas), oldscripts eliminado, out-of-scope documentado
- [ ] **Phase 4: Compatibility Qualification** — Calificación de dinamismo: W10/W11, Home/Pro/LTSC, x86/x64, GPU families, hardware tiers
- [ ] **Phase 5: Portable Executable** — Distribución como `.exe` standalone, sin dependencias externas, sin artifacts de desarrollo

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

**Decision**: Approach de perfiles `.cfg` descartado — el formato no tiene especificación pública estable. Implementación final: 3 perfiles nativos via registro Windows sin dependencias externas. ShutUp10++ conservado como herramienta en `[T]` para técnicos que prefieran GUI.

**What was built:**
- `modules/Privacy.ps1` — `Invoke-PrivacyTweaks -Profile [Basic|Medium|Aggressive]` + `Start-PrivacyJob` async
- `modules/Privacy.ps1` — `Test-ShutUp10Available` + `Open-ShutUp10` para sub-opción [T] del menú
- `main.ps1 [13]` — sub-menú con 3 perfiles + [T] launcher GUI

**Plans**: 1 plan

Plans:

- [x] 02-01: Privacy.ps1 con 3 perfiles nativos via registro Windows

---

### Phase 3: Polish & Production ✅ COMPLETE

**Goal**: Cerrar remanentes técnicos de baja prioridad antes de dar el proyecto por completo.
**Depends on**: Phase 2
**Completed**: 2026-03-10 06:43 ART

**Success Criteria** (all met ✅):

1. ✅ `manifest.json` SHA-256 vacíos documentados como intencional (URLs apuntan a "latest", no a versiones fijas)
2. ✅ `Restore-SystemTweaks` documentado como Out of Scope (nunca solicitado; System Restore Point cumple el mismo propósito)
3. ✅ `/oldscripts` eliminado del working tree (preservado en git history)

**What was built:**
- `tools/manifest.json` v3 — 15 herramientas con campos `category` y `approxSizeMB`; 8 herramientas nuevas (crystaldiskinfo, crystaldiskmark, wiztree, hwinfo64, cpuz, ddu, bleachbit, winutil)
- `main.ps1 [T]` — tabla mejorada con columnas Categoría, Peso y descripción corta; herramientas agrupadas por categoría
- `oldscripts/` — eliminado del working tree, preservado en git history
- Bugfixes: `Apps.ps1` `$args` → `$cmdArgs`; `Performance.ps1` em dash → ASCII hyphen

**Plans**: 1 plan

Plans:

- [x] 03-01: Cleanup de producción (manifest v3, Restore-SystemTweaks decision, oldscripts)

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|---------------|--------|-----------|
| 1. Core Toolkit | 4/4 | ✅ Complete | 2026-03-10 |
| 2. Privacy Module | 1/1 | ✅ Complete | 2026-03-10 |
| 3. Polish & Production | 1/1 | ✅ Complete | 2026-03-10 |
| 4. Compatibility Qualification | 0/? | 🔜 Pending | — |
| 5. Portable Executable | 0/? | 🔜 Pending | — |

**Overall:** 6/? plans complete — Fases 1-3 cerradas.

---

## Phase Details (Pending)

### Phase 4: Compatibility Qualification 🔜

**Goal**: Calificar qué tan dinámico es el script frente a diferentes entornos. El toolkit debe ejecutarse sin crashes ni errores falsos en cualquier variante soportada de Windows, y degradar gracefully las funciones no disponibles.

**Scope of qualification:**
- **OS**: Windows 10 (21H2+), Windows 11 (22H2+)
- **Editions**: Home, Pro, Enterprise, LTSC
- **Architecture**: x64 (primario), x86 (secundario), ARM64 (best-effort)
- **GPU families**: NVIDIA, AMD, Intel integrated
- **CPU families**: Intel (moderna + legacy), AMD Ryzen
- **Hardware tiers**: Gama baja (TDP bajo, HDDs, <8GB RAM), media (8-16GB, SSD), alta (>16GB, NVMe, dGPU)

**Key risks to audit:**
- `Ultimate Power Plan` (`powercfg /duplicatescheme`) — no disponible en Home ni en algunas LTSC
- `DISM /RestoreHealth` — requiere Windows Update o fuente alternativa; falla sin internet en LTSC
- CIM queries (`Win32_VideoController`, `Win32_Processor`) — algunas pueden estar bloqueadas en entornos corporativos
- `Get-AppxPackage` — comportamiento distinto en LTSC (apps UWP pueden no existir)
- Disk cleanup paths (`%TEMP%`, `Windows\Temp`) — permisos variables según usuario
- Registry paths de 32-bit vs 64-bit (`WOW6432Node`) — ya cubierto en Apps.ps1
- `StartupApproved` registry — existente desde W8, pero estructura puede variar

**Deliverable**: Matriz de compatibilidad + guards/fallbacks implementados en código.

**Depends on**: Phase 3

---

### Phase 5: Portable Executable 🔜

**Goal**: Un solo archivo distribuible (`.exe` o `.bat` autónomo) que contenga el toolkit completo. Sin carpetas de desarrollo (Logs/, .gsd/, .git/), sin requisitos de descarga adicional. Completamente portable.

**Key decisions to make:**
- Tool: `ps2exe` (convierte PS1 → EXE) vs. wrapper `.bat` con PS1 embebido vs. self-extracting archive
- Inclusión de módulos: embed dentro del EXE o extraer al `%TEMP%` al runtime
- Assets: `tools/manifest.json` embebido; binarios externos (Autoruns, etc.) no incluidos por defecto — se descargan al usar `[T]`
- Signing: opcional para evitar SmartScreen warning

**Constraints:**
- Solo cmdlets nativos de PowerShell / WMI / CIM (ya vigente)
- No descargar nada en runtime para funciones core
- Compatible con ejecución directa por doble click (no requiere PS abierto)

**Depends on**: Phase 4
