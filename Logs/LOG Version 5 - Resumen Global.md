# PC Optimizacion Toolkit — Resumen Global (Foto Definitiva)

> **Generado:** 10/3/2026  
> **Propósito:** Consolidación canónica de 5 sesiones de desarrollo. Reemplaza lectura secuencial de LOGs anteriores. A partir de aquí el proyecto es gestionado con el framework GSD.

---

## Estado Global del Proyecto

| Dimensión | Estado |
|-----------|--------|
| Módulos completos | 11 / 13 |
| Módulos stub / pendientes | 1 (Privacy.ps1) |
| Opciones de menú funcionales | 14 + [T] |
| Motor asíncrono | ✅ Operativo |
| Arquitectura de herramientas externas | ✅ Operativa (manifest v2 + Bootstrap) |
| Framework GSD | ✅ Instalado, onboarding en curso |

---

## Arquitectura del Sistema

```
Run.bat  →  main.ps1  (dot-source automático de /core, /utils, /modules)
                │
         ┌──────┴──────────────────────────────────────┐
         │  core/JobManager.ps1                         │
         │    Invoke-AsyncToolkitJob                    │
         │    Wait-ToolkitJobs  (spinner visual)        │
         └─────────────────────────────────────────────-┘
                │
     ┌──────────┴──────────────────────────────────────────────────────────┐
     │  modules/                                                            │
     │  Debloat.ps1       Cleanup.ps1       Maintenance.ps1               │
     │  RestorePoint.ps1  Network.ps1       Performance.ps1               │
     │  Telemetry.ps1     Diagnostics.ps1   Apps.ps1                      │
     │  Privacy.ps1 ⚠️     StartupManager.ps1                              │
     └─────────────────────────────────────────────────────────────────────┘
                │
     ┌──────────┴──────────────────────────────┐
     │  utils/HelpContent.ps1                   │
     │  tools/manifest.json + Bootstrap-Tools.ps1│
     └──────────────────────────────────────────┘
```

**Regla de oro:** Todo scan/operación pesada → `Start-Job`. La consola nunca bloquea.

---

## Inventario Completo de Features

### core/JobManager.ps1 — ✅ COMPLETO

