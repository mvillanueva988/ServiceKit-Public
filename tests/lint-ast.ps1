# =============================================================================
# lint-ast.ps1  -  Lints por AST sobre TODO el codigo de producto (P2a).
#
# POR QUE EXISTE
#   Dos clases de bug llegaron a Mateo siendo cazables con un lint:
#
#   E21 (#80) ARCHIVE  Expand-Archive / Compress-Archive viven en el modulo
#       Microsoft.PowerShell.Archive, que puede NO cargar en un Windows degradado
#       y en la Sandbox. El [T] revento asi en el gate v2.10.0. El guard que habia
#       estaba atado a UNA funcion (Invoke-ExportClientLogs): Bootstrap-Tools y
#       Launch seguian usando Expand-Archive y el guard quedaba verde. Este lint le
#       pregunta a la CARPETA, no a una funcion: cualquier .ps1 de producto.
#
#   E16 UNROLL  PS5.1 desenrolla la salida de un pipeline / $(...) / if-expresion:
#       con 1 elemento queda un escalar, con 0 queda $null. Bajo
#       Set-StrictMode -Version Latest, `.Count` sobre un escalar (string, int,
#       PSCustomObject) o sobre $null tira PropertyNotFoundStrict. Medido en
#       5.1: un tipo [object[]] en la variable salva el caso de 1 elemento pero
#       NO el de 0 ($null queda $null). La unica forma segura es `@(...)`.
#       Historicos de esta clase: a0ec87b, 7e33ae6, f762458 (fixtures abajo en el
#       smoke), 86aae18 (return sin coma), 1673e73 (Measure-Object vacio).
#
# REGLAS (AST, nunca regex sobre texto: los comentarios que describen la
# trampa no cuentan)
#   ARCHIVE  todo CommandAst cuyo nombre sea Compress-Archive o Expand-Archive
#            (tambien calificado con el modulo). Sin allowlist.
#   R1  unroll-count  `$v = <rhs desenrollable>` SIN @() (con o sin tipo en la
#            variable) y despues `$v.Count` en la MISMA funcion. rhs desenrollable
#            = pipeline de 2+ etapas, un comando suelto, $( ... ), ( pipeline ),
#            o un if/switch/foreach/for/while/do/try usado como expresion.
#   R2  array-en-if-expresion  un if/switch usado como expresion (lado derecho de
#            una asignacion o dentro de $( ... )) cuya rama termina en `@(...)`:
#            el autor queria un array y PowerShell se lo desenrolla igual. Es la
#            forma exacta de 7e33ae6 y f762458. Salvo que lo envuelva un @() o una
#            coma unaria.
#
# PUNTOS CIEGOS (declarados)
#   - R1 no sigue datos entre funciones: el `.Count` del caller sobre un return
#     desenrollado (86aae18) no lo ve. Tampoco ve .Count sobre una propiedad
#     ($obj.Lista.Count) ni el $null de Measure-Object (1673e73).
#   - R1 marca `$x = Get-Repo` aunque Get-Repo devuelva `,$array`: va al allowlist
#     con la razon.
#
# API
#   Get-LintProductFiles  -RepoRoot <path>          -> [string[]] rutas .ps1
#   Find-LintArchiveHits  -Ast <Ast> -File <label>  -> hits
#   Find-LintUnrollHits   -Ast <Ast> -File <label>  -> hits (R1 + R2)
#   Get-LintAstFromText   -Text <string>            -> Ast (para fixtures)
#   Get-LintAstReport     -RepoRoot <path>          -> .Files .ArchiveHits
#                                                      .UnrollHits .UnrollAllowed
#   Dot-source sin efectos. Corrido directo (powershell -File) imprime el reporte
#   y sale con exit 0/1.
# =============================================================================

# Allowlist de R1/R2: clave '<ruta relativa>|<funcion>|<variable o R2>' -> razon.
# Por funcion+variable y no por linea: los numeros de linea se pudren.
$script:LintUnrollAllowlist = @{
    # `if ($rv -is [array]) { $rv = if ($rv.Count -gt 0) { $rv[0] } else { $null } }`:
    # reduccion INTENCIONAL a escalar; el .Count se lee solo bajo `-is [array]`.
    'modules\Network.ps1|Get-NetworkDiagnostics|rv' = 'reduccion intencional a escalar; .Count solo bajo -is [array]'
}

# Freno: si R1/R2 marcan mas sitios de producto que esto, el lint queda en modo
# REPORTE (no falla) y la decision de arreglarlos es del orquestador.
$script:LintUnrollEnforce = $true

