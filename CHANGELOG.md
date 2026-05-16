# Changelog

Registro de cambios de PCTk. Formato: Keep a Changelog + SemVer.

## [Unreleased]

## [2.0.0] - 2026-05-15

Rework completo del toolkit. Arquitectura rediseñada de "menú con stubs" a **optimizador por perfiles**: el técnico elige el use-case del cliente (Generic / Office / Study / Multimedia), el toolkit detecta el hardware tier (Low / Mid / High) y aplica una receta pre-fabricada con snapshot PRE/POST automatizado.

### Added

- **Modelo de perfiles auto (4 use-cases × 3 tiers = 12 recetas)**: `data/profiles/auto/<use_case>_<tier>.json`. Cada receta declara qué servicios deshabilitar, perfil visual, nivel de privacidad y limpieza de temporales. El engine orquesta los módulos existentes a partir del JSON.
- **`core/ProfileEngine.ps1`**: orquestador de recetas — carga JSON, valida schema, aplica steps (Debloat → Performance → Privacy → Cleanup → Startup report), genera log de ejecución.
- **`core/MachineProfile.ps1` — tier classification**: detección de `Tier` (Low/Mid/High) basada en RAM, clase de CPU y VRAM de GPU. El banner del menú muestra el tier y el vendor OEM.
- **`core/Router.ps1` — menú v2 Opción A**: cuatro secciones — PERFILES, DIAGNÓSTICO, ACCIONES MANUALES (submenú `[A]`), HERRAMIENTAS. Opción `[1]` aplica perfil auto con selector de use-case; `[R]` abre el generador de research prompts.
- **`modules/ResearchPrompt.ps1`**: genera prompt estructurado para LLMs con el perfil de hardware + snapshot. 5 plantillas (Optimización, Troubleshooting, DriverAudit, MigrationReadiness, Custom). Copia al clipboard y guarda en `output/research/`.
- **`modules/CoreIsolation.ps1`**: toggle de Memory Integrity (HVCI) preservando VBS/WSL2.
- **`modules/UsbPower.ps1`**: deshabilitar/habilitar USB Selective Suspend via powercfg + registro global.
- **`modules/Hags.ps1`**: toggle de Hardware-Accelerated GPU Scheduling (HAGS).
- **`modules/Wsl.ps1`**: generador/editor de `.wslconfig` con presets (Default/Gaming/DevHeavy/DevDocker).
- **`modules/RawAudit.ps1`**: `New-RawAuditReport` — genera `.txt` human-readable en `output/audits/` desde el snapshot.
- **`modules/Privacy.ps1` — `Invoke-OOSU10Profile`**: invoca OOSU10.exe con el `.cfg` de la receta; fallback al perfil nativo si OOSU10 no está disponible.
- **`modules/Privacy.ps1` — `Add/Remove-WslDefenderExclusions`**: discovery dinámico de paths LXSS + Docker para exclusiones de Defender.
- **Snapshot enriquecido** (`Get-SystemSnapshot`): 8 campos nuevos — `DeviceGuard`, `UsbDevices`, `HidDevices`, `DnsServers`, `ThermalZones`, `InstalledPrograms`, `Steam`, `PowerPlan`. Snapshot PRE automático antes de aplicar receta; POST al final. Comparación mostrada en pantalla.
- **VM-mode** (`Get-SystemSnapshot`): detección de hypervisor via WMI. Queries que no aplican en VM (SMART, PnP, ACPI, Battery) se omiten automáticamente; el banner muestra `VM : <vendor>`. Timeout per-query configurable para evitar cuelgues en entornos virtualizados.
- **Carpeta de cliente**: `output/clients/<slug>_<fecha>/` creada automáticamente en cada run de receta — log de ejecución, snapshot PRE/POST y audit log en un solo lugar.
- **Audit log distribuido**: `Write-ActionAudit` invocado desde cada handler; log a `output/audit/<date>.jsonl`.
- **`Confirm-Action` helper**: preview de qué se va a aplicar + confirmación S/n antes de cada acción destructiva.
- **`tests/smoke.ps1`**: harness read-only que valida 39 funciones de detección y carga de recetas sin tocar el sistema.
- **`tools/manifest.json`**: DDU, LatencyMon, TimerResolution agregados. URLs rotas corregidas; versiones actualizadas (BCUninstaller 6.1.0.1, WizTree 4.31, CPU-Z 2.20, BleachBit 6.0.0).
- **`tools/Check-ToolUpdates.ps1`** + **`tools/README.md`**: helper para verificar herramientas en el manifest.

