# Phase 7: Auto-Cleanup / Self-Removal - Context

**Gathered:** 2026-03-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Mecanismo de auto-limpieza que permite al técnico borrar el toolkit de una PC ajena al terminar su sesión de trabajo. El toolkit se vuelve inutilizable sin re-descarga, con confirmación explícita antes de ejecutar.

</domain>

<decisions>
## Implementation Decisions

### Trigger

- Opción `[X] Limpiar y salir` visible en el **menú principal** (mismo nivel que Debloat, Network, etc.)
- Al seleccionar, el toolkit **pide confirmación** antes de proceder ("¿Estás seguro? Esta acción es irreversible.")
- El usuario debe confirmar explícitamente — sin confirmación, no pasa nada

### Alcance del borrado

- Borra el **directorio completo del toolkit** usando `$PSScriptRoot` para detectar la ruta (Copilot decide la implementación segura)
- Los **logs quedan** — no se borran (no son prioridad)
- El script queda **inutilizable** tras el borrado — el técnico necesita descargarlo de nuevo para usarlo
- El borrado debe ser recursivo e incluir todos los archivos del directorio

### Post-borrado

- Mostrar un **mensaje de confirmación** ("Toolkit eliminado. Hasta la próxima." o similar) antes de cerrar
- Luego cerrar la consola / terminar el proceso limpiamente

### Self-destruct EXE

- **Descartado para esta fase** — queda para una fase futura si se retoma el empaquetado en EXE

### No-trace mode

- **Descartado** — solo limpieza al final, no prevención de huellas durante la sesión

</decisions>

<specifics>
## Specific Ideas

- El borrado usa `$PSScriptRoot` como raíz — el script sabe dónde vive, sin importar dónde lo copió el técnico
- El mensaje final debe ser breve y claro, no técnico

</specifics>

<deferred>
## Deferred Ideas

- Self-destruct del EXE empaquetado — requiere retomar empaquetado EXE (futuro)
- No-trace mode (sin logs durante sesión) — podría ser una fase independiente

</deferred>

---

_Phase: 07-auto-cleanup_
_Context gathered: 2026-03-10_
