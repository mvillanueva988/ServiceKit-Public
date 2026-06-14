# CLAUDE.md — Reglas factuales del repo

> Claude Code lee este archivo automáticamente al iniciar una sesión en
> este repo. Acá viven las reglas **factuales y estables** del proyecto:
> identidad, topología, convenciones técnicas, gates de release.
>
> Lo que **NO** está acá:
> - **Conducta orquestadora** (cómo Opus coordina Sonnet, modos
>   colaborativo/autónomo, manejo de worktrees): vive en la skill
>   user-level `orquestador` (`~/.claude/skills/orquestador/`).
> - **Contexto operativo vivo** (estado actual, features en curso,
>   cola priorizada): vive en `_local-dev/INDEX.md` (gitignored, fuera
>   del repo público).
> - **Backlog de features no desarrolladas**: `_local-dev/backlog.md`.

## Identidad git

Verificar `git config user.email` antes de cualquier commit / merge / push.

- El `userEmail` que el harness Claude Code pasa en el contexto del
  sistema **NO es fuente de verdad** para git. La fuente es
  `git config --global user.email` + `git config --local user.email`
  (para este repo específicamente).
- Si la config local difiere de la esperada → **corregir antes de
  commitear**, no proseguir. El reincidente más grave de la historia
  del repo fue por confiar en el harness en vez de en `git config`.

## Topología git (trampa importante)

- **Local `master`** trackea **`origin/main`**. NO existe rama local `main`.
- **`origin/main`** = línea v2/PCTk (default de GitHub).
- **`origin/master`** = legacy v1 abandonada (linaje `1.0.x`). **NUNCA
  tocar** — pushear/mergear ahí rompe historia publicada (high blast
  radius).
- **"merge a main"** = `git push origin master:main` (refspec explícito,
  no confiar en el push.default).
- Antes de cualquier merge / push: `git branch -vv` + `git worktree list`
  + `git status` de cada worktree.

## Commits

- **NUNCA** trailer `Co-Authored-By` ni atribución a IA en mensajes de
  commit. Esto anula el default del harness — el harness lo sugiere por
  defecto, ignorarlo siempre.
- Estilo: Conventional Commits en **español**. Tipos usados: `feat`,
  `fix`, `test`, `doc` / `docs`, `chore`, `release`.
- Pre-commit hooks: respetar (no usar `--no-verify` sin pedirlo
  explícitamente).

## Stack

**PowerShell 5.1**. NO migrar a PS7 ni a otros runtimes.

Razón: el toolkit corre en PCs de cliente vía sesiones AnyDesk (~30 min).
PS5.1 viene preinstalado en cualquier Win10/11 → fricción cero, no hace
falta bootstrap de runtime. PS7 / C# / Rust agregan runtime sin ganancia
funcional para este scope.

## BOM UTF-8 en `.ps1` con caracteres non-ASCII

PowerShell 5.1 sin BOM lee con la code page del sistema (Windows-1252 en
es-AR). Caracteres UTF-8 multi-byte (em-dash `—`, tildes en string
literals, box-drawing chars) se interpretan mal y rompen con `ParserError`
en mitad de un string.

**Regla**: después de cada `Write` / `Edit` a un `.ps1` que tenga (o
pueda tener) caracteres non-ASCII, **verificar BOM** y re-aplicar si
falta. Snippet:

```powershell
$bytes = [System.IO.File]::ReadAllBytes($path)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
if (-not $hasBom) {
    $newBytes = New-Object byte[] ($bytes.Length + 3)
    [Array]::Copy(([byte[]](0xEF,0xBB,0xBF)), 0, $newBytes, 0, 3)
    [Array]::Copy($bytes, 0, $newBytes, 3, $bytes.Length)
    [System.IO.File]::WriteAllBytes((Resolve-Path $path).Path, $newBytes)
}
```

`tests/smoke.ps1` tiene `Test-BomRegression` que falla si encuentra un
`.ps1` con non-ASCII sin BOM. Correr smoke después de ediciones grandes.

## Trampas PowerShell 5.1 conocidas

### `@()` en if-expression NO garantiza array

