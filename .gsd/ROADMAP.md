# Roadmap: PC Optimizacion Toolkit

## Overview

El toolkit arrancó con un motor asíncrono y fue creciendo módulo a módulo durante 5 sesiones. **Proyecto completo.** Fase 1 (Core Toolkit), Fase 2 (Privacy Module con 3 perfiles nativos via registro) y Fase 3 (Polish & Production) cerradas.

## Phases

- [x] **Phase 1: Core Toolkit** — Motor asíncrono + todos los módulos funcionales (sesiones 1-5)
- [x] **Phase 2: Privacy Module** — 3 perfiles nativos (Basic/Medium/Aggressive) via registro Windows
- [x] **Phase 3: Polish & Production** — manifest v3 (15 herramientas), oldscripts eliminado, out-of-scope documentado
- [x] **Phase 4a: Compatibility — Crash Guards** — 7 guards en Telemetry.ps1 + COMPATIBILITY.md
- [x] **Phase 4b: Compatibility — UX Guards** — Banner OS/HW/Edition, x86 guard en Apps, LTSC en UWP, Privacy GPO note, PS1 launcher, instance mutex
- [ ] **Phase 5: Portable Executable** — Distribución como `.exe` standalone, sin dependencias externas, sin artifacts de desarrollo
  - [ ] 05-01-PLAN.md — Launch.ps1 (one-liner handler) + Release.ps1 (build script)
  - [ ] 05-02-PLAN.md — Bootstrap integrity fix + README rewrite
- [ ] **Phase 6: Network Module Review** — Auditoría de Network.ps1: gaps de cobertura, casos borde, mejoras de diagnóstico
- [ ] **Phase 7: Auto-Cleanup / Self-Removal** — Opción para borrar o desaparecer el toolkit de una PC ajena al terminar el trabajo

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
| 4b. Compatibility — UX Guards | 1/1 | ✅ Complete | 2026-03-10 |
| 5. Portable Executable | 0/? | 🔜 Pending | — |
| 6. Network Module Review | 0/? | 🔜 Pending | — |
| 7. Auto-Cleanup / Self-Removal | 0/? | 🔜 Pending | — |

**Overall:** 8/? plans complete — Fases 1-3 + 4a + 4b cerradas.

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

### Phase 4b: Compatibility — UX Guards ✅ COMPLETE

**Goal**: Guards de UX informativos — el técnico sabe el contexto en el que está operando.
**Depends on**: Phase 4a
**Completed**: 2026-03-10

**What was built:**
- `main.ps1` banner — OS (Win10/Win11), edición, build, arch (x64/x86), RAM GB, GPU model
- `main.ps1` variables `$isWin11`, `$isHome`, `$isLtsc` disponibles en todo el scope del loop
- `main.ps1` Privacy submenu — nota amarilla en Home: "tweaks de Group Policy (perfil Agresivo) son ignorados"
- `main.ps1` UWP submenu — nota amarilla en LTSC: "Microsoft Store no incluida, lista puede ser reducida"
- `main.ps1` Tool launcher — soporte para `launchExe` con extensión `.ps1`
- `main.ps1` Instance mutex — `Local\PCOptimizacionToolkit` previene dos instancias
- `modules/Apps.ps1` — WOW6432Node saltado en x86 puro
- `tools/manifest.json` v4 — Sophia Script + WinSlop (18 herramientas total)

Plans:
- [x] 04b-01: UX guards

---

### Phase 5: Portable Executable 🔜

**Goal**: One-liner de PowerShell que descarga y lanza el toolkit desde GitHub en cualquier PC. Uso personal del técnico + servicio a distancia vía AnyDesk. Sin EXE compilado (ps2exe descartado), sin `%TEMP%`, sin versioning complejo.

**Decisions locked (post-discuss):**
- Formato: ZIP limpio + `Run.bat` — no EXE. ps2exe descartado por falsos positivos AV, SmartScreen, bugs con `Start-Job`/`Add-Type`, y overhead de compilación.
- One-liner: `irm https://raw.githubusercontent.com/USER/Toolkit/main/Launch.ps1 | iex`
- Extracción a ruta fija `C:\PCTk\` — no `%TEMP%` (AV, limpiezas, reconexiones AnyDesk)
- Auto-update por sobreescritura directa; `tools\bin\` se preserva entre actualizaciones
- Herramientas externas: on-demand siempre, sin auto-detection de versiones
- Firma: no. Click "ejecutar de todas formas" aceptable para uso técnico

**What to build:**
1. `Launch.ps1` — one-liner handler: descarga Release ZIP → extrae a `C:\PCTk\` → lanza `main.ps1`
2. `Release.ps1` — build script local: genera ZIP limpio (excluye `.gsd/`, `.git/`, `Logs/`, `output/`, `tools/bin/`)
3. Fix en `Bootstrap-Tools.ps1` — verificar tamaño de descarga para detectar archivos parciales
4. README actualizado con one-liner documentado

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

---

### Phase 7: Auto-Cleanup / Self-Removal 🔜

**Goal**: Mecanismo para que el toolkit desaparezca limpiamente de una PC ajena al terminar el trabajo.

**Options to evaluate:**
- `[X] Limpiar y salir` — opción en el menú principal que borra la carpeta del toolkit, limpia Recent Files, vacía Recycle Bin
- **Self-destruct on exit** — cuando se combine con Phase 5 (EXE), el exe puede borrarse a sí mismo al salir (`cmd /c del exePath` en detached process)
- **Ruta manual conocida** — instrucción en README de copiar a `C:\Toolkit` para borrado manual rápido
- **No-trace mode** — no crear archivos de log, no crear output/, ejecutar todo en memoria

**Depends on**: Phase 5 (para la variante EXE self-destruct)
