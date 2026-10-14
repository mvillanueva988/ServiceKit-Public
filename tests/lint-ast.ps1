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
#   APPX  (#83) todo Add-/Remove-AppxPackage / -AppxProvisionedPackage corre con
#            $ProgressPreference = 'SilentlyContinue' asignado LOCAL en la misma
#            funcion y antes del comando: si no, el progreso de deployment de
#            AppX queda pintado encima del menu. $global:/$script: no cuentan
#            (apagan el progreso del resto del toolkit).
#   R1  unroll-count  `$v = <rhs desenrollable>` SIN @() (con o sin tipo en la
#            variable) y despues `$v.Count` en la MISMA funcion. rhs desenrollable
#            = pipeline de 2+ etapas, un comando suelto, $( ... ), ( pipeline ),
#            o un if/switch/foreach/for/while/do/try usado como expresion.
#   R2  array-en-if-expresion  un if/switch usado como expresion (lado derecho de
#            una asignacion o dentro de $( ... )) cuya rama termina en `@(...)`:
#            el autor queria un array y PowerShell se lo desenrolla igual. Es la
#            forma exacta de 7e33ae6 y f762458. Salvo que lo envuelva un @() o una
#            coma unaria.
#   GLYPH  (U1, #95) todo literal de string (StringConstant / ExpandableString,
#            here-strings incluidos) de producto tiene que codificar EXACTO en la
#            code page OEM 850 (sin best-fit: U+2014 -> `-` cuenta como falla). Los
#            literales que NO van a consola (HTML del informe, archivo del prompt,
#            .wslconfig) van al allowlist por archivo+funcion con la razon. Por que
#            CP850 y no "lo que muestre Consolas": ver $script:LintGlyphCodePage.
#
# PUNTOS CIEGOS (declarados)
#   - R1 no sigue datos entre funciones: el `.Count` del caller sobre un return
#     desenrollado (86aae18) no lo ve. Tampoco ve .Count sobre una propiedad
#     ($obj.Lista.Count) ni el $null de Measure-Object (1673e73).
#   - R1 marca `$x = Get-Repo` aunque Get-Repo devuelva `,$array`: va al allowlist
#     con la razon.
#   - GLYPH mira literales: un caracter armado en runtime ([char]0x2501, datos de
#     data\*.json, texto que devuelve el sistema) no lo ve. Hoy el producto no
#     arma ninguno fuera de [char]27 (ESC de VT).
#
# API
#   Get-LintProductFiles  -RepoRoot <path>          -> [string[]] rutas .ps1
#   Find-LintArchiveHits  -Ast <Ast> -File <label>  -> hits
#   Find-LintAppxSites    -Ast <Ast> -File <label>  -> sitios APPX (con .Ok)
#   Find-LintUnrollHits   -Ast <Ast> -File <label>  -> hits (R1 + R2)
#   Get-LintAstFromText   -Text <string>            -> Ast (para fixtures)
#   Find-LintGlyphHits    -Ast <Ast> -File <label>  -> hits (con .Key file|funcion)
#   Get-LintAstReport     -RepoRoot <path>          -> .Files .ArchiveHits
#                                                      .AppxSites .AppxHits
#                                                      .UnrollHits .UnrollAllowed
#                                                      .GlyphHits .GlyphAllowed
#                                                      .GlyphStale .GlyphStrings
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

# GLYPH: conjunto permitido = lo que codifica en la code page OEM 850 (U1, #95).
# Por que esa y no "lo que dibuja la fuente":
#   - conhost en es-AR arranca con OEM 850. Con fuente raster (la "Terminal" que
#     queda en consolas viejas o configuradas a mano) el glifo SALE de la code
#     page: lo que no esta en 850 se ve como '?' o un cuadrado.
#   - Consolas / Lucida Console cubren 850 entero, pero no todo Unicode: Lucida
#     no trae los box-drawing gruesos (U+2501), y del lado de AnyDesk el
#     operador no controla la fuente del cliente.
#   - con la salida redirigida (gate de release, `> archivo`, pipe) PowerShell
#     codifica con [Console]::OutputEncoding = 850: lo de afuera se vuelve '?'.
# 850 es la interseccion segura de los tres casos y ya trae lo que la UI usa:
# tildes/enie, box-drawing finos y dobles (U+2500 U+2502 U+250C U+2550 U+2551
# U+2554), sombreados y bloque (U+2591-U+2593, U+2588). Los controles (`t `n `r,
# ESC de VT) codifican en 850 y pasan. Exacto (ExceptionFallback): el best-fit de
# .NET mapea U+2014 a `-` y un round-trip "tolerante" lo dejaria pasar.
# (Este archivo queda 100% ASCII a proposito: por eso los glifos van como U+.)
$script:LintGlyphCodePage = 850