function Get-LintAstFromFile {
    param([string] $Path)
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $perrors = $null
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perrors)
}

function Get-LintAstFromText {
    param([string] $Text)
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $perrors = $null
    return [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$perrors)
}

function Get-LintProductFiles {
    # Todo .ps1 del repo menos tests/, _local-dev/ y .claude/ (y .git/). Barre el
    # arbol entero en vez de una lista de carpetas: una carpeta nueva queda
    # cubierta sola, el guard no se vacia cuando el codigo se muda.
    param([string] $RepoRoot)
    [string] $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
    [string[]] $excluded = @('tests', '_local-dev', '.claude', '.git')
    [System.Collections.Generic.List[string]] $out = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)) {
        [string] $rel = $f.FullName.Substring($root.Length + 1)
        [string] $top = ($rel -split '\\')[0]
        if ($rel.Contains('\') -and ($excluded -contains $top)) { continue }
        $out.Add($f.FullName)
    }
    return ($out.ToArray() | Sort-Object)
}

function Get-LintEnclosingFunction {
    param([System.Management.Automation.Language.Ast] $Node)
    [System.Management.Automation.Language.Ast] $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
        $p = $p.Parent
    }
    return $null
}

function Get-LintFunctionLabel {
    param([System.Management.Automation.Language.Ast] $Node)
    $fn = Get-LintEnclosingFunction -Node $Node
    if ($null -eq $fn) { return '<top-level>' }
    return $fn.Name
}

function Get-LintVarName {
    param([System.Management.Automation.Language.VariableExpressionAst] $Var)
    [string] $n = $Var.VariablePath.UserPath.ToLowerInvariant()
    if ($n.StartsWith('local:')) { $n = $n.Substring(6) }
    return $n
}

function Find-LintArchiveHits {
    param([System.Management.Automation.Language.Ast] $Ast, [string] $File)
    [System.Collections.Generic.List[PSCustomObject]] $hits = [System.Collections.Generic.List[PSCustomObject]]::new()
    $cmds = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in @($cmds)) {
        [string] $name = $c.GetCommandName()
        if ([string]::IsNullOrEmpty($name)) { continue }
        [string] $short = ($name -split '\\')[-1]
        if ($short -eq 'Expand-Archive' -or $short -eq 'Compress-Archive') {
            $hits.Add([PSCustomObject]@{
                File     = $File
                Line     = $c.Extent.StartLineNumber
                Function = (Get-LintFunctionLabel -Node $c)
                Command  = $short
                Text     = $c.Extent.Text.Split("`n")[0].Trim()
            })
        }
    }
    return $hits.ToArray()
}

function Get-LintUnrollKind {
    # $null si el statement NO desenrolla; si desenrolla, el tipo ('pipeline',
    # 'command', 'subexpr', 'paren', 'if', ...). @(...) y la coma unaria salvan.
    param([System.Management.Automation.Language.Ast] $Stmt, [hashtable] $SafeFunctions = @{})
    if ($Stmt -is [System.Management.Automation.Language.IfStatementAst])      { return 'if' }
    if ($Stmt -is [System.Management.Automation.Language.SwitchStatementAst])  { return 'switch' }
    if ($Stmt -is [System.Management.Automation.Language.ForEachStatementAst]) { return 'foreach' }
    if ($Stmt -is [System.Management.Automation.Language.ForStatementAst])     { return 'for' }
    if ($Stmt -is [System.Management.Automation.Language.WhileStatementAst])   { return 'while' }
    if ($Stmt -is [System.Management.Automation.Language.DoWhileStatementAst]) { return 'do' }
    if ($Stmt -is [System.Management.Automation.Language.DoUntilStatementAst]) { return 'do' }
    if ($Stmt -is [System.Management.Automation.Language.TryStatementAst])     { return 'try' }
    if ($Stmt -is [System.Management.Automation.Language.PipelineAst]) {
        $els = $Stmt.PipelineElements
        if ($els.Count -gt 1) { return 'pipeline' }
        if ($els.Count -eq 0) { return $null }
        $e = $els[0]
        if ($e -is [System.Management.Automation.Language.CommandAst]) {
            [string] $cn = $e.GetCommandName()
            if (-not [string]::IsNullOrEmpty($cn) -and $SafeFunctions.ContainsKey($cn.ToLowerInvariant())) { return $null }
            return 'command'
        }
        if ($e -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $x = $e.Expression
            if ($x -is [System.Management.Automation.Language.SubExpressionAst]) { return 'subexpr' }
            if ($x -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $inner = Get-LintUnrollKind -Stmt $x.Pipeline -SafeFunctions $SafeFunctions
                if ($null -ne $inner) { return 'paren' }
            }
        }
    }
    return $null
}

