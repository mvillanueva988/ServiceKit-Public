# Phase 8: Codebase Polish - Context

**Gathered:** 2026-03-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Resolver bugs críticos, regressions silenciosas y problemas de UX/async identificados en la auditoría CONCERNS.md. Sin refactors estructurales (main.ps1 god file, job serialization pattern) — esos son cambios de alto riesgo sin retorno funcional claro. Solo arreglos concretos y de bajo riesgo.

</domain>

<decisions>
## Implementation Decisions

### 08-01: Safety & Correctness

**Admin elevation check:**
- Agregar al inicio de `main.ps1` (antes del primer menú)
- Si no es admin: mensaje claro en rojo + `exit 1`
- Snippet: `[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`

**Spooler warning:**
- En `modules/Debloat.ps1` y en el display de la lista de servicios en `main.ps1`
- Agregar nota visible tipo `[!] Deshabilitar Spooler rompe todas las impresoras (local y red)`
- No bloquear la selección — solo advertir

**Restore point 24hr cooldown:**
- En `modules/RestorePoint.ps1`, antes de `Checkpoint-Computer` llamar `Get-ComputerRestorePoint`
- Si el más reciente tiene menos de 24h: retornar objeto con `Success=$false` y `Reason='Cooldown 24h activo'`
- El mensaje en `main.ps1` debe diferenciar cooldown de error de permisos

### 08-02: UX & Async

**CIM hardware caching:**
- En `main.ps1`, las queries `Win32_ComputerSystem` y `Win32_VideoController` deben correr UNA sola vez al inicio y guardarse en `$script:hwInfo`
- El header del menú lee `$script:hwInfo` en lugar de re-consultar CIM cada iteración

**Apps Win32 + UWP → async:**
- `Get-InstalledWin32Apps` y `Get-InstalledUwpApps` deben lanzarse con `Invoke-AsyncToolkitJob` igual que todas las otras operaciones pesadas
- Mostrar spinner mientras cargan, luego mostrar la lista cuando el job termina
- Consistente con el patrón del resto del toolkit

**Cleanup preview → async:**
- El scan de `_Get-CleanupPaths` se mueve a un job async antes de mostrar la preview
- Mensaje "Escaneando..." con spinner, luego muestra el preview con MB/GB

**Maintenance output:**
- Capturar stdout de DISM y SFC con `2>&1` en variable, no redirigir a `$null`
- Mostrar: exit code, líneas clave del output (no todo), y ruta `C:\Windows\Logs\CBS\CBS.log` si hay error
- DISM exit code 87 → mensaje específico "parámetro inválido, puede requerir actualización de fuente"

**Job error surfacing:**
- En `core/JobManager.ps1` → `Wait-ToolkitJobs`: verificar `.State -eq 'Failed'` antes de `Receive-Job`
- Si el job falló: capturar el error con `Receive-Job -ErrorVariable jobErr`, mostrar mensaje rojo con el error
- Evitar el escenario de "operación exitosa con cero resultados" cuando el job crasheó

### 08-03: Launch.ps1 Hardening

**WebClient → Invoke-WebRequest:**
- Reemplazar `[System.Net.WebClient]::new()` con `Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing`
- Agregar `-TimeoutSec 30` para timeout explícito

**Repo placeholder check:**
- Al inicio de `Launch.ps1`, si `$GitHubRepo -eq 'TU_USUARIO/TU_REPO'` o contiene `TU_`:
  ```powershell
  Write-Host '  [!] Configura $GitHubRepo en Launch.ps1 antes de usar el auto-update.' -ForegroundColor Red
  Write-Host '      Ejemplo: $GitHubRepo = "mateo/pc-toolkit"' -ForegroundColor DarkGray
  exit 1
  ```

### Items explícitamente fuera de scope

- Refactor main.ps1 en módulos → riesgo alto, no aporta funcionalidad
- Job serialization con `-InitializationScript` → refactor masivo, alto riesgo de regresión
- SHA-256 en manifest.json → ya documentado como out-of-scope
- Test coverage (Pester) → no hay framework, fuera de alcance
- `_Invoke-UninstallCommand` security → riesgo aceptable con admin + confirmación

</decisions>

<specifics>
## Specific Ideas

- El admin check en main.ps1 es la primera prioridad absoluta — muchas operaciones fallan silenciosamente sin él
- Los cambios de async (Apps, Cleanup preview) tienen el patrón exacto en otros módulos — copiar el mismo modelo
- El job error surfacing arregla el bug más insidioso: operaciones que "parecen funcionar" pero no hicieron nada

</specifics>

<deferred>
## Deferred Ideas

- main.ps1 refactor en módulos — futuro, si el proyecto crece
- Job serialization via -InitializationScript — futuro, cuando haya más funciones helper compartidas
- Pester tests — futuro, si se adopta un framework de CI

</deferred>

---

_Phase: 08-codebase-polish_
_Context gathered: 2026-03-10_