# Allowlist GLYPH: '<ruta relativa>|<funcion o <top-level>>' -> razon. Solo para
# literales que NO van a la consola. Por funcion, no por linea (se pudren). Una
# entrada que ya no matchea nada es falla (GlyphStale): el allowlist no se pudre.
$script:LintGlyphAllowlist = @{
    'modules\ClientReport.ps1|New-ClientReport'     = 'HTML del informe al cliente (UTF-8, lo abre el navegador); no va a consola'
    'modules\ResearchPrompt.ps1|<top-level>'        = 'texto del prompt para el LLM: va a archivo UTF-8 + clipboard, no a consola'
    'modules\ResearchPrompt.ps1|New-ResearchPrompt' = 'texto del prompt para el LLM: va a archivo UTF-8 + clipboard, no a consola'
    'modules\Wsl.ps1|New-WslConfig'                 = 'contenido de .wslconfig: va a archivo UTF-8, no a consola'
}

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

function Find-LintAppxSites {
    # APPX (#83): cada Add-/Remove-AppxPackage / -AppxProvisionedPackage, con Ok =
    # la MISMA funcion asigna $ProgressPreference = 'SilentlyContinue' LOCAL (sin
    # $global:/$script:) ANTES del comando. Devuelve TODOS los sitios (no solo los
    # malos) para que el smoke pueda exigir que el barrido no este vacio.
    param([System.Management.Automation.Language.Ast] $Ast, [string] $File)
    [System.Collections.Generic.List[PSCustomObject]] $sites = [System.Collections.Generic.List[PSCustomObject]]::new()
    $cmds = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in @($cmds)) {
        [string] $name = $c.GetCommandName()
        if ([string]::IsNullOrEmpty($name)) { continue }
        [string] $short = ($name -split '\\')[-1]
        if ($short -notmatch '^(Add|Remove)-Appx(Provisioned)?Package$') { continue }
        $fn = Get-LintEnclosingFunction -Node $c
        [System.Management.Automation.Language.Ast] $owner = $Ast
        if ($null -ne $fn) { $owner = $fn }
        [bool] $ok = $false
        $asgs = $owner.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
        foreach ($a in @($asgs)) {
            if ($a.Extent.StartOffset -ge $c.Extent.StartOffset) { continue }
            if (-not ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
            if ((Get-LintVarName -Var $a.Left) -ne 'progresspreference') { continue }
            if ($a.Right.Extent.Text -notmatch 'SilentlyContinue') { continue }
            # una asignacion dentro de una funcion anidada no cubre al comando
            $afn = Get-LintEnclosingFunction -Node $a
            if (-not [object]::ReferenceEquals($afn, $fn)) { continue }
            $ok = $true
            break
        }
        $sites.Add([PSCustomObject]@{
            File     = $File
            Line     = $c.Extent.StartLineNumber
            Function = (Get-LintFunctionLabel -Node $c)
            Command  = $short
            Ok       = $ok
        })
    }
    return $sites.ToArray()
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

function Get-LintGlyphEncoding {
    return [System.Text.Encoding]::GetEncoding($script:LintGlyphCodePage,
        [System.Text.EncoderFallback]::ExceptionFallback,
        [System.Text.DecoderFallback]::ExceptionFallback)
}

function Get-LintGlyphBadChars {
    # Caracteres de $Text que NO codifican en la code page del lint. Por char,
    # para poder nombrar cada uno en el hit. Un surrogate suelto (emoji, fuera
    # del BMP) tambien falla al codificar: queda marcado.
    param([string] $Text, [System.Text.Encoding] $Encoding)
    [System.Collections.Generic.List[string]] $bad = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -lt 128) { continue }
        try { [void] $Encoding.GetBytes([string]$ch) }
        catch {
            [string] $code = 'U+{0:X4}' -f [int]$ch
            if (-not $bad.Contains($code)) { $bad.Add($code) }
        }
    }
    return $bad.ToArray()
}

function Find-LintGlyphHits {
    # GLYPH: literales de string (constantes y expandibles, here-strings
    # incluidos) con caracteres fuera de la code page. Por AST: los comentarios
    # no son nodos de string y no cuentan.
    param([System.Management.Automation.Language.Ast] $Ast, [string] $File)
    [System.Collections.Generic.List[PSCustomObject]] $hits = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Text.Encoding] $enc = Get-LintGlyphEncoding
    $nodes = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
    foreach ($n in @($nodes)) {
        [string[]] $bad = @(Get-LintGlyphBadChars -Text ([string]$n.Value) -Encoding $enc)
        if ($bad.Count -eq 0) { continue }
        [string] $fn = Get-LintFunctionLabel -Node $n
        [string] $first = ([string]$n.Value).Split("`n")[0].Trim()
        $hits.Add([PSCustomObject]@{
            File     = $File
            Line     = $n.Extent.StartLineNumber
            Function = $fn
            Chars    = ($bad -join ',')
            Key      = ('{0}|{1}' -f $File, $fn)
            Text     = $first
        })
    }
    return $hits.ToArray()
}

function Get-LintStringCount {
    param([System.Management.Automation.Language.Ast] $Ast)
    return @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)).Count
}

