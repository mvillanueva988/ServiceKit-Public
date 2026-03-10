# Roadmap: PC Optimizacion Toolkit

## Overview

El toolkit arrancó con un motor asíncrono y fue creciendo módulo a módulo durante 5 sesiones. **Proyecto completo.** Fase 1 (Core Toolkit), Fase 2 (Privacy Module con 3 perfiles nativos via registro) y Fase 3 (Polish & Production) cerradas.

## Phases

- [x] **Phase 1: Core Toolkit** — Motor asíncrono + todos los módulos funcionales (sesiones 1-5)
- [x] **Phase 2: Privacy Module** — 3 perfiles nativos (Basic/Medium/Aggressive) via registro Windows
- [x] **Phase 3: Polish & Production** — manifest v3 (15 herramientas), oldscripts eliminado, out-of-scope documentado
- [x] **Phase 4a: Compatibility — Crash Guards** — 7 guards en Telemetry.ps1 + COMPATIBILITY.md
- [ ] **Phase 4b: Compatibility — UX Guards** — Detección edición/build, guard x86 en Apps, LTSC en UWP, hardware info en banner, instance lock
- [ ] **Phase 5: Portable Executable** — Distribución como `.exe` standalone, sin dependencias externas, sin artifacts de desarrollo
- [ ] **Phase 6: Network Module Review** — Auditoría de Network.ps1: gaps de cobertura, casos borde, mejoras de diagnóstico

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
| 4a. Compatibility — Crash Guards | 1/1 | ✅ Complete | 2026-03-10 |
| 4b. Compatibility — UX Guards | 0/? | 🔜 Pending | — |
| 5. Portable Executable | 0/? | 🔜 Pending | — |
| 6. Network Module Review | 0/? | 🔜 Pending | — |

**Overall:** 7/? plans complete — Fases 1-3 + 4a cerradas.

### Phase 4a: Compatibility — Crash Guards ✅ COMPLETE

**Goal**: Calificar qué tan dinámico es el script frente a diferentes entornos. El toolkit debe ejecutarse sin crashes ni errores falsos en cualquier variante soportada de Windows, y degradar gracefully las funciones no disponibles.
**Depends on**: Phase 3
**Completed**: 2026-03-10

**What was built:**
- `modules/Telemetry.ps1` — 7 guards de compatibilidad en `Get-SystemSnapshot`: Win32_Processor, Win32_VideoController, Win32_ComputerSystem, Win32_PhysicalMemory, Get-PhysicalDisk, Win32_SystemEnclosure, Win32_OperatingSystem — todos con `-ErrorAction SilentlyContinue` + fallback a valores vacíos/cero
- `COMPATIBILITY.md` — Matriz completa feature × edición (Home/Pro/LTSC) × arquitectura (x64/x86/ARM64) + sección Out of Scope

**Plans**: 1 plan

Plans:

- [x] 04-01: Compatibility guards + matriz de compatibilidad

---

## Phase Details (Pending)

### Phase 4b: Compatibility — UX Guards 🔜

**Goal**: Agregar guards de UX que avisan al técnico del contexto en el que está operando — sin crashear (eso ya está), sino mostrando información contextual relevante o degradando con mensaje explicativo.

**Depends on**: Phase 4a
**Scope:**

| Área | Problema | Implementación propuesta |
|------|----------|--------------------------|
| Edición Windows (GPO) | `HKLM:\SOFTWARE\Policies\...` funciona en Pro/Enterprise pero Home silenciosamente ignora las keys. Privacy "Aggressive" aplica GPO que Home ignora | Detectar edición, mostrar nota en sub-menú Privacy si la edición es Home |
| OS build Win10 vs Win11 | Win11 cambió ubicación del menú Start y algunos registry keys de startup | Detectar `CurrentBuild >= 22000` para Win11; nota contextual donde corresponda |
| x86 vs x64 en Apps.ps1 | `WOW6432Node` solo existe en x64. En x86 puro las 3 rutas son equivalentes, pero el path `WOW6432Node` devuelve resultados duplicados | Guard de arquitectura en `Get-InstalledWin32Apps` — saltar WOW6432Node si `[Environment]::Is64BitOperatingSystem -eq $false` |
| LTSC detection en UWP | `Get-AppxPackage` devuelve poco/nada en LTSC; lista vacía puede confundir | Detectar LTSC, mostrar nota explicativa en sub-menú UWP |
| Hardware info en banner | El banner de inicio solo muestra OS. Podría mostrar RAM, tipo de disco, GPU | Agregar 2-3 líneas de info de hardware al menú principal (lectura rápida, no async) |
| Instance lock | Si el técnico ejecuta dos instancias simultáneas, los jobs pueden colisionar en el mismo output/ | Mutex o lockfile simple en main.ps1 al inicio |

**Tier 1 (impacto real, pocos cambios):**
1. Guard x86 en `Get-InstalledWin32Apps` (saltar WOW6432Node en x86)
2. Guard LTSC en sub-menú UWP (mensaje + skip `Get-AppxPackage`)
3. Detección Win10/Win11 + Home/Pro en banner de inicio
4. Nota de edición en Privacy "Aggressive" si GPO será ignorada

**Tier 2 (cosmético/nice-to-have):**
5. Hardware info en banner (RAM, SSD/HDD, GPU)
6. Instance lock

**Depends on**: Phase 4a

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

**Depends on**: Phase 4b

---

### Phase 6: Network Module Review 🔜

**Goal**: Auditoría profunda de `modules/Network.ps1`. Evaluar qué falta, qué puede fallar a escala, qué está mal hecho, y qué optimizaciones no se están considerando.

**Areas a revisar:**

- **Cobertura de adaptadores**: Solo se procesan NICs activos (`Status=Up`). ¿Qué pasa con el Wi-Fi en modo avión? ¿Con adaptadores de VM (Hyper-V, VirtualBox)?
- **Power-saving via Set-NetAdapterAdvancedProperty**: La actual implementación escribe directo al registro por GUID. `Set-NetAdapterAdvancedProperty` es el cmdlet oficial — existe desde W8. ¿Vale la pena migrar?
- **TCP AutoTuning "normal"**: En algunos entornos corporativos o conexiones satelitales, `autotuninglevel=normal` puede ser peor que `disabled`. ¿Debería ser configurable?
- **DNS flush solo**: `ipconfig /flushdns` es ruidoso si no hay problemas de DNS. ¿Separar en opción independiente?
- **Falta de diagnóstico de red**: El módulo solo optimiza pero no diagnostica. ¿Agregar lectura de latencia, pérdida de paquetes, configuración de DNS actual?
- **IPv6**: No se toca. En algunos entornos problemáticos, IPv6 mal configurado genera latencia. ¿Agregar opción de deshabilitar con advertencia?
- **MTU**: No se configura. MTU 1500 vs jumbo frames — relevante en algunos entornos.
- **Resultados de diagnóstico**: El módulo retorna `AdaptersOptimized[]` pero no verifica si los cambios de registro realmente se aplicaron (algunos drivers ignoran las propiedades).

**Depends on**: Phase 4b (o puede ejecutarse en paralelo)