| Función | Descripción |
|---------|-------------|
| `Invoke-AsyncToolkitJob` | Wrapper tipado sobre `Start-Job`. Acepta `JobName` y `ArgumentList` opcionales |
| `Wait-ToolkitJobs` | Espera array de jobs con spinner `\|/-\` + contador activos. Retorna output agregado |

### modules/Debloat.ps1 — ✅ COMPLETO

- Catálogo de 12 servicios bloat clasificados: `Alto` (Xbox, DiagTrack, RemoteRegistry, RemoteAccess), `Medio` (Spooler, PrintNotify, dmwappushservice), `Bajo` (Fax, WMPNetworkSvc)
- Tabla coloreada con estado actual por servicio
- Selección granular: `1,3,5`, rango, `all`
- `Start-DebloatProcess -ServicesList` → async

### modules/Cleanup.ps1 — ✅ COMPLETO

- 12 rutas: `%SystemRoot%\Temp`, `%TEMP%`, Prefetch, SoftwareDistribution\Download, WER, Edge, Chrome, Firefox, Brave, Opera GX, Windows Logs, RecycleBin
- `Get-CleanupPreview` (síncrono, read-only) → tabla previsualizacion + total MB/GB
- `Start-CleanupProcess` → async, detiene/reinicia `wuauserv` para Update cache
- Retorna: `FreedMB`, `FreedGB`, `SoftErrors`

### modules/Maintenance.ps1 — ✅ COMPLETO

- Secuencia: `DISM /Online /Cleanup-Image /RestoreHealth` → `sfc /scannow`
- `Start-MaintenanceProcess` → async
- Retorna `DismExitCode`, `SfcExitCode` + nota de ruta CBS.log

### modules/RestorePoint.ps1 — ✅ COMPLETO

- Habilita System Restore en `C:\` si está desactivado
- Crea checkpoint tipo `MODIFY_SETTINGS` → `"Toolkit Pre-Service"`
- Maneja límite de 1 punto/24h con mensaje informativo
- `Start-RestorePointProcess` → async

### modules/Network.ps1 — ✅ COMPLETO

- Detecta NICs físicos activos (Ethernet `802.3` + Wi-Fi `Native 802.11`)  
- Deshabilita power-saving en registro: `EEE`, `GreenEthernet`, `PowerSavingMode`, `EnablePME`, `ULPMode`  
- TCP global: `AutoTuningLevel=Normal`, `FastOpen=Enabled`, `ipconfig /flushdns`
- Sub-menú `[i]` con texto educativo por optimización (`utils/HelpContent.ps1`)
- `Start-NetworkOptimizationProcess` → async

### modules/Performance.ps1 — ✅ COMPLETO

#### Perfiles visuales

| Perfil | `VisualFXSetting` | ClearType | Thumbnails | Drag | Animaciones | Transparencia |
|--------|:-----------------:|:---------:|:----------:|:----:|:-----------:|:-------------:|
| `Set-BalancedVisuals` | 3 Custom | ✅ | ✅ | ✅ | ❌ | ❌ |
| `Set-FullOptimizedVisuals` | 2 Best Perf | ❌ | ❌ | ❌ | ❌ | ❌ |
| `Restore-DefaultVisuals` | 1 Best Appearance | ✅ | ✅ | ✅ | ✅ | ✅ |

#### Set-UltimatePowerPlan

- Activa plan Ultimate Performance (`e9a42b02-...`), fallback a High Performance si no disponible en la edición

#### Set-SystemTweaks (corre en TODOS los perfiles incluyendo TweaksOnly)

| Tweak | Mecanismo | Condición |
|-------|-----------|-----------|
| Deshabilitar hibernación | `powercfg /h off` | Siempre |
| `WaitToKillServiceTimeout` | Registro → `2000` ms | Siempre |
| `WaitToKillAppTimeout` | Registro → `2000` ms | Siempre |
| Game DVR | `HKCU:\...\GameBar → 0` | Siempre |
| `SvcHostSplitThreshold` | → RAM total en bytes | Solo si RAM ≤ 8 GB |

- `Start-PerformanceProcess -VisualProfile 'Balanced'|'Full'|'Restore'|'TweaksOnly'` → async
- Serialización de funciones al job context con `.ToString()`

### modules/Telemetry.ps1 — ✅ COMPLETO

#### Get-SystemSnapshot -Phase Pre|Post

Recopila 14 áreas vía CIM/WMI. Áreas comparables PRE/POST:

| Campo | Comparable |
|-------|-----------|
| CPU, GPU, RAM (info estática) | ❌ |
| Volúmenes: espacio libre GB/% | ✅ |
| Page File usage | ✅ |
| Servicios: running count + bloat activos | ✅ |
| Startup count | ✅ |
| Top 5 procesos por WorkingSet | ✅ |
| Batería: charge%, health% | ✅ |
| Antivirus: lista + `MultipleAvProblem` | ✅ |
| UptimeHours | ✅ |
| CPU temp (MSAcpi, best-effort) | ❌ |

#### Save-Snapshot / Compare-Snapshot / Show-SnapshotComparison

- Sin movidas manuales de archivos. Carga los JSON más recientes automáticamente.
- Score **0/6**: almacenamiento, servicios, bloat, startup, antivirus, sistema (reinicio)
- Visualización `[+]` verde / `[-]` rojo / `[ ]` gris / `[!]` amarillo
- `Start-TelemetryJob -Phase 'Pre'|'Post'` → async (dot-sourcea el módulo dentro del job)

### modules/Diagnostics.ps1 — ✅ COMPLETO

#### Get-BsodHistory -Days 90 + Show-BsodHistory

- Lee Event Log (EventIDs 41, 1001, 6008) — 90 días
- Lista `.dmp` de `C:\Windows\Minidump`
- Lookup table de 5 stop code patterns → causa probable
- Heurísticas por patrón: múltiples Kernel-Power sin BugCheck = PSU/overheating
- `Start-BsodHistoryJob` → async

#### Backup-Drivers -OutputRoot

- Criterio: drivers de terceros (`ProviderName ≠ Microsoft`) + drivers de red (siempre)
- Estrategia: `Export-WindowsDriver` masivo, fallback a `pnputil /export-driver`
- Destino: `output\driver_backup\<timestamp>\`
- `Start-DriverBackupJob` → async

### modules/Apps.ps1 — ✅ COMPLETO

#### Get-InstalledWin32Apps -Filter

- Lee 3 hives: `HKLM\Uninstall\*` (x64 + WOW6432Node) + `HKCU`
- Deduplica por `DisplayName` (HashSet OrdinalIgnoreCase)
- Excluye: sin nombre, `SystemComponent=1`, entradas con `ParentKeyName`
- `-Filter`: regex con fallback `-like` si regex inválido

#### Get-InstalledUwpApps -Filter

- `Get-AppxPackage` filtrado: excluye resource packages, bundles y NonRemovable
- `IsMicrosoft` flag para coloreo diferencial
- Ordenado: terceros primero

#### Invoke-Win32Uninstall -App

Prioridad: `QuietUninstallString` → `MsiExec /X{GUID} /qn /norestart` → `UninstallString` interactivo  
Retorna: `Success`, `Method`, `App`, `ExitCode` / `Error`

### modules/Privacy.ps1 — ⚠️ STUB (pendiente rediseño)

**Estado actual:** Solo 2 funciones mínimas:
- `Test-ShutUp10Available` — verifica si `OOSU10.exe` existe en `tools/bin/`
- `Open-ShutUp10` — lanza el GUI de ShutUp10++ sin argumentos

**Decisión arquitectónica tomada (LOG 5):**  
Implementar perfiles nativos vía CLI: `OOSU10.exe perfil.cfg /quiet`  
Los `.cfg` se versionan en `tools/privacy-profiles/` (Basic, Medium, Aggressive).  
El binario se descarga vía `manifest.json` (ya está definido como `shutup10`).

**Lo que falta implementar:**
1. Crear `tools/privacy-profiles/basic.cfg`, `medium.cfg`, `aggressive.cfg`
2. Función `Invoke-PrivacyProfile -Profile Basic|Medium|Aggressive` en Privacy.ps1
3. Función `Start-PrivacyProcess -Profile` → async
4. Actualizar `main.ps1` opción `[13]` con sub-menú de 3 perfiles

### modules/StartupManager.ps1 — ✅ COMPLETO

#### Get-StartupEntries

- Registry: `HKLM\Run`, `HKLM\Run32`, `HKCU\Run`, `HKLM\RunOnce`, `HKCU\RunOnce`
- Check `StartupApproved` keys (byte 0 = `0x03` → disabled)
- Carpetas de inicio: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` + AllUsers
- Retorna: `Name`, `Command`, `Location`, `Enabled`, `CanToggle`, `Type`, `RunPath`, `ApprovedPath`, `FilePath`

