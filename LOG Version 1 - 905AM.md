# PC Optimizacion Toolkit — Resumen del Proyecto

## Vision general

Toolkit de optimización de PC escrito íntegramente en PowerShell 5.1, sin dependencias externas.
Toda la lógica usa cmdlets nativos, WMI/CIM y llamadas al SO.
Cada operación pesada corre en background mediante `Start-Job` para no bloquear la consola.

---

## Arquitectura

| Capa | Archivo | Rol |
|------|---------|-----|
| Entrypoint | `Run.bat` | Lanzador UAC: eleva privilegios y llama a `main.ps1` |
| Entrypoint | `main.ps1` | Dot-source de todos los módulos + menú interactivo |
| Core | `core/JobManager.ps1` | Motor asíncrono: `Invoke-AsyncToolkitJob` y `Wait-ToolkitJobs` |
| Módulos | `modules/*.ps1` | Lógica funcional independiente, cada uno con función principal y wrapper `Start-*` |
| Utils | `utils/HelpContent.ps1` | Contenido educativo por tema (`Get-ToolkitHelp`) |

---

## Features implementadas

### [1] Debloat de Servicios — `Debloat.ps1`
- Catálogo de 12 servicios bloat clasificados por riesgo (`Alto` / `Medio` / `Bajo`): Xbox Live, telemetría (DiagTrack), fax, Remote Registry, impresión, etc.
- El menú escanea cuáles existen en el sistema y los presenta en tabla coloreada con estado actual.
- Selección granular por número, rango o `all`. Deshabilitado asíncrono vía job.

### [2] Limpieza de Temporales — `Cleanup.ps1`
- Borra archivos temporales de 12 rutas: `%SystemRoot%\Temp`, Prefetch, SoftwareDistribution\Download, caché de Chrome, Edge, Firefox, Brave, Opera GX, logs de Windows, etc.
- Para Windows Update detiene y reinicia `wuauserv` automáticamente.
- Retorna MB/GB liberados y contador de errores no críticos.

### [3] Mantenimiento del Sistema — `Maintenance.ps1`
- Ejecuta `DISM /Online /Cleanup-Image /RestoreHealth` y `sfc /scannow` en secuencia.
- Reporta el código de salida de cada proceso. Informa la ruta del log CBS.

### [4] Punto de Restauración — `RestorePoint.ps1`
- Habilita System Restore en `C:\` si está desactivado.
- Crea un checkpoint tipo `MODIFY_SETTINGS` con descripción `Toolkit Pre-Service`.
- Maneja el límite de 1 punto cada 24 h de Windows con mensaje informativo.

### [5] Optimización de Red — `Network.ps1`
- Detecta adaptadores físicos activos (Ethernet `802.3` y Wi-Fi `Native 802.11`).
- Deshabilita propiedades de ahorro energético en el Registro de cada NIC: `EEE`, `GreenEthernet`, `PowerSavingMode`, `EnablePME`, `ULPMode`, etc.
- Aplica configuración global TCP: `AutoTuningLevel=Normal`, `FastOpen=Enabled`, `ipconfig /flushdns`.
- Submódulo `[i]` de información educativa detallando el impacto de cada optimización.

---

## Core: Motor Asíncrono — `JobManager.ps1`

| Función | Descripción |
|---------|-------------|
| `Invoke-AsyncToolkitJob` | Wrapper tipado sobre `Start-Job`, acepta nombre y argumentos opcionales |
| `Wait-ToolkitJobs` | Espera un array de jobs con spinner visual `\|/-\` y contador de activos. Retorna el output agregado limpiando la línea al finalizar |

---

*09:05 — 9/3/2026*
