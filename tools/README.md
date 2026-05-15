# `tools/`

Herramientas externas que PCTk lanza on-demand. El menú `[T]` del Router las descarga, las pone en `tools/bin/`, y las invoca cuando hace falta.

`tools/bin/` está gitignored — los binarios se descargan vía `Bootstrap-Tools.ps1` a partir del manifest. No los commiteamos.

## `manifest.json`

Catálogo de las herramientas. Cada entry declara una **política de update** que indica cómo se mantiene "la última versión adecuada".

### Políticas

| `updatePolicy` | Quién garantiza que sea la última | Mantenimiento |
|---|---|---|
| `"latest"` | El publisher: la URL siempre devuelve la última versión. Ej: `live.sysinternals.com/X.exe`, `github.com/.../releases/latest/download/X.zip`. | **Cero**. |
| `"latest-html"` | URL devuelve HTML con redirect; `Bootstrap-Tools.ps1` lo parsea y resuelve el descargable real. Ej: SourceForge `/files/latest/download`. | Frágil — si el publisher cambia el HTML, el parser puede romperse. |
| `"pinned"` | Versión específica hardcodeada con `version` y SHA-256 opcional. | **Manual**: hay que bumpear `version` + `url` + recalcular SHA cuando hay update. |

### Campos del entry

| Campo | Requerido | Descripción |
|---|---|---|
| `name` | sí | Identificador interno (lowercase, sin espacios) |
| `category` | sí | Categoría visual del menú `[T]` |
| `description` | sí | Tooltip / texto descriptivo |
| `filename` | sí | Nombre del archivo en `tools/bin/` |
| `launchExe` | sí | Path relativo al ejecutable a lanzar (importante para ZIPs) |
| `type` | no | `"zip"` si hay que descomprimir, omitir si es .exe directo |
| `extractDir` | no | Nombre del subdir donde descomprimir (sólo para ZIPs) |
| `url` | sí (salvo placeholders) | URL de descarga directa |
| `updatePolicy` | sí | `"latest"` \| `"latest-html"` \| `"pinned"` |
| `version` | sólo `pinned` | Versión declarada |
| `checkUpdate` | sólo `pinned` | URL para verificar nuevas versiones (GitHub API o página HTML) |
| `versionPattern` | sólo `pinned` con HTML | Regex con grupos para extraer versión del HTML del `checkUpdate` |
| `approxSizeMB` | sí | Tamaño esperado, usado para detectar descargas incompletas |
| `sha256` | no | SHA-256 hex uppercase. Vacío significa "no verificable" (típico de `latest`). Recomendado para `pinned`. |

## Workflow de mantenimiento

### Chequear si hay updates

```powershell
.\tools\Check-ToolUpdates.ps1
```

Sale con código 1 si encuentra al menos una `pinned` desactualizada — útil para CI.

El script:
- Para entries `pinned` con `checkUpdate` apuntando a GitHub API: parsea `tag_name` + asset names.
- Para `checkUpdate` que devuelven HTML: usa `versionPattern` para extraer la versión. Sin `versionPattern` recurre a heurística genérica (frágil, puede dar falsos positivos).
- Compara semánticamente: `OUTDATED`, `CURRENT`, `AHEAD`, `UNKNOWN`.

### Bumpear una versión pinned

1. Verificar manualmente que la nueva URL responde (`Invoke-WebRequest -Method Head -Uri ...`)
2. Editar el entry en `manifest.json`:
   - `version` → nueva
   - `url` → nueva
   - `approxSizeMB` → actualizar si cambia mucho
   - `sha256` → recalcular con `(Get-FileHash <path> -Algorithm SHA256).Hash.ToUpper()` después de descargar
3. Re-correr `Check-ToolUpdates.ps1` para confirmar que ahora dice `CURRENT`
4. Commit con mensaje `chore(tools): bump <name> X.Y -> X.Z`

### Agregar una herramienta nueva

1. Identificar el patrón más estable disponible:
   - ¿GitHub Releases con asset estable? → `latest`, URL `/releases/latest/download/<asset>.<ext>`
   - ¿Publisher con CDN canónico (Sysinternals, OOSU10)? → `latest`
   - ¿SourceForge / sitio con redirect HTML? → `latest-html`
   - ¿Sólo URL con versión en el filename? → `pinned`
2. Agregar el entry siguiendo el schema arriba
3. Verificar que `Bootstrap-Tools.ps1` la descarga correctamente
4. Commit

## Caveats conocidos

- **Sin SHA-256 en `latest`**: si el CDN del publisher se compromete, no hay protección. Acepto el riesgo porque la alternativa (pinear todo) es insostenible.
- **BCUninstaller filename con versión completa**: los assets de BCU se llaman `BCUninstaller_<version>_portable.zip` — no hay nombre estable. Por eso queda `pinned` aunque el repo es GitHub.
- **TimerResolution**: la página de Lucas Hale tiene un download iframe — el `versionPattern` puede no matchear. Status `UNKNOWN` es esperado; verificar manualmente cada par de meses.
- **SourceForge HTML scraping**: el parser de `Bootstrap-Tools.ps1` es heurístico; si SF cambia el layout, puede fallar para `latest-html`.
