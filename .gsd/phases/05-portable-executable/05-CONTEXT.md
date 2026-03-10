# Phase 5: Portable Executable — Context

**Gathered:** 2026-03-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Convertir el toolkit en algo ejecutable con un one-liner desde cualquier PC, sin instalación previa. El técnico (uso personal + servicio a distancia vía AnyDesk) pega un comando en PowerShell y el toolkit se descarga, extrae y lanza automáticamente. También incluye un script de build local para generar releases limpios.

</domain>

<decisions>
## Implementation Decisions

### Formato de distribución

- **ZIP + Run.bat** — no EXE compilado. ps2exe descartado: falsos positivos en AV, SmartScreen en cada PC, re-compilación en cada cambio, bugs con `Add-Type`/`Start-Job`, cero ventaja para un técnico que usa PowerShell.
- El ZIP no incluye artifacts de desarrollo: `.gsd/`, `.git/`, `Logs/`, `output/`, `tools/bin/`.

### One-liner de instalación

- Forma: `irm https://raw.githubusercontent.com/USER/Toolkit/main/Launch.ps1 | iex`
- `Launch.ps1` vive en la raíz del repo (en `main`), siempre actualizado.
- Compatible con AnyDesk: pegar en PowerShell del cliente funciona igual que local.

### Script de lanzamiento (Launch.ps1)

- Descarga el último Release ZIP de GitHub (no la rama main — el Release es el ZIP limpio).
- Extrae a ruta fija `C:\PCTk\` (no `%TEMP%` — AV lo monitoriza más, vulnerable a limpiezas, no sobrevive reconexiones de AnyDesk).
- Auto-update por sobreescritura: cada lanzamiento descarga la versión más reciente. No hay lógica de versiones — PowerShell carga módulos en memoria al inicio, sobreescribir en disco no afecta la sesión activa.
- Si la PC ya tiene `C:\PCTk\` con una versión previa: sobreescribir directamente (no limpiar primero — preserva `tools\bin\` con herramientas ya descargadas).

### Herramientas externas (manifest.json)

- On-demand siempre — no se bundlean en el ZIP.
- Actualización manual: el técnico revisa localmente si hay nueva versión → actualiza URL en `manifest.json` → push a GitHub → próximo one-liner incluye el manifest actualizado.
- Sin auto-detection de versiones en runtime (laborioso, cada tool tiene esquema distinto, innecesario para un solo usuario).
- **Bug a corregir**: `Bootstrap-Tools.ps1` actualmente no verifica integridad del archivo descargado (solo chequea existencia). Agregar verificación de tamaño mínimo para detectar descargas parciales (conexión lenta que cortó a mitad).

### Firma de código

- Sin firma. SmartScreen solo aparece si se descarga el ZIP directamente desde un browser por primera vez. Via one-liner + AnyDesk no se activa. Click "Más información → Ejecutar de todas formas" si aparece — aceptable para uso técnico personal.

### Script de build / release (Release.ps1)

- Corre localmente antes de hacer push del release.
- Genera ZIP limpio excluyendo `.gsd/`, `.git/`, `Logs/`, `output/`, `tools/bin/`, archivos de dev.
- Opcionalmente sube a GitHub Releases via API (token personal).

### Persistencia de sesión

- Herramientas descargadas (`tools\bin\`) persisten entre sesiones — no se borran al cerrar el toolkit.
- Logs (`Logs/`) y output (`output/`) persisten para revisión posterior.
- Limpieza voluntaria: Phase 7 implementa `[X] Limpiar y salir` que borra `C:\PCTk\` completo cuando el técnico termina el servicio.

### Copilot's Discretion

- Manejo de errores en `Launch.ps1`: si GitHub no responde, si la descarga falla, si no hay permisos en `C:\PCTk\` — definir comportamiento de fallback.
- Compresión del ZIP: nivel de compresión (velocidad vs tamaño).
- Nombre del Release tag en GitHub (v1.0, fecha, etc.).

</decisions>

<specifics>
## Specific Ideas

- Ruta de extracción: `C:\PCTk\` — corta, predecible, fácil de tipear para borrado manual.
- URL del one-liner: `raw.githubusercontent.com/.../main/Launch.ps1` (siempre apunta a main, no a un tag).
- El ZIP del Release es el artefacto limpio; la rama main contiene el código fuente completo (con `.gsd/` etc.).
- Caso de uso AnyDesk: abrir PowerShell en el cliente → pegar one-liner → toolkit disponible. Sin requerir que el técnico tenga el ZIP en un USB ni acceso al repo.

</specifics>

<deferred>
## Deferred Ideas

- Self-destruct automático al cerrar: pertenece a Phase 7 (Auto-Cleanup).
- No-trace mode (no crear logs, todo en memoria): Phase 7.
- Signing gratuito (SignPath, etc.): descartado por decisión explícita.

</deferred>

---

_Phase: 05-portable-executable_
_Context gathered: 2026-03-10_
