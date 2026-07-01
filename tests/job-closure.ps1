# =============================================================================
# job-closure.ps1  -  Static transitive-closure net for background-job
#                     serialization (backlog #26-A1).
#
# WHY THIS EXISTS
#   PS5.1 Start-Job runs in a fresh runspace with NONE of the module functions.
#   The Start-*Process helpers build the job scriptblock with a here-string that
#   embeds `function X { <body> }` for each function the job needs. If a function
#   the entry calls TRANSITIVELY is not embedded, the job throws
#   CommandNotFoundException AT RUNTIME (not at build time) and the read-only
#   smoke does NOT catch it. This exact bug shipped release v2.3.0 broken
#   (Start-NetworkDiagnosticsProcess forgot the Get-NetworkAdapterReport chain).
#   See CLAUDE.md "Funciones a un background job".
#
# WHAT IT DOES (no side effects, safe to run anywhere incl. the dev PC)
#   1. Parses core/ + modules/ ASTs and builds the repo call graph
#      (top-level function -> repo functions it calls, transitively).
#   2. Finds every job-serialization site: a here-string passed to
#      [scriptblock]::Create(...). EMBEDDED = the `function <Name>` decls in it.
#   3. For each site, asserts the transitive closure of the embedded functions
#      is itself embedded. Any repo function reachable-but-not-embedded is a
#      latent CommandNotFound (site.Missing).
#
# BLIND SPOT (declared, never silently green)
#   Dynamic dispatch (& $var, Invoke-Expression) can't be resolved statically.
#   Sites whose embedded functions use it are flagged (site.Dynamic = $true),
#   not passed silently. Also: inline scriptblock jobs (NOT here-string ->
#   [scriptblock]::Create) are out of scope, e.g. Telemetry.ps1's self-contained
#   inline job. Kept explicit here so coverage is never assumed complete.
#
# API
#   Get-JobClosureReport -RepoRoot <path>  ->  PSCustomObject with:
#     .RepoFuncCount [int]
#     .Sites [PSCustomObject[]]  each: Enclosing, File, Line, Embedded[],
#                                      Missing[], Dynamic[bool]
#   Dot-source this file to get the function without side effects. Run it
#   directly (powershell -File) to print a report and exit 0/1.
# =============================================================================

function Get-JcAstFromFile {
    param([string] $Path)
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $perrors = $null
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perrors)
}

function Test-JcAstIsNested {
    # $true if this FunctionDefinitionAst is nested inside another function.
    param([System.Management.Automation.Language.Ast] $Node)
    [System.Management.Automation.Language.Ast] $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }
        $p = $p.Parent
    }
    return $false
}

function Get-JcEnclosingFunctionName {
    param([System.Management.Automation.Language.Ast] $Node)
    [System.Management.Automation.Language.Ast] $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
        $p = $p.Parent
    }
    return '<top-level>'
}

function Get-JcTransitiveClosure {
    param([string[]] $Roots, [hashtable] $Graph)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $stack = New-Object 'System.Collections.Stack'
    foreach ($r in $Roots) { [void]$stack.Push($r) }
    while ($stack.Count -gt 0) {
        [string] $n = [string]$stack.Pop()
        if ($seen.Contains($n)) { continue }
        [void]$seen.Add($n)
        if ($Graph.ContainsKey($n)) {
            foreach ($c in @($Graph[$n])) {
                if (-not $seen.Contains($c)) { [void]$stack.Push($c) }
            }
        }
    }
    return $seen
}

