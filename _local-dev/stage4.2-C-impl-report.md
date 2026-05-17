# Stage 4.2-C - Steam-autodetect - Impl Report

> Sonnet, 2026-05-16. Contrato: `_local-dev/stage4.2-C-plan.md`.

## Helper Steam-autodetect

**Funcion:** `Get-SteamLibraryPaths` en `core/NamedProfileEditor.ps1` (funcion privada del modulo).

**Firma:**
```powershell
function Get-SteamLibraryPaths { [OutputType([string[]])] param() }
```

**Comportamiento:**
- Lee `HKCU:\Software\Valve\Steam` → valor `SteamPath` via `Get-ItemProperty -ErrorAction SilentlyContinue`.
- Acceso al resultado via `PSObject.Properties['SteamPath']` (StrictMode-safe).
- Arma ruta `<SteamPath>\steamapps\libraryfolders.vdf` y la comprueba con `Test-Path -ErrorAction SilentlyContinue`.
- Parsea el VDF con regex `"path"\s+"([^"]+)"` (tolerante a formato); desescapa `\\` → `\` en cada path capturado.
- Retorna `[string[]]` (puede ser array vacio). **NUNCA throw** — todo el cuerpo envuelto en try/catch que retorna `@()`.
- **Cost-zero:** lectura registry + archivo, one-shot, sin proceso residente.

**Casos cubiertos:**
| Caso | Resultado |
|---|---|
| Steam no instalado / key ausente | `@()` sin throw |
| VDF ausente o no parseable | `@()` sin throw |
| Una o mas librerias en VDF | Array con sus paths |

## Cambio en el builder (New-NamedProfileInteractive)

Bloque `defender_exclusions` reemplazado. Nuevo flujo:

1. Llama `Get-SteamLibraryPaths` al entrar al bloque.
2. **Si hay sugerencias Steam:** las muestra numeradas (`[1] D:\SteamLibrary`) en amarillo. Pregunta al operador por numeros a incluir (espacio-delimitados). Los numeros validos agregan el path correspondiente; los invalidos/fuera de rango se ignoran silenciosamente.
3. **Siempre:** pregunta por paths adicionales separados por `;` (campo libre, mismo comportamiento que el prompt original).
4. Une seleccionados + adicionales y llama `Add-Tweak 'defender_exclusions' $dePaths.ToArray()` si hay al menos uno.

**Sin Steam:** solo se muestra el prompt de paths adicionales (comportamiento identico al anterior).

**Schema intacto:** `defender_exclusions` sigue siendo `[string[]]`. `Test-NamedProfileSchema` no fue tocado (validador linea 21-95 del archivo original; verificado: sin cambios).

## BOM / Parse

| Archivo | BOM post-edit | Parse-check |
|---|---|---|
| `core/NamedProfileEditor.ps1` | OK (presente tras Edit) | `ParseFile` sin errores |
| `modules/Privacy.ps1` | NO tocado | N/A |

## Smoke

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
OK: 65  FAIL: 0
```

Incluye:
- `StaticCheck::BomRegression` OK
- `NamedProfileEditor::Get-SteamLibraryPaths no-throw devuelve array` OK (nuevo)
- Todos los tests previos de schema/validador intactos

## DoD

- [x] Helper Steam-autodetect read-only, no-throw, StrictMode-safe; array vacio si no hay Steam.
- [x] Builder ofrece rutas como sugerencia opt-in en el prompt de `defender_exclusions`; schema/validador SIN cambios.
- [x] `core/NamedProfileEditor.ps1` BOM+PARSE OK.
- [x] `tests/smoke.ps1` TODO OK (65/65) incl. BomRegression + entrada read-only nueva.
- [x] Reporte generado.
