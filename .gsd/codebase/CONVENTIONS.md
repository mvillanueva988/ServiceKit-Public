# Coding Conventions

**Analysis Date:** 2026-03-10

## Mandatory Header

Every `.ps1` file opens with `Set-StrictMode -Version Latest` as the first executable line. Entry point `main.ps1` additionally declares `#Requires -Version 5.1` as the very first line.

```powershell
#Requires -Version 5.1        # main.ps1 only
Set-StrictMode -Version Latest
```

## Naming Patterns

**Files:**
- PascalCase, one module per file: `Network.ps1`, `StartupManager.ps1`, `JobManager.ps1`
- Filename matches the primary concept exported, not a fixed verb

**Functions (public):**
- PowerShell approved `Verb-Noun` pattern: `Get-NetworkDiagnostics`, `Invoke-PrivacyTweaks`, `Set-BalancedVisuals`
- Async job launchers always named `Start-<Concept>Process` or `Start-<Concept>Job`: `Start-NetworkProcess`, `Start-DebloatProcess`, `Start-PrivacyJob`
- Data collectors: `Get-*` prefix
- Mutating operations: `Set-*`, `Invoke-*`, `Disable-*`, `New-*`, `Restore-*`

**Functions (private/internal):**
- Prefixed with `_` to signal non-public: `_Get-CleanupPaths`
- Not exported; called only within the same file

**Variables:**
- Local: camelCase with explicit type annotation inline — `[string] $adapterGuid`, `[bool] $overallSuccess`
- Module-scoped (shared across functions in same file): `$script:DesktopPath`, `$script:TelemetryModulePath`
- No global variables anywhere

**Parameters:**
- PascalCase: `$AdapterNames`, `$ServicesList`, `$Profile`
- Mandatory params use `[Parameter(Mandatory)]`, optional params use bare `[Parameter()]`

## Strong Typing

All local variables carry explicit type casts. This is non-negotiable under `Set-StrictMode -Version Latest`.

```powershell
[string]   $adapterGuid  = ($adapter.InterfaceGuid -replace '[{}]', '').ToLower()
[bool]     $overallSuccess = $true
[int]      $pingMs        = -1
[object[]] $targets       = @($allAdapters | Where-Object { $_.Status -eq 'Up' })
```

Properties in returned `[PSCustomObject]` are always cast:

```powershell
return [PSCustomObject]@{
    AdaptersOptimized = [PSCustomObject[]] $optimized.ToArray()
    Success           = [bool] $overallSuccess
}
```

## Collections

**Mutable accumulation:** Always `[System.Collections.Generic.List[T]]`, never `+=` on arrays:

```powershell
[System.Collections.Generic.List[PSCustomObject]] $optimized =
    [System.Collections.Generic.List[PSCustomObject]]::new()
$optimized.Add([PSCustomObject]@{ Name = $adapter.Name; ChangesMade = $changesMade })
# Convert at return boundary:
return $optimized.ToArray()
```

**Deduplication sets:** `[System.Collections.Generic.HashSet[string]]`

```powershell
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (-not $seen.Add($name)) { continue }
```

**Empty-safe `[object[]]` wrapping:** Any CIM/cmdlet call that might return `$null` or a single object is wrapped with `@(...)`:

```powershell
[object[]] $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
[object[]] $targets     = @($allAdapters | Where-Object { ... })
```

## Function Structure

Every public function follows this layout:

1. `[CmdletBinding()]` attribute block
2. `.SYNOPSIS` comment block (Spanish prose)
3. Typed `param()` block
4. Section comments with `# -- Section Name --` or `# ─── Section ───────────` separators
5. Local variable declarations with types
6. Logic body
7. Single structured `return [PSCustomObject]@{...}` at each exit point

```powershell
function Optimize-Network {
    <#
    .SYNOPSIS
        Deshabilita características de ahorro de energía en adaptadores ...
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $AdapterNames
    )

    # -- 1. Resolver adaptadores objetivo --
    [System.Collections.Generic.List[PSCustomObject]] $optimized = ...
    [bool] $overallSuccess = $true

    # ... logic ...

    return [PSCustomObject]@{
        AdaptersOptimized = [PSCustomObject[]] $optimized.ToArray()
        Success           = [bool] $overallSuccess
    }
}
```

## Asynchronous Job Pattern

Every module exposes a symmetric pair:

| Function | Purpose |
|---|---|
| `Get-X` / `Invoke-X` / `Set-X` | Pure logic, synchronous, testable in isolation |
| `Start-XProcess` / `Start-XJob` | Serializes the above function and dispatches via `Invoke-AsyncToolkitJob` |

