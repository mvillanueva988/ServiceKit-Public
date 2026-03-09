# PC Optimizacion Toolkit — Sesión de Desarrollo 2

## Resumen

Segunda sesión de desarrollo. Foco principal: sistema de auditoría diagnóstica PRE/POST service.
Se analizaron los scripts de la versión anterior (`oldscripts/`) para rescatar lógica válida y descartar lo que causaba bugs y exceso de información.

---

## Scripts anteriores analizados como referencia

| Archivo | Descripción |
|---------|-------------|
| `collect_info.ps1` | Recopilación de datos del sistema (20 pasos síncronos, sin jobs) |
| `compare_pre_post.ps1` | Comparación PRE/POST basada en mover JSONs manualmente entre carpetas |
| `generate_report.ps1` | Generador de reportes Markdown + HTML desde JSON |

---

## Problemas identificados en la versión anterior

| Problema | Detalle |
|----------|---------|
| **Flujo PRE/POST roto** | El técnico debía mover manualmente el JSON de `output\pre_service\` a `output\post_service\`. Sin ese paso el comparador fallaba con error. |
| **Velocidad** | 20 pasos completamente síncronos. `Get-WindowsDriver -Online -All` podía tardar 60+ segundos. `Microsoft.Update.Session` COM era lento e inconsistente. |
| **Exceso de datos** | Capturaba slots de RAM, BIOS, placa madre, event log de 7 días, scheduled tasks completas, 300+ apps instaladas. Ninguno de esos datos cambia con un service. |
| **Temperatura CPU** | Placeholder vacío con comentario *"HWiNFO CLI requiere versión PRO"*. |

---

## Lógica rescatada del código viejo

- `Get-StorageReliabilityCounter` para temperatura, wear% y errores SMART de discos físicos.
- Detección GPU dedicada/integrada por regex en el nombre del adaptador.
- Estructura de comparación de volúmenes por letra de unidad (join key: `DriveLetter`).
- Cálculo de battery health: `(FullChargeCapacity / DesignCapacity) * 100`.
- Score *"X/N áreas mejoradas"* del reporte comparativo — pieza más valiosa para el técnico.

---

## Cambios implementados

### `modules/Telemetry.ps1` — NUEVO

Módulo de auditoría diagnóstica completo, siguiendo la arquitectura asíncrona del proyecto.

#### `Get-SystemSnapshot -Phase Pre|Post`

Recopila vía CIM/WMI y retorna un `PSCustomObject` con campo `Phase` incorporado:

| Campo | Fuente | Comparar pre/post |
|-------|--------|:-----------------:|
| CPU (nombre, cores, threads) | `Win32_Processor` | |
| GPU (nombre, tipo, driver) | `Win32_VideoController` | |
| RAM total GB | `Win32_ComputerSystem` | |
| RAM slots (capacity, speed, fabricante) | `Win32_PhysicalMemory` | |
| Discos: health, temp SMART, wear%, errores R/W | `Get-PhysicalDisk` + `Get-StorageReliabilityCounter` | |
| Volúmenes: espacio libre GB y % usado | `Get-Volume` | ✓ |
| Page File: current y peak usage MB | `Win32_PageFileUsage` | ✓ |
| Servicios: running count + bloat activos | `Get-Service` | ✓ |
| Startup count (registry Run + carpetas) | Registry + filesystem | ✓ |
| Top 5 procesos por WorkingSet MB | `Get-Process` | ✓ |
| Batería: charge%, health%, status | `Win32_Battery` (solo laptops) | ✓ |
| Antivirus: lista + flag `MultipleAvProblem` | `SecurityCenter2` + `Get-MpComputerStatus` | ✓ |
| Temperatura CPU | `MSAcpi_ThermalZoneTemperature` (best-effort, `$null` si no disponible) | |
| UptimeHours | `Win32_OperatingSystem` | ✓ |

#### `Save-Snapshot -Phase Pre|Post`
- Ejecuta `Get-SystemSnapshot` y guarda el JSON en `output\snapshots\`.
- Nombre: `yyyy-MM-dd_HHmmss_pre.json` / `yyyy-MM-dd_HHmmss_post.json`.
- Retorna `Phase`, `FilePath` y `FileName`. **Sin movidas manuales de archivos.**

#### `Compare-Snapshot [-PrePath] [-PostPath]`
- Carga automáticamente los JSONs más recientes de cada fase.
- Genera diff estructurado. Score **0/6** con lista de mejoras concretas.

| Área del score | Condición para sumar punto |
|----------------|---------------------------|
| Almacenamiento | Espacio total liberado > 0.1 GB |
| Servicios | Running count disminuyó |
| Bloat | Al menos un servicio bloat deshabilitado |
| Startup | Programas de inicio removidos |
| Antivirus | Conflicto de múltiples AV resuelto |
| Sistema | Uptime del POST menor al PRE (reinicio detectado) |

#### `Show-SnapshotComparison -Diff $diff`

Visualización coloreada en consola:

| Indicador | Color | Significado |
|-----------|-------|-------------|
| `[+]` | Verde | Área mejorada |
| `[-]` | Rojo | Área empeorada |
| `[ ]` | Gris | Sin cambios |
| `[!]` | Amarillo | Advertencia (ej: no reiniciado) |

Score final: verde ≥ 5, amarillo ≥ 3, rojo < 3.

#### `Start-TelemetryJob -Phase Pre|Post`
Wrapper asíncrono sobre `Save-Snapshot`. Dot-sourcea el módulo dentro del job para garantizar acceso a todas las funciones en el contexto del background job.

---

### `main.ps1` — MODIFICADO

Nueva sección **[DIAGNOSTICO Y AUDITORIA]** en el menú:

| Opción | Acción |
|--------|--------|
| `[6]` Snapshot PRE-service | `Start-TelemetryJob -Phase 'Pre'` |
| `[7]` Snapshot POST-service | `Start-TelemetryJob -Phase 'Post'` |
| `[8]` Comparar PRE vs POST | `Compare-Snapshot` + `Show-SnapshotComparison` |

---

### `.github/copilot-instructions.md` — MODIFICADO

Agregado ítem sobre la carpeta `/oldscripts`: uso exclusivo como referencia de diseño, carpeta temporal que será eliminada al finalizar el refactor.

---

*23:30 — 9/3/2026*