function Get-LintAstReport {
    param([string] $RepoRoot)
    [string] $root = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
    [System.Collections.Generic.List[PSCustomObject]] $arch    = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $unroll  = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $allowed = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $appx    = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $glyph   = [System.Collections.Generic.List[PSCustomObject]]::new()
    [System.Collections.Generic.List[PSCustomObject]] $glyphOk = [System.Collections.Generic.List[PSCustomObject]]::new()
    [int] $strings = 0
    [string[]] $files = @(Get-LintProductFiles -RepoRoot $root)
    $asts = @{}
    foreach ($f in $files) { $asts[$f] = Get-LintAstFromFile -Path $f }
    [hashtable] $safe = Get-LintCollectionSafeFunctions -Asts @($asts.Values)
    foreach ($f in $files) {
        [string] $rel = $f.Substring($root.Length + 1)
        $ast = $asts[$f]
        foreach ($h in @(Find-LintArchiveHits -Ast $ast -File $rel)) { $arch.Add($h) }
        foreach ($s in @(Find-LintAppxSites -Ast $ast -File $rel)) { $appx.Add($s) }
        foreach ($h in @(Find-LintUnrollHits -Ast $ast -File $rel -SafeFunctions $safe)) {
            if ($script:LintUnrollAllowlist.ContainsKey($h.Key)) {
                $h | Add-Member -NotePropertyName Reason -NotePropertyValue $script:LintUnrollAllowlist[$h.Key]
                $allowed.Add($h)
            }
            else { $unroll.Add($h) }
        }
        $strings += Get-LintStringCount -Ast $ast
        foreach ($h in @(Find-LintGlyphHits -Ast $ast -File $rel)) {
            if ($script:LintGlyphAllowlist.ContainsKey($h.Key)) {
                $h | Add-Member -NotePropertyName Reason -NotePropertyValue $script:LintGlyphAllowlist[$h.Key]
                $glyphOk.Add($h)
            }
            else { $glyph.Add($h) }
        }
    }
    # Entradas del allowlist que no matchean ningun hit: se pudrieron (el texto
    # se arreglo o se mudo). Solo se evalua si el barrido vio el archivo: con un
    # RepoRoot de fixture (tests de mutacion) no aplica.
    [System.Collections.Generic.List[string]] $stale = [System.Collections.Generic.List[string]]::new()
    [string[]] $rels = @($files | ForEach-Object { $_.Substring($root.Length + 1) })
    foreach ($k in @($script:LintGlyphAllowlist.Keys | Sort-Object)) {
        [string] $kFile = ($k -split '\|')[0]
        if ($rels -notcontains $kFile) { continue }
        if (-not @($glyphOk | Where-Object { $_.Key -eq $k }).Count) { $stale.Add($k) }
    }
    return [PSCustomObject]@{
        GlyphHits     = $glyph.ToArray()
        GlyphAllowed  = $glyphOk.ToArray()
        GlyphStale    = $stale.ToArray()
        GlyphStrings  = $strings
        Files         = $files
        ArchiveHits   = $arch.ToArray()
        AppxSites     = $appx.ToArray()
        AppxHits      = @($appx | Where-Object { -not $_.Ok })
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
    Write-Host ('-- APPX (#83: *-Appx*Package con $ProgressPreference local en SilentlyContinue)  {0} sitio(s) --' -f @($rep.AppxSites).Count)
    foreach ($h in @($rep.AppxHits)) {
        $failCount++
        Write-Host ('  [FAIL] {0}:{1}  {2}  en {3}' -f $h.File, $h.Line, $h.Command, $h.Function) -ForegroundColor Red
    }
    if (@($rep.AppxHits).Count -eq 0) { Write-Host '  [OK]   todos con progreso suprimido local' -ForegroundColor Green }

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
    Write-Host ('-- GLYPH (U1/#95: literales fuera de la code page {0})  {1} literal(es) barridos --' -f $script:LintGlyphCodePage, $rep.GlyphStrings)
    foreach ($h in @($rep.GlyphHits)) {
        $failCount++
        Write-Host ('  [FAIL] {0}:{1}  {2}  en {3}' -f $h.File, $h.Line, $h.Chars, $h.Function) -ForegroundColor Red
    }
    foreach ($k in @($rep.GlyphStale)) {
        $failCount++
        Write-Host ('  [FAIL] allowlist sin uso (sacarla): {0}' -f $k) -ForegroundColor Red
    }
    foreach ($h in @($rep.GlyphAllowed)) {
        Write-Host ('  [ALLOW] {0}:{1}  {2}  -> {3}' -f $h.File, $h.Line, $h.Chars, $h.Reason) -ForegroundColor DarkGray
    }
    if (@($rep.GlyphHits).Count -eq 0 -and @($rep.GlyphStale).Count -eq 0) { Write-Host '  [OK]   todo literal de consola codifica en 850' -ForegroundColor Green }

    Write-Host ''
    Write-Host ('Resultado: {0} FAIL  (archive {1}, appx {2}, unroll {3}, glyph {4}, allowlist {5}+{6})' -f `
        $failCount, @($rep.ArchiveHits).Count, @($rep.AppxHits).Count, @($rep.UnrollHits).Count, @($rep.GlyphHits).Count, @($rep.UnrollAllowed).Count, @($rep.GlyphAllowed).Count)
    if ($failCount -gt 0) { exit 1 }
    exit 0
}