#### Set-StartupEntry -Entry -Enabled

- Registry: escribe binario 12-byte en `StartupApproved` (0x02=on, 0x03=off)
- Folder: renombra con/sin `.disabled`
- RunOnce: read-only (no toggle)

#### Open-Autoruns

- Lanza `tools/bin/Autoruns.exe` (con fallback de error si no descargado)

---

## Infraestructura de Herramientas Externas

### tools/manifest.json (v2)

| Nombre | Archivo | URL | Tipo |
|--------|---------|-----|------|
| `autoruns` | `Autoruns.exe` | live.sysinternals.com | exe |
| `autorunsc` | `autorunsc.exe` | live.sysinternals.com | exe |
| `shutup10` | `OOSU10.exe` | dl5.oo-software.com | exe |
| `bcu` | `BCUninstaller_portable.zip` | GitHub v5.7 | zip → `BCUninstaller\` |
| `procmon` | `Procmon.exe` | live.sysinternals.com | exe |
| `procexp` | `procexp.exe` | live.sysinternals.com | exe |
| `tcpview` | `Tcpview.exe` | live.sysinternals.com | exe |

### Bootstrap-Tools.ps1 (reescrito en sesión 5)

- `-ToolName` → descarga solo una herramienta específica
- Barra de progreso: `HttpWebRequest` + loop chunked 64 KB + `X.X / Y.Y MB` en tiempo real
- ZIP: `Expand-Archive` → directorio configurable → elimina `.zip`
- `Test-ToolInstalled` con lógica `extractDir` vs `filename`
- Limpieza de archivo parcial si hash falla o error de descarga

---

## Menú Principal — Estado Completo

```
================================================
        PC OPTIMIZACION TOOLKIT
