# PC Optimizacion Toolkit — Sesión de Desarrollo 4

## Resumen

Cuarta sesión. Foco: integración de `Set-SystemTweaks` al flujo de rendimiento, guía de diagnóstico en el historial de BSOD, perfil `TweaksOnly` en el sub-menú de Performance, y arquitectura para herramientas externas sin inflar el repositorio.

---

## Cambios implementados

### `modules/Performance.ps1` — MODIFICADO

#### `Set-SystemTweaks` — NUEVA

Función de ajustes de sistema independientes del perfil visual. Se ejecuta en todos los perfiles de rendimiento.

| Tweak | Mecanismo | Condición |
|-------|-----------|-----------|
| Deshabilitar hibernación | `powercfg /h off` | Siempre |
| Reducir `WaitToKillServiceTimeout` | Registro → `2000` ms | Siempre |
| Reducir `WaitToKillAppTimeout` | Registro → `2000` ms | Siempre |
| Game DVR (`GameDVR_Enabled`) | `HKCU:\...\GameBar → 0` | Siempre |
| `SvcHostSplitThreshold` | Ajustado a RAM total en bytes | Solo si RAM ≤ 8 GB — en sistemas con más RAM el split ya no impacta |

Retorna `Success`, `Applied[]` y `Errors[]`.

#### `Start-PerformanceProcess` — ACTUALIZADO

- `ValidateSet` ampliado a `'Balanced' | 'Full' | 'Restore' | 'TweaksOnly'`
- Serializa `$fnTweaks = ${Function:Set-SystemTweaks}.ToString()` junto a los demás cuerpos de función
- El job embebe y llama `Set-SystemTweaks` en todos los perfiles
- Para `TweaksOnly`, el paso visual se omite (`$v = $null`) pero `Set-UltimatePowerPlan` y `Set-SystemTweaks` se ejecutan igual
- Retorna `[PSCustomObject]@{ Visuals = ...; PowerPlan = ...; Tweaks = ... }`

---

### `modules/Diagnostics.ps1` — MODIFICADO

#### `Show-BsodHistory` — ACTUALIZADO

Agrega un bloque de guía diagnóstica después del listado de eventos. Dos niveles de análisis:

**Lookup table de Stop Codes** (5 patrones):

| Patrón de Stop Code | Causa probable |
|---------------------|---------------|
| `MEMORY_MANAGEMENT`, `PAGE_FAULT_IN_NONPAGED_AREA`, `IRQL_NOT_LESS_OR_EQUAL` | RAM defectuosa o incompatible — ejecutar MemTest86 |
| `DRIVER_POWER_STATE_FAILURE`, `SYSTEM_THREAD_EXCEPTION_NOT_HANDLED` | Driver de energia / dispositivo mal manejado — actualizar o revertir drivers |
| `*DPC*`, `*DRIVER*`, `*SYSTEM_SERVICE*` (genérico) | Driver incompatible o corrupto — revisar drivers recientes |
| `WHEA_UNCORRECTABLE_ERROR`, `MACHINE_CHECK_EXCEPTION` | Inestabilidad de hardware — temperatura, voltaje, overclocking |
| `NTFS_FILE_SYSTEM`, `FAT_FILE_SYSTEM`, `CRITICAL_PROCESS_DIED` | Error de disco — ejecutar `chkdsk /r` |

**Heurísticas por patrón de eventos:**

| Patrón detectado | Interpretación |
|------------------|---------------|
| Múltiples EventID 41 (Kernel-Power) sin ningún 1001 (BugCheck) | Probable PSU inestable u overheating — sin BSOD real registrado |
| Múltiples EventID 6008 (apagado abrupto) sin EventID 41 | Cortes de electricidad o apagados forzados por el usuario — no hardware |

---

### `main.ps1` — MODIFICADO

#### Sub-menú opción 6 — ACTUALIZADO

Añadida opción `[4]`:

```
[4]  Tweaks del sistema  (sin tocar visuales)
     Deshabilita hibernacion y Game DVR.
     Reduce shutdown timeout. Ajusta SvcHost threshold segun RAM.
```

Texto de nota actualizado: *"Los perfiles 1-3 incluyen también: Power Plan + Tweaks del sistema."*

#### Switch `$visualProfile` — ACTUALIZADO

```powershell
'4' { 'TweaksOnly' }
```

#### Bloque de resultado — ACTUALIZADO

- Visuals y PowerPlan envueltos en `if ($null -ne $result.Visuals / PowerPlan)` — se omiten si el perfil es `TweaksOnly`
- Nuevo bloque **Tweaks del Sistema** siempre visible: lista cada ítem aplicado en verde, errores en rojo

---

### Arquitectura de herramientas externas — NUEVA

Solución al problema de repo bloat (herramientas externas ~500 MB sin subir a git).

#### [Bootstrap-Tools.ps1](Bootstrap-Tools.ps1)

Script de setup a correr una sola vez en cada máquina nueva.

- Lee `tools/manifest.json`
- Descarga cada herramienta con `[System.Net.WebClient]`
- Verifica SHA-256 si está definido en el manifest — borra el archivo si no coincide
- Flag `-Force` para re-descargar aunque ya existan

#### [tools/manifest.json](tools/manifest.json)

Declara 4 herramientas Sysinternals con URL oficial y campo `sha256` (vacío hasta fijar versiones):

| Herramienta | Descripción |
|-------------|-------------|
| `autoruns` | Startup entries — Sysinternals |
| `procmon` | Process Monitor — Sysinternals |
| `procexp` | Process Explorer — Sysinternals |
| `tcpview` | Conexiones de red activas — Sysinternals |

#### `.gitignore` — ACTUALIZADO

Agregado `tools/bin/` para excluir binarios descargados del repo.

---

## Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| `Set-SystemTweaks` corre en todos los perfiles, incluido `Restore` | Los tweaks de registro (GameDVR, timeouts) son independientes de los efectos visuales. Restaurar visuals no implica revertir tweaks de latencia. |
| `SvcHostSplitThreshold` condicional a ≤8 GB RAM | En sistemas con más RAM el split de svchost.exe no genera overhead medible. Evita tocar registros en equipos donde no aplica. |
| Manifest JSON + Bootstrap script en lugar de submodules o scripts de descarga ad-hoc | Centraliza URLs y hashes en un solo archivo versionado. Fácil de auditar, actualizar y verificar. Sin dependencias de git-lfs ni herramientas externas para el bootstrap. |
| `sha256` vacío por ahora | Las URLs de Sysinternals Live apuntan siempre a la última versión; el hash cambiaría con cada actualización. Se llenará cuando se fijen versiones específicas para producción. |

---

## Estado del menú (post-sesión 4)

| # | Feature |
|---|---------|
| 1 | Deshabilitar Servicios Bloat |
| 2 | Limpieza de Temporales (preview + confirm) |
| 3 | Mantenimiento del Sistema (DISM/SFC) |
| 4 | Crear Punto de Restauracion |
| 5 | Optimizar Red (Adaptadores + TCP/DNS) |
| 6 | **Rendimiento** → sub-menú `[1]` Balanceado `[2]` Máximo `[3]` Restaurar `[4]` TweaksOnly |
| — | *[DIAGNOSTICO Y AUDITORIA]* |
| 7 | Snapshot PRE-service |
| 8 | Snapshot POST-service |
| 9 | Comparar PRE vs POST |
| 10 | Historial de BSOD / Crashes |
| 11 | Backup de Drivers |
| q | Salir |

---

*03:00 — 10/3/2026*
