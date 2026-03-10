# PC Optimizacion Toolkit — Sesión GSD (Sesión 6)

> **Fecha:** 2026-03-10  
> **Inicio estimado:** ~04:00 ART  
> **Cierre de log:** 06:43 ART  
> **Framework:** GSD para GitHub Copilot  
> **Fases completadas en esta sesión:** Phase 2 (Privacy Module) + Phase 3 (Polish & Production)

---

## Contexto de arranque

Se retomó el proyecto post-onboarding GSD. STATE.md indicaba:
- Phase 2 pendiente (Privacy Module)
- Decisión previa: Privacy via `OOSU10.exe perfil.cfg /quiet` + perfiles `.cfg` versionados

---

## Decisiones tomadas (con timestamp ART)

### ~04:30 ART — Descartar approach .cfg

**Problema:** El formato `.cfg` de ShutUp10++ no tiene especificación pública documentada y estable. Mantener los archivos requeriría investigación manual y actualizaciones frecuentes.

**Decisión:** Descartar perfiles `.cfg`. Implementar tweaks de privacidad nativamente en PowerShell via registro de Windows. ShutUp10++ queda disponible en `[T]` como herramienta GUI avanzada.

**Rationale:** Las rutas de registro de privacidad (`HKLM:\SOFTWARE\Policies\Microsoft\...`, `HKCU:\SOFTWARE\Microsoft\...`) son documentadas por Microsoft, llevan 10+ años estables y no requieren dependencia externa.

---

## Implementaciones

### Plan 02-01 — Privacy.ps1 con 3 perfiles nativos

**Commit:** `33b471c` — 06:xx ART

#### `Invoke-PrivacyTweaks -Profile [Basic|Medium|Aggressive]`

Perfiles escalonados (acumulativos):

| Perfil | Tweaks | Keys de registro |
|--------|--------|-----------------|
| Basic | Telemetría, Advertising ID, Bing en Start, Cortana consent, Feedback, Activity Feed | `AllowTelemetry=0`, `AdvertisingInfo\Enabled=0`, `BingSearchEnabled=0`, `CortanaConsent=0`, `NumberOfSIUFInPeriod=0`, `EnableActivityFeed=0` |
| Medium | + Ubicación global (sistema), Tailored experiences, Sugerencias en inicio, Apps silenciosas de MS, Mapas en background | `SensorPermissionState=0`, `TailoredExperiencesWithDiagnosticDataEnabled=0`, `SystemPaneSuggestionsEnabled=0`, `SilentInstalledAppsEnabled=0`, `AutoUpdateEnabled=0` |
| Aggressive | + OneDrive policy, Edge Startup Boost, Edge background, Consumer features, Tips, Contenido suscrito, Windows Error Reporting | `DisableFileSyncNGSC=1`, `StartupBoostEnabled=0`, `BackgroundModeEnabled=0`, `DisableWindowsConsumerFeatures=1`, `SoftLandingEnabled=0`, `SubscribedContent-310093Enabled=0`, `WER\Disabled=1` |

#### `Start-PrivacyJob -Profile`

Serialización de función al job via `.ToString()` — patrón estándar del proyecto. Retorna Job para `Wait-ToolkitJobs`.

#### Sub-menú `[13]` en main.ps1

- Muestra 3 perfiles con colores: Basico (White), Medio (Yellow), Agresivo (Red)
- Descripción de qué toca cada perfil
- Opción `[T]` para abrir ShutUp10++ GUI si está descargado
- Loop con `[q]` para volver

---

### Phase 3 — Polish & Production

#### Bugfix: $args reservada en Apps.ps1 — `a37a510`

`Set-StrictMode -Version Latest` prohíbe reasignar variables automáticas de PowerShell. `$args` contiene los argumentos del script — no se puede redeclarar con tipo. Renombrado a `$cmdArgs` (4 ocurrencias en la función `_Invoke-UninstallCommand`).