================================================
  Sistema: Windows XX - Build XXXXX

  [OPTIMIZACION]
  [1]  Deshabilitar Servicios Bloat
  [2]  Limpieza de Temporales
  [3]  Mantenimiento del Sistema
  [4]  Crear Punto de Restauracion
  [5]  Optimizar Red
  [6]  Rendimiento → [1]Balanceado [2]Maximo [3]Restaurar [4]TweaksOnly

  [DIAGNOSTICO Y AUDITORIA]
  [7]  Snapshot PRE-service
  [8]  Snapshot POST-service
  [9]  Comparar PRE vs POST
  [10] Historial de BSOD / Crashes
  [11] Backup de Drivers

  [APLICACIONES]
  [12] Apps Win32 + UWP
  [13] Privacidad (ShutUp10++) ← stub actual, pendiente sub-menú de perfiles
  [14] Inicio del Sistema

  [HERRAMIENTAS EXTERNAS]
  [T]  Herramientas
  [q]  Salir
================================================
```

---

## Decisiones de Diseño Clave

| Área | Decisión | Justificación |
|------|----------|---------------|
| Asincronismo | `Start-Job` para toda operación pesada | No bloquear consola. Sin eventos, sin runspaces custom — `Start-Job` + `Wait-ToolkitJobs` es el patrón universal |
| Strictmode | `Set-StrictMode -Version Latest` en todos los archivos | Detección temprana de variables no inicializadas y accesos a propiedades inexistentes |
| Preview→Confirm | Patrón obligatorio en operaciones destructivas (limpieza, uninstall) | `-WhatIf` no funciona en contexto de `Start-Job`. Preview síncrono logra el mismo objetivo |
| Serialización de funciones al job | `.ToString()` + `[ScriptBlock]::Create()` + `Invoke-Expression` dentro del job | Los jobs corren en runspace aislado sin acceso a funciones del scope padre |
| Privacy via CLI | `OOSU10.exe perfil.cfg /quiet` | Evita reimplementar 200+ tweaks nativamente. `.cfg` versionado = reproducible y auditable |
| Apps uninstall prioridad | QuietUninstallString > MSI > interactivo | Maximiza silencio. El fallback interactivo es safety net para instaladores no-MSI |
| Herramientas externas | `manifest.json` + Bootstrap script | Sin git-lfs, sin submodules, sin inflar el repo. URLs auditables, SHA-256 opcional |
| `SvcHostSplitThreshold` condicional | Solo aplica en RAM ≤ 8 GB | En sistemas con más RAM el split de svchost no genera overhead medible |
| Startup toggle via `StartupApproved` | Binario 12-byte en registro | Método oficial de Windows 10/11. No borra ni modifica la entrada original |

---

## Pendientes al Cierre de Sesión 5

| Feature | Prioridad | Módulo |
|---------|-----------|--------|
| Implementar perfiles Basic/Medium/Aggressive con `.cfg` + CLI | **ALTA** | `Privacy.ps1` + `tools/privacy-profiles/` |
| SHA-256 en `manifest.json` para producción | Baja | `tools/manifest.json` |
| `Restore-SystemTweaks` en Performance | Baja | `modules/Performance.ps1` |
| Pruebas en VM (testing2) | — | — |

---

*Generado: 10/3/2026 — Onboarding a GSD Framework*