Serialization uses `${Function:FunctionName}.ToString()` to capture the function body:

```powershell
function Start-DebloatProcess {
    [CmdletBinding()]
    param([Parameter()][string[]] $ServicesList)

    $fnBody   = ${Function:Disable-BloatServices}.ToString()
    $jobBlock = [scriptblock]::Create(@"
param([string[]]`$ServicesList)
function Disable-BloatServices {
$fnBody
}
Disable-BloatServices -ServicesList `$ServicesList
"@)

    $argList = @(, [string[]] $(if ($ServicesList ...) { $ServicesList } else { @() }))
    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DebloatServices' -ArgumentList $argList
}
```

Note: `@(, ...)` (comma prefix) forces PowerShell to pass the array as a single element in `ArgumentList`.

## Return Objects

All public functions return `[PSCustomObject]` — never raw values, never `void`. Standard result shapes:

**Operation result:**
```powershell
return [PSCustomObject]@{
    Success = [bool] $true
    Message = [string] 'Descripción'
}
```

**Operation with counters:**
```powershell
return [PSCustomObject]@{
    Disabled = $disabled
    Failed   = $failed
    Errors   = $errors.ToArray()
}
```

**Data query result:**
```powershell
return [PSCustomObject]@{
    TcpAutoTuning = [string]    $tcpTuning
    Adapters      = [object[]]  $adapters
    PingMs        = [int]       $pingMs
}
```

## Error Handling

**Non-critical errors (expected, skippable):** `-ErrorAction SilentlyContinue`. Execution continues silently.

**Errors that should abort the current item but not the whole operation:** `try/catch` per-item, accumulate into `$errors` list, continue loop:

```powershell
foreach ($svcName in $targetServices) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
        $disabled++
    }
    catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # Servicio no existe — omitir silenciosamente (typed catch, no logging)
    }
    catch {
        $failed++
        $errors.Add("$svcName : $($_.Exception.Message)")
    }
}
```

**Fatal pre-conditions:** `throw` with descriptive Spanish message (rare, only in Telemetry.ps1 for validation):

```powershell
throw 'No se encontro snapshot PRE. Usa la opcion [6] antes del service.'
```

**Never** used: `Write-Error` inside module functions (only in Bootstrap-Tools.ps1 at script level). No re-throwing of caught exceptions from module logic.

## Output Suppression

Suppress pipeline output with `$null = ...` or `| Out-Null` for explicit clarity:

```powershell
$null = & netsh int tcp set global autotuninglevel=normal 2>&1
New-Item -Path $path -Force | Out-Null
```

Use `*> $null` only when redirecting both stdout and stderr (e.g., DISM, SFC calls):

```powershell
DISM /Online /Cleanup-Image /RestoreHealth *> $null
```

## Comments

**Section delimiters (visual):**
```powershell
# -- 1. Resolver adaptadores objetivo --
# ─────────────────────────────────────────────────────────────────────────────
#  BSOD / CRASH HISTORY
# ─────────────────────────────────────────────────────────────────────────────
# ─── _Get-CleanupPaths ────────────────────────────────────────────────────────
```

**Inline explanatory comments:** Single `#` with space, Spanish or English, placed on line above or to the right. Used when the intent is not obvious from the code:

```powershell
# Normalizar GUID del adaptador para comparación con NetCfgInstanceId del Registro
[string] $adapterGuid = ($adapter.InterfaceGuid -replace '[{}]', '').ToLower()
```

**No JSDoc-style `@param`/`@returns`** in `.SYNOPSIS` blocks — synopsis is free prose describing behavior and return value inline.

## UI / Console Output

All user-facing output via `Write-Host` with explicit `-ForegroundColor`. Color semantics:
- `Cyan`: section headers, module names
- `DarkCyan`: dividers, category labels
- `Green`: success, OS/HW info
- `Yellow`: warnings, items needing attention
- `Red`: errors, high-risk items
- `DarkGray`: descriptive sub-text under menu items

Format specifiers (`-f`) used for aligned tabular output:
```powershell
Write-Host ('  {0,-21} {1,-7} {2,-35} {3}' -f 'Fecha', 'ID', 'Tipo', 'Detalle') -ForegroundColor DarkCyan
```

## Language

- Code identifiers and function names: English
- UI text (Write-Host), `.SYNOPSIS` content, inline comments: Spanish
- Registry paths, Windows API names: English as-is

---

_Convention analysis: 2026-03-10_
