# Changelog

Registro de cambios de PCTk. Formato: Keep a Changelog + SemVer.

## [Unreleased]

### Stage 0 — Audit técnico + módulos prerequisitos

#### Fixed
- **Encoding** UTF-8 BOM en 13 archivos `.ps1` con bytes non-ASCII (em-dash, tildes en strings literales). Sin BOM, PowerShell 5.1 en locale es-AR los leía como Windows-1252 y reventaba el parser en pleno string literal. Síntoma observado: `Router.ps1` no parseaba en una máquina en español.
- **Network.ps1 `Optimize-Network`**: tres bugs reales — acceso a propiedad inexistente en StrictMode, `netsh fastopen` no válido para `set global` en Win11 24H2, y `autotuninglevel=normal` aplicado siempre aunque ya sea default. El output ahora expone `NetshIssues[]` con detalle.
- **Network.ps1 `Get-NetworkDiagnostics`**: la primera fila de `Get-NetTCPSetting` (`Automatic`) tiene el campo vacío; ahora filtra por `SettingName='Internet'` y fallback locale-agnostic en netsh.
- **Performance.ps1 `Set-UltimatePowerPlan`**: en laptops con TDP locked vía EC, Ultimate Performance degrada la performance sostenida (fuerza Min processor state alto → más temperatura → throttle más agresivo). Ahora detecta laptop y aplica Balanced; mantiene Ultimate sólo en desktop.
- **Telemetry.ps1 AV passive mode**: `MultipleAvProblem` solía dar falso positivo cuando Defender estaba en Passive Mode con un AV de terceros activo. Ahora separa `Enabled` (registrado) de `IsActive` (escaneando en tiempo real) usando `Get-MpComputerStatus.AMRunningMode`.
- **Telemetry.ps1 PowerPlan parsing**: el header real de `powercfg /getactivescheme` es `GUID de plan de energía:` (no `del esquema`). Regex reemplazado por uno locale-agnostic.
- **Telemetry.ps1 Defender duplicado**: SecurityCenter2 enumera Defender; ahora se skipea allí para evitar el duplicado con `Get-MpComputerStatus`.
- **UsbPower.ps1 regex**: locale-agnostic — matchea `Índice de configuración de corriente alterna actual` (es-AR), `Current AC Power Setting Index` (en-US) y `Índice da Configuração de Energia CA Atual` (pt-BR).
- **RawAudit.ps1 cosmetic**: `%%` literal en línea de Volumes → `%`.

#### Added
- **`modules/CoreIsolation.ps1`**: `Get-CoreIsolationStatus` + `Disable-Hvci` + `Enable-Hvci` — toggle de Memory Integrity preservando VBS para WSL2.
- **`modules/UsbPower.ps1`**: `Get-UsbSelectiveSuspendStatus` + `Disable/Enable-UsbSelectiveSuspend` — apaga selective suspend en AC + DC con registro global como reaseguro.
- **`modules/Hags.ps1`**: `Get-HagsStatus` + `Disable/Enable-Hags` — toggle de Hardware-Accelerated GPU Scheduling.
- **`modules/Wsl.ps1`**: `Test-WslAvailable` + `Get-WslConfig` + `New-WslConfig` (presets Default/Gaming/DevHeavy/DevDocker) + `Set-WslConfig` + `Invoke-WslShutdown`.
- **`modules/Privacy.ps1`**: `Add-WslDefenderExclusions` + `Remove-WslDefenderExclusions` con discovery dinámico de paths LXSS (Ubuntu/Debian/Kali/etc.) + Docker.
- **`modules/RawAudit.ps1`**: `New-RawAuditReport` produce `.txt` human-readable en `output/audits/` desde el snapshot enriquecido.
- **`modules/Telemetry.ps1` snapshot enriquecido** con 8 campos: `DeviceGuard`, `UsbDevices`, `HidDevices`, `DnsServers`, `ThermalZones`, `InstalledPrograms` (filtrado por vendors), `Steam` (autoexec + launch options), `PowerPlan`.
- **`tests/smoke.ps1`**: harness read-only que valida 20 funciones de detección sin tocar el sistema.

#### Changed
- **Branding**: `ServiceKit v2` → `PCTk v2` en `main.ps1` (mutex, error messages) y `core/Router.ps1` (banner, exit message). El resto del codebase ya usaba PCTk consistentemente.
- **VERSION**: bump `1.0.3` → `2.0.0-alpha.1` para reflejar el rework completo en curso.

#### Notes
- Stage 0 cerrado y pusheado. Próximo: Stage 1 (Router refactor a menú Opción A + Research prompt generator).

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