`$v = if (c) { @($x) } else { ... }` con un solo elemento se **desenrolla
a escalar**: el bloque del `if` enumera, y un array de 1 elemento queda
como PSCustomObject suelto sin `.Count`. Bajo `Set-StrictMode -Version
Latest`, `.Count` tira `PropertyNotFoundException` con
`FullyQualifiedErrorId PropertyNotFoundStrict`.

**Patrón seguro**:
```powershell
[object[]] $v = @()
if (c) { $v = @($x) }
```
(Variable tipada `[object[]]` + asignación por statement, no por
if-expression.)

Fixtures de smoke **deben incluir colecciones de 1 elemento** (1 RAM
slot, 1 GPU, 1 disco) — no solo ausente/vacío/multi. Una fixture sparse
SIN la propiedad no ejercita el path. El bug vive en el caso de
exactamente-1. La validación canaria es Windows Sandbox limpia
(1-de-cada-cosa por design).

### Bulk-edit a JSON: validar parse después

Si reemplazás texto en N archivos JSON (PowerShell `WriteAllText`, `sed`,
etc.), **validar parse con `ConvertFrom-Json`** en todos los archivos
tocados después del batch. Una comilla doble sin escapar dentro de un
valor string rompe el JSON silenciosamente (el archivo se escribe OK,
pero el toolkit muere al parsearlo).

### `powercfg` / exe nativo + `$ErrorActionPreference='Stop'` = crash

`main.ps1` corre con `$ErrorActionPreference = 'Stop'`. En PS5.1 el
**stderr de un ejecutable nativo** (`powercfg`, `netsh`, etc.) bajo
EAP=Stop se convierte en `NativeCommandError` **terminante** — y el
redirect NO salva: `2>&1` **y** `2>$null` tiran igual. Si el comando
escribe algo a stderr (ej. `powercfg` en una Sandbox con scheme de
energía mínimo, o un setting ausente), la llamada **crashea el toolkit
entero**.

**Regla**: toda función que invoque un exe nativo y dependa de
`$LASTEXITCODE` (no de excepciones) neutraliza EAP localmente:

```powershell
function Set-Algo {
    $ErrorActionPreference = 'Continue'   # local: auto-revierte al return
    & powercfg ... 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { ... }
    # los cmdlets PowerShell de abajo igual usan -ErrorAction Stop explicito,
    # que prevalece sobre esta preferencia local.
}
```

**El smoke NO lo caza** porque corre con `$ErrorActionPreference =
'Continue'` (mismatch con `main.ps1`). Lección del gate Sandbox #11
(2026-05-30): `[A][16]` USB crasheaba al deshabilitar; el smoke estaba
verde igual. Los tests que ejercitan handlers deben fijar `EAP='Stop'`
para espejar `main.ps1`.

### Funciones a un background job: serializar la clausura COMPLETA

`Start-Job` corre en un runspace fresco que NO tiene las funciones del
módulo. Las funciones `Start-*Process` arman el scriptblock del job con un
here-string que embebe `function X { $body }`. Hay que embeber la función
entry **Y toda función propia que llame transitivamente** - si falta una, el
job tira `CommandNotFoundException` al ejecutarse (no al armarse).

**El smoke con fixtures NO lo caza**: probar `Get-Helper` directo pasa
(existe en la sesión del smoke); el bug vive SOLO en el path del job. Lo
mismo un gate HW de una función puede pasar si se la ejercita directa y no
por el menú que la manda al job.

**Regla**: al serializar a un job, mapear el cierre transitivo de llamadas a
funciones propias y embeberlas todas. El test de regresión debe **correr el
job real** (`Start-...Process` + `Receive-Job`) y fallar si hay
`CommandNotFound`, no probar los helpers sueltos.