#### Bugfix: Em dash encoding en Performance.ps1 — `a37a510`

El carácter `—` (U+2014) guardado en UTF-8 era interpretado como Latin-1 por el parser de PowerShell en ciertos contextos, produciendo `â€"` y rompiendo el string. Reemplazado por guion ASCII `-`.

#### Manifest v3 con 15 herramientas — `3de5a83`

Agregadas 8 herramientas nuevas con campos `category` y `approxSizeMB`:

| Nueva herramienta | Categoría | Peso aprox | URL |
|-------------------|----------|-----------|-----|
| crystaldiskinfo | disco | ~6 MB | sourceforge.net/projects/crystaldiskinfo |
| crystaldiskmark | disco | ~5 MB | sourceforge.net/projects/crystaldiskmark |
| wiztree | disco | ~3 MB | diskanalyzer.com/files/wiztree_portable.zip |
| hwinfo64 | hardware | ~10 MB | hwinfo.com/files/hwi_portable.zip |
| cpuz | hardware | ~3 MB | download.cpuid.com/cpu-z/cpu-z_portable.zip |
| ddu | drivers | ~9 MB | wagnardsoft.com/DDU/DDU-setup.exe |
| bleachbit | limpieza | ~18 MB | download.bleachbit.org/BleachBit-portable.zip |
| winutil | setup | ~5 MB | github.com/ChrisTitusTech/winutil/releases/latest |

**Nota WizTree vs WinDirStat:** WizTree lee la MFT directamente (segundos para 2TB). WinDirStat lee filesystem recursivamente (lento, ~15 min en discos grandes). WizTree elegido.

#### main.ps1 [T] — tabla mejorada — `3de5a83`

Tabla de herramientas ahora muestra: Estado | # | Categoría | Nombre | Peso | Descripción corta. Herramientas agrupadas visualmente por categoría.

#### oldscripts/ eliminado — `3de5a83`

`git rm -r oldscripts/` — los 3 scripts de referencia (collect_info, compare_pre_post, generate_report) quedan en el historial de git para acceso futuro:
```
git show <hash>:oldscripts/collect_info.ps1
git show 3de5a83^:oldscripts/generate_report.ps1
```

---

## Out of Scope documentado

**`Restore-SystemTweaks`:** Función inversa de `Set-SystemTweaks` que restauraría valores de registro de rendimiento a defaults de Windows. No fue solicitada y para el caso de uso (técnico de servicio) un System Restore Point cumple el mismo propósito con menor complejidad.

**SHA-256 en manifest:** Las herramientas con URL "latest" (Sysinternals, O&O, WizTree, etc.) cambian binario sin cambiar URL — el hash es inverificable. Documentado en el campo `"comment"` del manifest.

---

## Estado del repo al cierre

```
git log --oneline:

3de5a83  feat: manifest v3 con 15 herramientas + oldscripts eliminado
a37a510  fix: $args reserved var en Apps.ps1, em dash encoding en Performance.ps1
33b471c  feat(02-01): Privacy.ps1 con 3 perfiles nativos + sub-menu en main.ps1
bec4fc2  docs: GSD onboarding + mover logs a Logs/
d098e50  feat: sesion 5 - Apps, StartupManager, Privacy + GSD onboarding
3468e42  chore: excluir output/ de git, limpiar archivos trackeados por error
...
```

**Working tree:** limpio (sin cambios sin commitear)

---

## Estado del proyecto al cierre

| Dimensión | Estado |
|-----------|--------|
| Módulos completos | 13 / 13 |
| Opciones de menú | 14 + [T] (todos funcionales) |
| Privacy.ps1 | ✅ 3 perfiles nativos via registro |
| Herramientas externas | 15 en manifest v3 |
| oldscripts/ | Eliminado del working tree, en historial git |
| Fases GSD | Phase 1 ✅ — Phase 2 ✅ — Phase 3 ✅ |

**Proyecto: COMPLETO** — todas las fases cerradas.
