# Changelog

Registro de cambios del Toolkit de optimizacion para Windows.

Formato: Keep a Changelog + versionado semantico.

## [Unreleased]

### Notes
- A partir de este punto, las versiones se toman desde `VERSION` (`MAJOR.MINOR.PATCH`).
- Los releases historicos con fecha (`v2026.03.xx`) se mantienen como legado de transicion.

## [v1.0.2] - 2026-03-14

### Fixed
- Bootstrap: reintentos de descarga y validacion de payload ZIP antes de extraer.
- Menu de herramientas: Enter vacio ya no sale del submenu; `D N -f` habilita re-descarga forzada explicita.
- Privacidad: deteccion/lanzamiento de ShutUp10 unificado para evitar falsos "no descargado".
- Telemetria: referencias PRE/POST alineadas a opciones [7]/[8] del menu actual.
- Windows Update: fallback de fechas endurecido para evitar valores ambiguos/invalidos.

## [v2026.03.14] - 2026-03-14

### Added
- Publicacion de release en GitHub con assets:
  - PCTk-2026.03.14.zip
  - PCTk-2026.03.14.zip.sha256

### Changed
- Launch configurado al repo real: mvillanueva988/ServiceKit-Public.
- Flujo de distribucion por Releases validado para descarga y actualizacion.

### Fixed
- Correccion en Apps para evitar colision con variable automatica args.

## [v2026.03.13] - 2026-03-14

### Changed
- Hardening de launcher y ajustes de despliegue previos al release estable.

## [v2026.03.10] - 2026-03-10

### Added
- Cierre de fases funcionales 1 a 8:
  - Core toolkit y modulos principales.
  - Privacy con perfiles nativos.
  - Compatibilidad, auto-cleanup y polish de codebase.

### Notes
- Este changelog refleja el producto Toolkit (no el framework interno de planificacion).
