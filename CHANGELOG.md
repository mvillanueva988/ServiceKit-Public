# Changelog

Registro de cambios de PCTk. Formato: Keep a Changelog + SemVer.

## [2.1.5] - 2026-06-02

Release: fix de robustez en la lectura de disco (timeout honesto en HDD lento) + neutralizacion de EAP=Stop en el backup de drivers (`pnputil`).

### Fixed

- **Lectura de disco en HDD lento devolvia el disco vacio (`modules/DiskHealth.ps1` + `modules/Telemetry.ps1`)**: en PCs con disco lento la lectura SMART/reliability cruzaba el timeout (10/8s) e `Invoke-WithTimeout` devolvia el `-Default` vacio; como el flag `TimedOut` se descartaba, el disco quedaba nulo e indistinguible de "no hay disco" -- tanto en el diagnostico `[7]` como en el snapshot PRE/POST (el "antes/despues" del cliente). Ahora el timeout se propaga: `[7]` muestra "se agoto el tiempo (PC o disco lento), no es que no haya disco", y el snapshot marca `SmartTimedOut` por disco en vez de un vacio silencioso. Timeouts subidos 10/8s -> 20/12s (constantes tuneables; el valor exacto queda por calibrar en HW con HDD lento). Bug de campo (sesion de taller).
- **`pnputil` crasheaba el backup de drivers bajo EAP=Stop (`modules/Diagnostics.ps1`)**: la llamada nativa a `pnputil` corria bajo `$ErrorActionPreference='Stop'` de `main.ps1`; en PS5.1 su stderr se vuelve `NativeCommandError` terminante y abortaba el backup. Fix: neutralizar EAP localmente (misma clase que el fix de USB `[16]` de v2.1.4).

## [2.1.4] - 2026-06-01

Release: recetas auto consolidadas a schema v2.0 + nuevo diagnostico de salud de discos `[7]` + 5 modulos expuestos en `[A][12]-[16]` + 2 fixes de crash por trap StrictMode (USB `[16]`, marca de 1 palabra).

### Added

- **Salud de discos SMART/wear (`modules/DiskHealth.ps1`, menu `[7]`)**: nuevo diagnostico que lee estado SMART y wear-level (SSD) y avisa en el menu cuando un disco esta WARN/CRIT (prediccion de falla, wear sobre umbral). Read-only.
- **5 modulos huerfanos expuestos como `[A][12]-[16]` (`core/Router.ps1`)**: modulos que existian pero no tenian entrada de menu ahora son accesibles desde el submenu avanzado `[A]`.
- **Clase `Normal` en `[15]` Process Priority (`modules/ProcessPriority.ps1`)**: ademas de las clases altas, se puede devolver un proceso a prioridad Normal.

### Fixed

- **Crash de arranque con marca de 1 palabra (`core/MachineProfile.ps1`, confirmado en cliente real)**: `Get-NormalizedManufacturer` con una marca off-brand de una sola palabra (ej. `EXO`) hacia que `$value.Split(' ') | Where-Object {...}` se desenrollara a escalar y `$parts.Count` tirara `PropertyNotFoundStrict` bajo StrictMode, crasheando `Get-MachineProfile` en el arranque y el toolkit no levantaba. Fix con el patron del repo (`[object[]] $parts = @(...)`). Canary en smoke con fixture de 1 palabra.
- **`[16]` USB crasheaba al deshabilitar (`modules/UsbPower.ps1`)**: las llamadas a `powercfg` corrian bajo `$ErrorActionPreference='Stop'` de `main.ps1`; en PS5.1 el stderr de un exe nativo se vuelve `NativeCommandError` terminante y crasheaba el toolkit entero. Fix: neutralizar EAP localmente (`Continue`) en las funciones que invocan `powercfg` y dependen de `$LASTEXITCODE`.
- **Labels `[1]` y `[A]` desalineados con el schema v2.0 (`core/Router.ps1`)**: textos de menu actualizados.

### Changed

