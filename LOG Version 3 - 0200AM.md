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

#### `Start-PerformanceProcess`

Serializa ambas funciones al contexto de `Start-Job` y retorna un objeto con campos `Visuals` y `PowerPlan`.

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

### `main.ps1` — MODIFICADO

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

#### Opción 6 — Confirmación con preview estático

Muestra la lista completa de qué se activa y qué se desactiva antes de ejecutar. Pide `[s]` para confirmar.

---

## Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| `Get-CleanupPreview` síncrono | Es solo `Measure-Object` sobre archivos existentes. Sin writes, sin riesgo. Job overhead innecesario. |
| Preview estático en opción 6 | Los cambios de visual effects son siempre los mismos. No requiere scan previo. |
| `UserPreferencesMask` hardcodeado en lugar de bit manipulation | La máscara `0x90,0x12,0x01,0x80...` es el valor documentado de "Best Performance" con font smoothing preservado. Modificarla por bits en PowerShell requeriría leer el valor actual y hacer AND/OR, añadiendo complejidad sin beneficio. |
| `-WhatIf` descartado por ahora | `SupportsShouldProcess` no funciona en `Start-Job` (runspace aislado). Requeriría agregar un parámetro `[bool]$DryRun` a ~20 puntos de cambio en 5 módulos. El patrón preview→confirm logra el mismo objetivo sin esa complejidad. |

---

*02:00 — 10/3/2026*