function Get-LintCollectionSafeFunctions {
    # Funciones del repo cuyo resultado NO se desenrolla al asignarlo: TODOS sus
    # `return` son `,expr` (coma unaria, el idiom de 86aae18) o devuelven una
    # variable [hashtable] (el pipeline no enumera un hashtable). Sin esto R1
    # marcaria cada `$r = Wait-ToolkitJobs ...`, que es seguro.
    # Devuelve un hashtable nombre-en-minusculas -> $true.
    param([System.Management.Automation.Language.Ast[]] $Asts)
    $safe = @{}
    foreach ($ast in $Asts) {
        $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($fn in @($fns)) {
            $hashVars = @{}
            $typed = $fn.Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $n.Child -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.Type.TypeName.Name -match '^(System\.Collections\.)?hashtable$'
            }, $true)
            foreach ($t in @($typed)) { $hashVars[(Get-LintVarName -Var $t.Child)] = $true }

            $rets = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true) |
                Where-Object { [object]::ReferenceEquals((Get-LintEnclosingFunction -Node $_), $fn) })
            if ($rets.Count -eq 0) { continue }
            [bool] $allSafe = $true
            foreach ($r in $rets) {
                [bool] $ok = $false
                $pl = $r.Pipeline
                if ($pl -is [System.Management.Automation.Language.PipelineAst] -and $pl.PipelineElements.Count -eq 1 -and
                    $pl.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $x = $pl.PipelineElements[0].Expression
                    if (Test-LintIsUnaryComma -Node $x) { $ok = $true }
                    elseif ($x -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $hashVars.ContainsKey((Get-LintVarName -Var $x))) { $ok = $true }
                }
                if (-not $ok) { $allSafe = $false; break }
            }
            if ($allSafe) { $safe[$fn.Name.ToLowerInvariant()] = $true }
        }
    }
    return $safe
}

function Test-LintIsUnaryComma {
    # `,expr` (coma unaria): el parser lo arma como ArrayLiteralAst de UN elemento.
    param([System.Management.Automation.Language.Ast] $Node)
    return ($Node -is [System.Management.Automation.Language.ArrayLiteralAst] -and $Node.Elements.Count -eq 1)
}

function Test-LintIsArrayWrapped {
    # $true si subiendo desde $Node (sin cruzar un limite de statement real)
    # aparece un @( ... ) o una coma unaria que preserva el array.
    param([System.Management.Automation.Language.Ast] $Node)
    [System.Management.Automation.Language.Ast] $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.ArrayExpressionAst]) { return $true }
        if (Test-LintIsUnaryComma -Node $p) { return $true }
        if ($p -is [System.Management.Automation.Language.SubExpressionAst] -or
            $p -is [System.Management.Automation.Language.ParenExpressionAst] -or
            $p -is [System.Management.Automation.Language.CommandExpressionAst] -or
            $p -is [System.Management.Automation.Language.StatementBlockAst] -or
            ($p -is [System.Management.Automation.Language.PipelineAst] -and $p.PipelineElements.Count -eq 1)) {
            $p = $p.Parent
            continue
        }
        return $false
    }
    return $false
}

function Test-LintIsExpressionPosition {
    # if/switch usado como VALOR: lado derecho de una asignacion, o adentro de
    # $( ... ) / ( ... ). Un if suelto en un bloque es un statement normal.
    param([System.Management.Automation.Language.Ast] $Stmt)
    $p = $Stmt.Parent
    if ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($p.Right, $Stmt)) { return $true }
    if ($p -is [System.Management.Automation.Language.StatementBlockAst] -and
        $p.Parent -is [System.Management.Automation.Language.SubExpressionAst]) { return $true }
    return $false
}

function Get-LintBranchBodies {
    param([System.Management.Automation.Language.Ast] $Stmt)
    [System.Collections.Generic.List[object]] $bodies = [System.Collections.Generic.List[object]]::new()
    if ($Stmt -is [System.Management.Automation.Language.IfStatementAst]) {
        foreach ($cl in $Stmt.Clauses) { $bodies.Add($cl.Item2) }
        if ($null -ne $Stmt.ElseClause) { $bodies.Add($Stmt.ElseClause) }
    }
    elseif ($Stmt -is [System.Management.Automation.Language.SwitchStatementAst]) {
        foreach ($cl in $Stmt.Clauses) { $bodies.Add($cl.Item2) }
        if ($null -ne $Stmt.Default) { $bodies.Add($Stmt.Default) }
    }
    return $bodies.ToArray()
}