Lección del gate Sandbox v2.3.0 (2026-06-14): `[A][5] D` (#24) crasheaba
porque `Start-NetworkDiagnosticsProcess` serializaba `Get-NetworkDiagnostics`
pero no su cadena de helpers (`Get-NetworkAdapterReport` ->
`ConvertTo-PowerPropState`/`Test-LinkSuspect` -> `ConvertTo-Mbps`). El gate
HW había probado los helpers directos; el smoke igual. Auditados los 14
sitios de serialización a job: era el único incompleto.

## Scope del producto

**PCTk = orquestación + extractor + guía**. NO autor de tweaks hardcoded.

- **Orquesta** tools terceras curadas: OOSU10 (privacy), CrystalDiskInfo
  (SMART), CrystalDiskMark (bench disco), HWiNFO64 (sensores). Las
  descarga vía `Bootstrap-Tools.ps1` y las invoca con configs
  predefinidas.
- **Extrae** info que el sistema oculta: snapshots PRE/POST, audit
  JSONL, machine profile (`Get-MachineProfile`), reportes legibles.
- **Guía** al operador: menús con vocabulario consistente, recetas que
  encapsulan decisiones, research prompt para LLM externo cuando hace
  falta info por-PC.
- **NO** hardcodear lógica de privacy/registry/services que un proyecto
  comunitario maduro (Titus, OOSU) ya mantiene mejor.

## Recetas auto (schema v2.0)

Las recetas que aplica el menú `[1]` viven en `data/profiles/auto/`:

```
generic.json     work.json     multimedia.json
```

- `_schema_version: "2.0"`.
- `_use_case` whitelist: `generic` / `work` / `multimedia` / `named`.
- **Sin `_tier`** en el JSON (v1.0 tenía 4 use-cases × 3 tiers = 12
  archivos; v2.0 colapsó a 3). La diferenciación por hardware (laptop
  vs desktop por chassis, RAM ≤ 8 GB → `SvcHostSplitThreshold`, etc.)
  vive en `modules/Performance.ps1` al ejecutarse, no en el JSON.
- Validación: `Test-AutoProfileSchema` en `core/ProfileEngine.ps1`.
- Spec completa por receta: `docs/recipes/README.md`.

Las recetas nombradas (`data/profiles/named/`) usan el mismo schema con
`_use_case: "named"` + bloque `gaming_tweaks`.

## Tests

- Baseline: `tests/smoke.ps1` → **94/0**. Correr después de cada
  edición grande.
- Para cambios al engine/pipeline: validar también con
  `tests/stage2-harness.ps1` + `tests/postqueue-validate.ps1` (mutantes,
  requieren Sandbox o VM efímera).
- El smoke read-only **NO alcanza** para validar pipelines mutantes. Para
  esa clase de bug, correr en Windows Sandbox limpia.

## Gate de release

Cada release **DEBE** validarse en **Windows Sandbox limpia** instalando
con el **one-liner REAL del README** (apuntando al tag a publicar) y
ejercitando a mano los paths cambiados, **antes de declarar la release
"lista"**.

Smoke / code-review / resúmenes de Sonnets/Opus **NO alcanzan** para
esta clase de bug — dejaron pasar 3 releases rotas en mayo 2026 (BOM en
ZIP, Execution Policy, StrictMode con 1 RAM slot). La Sandbox las cazó
las 3 veces.

Runbook del gate: `_local-dev/sandbox-gate-runbook.md` (gitignored).

## Repo público y docs internos

- **Público**: `mvillanueva988/ServiceKit-Public`.
- `_local-dev/` y `HANDOFF_*.md` están gitignored. **Mantenerlo así** —
  cero doc interno adentro del repo público.
- `_local-dev/INDEX.md` = punto de entrada único para reanudar trabajo
  operativo. Si alguien arranca una sesión en este repo y quiere ver "qué
  está abierto", leer ese archivo primero.
- `_local-dev/backlog.md` = features no desarrolladas (estados: ACTIVE /
  DESIGN / PRODUCT-DECISION / PARKED / GATED / FUTURE).
- **Regla de retiro**: cuando se cierra una feature auditada, mover
  `<feat>-plan.md` + `<feat>-impl-report.md` a `_local-dev/_archive/
  <feat>/` y retirar la entrada del INDEX VIVO.

## Branding

**PCTk** (PC Toolkit). El código histórico mezclaba 3 nombres (PCTk,
ServiceKit v2, PC Optimización Toolkit) — desde v2.0 todo dice PCTk.
Cualquier string nuevo referido al producto va como "PCTk".