- **Consolidación de recetas auto (data schema v1.0 → v2.0)**. Las 12 recetas auto (`<use_case>_<tier>.json` con 4 use-cases × 3 tiers) se redujeron a 3 (`<use_case>.json`, uno por use-case): `generic.json`, `work.json` (fusión de `office_*` + `study_*` que eran funcionalmente idénticos en runtime), `multimedia.json`. El audit `_local-dev/recipes-audit.md` mostró que 11 de 12 archivos tenían contenido funcional idéntico (todos `visual_profile=Balanced`, mismos services por use-case), y que el `_tier` del JSON sólo se usaba para validación de schema y display — no condicionaba ningún tweak. La diferenciación por hardware (laptop vs desktop, RAM ≤ 8 GB) sigue viviendo en los módulos `Performance` (`Set-UltimatePowerPlan`, `Set-SystemTweaks`) y `Debloat` al ejecutarse, como antes. Cambios:
  - `core/ProfileEngine.ps1`: `Get-AutoProfilePath` sin parámetro `-Tier`; `Test-AutoProfileSchema` exige `_schema_version: "2.0"`, `_tier` removido, `_use_case` con whitelist (`generic|work|multimedia|named`); `Get-AutoProfilePreviewLines` reformulada; `Invoke-AutoProfile` lee tier del `MachineProfile` (HW real) en vez del JSON.
  - `core/Router.ps1`: menú principal `[1] Generic / [2] Work / [3] Multimedia` (era 4 entradas con office + study separados). Audit-action `Profile.Apply.Work` reemplaza `Profile.Apply.Office`/`Profile.Apply.Study`.
  - `core/NamedProfileEditor.ps1` + `data/profiles/named/_sample.json`: builder y fixture en schema v2.0 (sin `_tier`, sin `_future` blocks).
  - `data/profiles/auto/`: 12 archivos viejos eliminados; 3 nuevos creados; README actualizado.
  - `docs/recipes/`: `office.md` + `study.md` reemplazados por `work.md`; `generic.md` + `multimedia.md` reescritos sin tier; índice README actualizado.
  - `data/oosu10-profiles/README.md`: referencias a `office_*`/`study_*` actualizadas a `work.json`.
  - `tests/smoke.ps1`: 13 tests de Import (1 Get-AutoProfilePath + 12 por receta) → 4 tests (1 Get-AutoProfilePath + 3 por receta). Smoke baseline 103 → 94.
  - `tests/stage3-validate.ps1`, `tests/stage2-harness.ps1`, `tests/stage4-validate.ps1`, `tests/postqueue-validate.ps1`: actualizados al shape v2.0.
- **Fix (bug latente desde v2.0)**: `multimedia_high.json` tenía `visual_profile: "Full"` que invocaba `Set-FullOptimizedVisuals` (Windows "Adjust for best performance" = apaga ClearType + thumbnails + drag-full-windows). Contraintuitivo para el use-case streaming. La nueva `multimedia.json` aplica `Balanced` para todos los casos (preserva ClearType y thumbnails — preview de archivos de video importa).

### Notes

- **`meta.json` del cliente — `schema_version` cambia, shape no**. El campo `schema_version` del `output/clients/<slug>_<ts>/meta.json` se hereda del `_schema_version` del recipe aplicado. Post v2.0, los `meta.json` nuevos tendrán `schema_version: "2.0"`. Las 11 keys del meta.json (`client`, `date`, `computer_name`, `anydesk_id`, `tier`, `use_case`, `schema_version`, `compare_score`, `status`, `amount_charged_ars`, `notes`) **NO cambian** — solo el label. Si un agregador externo lee meta.json y depende del valor literal `"1.0"` para algo, va a tener que aceptar `"2.0"` como sinónimo (mismo shape).
- **`use_case` en meta.json**: post v2.0 los valores válidos son `generic` / `work` / `multimedia` / `named`. Los `meta.json` históricos pueden tener `office` / `study` — son inmutables (audit del pasado) y siguen siendo legibles.

## [2.1.3] - 2026-05-23

Patch: fix de bug confirmado en cliente real — `[U]` perdía snapshots del workflow diagnóstico-only.

### Fixed