function Get-JobClosureReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepoRoot)

    Set-StrictMode -Version Latest   # function-scoped: revierte al return, no filtra al caller (smoke usa EAP=Continue)

    [string[]] $scanDirs = @('core', 'modules') | ForEach-Object { Join-Path $RepoRoot $_ }
    [object[]] $files = @()
    foreach ($d in $scanDirs) {
        if (Test-Path $d) { $files += @(Get-ChildItem -Path $d -Filter '*.ps1' -File -Recurse) }
    }

    # ---- pass 1: top-level repo functions + their ASTs ----------------------
    $defs = @{}   # name -> FunctionDefinitionAst
    foreach ($f in $files) {
        [System.Management.Automation.Language.Ast] $ast = Get-JcAstFromFile -Path $f.FullName
        [object[]] $fnAsts = @($ast.FindAll(
            { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($fn in $fnAsts) {
            if (Test-JcAstIsNested -Node $fn) { continue }   # nested = private to parent
            if (-not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = $fn }
        }
    }
    $repoNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $defs.Keys) { [void]$repoNames.Add($k) }

    # ---- pass 2: direct call graph + dynamic-dispatch flag ------------------
    $graph = @{}          # name -> string[] repo callees
    $dynamic = @{}        # name -> $true if body uses & $var / Invoke-Expression
    foreach ($name in $defs.Keys) {
        [System.Management.Automation.Language.FunctionDefinitionAst] $fn = $defs[$name]
        $callees = New-Object 'System.Collections.Generic.HashSet[string]'
        [bool] $hasDyn = $false

        [object[]] $cmds = @($fn.Body.FindAll(
            { param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
        foreach ($c in $cmds) {
            [string] $cn = $c.GetCommandName()
            if ([string]::IsNullOrEmpty($cn)) { $hasDyn = $true; continue }
            if ($cn -eq 'Invoke-Expression' -or $cn -eq 'iex') { $hasDyn = $true }
            if ($repoNames.Contains($cn)) { [void]$callees.Add($cn) }
        }
        $graph[$name] = @($callees)
        $dynamic[$name] = $hasDyn
    }

    # ---- pass 3: find job sites (here-string -> [scriptblock]::Create) ------
    [object[]] $siteResults = @()
    foreach ($f in $files) {
        [System.Management.Automation.Language.Ast] $ast = Get-JcAstFromFile -Path $f.FullName
        [object[]] $creates = @($ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $null -ne $a.Member -and $a.Member.Value -eq 'Create' -and
            $a.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $a.Expression.TypeName.FullName -match 'ScriptBlock'
        }, $true))

        foreach ($cr in $creates) {
            if ($null -eq $cr.Arguments -or @($cr.Arguments).Count -eq 0) { continue }
            [string] $hereText = $cr.Arguments[0].Extent.Text
            [object[]] $m = @([regex]::Matches($hereText, '(?m)^\s*function\s+([A-Za-z_][A-Za-z0-9_\-]*)'))
            if ($m.Count -eq 0) { continue }   # not a function-serialization block
            [string[]] $embedded = @($m | ForEach-Object { $_.Groups[1].Value })

            $embSet = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($e in $embedded) { [void]$embSet.Add($e) }

            [string[]] $roots = @($embedded | Where-Object { $repoNames.Contains($_) })
            $closure = Get-JcTransitiveClosure -Roots $roots -Graph $graph

            [string[]] $missing = @()
            foreach ($cn in $closure) {
                if ($repoNames.Contains($cn) -and -not $embSet.Contains($cn)) { $missing += $cn }
            }

            [bool] $siteDyn = $false
            foreach ($e in $roots) { if ($dynamic.ContainsKey($e) -and $dynamic[$e]) { $siteDyn = $true } }

            $siteResults += ,([PSCustomObject]@{
                Enclosing = (Get-JcEnclosingFunctionName -Node $cr)
                File      = $f.Name
                Line      = $cr.Extent.StartLineNumber
                Embedded  = $embedded
                Missing   = @($missing)
                Dynamic   = $siteDyn
            })
        }
    }

    return [PSCustomObject]@{
        RepoFuncCount = $repoNames.Count
        Sites         = @($siteResults | Sort-Object File, Line)
    }
}

# ---- direct-run entry point (skipped when dot-sourced) ----------------------
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    [string] $root = Split-Path -Parent $PSScriptRoot
    $rep = Get-JobClosureReport -RepoRoot $root

    [int] $failCount = 0
    [int] $warnCount = 0
    Write-Host ''
    Write-Host '=== Job-serialization closure net (#26-A1) ===' -ForegroundColor Cyan
    Write-Host ("Repo funcs: {0}   Job sites: {1}" -f $rep.RepoFuncCount, @($rep.Sites).Count)
    Write-Host ''

    foreach ($s in @($rep.Sites)) {
        [string] $label = ('{0}  [{1}:{2}]' -f $s.Enclosing, $s.File, $s.Line)
        if (@($s.Missing).Count -gt 0) {
            $failCount++
            Write-Host ("  [FAIL] {0}" -f $label) -ForegroundColor Red
            Write-Host ("         embebidas: {0}" -f (@($s.Embedded) -join ', '))
            Write-Host ("         FALTAN en el job (CommandNotFound latente): {0}" -f (@($s.Missing) -join ', ')) -ForegroundColor Red
        }
        elseif ($s.Dynamic) {
            $warnCount++
            Write-Host ("  [WARN] {0}" -f $label) -ForegroundColor Yellow
            Write-Host '         cierre estatico COMPLETO, pero usa dispatch dinamico (& $var / IEX)'
            Write-Host '         -> requiere cobertura por corrida real; no se da por verde en silencio'
        }
        else {
            Write-Host ("  [OK]   {0}  ({1} func)" -f $label, @($s.Embedded).Count) -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host ('Resultado: {0} FAIL, {1} WARN, {2} OK' -f `
        $failCount, $warnCount, (@($rep.Sites).Count - $failCount - $warnCount))

    if ($failCount -gt 0) {
        Write-Host 'CIERRE INCOMPLETO: hay sitios que romperian con CommandNotFound en el job.' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Todos los sitios de job tienen el cierre transitivo completo.' -ForegroundColor Green
    exit 0
}