function Test-LintBodyEndsInArrayExpr {
    param([System.Management.Automation.Language.StatementBlockAst] $Body)
    $stmts = $Body.Statements
    if ($null -eq $stmts -or $stmts.Count -eq 0) { return $false }
    $last = $stmts[$stmts.Count - 1]
    if ($last -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    if ($last.PipelineElements.Count -ne 1) { return $false }
    $e = $last.PipelineElements[0]
    if ($e -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $false }
    return ($e.Expression -is [System.Management.Automation.Language.ArrayExpressionAst])
}

function Find-LintUnrollHits {
    # -SafeFunctions: salida de Get-LintCollectionSafeFunctions sobre el repo
    # entero (un `$x = Get-Repo` cuya funcion devuelve `,$arr` no desenrolla).
    param([System.Management.Automation.Language.Ast] $Ast, [string] $File, [hashtable] $SafeFunctions = @{})
    [System.Collections.Generic.List[PSCustomObject]] $hits = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- R1: asignacion desenrollable + .Count en la misma funcion ---------
    # Indice de lecturas .Count por (funcion, variable).
    $countReads = @{}
    $members = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq 'Count'
    }, $true)
    foreach ($m in @($members)) {
        $fn = Get-LintEnclosingFunction -Node $m
        [string] $fkey = if ($null -eq $fn) { '<top>' } else { [string] $fn.Extent.StartOffset }
        [string] $k = $fkey + '|' + (Get-LintVarName -Var $m.Expression)
        $countReads[$k] = $true
    }

    $asgs = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals
    }, $true)
    foreach ($a in @($asgs)) {
        $left = $a.Left
        # [tipo] $v = ... : desarmar el cast para llegar a la variable. El tipo NO
        # exime (un [object[]] con 0 elementos queda $null), salvo que no sea
        # una coleccion: [string]/[int]/... no son el patron.
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            $tn = $left.Type.TypeName
            if (-not $tn.IsArray -and $tn.Name -notmatch '^(System\.)?(array|object\[\])$') { continue }
            $left = $left.Child
        }
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        [string] $kind = Get-LintUnrollKind -Stmt $a.Right -SafeFunctions $SafeFunctions
        if ([string]::IsNullOrEmpty($kind)) { continue }
        $fn = Get-LintEnclosingFunction -Node $a
        [string] $fkey = if ($null -eq $fn) { '<top>' } else { [string] $fn.Extent.StartOffset }
        [string] $var = Get-LintVarName -Var $left
        if (-not $countReads.ContainsKey($fkey + '|' + $var)) { continue }
        $hits.Add([PSCustomObject]@{
            Rule     = 'R1'
            File     = $File
            Line     = $a.Extent.StartLineNumber
            Function = (Get-LintFunctionLabel -Node $a)
            Variable = $var
            Kind     = $kind
            Key      = ('{0}|{1}|{2}' -f $File, (Get-LintFunctionLabel -Node $a), $var)
            Text     = $a.Extent.Text.Split("`n")[0].Trim()
        })
    }

    # --- R2: @() como salida de una rama de if/switch-expresion ------------
    $conds = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -or
        $n -is [System.Management.Automation.Language.SwitchStatementAst]
    }, $true)
    foreach ($s in @($conds)) {
        if (-not (Test-LintIsExpressionPosition -Stmt $s)) { continue }
        [bool] $hasArrayBranch = $false
        foreach ($b in @(Get-LintBranchBodies -Stmt $s)) {
            if (Test-LintBodyEndsInArrayExpr -Body $b) { $hasArrayBranch = $true; break }
        }
        if (-not $hasArrayBranch) { continue }
        # $( if ... ) envuelto en @( ) o con coma unaria: esta salvado.
        $anchor = $s
        if ($s.Parent -is [System.Management.Automation.Language.StatementBlockAst]) { $anchor = $s.Parent }
        if (Test-LintIsArrayWrapped -Node $anchor) { continue }
        [string] $fnLabel = Get-LintFunctionLabel -Node $s
        $hits.Add([PSCustomObject]@{
            Rule     = 'R2'
            File     = $File
            Line     = $s.Extent.StartLineNumber
            Function = $fnLabel
            Variable = ''
            Kind     = 'array-in-if-expr'
            Key      = ('{0}|{1}|R2' -f $File, $fnLabel)
            Text     = $s.Extent.Text.Split("`n")[0].Trim()
        })
    }

    return $hits.ToArray()
}