- **P1: `[U]` perdía `output\snapshots\` silenciosamente (bug confirmado en cliente real, 2026-05-21).** El bloque "preservar historial" de `Invoke-UninstallToolkit` estaba gateado por la existencia de `output\clients\`; en el workflow diagnóstico-only (solo `[3]` Pre, sin perfil), ese directorio no existe, el bloque se saltaba íntegramente y los snapshots se borraban junto con la instalación sin ningún aviso. Fix en dos capas: (1) `modules/ExportClientLogs.ps1` — nuevo parámetro `-TagOverride [string]` que omite el `Read-Host` interactivo cuando se pasa explícitamente (comportamiento del `[L]` standalone sin cambio). (2) `modules/UninstallToolkit.ps1` — nueva función `Save-PreUninstallArtifacts` extrae toda la lógica de preservación; el bloque (A) mantiene la UX de `output\clients\` + `output\audit\` en carpeta plana en Desktop (sin regresión); el bloque (B) NUEVO invoca `Invoke-ExportClientLogs -TagOverride 'preuninstall'` incondicionalmente, generando `<HOST>-preuninstall_<ts>.zip` en Desktop con `audit\` + `snapshots\`. Si no había ningún artifact (PCTk recién instalado), `[L]` retorna `Status='Empty'` silenciosamente y el `[U]` prosigue. Fallo del zip no aborta la desinstalación (se avisa y continúa). Gate: Sandbox limpia pendiente.

## [2.1.2] - 2026-05-20

Patch: fix de regresión crítica en self-uninstall + QoL en selectores de apps y startup + preservar audit del operador al desinstalar.

### Added

- **Apps uninstall — selector con rango (`core/Router.ps1` `Invoke-ActionApps`)**: el parser ahora acepta `N-M` además de número suelto y lista coma/espacio (también `N-M` invertido se normaliza). UI base de desinstalación ya existía en v2.1.1 (commit `7ab6b79`); este patch cubre el único gap conocido del selector.
- **Startup toggle real (`core/Router.ps1` `Invoke-ActionStartup` + `modules/StartupManager.ps1`)**: el handler `[A]→[10]` antes listaba pero el toggle era un stub no-op. Ahora togglea de verdad multi-hive — Registry `Run`/`Run32`/`RunOnce` (vía clave nativa `StartupApproved`, round-trip exacto al estilo del Administrador de tareas), carpeta Startup (rename `.lnk` ↔ `.lnk.disabled`), y **tareas programadas** (`Enable-`/`Disable-ScheduledTask`, soporte nuevo en `Get-StartupEntries`). Selección por número / lista / rango; confirm `[s/N]` si alguna entrada va a OFF. El pipeline auto NO cambia (sigue report-only por decisión de producto: Mateo deshabilita startup a mano con esta opción).
- **`F1` — preservar `output\audit\` al desinstalar (`modules/UninstallToolkit.ps1` `Invoke-UninstallToolkit`)**: cuando el operador acepta preservar el historial, además de `output\clients\` se copia también `output\audit\` al mismo destino (`Desktop\PCTk-historial-clientes\audit\*.jsonl`). El audit `Toolkit.Uninstall` se escribe ANTES del copy para quedar incluido. Alimenta el tracking persistente de clientes.

### Fixed

- **P1: el self-uninstall `[U]` no borraba `C:\PCTk` (afectaba también v2.1.0 y v2.1.1).** Causa raíz: `Run.bat` hace `pushd "%~dp0"` → el `cmd.exe` que lanzó PCTk retiene `CWD = C:\PCTk` un instante después de que `powershell.exe` muere; el deleter desprendido disparaba un único `Remove-Item -ErrorAction SilentlyContinue` antes de que `cmd.exe` muriera, perdía la race contra el CWD lock, y el fallo quedaba mudo. Fix en `New-PctkUninstallScript`: CWD propio neutral (`Set-Location $env:TEMP`) + loop de retry con verificación (80 × 750 ms ≈ 60 s, `Remove-Item` + `Test-Path`) que gana la race del `cmd.exe` y cubre además latencias de AV/handles + log persistente en `$env:TEMP\pctk-uninstall-<ts>.log` con resultado real (Deleted: True/False + intentos + último error). El mensaje al usuario deja de afirmar "borrará la carpeta" con certeza y muestra la ruta del log. Test headless `tests/uninstall-validate.ps1` T2 extendido con un `cwdHolder` separado para reproducir la race sin necesitar Sandbox. Cazado por el gate Sandbox limpia.

## [2.1.1] - 2026-05-19

Patch: icono de PCTk en la ventana de consola en runtime (branding cosmético; no toca la cadena de confianza ni el one-liner).

### Added

- **Icono de consola en runtime (`utils/ConsoleIcon.ps1`, `assets/pctk.ico`)**: `Set-PctkConsoleIcon` setea el icono de la ventana de PowerShell al arrancar `main.ps1`, vía P/Invoke (`GetConsoleWindow` + `LoadImageW` + `SendMessageW`/`WM_SETICON`, ICON_SMALL+ICON_BIG). Defensivo total: no-op silencioso si no hay consola / falta el `.ico` / falla la API; jamás aborta el toolkit. Sin proceso residente ni timers. NO toca `Launch.ps1` ni el one-liner → SHA-256 de la cadena de confianza intacto. Smoke read-only nuevo (presencia de la función + header ICO; no muta la ventana del runner).

## [2.1.0] - 2026-05-19

Minor: perfiles O&O ShutUp10++ para la rama de privacidad por receta + dos bugfixes de v2.0.1 hallados probando el release publicado en Windows Sandbox limpia.

### Added

- **Perfiles O&O ShutUp10++ (`data/oosu10-profiles/*.cfg`)**: `basic.cfg`, `medium.cfg`, `multimedia.cfg`, `aggressive.cfg` generados por ID estable desde el catálogo OOSU V2.2.1024, espejando los niveles de `modules/Privacy.ps1`. Las recetas (generic→basic, office/study→medium, multimedia→multimedia, named-aggressive→aggressive) aplican OOSU vía `Invoke-ProfilePrivacyStep` con fallback nativo si falta el `.cfg`/`OOSU10.exe`. Determinístico (272 entradas, `+` solo en el scope del nivel); historial de portapapeles / SmartScreen / Windows Update / permisos por-app quedan intactos.

### Fixed

- **Instalación rota (Execution Policy)**: el one-liner de v2.0.1 (`… -OutFile $f; & $f`) fallaba en toda máquina nueva con `SecurityError / running scripts is disabled` — la Execution Policy default (`Restricted`) bloquea ejecutar un `.ps1`. El fix de v2.0.1 había resuelto el BOM/`#Requires` (cambiando `| iex` por `& $f`) pero `& archivo` SÍ está sujeto a Execution Policy mientras que `iex` no. README ahora usa `powershell -NoProfile -ExecutionPolicy Bypass -File $f` (maneja BOM + `#Requires` + Policy). Pin a `v2.1.0`.
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
