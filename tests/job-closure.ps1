# =============================================================================
# job-closure.ps1  -  Static transitive-closure net for background-job
#                     serialization (backlog #26-A1) + $script: reads (P2b).
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
#   Same runspace, second class of bug: a function that runs inside the job and
#   reads `$script:<Name>` that nothing assigned IN THE JOB. In the main session
#   the module defined it; in the job it does not exist -> $null (or
#   VariableIsUndefined under StrictMode), usually swallowed by a try/catch.
#   Audit 2026-10-13 called it E15 (Telemetry.ps1 energy GUIDs, fixed d228ca7).
#
# WHAT IT DOES (no side effects, safe to run anywhere incl. the dev PC)
#   1. Parses core/ + modules/ ASTs and builds the repo call graph
#      (top-level function -> repo functions it calls, transitively).
#   2. Finds every job site, two kinds:
#      - HereString: a here-string passed to [scriptblock]::Create(...).
#        EMBEDDED = the `function <Name>` decls in it.
#      - Inline: a literal { ... } scriptblock passed to Start-Job /
#        Invoke-AsyncToolkitJob. If it dot-sources a module (`. $ModPath`), the
#        module is resolved statically (see BLIND SPOT) and EMBEDDED = every
#        top-level function of that file + the functions defined in the block.
#   3. Missing: the transitive closure of the job's roots must be embedded. Any
#      repo function reachable-but-not-embedded is a latent CommandNotFound.
#   4. ScriptVars (by AST: VariableExpressionAst with scope `script`): reads of
#      `$script:<Name>` in the job text and in the bodies of the embedded
#      functions the job reaches, whose Name is NOT assigned inside the job.
#      "Assigned inside the job" = an assignment `$script:<Name> = ...` in the
#      job text itself, in an embedded function body, or (Inline + dot-source)
#      at FILE level of the dot-sourced module, which runs in the job when the
#      block dot-sources it. Measured 2026-10-13: a file-level `$script:X = ...`
#      of a module dot-sourced inside Start-Job IS visible to its functions in
#      the job (pre-d228ca7 Telemetry.ps1 returned PerfBoostModeAc=4 in a real
#      job). What breaks is a `$script:` defined in ANOTHER file, or only in
#      the main session, or never.
#      In a HereString site, an UNESCAPED `$script:X` inside the here-string is
#      expanded at build time in the main session (fine); only the escaped
#      `$script:X form survives into the job text and counts as a job read.
#
# BLIND SPOT (declared, never silently green)
#   - Dynamic dispatch (& $var, Invoke-Expression) can't be resolved statically.
#     Sites whose embedded functions use it are flagged (site.Dynamic = $true),
#     not passed silently.
#   - Inline dot-source resolution: the target is taken as the enclosing file
#     only when that file has a file-level `$script:<V> = $PSCommandPath` and the
#     enclosing function reads `$script:<V>` (the Start-TelemetryJob pattern).
#     Any other dot-source target -> site.Dynamic = $true (WARN), not green.
#   - ScriptVars ignores ORDER: an assignment anywhere in the job counts, even if
#     a read could run before it. It also ignores `Get-Variable/Set-Variable
#     -Scope Script`, `$ExecutionContext.SessionState` and other non-AST access.
#   - Runspaces that are not jobs (Invoke-WithTimeout's PowerShell.Create +
#     AddScript) are out of scope: a `$script:` inside those blocks is just as
#     unresolved, but this net does not look there.
#
# API
#   Get-JobClosureReport -RepoRoot <path>  ->  PSCustomObject with:
#     .RepoFuncCount [int]
#     .Sites [PSCustomObject[]]  each: Enclosing, File, Line, Kind, Embedded[],
#                                      Missing[], ScriptVars[], Dynamic[bool]
#     ScriptVars entries read "<where> -> $script:<Name>" (<where> = function
#     name, or '<job>' for the job text itself).
#   Dot-source this file to get the function without side effects. Run it
#   directly (powershell -File) to print a report and exit 0/1.
# =============================================================================

function Get-JcAstFromFile {
    param([string] $Path)
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $perrors = $null
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perrors)
}

function Get-JcAstFromText {
    param([string] $Text)
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $perrors = $null
    return [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$perrors)
}

