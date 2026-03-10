---
phase: 05-portable-executable
plan: 01
subsystem: distribution
tags: [launcher, release, zip, github-releases, one-liner]

dependency_graph:
  requires:
    - "04b: All modules functional — main.ps1 must work standalone to be launchable"
  provides:
    - "Launch.ps1: one-liner installer/updater for any PC"
    - "Release.ps1: local build script generating clean distribution ZIP"
  affects:
    - "05-02: Bootstrap integrity fix + README (one-liner URL documented in README)"
    - "07-01: Auto-Cleanup (deletes C:\\PCTk\\ on exit)"

tech_stack:
  added: []
  patterns:
    - "WebClient.DownloadFile for binary downloads (no header parsing)"
    - "Move-Item for atomic tools\\bin\\ preservation across updates"
    - "Compress-Archive with '$staging\\*' glob for flat ZIP (no root folder)"

key_files:
  created:
    - Launch.ps1
    - Release.ps1
  modified:
    - .gitignore

decisions:
  - "param() block must come before Set-StrictMode in PS5 scripts — fixed during execution"
  - ".github/ excluded from ZIP (contains GSD/Copilot dev artifacts, not toolkit code)"
  - "TLS 1.2 forced explicitly in Launch.ps1 (older Windows defaults can fail HTTPS)"

metrics:
  duration: "~15 min"
  completed: "2026-03-10"
---

# Phase 5 Plan 1: Distribution Scripts Summary

**One-liner:** ZIP distribution via GitHub Releases with auto-updating launcher and local build script.

## What Was Built

### Launch.ps1 (84 lines)

Receptor del one-liner `irm .../Launch.ps1 | iex`:

1. Llama a `api.github.com/repos/$GitHubRepo/releases/latest` para obtener el URL del ZIP
2. Descarga a `$env:TEMP\PCTk-update.zip` via `WebClient.DownloadFile` (TLS 1.2 forzado)
3. Preserva `C:\PCTk\tools\bin\` moviéndolo a `$env:TEMP` antes de extraer
4. Extrae ZIP a `C:\PCTk\` (sobreescritura completa)
5. Restaura `tools\bin\` (herramientas externas no se re-descargan)
6. Lanza `C:\PCTk\main.ps1`

**Fallback:** si GitHub no responde y existe versión local → lanza local.
**Fatal error:** si no hay internet ni versión local → muestra URL de descarga manual.

Constante `$GitHubRepo = 'TU_USUARIO/TU_REPO'` marcada con comentario `<-- cambiar esto`.

### Release.ps1 (111 líneas)

Build script local para generar el ZIP de distribución:

- Parámetros: `-Version` (default: fecha actual) y `-Publish` (sube a GitHub Releases)
- Copia fuente a staging en `$env:TEMP`
- Elimina del staging: `.git`, `.gsd`, `.github`, `Logs`, `output`, `dist`, `memories`, `tools\bin`, `Release.ps1`, `GSD-STYLE.md`, `CHANGELOG.md`, `*.code-workspace`
- Genera ZIP con `Compress-Archive "$staging\*"` → flat ZIP sin carpeta raíz
- Con `-Publish`: verifica `$env:GITHUB_TOKEN`, crea release + sube asset via GitHub API

ZIP final: 0.1 MB, 21 archivos, solo código del toolkit.

## Commits

| Hash | Type | Description |
|------|------|-------------|
| 886bcfc | feat | Launch.ps1 one-liner installer handler |
| f2719e6 | feat | Release.ps1 build script + dist/ to .gitignore |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Set-StrictMode before param() causes parse error in PS5**

- **Found during:** Task 2 — syntax validation
- **Issue:** `Set-StrictMode -Version Latest` colocado antes de `param()` hace que PS5 interprete los parámetros como assignment statements inválidos
- **Fix:** Movido `Set-StrictMode` a después del bloque `param()`
- **Files modified:** Release.ps1
- **Commit:** f2719e6

**2. [Rule 2 - Missing Critical] .github/ leaked into ZIP (dev artifacts)**

- **Found during:** Task 2 — ZIP content verification
- **Issue:** `.github/` contiene archivos GSD/Copilot (agents, skills, instructions) que no pertenecen al toolkit distribuido
- **Fix:** Agregado `.github` a la lista `$excludeDirs` en Release.ps1
- **Files modified:** Release.ps1
- **Commit:** f2719e6

## Next Phase Readiness

**05-02** (Bootstrap integrity fix + README rewrite) puede proceder inmediatamente. No tiene dependencias sobre los archivos de esta plan.

El one-liner real se documentará en README una vez el usuario configure `$GitHubRepo` en Launch.ps1 y publique el primer release en GitHub.
