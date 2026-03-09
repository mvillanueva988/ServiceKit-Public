# PC Optimizacion Toolkit — Sesión de Desarrollo 3

## Resumen

Tercera sesión. Foco: nuevas features de rendimiento y UX, reordenamiento del menú, y preview pre-acción en operaciones destructivas.

---

## Cambios implementados

### `modules/Performance.ps1` — NUEVO

Módulo de optimización de rendimiento del sistema. Arquitectura asíncrona idéntica a los módulos anteriores.

#### `Set-BalancedVisuals`

Perfil de efectos visuales "punto intermedio": deshabilita el bloat visual sin degradar la legibilidad ni la usabilidad.

| Efecto | Estado | Clave de Registro |
|--------|:------:|-------------------|
| Smooth edges of screen fonts (ClearType) | ✅ ON | `Control Panel\Desktop` → `FontSmoothing=2`, `FontSmoothingType=2` |
| Show thumbnails instead of icons | ✅ ON | `Explorer\Advanced` → `IconsOnly=0` |
| Show window contents while dragging | ✅ ON | `Control Panel\Desktop` → `DragFullWindows=1` |
| Taskbar animations | ❌ OFF | `Explorer\Advanced` → `TaskbarAnimations=0` |
| Animate minimize / maximize | ❌ OFF | `Desktop\WindowMetrics` → `MinAnimate=0` |
| Drop shadows under desktop icons | ❌ OFF | `Explorer\Advanced` → `ListviewShadow=0` |
| Glass / Acrylic transparency | ❌ OFF | `Themes\Personalize` → `EnableTransparency=0` |
| Fade / slide menus, tooltip delays | ❌ OFF | `UserPreferencesMask` + `MenuShowDelay=0` |

Fija `VisualFXSetting=3` (Custom) para que Windows no sobrescriba los valores individuales.
Retorna `Success`, `Applied[]` y `Errors[]`.

#### `Set-UltimatePowerPlan`

- Verifica si el plan **Ultimate Performance** (`e9a42b02-d5df-448d-aa00-03f14749eb61`) está disponible.
- Si no, lo intenta importar con `powercfg /duplicatescheme`.
- Fallback a **High Performance** si no está disponible en la edición de Windows.
- Retorna `Success`, `PlanName` y `PlanGuid`.

#### Tres perfiles de efectos visuales

| Perfil | `VisualFXSetting` | ClearType | Thumbnails | Drag content | Animaciones | Transparencia |
|--------|:-----------------:|:---------:|:----------:|:------------:|:-----------:|:-------------:|
| `Set-BalancedVisuals` | 3 Custom | ✅ | ✅ | ✅ | ❌ | ❌ |
| `Set-FullOptimizedVisuals` | 2 Best Perf | ❌ | ❌ | ❌ | ❌ | ❌ |
| `Restore-DefaultVisuals` | 1 Best Appearance | ✅ | ✅ | ✅ | ✅ | ✅ |

Claves de registro compartidas refactorizadas a variables `$script:` para evitar repetición.

#### `Start-PerformanceProcess -VisualProfile 'Balanced'|'Full'|'Restore'`

Serializa el perfil elegido + `Set-UltimatePowerPlan` al contexto del job. Retorna `Visuals` y `PowerPlan`.

---

### `modules/Cleanup.ps1` — MODIFICADO

#### `Get-CleanupPreview` — NUEVA

Función síncrona (solo lectura, no borra nada) que escanea las 12 rutas de limpieza y retorna:

| Campo | Descripción |
|-------|-------------|
| `Folders[]` | Array con `Label`, `Path`, `SizeBytes`, `SizeMB` — solo carpetas con contenido |
| `TotalBytes` / `TotalMB` / `TotalGB` | Totales agregados |

Sirve como paso de preview antes de confirmar la limpieza real.

---

### `modules/Diagnostics.ps1` — NUEVO

Módulo de diagnóstico de hardware y estado del sistema. Dos features independientes en un mismo archivo.

#### `Get-BsodHistory -Days 90`

Lee el Event Log (`System`) para los últimos 90 días filtrando tres EventIDs críticos:

| EventID | Fuente | Significado |
|---------|--------|-------------|
| 41 | Kernel-Power | Reinicio sin apagado limpio (crash, corte de luz) |
| 1001 | BugCheck | BSOD confirmado — intenta extraer el Stop Code del mensaje |
| 6008 | EventLog | Apagado abrupto detectado al arrancar |