function Test-JcAstIsNested {
    # $true if this node is nested inside a FunctionDefinitionAst.
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

function Get-JcEnclosingFunctionAst {
    param([System.Management.Automation.Language.Ast] $Node)
    [System.Management.Automation.Language.Ast] $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
        $p = $p.Parent
    }
    return $null
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

function Get-JcScriptVarName {
    # 'script:Foo' -> 'Foo'
    param([System.Management.Automation.Language.VariableExpressionAst] $Var)
    [string] $up = $Var.VariablePath.UserPath
    return $up.Substring($up.IndexOf(':') + 1)
}

function Test-JcIsAssignTarget {
    # $true if $Var is the plain target of `=` (also `[type] $script:X = ...`).
    # Compound `+=` etc. read the old value -> they count as reads.
    param([System.Management.Automation.Language.VariableExpressionAst] $Var)
    [System.Management.Automation.Language.Ast] $node = $Var
    [System.Management.Automation.Language.Ast] $p = $Var.Parent
    if ($p -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $p; $p = $p.Parent }
    return ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            [object]::ReferenceEquals($p.Left, $node) -and
            $p.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals)
}

function Get-JcScriptVarUse {
    # Splits the $script: variables of an AST into Reads / Assigns (name lists).
    # -FileLevelOnly: only nodes NOT inside a function definition (file-level code).
    param(
        [System.Management.Automation.Language.Ast] $Ast,
        [switch] $FileLevelOnly
    )
    [object[]] $vars = @($Ast.FindAll({
        param($a)
        $a -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.VariablePath.IsScript
    }, $true))
    $reads = New-Object 'System.Collections.Generic.List[string]'
    $assigns = New-Object 'System.Collections.Generic.List[string]'
    foreach ($v in $vars) {
        if ($FileLevelOnly -and (Test-JcAstIsNested -Node $v)) { continue }
        [string] $n = Get-JcScriptVarName -Var $v
        if (Test-JcIsAssignTarget -Var $v) { $assigns.Add($n) } else { $reads.Add($n) }
    }
    return [PSCustomObject]@{ Reads = @($reads); Assigns = @($assigns) }
}

