# Changelog

Registro de cambios de PCTk. Formato: Keep a Changelog + SemVer.

## [Unreleased]

## [2.0.2] - 2026-05-19

Patch: dos bugs de v2.0.1 hallados probando el release publicado en Windows Sandbox limpia.

### Fixed

- **Instalación rota (Execution Policy)**: el one-liner de v2.0.1 (`… -OutFile $f; & $f`) fallaba en toda máquina nueva con `SecurityError / running scripts is disabled` — la Execution Policy default (`Restricted`) bloquea ejecutar un `.ps1`. El fix de v2.0.1 había resuelto el BOM/`#Requires` (cambiando `| iex` por `& $f`) pero `& archivo` SÍ está sujeto a Execution Policy mientras que `iex` no. README ahora usa `powershell -NoProfile -ExecutionPolicy Bypass -File $f` (maneja BOM + `#Requires` + Policy). Pin a `v2.0.2`.
- **`New-ResearchPrompt` crash en máquinas con 1 módulo de RAM** (`modules/ResearchPrompt.ps1`): el hardening de v2.0.1 usaba `$slotsArr = if (c) { @($x) } else { $null }`; la expresión-`if` enumera la salida del bloque y con 1 solo elemento el `@()` se desenrolla a escalar → un PSCustomObject suelto no tiene `.Count` → `PropertyNotFoundException` bajo StrictMode. Se disparaba en VM/Sandbox/laptops (1 slot RAM). Corregido a variable tipada `[object[]]` + asignación por statement. + regresión smoke con colecciones de 1 elemento (la fixture sparse anterior no tenía `RamSlots`, por eso no lo cazó).

## [2.0.1] - 2026-05-18

Patch: bugs hallados probando el v2.0.0 publicado + endurecimiento.

### Fixed

- **Instalación rota**: el one-liner `irm … | iex` fallaba porque `Launch.ps1` arranca con BOM UTF-8 + `#Requires` (el BOM queda como carácter antes de `#Requires` y PowerShell lo trata como comando). Las instrucciones del README ahora **descargan a archivo y lo ejecutan** (`& $f`), que maneja BOM/`#Requires` correctamente.
- **`New-NamedProfileInteractive` (`core/NamedProfileEditor.ps1`)**: `Add-Tweak` escribía `$script:gt` (scope nunca seteado) → crash StrictMode al primer toggle; rompía **todo** el builder interactivo de recetas nombradas (`[2] → [1] Nueva`). Además leía un `$gt` local distinto del retornado (receta vacía). Corregido a `$gt` (scope dinámico) + regresión en smoke.
- **`New-ResearchPrompt` (`modules/ResearchPrompt.ps1`)**: decenas de accesos anidados a `$Snapshot`/`$MachineProfile` sin guarda bajo StrictMode podían crashear el generador de research según el hardware/PC. Blindados con helper `_Rp_Prop` + `PSObject.Properties` (modelo `Show-MachineBanner`); output de campos presentes intacto. + regresión smoke (snapshot sparse).
- **`.gitattributes`**: los rigs `tests/uninstall-*` se filtraron al ZIP público de v2.0.0 (la lista enumeraba rigs por nombre y no incluía los nuevos). Glob `tests/*-{validate.ps1,sandbox-launcher.ps1,sandbox.wsb,sandbox-test.wsb,harness.ps1}` cubre presente y futuro sin enumerar (no afecta `tests/smoke.ps1`).

### Changed

- **`README.md`**: método de instalación documentado = descargar-a-archivo + ejecutar (no `irm|iex`); one-liner pineado a `v2.0.1`.
- **`data/oosu10-profiles/README.md`**: set real de `.cfg` que consumen las recetas — `basic.cfg` (generic), `medium.cfg` (office/study), **`multimedia.cfg`** (multimedia); `aggressive.cfg` solo el named. CLI real `OOSU10.exe <cfg> /quiet` (antes documentaba `/ofile=`, incorrecto).

### Added

- **`tests/smoke.ps1` — harness de abort-seguro de handlers interactivos**: Bugs StrictMode (named-builder, research-prompt) shippearon porque ningún test ejercitaba los handlers interactivos del Router. Nuevos tests drivean `Invoke-ActionStartup` / `Invoke-ActionApps` / `Invoke-ResearchPrompt` a su abort-seguro verificado (Read-Host shadow) y asertan no-crash bajo StrictMode.

## [2.0.0] - 2026-05-17

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
- **`tests/smoke.ps1`**: harness read-only que valida 76 funciones de detección y carga de recetas sin tocar el sistema.
- **`tools/manifest.json`**: DDU, LatencyMon, TimerResolution agregados. URLs rotas corregidas; versiones actualizadas (BCUninstaller 6.1.0.1, WizTree 4.31, CPU-Z 2.20, BleachBit 6.0.0).
- **`tools/Check-ToolUpdates.ps1`** + **`tools/README.md`**: helper para verificar herramientas en el manifest.
- **Self-uninstall (`core/Router.ps1` + `modules/UninstallToolkit.ps1`)**: `[X]` pasa a **"Salir"** (deja todo instalado); nueva opción **`[U]` "Desinstalar PCTk de esta PC"** — doble confirmación (preview + tipear `BORRAR`), preserva `output/clients/` fuera de la instalación, y un desinstalador desprendido borra solo el footprint de PCTk (carpeta de instalación + `%TEMP%\PCTk-*`) recién después de cerrar el proceso. Validado en Windows Sandbox.
- **Apps — desinstalación interactiva (`core/Router.ps1` `Invoke-ActionApps` + `modules/Apps.ps1`)**: la opción `[8]` ahora lista Win32 + UWP indexado, selección múltiple, preview del método (Quiet / MSI / Interactive para Win32, `Remove-AppxPackage` usuario actual para UWP) y confirmación única; desinstala con audit por app + batch.
- **Startup — toggle interactivo (`core/Router.ps1` `Invoke-ActionStartup` + `modules/StartupManager.ps1`)**: la opción `[10]` ahora activa/desactiva entradas de inicio (Registry StartupApproved + carpeta Startup), respeta `RunOnce` (no editable) y re-lee el estado tras cada cambio.
- Con lo anterior se cierran los **2 últimos stubs de menú** (`Stage 2+ extiende este handler`): la transición de "menú con stubs" a optimizador por perfiles queda 100% real.

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