### Changed

- **Branding**: `ServiceKit v2` → `PCTk v2` en `main.ps1` y `core/Router.ps1`.
- **Performance.ps1 `Set-UltimatePowerPlan`**: detecta laptop; en laptops aplica Balanced en lugar de Ultimate Performance (evita throttle por TDP locked vía EC). Muestra el power plan previo y el comando para revertir.
- **`RestorePoint.ps1`**: muestra el punto de restauración existente y ofrece bypass de cooldown opt-in.
- **`Release.ps1`**: excluye `_local-dev/`, `.claude/` y rigs de test/sandbox del ZIP de distribución.
- **VERSION**: `1.0.3` → `2.0.0`.

### Fixed

- **Encoding**: UTF-8 BOM en 13 archivos `.ps1` — sin BOM, PowerShell 5.1 en locale es-AR leía con Windows-1252 y reventaba el parser en strings con tildes o em-dash.
- **Network.ps1 `Optimize-Network`**: acceso a propiedad inexistente en StrictMode; `netsh fastopen` no válido para `set global` en Win11 24H2; autotuning ya default en 22H2+ (no-op eliminado).
- **Network.ps1 `Get-NetworkDiagnostics`**: primera fila de `Get-NetTCPSetting` tenía campo vacío; filtra ahora por `SettingName='Internet'` + fallback locale-agnostic.
- **Telemetry.ps1**: falso positivo en `MultipleAvProblem` cuando Defender está en Passive Mode con AV tercero activo; ahora separa `Enabled` de `IsActive` via `AMRunningMode`.
- **Telemetry.ps1**: parsing de `powercfg /getactivescheme` reemplazado por regex locale-agnostic (el header varía entre locales de Windows).
- **Telemetry.ps1**: Defender duplicado en SecurityCenter2 eliminado.
- **UsbPower.ps1**: regex locale-agnostic para AC Power Setting Index (es-AR, en-US, pt-BR).
- **Telemetry.ps1 `Compare-Snapshot`**: crash con `volDiff` vacío en PS5.1 StrictMode corregido.
- **Router.ps1**: Enter vacío ya no crashea el dispatcher del menú principal.
- **`main.ps1`**: dot-source inline de módulos corregido (bug de scope que tiraba "Falta Get-MachineProfile").
- **`core/JobManager.ps1`**: `Wait-ToolkitJobs` devuelve array siempre para evitar unwrap incorrecto.

## [1.0.3] - 2026-03-14

### Fixed
- Descargas de herramientas externas endurecidas con resolución de URL final cuando el proveedor entrega HTML intermedio.
- Validación de payload para ZIP/EXE antes de extraer o ejecutar.
- Manifest de herramientas actualizado para enlaces caídos.
- Detección y resolución de ruta de lanzamiento mejorada para extraídos con carpetas versionadas.

## [1.0.2] - 2026-03-14

### Fixed
- Bootstrap: reintentos de descarga y validación de payload ZIP antes de extraer.
- Menú de herramientas: Enter vacío ya no sale del submenú; `D N -f` habilita re-descarga forzada.
- Privacidad: detección/lanzamiento de ShutUp10 unificado.
- Telemetría: referencias PRE/POST alineadas a opciones [7]/[8].
- Windows Update: fallback de fechas endurecido.