function Get-JcUnassignedScriptVars {
    # $ReadsByWhere: ordered hashtable where -> string[] names read.
    # $Assigned: HashSet[string] (OrdinalIgnoreCase) of names assigned in the job.
    param([System.Collections.Specialized.OrderedDictionary] $ReadsByWhere, $Assigned)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $dedup = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($where in $ReadsByWhere.Keys) {
        foreach ($n in @($ReadsByWhere[$where])) {
            if ($Assigned.Contains($n)) { continue }
            [string] $entry = ('{0} -> $script:{1}' -f $where, $n)
            if ($dedup.Add($entry)) { $out.Add($entry) }
        }
    }
    return @($out)
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
    $defs = @{}        # name -> FunctionDefinitionAst
    $fileAsts = @{}    # FullName -> ScriptBlockAst
    $fileFuncs = @{}   # FullName -> string[] top-level function names
    foreach ($f in $files) {
        [System.Management.Automation.Language.Ast] $ast = Get-JcAstFromFile -Path $f.FullName
        $fileAsts[$f.FullName] = $ast
        [object[]] $fnAsts = @($ast.FindAll(
            { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $names = New-Object 'System.Collections.Generic.List[string]'
        foreach ($fn in $fnAsts) {
            if (Test-JcAstIsNested -Node $fn) { continue }   # nested = private to parent
            $names.Add($fn.Name)
            if (-not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = $fn }
        }
        $fileFuncs[$f.FullName] = @($names)
    }
    $repoNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $defs.Keys) { [void]$repoNames.Add($k) }

    # ---- pass 2: direct call graph + dynamic-dispatch flag + $script: use ---
    $graph = @{}          # name -> string[] repo callees
    $dynamic = @{}        # name -> $true if body uses & $var / Invoke-Expression
    $svUse = @{}          # name -> PSCustomObject Reads/Assigns ($script: in the body)
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
        $svUse[$name] = Get-JcScriptVarUse -Ast $fn.Body
    }

    # ---- pass 3: find job sites ---------------------------------------------
    [object[]] $siteResults = @()
    foreach ($f in $files) {
        [System.Management.Automation.Language.Ast] $ast = $fileAsts[$f.FullName]

        # -- 3a: here-string -> [scriptblock]::Create -------------------------
        [object[]] $creates = @($ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $null -ne $a.Member -and $a.Member.Value -eq 'Create' -and
            $a.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $a.Expression.TypeName.FullName -match 'ScriptBlock'
        }, $true))

        foreach ($cr in $creates) {
            if ($null -eq $cr.Arguments -or @($cr.Arguments).Count -eq 0) { continue }
            [System.Management.Automation.Language.Ast] $arg0 = $cr.Arguments[0]
            [string] $hereText = $arg0.Extent.Text
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

            # $script: -- the job text = the here-string AFTER build-time expansion.
            # Its skeleton is the string value (escapes processed, $vars unexpanded);
            # unescaped $script:X were expanded at build time (main session) -> not job reads.
            [string] $skeleton = ''
            $buildTime = @{}   # name -> count of unescaped (build-time) $script: reads
            if ($arg0 -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                $skeleton = $arg0.Value
                foreach ($nv in @($arg0.FindAll({
                    param($a)
                    $a -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.VariablePath.IsScript
                }, $true))) {
                    [string] $bn = Get-JcScriptVarName -Var $nv
                    if ($buildTime.ContainsKey($bn)) { $buildTime[$bn]++ } else { $buildTime[$bn] = 1 }
                }
            }
            elseif ($arg0 -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $skeleton = $arg0.Value
            }
            $assigned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $readsByWhere = [ordered]@{}
            if ($skeleton -ne '') {
                $skUse = Get-JcScriptVarUse -Ast (Get-JcAstFromText -Text $skeleton)
                foreach ($n in $skUse.Assigns) { [void]$assigned.Add($n) }
                $jobReads = New-Object 'System.Collections.Generic.List[string]'
                foreach ($n in $skUse.Reads) {
                    if ($buildTime.ContainsKey($n) -and $buildTime[$n] -gt 0) { $buildTime[$n]--; continue }
                    $jobReads.Add($n)
                }
                $readsByWhere['<job>'] = @($jobReads)
            }
            foreach ($e in $embedded) {
                if (-not $svUse.ContainsKey($e)) { continue }
                foreach ($n in $svUse[$e].Assigns) { [void]$assigned.Add($n) }
                $readsByWhere[$e] = @($svUse[$e].Reads)
            }
            [string[]] $scriptVars = @(Get-JcUnassignedScriptVars -ReadsByWhere $readsByWhere -Assigned $assigned)

            $siteResults += ,([PSCustomObject]@{
                Enclosing  = (Get-JcEnclosingFunctionName -Node $cr)
                File       = $f.Name
                Line       = $cr.Extent.StartLineNumber
                Kind       = 'HereString'
                Embedded   = $embedded
                Missing    = @($missing)
                ScriptVars = @($scriptVars)
                Dynamic    = $siteDyn
            })
        }

        # -- 3b: inline { } scriptblock -> Start-Job / Invoke-AsyncToolkitJob --
        [object[]] $jobCmds = @($ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.CommandAst] -and
            @('Start-Job', 'Invoke-AsyncToolkitJob') -contains $a.GetCommandName()
        }, $true))
        foreach ($jc in $jobCmds) {
            [object[]] $sbs = @($jc.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] })
            if ($sbs.Count -eq 0) { continue }   # -ScriptBlock $var: the here-string pass covers it
            [System.Management.Automation.Language.ScriptBlockAst] $blk = $sbs[0].ScriptBlock

            [bool] $siteDyn = $false
            $embSet = New-Object 'System.Collections.Generic.HashSet[string]'
            $assigned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $readsByWhere = [ordered]@{}

            # functions defined in the block itself
            foreach ($bf in @($blk.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
                [void]$embSet.Add($bf.Name)
            }

            # dot-sourced module: resolve to the enclosing file via the
            # `$script:<V> = $PSCommandPath` + enclosing-function-reads-$script:<V> pattern
            [object[]] $dots = @($blk.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.CommandAst] -and
                $a.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
            }, $true))
            [string] $dotFile = ''
            if ($dots.Count -gt 0) {
                $pathVars = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($as in @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
                    if (Test-JcAstIsNested -Node $as) { continue }
                    [System.Management.Automation.Language.Ast] $lhs = $as.Left
                    if ($lhs -is [System.Management.Automation.Language.ConvertExpressionAst]) { $lhs = $lhs.Child }
                    if (-not ($lhs -is [System.Management.Automation.Language.VariableExpressionAst] -and $lhs.VariablePath.IsScript)) { continue }
                    [bool] $isCmdPath = @($as.Right.FindAll({
                        param($a)
                        $a -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $a.VariablePath.UserPath -eq 'PSCommandPath'
                    }, $true)).Count -gt 0
                    if ($isCmdPath) { [void]$pathVars.Add((Get-JcScriptVarName -Var $lhs)) }
                }
                $encFn = Get-JcEnclosingFunctionAst -Node $jc
                [bool] $resolved = $false
                if ($null -ne $encFn -and $pathVars.Count -gt 0) {
                    foreach ($n in (Get-JcScriptVarUse -Ast $encFn.Body).Reads) {
                        if ($pathVars.Contains($n)) { $resolved = $true }
                    }
                }
                if ($dots.Count -eq 1 -and $resolved) {
                    $dotFile = $f.FullName
                    foreach ($fnName in @($fileFuncs[$f.FullName])) { [void]$embSet.Add($fnName) }
                    $fileUse = Get-JcScriptVarUse -Ast $ast -FileLevelOnly
                    foreach ($n in $fileUse.Assigns) { [void]$assigned.Add($n) }
                }
                else {
                    $siteDyn = $true   # dot-source we can't resolve: never green in silence
                }
            }

            # roots = commands the block calls (dynamic calls in the block -> WARN)
            $rootSet = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($c in @($blk.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                if ($c.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) { continue }
                [string] $cn = $c.GetCommandName()
                if ([string]::IsNullOrEmpty($cn)) { $siteDyn = $true; continue }
                if ($repoNames.Contains($cn)) { [void]$rootSet.Add($cn) }
            }
            [string[]] $roots = @($rootSet)
            $closure = Get-JcTransitiveClosure -Roots $roots -Graph $graph

            [string[]] $missing = @()
            if (-not $siteDyn) {
                foreach ($cn in $closure) {
                    if ($repoNames.Contains($cn) -and -not $embSet.Contains($cn)) { $missing += $cn }
                }
            }
            foreach ($cn in $closure) {
                if ($embSet.Contains($cn) -and $dynamic.ContainsKey($cn) -and $dynamic[$cn]) { $siteDyn = $true }
            }

            # $script: -- block text + bodies of the embedded functions the job reaches
            $blkUse = Get-JcScriptVarUse -Ast $blk
            foreach ($n in $blkUse.Assigns) { [void]$assigned.Add($n) }
            $readsByWhere['<job>'] = @($blkUse.Reads)
            foreach ($cn in @($closure | Sort-Object)) {
                if (-not $embSet.Contains($cn) -or -not $svUse.ContainsKey($cn)) { continue }
                foreach ($n in $svUse[$cn].Assigns) { [void]$assigned.Add($n) }
                $readsByWhere[$cn] = @($svUse[$cn].Reads)
            }
            [string[]] $scriptVars = @(Get-JcUnassignedScriptVars -ReadsByWhere $readsByWhere -Assigned $assigned)

            [string[]] $embList = @($embSet | Where-Object { $closure.Contains($_) -or -not $repoNames.Contains($_) } | Sort-Object)
            $siteResults += ,([PSCustomObject]@{
                Enclosing  = (Get-JcEnclosingFunctionName -Node $jc)
                File       = $f.Name
                Line       = $jc.Extent.StartLineNumber
                Kind       = $(if ($dotFile -ne '') { 'Inline+dot' } else { 'Inline' })
                Embedded   = $embList
                Missing    = @($missing)
                ScriptVars = @($scriptVars)
                Dynamic    = $siteDyn
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
    if ($args.Count -ge 2 -and $args[0] -eq '-RepoRoot') { $root = [string]$args[1] }
    $rep = Get-JobClosureReport -RepoRoot $root

    [int] $failCount = 0
    [int] $warnCount = 0
    Write-Host ''
    Write-Host '=== Job-serialization closure net (#26-A1 + $script:) ===' -ForegroundColor Cyan
    Write-Host ("Repo: {0}" -f $root)
    Write-Host ("Repo funcs: {0}   Job sites: {1}" -f $rep.RepoFuncCount, @($rep.Sites).Count)
    Write-Host ''

    foreach ($s in @($rep.Sites)) {
        [string] $label = ('{0}  [{1}:{2}] {3}' -f $s.Enclosing, $s.File, $s.Line, $s.Kind)
        [bool] $miss = @($s.Missing).Count -gt 0
        [bool] $sv = @($s.ScriptVars).Count -gt 0
        if ($miss -or $sv) {
            $failCount++
            Write-Host ("  [FAIL] {0}" -f $label) -ForegroundColor Red
            Write-Host ("         embebidas: {0}" -f (@($s.Embedded) -join ', '))
            if ($miss) {
                Write-Host ("         FALTAN en el job (CommandNotFound latente): {0}" -f (@($s.Missing) -join ', ')) -ForegroundColor Red
            }
            if ($sv) {
                Write-Host '         $script: leido en el job y NO asignado en el job ($null / VariableIsUndefined):' -ForegroundColor Red
                foreach ($x in @($s.ScriptVars)) { Write-Host ("           {0}" -f $x) -ForegroundColor Red }
            }
        }
        elseif ($s.Dynamic) {
            $warnCount++
            Write-Host ("  [WARN] {0}" -f $label) -ForegroundColor Yellow
            Write-Host '         cierre estatico COMPLETO, pero usa dispatch dinamico (& $var / IEX) o un dot-source no resuelto'
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
        Write-Host 'CIERRE INCOMPLETO: hay sitios que romperian en el job (CommandNotFound o $script: sin resolver).' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Todos los sitios de job tienen el cierre transitivo completo y sin $script: sin resolver.' -ForegroundColor Green
    exit 0
}