function Get-LintAstReport {
    param([string] $RepoRoot)
    [string] $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
    [System.Collections.Generic.List[PSCustomObject]] $arch    = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $unroll  = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $allowed = [System.Collections.Generic.List[PSCustomObject]]::new()
    [string[]] $files = @(Get-LintProductFiles -RepoRoot $root)
    $asts = @{}
    foreach ($f in $files) { $asts[$f] = Get-LintAstFromFile -Path $f }
    [hashtable] $safe = Get-LintCollectionSafeFunctions -Asts @($asts.Values)
    foreach ($f in $files) {
        [string] $rel = $f.Substring($root.Length + 1)
        $ast = $asts[$f]
        foreach ($h in @(Find-LintArchiveHits -Ast $ast -File $rel)) { $arch.Add($h) }
        foreach ($h in @(Find-LintUnrollHits -Ast $ast -File $rel -SafeFunctions $safe)) {
            if ($script:LintUnrollAllowlist.ContainsKey($h.Key)) {
                $h | Add-Member -NotePropertyName Reason -NotePropertyValue $script:LintUnrollAllowlist[$h.Key]
                $allowed.Add($h)
            }
            else { $unroll.Add($h) }
        }
    }
    return [PSCustomObject]@{
        Files         = $files
        ArchiveHits   = $arch.ToArray()
        UnrollHits    = $unroll.ToArray()
        UnrollAllowed = $allowed.ToArray()
        UnrollEnforce = [bool] $script:LintUnrollEnforce
        SafeFunctions = @($safe.Keys | Sort-Object)
    }
}

# ---- entrada directa (se saltea al dot-sourcear) -----------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    [string] $root = Split-Path -Parent $PSScriptRoot
    $rep = Get-LintAstReport -RepoRoot $root

    [int] $failCount = 0
    Write-Host ''
    Write-Host '=== Lints AST de producto (P2a) ===' -ForegroundColor Cyan
    Write-Host ('Archivos .ps1 de producto: {0}' -f @($rep.Files).Count)
    Write-Host ('Funciones que no desenrollan (return ,x / hashtable): {0}' -f (@($rep.SafeFunctions) -join ', '))
    Write-Host ''
    Write-Host '-- ARCHIVE (Expand-Archive / Compress-Archive: modulo que puede no cargar) --'
    foreach ($h in @($rep.ArchiveHits)) {
        $failCount++
        Write-Host ('  [FAIL] {0}:{1}  {2}  en {3}' -f $h.File, $h.Line, $h.Command, $h.Function) -ForegroundColor Red
    }
    if (@($rep.ArchiveHits).Count -eq 0) { Write-Host '  [OK]   ningun *-Archive' -ForegroundColor Green }

    Write-Host ''
    [string] $mode = if ($rep.UnrollEnforce) { 'FAIL' } else { 'REPORTE' }
    Write-Host ('-- UNROLL (E16: desenrollado + .Count bajo StrictMode)  modo {0} --' -f $mode)
    foreach ($h in @($rep.UnrollHits)) {
        if ($rep.UnrollEnforce) { $failCount++ }
        Write-Host ('  [{0}] {1}:{2}  {3} {4} ${5}  en {6}' -f $(if ($rep.UnrollEnforce) { 'FAIL' } else { 'WARN' }), $h.File, $h.Line, $h.Rule, $h.Kind, $h.Variable, $h.Function) -ForegroundColor $(if ($rep.UnrollEnforce) { 'Red' } else { 'Yellow' })
        Write-Host ('         {0}' -f $h.Text)
    }
    foreach ($h in @($rep.UnrollAllowed)) {
        Write-Host ('  [ALLOW] {0}:{1}  {2} ${3}  -> {4}' -f $h.File, $h.Line, $h.Rule, $h.Variable, $h.Reason) -ForegroundColor DarkGray
    }
    if (@($rep.UnrollHits).Count -eq 0) { Write-Host '  [OK]   ningun desenrollado sin @()' -ForegroundColor Green }

    Write-Host ''
    Write-Host ('Resultado: {0} FAIL  (archive {1}, unroll {2}, allowlist {3})' -f `
        $failCount, @($rep.ArchiveHits).Count, @($rep.UnrollHits).Count, @($rep.UnrollAllowed).Count)
    if ($failCount -gt 0) { exit 1 }
    exit 0
}