- Ordena eventos cronológico descendente
- Lista los archivos `.dmp` presentes en `C:\Windows\Minidump` con fecha y tamaño
- Retorna `TotalCrashes`, `Events[]` y `Minidumps[]`

#### `Show-BsodHistory -Data`

Visualización coloreada: rojo para BSODs (1001), amarillo para Kernel-Power (41), naranja oscuro para apagados abruptos (6008). El contador de total se colorea según severidad (verde < 2, amarillo < 5, rojo ≥ 5).

#### `Start-BsodHistoryJob -Days 90`

Wrapper asíncrono sobre `Get-BsodHistory`.

---

#### `Backup-Drivers -OutputRoot`

Exporta drivers al directorio `output\driver_backup\<timestamp>\`. Criterio de selección:

- **Drivers de terceros:** `ProviderName` no coincide con `Microsoft`
- **Drivers de red:** clase `Net`, siempre incluidos independientemente del proveedor

Estrategia de exportación en dos pasos:
1. Intenta `Export-WindowsDriver -Online -Destination` (exportación masiva, más rápida)
2. Si falla, cae a `pnputil /export-driver` driver a driver

Retorna `Success`, `Destination`, `Exported`, `Total` y `Message`.

#### `Start-DriverBackupJob -OutputRoot`

Wrapper asíncrono sobre `Backup-Drivers`.

---

### `main.ps1` — MODIFICADO (opciones 10 y 11)

| Opción | Acción |
|--------|--------|
| `[10]` Historial de BSOD / Crashes | `Start-BsodHistoryJob` + `Show-BsodHistory` |
| `[11]` Backup de Drivers | Preview de criterios → confirmar → `Start-DriverBackupJob` |

Opción 11 muestra destino y criterios antes de pedir confirmación (mismo patrón que opción 2).

---

#### Reordenamiento del menú

Las opciones de **Diagnóstico y Auditoría** siempre cierran el menú, antes del botón de salida. Rendimiento pasa a ser opción 6.

| # | Feature |
|---|---------|
| 1 | Deshabilitar Servicios Bloat |
| 2 | Limpieza de Temporales |
| 3 | Mantenimiento del Sistema (DISM/SFC) |
| 4 | Crear Punto de Restauracion |
| 5 | Optimizar Red (Adaptadores + TCP/DNS) |
| 6 | **Rendimiento** (Efectos Visuales + Plan de Energia) ← nuevo |
| — | *[DIAGNOSTICO Y AUDITORIA]* |
| 7 | Snapshot PRE-service |
| 8 | Snapshot POST-service |
| 9 | Comparar PRE vs POST |
| q | Salir |

#### Opción 2 — Preview + Confirmación

Flujo rediseñado:
1. Corre `Get-CleanupPreview` (síncrono, solo lectura).
2. Muestra tabla con cada carpeta y su peso estimado + total.
3. Pide `[s]` para confirmar → lanza `Start-CleanupProcess` asíncrono.
4. Pide `[q]` para cancelar sin tocar nada.

#### Opción 6 — Sub-menú de tres perfiles

Reemplaza el confirm estático. Muestra un sub-menú `[1] Balanceado  [2] Máximo  [3] Restaurar` con descripción de cada perfil. Ejecuta sin confirmación adicional tras elegir.

---

## Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| `Get-CleanupPreview` síncrono | Es solo `Measure-Object` sobre archivos existentes. Sin writes, sin riesgo. Job overhead innecesario. |
| Preview estático en opción 6 reemplazado por sub-menú | Tres perfiles requieren selección explícita; el preview estático ya no aplica. |
| Claves de registro en variables `$script:` | Evita repetir 5 strings de ruta idénticos en las tres funciones del módulo. |
| `UserPreferencesMask` hardcodeado en lugar de bit manipulation | La máscara `0x90,0x12,0x01,0x80...` es el valor documentado de "Best Performance" con font smoothing preservado. Modificarla por bits en PowerShell requeriría leer el valor actual y hacer AND/OR, añadiendo complejidad sin beneficio. |
| `-WhatIf` descartado por ahora | `SupportsShouldProcess` no funciona en `Start-Job` (runspace aislado). Requeriría agregar un parámetro `[bool]$DryRun` a ~20 puntos de cambio en 5 módulos. El patrón preview→confirm logra el mismo objetivo sin esa complejidad. |

---

*02:00 — 10/3/2026*
