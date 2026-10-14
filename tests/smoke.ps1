#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test mínimo para los módulos del toolkit. Verifica que las funciones
    expuestas se pueden invocar sin tirar excepción en una máquina típica.
    Read-only: solo invoca funciones de detección / preview, NUNCA las que mutan
    el sistema (Disable-BloatServices, Optimize-Network, etc.).

.DESCRIPTION
    Para correr antes de cualquier release o después de cambios en módulos.
    Output: tabla con OK/FAIL por función + exit code 0 si todos pasan, 1 si alguno falla.

.EXAMPLE
    .\tests\smoke.ps1                # corre todos
    .\tests\smoke.ps1 -Module Network # solo un módulo
    .\tests\smoke.ps1 -ResultPath "$env:TEMP\smoke.txt"   # + resumen a archivo

.NOTES
    Corrida canonica = HEADLESS (stdin y stdout redirigidos), desde Bash:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/smoke.ps1 < /dev/null
    En una consola interactiva los tests marcados -RequiresHeadless salen SKIP
    (no FAIL falso) y el resumen lo dice. -ForceInteractive simula esa consola
    (stdin no redirigido + VT on) para probar el mecanismo sin una consola real.
#>

[CmdletBinding()]
param(
    [string] $Module = '',
    # Escribe el resumen (entorno + conteos + FAIL/SKIP) a este archivo, ademas de la consola.
    [string] $ResultPath = '',
    # SOLO para probar el smoke: simula consola interactiva aunque stdin/stdout esten redirigidos.
    [switch] $ForceInteractive
)

Set-StrictMode -Version Latest

# ESPEJO DE main.ps1. Estuvo en 'Continue' hasta 2026-07-29, y ese desfasaje tiene
# un muerto conocido: el crash de [A][16] USB (powercfg, exe nativo) paso el smoke
# en verde y lo cazo recien el gate Sandbox #11. Bajo EAP=Stop el stderr de un exe
# nativo se vuelve NativeCommandError TERMINANTE, y el redirect no salva.
# CLAUDE.md ya prescribia "los tests que ejercitan handlers deben fijar EAP=Stop";
# esto lo hace global en vez de test por test.
# Medido antes de cambiarlo: 242/0 con 'Continue' y 242/0 con 'Stop' -- cerrar el
# desfasaje no costo un solo test.
$ErrorActionPreference = 'Stop'

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
[string] $modulesDir = Join-Path $repoRoot 'modules'
[string] $coreDir    = Join-Path $repoRoot 'core'
[string] $utilsDir   = Join-Path $repoRoot 'utils'

# Dot-source en orden de dependencia: utils → core → modules
foreach ($folder in @($utilsDir, $coreDir, $modulesDir)) {
    Get-ChildItem -Path $folder -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}

[System.Collections.Generic.List[PSCustomObject]] $results =
    [System.Collections.Generic.List[PSCustomObject]]::new()

# ─── Entorno de la corrida: headless vs consola interactiva ───────────────────
# Se decide UNA vez, aca, y lo leen Test-SmokeFunction (-RequiresHeadless) y el
# resumen. Se mide con [Console] directo y NO con Test-PctkInteractiveConsole /
# Enable-PctkVT: esas son codigo bajo prueba, y si el gate del SKIP dependiera de
# ellas, una regresion que las hiciera devolver $true se esconderia como SKIP.
# Headless = stdin Y stdout redirigidos (la corrida canonica desde Bash con
# '< /dev/null'). Con cualquiera de los dos en consola, Test-PctkInteractiveConsole
# o Enable-PctkVT pueden dar distinto y los tests que asumen headless no aplican.
[bool] $script:SmokeInputRedirected  = $true
[bool] $script:SmokeOutputRedirected = $true
try { $script:SmokeInputRedirected  = [Console]::IsInputRedirected }  catch { }
try { $script:SmokeOutputRedirected = [Console]::IsOutputRedirected } catch { }
[bool] $script:SmokeHeadless = $script:SmokeInputRedirected -and $script:SmokeOutputRedirected
if ($ForceInteractive) {
    # Simula la consola de Mateo: lo que ahi cambia para el codigo bajo prueba es
    # que Test-PctkInteractiveConsole da $true y Enable-PctkVT prende el VT. Se
    # sombrean SOLO esas dos; el resto del producto corre igual que headless.
    $script:SmokeHeadless = $false
    function Test-PctkInteractiveConsole { [OutputType([bool])] param() return $true }
    function Enable-PctkVT { [OutputType([bool])] param() $script:PctkVT = $true; return $true }
}

# ─── Static check: BOM regression detector ────────────────────────────────────
# Cuando un .ps1 tiene bytes no-ASCII (em-dash, tildes en string literals) y
# está guardado sin BOM, PowerShell 5.1 en locale es-AR lo lee como CP-1252 y
# revienta el parser. Este es un bug que ya nos mordió 2 veces (Stage 0 PR0
# y Stage 1 cuando edité MachineProfile/Privacy). Lo chequeamos cada smoke run.
function Test-BomRegression {
    [string] $rRoot = (Split-Path -Parent $PSScriptRoot)
    [string[]] $patterns = @('core\*.ps1', 'modules\*.ps1', 'utils\*.ps1', 'tools\*.ps1', 'main.ps1', 'Launch.ps1', 'Release.ps1', 'Bootstrap-Tools.ps1')
    [System.Collections.Generic.List[string]] $atRisk = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $rRoot $p) -File -ErrorAction SilentlyContinue)) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            [bool] $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
            if ($hasBom) { continue }
            [bool] $hasNonAscii = $false
            foreach ($byte in $b) { if ($byte -gt 127) { $hasNonAscii = $true; break } }
            if ($hasNonAscii) {
                $atRisk.Add($f.FullName.Substring($rRoot.Length + 1))
            }
        }
    }
    if ($atRisk.Count -gt 0) {
        throw ('BOM missing en {0} archivo(s) con bytes non-ASCII: {1}. Aplicar BOM UTF-8 antes de commit.' -f $atRisk.Count, ($atRisk -join ', '))
    }
}

function Test-SmokeFunction {
    param(
        [string] $ModuleName,
        [string] $FunctionName,
        [scriptblock] $Invocation,
        # El test asume la corrida headless (stdin/stdout redirigidos). Fuera de
        # ella se registra SKIP con -SkipReason en vez de dar un FAIL falso.
        [switch] $RequiresHeadless,
        [string] $SkipReason = 'asume corrida headless (stdin/stdout redirigidos)'
    )

    if (-not [string]::IsNullOrWhiteSpace($script:Module) -and $ModuleName -ne $script:Module) {
        return
    }

    if ($RequiresHeadless -and -not $script:SmokeHeadless) {
        # SKIP no es OK ni FAIL. Un SKIP en corrida headless es un bug del smoke:
        # lo caza el guard del resumen, que no depende de esta condicion.
        $script:results.Add([PSCustomObject]@{
            Module     = $ModuleName
            Function   = $FunctionName
            Status     = 'SKIP'
            DurationMs = 0
            Error      = $SkipReason
        })
        return
    }

    [string] $status = 'OK'
    [string] $errMsg = ''
    [int] $durationMs = 0

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & $Invocation
        $sw.Stop()
        $durationMs = [int] $sw.ElapsedMilliseconds
    }
    catch {
        $status = 'FAIL'
        $errMsg = $_.Exception.Message
        if ($null -ne $sw) { $sw.Stop() }
    }

    $script:results.Add([PSCustomObject]@{
        Module     = $ModuleName
        Function   = $FunctionName
        Status     = $status
        DurationMs = $durationMs
        Error      = $errMsg
    })
}

function Get-CoreSourceText {
    <#
    .SYNOPSIS
        El texto de TODA la capa core\, concatenado, para los guards estructurales.
    .DESCRIPTION
        #26-B: varios tests leian 'core\Router.ps1' por path para verificar que el
        Router llama a tal funcion o que no usa tal patron. Cuando los handlers
        salieron a core\ActionHandlers.ps1 esos guards se rompieron -- y uno de
        ellos habria quedado VERDE POR VACUIDAD, que es peor: seguia mirando un
        archivo del que el codigo ya se habia ido.

        Un guard estructural atado a UN path deja de guardar en cuanto el codigo
        se muda de archivo. Preguntandole a la carpeta entera, el proximo split
        no lo rompe ni lo vacia.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    [string] $coreDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
    [System.Collections.Generic.List[string]] $partes = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $coreDir -Filter '*.ps1' -File | Sort-Object -Property Name)) {
        [void] $partes.Add((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8))
    }
    return ($partes -join "`r`n")
}

# ─── static checks ────────────────────────────────────────────────────────────
Test-SmokeFunction 'StaticCheck' 'BomRegression' { Test-BomRegression }

# Los scripts de tests\ NO los cubre Test-BomRegression (mira core/modules/utils/
# tools + los .ps1 de la raiz) y nadie los dot-sourcea, asi que un error de
# sintaxis vive ahi sin que nada lo grite hasta que alguien los corre a mano.
# Justo donde menos conviene: son las herramientas del gate.
Test-SmokeFunction 'StaticCheck' 'Los .ps1 de tests\ parsean (incluye las herramientas del gate)' {
    [System.Collections.Generic.List[string]] $rotos = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $perr = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $perr)
        if ($null -ne $perr -and @($perr).Count -gt 0) {
            [void] $rotos.Add(('{0} (linea {1}): {2}' -f $f.Name, $perr[0].Extent.StartLineNumber, $perr[0].Message))
        }
    }
    if ($rotos.Count -gt 0) { throw ($rotos -join ' ;; ') }
}

# Las herramientas del gate tienen que EXISTIR y estar completas: si alguien
# borra una mitad, el gate deja de correr y "no corrio" se ve como "no fallo".
Test-SmokeFunction 'StaticCheck' 'Las herramientas del gate de release estan completas' {
    foreach ($f in @('release-preflight.ps1', 'release-gate-validate.ps1',
                     'release-gate-launcher.ps1', 'New-ReleaseGate.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f) -PathType Leaf)) {
            throw ('falta tests\{0}: el gate de release no se puede armar' -f $f)
        }
    }
    # El validate DEBE correr con EAP=Stop para espejar main.ps1. Con 'Continue'
    # (como el smoke) deja pasar los crashes de exe nativo -- fue lo que dejo
    # pasar el crash de [A][16] USB hasta el gate Sandbox.
    [string] $val = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release-gate-validate.ps1') -Raw -Encoding UTF8
    if ($val -notmatch "ErrorActionPreference\s*=\s*'Stop'") {
        throw 'release-gate-validate.ps1 no fija EAP=Stop: no espejaria main.ps1'
    }
}

# ─── `if` usado como sub-expresion: el bug que NO es de parseo ────────────────
# MEDIDO en PS5.1 (5.1.19041): `('{0}' -f (if ...))` y `Cmd (if ...)` PARSEAN
# PERFECTO. Revientan en RUNTIME con "El termino 'if' no se reconoce como nombre
# de un cmdlet" -- PowerShell busca un comando llamado `if`. Y bajo el
# $ErrorActionPreference='Stop' de main.ps1 eso es TERMINANTE: se lleva puesto el
# toolkit entero.
#
# Por eso ni el parser ni el smoke lo cazan: sale a la luz solo cuando ESA rama
# se ejecuta. El panel de bateria del reporte [8] vivio asi hasta v2.4.0, y solo
# se rompia en laptops (una PC de escritorio no tiene bateria -> la rama nunca
# corria). Un chequeo estatico de texto es la unica red barata.
#
# Legal y muy usado: `$x = if (c) {...} else {...}` (asignacion) y `$(if ...)`
# (operador de sub-expresion).
#
# COMO SE DETECTA: por AST, no por texto. Cuando PowerShell ve `(if ...)` lo
# parsea como un CommandAst cuyo nombre de comando es literalmente "if" -- por
# eso el error en runtime es "no se reconoce el termino 'if'". Buscar ese
# CommandAst es exacto: la asignacion queda como IfStatementAst y `$(if ...)` como
# SubExpressionAst, asi que ninguna de las dos formas legales se marca.
# (Un primer intento con regex sobre el texto crudo marcaba los COMENTARIOS que
# describen la trampa -- incluido este. El AST no tiene ese problema.)
Test-SmokeFunction 'StaticCheck' 'Palabras clave usadas como comando (CommandNotFound en runtime)' {
    [string] $rRoot = Split-Path -Parent $PSScriptRoot
    [string[]] $patterns = @('core\*.ps1', 'modules\*.ps1', 'utils\*.ps1', 'tests\*.ps1',
                             'main.ps1', 'Launch.ps1', 'Release.ps1', 'Bootstrap-Tools.ps1')
    [string[]] $keywords = @('if', 'foreach', 'while', 'switch', 'do', 'try')
    [System.Collections.Generic.List[string]] $hits = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $patterns) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $rRoot $p) -File -ErrorAction SilentlyContinue)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $null)
            if ($null -eq $ast) { continue }
            foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                [string] $name = ''
                try { $name = [string] $c.GetCommandName() } catch { }
                if (-not [string]::IsNullOrEmpty($name) -and $keywords -contains $name.ToLowerInvariant()) {
                    [void] $hits.Add(('{0}:{1} -> {2}' -f $f.Name, $c.Extent.StartLineNumber, $name))
                }
            }
        }
    }
    if ($hits.Count -gt 0) {
        throw ('Palabra clave usada como comando (parsea, pero revienta en runtime bajo EAP=Stop) en: {0}. Usar variable temporal o $(...).' -f ($hits -join ', '))
    }
}

# --- #26-A1: red de cierre de serializacion a background jobs ---
# Caza la clase de bug que rompio v2.3.0: un Start-*Process que serializa una
# funcion entry al job sin embeber una funcion que llama transitivamente ->
# CommandNotFound al ejecutar el job (probar los helpers sueltos NO lo caza).
# Red estatica por AST, sin efectos secundarios -> segura en el gate. Detalle y
# demostracion con diente: tests/job-closure.ps1 (corrible standalone).
. (Join-Path $PSScriptRoot 'job-closure.ps1')
$script:JobClosureReport = Get-JobClosureReport -RepoRoot $repoRoot
Test-SmokeFunction 'JobClosure' 'red encontro los sitios de job (piso 14)' {
    [int] $n = @($script:JobClosureReport.Sites).Count
    if ($n -lt 14) { throw ("esperaba >=14 sitios de job serializado; encontro {0} (AST/regex roto?)" -f $n) }
}
Test-SmokeFunction 'JobClosure' 'red encontro el job inline de telemetria con su modulo resuelto (P2b)' {
    # Sin esto, si el patron de Start-TelemetryJob cambia, el sitio inline desaparece
    # o queda Dynamic y el chequeo de $script: deja de mirar ahi SIN ponerse rojo.
    [object[]] $inl = @($script:JobClosureReport.Sites | Where-Object { $_.Kind -eq 'Inline+dot' -and -not $_.Dynamic })
    if ($inl.Count -lt 1) { throw 'ningun sitio Inline+dot resuelto (Start-TelemetryJob): el chequeo de $script: no ve el job de telemetria' }
}
foreach ($__site in @($script:JobClosureReport.Sites)) {
    Test-SmokeFunction 'JobClosure' ('{0} [{1}:{2}]' -f $__site.Enclosing, $__site.File, $__site.Line) {
        if (@($__site.Missing).Count -gt 0) {
            throw ('cierre INCOMPLETO: faltan en el job -> {0}' -f (@($__site.Missing) -join ', '))
        }
        # P2b (E15): $script: leido dentro del job y no asignado en el job -> $null /
        # VariableIsUndefined en el runspace del job. Pasar el valor como parametro.
        if (@($__site.ScriptVars).Count -gt 0) {
            throw ('$script: sin resolver dentro del job -> {0}' -f (@($__site.ScriptVars) -join '; '))
        }
    }
}
Test-SmokeFunction 'JobClosure' 'la red de $script: tiene diente: fixture con un sitio here-string y uno inline+dot (P2b)' {
    # Repo sintetico: lo que DEBE marcar y lo que NO (asignado a nivel archivo del modulo
    # dot-sourceado, asignado en el job, o expandido en build time sin escapar).
    $fxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-jc-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path (Join-Path $fxRoot 'modules') -Force)
        $fx = @'
$script:FxPath = $PSCommandPath
$script:FxOk = 'a'
function Get-FxHelper { "$script:FxOk $script:FxMissing" }
function Get-FxEntry { Get-FxHelper }
function Start-FxJob {
    [string] $m = $script:FxPath
    Invoke-AsyncToolkitJob -ScriptBlock { param($p) . $p; Get-FxEntry } -ArgumentList @($m)
}
function Get-FxEmb { $script:FxEmbVar; $script:FxSet = 1; $script:FxSet }
function Start-FxHere {
    $b = ${function:Get-FxEmb}.ToString()
    [scriptblock]::Create(@"
function Get-FxEmb {
$b
}
`$script:FxSkel
`$script:FxSkelOk = 1
`$script:FxSkelOk
$script:FxBuild
Get-FxEmb
"@)
}
'@
        [System.IO.File]::WriteAllText((Join-Path $fxRoot 'modules\Fx.ps1'), $fx)
        $r = Get-JobClosureReport -RepoRoot $fxRoot
        $inl = @($r.Sites | Where-Object { $_.Enclosing -eq 'Start-FxJob' })
        $her = @($r.Sites | Where-Object { $_.Enclosing -eq 'Start-FxHere' })
        if ($inl.Count -ne 1 -or $inl[0].Kind -ne 'Inline+dot') { throw ('sitio inline no detectado/resuelto: {0}' -f (@($r.Sites | ForEach-Object { $_.Enclosing + ':' + $_.Kind }) -join ', ')) }
        if ($her.Count -ne 1) { throw 'sitio here-string no detectado' }
        [string] $gotInl = (@($inl[0].ScriptVars) | Sort-Object) -join '; '
        [string] $gotHer = (@($her[0].ScriptVars) | Sort-Object) -join '; '
        if ($gotInl -ne 'Get-FxHelper -> $script:FxMissing') { throw ('inline: esperaba solo FxMissing; dio [{0}]' -f $gotInl) }
        if ($gotHer -ne '<job> -> $script:FxSkel; Get-FxEmb -> $script:FxEmbVar') { throw ('here-string: esperaba FxSkel + FxEmbVar; dio [{0}]' -f $gotHer) }
    } finally {
        Remove-Item -LiteralPath $fxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── core ─────────────────────────────────────────────────────────────────────
Test-SmokeFunction 'MachineProfile' 'Get-MachineProfile' { Get-MachineProfile }
Test-SmokeFunction 'MachineProfile' 'IsVirtualMachine field' {
    (Get-MachineProfile).PSObject.Properties['IsVirtualMachine']
}
# Canary gate Sandbox: marca off-brand de 1 sola palabra (EXO, BANGHO, etc.).
# $value.Split(' ') | Where-Object {...} con 1 elemento se desenrolla a escalar
# y $parts.Count tiraba PropertyNotFoundStrict → crasheaba Get-MachineProfile en
# el arranque (main.ps1). El path default sólo se ejercita con marca NO conocida
# de 1 palabra — Get-MachineProfile sobre la PC de dev (marca multi-palabra) no
# lo toca. Test directo del helper con fixture de 1 palabra.
Test-SmokeFunction 'MachineProfile' 'Get-NormalizedManufacturer 1-word off-brand' {
    [string] $r = Get-NormalizedManufacturer -RawManufacturer 'EXO'
    if ($r -ne 'Exo') { throw ("EXO -> 'Exo' esperado; got '{0}'" -f $r) }
    # Sanity de marcas conocidas + vacío (no deben regresionar)
    if ((Get-NormalizedManufacturer -RawManufacturer 'ASUSTeK COMPUTER INC.') -ne 'Asus') { throw 'ASUSTeK -> Asus rompió' }
    if ((Get-NormalizedManufacturer -RawManufacturer '') -ne 'Unknown')                   { throw 'vacío -> Unknown rompió' }
}

# ─── #43: el menú se entera del resize sin esperar una tecla ──────────────────
Test-SmokeFunction 'ConsoleMenu' 'Test-PctkConsoleResized: guarda anti-cuelgue con refs inválidas' {
    # Si el redibujo completo nunca logró leer la geometría, las refs quedan en -1.
    # Comparar contra -1 daría "cambió" en cada vuelta -> redibujo infinito sin
    # consumir teclas, o sea un CUELGUE del menú. Tiene que devolver $false.
    foreach ($caso in @(
        @{ W = -1; H = 40; B = 120 },
        @{ W = 80; H = -1; B = 120 },
        @{ W = 80; H = 40; B = -1  },
        @{ W = -1; H = -1; B = -1  }
    )) {
        if (Test-PctkConsoleResized -LastWidth $caso.W -LastHeight $caso.H -LastBufferWidth $caso.B) {
            throw ("refs inválidas (W={0} H={1} B={2}) reportaron resize -> riesgo de bucle" -f $caso.W, $caso.H, $caso.B)
        }
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Test-PctkConsoleResized: detecta el cambio y no da falsos' {
    # Con la geometría REAL de esta consola no debe reportar cambio; con valores
    # que no pueden coincidir, sí. Si el host no expone geometría, la función
    # devuelve $false por diseño y el test no puede distinguir -> se saltea.
    [int] $w = -1; [int] $h = -1; [int] $b = -1
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight; $b = [Console]::BufferWidth } catch { }
    if ($w -lt 0 -or $h -lt 0 -or $b -lt 0) { return 'sin geometría de consola en este host: no aplica' }

    if (Test-PctkConsoleResized -LastWidth $w -LastHeight $h -LastBufferWidth $b) {
        throw 'la geometría actual reportó cambio (falso positivo -> redibujaría de gratis)'
    }
    if (-not (Test-PctkConsoleResized -LastWidth ($w + 7) -LastHeight $h -LastBufferWidth $b)) {
        throw 'un ancho distinto NO reportó cambio (el bug de #43 volvería)'
    }
}
# RED DE REGRESIÓN DE LA CLASE DEL BUG. Los dos menús interactivos tienen que
# SONDEAR (KeyAvailable) en vez de bloquearse en ReadKey: con el ReadKey detenido,
# la guarda de resize no se evalúa hasta que llega una tecla, y maximizar deja el
# menú mal dibujado hasta que el operador aprieta algo. Eso es #43, y estaba en
# los DOS menús. Por AST: se busca la llamada real, no la palabra en un comentario.
Test-SmokeFunction 'ConsoleMenu' 'los dos menús sondean el teclado, no se bloquean (#43)' {
    [string] $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'utils\ConsoleMenu.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
    foreach ($nombre in @('Read-PctkMenuChoice', 'Read-PctkMultiChoice')) {
        [object[]] $fn = @($ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { $_.Name -eq $nombre })
        if ($fn.Count -ne 1) { throw ("no encontré la función {0}" -f $nombre) }

        # KeyAvailable es una propiedad estática -> MemberExpressionAst, no CommandAst.
        [object[]] $polls = @($fn[0].FindAll({
            param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst]
        }, $true) | Where-Object {
            $_.Member.Extent.Text -eq 'KeyAvailable'
        })
        if ($polls.Count -eq 0) {
            throw ("{0} no sondea KeyAvailable: volvió al ReadKey bloqueante y el resize se vuelve a notar tarde" -f $nombre)
        }
    }
}

# ─── #34: estado de HAGS ──────────────────────────────────────────────────────
Test-SmokeFunction 'MachineProfile' 'Get-HagsMode: read-only y siempre un valor conocido' {
    [string] $m = Get-HagsMode
    if ($m -notin @('Off', 'On', 'Default', 'Unknown')) {
        throw ("modo inesperado: '{0}'" -f $m)
    }
}
# Fixtures de las 4 combinaciones: el aviso sale SÓLO en On+iGPU. Los otros tres
# estados son dato, no aviso — el signo de HAGS depende del equipo y el toolkit
# no opina (misma regla que el power plan de Ryzen).
Test-SmokeFunction 'MachineProfile' 'Get-HagsAdvisory avisa sólo en On + GPU integrada' {
    if ([string]::IsNullOrEmpty((Get-HagsAdvisory -Mode 'On' -HasIGpuOnly $true))) {
        throw 'On + iGPU tendría que avisar y no avisó'
    }
    foreach ($caso in @(
        @{ M = 'On';      I = $false },   # dGPU: HAGS on es normal
        @{ M = 'Off';     I = $true  },   # apagado: nada que avisar
        @{ M = 'Default'; I = $true  },   # Windows nunca lo seteó
        @{ M = 'Unknown'; I = $true  }
    )) {
        [string] $r = Get-HagsAdvisory -Mode $caso.M -HasIGpuOnly $caso.I
        if (-not [string]::IsNullOrEmpty($r)) {
            throw ("Mode={0} iGpuOnly={1} no debía avisar; dijo: {2}" -f $caso.M, $caso.I, $r)
        }
    }
}
# El HANDLER, no la función pura: es Get-MachineProfile lo que corre en producción.
Test-SmokeFunction 'MachineProfile' 'Hags field: el perfil expone el estado (handler)' {
    $p = Get-MachineProfile
    if ($null -eq $p.PSObject.Properties['Hags']) { throw 'falta el campo Hags en el perfil' }
    if ([string]$p.Hags -notin @('Off', 'On', 'Default', 'Unknown')) {
        throw ("Hags='{0}' no es un valor conocido" -f $p.Hags)
    }
}
# RED ANTI-REGRESIÓN DEL LÍMITE DE JOB. `modules\Hags.ps1` tiene un Get-HagsStatus
# que hace esto mismo y mejor, pero Get-MachineProfile se serializa a background
# jobs donde ese módulo NO está cargado: usarlo desde acá sería CommandNotFound al
# EJECUTARSE el job — invisible para el smoke y para cualquier prueba de la función
# suelta (el bug #24, exacto). Si alguien "simplifica" el código llamándolo, este
# test lo caza. Por AST y no por texto, para no marcar los comentarios que lo
# explican (misma lección que el canario de `if` como comando).
Test-SmokeFunction 'MachineProfile' 'no llama a funciones de modules\ (límite de job)' {
    [string] $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'core\MachineProfile.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
    [string[]] $prohibidas = @('Get-HagsStatus', 'Test-IsVirtualMachine')
    [object[]] $malas = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true) | Where-Object {
        [string] $nom = $_.GetCommandName()
        (-not [string]::IsNullOrEmpty($nom)) -and ($prohibidas -contains $nom)
    })
    if ($malas.Count -gt 0) {
        throw ("MachineProfile.ps1 llama a {0} de modules\, que no existe dentro de un background job" -f
            (($malas | ForEach-Object { $_.GetCommandName() }) -join ', '))
    }
}

# ─── modules: solo funciones read-only / preview ──────────────────────────────
Test-SmokeFunction 'Apps' 'Get-InstalledWin32Apps' { Get-InstalledWin32Apps }
Test-SmokeFunction 'Apps' 'Get-InstalledUwpApps'   { Get-InstalledUwpApps }

# §6.4 — read-only: preview shapes, NUNCA llamar Invoke-*Uninstall en smoke
Test-SmokeFunction 'Apps' 'Get-Win32UninstallPreview MSI' {
    $fake = [PSCustomObject]@{
        Name                 = 'Fake App'
        UninstallString      = 'MsiExec.exe /X{12345678-1234-1234-1234-1234567890AB}'
        QuietUninstallString = ''
    }
    $p = Get-Win32UninstallPreview -App $fake
    if ($p.Method -ne 'MSI')             { throw ('Method MSI esperado; got {0}' -f $p.Method) }
    if ($p.CommandLine -notmatch '/X\{') { throw ('CommandLine debe tener /X{; got {0}' -f $p.CommandLine) }
}
Test-SmokeFunction 'Apps' 'Get-UwpUninstallPreview shape' {
    $fake = [PSCustomObject]@{ PackageFullName = 'Foo_1.0_x64__abc' }
    $p = Get-UwpUninstallPreview -App $fake
    if ($p.Success -ne $true)                           { throw ('Success=$true esperado; got {0}' -f $p.Success) }
    if ($p.CommandLine -notmatch 'Remove-AppxPackage')  { throw ('CommandLine debe tener Remove-AppxPackage; got {0}' -f $p.CommandLine) }
}

Test-SmokeFunction 'Cleanup' 'Get-CleanupPreview' { Get-CleanupPreview }

Test-SmokeFunction 'StartupManager' 'Get-StartupDescription: conocido vs desconocido' {
    if ($null -eq (Get-Command 'Get-StartupDescription' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Get-StartupDescription no encontrado'
    }
    [string] $known = Get-StartupDescription -Name 'RtkAudUService'
    if ([string]::IsNullOrEmpty($known)) { throw 'RtkAudUService deberia tener descripcion' }
    # Regresion del falso positivo: 'Application Restart' NO debe matchear Brave por
    # el comando (ahora el match es solo por Name) -> debe ser "Restaurar...".
    [string] $appRestart = Get-StartupDescription -Name 'Application Restart #1'
    if ($appRestart -notmatch 'Restaurar') { throw ("Application Restart deberia ser Restaurar...; got '{0}'" -f $appRestart) }
    [string] $unknown = Get-StartupDescription -Name 'ZxQ_nada_123'
    if ($unknown -ne '') { throw ("desconocido deberia dar ''; got '{0}'" -f $unknown) }
}

Test-SmokeFunction 'Diagnostics' 'Get-BsodHistory' { Get-BsodHistory -Days 7 }

Test-SmokeFunction 'Network' 'Get-NetworkDiagnostics' { Get-NetworkDiagnostics }

# §9 captura AnyDesk ID — helpers read-only (PUROS + StrictMode-safe).
# Herméticos: usan fixtures en TEMP + override de rutas; NO requieren AnyDesk instalado.
Test-SmokeFunction 'AnyDesk' 'ConvertFrom-AnyDeskConf: presente/ausente/espacios/1-linea (StrictMode)' {
    $ErrorActionPreference = 'Stop'
    if ($null -ne (ConvertFrom-AnyDeskConf -Lines @()))                          { throw 'vacío -> $null' }
    if ($null -ne (ConvertFrom-AnyDeskConf -Lines @('foo=bar', '# comentario'))) { throw 'sin clave -> $null' }
    $lines = @('ad.anynet.relay=x', 'ad.anynet.id=123456789', 'ad.roster.items=y')
    if ((ConvertFrom-AnyDeskConf -Lines $lines) -ne '123456789')                 { throw 'ID 123456789 esperado' }
    if ((ConvertFrom-AnyDeskConf -Lines @('ad.anynet.id = 987654321 ')) -ne '987654321') { throw 'tolerar espacios' }
    # 1 sola línea = trampa exactamente-1 (se desenrolla a escalar bajo StrictMode).
    if ((ConvertFrom-AnyDeskConf -Lines @('ad.anynet.id=555')) -ne '555')        { throw '1-línea exacta' }
    if ($null -ne (ConvertFrom-AnyDeskConf -Lines @('ad.anynet.id=abc')))        { throw 'no-numérico -> $null' }
}

Test-SmokeFunction 'AnyDesk' 'Get-AnyDeskId: sin conf -> $null; con fixture -> ID' {
    $ErrorActionPreference = 'Stop'
    # rutas inexistentes -> $null (caso "AnyDesk no instalado", el de la PC de smoke).
    if ($null -ne (Get-AnyDeskId -ConfPaths @((Join-Path $env:TEMP 'pctk-no-existe\system.conf')))) { throw 'sin conf -> $null' }
    # fixture real: archivo temp con la clave.
    $tmp = Join-Path $env:TEMP ('pctk_ad_{0}.conf' -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $tmp -Value @('ad.anynet.id=246813579', 'otra=cosa') -Encoding ASCII
        if ((Get-AnyDeskIdFromConf -ConfPath $tmp) -ne '246813579') { throw 'Get-AnyDeskIdFromConf roto' }
        if ((Get-AnyDeskId -ConfPaths @($tmp)) -ne '246813579')     { throw 'Get-AnyDeskId override roto' }
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# §24 capa de red — helpers de diagnóstico PUROS con fixtures 0/1/N adapters.
# La trampa StrictMode vive en EXACTAMENTE-1 (se desenrolla a escalar). El smoke
# corre con Set-StrictMode -Version Latest, así que ejercita el path real.
Test-SmokeFunction 'Network' 'Get-NetworkAdapterReport: 0/1/N + virtual excluido (StrictMode)' {
    $ErrorActionPreference = 'Stop'
    # 0 adapters -> vacío, sin tirar.
    if (@(Get-NetworkAdapterReport -Adapters @() -AdvByName @{}).Count -ne 0) { throw '0 adapters debe dar vacío' }

    # EXACTAMENTE 1 físico (Wi-Fi, sin EEE).
    $one = [PSCustomObject]@{ Name='Wi-Fi'; LinkSpeed='300 Mbps'; PhysicalMediaType='Native 802.11'; HardwareInterface=$true; DriverVersion='10.45'; DriverDate='2023-08-01' }
    $r1 = @(Get-NetworkAdapterReport -Adapters $one -AdvByName @{ 'Wi-Fi' = [PSCustomObject]@{ Eee=$null; InterruptModeration='1'; SpeedDuplex=$null } })
    if ($r1.Count -ne 1)                     { throw ("1 físico esperado; got {0}" -f $r1.Count) }
    if ($r1[0].Eee -ne 'n/d')                { throw ("Wi-Fi sin EEE -> n/d; got {0}" -f $r1[0].Eee) }
    if ($r1[0].InterruptModeration -ne 'on') { throw ("IM '1' -> on; got {0}" -f $r1[0].InterruptModeration) }
    if ($r1[0].LinkSuspect)                  { throw 'Wi-Fi 300Mbps no debe ser LinkSuspect' }

    # 1 físico + 1 virtual 802.3 (VBox/ZeroTier): el virtual NO entra (fix HW).
    $mix = @(
        [PSCustomObject]@{ Name='Ethernet';   LinkSpeed='100 Mbps'; PhysicalMediaType='802.3'; HardwareInterface=$true;  DriverVersion='9.1'; DriverDate='' },
        [PSCustomObject]@{ Name='Ethernet 3'; LinkSpeed='1 Gbps';   PhysicalMediaType='802.3'; HardwareInterface=$false; DriverVersion='';    DriverDate='' }
    )
    $rm = @(Get-NetworkAdapterReport -Adapters $mix -AdvByName @{ 'Ethernet' = [PSCustomObject]@{ Eee='1'; InterruptModeration='0'; SpeedDuplex='100 Mbps Full Duplex' } })
    if ($rm.Count -ne 1)                          { throw ("virtual debe excluirse; esperado 1, got {0}" -f $rm.Count) }
    if ($rm[0].Name -ne 'Ethernet')               { throw ("el físico es Ethernet; got {0}" -f $rm[0].Name) }
    if ($rm[0].Eee -ne 'on')                      { throw ("EEE '1' -> on; got {0}" -f $rm[0].Eee) }
    if (-not $rm[0].LinkSuspect)                  { throw 'Ethernet 100Mbps debe ser LinkSuspect' }
    if ($rm[0].SpeedDuplex -ne '100 Mbps Full Duplex') { throw 'SpeedDuplex passthrough roto' }

    # N físicos sin AdvByName -> EEE n/d, shape consistente.
    $many = @(
        [PSCustomObject]@{ Name='A'; LinkSpeed='1 Gbps';   PhysicalMediaType='802.3'; HardwareInterface=$true },
        [PSCustomObject]@{ Name='B'; LinkSpeed='1 Gbps';   PhysicalMediaType='802.3'; HardwareInterface=$true },
        [PSCustomObject]@{ Name='C'; LinkSpeed='2.5 Gbps'; PhysicalMediaType='802.3'; HardwareInterface=$true }
    )
    $rn = @(Get-NetworkAdapterReport -Adapters $many -AdvByName @{})
    if ($rn.Count -ne 3)        { throw ("3 físicos esperados; got {0}" -f $rn.Count) }
    foreach ($e in $rn) { if ($e.Eee -ne 'n/d') { throw 'sin AdvByName -> EEE n/d' } }
    if ($rn[2].LinkSuspect)     { throw '2.5 Gbps no es LinkSuspect' }
}

# §24 REGRESIÓN (gate Sandbox v2.3.0): el diagnóstico de red corre en un background
# job, que arranca en un runspace FRESCO sin las funciones del módulo. El bug:
# Start-NetworkDiagnosticsProcess solo serializaba Get-NetworkDiagnostics, no sus
# helpers (Get-NetworkAdapterReport -> ConvertTo-PowerPropState / Test-LinkSuspect
# -> ConvertTo-Mbps) -> CommandNotFoundException al recibir el job y crash de [A][5] D.
# El smoke previo probaba los helpers SUELTOS (existen en esta sesión), nunca el job.
# Este test ejercita el path real: corre el job y falla si reaparece el CommandNotFound.
Test-SmokeFunction 'Network' 'Start-NetworkDiagnosticsProcess: job serializa toda la clausura (no CommandNotFound)' {
    $job = Start-NetworkDiagnosticsProcess
    try {
        $null = Wait-Job -Job $job -Timeout 45
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErr
        # Firma del bug: cualquier CommandNotFound dentro del job (helper no serializado).
        [object[]] $cmdNotFound = @($jobErr | Where-Object {
            ($null -ne $_.FullyQualifiedErrorId -and $_.FullyQualifiedErrorId -match 'CommandNotFound') -or
            $_.Exception -is [System.Management.Automation.CommandNotFoundException]
        })
        if ($cmdNotFound.Count -gt 0) {
            throw ("job tiró CommandNotFound (helper no serializado): {0}" -f $cmdNotFound[0].Exception.Message)
        }
        # Con la clausura completa el job completa y devuelve el shape esperado.
        if ($job.State -eq 'Completed' -and $null -ne $result) {
            foreach ($p in 'TcpAutoTuning','Adapters','PingMs','DnsServers','NetworkThrottlingIndex') {
                if ($null -eq $result.PSObject.Properties[$p]) { throw ("falta prop '{0}' en el resultado del job" -f $p) }
            }
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Network' 'ConvertTo-Mbps + Test-LinkSuspect + ConvertTo-PowerPropState' {
    $ErrorActionPreference = 'Stop'
    if ((ConvertTo-Mbps -LinkSpeed '1 Gbps')   -ne 1000) { throw '1 Gbps -> 1000' }
    if ((ConvertTo-Mbps -LinkSpeed '100 Mbps') -ne 100)  { throw '100 Mbps -> 100' }
    if ((ConvertTo-Mbps -LinkSpeed '2.5 Gbps') -ne 2500) { throw '2.5 Gbps -> 2500' }
    if ((ConvertTo-Mbps -LinkSpeed '')         -ne -1)   { throw 'vacío -> -1' }
    if ((ConvertTo-Mbps -LinkSpeed 'nonsense') -ne -1)   { throw 'basura -> -1' }
    if (-not (Test-LinkSuspect -MediaType '802.3' -LinkSpeed '100 Mbps')) { throw 'Eth 100 = suspect' }
    if (Test-LinkSuspect -MediaType '802.3' -LinkSpeed '1 Gbps')          { throw 'Eth 1Gbps no suspect' }
    if (Test-LinkSuspect -MediaType 'Native 802.11' -LinkSpeed '54 Mbps') { throw 'Wi-Fi no aplica heurística de cable' }
    if ((ConvertTo-PowerPropState -RegistryValue $null)      -ne 'n/d') { throw 'null -> n/d' }
    if ((ConvertTo-PowerPropState -RegistryValue '1')        -ne 'on')  { throw '1 -> on' }
    if ((ConvertTo-PowerPropState -RegistryValue '0')        -ne 'off') { throw '0 -> off' }
    if ((ConvertTo-PowerPropState -RegistryValue 'Enabled')  -ne 'on')  { throw 'Enabled -> on' }
}

# §24 3.B bufferbloat (delegado a waveform): grado PURO + baseline read-only.
Test-SmokeFunction 'Network' 'Get-BufferbloatGrade: umbrales A/B/C/F (puro)' {
    $ErrorActionPreference = 'Stop'
    if ((Get-BufferbloatGrade -DeltaMs -1)  -ne '?') { throw 'negativo -> ?' }
    if ((Get-BufferbloatGrade -DeltaMs 0)   -ne 'A') { throw '0 -> A' }
    if ((Get-BufferbloatGrade -DeltaMs 29)  -ne 'A') { throw '29 -> A' }
    if ((Get-BufferbloatGrade -DeltaMs 30)  -ne 'B') { throw '30 -> B' }
    if ((Get-BufferbloatGrade -DeltaMs 59)  -ne 'B') { throw '59 -> B' }
    if ((Get-BufferbloatGrade -DeltaMs 60)  -ne 'C') { throw '60 -> C' }
    if ((Get-BufferbloatGrade -DeltaMs 119) -ne 'C') { throw '119 -> C' }
    if ((Get-BufferbloatGrade -DeltaMs 120) -ne 'F') { throw '120 -> F' }
    if ((Get-BufferbloatGrade -DeltaMs 500) -ne 'F') { throw '500 -> F' }
}
Test-SmokeFunction 'Network' 'Get-NetworkBufferbloat: shape read-only (1 ping, StrictMode)' {
    $ErrorActionPreference = 'Stop'
    $bb = Get-NetworkBufferbloat -Count 1
    foreach ($p in @('Gateway','IdleAvgMs','IdleMaxMs','WaveformUrl')) {
        if ($null -eq $bb.PSObject.Properties[$p]) { throw ("falta campo {0}" -f $p) }
    }
    if ([string]::IsNullOrWhiteSpace($bb.Gateway)) { throw 'Gateway vacío' }
    if ($bb.WaveformUrl -notmatch 'waveform') { throw 'WaveformUrl roto' }
}

Test-SmokeFunction 'Privacy' 'Test-ShutUp10Available' { Test-ShutUp10Available }
Test-SmokeFunction 'Privacy' 'Get-ShutUp10Path'       { Get-ShutUp10Path }

Test-SmokeFunction 'StartupManager' 'Test-StartupSafeToDisable: updaters true; opcional/dejar/desconocido false' {
    $ErrorActionPreference = 'Stop'
    foreach ($n in @('GoogleUpdateTaskMachineCore','AdobeAAMUpdater','EqualizerAPO_Update','iTunesHelper','Apple Bonjour Service')) {
        if (-not (Test-StartupSafeToDisable -Name $n)) { throw ("'$n' deberia ser seguro-apagar (true)") }
    }
    foreach ($n in @('Discord','Steam','SecurityHealth','RtkAudUService','AnyDesk','ZxQ_nada_123','')) {
        if (Test-StartupSafeToDisable -Name $n) { throw ("'$n' NO deberia ser seguro-apagar (false)") }
    }
}
Test-SmokeFunction 'StartupManager' 'Get-StartupEntries' { Get-StartupEntries }

# §6.3: Set-StartupEntry early-return paths — entradas SINTETICAS, cero mutacion
Test-SmokeFunction 'StartupManager' 'Set-StartupEntry rechaza RunOnce' {
    $e = [PSCustomObject]@{ Name='x'; Enabled=$true; CanToggle=$false; Type='Registry'; ApprovedPath=$null; FilePath=$null }
    $r = Set-StartupEntry -Entry $e -Enabled $false
    if ($r.Success -ne $false) { throw ('Success debe ser $false para RunOnce; got {0}' -f $r.Success) }
}
Test-SmokeFunction 'StartupManager' 'Set-StartupEntry no-op si ya en estado' {
    $e = [PSCustomObject]@{ Name='x'; Enabled=$true; CanToggle=$true; Type='Registry'; ApprovedPath=$null; FilePath=$null }
    $r = Set-StartupEntry -Entry $e -Enabled $true
    if ($r.Success -ne $true)    { throw ('Success debe ser $true para no-op; got {0}' -f $r.Success) }
    if ($r.AlreadySet -ne $true) { throw ('AlreadySet debe ser $true para no-op; got {0}' -f $r.AlreadySet) }
}

Test-SmokeFunction 'Telemetry' 'Test-IsVirtualMachine' { Test-IsVirtualMachine }
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout returns on time' {
    $r = Invoke-WithTimeout -ScriptBlock { 42 } -TimeoutSeconds 5
    if (-not $r.Ok) { throw ('Debe ser Ok=$true; Ok={0}' -f $r.Ok) }
    if ($r.TimedOut) { throw 'No debe ser TimedOut' }
    if ($r.Value[0] -ne 42) { throw ('Value[0] debe ser 42; got {0}' -f $r.Value[0]) }
}
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout honors timeout' {
    # debe devolver envelope con TimedOut=$true sin colgar el smoke (~2s, no el sleep)
    $r = Invoke-WithTimeout -ScriptBlock { Start-Sleep 30; 'NO' } -TimeoutSeconds 2 -Default 'TIMEOUT'
    if (-not $r.TimedOut) { throw ('Debe ser TimedOut=$true; TimedOut={0}' -f $r.TimedOut) }
    if ($r.Ok) { throw 'No debe ser Ok=$true en timeout' }
    if ($r.Value[0] -ne 'TIMEOUT') { throw ('Value[0] debe ser TIMEOUT; got {0}' -f $r.Value[0]) }
}

$script:_snapshotResult = $null
Test-SmokeFunction 'Telemetry' 'Get-SystemSnapshot' {
    $script:_snapshotResult = Get-SystemSnapshot -Phase Pre
    $script:_snapshotResult
}
Test-SmokeFunction 'Telemetry' 'Snapshot has IsVirtualMachine field' {
    if ($null -eq $script:_snapshotResult) { throw 'Snapshot no disponible (test previo fallo)' }
    $script:_snapshotResult.PSObject.Properties['IsVirtualMachine'] | Out-Null
    if ($null -eq $script:_snapshotResult.PSObject.Properties['IsVirtualMachine']) {
        throw 'Campo IsVirtualMachine ausente en snapshot'
    }
    if ($null -eq $script:_snapshotResult.PSObject.Properties['VmVendor']) {
        throw 'Campo VmVendor ausente en snapshot'
    }
    if ($null -eq $script:_snapshotResult.PSObject.Properties['QueryTimings']) {
        throw 'Campo QueryTimings ausente en snapshot'
    }
}

# ─── #37: salud de bateria ────────────────────────────────────────────────────
# Win32_Battery devuelve DesignCapacity y FullChargeCapacity VACIAS en la mayoria
# de las notebooks (limitacion de esa clase WMI, no bug de PCTk), asi que la fila
# "Salud" del reporte [8] no salia nunca. Get-BatteryHealth encadena
# root\wmi -> powercfg /XML -> Win32_Battery.

Test-SmokeFunction 'Telemetry' '#37 _BatteryPercent: calculo normal' {
    # Medido en HW real (notebook de Mateo, 2026-08-07): 35380/45000 = 78.6%.
    $r = _BatteryPercent -Designed 45000 -Charged 35380
    if ($r -ne 78.6) { throw ('esperaba 78.6; got {0}' -f $r) }
}

Test-SmokeFunction 'Telemetry' '#37 _BatteryPercent: sin dato da null, NUNCA un numero' {
    # El guardrail de #37: si no hay dato, la fila se omite. Jamas un 100% por
    # defecto ni un numero inventado. El caso 'strings vacios' es literalmente lo
    # que devuelve Win32_Battery en la notebook de Mateo.
    foreach ($caso in @(
        @{ D = $null; C = 35380; Que = 'diseno null' },
        @{ D = 45000; C = $null; Que = 'carga null' },
        @{ D = 0;     C = 35380; Que = 'diseno cero' },
        @{ D = 45000; C = 0;     Que = 'carga cero' },
        @{ D = '';    C = '';    Que = 'strings vacios (lo que da Win32_Battery)' },
        @{ D = 'ab';  C = 'cd';  Que = 'no numerico' },
        @{ D = 100;   C = 900;   Que = 'ratio absurdo: unidades que no cierran' }
    )) {
        $r = _BatteryPercent -Designed $caso.D -Charged $caso.C
        if ($null -ne $r) { throw ('{0}: esperaba null; got {1}' -f $caso.Que, $r) }
    }
}

Test-SmokeFunction 'Telemetry' '#37 _BatteryPercent: bateria nueva se acota a 100' {
    # Una bateria que carga MAS que su diseno esta sana al 100%. Un "103%" en el
    # reporte del cliente se lee como error del toolkit.
    $r = _BatteryPercent -Designed 45000 -Charged 46500
    if ($r -ne 100) { throw ('esperaba 100; got {0}' -f $r) }
}

Test-SmokeFunction 'Telemetry' '#37 Get-BatteryHealth: shape o null, bajo EAP=Stop' {
    # EAP=Stop espeja main.ps1. powercfg es exe NATIVO y ahi su stderr es
    # TERMINANTE (ver CLAUDE.md); si la neutralizacion local se cae, esto lo caza.
    # En desktop o Sandbox no hay bateria: $null es una respuesta valida.
    $ErrorActionPreference = 'Stop'
    [object] $h = Get-BatteryHealth -TimeoutSeconds 2
    if ($null -eq $h) { return }

    foreach ($campo in @('Percent', 'Source', 'DesignedMwh', 'FullChargedMwh', 'CycleCount')) {
        if ($null -eq $h.PSObject.Properties[$campo]) { throw ('falta el campo {0}' -f $campo) }
    }
    if ($h.Percent -le 0 -or $h.Percent -gt 100) { throw ('Percent fuera de rango: {0}' -f $h.Percent) }
    if ($h.Source -notin @('root\wmi', 'powercfg', 'Win32_Battery')) {
        throw ('Source desconocido: {0}' -f $h.Source)
    }
}

Test-SmokeFunction 'Telemetry' '#37 el snapshot expone HealthSource y CycleCount' {
    if ($null -eq $script:_snapshotResult) { throw 'Snapshot no disponible (test previo fallo)' }
    [object] $bat = $script:_snapshotResult.Battery
    if ($null -eq $bat) { return }   # desktop sin bateria: valido

    foreach ($campo in @('ChargePercent', 'HealthPercent', 'HealthSource', 'CycleCount', 'Status')) {
        if ($null -eq $bat.PSObject.Properties[$campo]) {
            throw ('falta el campo {0} en Battery' -f $campo)
        }
    }
}

Test-SmokeFunction 'RawAudit' '#37 snapshot VIEJO (sin los campos nuevos) no rompe bajo StrictMode' {
    # Pasa de verdad: el toolkit se actualiza entre el PRE y el POST de un mismo
    # service, o se abre un snapshot guardado hace semanas. Ese Battery tiene
    # SOLO 3 campos, y leer HealthSource/CycleCount directo sobre el bajo
    # StrictMode tira PropertyNotFoundStrict. Se ejercita el HANDLER que arma el
    # informe, no la lectura suelta de la propiedad.
    $ErrorActionPreference = 'Stop'
    if ($null -eq $script:_snapshotResult) { $script:_snapshotResult = Get-SystemSnapshot -Phase Pre }

    [PSCustomObject] $viejo = $script:_snapshotResult.PSObject.Copy()
    $viejo.Battery = [PSCustomObject]@{
        ChargePercent = 59
        HealthPercent = $null
        Status        = 'AC'
    }

    [object] $r = New-RawAuditReport -Snapshot $viejo
    try {
        if (-not $r.Success) { throw 'New-RawAuditReport fallo con un snapshot viejo' }
        [string] $body = Get-Content -LiteralPath $r.FilePath -Raw
        if ($body -notmatch 'Charge %')  { throw 'no renderizo la seccion BATTERY' }
        if ($body -match 'Health src')   { throw 'inventó "Health src" en un snapshot que no lo trae' }
        if ($body -match 'Ciclos')       { throw 'inventó "Ciclos" en un snapshot que no lo trae' }
    } finally {
        if ($r.FilePath -and (Test-Path -LiteralPath $r.FilePath)) {
            Remove-Item -LiteralPath $r.FilePath -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-SmokeFunction 'RawAudit' '#37 snapshot NUEVO muestra la fuente y los ciclos' {
    $ErrorActionPreference = 'Stop'
    if ($null -eq $script:_snapshotResult) { $script:_snapshotResult = Get-SystemSnapshot -Phase Pre }

    [PSCustomObject] $nuevo = $script:_snapshotResult.PSObject.Copy()
    $nuevo.Battery = [PSCustomObject]@{
        ChargePercent = 99
        HealthPercent = 78.6
        HealthSource  = 'powercfg'
        CycleCount    = 817
        Status        = 'AC'
    }

    [object] $r = New-RawAuditReport -Snapshot $nuevo
    try {
        if (-not $r.Success) { throw 'New-RawAuditReport fallo con un snapshot nuevo' }
        [string] $body = Get-Content -LiteralPath $r.FilePath -Raw
        if ($body -notmatch '78[.,]6')  { throw 'no renderizo la salud (78.6)' }
        if ($body -notmatch 'powercfg') { throw 'no renderizo la fuente del dato' }
        if ($body -notmatch '817')      { throw 'no renderizo los ciclos' }
    } finally {
        if ($r.FilePath -and (Test-Path -LiteralPath $r.FilePath)) {
            Remove-Item -LiteralPath $r.FilePath -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-SmokeFunction 'ToolkitSupport' 'Get-WindowsUpdateStatus' {
    Get-WindowsUpdateStatus -IsLtsc $false
}
Test-SmokeFunction 'ToolkitSupport' 'Convert-ToolkitDateDisplay' {
    Convert-ToolkitDateDisplay -Value (Get-Date)
}

# ─── ProfileEngine v2.0: 3 recetas auto (read-only: path + import/validate) ──
# v2.0 consolido los 12 archivos (4 use-cases x 3 tiers) en 3 archivos
# (generic/work/multimedia), eliminando _tier del JSON. Office+study fusionados
# a 'work'. Multimedia_high (Full visuals = bug) fixeado a Balanced.
Test-SmokeFunction 'ProfileEngine' 'Get-AutoProfilePath'  { Get-AutoProfilePath -UseCase generic }
Test-SmokeFunction 'ProfileEngine' 'Import generic'       { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase generic) }
Test-SmokeFunction 'ProfileEngine' 'Import work'          { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase work) }
Test-SmokeFunction 'ProfileEngine' 'Import multimedia'    { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase multimedia) }

# ─── Stage 0 new modules (read-only paths only) ───────────────────────────────
Test-SmokeFunction 'CoreIsolation' 'Get-CoreIsolationStatus' { Get-CoreIsolationStatus }

Test-SmokeFunction 'UsbPower' 'Get-UsbSelectiveSuspendStatus' { Get-UsbSelectiveSuspendStatus }

Test-SmokeFunction 'Hags' 'Get-HagsStatus' { Get-HagsStatus }

Test-SmokeFunction 'Wsl' 'Test-WslAvailable' { Test-WslAvailable }
Test-SmokeFunction 'Wsl' 'Get-WslConfig'     { Get-WslConfig }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Default)' { New-WslConfig -Preset Default }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Gaming)'  { New-WslConfig -Preset Gaming }
Test-SmokeFunction 'Wsl' 'New-WslConfig (DevHeavy)' { New-WslConfig -Preset DevHeavy }

# Stage 4 — read-only (no mutan): editor/IO de recetas nombradas + helpers toggle
Test-SmokeFunction 'NamedProfileEditor' 'Get-NamedProfileDir'  { Get-NamedProfileDir }
Test-SmokeFunction 'NamedProfileEditor' 'Get-NamedProfileList' { Get-NamedProfileList }
Test-SmokeFunction 'NamedProfileEditor' 'Import/validate _sample' { Import-NamedProfile -Path (Join-Path (Get-NamedProfileDir) '_sample.json') }
# Regresion Bug2 (v2.0.1): Add-Tweak escribia $script:gt -> crash StrictMode al
# 1er toggle; ademas 410/438 leian $gt local -> receta vacia. Read-only: el
# builder solo construye/retorna un objeto (Get-*Status son deteccion).
# Shadow de Read-Host (funcion local) -> headless: 'f' hace toggles 'off'.
Test-SmokeFunction 'NamedProfileEditor' 'New-NamedProfileInteractive escribe gaming_tweaks' {
    function Read-Host { 'f' }
    $p = New-NamedProfileInteractive -MachineProfile (Get-MachineProfile)
    if ($null -eq $p) { throw 'New-NamedProfileInteractive devolvio $null' }
    $gtp = $p.PSObject.Properties['gaming_tweaks']
    if ($null -eq $gtp) { throw 'falta gaming_tweaks en la receta' }
    $hv = $gtp.Value.PSObject.Properties['hvci']
    if ($null -eq $hv -or [string]$hv.Value -ne 'off') {
        throw ("gaming_tweaks.hvci esperado 'off'; got {0}" -f $(if ($hv) { $hv.Value } else { '(ausente)' }))
    }
}
Test-SmokeFunction 'Performance' 'Get-GameModeStatus' { Get-GameModeStatus }
Test-SmokeFunction 'Privacy' 'Get-CustomDefenderExclusions' { Get-CustomDefenderExclusions }
Test-SmokeFunction 'Privacy' 'Get-DefenderScanSchedule (read-only)' { $null = Get-DefenderScanSchedule }
Test-SmokeFunction 'Privacy' 'Set-DefenderScanSchedule definida (no se ejecuta: muta Defender)' {
    if (-not (Get-Command Set-DefenderScanSchedule -ErrorAction SilentlyContinue)) { throw 'Set-DefenderScanSchedule no definida' }
}
Test-SmokeFunction 'Router' 'Invoke-ActionDefenderScan definida ([A][19])' {
    if (-not (Get-Command Invoke-ActionDefenderScan -ErrorAction SilentlyContinue)) { throw 'Invoke-ActionDefenderScan no definida' }
}

# ─── ITEM C: Test-StepSucceeded (D-SD2 adapters, structural-debt-plan.md) ────
# Entradas read-only: solo ejercitan el helper con fixtures en memoria, sin mutar.
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded null -> false' {
    $r = Test-StepSucceeded -StepResult $null
    if ($r -ne $false) { throw ('null debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Success=$true -> true' {
    $obj = [PSCustomObject]@{ Success = $true }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Success=$true debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Success=$false -> false' {
    $obj = [PSCustomObject]@{ Success = $false }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Success=$false debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Errors no vacio -> false' {
    $obj = [PSCustomObject]@{ Errors = @('algo fallo') }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Errors no-vacio debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Errors vacio -> true' {
    $obj = [PSCustomObject]@{ Errors = @() }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Errors vacio debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Failed>0 -> false' {
    $obj = [PSCustomObject]@{ Failed = 3 }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Failed=3 debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Failed=0 -> true' {
    $obj = [PSCustomObject]@{ Failed = 0 }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Failed=0 debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded objeto plano no-null -> true' {
    $obj = [PSCustomObject]@{ SomeField = 'valor' }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('objeto plano no-null debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Error no vacio -> false' {
    $obj = [PSCustomObject]@{ Error = 'mensaje de error' }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Error no-vacio debe dar false; got {0}' -f $r) }
}

# ─── ToolsSelector: listado/estado read-only (D-TS1) ─────────────────────────
# Verifica que Get-ToolStatus parsea manifest.json y devuelve bool por herramienta
# sin descargar nada (read-only).
Test-SmokeFunction 'ToolsSelector' 'Get-ToolStatus parsea manifest sin descargar' {
    [string] $rRoot  = Split-Path -Parent $PSScriptRoot
    [string] $mPath  = Join-Path $rRoot 'tools\manifest.json'
    [string] $binDir = Join-Path $rRoot 'tools\bin'
    if (-not (Test-Path $mPath)) { throw 'tools\manifest.json no encontrado' }
    $m = Get-Content $mPath -Raw | ConvertFrom-Json
    [object[]] $tl = @($m.tools)
    if ($tl.Count -eq 0) { throw 'Manifest sin herramientas' }
    foreach ($t in $tl) {
        $r = Get-ToolStatus -Tool $t -BinDir $binDir
        if ($r -isnot [bool]) { throw ('Get-ToolStatus devolvio no-bool para {0}' -f $t.name) }
    }
    $tl.Count
}

# ─── Stage 4.2-A: TimerResolution + ProcessPriority (read-only) ──────────────
Test-SmokeFunction 'TimerResolution' 'Get-TimerResolutionStatus no throw' { Get-TimerResolutionStatus }
Test-SmokeFunction 'TimerResolution' 'Get-TimerResolutionStatus shape' {
    $s = Get-TimerResolutionStatus
    foreach ($f in @('Enabled','RawValue','RegistryPath','WinBuild','GateWin11')) {
        if ($null -eq $s.PSObject.Properties[$f]) { throw "Campo $f ausente en Get-TimerResolutionStatus" }
    }
}
Test-SmokeFunction 'ProcessPriority' 'Get-ProcessPriorityIFEO no throw' { Get-ProcessPriorityIFEO }
Test-SmokeFunction 'ProcessPriority' 'clase Normal aceptada (Router [N] <-> modulo)' {
    # [15] ofrece [N]ormal en el menu; el modulo DEBE tener 'Normal' en el map o
    # la accion falla. Guarda contra el medio-cableado (Router si, modulo no).
    if (-not $script:PriorityClassMap.ContainsKey('Normal')) { throw "modulo: PriorityClassMap sin 'Normal'" }
    $rh = (Get-Command Invoke-ActionProcessPriority -CommandType Function).Definition
    if ($rh -notmatch "'N'\s*\{\s*'Normal'") { throw "Router [N] no mapea a 'Normal'" }
}

# ─── Stage 5: handlers menu [A] de modulos huerfanos (backlog #11) ────────────
# Cada handler es interactivo (Read-Host). Por handler:
#  (1) ROUTING: el dispatch rutea su numero [12]-[16] al handler correcto.
#  (2) ABORT-SEGURO: shadowea Read-Host con '' (aborta en el 1er prompt SIN
#      mutar) y corre el handler -> ejercita el display (Get-*Status) + cancela.
# Cada test fija $ErrorActionPreference='Stop' para ESPEJAR main.ps1 (el smoke
# global usa 'Continue'; ese mismatch dejo pasar el bug del gate #11: powercfg
# nativo bajo EAP=Stop tira NativeCommandError terminante). No-throw caza esa
# familia + crashes StrictMode en el path de lectura.
# La mutacion real (registry/powercfg) la valida el gate Sandbox, no el smoke.
Test-SmokeFunction 'Router' 'handler [12] CoreIsolation routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'12'\s*\{\s*Invoke-ActionCoreIsolation") { throw 'dispatch no rutea [12] -> Invoke-ActionCoreIsolation' }
    function Read-Host { '' }
    Invoke-ActionCoreIsolation -MachineProfile (Get-MachineProfile) | Out-Null
}
# #27(a): [A][12] [D] avisa de anti-cheat kernel ANTES de apagar HVCI y pide S/N
# (default N). Corre el HANDLER (no CoreIsolation) con el input en cola; Confirm-Action
# e Invoke-EncryptionGate van reales (el input llega por el Read-Host sombreado), y se
# sombrean el estado, la mutacion (Disable-Hvci/Enable-Hvci cuentan llamadas), el
# cifrado (sin cifrar), la auditoria y los renderers.
# Las colas traen respuestas DE MAS para los prompts viejos (VBS + Confirm-Action):
# si el handler no pregunta en el aviso, 'D','N','S','S' corre un lugar y llega a
# Disable-Hvci, asi el test se rompe por el assert de la mutacion y no solo por el
# texto. (Con 'D','N','N','S' el sobrante cancelaba en Confirm-Action y la mutacion
# "sin confirmacion" pasaba el caso N: medido.)
function Invoke-HvciAntiCheatHarness {
    param([string[]] $Answers)
    $script:HvAns    = [System.Collections.Generic.Queue[string]]::new()
    foreach ($a in $Answers) { $script:HvAns.Enqueue($a) }
    $script:HvOut    = [System.Collections.Generic.List[string]]::new()
    $script:HvWarn   = [System.Collections.Generic.List[string]]::new()
    $script:HvDisable = 0
    $script:HvEnable  = 0
    function Read-Host {
        param([object] $Prompt)
        $script:HvOut.Add(('prompt:{0}' -f $Prompt))
        if ($script:HvAns.Count -eq 0) { throw ('Read-Host sin respuesta en cola: {0}' -f $Prompt) }
        return $script:HvAns.Dequeue()
    }
    function Get-CoreIsolationStatus {
        [PSCustomObject]@{ VbsConfigured = $true; VbsRunning = $true; HvciConfigured = $true; HvciRunning = $true; HypervisorPresent = $true }
    }
    function Disable-Hvci { param([switch] $DisableVbsToo) $script:HvDisable++; [PSCustomObject]@{ Success = $true; Applied = @('x'); Errors = @(); Reason = '' } }
    function Enable-Hvci  { $script:HvEnable++;  [PSCustomObject]@{ Success = $true; Applied = @('x'); Errors = @(); Reason = '' } }
    function Get-DiskEncryptionStatus { param($DriveLetter) [PSCustomObject]@{ IsEncrypted = $false } }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    function Show-OrphanModuleResult { param($Action, $Result) }
    function Write-Host { $script:HvOut.Add(($args -join ' ')) }
    function Write-PctkLine { param([AllowEmptyString()][string] $Text, $Kind) $script:HvOut.Add($Text) }
    function Write-PctkWarn { param([AllowEmptyString()][string] $Text) $script:HvOut.Add($Text); $script:HvWarn.Add($Text) }
    function Write-PctkHint { param([AllowEmptyString()][string] $Text) $script:HvOut.Add($Text); $script:HvWarn.Add($Text) }
    function Write-PctkWork { param([AllowEmptyString()][string] $Text) $script:HvOut.Add($Text) }
    function Write-PctkSection { param([AllowEmptyString()][string] $Text) $script:HvOut.Add($Text) }
    function Write-PctkOk { param([AllowEmptyString()][string] $Text) $script:HvOut.Add($Text) }
    Invoke-ActionCoreIsolation -MachineProfile ([PSCustomObject]@{}) | Out-Null
    return [PSCustomObject]@{
        Text    = ($script:HvOut -join "`n")
        Avisos  = @($script:HvWarn)
        Disable = $script:HvDisable
        Enable  = $script:HvEnable
    }
}
Test-SmokeFunction 'Router' 'handler [12] [D]+N: avisa anti-cheat y NO deshabilita HVCI (#27a)' {
    $r = Invoke-HvciAntiCheatHarness -Answers @('D', 'N', 'S', 'S')
    if ($r.Text -notmatch 'anti-cheat') { throw ('falta el aviso anti-cheat en la salida: ' + $r.Text) }
    if ($r.Disable -ne 0) { throw ('con N se llamo Disable-Hvci {0} vez/veces' -f $r.Disable) }
    if ($r.Enable -ne 0) { throw 'con N se llamo Enable-Hvci' }
}
Test-SmokeFunction 'Router' 'handler [12] [D]+Enter vacio: default N, NO deshabilita HVCI (#27a)' {
    $r = Invoke-HvciAntiCheatHarness -Answers @('D', '', 'S', 'S')
    if ($r.Text -notmatch 'anti-cheat') { throw 'falta el aviso anti-cheat en la salida' }
    if ($r.Disable -ne 0) { throw ('Enter vacio deshabilito HVCI ({0} llamadas): el default tiene que ser N' -f $r.Disable) }
}
Test-SmokeFunction 'Router' 'handler [12] [D]+S: avisa y deshabilita HVCI exactamente 1 vez (#27a)' {
    $r = Invoke-HvciAntiCheatHarness -Answers @('D', 'S', 'N', 'S')
    if ($r.Text -notmatch 'anti-cheat') { throw 'falta el aviso anti-cheat en la salida' }
    if ($r.Disable -ne 1) { throw ('con S Disable-Hvci se llamo {0} vez/veces (esperado 1)' -f $r.Disable) }
    if ($r.Enable -ne 0) { throw 'con S se llamo Enable-Hvci' }
    # Paleta CP850: el aviso es ASCII puro (nada de flechas, bullets ni guion largo).
    foreach ($l in $r.Avisos) {
        foreach ($ch in $l.ToCharArray()) {
            if ([int] $ch -gt 127) { throw ('aviso con caracter no-ASCII U+{0:X4}: {1}' -f [int] $ch, $l) }
        }
    }
}

# Fixtures del preview de receta nombrada (Get-NamedProfilePreviewLines): el
# _sample.json (schema v2.0, sin _tier) con gaming_tweaks.hvci a eleccion, y una
# maquina igual a su _hardware_snapshot.
function New-HvciPreviewFixture {
    param([string] $Hvci)   # 'off' | 'on' | '' = ausente
    $p = Get-Content (Join-Path (Get-NamedProfileDir) '_sample.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($Hvci)) { $p.gaming_tweaks.PSObject.Properties.Remove('hvci') }
    else { $p.gaming_tweaks.hvci = $Hvci }
    return $p
}
function New-HvciPreviewMachine {
    # Igual al _hardware_snapshot del _sample: sin avisos de "hardware cambio".
    [PSCustomObject]@{ Tier = 'High'; CpuName = 'Sample CPU'; RamMB = 16384; Manufacturer = 'Sample'; HasIGpuOnly = $false }
}
Test-SmokeFunction 'NamedProfileEditor' 'preview de receta v2.0 (sin _tier) no crashea bajo StrictMode' {
    # v2.0 saco _tier del JSON (New-NamedProfileInteractive no lo escribe, el _sample
    # no lo tiene) y el preview lo seguia leyendo directo: PropertyNotFoundStrict y el
    # [2] moria antes del Confirm-Action. Corre bajo el StrictMode Latest del smoke.
    Set-StrictMode -Version Latest
    $p = New-HvciPreviewFixture -Hvci 'off'
    if ($null -ne $p.PSObject.Properties['_tier']) { throw 'el fixture tiene _tier: no ejercita el caso v2.0' }
    [string[]] $lines = Get-NamedProfilePreviewLines -Profile $p -MachineProfile (New-HvciPreviewMachine)
    if (@($lines | Where-Object { $_ -like 'Tier receta: High*Tier detectado: High*' }).Count -ne 1) {
        throw ('la linea de tier no toma el del _hardware_snapshot: ' + ($lines -join ' | '))
    }
}
# #87: el camino de recetas nombradas apaga HVCI (gaming_tweaks.hvci = 'off', que
# pre-llena New-GamingPreset o viene del JSON) sin pasar por el [A][12]. El aviso
# anti-cheat de #27(a) tiene que estar en el preview que el operador confirma, y
# salir de la MISMA fuente que el del [12] (Get-HvciAntiCheatNotice) para que no
# se desincronicen. Solo avisa: sin confirmacion extra ni deteccion de juegos.
Test-SmokeFunction 'NamedProfileEditor' '#87 preview hvci=off: [AVISO] anti-cheat nombra Vanguard y FACEIT, conserva la linea [i] de VBS' {
    [string[]] $lines = Get-NamedProfilePreviewLines -Profile (New-HvciPreviewFixture -Hvci 'off') -MachineProfile (New-HvciPreviewMachine)
    [string[]] $av = @($lines | Where-Object { $_ -like '`[AVISO`]*' -and $_ -match 'Vanguard' -and $_ -match 'FACEIT' })
    if ($av.Count -lt 1) { throw ('falta la linea [AVISO] anti-cheat (Vanguard + FACEIT) en el preview: ' + ($lines -join ' | ')) }
    if (@($lines | Where-Object { $_ -like '`[i`] HVCI off*VBS se preserva*' }).Count -ne 1) { throw 'se perdio la linea [i] HVCI off / VBS se preserva' }
    foreach ($l in $lines) {
        foreach ($ch in $l.ToCharArray()) {
            if ([int] $ch -gt 127) { throw ('preview con caracter no-ASCII U+{0:X4}: {1}' -f [int] $ch, $l) }
        }
    }
}
Test-SmokeFunction 'NamedProfileEditor' '#87 preview hvci=on o ausente: SIN aviso anti-cheat' {
    foreach ($v in @('on', '')) {
        [string[]] $lines = Get-NamedProfilePreviewLines -Profile (New-HvciPreviewFixture -Hvci $v) -MachineProfile (New-HvciPreviewMachine)
        if (@($lines | Where-Object { $_ -match 'anti-cheat|Vanguard|FACEIT' }).Count -ne 0) {
            throw ("hvci='{0}': el preview avisa anti-cheat sin apagar HVCI: {1}" -f $v, ($lines -join ' | '))
        }
    }
}
Test-SmokeFunction 'NamedProfileEditor' '#87 una sola fuente: [A][12] y el preview muestran Get-HvciAntiCheatNotice' {
    [string[]] $notice = @(Get-HvciAntiCheatNotice)
    if ($notice.Count -lt 3) { throw ('Get-HvciAntiCheatNotice devolvio {0} lineas, esperaba 3' -f $notice.Count) }
    if (($notice -join ' ') -notmatch 'Vanguard' -or ($notice -join ' ') -notmatch 'FACEIT') { throw 'el texto compartido no nombra Vanguard/FACEIT' }
    $r12 = Invoke-HvciAntiCheatHarness -Answers @('D', 'N', 'S', 'S')
    [string] $prev = (Get-NamedProfilePreviewLines -Profile (New-HvciPreviewFixture -Hvci 'off') -MachineProfile (New-HvciPreviewMachine)) -join "`n"
    foreach ($l in $notice) {
        if (-not $r12.Text.Contains($l)) { throw ('[A][12] no muestra la linea compartida: ' + $l) }
        if (-not $prev.Contains($l))     { throw ('el preview no muestra la linea compartida: ' + $l) }
    }
    # Diente estructural: el texto vive en UN archivo. Si alguien lo re-pega inline en
    # el [12] o en el preview, las dos copias se pueden desincronizar.
    [string] $root = Split-Path -Parent $PSScriptRoot
    [string[]] $con = @(foreach ($d in @('core', 'modules', 'utils')) {
        Get-ChildItem -LiteralPath (Join-Path $root $d) -Filter '*.ps1' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'BattlEye' } |
            ForEach-Object { $_.Name }
    })
    if ($con.Count -ne 1) { throw ('el texto anti-cheat (BattlEye) esta en {0} archivos, esperaba 1: {1}' -f $con.Count, ($con -join ', ')) }
}

# Handler [2] (Invoke-NamedProfileMenu): el preview con el aviso se muestra ANTES de
# aplicar, tanto al crear la receta ([1]) como al cargar una guardada ([2]) o
# reaplicar la ultima ([3]): un hvci=off puede venir del JSON, no solo del preset.
# Corre el HANDLER real; se sombrean el menu, el editor/IO, la mutacion
# (Invoke-NamedProfile solo registra) y los renderers.
function Invoke-NamedHvciHarness {
    param([string] $Choice, [bool] $Confirm)
    $script:NhEv  = [System.Collections.Generic.List[string]]::new()
    $script:NhCfm = $Confirm
    $script:NhProf = New-HvciPreviewFixture -Hvci 'off'
    function Read-PctkMenuChoice { param($Rows, $RenderHeader) return $Choice }
    function Read-Host { param([object] $Prompt) return '1' }
    function Confirm-Action {
        param([string] $Title, [string[]] $Lines = @(), [bool] $DefaultYes = $true)
        $script:NhEv.Add(('confirm:{0}|{1}' -f $Title, ($Lines -join "`n")))
        if (@($Lines).Count -eq 0) { return $true }   # preset gaming / aplicar ahora / RP gate
        return $script:NhCfm
    }
    function New-NamedProfileInteractive { param($MachineProfile, [switch] $UseGamingPreset) return $script:NhProf }
    function Save-NamedProfile { param($Profile, $Slug) $script:NhEv.Add('save'); return 'C:\pctk-fake\receta.json' }
    function Get-NamedProfileList {
        @([PSCustomObject]@{ Name = 'Receta X'; Path = 'C:\pctk-fake\receta.json'; IsSample = $false; LastApplied = '2026-01-01T00:00:00' })
    }
    function Import-NamedProfile { param($Path) return $script:NhProf }
    function Invoke-NamedProfile { $script:NhEv.Add('apply'); [PSCustomObject]@{ NamedStatus = 'Success'; RebootNeeded = $false; ClientRun = $null } }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:NhEv.Add('audit:' + $Status) }
    function Write-Host { }
    function Write-PctkLine { param([AllowEmptyString()][string] $Text, $Kind) }
    function Write-PctkWarn { param([AllowEmptyString()][string] $Text) }
    function Write-PctkHint { param([AllowEmptyString()][string] $Text) }
    function Write-PctkWork { param([AllowEmptyString()][string] $Text) }
    function Write-PctkOk   { param([AllowEmptyString()][string] $Text) }
    function Write-PctkErr  { param([AllowEmptyString()][string] $Text) }
    Invoke-NamedProfileMenu -MachineProfile (New-HvciPreviewMachine) | Out-Null
    return @($script:NhEv)
}
# Test-SmokeFunction corre el bloque en el acto: $nhCase se lee con el valor de la vuelta.
foreach ($nhCase in @('1', '2', '3')) {
    Test-SmokeFunction 'NamedProfileEditor' ('#87 handler [2] opcion {0}: el aviso anti-cheat se confirma ANTES de aplicar hvci=off' -f $nhCase) {
        $ev = @(Invoke-NamedHvciHarness -Choice $nhCase -Confirm $true)
        [int] $iAviso = -1; [int] $iApply = -1
        for ([int] $i = 0; $i -lt $ev.Count; $i++) {
            if ($iAviso -lt 0 -and $ev[$i] -like 'confirm:*' -and $ev[$i] -match '\[AVISO\][^\n]*Vanguard') { $iAviso = $i }
            if ($iApply -lt 0 -and $ev[$i] -eq 'apply') { $iApply = $i }
        }
        if ($iApply -lt 0) { throw ('no aplico la receta confirmada: ' + ($ev -join ' || ')) }
        if ($iAviso -lt 0) { throw ('se aplico hvci=off sin el aviso anti-cheat en ningun Confirm-Action: ' + ($ev -join ' || ')) }
        if ($iAviso -gt $iApply) { throw 'el aviso anti-cheat aparecio DESPUES de aplicar' }
        $evN = @(Invoke-NamedHvciHarness -Choice $nhCase -Confirm $false)
        if ($evN -contains 'apply') { throw 'cancelando el preview igual aplico la receta' }
    }
}
Test-SmokeFunction 'Router' 'handler [13] HAGS routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'13'\s*\{\s*Invoke-ActionHags") { throw 'dispatch no rutea [13] -> Invoke-ActionHags' }
    function Read-Host { '' }
    Invoke-ActionHags -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [14] TimerResolution routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'14'\s*\{\s*Invoke-ActionTimerResolution") { throw 'dispatch no rutea [14] -> Invoke-ActionTimerResolution' }
    function Read-Host { '' }
    Invoke-ActionTimerResolution -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [15] ProcessPriority routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'15'\s*\{\s*Invoke-ActionProcessPriority") { throw 'dispatch no rutea [15] -> Invoke-ActionProcessPriority' }
    function Read-Host { '' }
    Invoke-ActionProcessPriority -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [16] UsbPower routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'16'\s*\{\s*Invoke-ActionUsbPower") { throw 'dispatch no rutea [16] -> Invoke-ActionUsbPower' }
    function Read-Host { '' }
    Invoke-ActionUsbPower -MachineProfile (Get-MachineProfile) | Out-Null
}
# Guard estructural del fix del gate #11: las 3 funciones de UsbPower que llaman
# powercfg (nativo) deben neutralizar EAP localmente, o crashean bajo main.ps1
# (EAP=Stop). El smoke no puede reproducir la mutacion sin mutar; este guard
# evita que el fix se borre en silencio.
Test-SmokeFunction 'UsbPower' 'powercfg EAP-guarded (regresion gate #11)' {
    foreach ($fn in @('Get-UsbSelectiveSuspendStatus','Disable-UsbSelectiveSuspend','Enable-UsbSelectiveSuspend')) {
        $def = (Get-Command $fn -CommandType Function).Definition
        if ($def -notmatch "ErrorActionPreference\s*=\s*'Continue'") {
            throw ("$fn no neutraliza EAP=Stop; powercfg crashearia bajo main.ps1 (ver gate #11)")
        }
    }
}

# ─── #78 Energia: PERFBOOSTMODE / PROCTHROTTLEMIN / MMAgent / SysMain ─────────
# Fixtures de powercfg /qh REALES (es-AR, captura 13-10-2026): el parseo es por
# posicion del hex, no por el texto "corriente alterna". El rango min/max/incr
# de PROCTHROTTLEMIN tambien trae 0x: los ultimos DOS son AC y DC.
$script:EnergyFixtureBoostEs = @(
    'GUID de plan de energia: 381b4222-f694-41f0-9685-ff5bb260df2e  (Equilibrado)'
    '    Alias de GUID: PERFBOOSTMODE'
    '      Indice de configuracion posible: 002'
    '      Nombre descriptivo de configuracion posible: Agresiva'
    '    Indice de configuracion de corriente alterna actual: 0x00000004'
    '    Indice de configuracion de corriente continua actual: 0x00000000'
) -join "`n"
$script:EnergyFixtureThrottleEs = @(
    '    Alias de GUID: PROCTHROTTLEMIN'
    '      Minima configuracion posible: 0x00000000'
    '      Maxima configuracion posible: 0x00000064'
    '      Incremento de configuracion posible: 0x00000001'
    '    Indice de configuracion de corriente alterna actual: 0x00000005'
    '    Indice de configuracion de corriente continua actual: 0x0000000a'
) -join "`n"

Test-SmokeFunction 'EnergyTuning' 'ConvertFrom-PowercfgQhIndices: es-AR por posicion (boost 4/0, throttle 5/10)' {
    $b = ConvertFrom-PowercfgQhIndices -Text $script:EnergyFixtureBoostEs
    if ($b.Ac -ne 4 -or $b.Dc -ne 0) { throw ('boost: AC={0} DC={1}' -f $b.Ac, $b.Dc) }
    $t = ConvertFrom-PowercfgQhIndices -Text $script:EnergyFixtureThrottleEs
    if ($t.Ac -ne 5 -or $t.Dc -ne 10) { throw ('throttle: AC={0} DC={1} (el rango min/max/incr no debe contar)' -f $t.Ac, $t.Dc) }
}
Test-SmokeFunction 'EnergyTuning' 'ConvertFrom-PowercfgQhIndices: en-US igual y basura/vacio -> $null' {
    $en = "  Current AC Power Setting Index: 0x00000002`n  Current DC Power Setting Index: 0x00000001"
    $r = ConvertFrom-PowercfgQhIndices -Text $en
    if ($r.Ac -ne 2 -or $r.Dc -ne 1) { throw 'en-US mal parseado' }
    foreach ($bad in @('', 'No se encontro el setting', $null)) {
        $x = ConvertFrom-PowercfgQhIndices -Text $bad
        if ($null -ne $x.Ac -or $null -ne $x.Dc) { throw 'basura debe dar $null' }
    }
}
Test-SmokeFunction 'EnergyTuning' 'Get-MMAgentState: Get-MMAgent falla -> Available=false, no revienta' {
    function Get-MMAgent { throw 'Acceso denegado (simulado)' }
    $r = Get-MMAgentState
    if ($r.Available -or $null -ne $r.MemoryCompression) { throw 'debia quedar no disponible' }
}
Test-SmokeFunction 'EnergyTuning' 'Get-MMAgentState: lee MemoryCompression y ApplicationLaunchPrefetching' {
    function Get-MMAgent { [PSCustomObject]@{ MemoryCompression = $true; ApplicationLaunchPrefetching = $false } }
    $r = Get-MMAgentState
    if (-not $r.Available -or $r.MemoryCompression -ne $true -or $r.ApplicationLaunchPrefetching -ne $false) { throw 'MMAgent mal leido' }
}
Test-SmokeFunction 'EnergyTuning' 'Get-EnergyTuningState: powercfg es-AR + MMAgent caido + SysMain (1 servicio)' {
    function powercfg {
        if ($args -contains 'be337238-0d82-4146-a960-4f3749d470c7') { return $script:EnergyFixtureBoostEs -split "`n" }
        return $script:EnergyFixtureThrottleEs -split "`n"
    }
    function Get-MMAgent { throw 'sin admin' }
    function Get-Service { [PSCustomObject]@{ Name = 'SysMain'; Status = 'Running'; StartType = 'Automatic' } }
    $s = Get-EnergyTuningState
    if ($s.PerfBoostModeAc -ne 4 -or $s.ProcThrottleMinAc -ne 5 -or $s.ProcThrottleMinDc -ne 10) { throw 'valores powercfg' }
    if ($s.MmAgentAvailable) { throw 'MMAgent debia ser no disponible' }
    if ($s.SysMainStatus -ne 'Running' -or $s.SysMainStartType -ne 'Automatic') { throw 'SysMain' }
}
Test-SmokeFunction 'EnergyTuning' 'el snapshot lleva el campo Energy' {
    $def = (Get-Command Get-SystemSnapshot -CommandType Function).Definition
    if ($def -notmatch 'Energy\s*=\s*\$energy') { throw 'Get-SystemSnapshot no devuelve Energy' }
}
Test-SmokeFunction 'EnergyTuning' 'Get-EnergyTuningState DENTRO de un Start-Job real (como Start-TelemetryJob): GUIDs resuelven (#78 ronda 2)' {
    # Mismo patron que Start-TelemetryJob: runspace fresco, StrictMode Latest, dot-source
    # de Telemetry.ps1. El powercfg falso vive DENTRO del job y devuelve el fixture es-AR
    # SOLO si recibe SUB_PROCESSOR + el GUID del setting: un $script: sin resolver o un
    # GUID mal escrito da texto de error -> PerfBoostModeAc $null -> el test falla.
    $modPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Telemetry.ps1'
    $j = Start-Job -ScriptBlock {
        param([string] $ModPath, [string] $FixBoost, [string] $FixThr)
        Set-StrictMode -Version Latest
        . $ModPath
        function powercfg {
            $a = @($args | ForEach-Object { [string] $_ })
            $okSub = $a -contains '54533251-82be-4824-96c1-47b60b740d00'
            if ($okSub -and ($a -contains 'be337238-0d82-4146-a960-4f3749d470c7')) { return ($FixBoost -split "`n") }
            if ($okSub -and ($a -contains '893dee8e-2bef-41e0-89c6-b55d0929964c')) { return ($FixThr -split "`n") }
            return @('Argumentos no validos: ' + ($a -join ' '))
        }
        Get-EnergyTuningState
    } -ArgumentList @($modPath, $script:EnergyFixtureBoostEs, $script:EnergyFixtureThrottleEs)
    try {
        if (-not (Wait-Job $j -Timeout 120)) { throw 'el job no termino en 120 s' }
        $s = Receive-Job $j -ErrorAction Stop
    } finally { Remove-Job $j -Force -ErrorAction SilentlyContinue }
    if ($null -eq $s) { throw 'el job no devolvio estado' }
    if ($null -eq $s.PerfBoostModeAc) { throw 'PerfBoostModeAc $null dentro del job (GUID/$script: sin resolver)' }
    if ($s.PerfBoostModeAc -ne 4 -or $s.PerfBoostModeDc -ne 0) { throw ('boost AC={0} DC={1}' -f $s.PerfBoostModeAc, $s.PerfBoostModeDc) }
    if ($s.ProcThrottleMinAc -ne 5 -or $s.ProcThrottleMinDc -ne 10) { throw ('throttle AC={0} DC={1}' -f $s.ProcThrottleMinAc, $s.ProcThrottleMinDc) }
}
Test-SmokeFunction 'EnergyTuning' 'powercfg EAP-guarded en las funciones nativas (#78)' {
    foreach ($fn in @('Get-ProcessorPowerSetting','Show-PerfBoostModeSetting','Set-ProcessorAcValue','Enable-LaptopGamingEnergy','Restore-LaptopGamingEnergy')) {
        $def = (Get-Command $fn -CommandType Function).Definition
        if ($def -notmatch "ErrorActionPreference\s*=\s*'Continue'") { throw "$fn no neutraliza EAP=Stop" }
    }
}

# Handler [A][20]: powercfg falso CON ESTADO (AC por setting), Read-Host/Confirm
# guionados, respaldo a un temp. Se llama al HANDLER, no a Enable-/Restore-.
function Invoke-EnergyHandlerHarness {
    param([string] $Answer, [bool] $IsLaptop, [bool] $Confirm = $true, [hashtable] $Start = @{ Boost = 2; Thr = 70 })
    $script:EhState = @{ Boost = $Start.Boost; Thr = $Start.Thr; Calls = [System.Collections.Generic.List[string]]::new() }
    $script:EhBak = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-energy-' + [guid]::NewGuid().ToString('N') + '.json')
    if ($Start.ContainsKey('Backup')) { $Start.Backup | ConvertTo-Json | Out-File -LiteralPath $script:EhBak -Encoding UTF8 }
    $script:EhAnswer = $Answer; $script:EhConfirm = $Confirm
    function Get-EnergyBackupPath { $script:EhBak }
    function Read-Host { $script:EhAnswer }
    function Confirm-Action { $script:EhConfirm }
    # Show-OrphanModuleResult es el REAL (ahi vivio el bug de .Count, ronda 4); se captura lo que le pasa a la auditoria.
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:EhStatus = $Status; if ($null -ne $Details) { $script:EhResult = $Details } }
    function Get-MMAgent { throw 'sin admin' }
    function powercfg {
        $script:EhState.Calls.Add(($args -join ' '))
        $a = @($args)
        if ($a[0] -eq '/qh') {
            $isBoost = ($a -contains 'be337238-0d82-4146-a960-4f3749d470c7')
            $v = if ($isBoost) { $script:EhState.Boost } else { $script:EhState.Thr }
            return @(('    Indice de configuracion de corriente alterna actual: 0x{0:x8}' -f $v), '    Indice de configuracion de corriente continua actual: 0x00000000')
        }
        if ($a[0] -eq '/SETACVALUEINDEX') {
            if ($a[3] -eq 'be337238-0d82-4146-a960-4f3749d470c7') { $script:EhState.Boost = [int]$a[4] } else { $script:EhState.Thr = [int]$a[4] }
        }
        $global:LASTEXITCODE = 0
    }
    $script:EhResult = $null; $script:EhStatus = $null
    $prof = [PSCustomObject]@{ IsLaptop = $IsLaptop }
    Invoke-ActionEnergyLaptop -MachineProfile $prof | Out-Null
    return $script:EhState
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: dispatch ruteado' {
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'20'\s*\{\s*Invoke-ActionEnergyLaptop") { throw 'dispatch no rutea [20]' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: NO laptop -> A no muta nada (no se ofrece)' {
    $st = Invoke-EnergyHandlerHarness -Answer 'A' -IsLaptop $false
    if (@($st.Calls | Where-Object { $_ -match 'SETACVALUEINDEX' }).Count -ne 0) { throw 'muto en un no-laptop' }
    if ($st.Boost -ne 2 -or $st.Thr -ne 70) { throw 'cambio el estado' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: laptop + A + confirma -> boost 4, thr 5, respaldo con los previos' {
    $st = Invoke-EnergyHandlerHarness -Answer 'A' -IsLaptop $true
    if ($st.Boost -ne 4 -or $st.Thr -ne 5) { throw ('AC final boost={0} thr={1}' -f $st.Boost, $st.Thr) }
    if (-not (Test-Path -LiteralPath $script:EhBak)) { throw 'sin respaldo' }
    $b = Get-Content -LiteralPath $script:EhBak -Raw | ConvertFrom-Json
    if ($b.PerfBoostModeAc -ne 2 -or $b.ProcThrottleMinAc -ne 70) { throw 'respaldo no tiene los valores previos' }
    if (-not $script:EhResult.Success) { throw 'Result.Success=false' }
    Remove-Item -LiteralPath $script:EhBak -Force
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: no confirma -> no muta ni respalda' {
    $st = Invoke-EnergyHandlerHarness -Answer 'A' -IsLaptop $true -Confirm $false
    if (@($st.Calls | Where-Object { $_ -match 'SETACVALUEINDEX' }).Count -ne 0) { throw 'muto sin confirmar' }
    if (Test-Path -LiteralPath $script:EhBak) { throw 'creo respaldo sin confirmar' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: R restaura el respaldo y lo borra' {
    $st = Invoke-EnergyHandlerHarness -Answer 'R' -IsLaptop $true -Start @{ Boost = 4; Thr = 5; Backup = @{ PerfBoostModeAc = 3; ProcThrottleMinAc = 40 } }
    if ($st.Boost -ne 3 -or $st.Thr -ne 40) { throw ('restaurado boost={0} thr={1}' -f $st.Boost, $st.Thr) }
    if (Test-Path -LiteralPath $script:EhBak) { throw 'el respaldo no se borro' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: R sin respaldo -> boost 2, thr intacto, avisa' {
    $st = Invoke-EnergyHandlerHarness -Answer 'R' -IsLaptop $true -Start @{ Boost = 4; Thr = 5 }
    if ($st.Boost -ne 2) { throw "boost=$($st.Boost)" }
    if ($st.Thr -ne 5) { throw 'toco PROCTHROTTLEMIN sin respaldo' }
    if ($script:EhResult.Reason -notmatch 'Sin respaldo') { throw 'no aviso la falta de respaldo' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: M des-oculta PERFBOOSTMODE sin cambiar valores (cualquier chassis)' {
    $st = Invoke-EnergyHandlerHarness -Answer 'M' -IsLaptop $false
    if (@($st.Calls | Where-Object { $_ -match '^-attributes SUB_PROCESSOR PERFBOOSTMODE -ATTRIB_HIDE$' }).Count -ne 1) { throw 'no llamo -ATTRIB_HIDE' }
    if (@($st.Calls | Where-Object { $_ -match 'SETACVALUEINDEX' }).Count -ne 0) { throw 'cambio valores' }
}
Test-SmokeFunction 'EnergyTuning' 'handler [A][20]: M pasa por el reporte real sin romper' {
    $st = Invoke-EnergyHandlerHarness -Answer 'M' -IsLaptop $true
    if ($script:EhStatus -ne 'Success') { throw ('audit final Status={0}' -f $script:EhStatus) }
    if (@($script:EhResult.Applied).Count -ne 1 -or @($script:EhResult.Errors).Count -ne 0) { throw 'Applied/Errors no son arrays' }
    if ($script:EhResult.Applied -isnot [array] -or $script:EhResult.Errors -isnot [array]) { throw 'Applied/Errors desenrollados' }
}
Test-SmokeFunction 'EnergyTuning' 'la opcion laptop gaming NO esta en el engine ni en Performance (nunca en el [1])' {
    $root = Split-Path -Parent $PSScriptRoot
    foreach ($f in @('core\ProfileEngine.ps1', 'modules\Performance.ps1')) {
        if ((Get-Content -LiteralPath (Join-Path $root $f) -Raw) -match 'LaptopGamingEnergy|PERFBOOSTMODE') { throw "$f menciona la opcion mutante" }
    }
}

# Comparacion PRE/POST con Energy (#78 ronda 3). Se llama al HANDLER del menu
# (Invoke-DiagnosticCompare) con Compare-Snapshot y Show-SnapshotComparison REALES
# sobre snapshots JSON en un temp; solo se shadowean la salida (se captura el texto)
# y la auditoria. $script:TelemetryModulePath apunta al temp para que
# Compare-Snapshot lea de ahi, y se restaura en el finally.
function Invoke-EnergyCompareHarness {
    param([hashtable] $PreEnergy, [hashtable] $PostEnergy)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-cmp-' + [guid]::NewGuid().ToString('N'))
    $snapDir = Join-Path $root 'output\snapshots'
    $null = New-Item -ItemType Directory -Path $snapDir -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'modules') -Force
    foreach ($ph in @('pre', 'post')) {
        $snap = [ordered]@{
            Timestamp         = '2026-10-13T10:00:00'
            ComputerName      = 'PC-TEST'
            UptimeHours       = 5.0
            Volumes           = @(@{ Letter = 'C'; FreeGb = 50.0; UsedPct = 50.0 })
            Services          = @{ RunningCount = 100; BloatRunning = @() }
            StartupCount      = 10
            Battery           = $null
            MultipleAvProblem = $false
        }
        $en = $PreEnergy
        if ($ph -eq 'post') { $en = $PostEnergy }
        if ($null -ne $en) { $snap['Energy'] = $en }
        $snap | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $snapDir ('2026-10-13_100000_' + $ph + '.json')) -Encoding UTF8
    }
    $script:EcOut = [System.Collections.Generic.List[string]]::new()
    $script:EcAudit = [System.Collections.Generic.List[string]]::new()
    function Write-PctkLine { $script:EcOut.Add(($args -join ' ')) }
    function Write-PctkHint { $script:EcOut.Add(($args -join ' ')) }
    function Write-PctkSection { $script:EcOut.Add(($args -join ' ')) }
    function Write-PctkOk { $script:EcOut.Add(($args -join ' ')) }
    function Write-PctkWarn { $script:EcOut.Add(($args -join ' ')) }
    function Write-PctkActionTitle { $script:EcOut.Add(($args -join ' ')) }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:EcAudit.Add(('{0}|{1}|{2}' -f $Action, $Status, $Summary)) }
    $oldPath = $script:TelemetryModulePath
    try {
        $script:TelemetryModulePath = Join-Path $root 'modules\Telemetry.ps1'
        Invoke-DiagnosticCompare -MachineProfile ([PSCustomObject]@{ IsLaptop = $true }) | Out-Null
    } finally {
        $script:TelemetryModulePath = $oldPath
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [PSCustomObject]@{ Text = ($script:EcOut -join "`n"); Audit = @($script:EcAudit) }
}
$script:EcPreEn  = @{ PerfBoostModeAc = 2; ProcThrottleMinAc = 70; MemoryCompression = $true; ApplicationLaunchPrefetching = $true; SysMainStatus = 'Running'; SysMainStartType = 'Automatic' }
$script:EcPostEn = @{ PerfBoostModeAc = 4; ProcThrottleMinAc = 5;  MemoryCompression = $true; ApplicationLaunchPrefetching = $null; SysMainStatus = 'Running'; SysMainStartType = 'Automatic' }
Test-SmokeFunction 'EnergyTuning' 'comparacion PRE/POST (handler): ambos con Energy -> filas de energia con pre -> post' {
    $r = Invoke-EnergyCompareHarness -PreEnergy $script:EcPreEn -PostEnergy $script:EcPostEn
    if (@($r.Audit | Where-Object { $_ -match '^Snapshot\.Compare\|Success\|' }).Count -ne 1) { throw ('el handler no termino en Success: ' + ($r.Audit -join ' ; ')) }
    foreach ($want in @('[ENERGIA]', 'Boost CPU (AC): 2 -> 4', 'Throttle minimo (AC): 70% -> 5%', 'Compresion de memoria: si -> si', 'Prefetch de aplicaciones: si -> no disponible', 'SysMain: Running / Automatic -> Running / Automatic')) {
        if (-not $r.Text.Contains($want)) { throw ("falta en la salida: '$want'") }
    }
}
Test-SmokeFunction 'EnergyTuning' 'comparacion PRE/POST (handler): PRE viejo SIN Energy + POST nuevo no rompe (StrictMode) y marca sin dato' {
    $r = Invoke-EnergyCompareHarness -PreEnergy $null -PostEnergy $script:EcPostEn
    if (@($r.Audit | Where-Object { $_ -match '^Snapshot\.Compare\|Success\|' }).Count -ne 1) { throw ('el handler fallo con PRE sin Energy: ' + ($r.Audit -join ' ; ')) }
    foreach ($want in @('[ENERGIA]', 'Boost CPU (AC): sin dato -> 4', 'SysMain: sin dato -> Running / Automatic')) {
        if (-not $r.Text.Contains($want)) { throw ("falta en la salida: '$want'") }
    }
    if ($r.Text -match 'sin dato -> 4.*\[i\]|\[i\][^\n]*sin dato') { throw 'un lado sin dato se marco como cambio' }
}
Test-SmokeFunction 'EnergyTuning' 'comparacion PRE/POST (handler): los dos snapshots viejos SIN Energy no rompen' {
    $r = Invoke-EnergyCompareHarness -PreEnergy $null -PostEnergy $null
    if (@($r.Audit | Where-Object { $_ -match '^Snapshot\.Compare\|Success\|' }).Count -ne 1) { throw ('el handler fallo con ambos sin Energy: ' + ($r.Audit -join ' ; ')) }
    foreach ($want in @('[ENERGIA]', 'Boost CPU (AC): sin dato -> sin dato', 'SysMain: sin dato -> sin dato')) {
        if (-not $r.Text.Contains($want)) { throw ("falta en la salida: '$want'") }
    }
}
Test-SmokeFunction 'EnergyTuning' 'Energy NO esta en el reporte de cliente [8] (ClientReport.ps1)' {
    $root = Split-Path -Parent $PSScriptRoot
    if ((Get-Content -LiteralPath (Join-Path $root 'modules\ClientReport.ps1') -Raw) -match '(?i)energy|EnergyDiff|PERFBOOST') { throw 'ClientReport.ps1 menciona Energy' }
}

# Guarda de SysMain (#78): nunca una receta/codigo que lo deshabilite. Escanea
# TODAS las carpetas del producto, no un archivo. Los comentarios no cuentan.
function Get-SysMainDisableHits {
    param([string] $Root)
    $hits = [System.Collections.Generic.List[string]]::new()
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($d in @('modules', 'core', 'utils', 'data')) {
        $p = Join-Path $Root $d
        if (Test-Path -LiteralPath $p) {
            foreach ($f in @(Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object { @('.ps1', '.json', '.psd1', '.cfg', '.bat', '.cmd') -contains $_.Extension })) { $files.Add($f) }
        }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -File | Where-Object { @('.ps1', '.json', '.psd1', '.bat', '.cmd') -contains $_.Extension })) { $files.Add($f) }
    foreach ($f in $files) {
        [string[]] $lines = @()
        if ($f.Extension -eq '.ps1') {
            $tokens = $null; $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
            $byLine = @{}
            foreach ($t in $tokens) {
                if ($t.Kind -eq 'Comment') { continue }
                $ln = $t.Extent.StartLineNumber
                $prev = ''
                if ($byLine.ContainsKey($ln)) { $prev = $byLine[$ln] }
                $byLine[$ln] = ('{0} {1}' -f $prev, $t.Text)
            }
            $lines = @($byLine.Values)
        } else {
            $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
        }
        foreach ($l in $lines) {
            if ($l -match '(?i)sysmain' -and $l -match '(?i)disabled') {
                $hits.Add(('{0}: {1}' -f $f.FullName, $l.Trim()))
            }
        }
    }
    return $hits.ToArray()
}
Test-SmokeFunction 'EnergyTuning' 'guarda SysMain: ninguna receta ni codigo del producto lo deshabilita' {
    $root = Split-Path -Parent $PSScriptRoot
    [string[]] $hits = @(Get-SysMainDisableHits -Root $root)
    if ($hits.Count -ne 0) { throw ('SysMain deshabilitado en: ' + ($hits -join ' | ')) }
}
Test-SmokeFunction 'EnergyTuning' 'guarda SysMain: probada por mutacion (JSON y .ps1 cazan; comentario no)' {
    $root = Split-Path -Parent $PSScriptRoot
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-sysmain-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'data\profiles\auto') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'modules') -Force
        Copy-Item -Path (Join-Path $root 'data\profiles\auto\*.json') -Destination (Join-Path $tmp 'data\profiles\auto') -Force
        if (@(Get-SysMainDisableHits -Root $tmp).Count -ne 0) { throw 'base de la mutacion no esta limpia' }
        Set-Content -LiteralPath (Join-Path $tmp 'modules\c.ps1') -Value '# nunca: Set-Service SysMain -StartupType Disabled' -Encoding UTF8
        if (@(Get-SysMainDisableHits -Root $tmp).Count -ne 0) { throw 'conto un comentario' }
        Set-Content -LiteralPath (Join-Path $tmp 'data\profiles\auto\mutante.json') -Value '{ "service": "SysMain", "start": "Disabled" }' -Encoding UTF8
        if (@(Get-SysMainDisableHits -Root $tmp).Count -ne 1) { throw 'no cazo la mutacion en JSON' }
        Set-Content -LiteralPath (Join-Path $tmp 'modules\m.ps1') -Value 'Set-Service -Name SysMain -StartupType Disabled' -Encoding UTF8
        if (@(Get-SysMainDisableHits -Root $tmp).Count -ne 2) { throw 'no cazo la mutacion en .ps1' }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta timer_resolution=on' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'timer_resolution' -NotePropertyValue 'on' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta process_priority valido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $pp = [PSCustomObject]@{}
    $pp | Add-Member -NotePropertyName 'game.exe' -NotePropertyValue 'High' -Force
    $p.gaming_tweaks | Add-Member -NotePropertyName 'process_priority' -NotePropertyValue $pp -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta sin timer_resolution ni process_priority' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza timer_resolution invalido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'timer_resolution' -NotePropertyValue 'maybe' -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar timer_resolution=maybe' }
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza process_priority clase invalida' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $pp = [PSCustomObject]@{}
    $pp | Add-Member -NotePropertyName 'game.exe' -NotePropertyValue 'Realtime' -Force
    $p.gaming_tweaks | Add-Member -NotePropertyName 'process_priority' -NotePropertyValue $pp -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar process_priority clase=Realtime' }
}

# ─── Stage 4.2-C: Steam-autodetect read-only ────────────────────────────────
Test-SmokeFunction 'NamedProfileEditor' 'Get-SteamLibraryPaths no-throw devuelve array' {
    [string[]] $r = @(Get-SteamLibraryPaths)
    if ($null -eq $r) { throw 'Get-SteamLibraryPaths retorno $null (esperado array, posiblemente vacio)' }
}

# ─── Progress UX: Wait-ToolkitJobs sin -ShowProgress (R3 opt-IN) ─────────────
# Verifica que Wait-ToolkitJobs SIN -ShowProgress sobre un job trivial devuelve
# array y no throw. No valida la UX visual (eso es Sandbox/Opus).
Test-SmokeFunction 'JobManager' 'Wait-ToolkitJobs no-ShowProgress devuelve array' {
    $j = Start-Job -ScriptBlock { 'ok' }
    $arr = Wait-ToolkitJobs -Jobs @($j) -TimeoutSeconds 10
    if ($null -eq $arr) { throw 'Wait-ToolkitJobs retorno $null (esperado array)' }
    if ($arr.Count -lt 1) { throw ('Array vacio; esperado Count>=1; Count={0}' -f $arr.Count) }
}

# ─── Progress UX extension: Invoke-JobWithProgress (wrapper acciones sueltas) ─
# Verifica que el wrapper devuelve array y no throw sobre un job trivial.
# No valida la UX visual (la barra se suprime en host no interactivo por
# $script:PctkProgressOk; eso es comportamiento correcto en rig).
Test-SmokeFunction 'JobManager' 'Invoke-JobWithProgress devuelve array sin throw' {
    $j = Start-Job -ScriptBlock { 'ok' }
    $arr = Invoke-JobWithProgress -Jobs @($j) -Activity 'Smoke test' -TimeoutSeconds 10
    if ($null -eq $arr) { throw 'Invoke-JobWithProgress retorno $null (esperado array)' }
    if ($arr.Count -lt 1) { throw ('Array vacio; esperado Count>=1; Count={0}' -f $arr.Count) }
}

# ─── Stage 4.2-B: NvidiaTweaks (read-only, no aplica nada) ──────────────────
Test-SmokeFunction 'NvidiaTweaks' 'Get-NvidiaSysmemStatus no throw' {
    Get-NvidiaSysmemStatus
}
Test-SmokeFunction 'NvidiaTweaks' 'Get-NvidiaSysmemStatus shape' {
    $s = Get-NvidiaSysmemStatus
    foreach ($f in @('IsNvidiaDedicated','Enabled','Reason')) {
        if ($null -eq $s.PSObject.Properties[$f]) {
            throw "Campo $f ausente en Get-NvidiaSysmemStatus"
        }
    }
}
Test-SmokeFunction 'NvidiaTweaks' 'Test-NvidiaInspectorAvailable no throw' {
    Test-NvidiaInspectorAvailable
}
Test-SmokeFunction 'NvidiaTweaks' 'New-NvidiaSysmemNip formato real' {
    [string] $pn = New-NvidiaSysmemNip -State prefer_no
    [string] $df = New-NvidiaSysmemNip -State default
    foreach ($xml in @($pn, $df)) {
        if ($xml -notmatch '<ArrayOfProfile>')                                              { throw 'Falta <ArrayOfProfile>' }
        if ($xml -notmatch '<SettingID>283962569</SettingID>')                              { throw 'Falta SettingID 283962569' }
        if ($xml -notmatch '<SettingNameInfo>CUDA Sysmem Fallback Policy</SettingNameInfo>'){ throw 'Falta SettingNameInfo CUDA Sysmem Fallback Policy' }
        if ($xml -notmatch '<ValueType>Dword</ValueType>')                                  { throw 'Falta ValueType Dword' }
        if ($xml -match 'NvidiaInspectorProfile')                                           { throw 'Contiene schema incorrecto NvidiaInspectorProfile' }
        if ($xml -match '0x00A06871')                                                       { throw 'Contiene ID incorrecto 0x00A06871' }
    }
    if ($pn -notmatch '<SettingValue>1</SettingValue>') { throw 'prefer_no debe tener SettingValue=1' }
    if ($df -notmatch '<SettingValue>0</SettingValue>') { throw 'default debe tener SettingValue=0' }
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta nvidia_sysmem_fallback=prefer_no' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'nvidia_sysmem_fallback' -NotePropertyValue 'prefer_no' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta sin nvidia_sysmem_fallback' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza nvidia_sysmem_fallback invalido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'nvidia_sysmem_fallback' -NotePropertyValue 'maybe' -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar nvidia_sysmem_fallback=maybe' }
}

# ─── DiskHealth (backlog #17): recoleccion read-only + logica de umbral ───────
# Get-DiskHealth lee el sistema real (smoke-safe, timeouts). Get-DiskAlertLevel
# es funcion PURA → se testea la logica de alerta con fixtures, sin depender
# del HW. Incluye la TRAMPA del research (vacio != sano) y el BUG de enum
# cazado en HW (HealthStatus/MediaType vienen como numero, no label).
Test-SmokeFunction 'DiskHealth' 'Get-DiskHealth no throw + shape' {
    $d = Get-DiskHealth
    foreach ($f in @('IsVM','Disks','AlertCount','PredictFailAny','EnumTimedOut')) {
        if ($null -eq $d.PSObject.Properties[$f]) { throw "Campo $f ausente en Get-DiskHealth" }
    }
}
Test-SmokeFunction 'DiskHealth' 'umbral: disco sano -> OK' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 10 -TempC 35
    if ($r.Alert -ne 'OK') { throw "esperado OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'BUG enum: HealthStatus 0 (numero) -> OK no CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus '0' -WearPct 10
    if ($r.Alert -ne 'OK') { throw "enum 0 debe ser Healthy/OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'BUG enum: HealthStatus 2 (numero) -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus '2'
    if ($r.Alert -ne 'CRIT') { throw "enum 2 debe ser Unhealthy/CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'enum: HealthStatus 1 (Warning) -> WARN' {
    $r = Get-DiskAlertLevel -HealthStatus '1'
    if ($r.Alert -ne 'WARN') { throw "enum 1 debe ser Warning/WARN; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'MediaType enum: 4->SSD, 3->HDD, 0->Desconocido' {
    if ((ConvertTo-DiskMediaTypeLabel -Raw '4') -ne 'SSD') { throw '4 debe ser SSD' }
    if ((ConvertTo-DiskMediaTypeLabel -Raw '3') -ne 'HDD') { throw '3 debe ser HDD' }
    if ((ConvertTo-DiskMediaTypeLabel -Raw '0') -ne 'Desconocido') { throw '0 debe ser Desconocido' }
}
Test-SmokeFunction 'DiskHealth' 'umbral: wear critico -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 95
    if ($r.Alert -ne 'CRIT') { throw "esperado CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'umbral: wear warn -> WARN' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 85
    if ($r.Alert -ne 'WARN') { throw "esperado WARN; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'Get-DiskWearLabel: HDD->N/A, SSD 0->sin dato real, SSD N->%' {
    if ((Get-DiskWearLabel -MediaType 'HDD' -WearPct 0)    -notmatch 'N/A')           { throw 'HDD wear deberia ser N/A' }
    if ((Get-DiskWearLabel -MediaType 'HDD' -WearPct 50)   -notmatch 'N/A')           { throw 'HDD 50 deberia ser N/A (mecanico)' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct $null) -ne 'no reportado')       { throw 'SSD null deberia ser no reportado' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct 0)    -notmatch 'sin dato real') { throw 'SSD 0 deberia marcarse sin dato real' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct 42)   -ne '42%')                 { throw 'SSD 42 deberia ser 42%' }
}
Test-SmokeFunction 'DiskHealth' 'umbral: prediccion de falla -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -PredictFail $true
    if ($r.Alert -ne 'CRIT') { throw "esperado CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'TRAMPA: vacio + sin SMART -> UNKNOWN (no OK)' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true
    if ($r.Alert -ne 'UNKNOWN') { throw "campo vacio NO debe ser OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'Healthy + SMART faltante -> OK (Windows dice sano)' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -SmartMissing $true
    if ($r.Alert -ne 'OK') { throw "esperado OK; got $($r.Alert)" }
}
# Bug de campo (HDD lento): el timeout devolvia disco vacio sin distinguirse de
# "no hay disco". El flag TimedOut ahora se propaga; la razon UNKNOWN lo dice.
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: SmartTimedOut + sin base -> UNKNOWN con razon de timeout' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true -SmartTimedOut $true
    if ($r.Alert -ne 'UNKNOWN') { throw "timeout sin base debe ser UNKNOWN; got $($r.Alert)" }
    if (($r.Reasons -join ' ') -notmatch 'tiempo|timeout|lento') { throw "la razon debe indicar timeout; got: $($r.Reasons -join ' | ')" }
}
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: sin timeout, la razon UNKNOWN NO menciona timeout' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true
    if (($r.Reasons -join ' ') -match 'se agoto el tiempo') { throw "sin timeout no debe decir timeout; got: $($r.Reasons -join ' | ')" }
}
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: Healthy + SmartTimedOut -> OK (timeout no degrada salud)' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -SmartMissing $true -SmartTimedOut $true
    if ($r.Alert -ne 'OK') { throw "Healthy con SMART en timeout debe seguir OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'shape disco: SmartTimedOut presente por disco' {
    $d = Get-DiskHealth
    foreach ($disk in @($d.Disks)) {
        if ($null -eq $disk.PSObject.Properties['SmartTimedOut']) { throw 'campo SmartTimedOut ausente en disco' }
    }
}
Test-SmokeFunction 'DiskHealth' 'cableado: menu principal [7] -> Invoke-DiagnosticDiskHealth' {
    if (-not (Get-Command Invoke-DiagnosticDiskHealth -CommandType Function -ErrorAction SilentlyContinue)) { throw 'handler Invoke-DiagnosticDiskHealth ausente' }
    $disp = (Get-Command Invoke-MainMenuDispatch -CommandType Function).Definition
    if ($disp -notmatch "'7'\s*\{\s*Invoke-DiagnosticDiskHealth") { throw 'dispatch principal no rutea [7]' }
}

# ─── Uninstall: New-PctkUninstallScript (read-only, no ejecuta nada) ─────────
Test-SmokeFunction 'Uninstall' 'New-PctkUninstallScript genera contenido esperado' {
    [string] $fakeRoot = 'C:\FakePCTk'
    [int]    $fakePid  = 99999
    [string] $s = New-PctkUninstallScript -InstallRoot $fakeRoot -PctkPid $fakePid
    # 1. Contiene Remove-Item y el root pasado
    if ($s -notmatch 'Remove-Item') { throw 'Script no contiene Remove-Item' }
    if ($s -notmatch [regex]::Escape($fakeRoot)) { throw "Script no contiene el install root '$fakeRoot'" }
    # 2. Limpieza de artefactos temporales PCTk-*
    if ($s -notmatch 'PCTk-\*') { throw "Script no contiene glob PCTk-*" }
    # 3. Espera al PID
    if ($s -notmatch [string]$fakePid) { throw "Script no contiene el PID $fakePid" }
    # 4. Auto-borrado del propio script
    if ($s -notmatch 'PSCommandPath') { throw 'Script no contiene auto-borrado del propio script (PSCommandPath)' }
    # 5. CWD neutral (no bloquear el dir a borrar)
    if ($s -notmatch 'Set-Location') { throw 'Script no contiene Set-Location (CWD neutral)' }
    # 6. Retry loop con verificacion (resuelve race cmd.exe)
    if ($s -notmatch '\$attempt') { throw 'Script no contiene retry loop ($attempt)' }
    if ($s -notmatch 'Start-Sleep -Milliseconds') { throw 'Script no contiene Start-Sleep -Milliseconds (retry delay)' }
    # 7. Log persistente
    if ($s -notmatch '\.log') { throw 'Script no contiene referencia al archivo .log' }
    if ($s -notmatch 'WriteAllLines|WriteLog') { throw 'Script no contiene escritura de log persistente' }
}

# ─── Handlers interactivos del Router: abort-seguro (gap que dejo pasar Bug2) ──
# Bugs 2/3 shippearon porque NINGUN test ejercitaba los handlers interactivos.
# Cada test shadowea Read-Host con un valor que ABORTA en el 1er prompt SIN
# mutar (tokens verificados contra el codigo: '' => break/return temprano).
# Solo handlers con abort-seguro PROBADO; ApplyAutoProfile/NamedProfileMenu se
# excluyen a proposito (flujos multi-prompt que llegan a aplicar -> peligroso
# en smoke que corre en la PC real). Asercion = no-throw (caza crash StrictMode
# en el path interactivo, la familia de Bug2).
Test-SmokeFunction 'RouterInteractive' 'Invoke-ActionStartup abort-seguro no crashea' {
    function Read-Host { '' }   # l.~1122: '' => break, sin Set-StartupEntry
    Invoke-ActionStartup -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'RouterInteractive' 'Invoke-ActionApps abort-seguro no crashea' {
    function Read-Host { '' }   # '' => return tras listar (jobs read-only), sin uninstall
    Invoke-ActionApps -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'RouterInteractive' 'Invoke-ResearchPrompt cancel no crashea' {
    function Read-Host { '' }   # l.324: '' => return ANTES de New-ResearchPrompt
    Invoke-ResearchPrompt -MachineProfile (Get-MachineProfile) | Out-Null
}

# ─── ResearchPrompt: snapshot sparse (regresion proactiva Bug3) ───────────────
# Con el bug original: StrictMode tira "property cannot be found" en el primer
# acceso crudo (ej. $Snapshot.RamSlots[0]). Con el fix: no lanza y Success=$true.
Test-SmokeFunction 'ResearchPrompt' 'New-ResearchPrompt sobrevive snapshot sparse' {
    $snap = [PSCustomObject]@{ CPU = [PSCustomObject]@{ Name = 'x' } }
    $mp   = [PSCustomObject]@{ }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r)    { throw 'New-ResearchPrompt retorno $null' }
    if (-not $r.Success) { throw ('Success=$false; esperado $true') }
}
# Regresion v2.0.2: colecciones de 1 elemento (1 modulo RAM = VM/Sandbox/laptop).
# El hardening v2.0.1 usaba `$x = if(c){@(...)}else{}` -> con 1 elem la
# expresion-if desenrolla el @() a escalar -> .Count PropertyNotFoundStrict.
# La fixture sparse de arriba NO tenia RamSlots, por eso no lo cazaba.
Test-SmokeFunction 'ResearchPrompt' 'New-ResearchPrompt colecciones de 1 elemento' {
    $snap = [PSCustomObject]@{
        CPU      = [PSCustomObject]@{ Name = 'x'; Cores = 4; Threads = 8 }
        RamSlots = @([PSCustomObject]@{ SpeedMhz = 3200 })
        GPU      = @([PSCustomObject]@{ Name = 'g'; Type = 'Dedicated'; DriverVersion = '1' })
        Disks    = @([PSCustomObject]@{ Name = 'd'; SizeGb = 500; MediaType = 'SSD'; HealthStatus = 'OK' })
    }
    $mp = [PSCustomObject]@{ }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r)    { throw 'New-ResearchPrompt retorno $null con colecciones de 1 elemento' }
    if (-not $r.Success) { throw 'Success=$false con colecciones de 1 elemento' }
}

# ─── ConsoleIcon: utils read-only (no llama Set-PctkConsoleIcon en smoke) ─────
Test-SmokeFunction 'ConsoleIcon' 'Set-PctkConsoleIcon presente + asset valido' {
    $cmd = Get-Command 'Set-PctkConsoleIcon' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw 'Set-PctkConsoleIcon no encontrado' }
    [string] $rRoot   = Split-Path -Parent $PSScriptRoot
    [string] $icoPath = Join-Path $rRoot 'assets\pctk.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) { throw "assets\pctk.ico no encontrado en $icoPath" }
    [byte[]] $b = [System.IO.File]::ReadAllBytes($icoPath)
    if ($b[0] -ne 0x00 -or $b[1] -ne 0x00 -or $b[2] -ne 0x01 -or $b[3] -ne 0x00) {
        throw ('Header ICO invalido: {0:X2} {1:X2} {2:X2} {3:X2}' -f $b[0],$b[1],$b[2],$b[3])
    }
}

# ConsoleSetup: QuickEdit off (utils read-only; NO muta la consola en smoke)
Test-SmokeFunction 'ConsoleSetup' 'Disable-PctkQuickEdit + Restore-PctkConsoleMode presentes' {
    foreach ($fn in @('Disable-PctkQuickEdit','Restore-PctkConsoleMode','Set-PctkConsoleSize')) {
        if ($null -eq (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
    }
}
Test-SmokeFunction 'ConsoleSetup' '#46: Set-PctkConsoleSize devuelve bool (antes seteaba y seguia en silencio)' {
    # Estructural, NO invoca la funcion (utils read-only en smoke -- ver el test de
    # arriba). Antes del fix la funcion no declaraba OutputType y en WT se
    # auto-cancelaba sin que nadie se enterara (issue #46). Ahora el caller
    # (main.ps1) tiene que poder leer si el resize realmente llego a $MinHeight.
    $cmd = Get-Command 'Set-PctkConsoleSize' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw 'Set-PctkConsoleSize no encontrado' }
    [bool] $declaraBool = @($cmd.OutputType | Where-Object { $_.Type -eq [bool] }).Count -gt 0
    if (-not $declaraBool) {
        [string[]] $outTypes = @($cmd.OutputType | ForEach-Object { $_.Name })
        throw ('Set-PctkConsoleSize deberia declarar [OutputType([bool])]; declara: {0}' -f ($outTypes -join ', '))
    }
}

# ─── ExportClientLogs (5 casos: empty, only-audit, both, tag-sanitize, collide) ─

Test-SmokeFunction 'ExportClientLogs' 'export-empty: output ausente -> Empty + sin zip' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'Empty') { throw ('Status esperado Empty; got {0}' -f $r.Status) }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw 'No debe haber zip cuando output\ esta ausente' }
    } finally {
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-only-audit: 1 subdir (PS5.1 array) -> zip con solo audit' {
    [string] $tmpOut      = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest     = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir    = Join-Path $tmpOut 'audit'
    [string] $auditFile   = Join-Path $auditDir '2026-05-20.jsonl'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $auditFile -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'Zip no fue creado' }
        if ((Get-Item -LiteralPath $r.ZipPath).Length -eq 0) { throw 'Zip tiene tamanio cero' }
        # Verificar que el zip contiene audit\ pero NO snapshots\
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [object[]] $entries = @()
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) }
        finally { $za.Dispose() }
        [bool] $hasAudit = $false
        [bool] $hasSnaps = $false
        foreach ($e in $entries) {
            if ($e -match '^audit')     { $hasAudit = $true }
            if ($e -match '^snapshots') { $hasSnaps = $true }
        }
        if (-not $hasAudit) { throw 'Zip no contiene audit\' }
        if ($hasSnaps)      { throw 'Zip contiene snapshots\ inesperado (trampa PS5.1 arrays)' }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- P2a: lints AST de producto (tests/lint-ast.ps1, corrible standalone) ---
# Reemplaza al guard viejo atado a Invoke-ExportClientLogs: ese miraba UNA funcion
# y dejo pasar Expand-Archive en Bootstrap-Tools y Launch (E21, #80: el [T]
# revento en el gate v2.10.0). Ahora se le pregunta al arbol entero, por AST.
. (Join-Path $PSScriptRoot 'lint-ast.ps1')
$script:LintAstReport = Get-LintAstReport -RepoRoot $repoRoot

Test-SmokeFunction 'LintAst' 'barre el arbol de producto (piso 40 .ps1, incluye raiz/core/modules/utils/tools)' {
    [string[]] $rels = @(@($script:LintAstReport.Files) | ForEach-Object { $_.Substring($repoRoot.Length + 1) })
    if ($rels.Count -lt 40) { throw ('esperaba >=40 .ps1 de producto; encontro {0}' -f $rels.Count) }
    foreach ($must in @('Launch.ps1', 'Bootstrap-Tools.ps1', 'main.ps1', 'core\', 'modules\', 'utils\', 'tools\')) {
        if (-not @($rels | Where-Object { $_ -eq $must -or $_.StartsWith($must) }).Count) { throw ('el barrido no cubre {0}' -f $must) }
    }
    if (@($rels | Where-Object { $_ -like 'tests\*' }).Count) { throw 'el barrido incluye tests\ (no es producto)' }
}

Test-SmokeFunction 'LintAst' 'ningun Expand-Archive/Compress-Archive en producto (modulo Archive puede no cargar; E21/#80)' {
    [object[]] $h = @($script:LintAstReport.ArchiveHits)
    if ($h.Count -gt 0) {
        throw ('*-Archive en producto (usar System.IO.Compression): {0}' -f (($h | ForEach-Object { '{0}:{1} {2}' -f $_.File, $_.Line, $_.Command }) -join ', '))
    }
}

Test-SmokeFunction 'LintAst' 'APPX: todo *-Appx*Package de producto corre con $ProgressPreference local en SilentlyContinue (#83)' {
    [object[]] $s = @($script:LintAstReport.AppxSites)
    # piso: si el barrido no encuentra ninguno, el guard quedo verde por vacuidad
    if ($s.Count -lt 1) { throw 'el barrido APPX no encontro ningun *-Appx*Package (Invoke-UwpUninstall usa Remove-AppxPackage): guard vacio' }
    [object[]] $h = @($script:LintAstReport.AppxHits)
    if ($h.Count -gt 0) {
        throw ('*-Appx*Package sin $ProgressPreference local en SilentlyContinue antes: {0}' -f (($h | ForEach-Object { '{0}:{1} {2} en {3}' -f $_.File, $_.Line, $_.Command, $_.Function }) -join ', '))
    }
}

Test-SmokeFunction 'LintAst' 'APPX: caza sin-fix, $global:, $script:, asignado despues y en funcion anidada; NO el comentario (mutacion)' {
    $ast = Get-LintAstFromText -Text @'
# Remove-AppxPackage en un comentario no cuenta
function Sin     { Remove-AppxPackage -Package x -ErrorAction Stop }
function Global  { $global:ProgressPreference = 'SilentlyContinue'; Remove-AppxPackage -Package x }
function Script  { $script:ProgressPreference = 'SilentlyContinue'; Add-AppxPackage -Path x }
function Tarde   { Remove-AppxProvisionedPackage -Online -PackageName x; $ProgressPreference = 'SilentlyContinue' }
function Anidada { function Inner { $ProgressPreference = 'SilentlyContinue' }; Remove-AppxPackage -Package x }
function Bien    { $ProgressPreference = 'SilentlyContinue'; Appx\Remove-AppxPackage -Package x }
'@
    [object[]] $s = @(Find-LintAppxSites -Ast $ast -File 'modules\Fx.ps1')
    if ($s.Count -ne 6) { throw ('esperaba 6 sitios (el comentario no cuenta); encontro {0}' -f $s.Count) }
    [string] $bad = (@($s | Where-Object { -not $_.Ok } | ForEach-Object { $_.Function }) -join ',')
    if ($bad -ne 'Sin,Global,Script,Tarde,Anidada') { throw ('hits={0}; esperaba Sin,Global,Script,Tarde,Anidada' -f $bad) }
}

Test-SmokeFunction 'LintAst' 'ningun desenrollado sin @() leido con .Count (E16, StrictMode)' {
    [object[]] $h = @($script:LintAstReport.UnrollHits)
    if ($h.Count -gt 0 -and $script:LintAstReport.UnrollEnforce) {
        throw ('desenrollado sin @(): {0}' -f (($h | ForEach-Object { '{0}:{1} {2} ${3}' -f $_.File, $_.Line, $_.Rule, $_.Variable }) -join ', '))
    }
}

Test-SmokeFunction 'LintAst' 'ARCHIVE: caza el comando en cualquier carpeta y NO los comentarios (mutacion)' {
    [string] $tmp = Join-Path $env:TEMP ('pctk-lintast-' + [guid]::NewGuid().ToString('N'))
    try {
        [void] (New-Item -ItemType Directory -Path (Join-Path $tmp 'modules') -Force)
        [void] (New-Item -ItemType Directory -Path (Join-Path $tmp 'tests') -Force)
        Set-Content -LiteralPath (Join-Path $tmp 'modules\Nuevo.ps1') -Encoding UTF8 -Value @(
            '# Expand-Archive en un comentario no cuenta',
            'function Get-X { Microsoft.PowerShell.Archive\Expand-Archive -Path a.zip -DestinationPath b -Force }')
        Set-Content -LiteralPath (Join-Path $tmp 'tests\T.ps1') -Encoding UTF8 -Value 'Compress-Archive -Path a -DestinationPath b'
        $rep = Get-LintAstReport -RepoRoot $tmp
        [object[]] $h = @($rep.ArchiveHits)
        if ($h.Count -ne 1) { throw ('esperaba 1 hit (el comando calificado de modules\); encontro {0}' -f $h.Count) }
        if ($h[0].File -ne 'modules\Nuevo.ps1' -or $h[0].Line -ne 2) { throw ('hit en lugar equivocado: {0}:{1}' -f $h[0].File, $h[0].Line) }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'LintAst' 'UNROLL: caza el codigo PRE-fix de a0ec87b / 7e33ae6 / f762458 y no el POST-fix' {
    # Extractos literales de `git show <c>^:<archivo>` (pre) y `git show <c>:<archivo>` (post).
    $cases = @(
        @{ C = 'a0ec87b'; Pre = @'
function Get-NormalizedManufacturer {
    param([string] $value)
    $parts = $value.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parts.Count -gt 0) {
        [string] $first = $parts[0].ToLowerInvariant()
    }
}
'@; Post = @'
function Get-NormalizedManufacturer {
    param([string] $value)
    [object[]] $parts = @($value.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -gt 0) {
        [string] $first = $parts[0].ToLowerInvariant()
    }
}
'@ },
        @{ C = '7e33ae6'; Pre = @'
function New-ResearchPrompt {
    $slotsProp = $Snapshot.PSObject.Properties['RamSlots']
    $slotsArr  = if ($null -ne $slotsProp -and $null -ne $slotsProp.Value) { @($slotsProp.Value) } else { $null }
    [string] $slotsCount = if ($null -ne $slotsArr) { [string] $slotsArr.Count } else { '?' }
}
'@; Post = @'
function New-ResearchPrompt {
    $slotsProp = $Snapshot.PSObject.Properties['RamSlots']
    [object[]] $slotsArr = @()
    if ($null -ne $slotsProp -and $null -ne $slotsProp.Value) { $slotsArr = @($slotsProp.Value) }
    [string] $slotsCount = if ($slotsArr.Count -gt 0) { [string] $slotsArr.Count } else { '?' }
}
'@ },
        @{ C = 'f762458'; Pre = @'
function Show-PerfBoostModeSetting {
    [bool] $ok = ($LASTEXITCODE -eq 0)
    return [PSCustomObject]@{
        Success = $ok
        Applied = $(if ($ok) { @('PERFBOOSTMODE visible en Power Options') } else { @() })
        Errors  = $(if ($ok) { @() } else { @("ATTRIB_HIDE exit $LASTEXITCODE") })
    }
}
'@; Post = @'
function Show-PerfBoostModeSetting {
    [int] $exit = $LASTEXITCODE
    [bool] $ok = ($exit -eq 0)
    [string[]] $applied = @()
    [string[]] $errs    = @()
    if ($ok) { $applied = @('PERFBOOSTMODE visible en Power Options') } else { $errs = @("ATTRIB_HIDE exit $exit") }
    return [PSCustomObject]@{
        Success = $ok
        Applied = $applied
        Errors  = $errs
    }
}
'@ }
    )
    foreach ($c in $cases) {
        [object[]] $pre  = @(Find-LintUnrollHits -Ast (Get-LintAstFromText -Text $c.Pre)  -File $c.C)
        [object[]] $post = @(Find-LintUnrollHits -Ast (Get-LintAstFromText -Text $c.Post) -File $c.C)
        if ($pre.Count -eq 0) { throw ('{0}: el lint NO caza el codigo pre-fix' -f $c.C) }
        if ($post.Count -gt 0) { throw ('{0}: el lint marca el codigo YA arreglado ({1})' -f $c.C, $post[0].Text) }
    }
}

Test-SmokeFunction 'LintAst' 'UNROLL: `$x = Get-Repo` no se marca si Get-Repo devuelve ,$arr (Wait-ToolkitJobs)' {
    foreach ($fn in @('wait-toolkitjobs', 'invoke-jobwithprogress')) {
        if (@($script:LintAstReport.SafeFunctions) -notcontains $fn) { throw ('{0} deberia contar como "no desenrolla" (return ,x)' -f $fn) }
    }
    [string] $src = @'
function Get-Coma { return ,@(1) }
function Get-Suelto { return @(1) }
function Use-Them {
    $a = Get-Coma
    $b = Get-Suelto
    $a.Count + $b.Count
}
'@
    $ast = Get-LintAstFromText -Text $src
    [object[]] $h = @(Find-LintUnrollHits -Ast $ast -File 'x' -SafeFunctions (Get-LintCollectionSafeFunctions -Asts @($ast)))
    if ($h.Count -ne 1 -or $h[0].Variable -ne 'b') { throw ('esperaba 1 hit en $b; encontro {0}' -f (($h | ForEach-Object { $_.Variable }) -join ',')) }
}

Test-SmokeFunction 'LintAst' 'extractores de Launch/Bootstrap pisan archivos existentes SIN el modulo Archive' {
    # Corre el helper REAL (extraido del .ps1 por AST: los dos archivos ejecutan
    # codigo al cargarse) en un powershell hijo donde el modulo
    # Microsoft.PowerShell.Archive NO puede cargarse (autoload apagado): si el
    # helper volviera a Expand-Archive, tira CommandNotFound.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [string] $tmp = Join-Path $env:TEMP ('pctk-unzip-' + [guid]::NewGuid().ToString('N'))
    [void] (New-Item -ItemType Directory -Path $tmp -Force)
    try {
        [string] $zipPath = Join-Path $tmp 'p.zip'
        $za = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            [void] $za.CreateEntry('vacia/')
            foreach ($pair in @(@('tools/a.txt', 'NUEVO'), @('b.txt', 'B'))) {
                $sw = New-Object System.IO.StreamWriter(($za.CreateEntry($pair[0])).Open())
                try { $sw.Write($pair[1]) } finally { $sw.Dispose() }
            }
        } finally { $za.Dispose() }

        [string] $child = Join-Path $tmp 'child.ps1'
        Set-Content -LiteralPath $child -Encoding UTF8 -Value @'
param([string] $Source, [string] $FunctionName, [string] $Zip, [string] $Dest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility, Microsoft.PowerShell.Management
$PSModuleAutoloadingPreference = 'None'
if (Get-Module Microsoft.PowerShell.Archive) { throw 'el modulo Archive ya estaba cargado: la prueba no vale' }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true)
if ($null -eq $fn) { throw ('no existe {0} en {1}' -f $FunctionName, $Source) }
. ([scriptblock]::Create($fn.Extent.Text))
& $FunctionName -Path $Zip -DestinationPath $Dest
'PASS'
'@
        foreach ($t in @(@('Launch.ps1', 'Expand-PctkZip'), @('Bootstrap-Tools.ps1', 'Expand-ToolZip'))) {
            [string] $dest = Join-Path $tmp ('dest-' + $t[1])
            [void] (New-Item -ItemType Directory -Path (Join-Path $dest 'tools') -Force)
            Set-Content -LiteralPath (Join-Path $dest 'tools\a.txt') -Value 'VIEJO' -NoNewline
            Set-Content -LiteralPath (Join-Path $dest 'queda.txt') -Value 'Q' -NoNewline
            [string] $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $child `
                -Source (Join-Path $repoRoot $t[0]) -FunctionName $t[1] -Zip $zipPath -Dest $dest 2>&1 | Out-String)
            if ($out -notmatch 'PASS') { throw ('{0}: el extractor fallo sin el modulo Archive: {1}' -f $t[1], $out.Trim()) }
            [string] $a = Get-Content -LiteralPath (Join-Path $dest 'tools\a.txt') -Raw
            if ($a -ne 'NUEVO') { throw ('{0}: tools\a.txt no quedo pisado (contenido: {1})' -f $t[1], $a) }
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'b.txt'))) { throw ('{0}: falta b.txt' -f $t[1]) }
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'vacia') -PathType Container)) { throw ('{0}: falta la carpeta vacia/' -f $t[1]) }
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'queda.txt'))) { throw ('{0}: borro un archivo que no estaba en el zip' -f $t[1]) }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ToolkitSupport' 'Write-ToolkitAuditLog escribe el audit en UTF-8 (no ANSI -> no mangla no-ASCII)' {
    # Write-ToolkitAuditLog es el escritor real del .jsonl (Write-ActionAudit del Router
    # es solo un wrapper que lo llama). El append por defecto de PS5.1 escribe ANSI.
    [string] $def = (Get-Command Write-ToolkitAuditLog -CommandType Function).Definition
    if ($def -notmatch 'AppendAllText') {
        throw 'Write-ToolkitAuditLog no usa AppendAllText (.NET); el append por defecto de PS5.1 escribe ANSI y mangla no-ASCII (em-dash, tildes) en el audit que viaja al CRM'
    }
    if ($def -notmatch 'UTF8') {
        throw 'Write-ToolkitAuditLog no escribe en UTF-8'
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-both: audit + snapshots -> zip con ambos' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    [string] $snapsDir  = Join-Path $tmpOut 'snapshots'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir 'pre.json')         -Value '{"Phase":"pre"}'  -Encoding UTF8
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'Zip no fue creado' }
        if ((Get-Item -LiteralPath $r.ZipPath).Length -eq 0) { throw 'Zip tiene tamanio cero' }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-tag-sanitize: chars invalidos -> solo validos en nombre' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { 'cliente/01 *<>' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch 'cliente01') { throw ('ZipName debe contener cliente01 (tag sanitizado); got {0}' -f $zipName) }
        if ($zipName -match '[/\\* <>]')    { throw ('ZipName contiene chars invalidos: {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-existing-collide: base.zip existe -> base_2.zip' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { '' }
        [string] $fixedTs  = '20260520-223015'
        [string] $baseZip  = Join-Path $tmpDest ('{0}_{1}.zip' -f $env:COMPUTERNAME, $fixedTs)
        New-Item -Path $baseZip -ItemType File -Force | Out-Null
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest -TimestampOverride $fixedTs
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $expected = Join-Path $tmpDest ('{0}_{1}_2.zip' -f $env:COMPUTERNAME, $fixedTs)
        if ($r.ZipPath -ne $expected) { throw ('ZipPath esperado {0}; got {1}' -f $expected, $r.ZipPath) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── ExportClientLogs: -TagOverride (2 casos) ────────────────────────────────

Test-SmokeFunction 'ExportClientLogs' 'export-tag-override-skip-prompt: con -TagOverride, NO llama Read-Host' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        # Si Read-Host se invoca, el test explota: eso es lo que queremos verificar.
        function Read-Host { throw 'Read-Host NO debe invocarse cuando se pasa -TagOverride' }
        $r = Invoke-ExportClientLogs -TagOverride 'preuninstall' -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch '-preuninstall_') { throw ('ZipName debe contener -preuninstall_; got {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-tag-override-sanitized: -TagOverride sanitiza igual que Read-Host' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse cuando se pasa -TagOverride' }
        $r = Invoke-ExportClientLogs -TagOverride 'cliente/01 *<>' -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch 'cliente01') { throw ('ZipName debe contener cliente01 (tag sanitizado); got {0}' -f $zipName) }
        if ($zipName -match '[/\\* <>]')    { throw ('ZipName contiene chars invalidos: {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── OOSU rework: Invoke-ProfilePrivacyStep (6 casos) ───────────────────────
# Tests read-only: usan fixtures en memoria + shadowing de funciones.
# Ningun test ejecuta OOSU10.exe real ni muta el sistema.

Test-SmokeFunction 'OosuRework' 'oosu-rework-no-cfg: skip silencioso' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    $privacy = [PSCustomObject]@{}
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Path    -ne 'skipped') { throw ('Path esperado skipped; got {0}' -f $r.Path) }
    if ($r.Success -ne $true)     { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'Skipped') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply Skipped no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-cfg-missing: cfg no encontrado' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'nonexistent_smoke_test.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $false) { throw ('Success esperado $false; got {0}' -f $r.Success) }
    if ($r.Detail['Reason'] -ne 'cfg_not_found') {
        throw ('Reason esperado cfg_not_found; got {0}' -f $r.Detail['Reason'])
    }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'Failed') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply Failed no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-oosu-available: aplica cfg, audit OK' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $true }
    function Invoke-OOSU10Profile {
        param([string]$Path, [int]$TimeoutSeconds = 120)
        return [PSCustomObject]@{ Success = $true; Skipped = $false; Reason = '' }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Path    -ne 'oosu10') { throw ('Path esperado oosu10; got {0}' -f $r.Path) }
    if ($r.Success -ne $true)    { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'OK') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply OK no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-download-needed: descarga OK, luego aplica' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $false }
    function Invoke-OOSUDownload {
        return [PSCustomObject]@{ Success = $true; Error = ''; ExePath = 'C:\fake\OOSU10.exe' }
    }
    function Invoke-OOSU10Profile {
        param([string]$Path, [int]$TimeoutSeconds = 120)
        return [PSCustomObject]@{ Success = $true; Skipped = $false; Reason = '' }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $true) { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $dlOk = $false; [bool] $applyOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Download' -and $a.Status -eq 'OK')    { $dlOk    = $true }
        if ($a.Action -eq 'Privacy.OOSU.Apply'    -and $a.Status -eq 'OK')    { $applyOk = $true }
    }
    if (-not $dlOk)    { throw 'Audit Privacy.OOSU.Download OK no registrado' }
    if (-not $applyOk) { throw 'Audit Privacy.OOSU.Apply OK no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-download-fails: falla de descarga, sin fallback nativo' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $false }
    function Invoke-OOSUDownload {
        return [PSCustomObject]@{ Success = $false; Error = 'no internet'; ExePath = '' }
    }
    [bool] $script:_nativeInvoked = $false
    function Start-PrivacyJob {
        param([string]$Profile)
        $script:_nativeInvoked = $true
        throw 'Start-PrivacyJob NO debe invocarse tras falla de descarga'
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $false) { throw ('Success esperado $false; got {0}' -f $r.Success) }
    if ($r.Detail['Reason'] -ne 'download_failed') {
        throw ('Reason esperado download_failed; got {0}' -f $r.Detail['Reason'])
    }
    if ($script:_nativeInvoked) { throw 'Start-PrivacyJob fue invocado (fallback nativo NO debe ocurrir)' }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Download' -and $a.Status -eq 'Failed') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Download Failed no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-no-native-fallback: grep estructural' {
    [string] $rRoot  = Split-Path -Parent $PSScriptRoot
    [string] $peFile = Join-Path $rRoot 'core\ProfileEngine.ps1'
    if (-not (Test-Path -LiteralPath $peFile)) { throw 'ProfileEngine.ps1 no encontrado' }
    [string] $content = [System.IO.File]::ReadAllText($peFile)
    $fnStart = $content.IndexOf('function Invoke-ProfilePrivacyStep')
    if ($fnStart -lt 0) { throw 'Invoke-ProfilePrivacyStep no encontrada en ProfileEngine.ps1' }
    # Buscar el cuerpo de la funcion: desde el { hasta el } de cierre al mismo nivel
    $braceOpen  = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -match 'Start-PrivacyJob') {
        throw 'Start-PrivacyJob encontrado en Invoke-ProfilePrivacyStep (regresion: fallback nativo presente)'
    }
}

# ─── UninstallPreserve: Save-PreUninstallArtifacts (6 casos) ─────────────────
# Testea la funcion extraida directamente, sin lanzar el deleter real.
# Shadowing: Read-Host (dest de clients), Write-ActionAudit (no-op en smoke).

Test-SmokeFunction 'UninstallPreserve' 'preserve-clients-and-snapshots: ambos presentes -> folder + zip' {
    [string] $tmpRoot     = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest  = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpCliDest  = Join-Path $env:TEMP ('pctk-smoke-cli-'  + [System.Guid]::NewGuid().ToString('N'))
    # Fixtures
    [string] $clientsDir  = Join-Path $tmpRoot 'output\clients\ClientA'
    [string] $auditDir    = Join-Path $tmpRoot 'output\audit'
    [string] $snapsDir    = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $clientsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $auditDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clientsDir 'run.log')           -Value 'log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl')    -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir  '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { $script:_rhCalled = $true; $tmpCliDest }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $script:_rhCalled = $false
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)                    { throw 'Save-PreUninstallArtifacts devolvio $null' }
        if (-not $script:_rhCalled)          { throw 'Read-Host no fue llamado (esperado para clients prompt)' }
        # clients copiados al dest que Read-Host retorno
        if (-not (Test-Path (Join-Path $tmpCliDest 'ClientA'))) {
            throw ('clients\ClientA no encontrado en {0}' -f $tmpCliDest)
        }
        # audit copiado dentro del folder
        if (-not (Test-Path (Join-Path $tmpCliDest 'audit'))) {
            throw ('audit\ no encontrado en {0}' -f $tmpCliDest)
        }
        # zip generado con audit + snapshots
        if ([string]::IsNullOrWhiteSpace($r.ZipPath) -or -not (Test-Path -LiteralPath $r.ZipPath)) {
            throw ('ZipPath esperado existente; got "{0}"' -f $r.ZipPath)
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [object[]] $entries = @()
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) }
        finally { $za.Dispose() }
        [bool] $hasAudit = $false; [bool] $hasSnaps = $false
        foreach ($e in $entries) {
            if ($e -match '^audit')     { $hasAudit = $true }
            if ($e -match '^snapshots') { $hasSnaps = $true }
        }
        if (-not $hasAudit) { throw 'Zip no contiene audit\' }
        if (-not $hasSnaps) { throw 'Zip no contiene snapshots\' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpCliDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-snapshots-only: sin clients -> SOLO zip, sin folder' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir   = Join-Path $tmpRoot 'output\audit'
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $auditDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl')   -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        # Read-Host NO debe invocarse (no hay clients\)
        function Read-Host { throw 'Read-Host NO debe invocarse sin clients\' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)          { throw 'Save-PreUninstallArtifacts devolvio $null' }
        # NO debe haber carpeta de historial en Desktop
        [string] $historial = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PCTk-historial-clientes'
        if (Test-Path $historial)  { throw 'PCTk-historial-clientes fue creado en Desktop inesperadamente' }
        # Zip SI debe existir
        if ([string]::IsNullOrWhiteSpace($r.ZipPath) -or -not (Test-Path -LiteralPath $r.ZipPath)) {
            throw ('ZipPath esperado existente; got "{0}"' -f $r.ZipPath)
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-empty-output: sin audit ni snapshots -> nada' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    # Dirs vacios (sin archivos adentro)
    New-Item -Path (Join-Path $tmpRoot 'output\audit')     -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tmpRoot 'output\snapshots') -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar)' }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('No debia crearse zip con output vacio; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-no-output: sin output\ -> nada' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    # NO crear nada en tmpRoot (ni siquiera output\)
    New-Item -Path $tmpRoot    -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar sin output\)' }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('No debia crearse zip sin output\; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-zip-fails-doesnt-abort-uninstall' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json') -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        # Simular fallo del zip en el limite real: Invoke-ExportClientLogs ahora usa
        # el API .NET (no Compress-Archive), asi que el mock va a nivel funcion ->
        # devuelve Failed, como cuando el zip no se puede crear.
        function Invoke-ExportClientLogs { return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = 'simulado' } }
        # No debe lanzar al caller aunque el zip falle
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)                      { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar por zip fallido)' }
        if (-not [string]::IsNullOrWhiteSpace($r.ZipPath) -and (Test-Path -LiteralPath $r.ZipPath)) {
            throw 'No debia generarse zip cuando Compress-Archive falla'
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-clients-survives-zip-fail: si zip falla, folder igual queda' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpCliDest = Join-Path $env:TEMP ('pctk-smoke-cli-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $clientsDir = Join-Path $tmpRoot 'output\clients\ClientA'
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $clientsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clientsDir 'run.log')          -Value 'log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { $tmpCliDest }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        # Simular fallo del zip a nivel funcion (Invoke-ExportClientLogs usa .NET, no
        # Compress-Archive): devuelve Failed. El copy de clients/ ocurre ANTES del zip
        # dentro de Save-PreUninstallArtifacts, asi que debe sobrevivir igual.
        function Invoke-ExportClientLogs { return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = 'simulado' } }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null' }
        # clients debe haber quedado copiado (el copy ocurre ANTES del zip)
        if (-not (Test-Path (Join-Path $tmpCliDest 'ClientA'))) {
            throw ('clients\ClientA no encontrado en {0} (el copy de clients debe sobrevivir al zip fallido)' -f $tmpCliDest)
        }
        # zip NO debe existir
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('Zip no debia generarse cuando Compress-Archive falla; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpCliDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── #10 Gaming Profile: schema, preset, Get-InstalledGames, fold-#19 ────────

# C. gaming-template.json valida con Test-NamedProfileSchema + ConvertFrom-Json
Test-SmokeFunction 'GamingProfile' 'gaming-template.json parsea sin error' {
    [string] $tplPath = Join-Path (Get-NamedProfileDir) 'gaming-template.json'
    if (-not (Test-Path -LiteralPath $tplPath)) { throw "gaming-template.json no encontrado en $(Get-NamedProfileDir)" }
    [PSCustomObject] $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $tpl) { throw 'gaming-template.json parseo a null' }
}
Test-SmokeFunction 'GamingProfile' 'gaming-template.json valida contra Test-NamedProfileSchema' {
    [string] $tplPath = Join-Path (Get-NamedProfileDir) 'gaming-template.json'
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $tpl
}

# B. oosu_profile='gaming' aceptado; 'xxx' rechazado
Test-SmokeFunction 'GamingProfile' "oosu_profile='gaming' aceptado por schema" {
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'oosu_profile' -NotePropertyValue 'gaming' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'GamingProfile' "oosu_profile='xxx' rechazado por schema" {
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'oosu_profile' -NotePropertyValue 'xxx' -Force
    [bool] $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw "Test-NamedProfileSchema debio rechazar oosu_profile='xxx'" }
}

# A. New-GamingPreset: fixture 1 GPU con VRAM 8GB -> hags=off
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset fixture 1-GPU VRAM<8GB -> hags off' {
    # Fixture con 1 GPU, VRAM 6144 MB (< 8192); coleccion de 1 elemento (trampa StrictMode)
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 3060')   # RTX30: no RTX40+, VRAM=6144
    $mp = [PSCustomObject]@{
        DGpuVramMb = 6144
        GpuNames   = $gpuNames
        IsWin11    = $false
    }
    $gt = New-GamingPreset -MachineProfile $mp
    if ($null -eq $gt) { throw 'New-GamingPreset devolvio $null' }
    [object] $hagsP = $gt.PSObject.Properties['hags']
    if ($null -eq $hagsP -or [string]$hagsP.Value -ne 'off') {
        throw ("VRAM<8GB debe dar hags=off; got '{0}'" -f $(if ($hagsP) { $hagsP.Value } else { '(ausente)' }))
    }
    [object] $hvciP = $gt.PSObject.Properties['hvci']
    if ($null -eq $hvciP -or [string]$hvciP.Value -ne 'off') { throw "hvci debe ser off; got '$($hvciP.Value)'" }
    [object] $gmP = $gt.PSObject.Properties['game_mode']
    if ($null -eq $gmP -or [string]$gmP.Value -ne 'on') { throw "game_mode debe ser on" }
    # timer_resolution: Win10 (build=19041) -> NO debe incluirse
    [object] $trP = $gt.PSObject.Properties['timer_resolution']
    if ($null -ne $trP) { throw 'Win10 (build<22000): timer_resolution NO debe incluirse en el preset' }
    # oosu_profile = gaming
    [object] $ooP = $gt.PSObject.Properties['oosu_profile']
    if ($null -eq $ooP -or [string]$ooP.Value -ne 'gaming') { throw "oosu_profile debe ser 'gaming'" }
}
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset fixture RTX40 -> hags on' {
    # Fixture con 1 GPU RTX40+ (RTX 4070); coleccion de 1 elemento
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 4070')
    $mp = [PSCustomObject]@{
        DGpuVramMb = 12288
        GpuNames   = $gpuNames
        IsWin11    = $true
    }
    $gt = New-GamingPreset -MachineProfile $mp
    if ($null -eq $gt) { throw 'New-GamingPreset devolvio $null con RTX40' }
    [object] $hagsP = $gt.PSObject.Properties['hags']
    if ($null -eq $hagsP -or [string]$hagsP.Value -ne 'on') {
        throw ("RTX40+ debe dar hags=on; got '{0}'" -f $(if ($hagsP) { $hagsP.Value } else { '(ausente)' }))
    }
    # timer_resolution: Win11 (build=22621) -> debe estar
    [object] $trP = $gt.PSObject.Properties['timer_resolution']
    if ($null -eq $trP -or [string]$trP.Value -ne 'on') {
        throw ("Win11 build>=22000: timer_resolution debe ser on; got '{0}'" -f $(if ($trP) { $trP.Value } else { '(ausente)' }))
    }
}
# El resultado del preset debe validar con Test-NamedProfileSchema (en una receta named completa)
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset produce gaming_tweaks que pasa schema' {
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 3070')
    $mp = [PSCustomObject]@{ DGpuVramMb = 8192; GpuNames = $gpuNames; IsWin11 = $true }
    $gt = New-GamingPreset -MachineProfile $mp
    # Construir receta named minima con el gaming_tweaks del preset
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    # Reemplazar gaming_tweaks con el preset (campo a campo)
    foreach ($prop in @($gt.PSObject.Properties)) {
        $p.gaming_tweaks | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
    $null = Test-NamedProfileSchema -Profile $p
}

# D. Get-InstalledGames: no-throw con/sin tiendas
Test-SmokeFunction 'GamingProfile' 'Get-InstalledGames no-throw devuelve array' {
    # Read-only: no valida deteccion real (eso es HW). Solo verifica que no lanza
    # y retorna un array (posiblemente vacio).
    [PSCustomObject[]] $games = @(Get-InstalledGames)
    if ($null -eq $games) { throw 'Get-InstalledGames retorno $null (esperado array, posiblemente vacio)' }
    # Shape: cada elemento debe tener Name, Path, Source
    foreach ($g in $games) {
        if ($null -eq $g.PSObject.Properties['Name'])   { throw 'campo Name ausente en juego' }
        if ($null -eq $g.PSObject.Properties['Path'])   { throw 'campo Path ausente en juego' }
        if ($null -eq $g.PSObject.Properties['Source']) { throw 'campo Source ausente en juego' }
    }
}

# E. Fold #19: Disable-Hvci / Enable-Hvci: check estructural (GPO check presente en codigo)
# El test de mutacion real (GPO impuesto) requiere HW con GPO; el smoke solo verifica
# que el codigo de la guardia esta presente (evita que el fix se borre en silencio).
Test-SmokeFunction 'GamingProfile' 'fold-19: Disable-Hvci tiene check GPO antes de Set-ItemProperty' {
    [string] $rRoot    = Split-Path -Parent $PSScriptRoot
    [string] $ciFile   = Join-Path $rRoot 'modules\CoreIsolation.ps1'
    if (-not (Test-Path -LiteralPath $ciFile)) { throw 'CoreIsolation.ps1 no encontrado' }
    [string] $content  = [System.IO.File]::ReadAllText($ciFile)
    # El bloque de Disable-Hvci debe contener la clave de la guardia
    [int] $fnStart = $content.IndexOf('function Disable-Hvci')
    if ($fnStart -lt 0) { throw 'Disable-Hvci no encontrada en CoreIsolation.ps1' }
    # Buscar el cuerpo de la funcion
    [int] $braceOpen = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -notmatch 'Policies.*DeviceGuard') {
        throw 'Disable-Hvci no contiene check GPO (Policies\Microsoft\Windows\DeviceGuard) -- fold-19 rota'
    }
    if ($fnBody -notmatch 'Blocked') {
        throw 'Disable-Hvci no retorna campo Blocked -- fold-19 rota'
    }
}
Test-SmokeFunction 'GamingProfile' 'fold-19: Enable-Hvci tiene check GPO antes de Set-ItemProperty' {
    [string] $rRoot    = Split-Path -Parent $PSScriptRoot
    [string] $ciFile   = Join-Path $rRoot 'modules\CoreIsolation.ps1'
    [string] $content  = [System.IO.File]::ReadAllText($ciFile)
    [int] $fnStart = $content.IndexOf('function Enable-Hvci')
    if ($fnStart -lt 0) { throw 'Enable-Hvci no encontrada en CoreIsolation.ps1' }
    [int] $braceOpen = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -notmatch 'Policies.*DeviceGuard') {
        throw 'Enable-Hvci no contiene check GPO (Policies\Microsoft\Windows\DeviceGuard) -- fold-19 rota'
    }
    if ($fnBody -notmatch 'Blocked') {
        throw 'Enable-Hvci no retorna campo Blocked -- fold-19 rota'
    }
}

# ─── ConsoleMenu: Read-PctkMenuChoice + Get-MainMenuRows (estructural) ───────
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMenuChoice presente' {
    if ($null -eq (Get-Command 'Read-PctkMenuChoice' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Read-PctkMenuChoice no encontrado'
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-MainMenuRows: 15 items en orden + 4 headers' {
    [object[]] $rows  = Get-MainMenuRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    # [I] = informe tecnico del equipo (RawAudit), cableado 2026-07-25.
    [string[]] $expectedKeys = @('1','2','3','4','5','6','7','8','R','A','T','I','L','X','U')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 4) {
        throw ('Se esperaban 4 headers; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMenuChoice fallback no bloquea (input redirigido)' {
    [object[]] $rows = Get-MainMenuRows
    [scriptblock] $rh = { }
    function Read-Host { '1' }
    [string] $result = Read-PctkMenuChoice -Rows $rows -RenderHeader $rh -ForceFallbackForTest
    if ($result -ne '1') {
        throw ("fallback retorno '$result'; esperado '1'")
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-IndividualActionRows: 21 items en orden + 5 headers' {
    [object[]] $rows  = Get-IndividualActionRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    [string[]] $expectedKeys = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19','20','B')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 5) {
        throw ('Se esperaban 5 headers; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-NamedProfileRows: 4 items en orden + 1 header' {
    [object[]] $rows  = Get-NamedProfileRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    [string[]] $expectedKeys = @('1','2','3','B')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 1) {
        throw ('Se esperaba 1 header; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMultiChoice + Test-PctkInteractiveConsole presentes' {
    foreach ($fn in @('Read-PctkMultiChoice', 'Test-PctkInteractiveConsole')) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Test-PctkInteractiveConsole: bool + false bajo input redirigido (smoke)' -RequiresHeadless -SkipReason 'espera $false, y en consola real Test-PctkInteractiveConsole da $true (stdin no redirigido)' {
    $r = Test-PctkInteractiveConsole
    if ($r -isnot [bool]) { throw 'no devolvio bool' }
    if ($r -ne $false) { throw "esperado false bajo input redirigido; got $r" }
}
Test-SmokeFunction 'ConsoleMenu' 'Invoke-ToolsMenuInteractive presente (handler [T])' {
    if ($null -eq (Get-Command 'Invoke-ToolsMenuInteractive' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Invoke-ToolsMenuInteractive no encontrado'
    }
}

# ─── #46: Get-PctkMenuLayout / Get-PctkMenuViewport (Windows Terminal) ───────
# La ventana de Windows Terminal NO se puede agrandar via Set-PctkConsoleSize
# (MaxWindowSize ahi es el tamanio ACTUAL -- ver ConsoleIcon.ps1). El fix mide
# el alto real de la consola en cada redibujo completo y elige Full / Compact
# (sin separadores) / Paged (ventana deslizante) / TooSmall (opcion c: avisar
# y caer al render plano). Estas dos funciones son PURAS a proposito -- no
# dependen de [Console], asi que se prueban sin abrir una consola real. El
# NOTA DE HONESTIDAD para quien lea esto despues: el loop de ReadKey de
# Read-PctkMenuChoice/Read-PctkMultiChoice NO se puede ejercitar end-to-end
# en smoke -- [Console]::ReadKey tira bajo input redirigido (por eso existe
# el gate Test-PctkInteractiveConsole) y [Console]::WindowHeight no se puede
# mockear. Por eso esta bateria prueba la MISMA funcion que el loop real
# llama (no una copia), y el test de "wiring" mas abajo confirma que el loop
# de verdad la invoca. La verificacion visual con Mateo mirando (ver el
# contrato D7) es la que cubre el tramo que smoke no puede.
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: Full cuando entra todo' {
    $l = Get-PctkMenuLayout -TotalRows 23 -CompactRows 19 -HeaderLines 8 -WindowHeight 44
    if ($l.Mode -ne 'Full') { throw "esperado Full; got $($l.Mode) (budget=$($l.Budget))" }
    # 44 - 8 (header) - 2 (footer) - 1 (BottomReserve, ver la nota de #46 en
    # Get-PctkMenuLayout: el newline de la ultima linea scrollearia la consola)
    if ($l.Budget -ne 33) { throw "budget esperado 33; got $($l.Budget)" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: limite exacto Full/Compact (budget == TotalRows)' {
    # budget = WindowHeight - HeaderLines - FooterLines - BottomReserve = 11-2-0-1 = 8 = TotalRows -> Full
    $l = Get-PctkMenuLayout -TotalRows 8 -CompactRows 6 -HeaderLines 2 -WindowHeight 11 -FooterLines 0
    if ($l.Mode -ne 'Full') { throw "budget==TotalRows deberia ser Full; got $($l.Mode) (budget=$($l.Budget))" }
    # un budget menos -> ya no entra todo, pero SI entra sin separadores -> Compact
    $l2 = Get-PctkMenuLayout -TotalRows 8 -CompactRows 6 -HeaderLines 3 -WindowHeight 11 -FooterLines 0
    if ($l2.Mode -ne 'Compact') { throw "budget==CompactRows deberia caer a Compact; got $($l2.Mode) (budget=$($l2.Budget))" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: Paged cuando ni compacto entra' {
    $l = Get-PctkMenuLayout -TotalRows 31 -CompactRows 25 -HeaderLines 8 -WindowHeight 29
    if ($l.Mode -ne 'Paged') { throw "esperado Paged; got $($l.Mode) (budget=$($l.Budget))" }
    if ($l.Budget -lt 3) { throw "Paged con budget < MinUsableRows no deberia pasar el gate: $($l.Budget)" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: TooSmall (opcion c) con ventana absurda' {
    $l = Get-PctkMenuLayout -TotalRows 31 -CompactRows 25 -HeaderLines 10 -WindowHeight 10
    if ($l.Mode -ne 'TooSmall') { throw "esperado TooSmall; got $($l.Mode) (budget=$($l.Budget))" }
    # budget negativo (header+footer ya se comen toda la ventana) tambien es TooSmall, no revienta
    $l2 = Get-PctkMenuLayout -TotalRows 31 -CompactRows 25 -HeaderLines 40 -WindowHeight 10
    if ($l2.Mode -ne 'TooSmall') { throw "budget negativo deberia ser TooSmall; got $($l2.Mode)" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: 0 filas compactas no fuerza Paged (evita bucle sin contenido)' {
    $l = Get-PctkMenuLayout -TotalRows 0 -CompactRows 0 -HeaderLines 10 -WindowHeight 10
    if ($l.Mode -ne 'TooSmall') { throw "CompactRows=0 deberia ser TooSmall (nada que paginar); got $($l.Mode)" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuLayout: la ventana ORIGINAL del bug (29 filas WT) nunca da Full ni revienta' {
    # Numeros medidos en field-bugs.md 2026-08-07: WT quedaba en 29 filas y NI el
    # menu principal (23 filas) NI el submenu [A] (31 filas) entraban. Esto ancla
    # el fix a esos numeros reales -- si alguien agrega items al menu y esto sigue
    # en Full, es que el guard se rompio (silenciosamente volveria al bug #46).
    foreach ($fn in @('Get-MainMenuRows', 'Get-IndividualActionRows')) {
        [object[]] $rows    = & $fn
        [int]      $total   = $rows.Count
        [int]      $compact = @($rows | Where-Object { $_.Kind -ne 'Spacer' }).Count
        foreach ($hdr in 6, 8, 10) {
            $l = Get-PctkMenuLayout -TotalRows $total -CompactRows $compact -HeaderLines $hdr -WindowHeight 29
            if ($l.Mode -eq 'Full') {
                throw ("{0} con header={1} en ventana de 29 filas dio Full -- el bug #46 volveria (WT no puede crecer la ventana)" -f $fn, $hdr)
            }
        }
    }
}
Test-SmokeFunction 'ConsoleMenu' '#46 el dibujo NUNCA llega a la ultima fila (si scrollea, las Y del redibujo surgical quedan desfasadas)' {
    # LA INVARIANTE QUE FALTABA. Los tests de arriba prueban que el modo se
    # CLASIFICA bien; ninguno probaba que lo dibujado ENTRE sin scrollear, y ahi
    # vivia el bug que encontro la verificacion visual de Mateo (2026-09-09).
    #
    # El caller emite, desde la fila 0: HeaderLines (banner) + N filas de menu +
    # FooterLines (linea en blanco + linea de ayuda). La ultima sale con
    # Write-Host, o sea con newline: para que ese newline NO scrollee, el total
    # tiene que terminar como mucho en WindowHeight-1, es decir
    #     HeaderLines + N + FooterLines <= WindowHeight - 1
    # Sin esa fila de reserva la consola scrollea 1, las $itemY capturadas durante
    # el dibujo quedan +1, y el redibujo de 2 filas pinta corrido.
    [int] $footer = 2
    foreach ($fn in @('Get-MainMenuRows', 'Get-IndividualActionRows')) {
        [object[]] $rows    = @(& $fn)
        [int]      $total   = $rows.Count
        [int]      $compact = @($rows | Where-Object { $_.Kind -ne 'Spacer' }).Count
        foreach ($winH in 20, 25, 29, 33, 39, 44, 60) {
            foreach ($hdr in 6, 8, 10, 12) {
                $l = Get-PctkMenuLayout -TotalRows $total -CompactRows $compact -HeaderLines $hdr -WindowHeight $winH -FooterLines $footer
                [int] $drawn = -1
                if     ($l.Mode -eq 'Full')     { $drawn = $total }
                elseif ($l.Mode -eq 'Compact')  { $drawn = $compact }
                elseif ($l.Mode -eq 'Paged')    { $drawn = $l.Budget }
                else                            { continue }   # TooSmall no dibuja: cae al render plano
                [int] $usadas = $hdr + $drawn + $footer
                if ($usadas -gt ($winH - 1)) {
                    throw ("{0} modo={1} winH={2} hdr={3}: dibuja {4} filas -> ocupa {5}, la consola scrollearia (max permitido {6})" -f $fn, $l.Mode, $winH, $hdr, $drawn, $usadas, ($winH - 1))
                }
            }
        }
    }
}
Test-SmokeFunction 'Router' '#46 Get-PctkBannerCim: consulta CIM UNA vez por sesion (1122 ms medidos por consulta)' {
    # Medido 2026-09-09 en la maquina de Mateo: Win32_Processor tarda ~1040 ms y
    # Win32_OperatingSystem ~28 ms. Eso corria en CADA redibujo completo del menu
    # (Show-MachineBanner vive en el $RenderHeader de los tres menus), y con la
    # paginacion de #46 el redibujo completo paso de raro a rutinario. Resultado:
    # las teclas se encolaban mas rapido de lo que se dibujaba.
    $script:PctkSmokeCimCount = 0
    function Get-CimInstance {
        param([string] $ClassName, $ErrorAction)
        $script:PctkSmokeCimCount++
        return [PSCustomObject]@{ OSArchitecture = '64 bits'; Name = 'CPU de prueba'; NumberOfCores = 8; NumberOfLogicalProcessors = 16 }
    }
    $script:PctkBannerCimCache = $null      # sesion limpia
    $null = Get-PctkBannerCim
    [int] $tras1 = $script:PctkSmokeCimCount
    if ($tras1 -lt 1) { throw "la primera llamada deberia consultar CIM; conteo=$tras1" }
    $null = Get-PctkBannerCim
    $null = Get-PctkBannerCim
    [int] $tras3 = $script:PctkSmokeCimCount
    if ($tras3 -ne $tras1) {
        throw "Get-PctkBannerCim re-consulto CIM: $tras1 consultas tras la 1ra llamada, $tras3 tras la 3ra. Cada consulta cuesta ~1 s y esto corre en cada redibujo del menu."
    }
    $script:PctkBannerCimCache = $null      # no contaminar los tests que siguen
}
Test-SmokeFunction 'Router' '#46 wiring: Show-MachineBanner NO consulta CIM directo (usa el cache)' {
    # Guard estructural, house rule "testear el wiring, no solo la funcion pura":
    # el cache de arriba no sirve de nada si el banner sigue llamando a
    # Get-CimInstance por su cuenta. Se lee el CODIGO FUENTE, igual que el guard
    # de #46 en ConsoleMenu.
    $fn = Get-Command -Name 'Show-MachineBanner' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $fn) { throw 'Show-MachineBanner no esta definida' }
    [string] $body = $fn.Definition
    if ($body -match 'Get-CimInstance') {
        throw 'Show-MachineBanner llama a Get-CimInstance directo -- vuelve el costo de ~1122 ms por redibujo completo del menu (#46)'
    }
    if ($body -notmatch 'Get-PctkBannerCim') {
        throw 'Show-MachineBanner no usa Get-PctkBannerCim -- el cache quedo desconectado'
    }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Get-PctkMenuViewport: sigue la fila resaltada sin des-sincronizarse' {
    # target adelante del budget -> la ventana se desliza para que quede al fondo
    [int] $vt = Get-PctkMenuViewport -TargetPos 7 -CurrentViewTop 0 -Budget 5 -TotalCompactRows 20
    if ($vt -ne 3) { throw "target=7 budget=5 deberia dar viewTop=3; got $vt" }
    # target atras del viewTop -> sube directo a mostrarlo primero
    [int] $vt2 = Get-PctkMenuViewport -TargetPos 1 -CurrentViewTop $vt -Budget 5 -TotalCompactRows 20
    if ($vt2 -ne 1) { throw "target=1 (antes del viewTop) deberia dar viewTop=1; got $vt2"}
    # target al final de la lista -> clampa a maxTop, nunca se pasa del final
    [int] $vt3 = Get-PctkMenuViewport -TargetPos 19 -CurrentViewTop $vt2 -Budget 5 -TotalCompactRows 20
    if ($vt3 -ne 15) { throw "target=19 (ultimo, total=20, budget=5) deberia clampar a viewTop=15; got $vt3" }
    # target dentro de la ventana actual -> no se mueve (evita redibujos de mas)
    [int] $vt4 = Get-PctkMenuViewport -TargetPos 16 -CurrentViewTop $vt3 -Budget 5 -TotalCompactRows 20
    if ($vt4 -ne $vt3) { throw "target dentro de la ventana visible no deberia mover viewTop; $vt3 -> $vt4" }
}
Test-SmokeFunction 'ConsoleMenu' '#46 wiring: Read-PctkMenuChoice y Read-PctkMultiChoice llaman a Get-PctkMenuLayout' {
    # Guard estructural (no de comportamiento): el house rule de este repo es
    # "testear el handler, no solo la funcion pura" -- Get-PctkMenuLayout ya esta
    # probada arriba, pero eso no prueba que el LOOP REAL la use. Como
    # [Console]::ReadKey/WindowHeight no se pueden mockear en smoke (tiran bajo
    # input redirigido, por diseño -- ver Test-PctkInteractiveConsole), esta es
    # la verificacion mas fuerte que se puede hacer sin abrir una consola real.
    [string] $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'utils\ConsoleMenu.ps1'
    [string] $src  = Get-Content -LiteralPath $path -Raw
    foreach ($fnName in @('Read-PctkMenuChoice', 'Read-PctkMultiChoice')) {
        # extraer el cuerpo de la funcion hasta la siguiente "function " top-level
        [int] $start = $src.IndexOf("function $fnName ")
        if ($start -lt 0) { throw "$fnName no encontrada en ConsoleMenu.ps1" }
        [int] $nextFn = $src.IndexOf("`nfunction ", $start + 10)
        [string] $body = if ($nextFn -gt 0) { $src.Substring($start, $nextFn - $start) } else { $src.Substring($start) }
        if ($body -notmatch 'Get-PctkMenuLayout') {
            throw "$fnName no llama a Get-PctkMenuLayout -- el redibujo completo dejaria de medir el alto real (bug #46 de nuevo)"
        }
        if ($body -notmatch 'TooSmall') {
            throw "$fnName no maneja el modo TooSmall (opcion c del plan D7: avisar en vez de romper)"
        }
    }
}

# ─── #46 (auditoria 2026-09-09): el aviso de TooSmall tiene que poder LEERSE ──
# Hallazgo de la auditoria del commit 9186063: el multi-select avisaba con
# Write-PctkWarn y devolvia Action=fallback al toque. El caller hace `return`,
# el menu de arriba redibuja con Clear-Host y el aviso se borra antes de que
# alguien lo lea: el operador ve un flash y un [T] que aparenta no hacer nada
# -- el mismo sintoma que el bug #46, justo en el camino que existe para
# explicarlo. El aviso se movio a Show-PctkMenuTooSmallNotice, AFUERA del loop
# de ReadKey, para poder probar el comportamiento de verdad (avisa + espera) en
# vez de mirar el texto del archivo.
Test-SmokeFunction 'ConsoleMenu' '#46 Show-PctkMenuTooSmallNotice: avisa Y ESPERA (si no, el Clear-Host de arriba se lo come)' {
    $script:d7Avisos = @()
    $script:d7Espero = $false
    # sombreado local: el lookup de comandos de PowerShell es dinamico, asi que
    # la funcion resuelve estas y no las reales (mismo patron que ya usa el
    # smoke para Write-PctkWarn mas abajo).
    function Write-PctkWarn { param([AllowEmptyString()][string] $Text) $script:d7Avisos += $Text }
    function Read-Host      { param([string] $Prompt) $script:d7Espero = $true; return '' }

    Show-PctkMenuTooSmallNotice '  [!] probe de auditoria'

    if ($script:d7Avisos.Count -ne 1) { throw ('esperaba 1 aviso en pantalla; hubo {0}' -f $script:d7Avisos.Count) }
    if ($script:d7Avisos[0] -notmatch 'probe de auditoria') { throw "el aviso no es el que se paso: $($script:d7Avisos[0])" }
    if (-not $script:d7Espero) { throw 'no espero al operador -- el Clear-Host del menu de arriba borra el aviso antes de que se lea (regresion del hallazgo de auditoria)' }
}
Test-SmokeFunction 'ConsoleMenu' '#46 Show-PctkMenuTooSmallNotice: una consola sin input no convierte el aviso en crash' {
    $script:d7Avisos2 = @()
    function Write-PctkWarn { param([AllowEmptyString()][string] $Text) $script:d7Avisos2 += $Text }
    function Read-Host      { param([string] $Prompt) throw 'no hay consola de entrada (headless)' }

    # main.ps1 corre con $ErrorActionPreference='Stop': si el Read-Host de cortesia
    # escapara, el aviso seria mas grave que lo que avisa. Espejar esa preferencia.
    $ErrorActionPreference = 'Stop'
    Show-PctkMenuTooSmallNotice '  [!] probe headless'

    if ($script:d7Avisos2.Count -ne 1) { throw 'el aviso tiene que salir igual cuando no hay input real' }
}
Test-SmokeFunction 'ConsoleMenu' '#46 wiring: la rama TooSmall del multi-select usa el aviso CON pausa' {
    # Guard del hallazgo: alcanza con que alguien vuelva a poner un Write-PctkWarn
    # pelado ahi para que el aviso deje de leerse, y ningun test de comportamiento
    # lo caza (la rama vive adentro del loop de ReadKey, que no se puede mockear).
    [string] $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'utils\ConsoleMenu.ps1'
    [string] $src  = Get-Content -LiteralPath $path -Raw
    [int] $start = $src.IndexOf('function Read-PctkMultiChoice ')
    if ($start -lt 0) { throw 'Read-PctkMultiChoice no encontrada en ConsoleMenu.ps1' }
    [int] $nextFn = $src.IndexOf("`nfunction ", $start + 10)
    [string] $body = if ($nextFn -gt 0) { $src.Substring($start, $nextFn - $start) } else { $src.Substring($start) }
    if ($body -notmatch 'Show-PctkMenuTooSmallNotice') {
        throw 'Read-PctkMultiChoice no usa Show-PctkMenuTooSmallNotice -- el aviso de TooSmall se borra sin leerse (hallazgo de la auditoria de 9186063)'
    }
}

# ─── Router: renderHeader robusto ante '& main.ps1' (regresion) ──────────────
# Canary del bug del gate 2026-06-07: el renderHeader que dibuja el banner NO debe
# usar .GetNewClosure(). Ese closure queda atado a un modulo dinamico que solo ve
# funciones GLOBALES; con '& main.ps1' (vs powershell -File) main.ps1 corre en un
# script-scope hijo y el closure no resuelve Show-MachineBanner -> CommandNotFound.
# El smoke NO lo reproduce funcionalmente (corre todo en un scope via -File), por eso
# el guard es estructural. Fix = scriptblock plano + $script:var (lookup dinamico).
Test-SmokeFunction 'Router' 'renderHeader sin GetNewClosure (sobrevive a "& main.ps1")' {
    # #26-B: barre TODO core\, no solo Router.ps1. Cuando los handlers salieron a
    # ActionHandlers.ps1 este canario quedaba verde por vacuidad -- seguia mirando
    # un archivo del que el codigo se habia ido. Un guard estructural atado a UN
    # path deja de guardar en cuanto el codigo se muda.
    [string] $coreDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
    [string[]] $hits = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $coreDir -Filter '*.ps1' -File)) {
        foreach ($linea in @(Get-Content -LiteralPath $f.FullName | Where-Object { $_ -match '\.GetNewClosure\(' })) {
            $hits += ('{0}: {1}' -f $f.Name, $linea.Trim())
        }
    }
    if ($hits.Count -gt 0) {
        throw ('core\ usa .GetNewClosure() ({0}): rompe el render con "& main.ps1" (el closure no ve Show-MachineBanner). Usar scriptblock plano + $script:var. -> {1}' -f $hits.Count, ($hits -join ' | '))
    }
}

Test-SmokeFunction 'StaticCheck' '#26-B: los handlers de accion no volvieron a Router.ps1' {
    # El split existe para que Router.ps1 sea menu + dispatch y nada mas. Sin este
    # guard el god-file vuelve de a poco: cada accion nueva definida "ahi nomas"
    # y en un año son otras 1.400 lineas. Que se rompa es la señal de que el
    # handler nuevo va a core\ActionHandlers.ps1.
    [string] $coreDir    = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
    [string] $routerPath = Join-Path $coreDir 'Router.ps1'
    [string] $ahPath     = Join-Path $coreDir 'ActionHandlers.ps1'

    if (-not (Test-Path -LiteralPath $ahPath)) { throw 'falta core\ActionHandlers.ps1' }

    [string[]] $enRouter = @(
        Select-String -Path $routerPath -Pattern '^function Invoke-Action' |
            ForEach-Object { $_.Line.Trim() }
    )
    if ($enRouter.Count -gt 0) {
        throw ('Router.ps1 volvio a definir handlers de accion ({0}): van a core\ActionHandlers.ps1 -> {1}' -f $enRouter.Count, ($enRouter -join ' | '))
    }

    [int] $enAh = @(Select-String -Path $ahPath -Pattern '^function Invoke-Action').Count
    if ($enAh -lt 19) {
        throw ('ActionHandlers.ps1 define {0} handlers de accion, esperaba al menos 19' -f $enAh)
    }
}

# ─── ConsoleTheme: VT + capa de helpers de output (estructural) ──────────────
# En smoke el output esta redirigido -> Enable-PctkVT da false y todo cae al
# render 16-color/texto. Estos tests verifican el contrato del FALLBACK: presencia,
# no-throw, devuelve bool, y que los Get-* NO emiten ANSI crudo con VT off.
# En consola interactiva el primer test PRENDE el VT ($script:PctkVT queda $true
# el resto de la corrida): el de 'Get-* ... con VT off' fija $script:PctkVT = $false
# adentro y lo restaura, asi prueba el fallback en todo entorno sin SKIP.
Test-SmokeFunction 'ConsoleTheme' 'Enable-PctkVT presente + devuelve bool + no-throw' {
    if ($null -eq (Get-Command 'Enable-PctkVT' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Enable-PctkVT no encontrado'
    }
    $r = Enable-PctkVT
    if ($r -isnot [bool]) { throw ('Enable-PctkVT no devolvio bool; got {0}' -f $r.GetType().Name) }
    $t = Test-PctkVT
    if ($t -isnot [bool]) { throw 'Test-PctkVT no devolvio bool' }
}
Test-SmokeFunction 'ConsoleTheme' 'helpers de tema presentes' {
    [string[]] $fns = @(
        'Write-PctkLine','Write-PctkOk','Write-PctkWarn','Write-PctkErr','Write-PctkHint',
        'Write-PctkWork','Write-PctkSection','Write-PctkValue','Write-PctkActionTitle',
        'Get-PctkBadge','Write-PctkDivider','ConvertTo-PctkAnsiFg','Get-PctkKindSpec',
        'Write-PctkMachineBanner','Get-PctkGrad'
    )
    foreach ($fn in $fns) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
    }
}
Test-SmokeFunction 'ConsoleTheme' 'helpers de output no-throw con VT off' {
    # Sub-scriptblock con *>$null: no ensuciamos el reporte; un throw igual propaga.
    & {
        Write-PctkLine -Text 'x' -Kind 'ok'
        Write-PctkOk 'x'; Write-PctkWarn 'x'; Write-PctkErr 'x'; Write-PctkHint 'x'
        Write-PctkWork 'x'; Write-PctkSection 'x'; Write-PctkValue 'x'; Write-PctkValue ''
        Write-PctkActionTitle 'TITULO DE PRUEBA'
        Write-PctkDivider 20
    } *> $null
}
Test-SmokeFunction 'ConsoleTheme' 'Get-* no emiten ANSI crudo con VT off' {
    # VT off fijado aca, no heredado del entorno: en consola real el test de
    # Enable-PctkVT lo deja prendido. Se restaura para no cambiar el resto de la corrida.
    [bool] $prevVT = $script:PctkVT
    $script:PctkVT = $false
    try {
        [char] $esc = [char]27
        [string] $b = Get-PctkBadge 'OK' 'ok'
        if ($b.IndexOf($esc) -ge 0) { throw 'Get-PctkBadge emitio ESC con VT off' }
        if ($b -ne '[OK]')          { throw ("Get-PctkBadge VT off esperado '[OK]'; got '{0}'" -f $b) }
        [string] $g = Get-PctkGrad 'abc' 255 170 40 95 108 124
        if ($g.IndexOf($esc) -ge 0) { throw 'Get-PctkGrad emitio ESC con VT off' }
        if ($g -ne 'abc')           { throw ("Get-PctkGrad VT off esperado 'abc'; got '{0}'" -f $g) }
        [string] $f = ConvertTo-PctkAnsiFg 'Green'
        if ($f -ne '')              { throw ("ConvertTo-PctkAnsiFg VT off esperado ''; got '{0}'" -f $f) }
    } finally { $script:PctkVT = $prevVT }
}
Test-SmokeFunction 'ConsoleTheme' 'Get-PctkKindSpec: shape + 16-color por kind' {
    $s = Get-PctkKindSpec 'ok'
    foreach ($k in @('R','G','B','C16')) {
        if (-not $s.ContainsKey($k)) { throw "Get-PctkKindSpec sin clave $k" }
    }
    if ($s.C16 -ne 'Green') { throw ("kind 'ok' C16 esperado Green; got {0}" -f $s.C16) }
    if ((Get-PctkKindSpec 'err').C16  -ne 'Red')      { throw "kind 'err' C16 != Red" }
    if ((Get-PctkKindSpec 'hint').C16 -ne 'DarkGray') { throw "kind 'hint' C16 != DarkGray" }
    if ((Get-PctkKindSpec 'zzz').C16  -ne 'Gray')     { throw "kind desconocido C16 != Gray (default value)" }
}

# --- P5: Release.ps1 falla con exit 1 y verifica lo publicado contra la API ---
# v2.7.0 quedo 9 dias como tag SIN release: el token habia vencido, el catch de
# Release.ps1 imprimio un mensaje rojo y el script termino con exit 0. Nadie lo vio.
#
# Se corre el SCRIPT REAL (una copia byte a byte en TEMP, para que dist\ caiga ahi
# y no en el repo), invocado como lo invoca el flujo de release, y se mira el exit
# code. NO una funcion suelta: el bug vivia en el wiring (catch -> fin normal).
#
# SEGURIDAD: los bordes que salen a la red o a git estan shadoweados por dobles que
# TIRAN ante cualquier llamada inesperada (otra URL, otro repo, otro token). El
# token de la sesion se reemplaza por uno falso mientras corre el escenario y se
# restaura al final: aunque la maquina tenga GITHUB_TOKEN configurado, publicar de
# verdad desde aca es imposible.
function Invoke-ReleaseSmokeScenario {
    param(
        [Parameter(Mandatory)] [string] $Scenario,
        [switch] $Dirty
    )

    # Espejo de produccion: Release.ps1 corre via -File, con EAP por defecto.
    $ErrorActionPreference = 'Continue'

    [string] $srcScript = Join-Path $repoRoot 'Release.ps1'
    [string] $tmpRoot   = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-release-smoke-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    Copy-Item -LiteralPath $srcScript -Destination (Join-Path $tmpRoot 'Release.ps1')
    [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'Launch.ps1'), "`$GitHubRepo = 'smoke-test/no-existe'`n")

    $relCtx = @{
        Scenario = $Scenario
        Repo     = 'smoke-test/no-existe'
        Version  = '0.0.0-smoke'
        Token    = 'smoke-token-falso-no-publica'
        Calls    = [System.Collections.Generic.List[string]]::new()
        Uploads  = @{}
        GetDone  = $false
    }

    # Doble de git: solo 'status' (guard de arbol sucio) y 'archive' (ZIP falso).
    function git {
        [object[]] $a = @($args)
        [void] $relCtx.Calls.Add('git ' + ($a -join ' '))
        if ($a -contains 'status') {
            $global:LASTEXITCODE = 0
            if ($relCtx.Scenario -eq 'dirty') { return ' M algo.ps1' }
            return ''
        }
        if ($a -contains 'archive') {
            if ($relCtx.Scenario -eq 'archive-fail') { $global:LASTEXITCODE = 128; return }
            [int] $i = [array]::IndexOf($a, '-o')
            if ($i -lt 0) { throw 'DOBLE git: archive sin -o' }
            [byte[]] $fake = [byte[]] (@(80, 75, 5, 6) + @(0) * 18)
            [System.IO.File]::WriteAllBytes([string] $a[$i + 1], $fake)
            $global:LASTEXITCODE = 0
            return
        }
        throw ('DOBLE git: llamada inesperada: git {0}' -f ($a -join ' '))
    }

    # Doble de la API de GitHub. Tira ante cualquier cosa que no sea el repo de
    # prueba con el token falso.
    function Invoke-RestMethod {
        [CmdletBinding()]
        param(
            [string] $Uri,
            [string] $Method = 'Get',
            [System.Collections.IDictionary] $Headers,
            [string] $ContentType,
            [object] $Body
        )
        if ($null -eq $Headers -or [string] $Headers['Authorization'] -ne ('token ' + $relCtx.Token)) {
            throw ('DOBLE: Authorization inesperado en {0} {1}' -f $Method, $Uri)
        }
        [void] $relCtx.Calls.Add(('{0} {1}' -f $Method.ToUpperInvariant(), $Uri))
        [string] $api    = 'https://api.github.com/repos/' + $relCtx.Repo
        [string] $upload = 'https://uploads.github.com/repos/' + $relCtx.Repo + '/releases/1/assets?name='

        if ($Method -eq 'Post' -and $Uri -eq ($api + '/releases')) {
            if ($relCtx.Scenario -eq 'post401') { throw 'El servidor remoto devolvio un error: (401) No autorizado.' }
            return [pscustomobject] @{
                id         = 1
                upload_url = 'https://uploads.github.com/repos/' + $relCtx.Repo + '/releases/1/assets{?name,label}'
                html_url   = 'https://github.com/' + $relCtx.Repo + '/releases/tag/v' + $relCtx.Version
            }
        }
        if ($Method -eq 'Post' -and $Uri.StartsWith($upload)) {
            [string] $name = $Uri.Substring($upload.Length)
            if ($relCtx.Scenario -eq 'upload-fail' -and $name -like '*.zip') { throw 'El servidor remoto devolvio un error: (502) Puerta de enlace no valida.' }
            [int] $len = @($Body).Count
            if ($Body -is [byte[]]) { $len = $Body.Length }
            $relCtx.Uploads[$name] = $len
            return [pscustomobject] @{ name = $name; state = 'uploaded'; size = $len }
        }
        if ($Method -eq 'Get' -and $Uri -eq ($api + '/releases/tags/v' + $relCtx.Version)) {
            $relCtx.GetDone = $true
            [System.Collections.Generic.List[object]] $assets = [System.Collections.Generic.List[object]]::new()
            foreach ($k in @($relCtx.Uploads.Keys)) {
                [int] $size = [int] $relCtx.Uploads[$k]
                if ($relCtx.Scenario -eq 'verify-missing' -and $k -like '*.sha256') { continue }
                if ($relCtx.Scenario -eq 'verify-size' -and $k -like '*.zip') { $size = $size + 1 }
                [void] $assets.Add([pscustomobject] @{ name = $k; state = 'uploaded'; size = $size })
            }
            return [pscustomobject] @{
                tag_name = 'v' + $relCtx.Version
                draft    = $false
                html_url = 'https://github.com/' + $relCtx.Repo + '/releases/tag/v' + $relCtx.Version
                assets   = $assets.ToArray()
            }
        }
        throw ('DOBLE: llamada inesperada a la API: {0} {1}' -f $Method, $Uri)
    }
    function Invoke-WebRequest { throw 'DOBLE: Invoke-WebRequest no esperado en Release.ps1' }

    [string] $prevToken = $env:GITHUB_TOKEN
    try {
        $env:GITHUB_TOKEN = $relCtx.Token
        $global:LASTEXITCODE = -999
        if ($Dirty) {
            & (Join-Path $tmpRoot 'Release.ps1') -Version $relCtx.Version -Repo $relCtx.Repo -Publish *> $null
        } else {
            & (Join-Path $tmpRoot 'Release.ps1') -Version $relCtx.Version -Repo $relCtx.Repo -Publish -AllowDirty *> $null
        }
        [int] $code = $global:LASTEXITCODE
    }
    finally {
        $env:GITHUB_TOKEN = $prevToken
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject] @{
        ExitCode = $code
        Calls    = @($relCtx.Calls)
        GetDone  = [bool] $relCtx.GetDone
        Uploads  = $relCtx.Uploads
    }
}

Test-SmokeFunction 'Release' 'P5: POST de la release falla (401) -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'post401'
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1 (el 401 no puede terminar "bien")' -f $r.ExitCode) }
}
Test-SmokeFunction 'Release' 'P5: falla el upload del ZIP -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'upload-fail'
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1' -f $r.ExitCode) }
}
Test-SmokeFunction 'Release' 'P5: publica OK pero el GET no ve el checksum -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'verify-missing'
    if (-not $r.GetDone)   { throw 'no verifico contra la API (sin GET de releases/tags)' }
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1 (falta un asset)' -f $r.ExitCode) }
}
Test-SmokeFunction 'Release' 'P5: publica OK pero el ZIP publicado tiene otro tamano -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'verify-size'
    if (-not $r.GetDone)   { throw 'no verifico contra la API (sin GET de releases/tags)' }
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1 (tamano distinto)' -f $r.ExitCode) }
}
Test-SmokeFunction 'Release' 'P5: todo OK -> exit 0, dos assets subidos y verificados' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'ok'
    if ($r.ExitCode -ne 0) { throw ('exit {0}, esperaba 0' -f $r.ExitCode) }
    if (-not $r.GetDone)   { throw 'termino OK sin verificar contra la API (sin GET de releases/tags)' }
    if ($r.Uploads.Count -ne 2) { throw ('subio {0} assets, esperaba 2 (ZIP + checksum)' -f $r.Uploads.Count) }
}
Test-SmokeFunction 'Release' 'P5: git archive falla -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'archive-fail'
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1' -f $r.ExitCode) }
    if (@($r.Calls | Where-Object { $_ -like 'POST *' }).Count -gt 0) { throw 'publico aunque git archive fallo' }
}
Test-SmokeFunction 'Release' 'P5: arbol sucio sin -AllowDirty -> exit 1' {
    $r = Invoke-ReleaseSmokeScenario -Scenario 'dirty' -Dirty
    if ($r.ExitCode -ne 1) { throw ('exit {0}, esperaba 1' -f $r.ExitCode) }
    if (@($r.Calls | Where-Object { $_ -like 'git *archive*' }).Count -gt 0) { throw 'empaqueto aunque el arbol estaba sucio' }
}

# ─── DiskMaintenance: Resolve-VolumeMaintenanceOp (funcion pura) ─────────────
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: SSD->ReTrim' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'SSD'
    if ($r.Op -ne 'ReTrim') { throw "SSD: Op esperado ReTrim; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'SSD: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: HDD->Defrag' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'HDD'
    if ($r.Op -ne 'Defrag') { throw "HDD: Op esperado Defrag; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'HDD: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: SCM->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'SCM'
    if ($r.Op -ne 'Skip') { throw "SCM: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'SCM: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: Desconocido->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'Desconocido'
    if ($r.Op -ne 'Skip') { throw "Desconocido: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Desconocido: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: vacio->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel ''
    if ($r.Op -ne 'Skip') { throw "Vacio: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Vacio: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: valor arbitrario->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'cualquiercosa'
    if ($r.Op -ne 'Skip') { throw "Arbitrario: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Arbitrario: Reason vacia' }
}

# ─── DiskMaintenance: Get-VolumeMaintenancePlan (read-only, live) ─────────────
# Canario de trampa StrictMode: la dev-PC tipica tiene 1-2 volumenes. Con
# @(...) forzamos array para el caso de exactamente 1 elemento.
Test-SmokeFunction 'DiskMaintenance' 'Get-VolumeMaintenancePlan: no lanza + shape correcto' {
    $ErrorActionPreference = 'Stop'
    # Forzar @(...) para proteger contra trampa StrictMode de 1 elemento
    [object[]] $plan = @(Get-VolumeMaintenancePlan)
    # En Sandbox/VM puede ser vacio (todo Skip antes del filtro, o sin volumenes fijos)
    foreach ($item in $plan) {
        [string[]] $requiredProps = @('DriveLetter','Label','SizeGb','MediaType','Op','Reason')
        foreach ($p in $requiredProps) {
            if ($null -eq $item.PSObject.Properties[$p]) {
                throw ("Volumen sin propiedad '$p'")
            }
        }
        [string] $op = [string]$item.Op
        if ($op -ne 'ReTrim' -and $op -ne 'Defrag' -and $op -ne 'Skip') {
            throw ("Op inesperada: '$op'")
        }
    }
}

# ─── DiskMaintenance: Get-WindowsDefragTaskStatus (read-only) ─────────────────
Test-SmokeFunction 'DiskMaintenance' 'Get-WindowsDefragTaskStatus: no lanza + shape o null' {
    $ErrorActionPreference = 'Stop'
    $r = Get-WindowsDefragTaskStatus
    if ($null -ne $r) {
        if ($null -eq $r.PSObject.Properties['Exists'])      { throw 'Get-WindowsDefragTaskStatus: falta propiedad Exists' }
        if ($null -eq $r.PSObject.Properties['State'])       { throw 'Get-WindowsDefragTaskStatus: falta propiedad State' }
        if ($null -eq $r.PSObject.Properties['LastRunTime']) { throw 'Get-WindowsDefragTaskStatus: falta propiedad LastRunTime' }
    }
}

# ─── DiskMaintenance: canario estructural dispatch ────────────────────────────
Test-SmokeFunction 'DiskMaintenance' 'handler [17] DiskMaintenance: dispatch rutea correctamente' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'17'\s*\{\s*Invoke-ActionDiskMaintenance") {
        throw 'dispatch no rutea [17] -> Invoke-ActionDiskMaintenance'
    }
}

# ─── DiskMaintenance: canario de NO-mutacion del smoke ───────────────────────
# El smoke NUNCA debe llamar Invoke-VolumeMaintenance ni Start-DiskMaintenanceProcess
# (solo las funciones read-only y la pura). Buscamos lineas con llamadas directas:
# la funcion aparece al inicio de la expresion (precedida por espacio o comienzo
# de linea) sin estar dentro de un -match/-notmatch (que solo la referencia como string).
Test-SmokeFunction 'DiskMaintenance' 'smoke no llama funciones mutantes de DiskMaintenance' {
    $ErrorActionPreference = 'Stop'
    [string] $smokePath = $PSCommandPath
    [string[]] $smokeLines = @(Get-Content -LiteralPath $smokePath -Encoding UTF8)
    foreach ($mutantFn in @('Invoke-VolumeMaintenance', 'Start-DiskMaintenanceProcess')) {
        # Buscar lineas donde la funcion aparece como llamada real (no como literal de string en -match/-notmatch)
        [object[]] $callLines = @($smokeLines | Where-Object {
            $_ -match "\b$([regex]::Escape($mutantFn))\b" -and
            $_.TrimStart() -notmatch '^#' -and
            $_ -notmatch '-match\s' -and
            $_ -notmatch '-notmatch\s' -and
            $_ -notmatch "'\s*$([regex]::Escape($mutantFn))" -and
            $_ -notmatch "@'\s*$([regex]::Escape($mutantFn))"
        })
        if ($callLines.Count -gt 0) {
            throw "smoke.ps1 llama a $mutantFn (funcion mutante): $($callLines[0].Trim())"
        }
    }
}

# ─── ToolsManifest: antimalware ───────────────────────────────────────────────
Test-SmokeFunction 'ToolsManifest' 'manifest: kvrt + adwcleaner con categoria antimalware' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($toolName in @('kvrt', 'adwcleaner')) {
        $tool = $m.tools | Where-Object { $_.name -eq $toolName } | Select-Object -First 1
        if ($null -eq $tool)                                          { throw "Tool '$toolName' no encontrada en manifest" }
        if ([string]$tool.category -ne 'antimalware')                 { throw "Tool '$toolName': category esperado 'antimalware'; got '$($tool.category)'" }
        if ([string]::IsNullOrWhiteSpace([string]$tool.url))          { throw "Tool '$toolName': url vacia" }
        if ([string]$tool.updatePolicy -ne 'latest')                  { throw "Tool '$toolName': updatePolicy esperado 'latest'; got '$($tool.updatePolicy)'" }
        if (-not ($tool.PSObject.Properties['approxSizeMB']) -or [int]$tool.approxSizeMB -le 0) { throw "Tool '$toolName': approxSizeMB debe ser > 0" }
    }
}
Test-SmokeFunction 'ToolsManifest' 'manifest: categoria antimalware existe' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $m.categories.PSObject.Properties['antimalware']) {
        throw "categoria 'antimalware' no encontrada en manifest.categories"
    }
}

# ─── ToolsManifest: #23d medicion fps + ddu ───────────────────────────────────
Test-SmokeFunction 'ToolsManifest' 'manifest: presentmon (diagnostico + url release x64)' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tool = $m.tools | Where-Object { $_.name -eq 'presentmon' } | Select-Object -First 1
    if ($null -eq $tool)                                    { throw "Tool 'presentmon' no encontrada en manifest" }
    if ([string]$tool.category -ne 'diagnostico')           { throw "presentmon: category esperado 'diagnostico'; got '$($tool.category)'" }
    if ([string]::IsNullOrWhiteSpace([string]$tool.url))    { throw 'presentmon: url vacia' }
    if ([string]$tool.url -notmatch 'PresentMon.*x64\.exe') { throw "presentmon: url no apunta al exe x64: $($tool.url)" }
}
Test-SmokeFunction 'ToolsManifest' 'manifest: ddu ya presente (drivers) - no re-agregar' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tool = $m.tools | Where-Object { $_.name -eq 'ddu' } | Select-Object -First 1
    if ($null -eq $tool)                      { throw "Tool 'ddu' no encontrada en manifest" }
    if ([string]$tool.category -ne 'drivers') { throw "ddu: category esperado 'drivers'; got '$($tool.category)'" }
}

Test-SmokeFunction 'ToolsManifest' 'manifest: cinebenchr23 (hardware, zip, launchExe correcto)' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tool = $m.tools | Where-Object { $_.name -eq 'cinebenchr23' } | Select-Object -First 1
    if ($null -eq $tool)                                       { throw "Tool 'cinebenchr23' no encontrada en manifest" }
    if ([string]$tool.category -ne 'hardware')                 { throw "cinebenchr23: category esperado 'hardware'; got '$($tool.category)'" }
    if ([string]$tool.type -ne 'zip')                          { throw "cinebenchr23: type esperado 'zip'; got '$($tool.type)'" }
    if ([string]::IsNullOrWhiteSpace([string]$tool.url))       { throw 'cinebenchr23: url vacia' }
    if ([string]$tool.launchExe -ne 'Cinebench\Cinebench.exe') { throw "cinebenchr23: launchExe esperado 'Cinebench\Cinebench.exe'; got '$($tool.launchExe)'" }
    if ([string]$tool.extractDir -ne 'Cinebench')             { throw "cinebenchr23: extractDir esperado 'Cinebench'; got '$($tool.extractDir)'" }
}

# ─── Encryption: label maps (funciones puras) ─────────────────────────────────
Test-SmokeFunction 'Encryption' 'ConvertTo-Enc*Label: enums conocidos y default' {
    $ErrorActionPreference = 'Stop'
    if ((ConvertTo-EncConversionLabel -Status 1)  -ne 'FullyEncrypted') { throw 'conv 1 != FullyEncrypted' }
    if ((ConvertTo-EncConversionLabel -Status 0)  -ne 'FullyDecrypted') { throw 'conv 0 != FullyDecrypted' }
    if ((ConvertTo-EncConversionLabel -Status 99) -ne 'Unknown')        { throw 'conv 99 != Unknown' }
    if ((ConvertTo-EncMethodLabel     -Method 4)  -ne 'AES256')         { throw 'method 4 != AES256' }
    if ((ConvertTo-EncMethodLabel     -Method 7)  -ne 'XTS_AES256')     { throw 'method 7 != XTS_AES256' }
    if ((ConvertTo-EncMethodLabel     -Method 99) -ne 'Unknown')        { throw 'method 99 != Unknown' }
}

# ─── Encryption: detector read-only ───────────────────────────────────────────
# Degrada limpio en VM/Sandbox/sin-permisos: Encryptable=$false, sin throw.
Test-SmokeFunction 'Encryption' 'Get-DiskEncryptionStatus: no lanza + shape completo' {
    $ErrorActionPreference = 'Stop'
    $st = Get-DiskEncryptionStatus
    if ($null -eq $st) { throw 'Get-DiskEncryptionStatus devolvio $null' }
    foreach ($p in @('DriveLetter','Encryptable','ProtectionOn','ConversionStatus',
                     'ConversionLabel','EncryptionPct','EncryptionMethod','IsEncrypted',
                     'HasRecoveryProtector','Error')) {
        if ($null -eq $st.PSObject.Properties[$p]) { throw ("falta propiedad {0}" -f $p) }
    }
}

# Read-only y SENSIBLE: devuelve [object[]] (vacio en dev sin cifrar/sin permisos).
Test-SmokeFunction 'Encryption' 'Get-BitLockerRecoveryKey: no lanza + devuelve array' {
    $ErrorActionPreference = 'Stop'
    [object[]] $keys = @(Get-BitLockerRecoveryKey)
    if ($keys -isnot [object[]]) { throw 'no devolvio [object[]]' }
}

# ─── Encryption: Save con coleccion de EXACTAMENTE 1 (canario StrictMode) ──────
Test-SmokeFunction 'Encryption' 'Save-BitLockerRecoveryKey: 1 protector + vacio->""' {
    $ErrorActionPreference = 'Stop'
    if ((Save-BitLockerRecoveryKey -Keys @()) -ne '') { throw 'coleccion vacia debe dar ""' }
    [object[]] $one = @([PSCustomObject]@{
        KeyProtectorId   = '{12345678-AAAA-BBBB-CCCC-DDDDDDDDDDDD}'
        KeyId8           = '12345678'
        RecoveryPassword = '111111-222222-333333-444444-555555-666666-777777-888888'
    })
    [string] $tmp = Join-Path $env:TEMP ('pctk-enc-smoke-' + [System.IO.Path]::GetRandomFileName())
    try {
        [string] $path = Save-BitLockerRecoveryKey -Keys $one -OutputRootOverride $tmp -TimestampOverride '20260101-000000'
        if ([string]::IsNullOrEmpty($path)) { throw 'no devolvio path' }
        if (-not (Test-Path -LiteralPath $path)) { throw 'archivo no creado' }
        [string] $body = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($body -notmatch '12345678')            { throw 'no contiene Key ID' }
        if ($body -notmatch '111111-222222')       { throw 'no contiene la clave' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ─── Encryption: canario estructural dispatch ─────────────────────────────────
Test-SmokeFunction 'Encryption' 'handler [18] Encryption: dispatch rutea correctamente' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'18'\s*\{\s*Invoke-ActionEncryption") {
        throw 'dispatch no rutea [18] -> Invoke-ActionEncryption'
    }
}

# ─── Encryption: canario de NO-mutacion del smoke ─────────────────────────────
# El smoke NUNCA debe llamar Start-BitLockerDecrypt (descifra el disco real).
Test-SmokeFunction 'Encryption' 'smoke no llama funciones mutantes de Encryption' {
    $ErrorActionPreference = 'Stop'
    [string] $smokePath = $PSCommandPath
    [string[]] $smokeLines = @(Get-Content -LiteralPath $smokePath -Encoding UTF8)
    foreach ($mutantFn in @('Start-BitLockerDecrypt')) {
        [object[]] $callLines = @($smokeLines | Where-Object {
            $_ -match "\b$([regex]::Escape($mutantFn))\b" -and
            $_.TrimStart() -notmatch '^#' -and
            $_ -notmatch '-match\s' -and
            $_ -notmatch '-notmatch\s' -and
            $_ -notmatch "'\s*$([regex]::Escape($mutantFn))" -and
            $_ -notmatch "@'\s*$([regex]::Escape($mutantFn))"
        })
        if ($callLines.Count -gt 0) {
            throw "smoke.ps1 llama a $mutantFn (funcion mutante): $($callLines[0].Trim())"
        }
    }
}

# ─── #23a: Test-IsX3dDualCcdCpu (funcion pura) ────────────────────────────────
Test-SmokeFunction 'PowerPlan' 'Test-IsX3dDualCcdCpu: dual-CCD true / single-CCD false' {
    $ErrorActionPreference = 'Stop'
    if (-not (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 9 7950X3D 16-Core Processor' -Cores 16)) { throw '7950X3D/16 debe ser true' }
    if (-not (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 9 9900X3D 12-Core Processor' -Cores 12)) { throw '9900X3D/12 debe ser true' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 7 9800X3D 8-Core Processor' -Cores 8)  { throw '9800X3D/8 debe ser false (single-CCD)' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 7 7800X3D 8-Core Processor' -Cores 8)  { throw '7800X3D/8 debe ser false (single-CCD)' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 5 5600X 6-Core Processor' -Cores 6)    { throw '5600X debe ser false (no X3D)' }
    if (Test-IsX3dDualCcdCpu -CpuName '' -Cores 0)                                       { throw 'vacio debe ser false' }
}

# ─── #23b: Get-RamAdvisories (funcion pura; canario StrictMode de 1 elemento) ──
Test-SmokeFunction 'HwAdvisories' 'Get-RamAdvisories: 1 modulo -> single-channel' {
    $ErrorActionPreference = 'Stop'
    [object[]] $one = @([PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 })
    [object[]] $adv = @(Get-RamAdvisories -Modules $one)
    if ($adv.Count -ne 1)                          { throw ("1 modulo debe dar 1 aviso; got {0}" -f $adv.Count) }
    if ($adv[0] -notmatch 'single-channel')        { throw ("aviso esperado single-channel; got '{0}'" -f $adv[0]) }
}
Test-SmokeFunction 'HwAdvisories' 'Get-RamAdvisories: XMP off detectado / dual ok sin avisos' {
    $ErrorActionPreference = 'Stop'
    [object[]] $xmpOff = @(
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 2133 }
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 2133 }
    )
    [object[]] $adv = @(Get-RamAdvisories -Modules $xmpOff)
    if (@($adv | Where-Object { $_ -match 'XMP' }).Count -ne 1) { throw 'dual a 2133/3200 debe avisar XMP' }
    [object[]] $ok = @(
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 }
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 }
    )
    if (@(Get-RamAdvisories -Modules $ok).Count -ne 0) { throw 'dual a rated no debe avisar' }
    if (@(Get-RamAdvisories -Modules @()).Count -ne 0) { throw 'vacio no debe avisar' }
}
Test-SmokeFunction 'HwAdvisories' 'Test-IsIntegratedGpuName: APU moderna (TM) = iGPU, dGPU sigue dGPU' {
    $ErrorActionPreference = 'Stop'
    # Regresion #23b: "(TM)" rompia el match y clasificaba la APU como dGPU
    if (-not (Test-IsIntegratedGpuName -GpuName 'AMD Radeon(TM) Graphics'))      { throw 'Radeon(TM) Graphics debe ser iGPU' }
    if (-not (Test-IsIntegratedGpuName -GpuName 'AMD Radeon(TM) 780M Graphics')) { throw 'Radeon(TM) 780M debe ser iGPU' }
    if (-not (Test-IsIntegratedGpuName -GpuName 'Radeon RX Vega 11 Graphics'))   { throw 'Vega 11 debe ser iGPU' }
    if (Test-IsIntegratedGpuName -GpuName 'AMD Radeon RX 6600')                  { throw 'RX 6600 debe ser dGPU' }
    if (Test-IsIntegratedGpuName -GpuName 'NVIDIA GeForce RTX 3060')             { throw 'RTX 3060 debe ser dGPU' }
}
Test-SmokeFunction 'HwAdvisories' 'Get-UmaAdvisory: APU UMA chico avisa / dGPU e Intel no' {
    $ErrorActionPreference = 'Stop'
    [string] $a = Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes (2GB)
    if ([string]::IsNullOrEmpty($a) -or $a -notmatch 'UMA') { throw ("APU 2GB debe avisar UMA; got '{0}'" -f $a) }
    if ((Get-UmaAdvisory -HasIGpuOnly $false -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes (2GB)) -ne '') { throw 'con dGPU no debe avisar' }
    if ((Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'Intel(R) UHD Graphics 630' -AdapterRamBytes (1GB)) -ne '') { throw 'Intel iGPU no debe avisar (UMA es de APU AMD)' }
    if ((Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes 0) -ne '') { throw 'AdapterRAM 0 (desconocido/overflow) no debe avisar' }
}
Test-SmokeFunction 'HwAdvisories' 'Get-MachineProfile expone Advisories como [string[]]' {
    $ErrorActionPreference = 'Stop'
    $mp = Get-MachineProfile
    if ($null -eq $mp.PSObject.Properties['Advisories']) { throw 'falta propiedad Advisories' }
    [object[]] $a = @($mp.Advisories)
    foreach ($x in $a) { if ($x -isnot [string]) { throw 'Advisories debe contener solo strings' } }
}

# ─── ClientReport: New-ClientReport + Invoke-ClientReport ────────────────────
Test-SmokeFunction 'ClientReport' 'New-ClientReport e Invoke-ClientReport definidas' {
    foreach ($fn in @('New-ClientReport', 'Invoke-ClientReport')) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "$fn no encontrado"
        }
    }
}

Test-SmokeFunction 'ClientReport' 'New-ClientReport: HTML valido desde fixture completo' {
    $ErrorActionPreference = 'Stop'

    # Fixture POST snapshot (1 disco, 1 GPU -- canario 1-elemento StrictMode)
    [PSCustomObject] $postSnap = [PSCustomObject]@{
        ComputerName = 'PC-SMOKE'
        CPU          = [PSCustomObject]@{ Name = 'Intel Core i5-12400'; Cores = 6; Threads = 12 }
        RamTotalGb   = 16
        RamSlots     = @([PSCustomObject]@{ Slot = 'DIMM1'; CapacityGb = 16; SpeedMhz = 3200; Manufacturer = 'Kingston' })
        GPU          = @([PSCustomObject]@{ Name = 'NVIDIA GeForce RTX 3060'; Type = 'Dedicated'; DriverVersion = '555.0' })
        Disks        = @([PSCustomObject]@{ Name = 'Samsung 870 EVO'; MediaType = 'SSD'; SizeGb = 500; HealthStatus = 'Healthy'; TempC = 38; WearPct = 12 })
        Volumes      = @([PSCustomObject]@{ Letter = 'C'; Label = 'Sistema'; SizeGb = 500; FreeGb = 280; UsedPct = 44 })
        Battery      = $null
        PowerPlan    = $null
    }

    # Fixture Compare
    [PSCustomObject] $cmp = [PSCustomObject]@{
        PreRunningCount  = 120
        PostRunningCount = 95
        ServicesDelta    = -25
        VolumeDiff       = @([PSCustomObject]@{ Letter = 'C'; SpaceFreedGb = 8.5; PreFreeGb = 271.5; PostFreeGb = 280.0; PreUsedPct = 46; PostUsedPct = 44 })
        TotalFreedGb     = 8.5
        BloatFixed       = @()
        StartupDelta     = 0
        PreStartupCount  = 12
        PostStartupCount = 12
        AvFixed          = $false
        Rebooted         = $true
        Score            = 5
        ScoreMax         = 6
        Improvements     = @()
    }

    # Fixture Result parcial
    [PSCustomObject] $result = [PSCustomObject]@{
        RestorePoint = [PSCustomObject]@{ Done = $true }
        Debloat      = [PSCustomObject]@{ Disabled = 18; TotalTargeted = 30 }
        Cleanup      = [PSCustomObject]@{ FreedGB = 8.5 }
        Performance  = [PSCustomObject]@{ Done = $true }
        Privacy      = [PSCustomObject]@{ Success = $true; Path = 'oosu' }
        PostSnapshot = [PSCustomObject]@{ Ok = $false }
        Compare      = $cmp
        Startup      = [PSCustomObject]@{ Count = 12; ReportedOnly = $true }
        ClientRun    = $null
    }

    [string] $tmp = Join-Path $env:TEMP ('pctk-cr-smoke-' + [System.IO.Path]::GetRandomFileName() + '.html')
    try {
        $r = New-ClientReport -Result $result -PostSnapshot $postSnap -Compare $cmp -OutputPath $tmp
        if (-not $r.Success)               { throw 'New-ClientReport retorno Success=false' }
        if (-not (Test-Path -LiteralPath $tmp)) { throw 'Archivo HTML no creado' }
        [string] $body = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
        # Titulos de seccion
        foreach ($expected in @('Tu equipo','Que hicimos','Antes y despues')) {
            if ($body -notmatch [regex]::Escape($expected)) {
                throw ("HTML no contiene seccion '{0}'" -f $expected)
            }
        }
        # Datos del fixture visibles
        if ($body -notmatch 'Intel Core i5') { throw 'CPU no aparece en el HTML' }
        if ($body -notmatch '8.5')           { throw 'GB liberados no aparece en el HTML' }
        if ($body -notmatch 'PC-SMOKE')      { throw 'ComputerName no aparece en el HTML' }
        # Sin placeholders sin sustituir
        if ($body -match '\$\{') { throw 'HTML contiene placeholders sin sustituir' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Test-SmokeFunction 'ClientReport' 'New-ClientReport: honestidad - sin PRE/POST no hay panel Antes/Despues' {
    $ErrorActionPreference = 'Stop'
    [string] $tmp = Join-Path $env:TEMP ('pctk-cr-nopre-' + [System.IO.Path]::GetRandomFileName() + '.html')
    try {
        # Solo un result minimo, sin Compare
        [PSCustomObject] $result = [PSCustomObject]@{
            RestorePoint = [PSCustomObject]@{ Done = $false }
            Debloat      = $null
            Cleanup      = $null
            Performance  = $null
            Privacy      = [PSCustomObject]@{ Success = $false }
            PostSnapshot = [PSCustomObject]@{ Ok = $false }
            Compare      = $null
            Startup      = $null
            ClientRun    = $null
        }
        $r = New-ClientReport -Result $result -Compare $null -OutputPath $tmp
        if (-not $r.Success)               { throw 'New-ClientReport retorno Success=false' }
        if (-not (Test-Path -LiteralPath $tmp)) { throw 'Archivo HTML no creado' }
        [string] $body = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
        # El panel Antes y Despues aparece con nota suave (no desaparece, se rinde con mensaje)
        if ($body -notmatch 'Antes y despues') { throw 'Seccion Antes y Despues ausente del HTML' }
        if ($body -notmatch 'no disponible')   { throw 'Nota suave de compare ausente' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Test-SmokeFunction 'ClientReport' 'New-ClientReport: fixture 1 disco + 1 GPU no lanza bajo StrictMode' {
    # Canario trampa @() en if con 1-elemento: GPU[0] y Disks[0] bajo EAP=Stop + StrictMode
    $ErrorActionPreference = 'Stop'
    [PSCustomObject] $postSnap = [PSCustomObject]@{
        ComputerName = 'PC-1SLOT'
        CPU          = [PSCustomObject]@{ Name = 'AMD Ryzen 5 5600'; Cores = 6; Threads = 12 }
        RamTotalGb   = 8
        RamSlots     = @([PSCustomObject]@{ Slot = 'DIMM0'; CapacityGb = 8; SpeedMhz = 3200; Manufacturer = 'Unknown' })
        GPU          = @([PSCustomObject]@{ Name = 'AMD Radeon RX 6600'; Type = 'Dedicated'; DriverVersion = '24.0' })
        Disks        = @([PSCustomObject]@{ Name = 'WD Blue 1TB'; MediaType = 'HDD'; SizeGb = 1000; HealthStatus = 'Healthy'; TempC = 32; WearPct = 0 })
        Volumes      = @([PSCustomObject]@{ Letter = 'C'; Label = ''; SizeGb = 1000; FreeGb = 400; UsedPct = 60 })
        Battery      = $null
        PowerPlan    = $null
    }
    [string] $tmp = Join-Path $env:TEMP ('pctk-cr-1slot-' + [System.IO.Path]::GetRandomFileName() + '.html')
    try {
        $r = New-ClientReport -PostSnapshot $postSnap -OutputPath $tmp
        if (-not $r.Success) { throw 'fallo con fixture de 1 elemento' }
        if (-not (Test-Path -LiteralPath $tmp)) { throw 'Archivo HTML no creado' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Test-SmokeFunction 'ClientReport' 'New-ClientReport: laptop con bateria no crashea (if como arg, EAP=Stop)' {
    # Regresion bug de campo 2026-06-18: el panel de bateria usaba un `if` como
    # ARGUMENTO de _CR_Row -> en laptops PS5.1 lo parsea como el cmdlet 'if' y el
    # reporte se cae. Las fixtures previas tenian Battery=$null y NO lo ejercitaban.
    # EAP=Stop espeja main.ps1 (el smoke corre con Continue, que no cazaria el crash).
    $ErrorActionPreference = 'Stop'
    [PSCustomObject] $postSnap = [PSCustomObject]@{
        ComputerName = 'LAPTOP-BAT'
        CPU          = [PSCustomObject]@{ Name = 'Intel Core i5-1135G7'; Cores = 4; Threads = 8 }
        RamTotalGb   = 16
        RamSlots     = @([PSCustomObject]@{ Slot = 'DIMM0'; CapacityGb = 16; SpeedMhz = 3200; Manufacturer = 'Unknown' })
        GPU          = @([PSCustomObject]@{ Name = 'Intel Iris Xe'; Type = 'Integrated'; DriverVersion = '31.0' })
        Disks        = @([PSCustomObject]@{ Name = 'PM9B1 512GB'; MediaType = 'SSD'; SizeGb = 512; HealthStatus = 'Healthy'; TempC = 38; WearPct = 2 })
        Volumes      = @([PSCustomObject]@{ Letter = 'C'; Label = ''; SizeGb = 512; FreeGb = 220; UsedPct = 57 })
        Battery      = [PSCustomObject]@{ ChargePercent = 85; HealthPercent = 92; Status = 'OK' }
        PowerPlan    = $null
    }
    [string] $tmp = Join-Path $env:TEMP ('pctk-cr-bat-' + [System.IO.Path]::GetRandomFileName() + '.html')
    try {
        $r = New-ClientReport -PostSnapshot $postSnap -OutputPath $tmp
        if (-not $r.Success)                    { throw 'New-ClientReport fallo con fixture de bateria' }
        if (-not (Test-Path -LiteralPath $tmp)) { throw 'Archivo HTML no creado' }
        [string] $body = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
        if ($body -notmatch 'Carga actual') { throw 'no renderizo la fila de bateria (Carga actual)' }
        if ($body -notmatch '85%')          { throw 'no renderizo el valor de carga (85%)' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Test-SmokeFunction 'ClientReport' 'Router [8] rutea a Invoke-ClientReport' {
    $ErrorActionPreference = 'Stop'
    [string] $dispDef = (Get-Command Invoke-MainMenuDispatch -CommandType Function).Definition
    if ($dispDef -notmatch "'8'\s*\{\s*Invoke-ClientReport") {
        throw 'dispatch [8] no rutea a Invoke-ClientReport'
    }
}

# ─── Recolector: ServiceState (pieza A del recolector-plan.md) ───────────────
# Tests con fixtures 0/1/N en $env:TEMP (no tocan output\ real).
# El caso EXACTAMENTE-1 es la trampa StrictMode de @()[0]: si se accede a
# elementos de un array en un if-expression, PS5.1 puede desenrollar a escalar.
# ServiceState evita eso con [object[]] explicito + PSObject.Properties.

Test-SmokeFunction 'ServiceState' 'funciones requeridas presentes' {
    $ErrorActionPreference = 'Stop'
    foreach ($fn in @('Get-ServiceStatePath','Get-ServiceState','Open-ServiceState',
                      'Set-ServiceStatePreTaken','Test-ServiceStateStale','Close-ServiceState')) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "$fn no encontrado"
        }
    }
}

Test-SmokeFunction 'ServiceState' 'sin state -> Get-ServiceState devuelve $null + Test-ServiceStateStale false' {
    $ErrorActionPreference = 'Stop'
    # Usar output root en $env:TEMP para no afectar el state real del sistema
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-0-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        $state = Get-ServiceState -OutputRootOverride $tmpRoot
        if ($null -ne $state) { throw ('sin state debe devolver $null; got {0}' -f $state) }
        [bool] $stale = Test-ServiceStateStale -OutputRootOverride $tmpRoot
        if ($stale -ne $false) { throw ('sin state Test-ServiceStateStale debe ser false; got {0}' -f $stale) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Open-ServiceState -> crea state con hostname + idempotente' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-open-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        $s = Open-ServiceState -OutputRootOverride $tmpRoot
        # Debe crear el state
        if ($null -eq $s) { throw 'Open-ServiceState devolvio $null' }
        # hostname correcto
        [string] $hn = if ($null -ne $s.PSObject.Properties['hostname']) { [string]$s.hostname } else { '' }
        if ($hn -ne $env:COMPUTERNAME) { throw ("hostname esperado {0}; got {1}" -f $env:COMPUTERNAME, $hn) }
        # open = true
        if ($null -eq $s.PSObject.Properties['open'] -or [bool]$s.open -ne $true) { throw 'open debe ser true' }
        # pre_taken_at debe ser null o vaciar (no sellar sin PRE)
        [string] $pre = if ($null -ne $s.PSObject.Properties['pre_taken_at']) { [string]$s.pre_taken_at } else { '' }
        if (-not [string]::IsNullOrEmpty($pre) -and $pre -ne 'null') {
            throw ('pre_taken_at debe estar vacio antes de Set-ServiceStatePreTaken; got {0}' -f $pre)
        }
        # Leer desde disco para verificar que se persitio
        $s2 = Get-ServiceState -OutputRootOverride $tmpRoot
        if ($null -eq $s2) { throw 'Get-ServiceState devolvio $null despues de Open' }
        # Idempotencia: abrir de nuevo no pisa el state (el pre_taken_at sigue null)
        $s3 = Open-ServiceState -OutputRootOverride $tmpRoot
        if ($null -eq $s3) { throw 'segundo Open-ServiceState devolvio $null (idempotencia)' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Set-ServiceStatePreTaken sella pre_taken_at (canario exactamente-1 state)' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-pre-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        # Caso EXACTAMENTE-1: un solo state file (la trampa StrictMode tipica)
        [string] $preAt = '2026-06-14T10:05:00-03:00'
        $s = Set-ServiceStatePreTaken -OutputRootOverride $tmpRoot -PreTakenAtOverride $preAt
        if ($null -eq $s) { throw 'Set-ServiceStatePreTaken devolvio $null' }
        [string] $got = if ($null -ne $s.PSObject.Properties['pre_taken_at']) { [string]$s.pre_taken_at } else { '' }
        if ($got -ne $preAt) { throw ("pre_taken_at esperado {0}; got {1}" -f $preAt, $got) }
        # Verificar que persitio en disco (no solo en memoria)
        $s2 = Get-ServiceState -OutputRootOverride $tmpRoot
        if ($null -eq $s2) { throw 'Get-ServiceState $null despues de Set-ServiceStatePreTaken' }
        [string] $got2 = if ($null -ne $s2.PSObject.Properties['pre_taken_at']) { [string]$s2.pre_taken_at } else { '' }
        if ($got2 -ne $preAt) { throw ("pre_taken_at en disco esperado {0}; got {1}" -f $preAt, $got2) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Test-ServiceStateStale: host distinto -> true / mismo host -> false' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-stale-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        # Crear state con hostname distinto (simula USB movido de otra PC)
        [string] $stateDir = Join-Path $tmpRoot 'output\state'
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        [string] $jsonPath = Join-Path $stateDir 'current-run.json'
        @{ schema_version='1.0'; hostname='OTRA-PC'; opened_at='2026-06-01T10:00:00-03:00'; pre_taken_at=$null; open=$true } |
            ConvertTo-Json | Out-File -FilePath $jsonPath -Encoding UTF8
        # Test-ServiceStateStale con host distinto = true (stale)
        [bool] $stale = Test-ServiceStateStale -OutputRootOverride $tmpRoot
        if ($stale -ne $true) { throw 'host distinto debe ser stale (true)' }
        # Cambiar hostname al local para probar el false
        @{ schema_version='1.0'; hostname=$env:COMPUTERNAME; opened_at='2026-06-01T10:00:00-03:00'; pre_taken_at=$null; open=$true } |
            ConvertTo-Json | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
        [bool] $notStale = Test-ServiceStateStale -OutputRootOverride $tmpRoot
        if ($notStale -ne $false) { throw 'mismo host NO debe ser stale (false)' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'JSON ilegible -> Get-ServiceState $null sin tirar' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-corrupt-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $stateDir = Join-Path $tmpRoot 'output\state'
    New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    try {
        # Escribir JSON corrupto (comilla sin cerrar)
        [string] $jsonPath = Join-Path $stateDir 'current-run.json'
        Set-Content -LiteralPath $jsonPath -Value '{"hostname": "PC-TEST", "open": true, "corrupto": "sin cerrar' -Encoding UTF8
        $state = Get-ServiceState -OutputRootOverride $tmpRoot
        if ($null -ne $state) { throw 'JSON corrupto debe devolver $null; got objeto' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Close-ServiceState: borra current-run.json (D3) + no tira si ausente' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-ss-close-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        # Abrir -> verificar que existe -> cerrar -> verificar que desaparecio
        $null = Open-ServiceState -OutputRootOverride $tmpRoot
        [string] $jsonPath = Get-ServiceStatePath -OutputRootOverride $tmpRoot
        if (-not (Test-Path -LiteralPath $jsonPath)) { throw 'state no creado por Open-ServiceState' }
        Close-ServiceState -OutputRootOverride $tmpRoot -WriteClosedLog $false
        if (Test-Path -LiteralPath $jsonPath) { throw 'Close-ServiceState no borro current-run.json (D3)' }
        # Llamar Close de nuevo sin state = no debe tirar (idempotencia)
        Close-ServiceState -OutputRootOverride $tmpRoot -WriteClosedLog $false
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Router [L] rutea a Invoke-ServiceClose -> Invoke-CloseService' {
    $ErrorActionPreference = 'Stop'
    # La cadena cambio al unificar [L]/[U]: el dispatch va a Invoke-ServiceClose,
    # y ES ESE el que llama a Invoke-CloseService (recolector pieza C).
    [string] $dispDef = (Get-Command Invoke-MainMenuDispatch -CommandType Function).Definition
    if ($dispDef -notmatch "'L'\s*\{[\s\S]*?Invoke-ServiceClose") {
        throw 'dispatch [L] no rutea a Invoke-ServiceClose'
    }
    [string] $closeDef = (Get-Command Invoke-ServiceClose -CommandType Function).Definition
    if ($closeDef -notmatch 'Invoke-CloseService') {
        throw 'Invoke-ServiceClose no llama a Invoke-CloseService (recolector pieza C)'
    }
}

# ─── Recolector: New-RunMeta (pieza D1) ──────────────────────────────────────
# Helper puro (sin I/O real): usa fixture de AnyDeskConfPaths para no depender
# de que AnyDesk este instalado en la PC del smoke. Shape completo.

Test-SmokeFunction 'ServiceState' 'New-RunMeta: shape completo + anydesk_id con fixture (D1)' {
    $ErrorActionPreference = 'Stop'
    # Fixture de AnyDesk conf en TEMP para no depender de la instalacion real
    [string] $tmpConf = Join-Path $env:TEMP ('pctk-ad-meta-' + [System.Guid]::NewGuid().ToString('N') + '.conf')
    try {
        Set-Content -LiteralPath $tmpConf -Value @('ad.anynet.id=123456789', 'other=x') -Encoding ASCII
        $meta = New-RunMeta -ClientSlug 'cliente-test' -DateOverride '2026-06-14T10:00:00-03:00' -AnyDeskConfPaths @($tmpConf)
        if ($null -eq $meta) { throw 'New-RunMeta devolvio $null' }
        # Campos obligatorios del shape
        foreach ($k in @('client','date','computer_name','anydesk_id','schema_version','compare_score','status','amount_charged_ars','notes')) {
            if (-not $meta.Contains($k)) { throw ("campo '$k' ausente en New-RunMeta") }
        }
        if ($meta['client'] -ne 'cliente-test') { throw 'client incorrecto' }
        if ($meta['computer_name'] -ne $env:COMPUTERNAME) { throw 'computer_name incorrecto' }
        if ($meta['anydesk_id'] -ne '123456789') { throw ("anydesk_id esperado 123456789; got {0}" -f $meta['anydesk_id']) }
        if ($meta['schema_version'] -ne '1.0') { throw 'schema_version incorrecto' }
        if ($meta['status'] -ne 'closed') { throw 'status debe ser closed' }
    } finally {
        Remove-Item -LiteralPath $tmpConf -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'New-RunMeta: sin AnyDesk instalado -> anydesk_id null sin tirar' {
    $ErrorActionPreference = 'Stop'
    # Ruta inexistente = AnyDesk no instalado
    $meta = New-RunMeta -AnyDeskConfPaths @((Join-Path $env:TEMP 'no-existe\system.conf'))
    if ($null -eq $meta) { throw 'New-RunMeta no debe devolver $null sin AnyDesk' }
    if ($meta.Contains('anydesk_id') -and -not [string]::IsNullOrEmpty([string]$meta['anydesk_id']) -and [string]$meta['anydesk_id'] -ne 'null') {
        throw ('anydesk_id debe ser null sin AnyDesk; got {0}' -f $meta['anydesk_id'])
    }
}

# ─── Recolector: Invoke-CloseService (pieza C) ───────────────────────────────
# Tests con output en $env:TEMP. NO ejercitan Start-TelemetryJob (requiere el
# sistema completo y muta output\snapshots\). Validan el bundle parcial (D4)
# y que meta.json quede en el ZIP.

Test-SmokeFunction 'ServiceState' 'Invoke-CloseService: bundle parcial sin service (D4) -> ZIP con audit' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-cs-partial-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-cs-dest-'    + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-06-14.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        # Sin state abierto + fake AnyDesk conf = bundle parcial (D4)
        [string] $tmpConf = Join-Path $env:TEMP ('pctk-ad-cs-' + [System.Guid]::NewGuid().ToString('N') + '.conf')
        Set-Content -LiteralPath $tmpConf -Value @('ad.anynet.id=999000111') -Encoding ASCII
        try {
            # Shadowear Start-TelemetryJob para que no se ejecute el POST real
            function Start-TelemetryJob { param([string]$Phase); return $null }
            function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }
            $r = Invoke-CloseService -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                     -TimestampOverride '20260614-100000' -AnyDeskConfPaths @($tmpConf)
            # Sin state/sin PRE -> resultado puede ser 'Empty' (si solo extraItems) o 'OK' si hay audit
            if ($r.Status -notin @('OK','Empty')) { throw ("Status esperado OK o Empty; got {0}" -f $r.Status) }
            if ($r.Status -eq 'OK') {
                # Si creo ZIP, verificar que existe y no esta vacio
                if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'ZipPath no existe' }
                # Verificar que el ZIP contiene meta.json
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [object[]] $entries = @()
                $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
                try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) }
                finally { $za.Dispose() }
                [bool] $hasMeta = $false
                foreach ($e in $entries) { if ($e -match 'meta') { $hasMeta = $true } }
                if (-not $hasMeta) { throw 'ZIP del bundle no contiene meta.json (regresion D1)' }
            }
        } finally {
            Remove-Item -LiteralPath $tmpConf -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Invoke-CloseService: cierra state despues de bundle (D3)' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-cs-close-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-cs-dest2-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-06-14.jsonl') -Value '{"Action":"test2"}' -Encoding UTF8
    try {
        # Abrir service (simula PRE tomado)
        [string] $preAt = '2026-06-14T10:00:00-03:00'
        $null = Set-ServiceStatePreTaken -OutputRootOverride $tmpRoot -PreTakenAtOverride $preAt
        [string] $statePath = Get-ServiceStatePath -OutputRootOverride $tmpRoot
        if (-not (Test-Path -LiteralPath $statePath)) { throw 'state no creado antes de CloseService' }
        # Shadowear telemetria para no hacer snapshot real
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }
        $r = Invoke-CloseService -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                 -TimestampOverride '20260614-101500'
        # Verificar que el state fue borrado (D3)
        if (Test-Path -LiteralPath $statePath) {
            throw 'Invoke-CloseService no borro current-run.json (D3)'
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── Canarios de la sesion 2026-07-25 (code-map + combo de campo) ────────────

Test-SmokeFunction 'Bundle' '#29: el bundle lleva reports/ y audits/, y NUNCA recovery/' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-b29-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-b29d-' + [System.Guid]::NewGuid().ToString('N'))
    foreach ($d in @('audit', 'snapshots', 'reports', 'audits', 'recovery')) {
        New-Item -Path (Join-Path $tmpRoot $d) -ItemType Directory -Force | Out-Null
    }
    New-Item -Path $tmpDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tmpRoot 'audit\2026-07-25.jsonl')     -Value '{"Action":"x"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmpRoot 'snapshots\a_pre.json')       -Value '{}'             -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmpRoot 'reports\reporte-cliente.html') -Value '<html></html>' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $tmpRoot 'audits\audit_PC.txt')        -Value 'informe'        -Encoding UTF8
    # El secreto que NUNCA debe viajar (feedback_secrets_not_in_bundles)
    Set-Content -LiteralPath (Join-Path $tmpRoot 'recovery\bitlocker.txt')     -Value '111111-222222'  -Encoding UTF8
    try {
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                     -TimestampOverride '20260725-000000' -TagOverride 'test' `
                                     -ExtraItems @((Join-Path $tmpRoot 'reports'), (Join-Path $tmpRoot 'audits'))
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [string[]] $entries = @()
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) } finally { $za.Dispose() }

        if (-not @($entries | Where-Object { $_ -like 'reports/*' })) { throw 'Falta reports/ en el ZIP' }
        if (-not @($entries | Where-Object { $_ -like 'audits/*' }))  { throw 'Falta audits/ en el ZIP' }
        if (@($entries | Where-Object { $_ -match '(?i)recovery|bitlocker' })) {
            throw 'FUGA DE SECRETO: recovery/ entro al ZIP'
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ClientReport' '#30: sin POST, la ficha del equipo sale del PRE (no el placeholder)' {
    $ErrorActionPreference = 'Stop'
    # El bug: Invoke-ClientReport solo miraba *_post.json; en visita de diagnostico
    # (sin pipeline auto) el reporte salia con el nombre del tecnico y nada mas.
    [PSCustomObject] $preSnap = [PSCustomObject]@{
        Phase = 'Pre'; ComputerName = 'PC-TEST'
        CPU = [PSCustomObject]@{ Name = 'Ryzen 7 5800H'; Cores = 8; Threads = 16 }
        RamTotalGb = 16.0
        Disks = @([PSCustomObject]@{ Name = 'SSD'; MediaType = 'SSD'; SizeGb = 512; HealthStatus = 'Healthy' })
    }
    [string] $out = Join-Path $env:TEMP ('pctk-r30-' + [System.Guid]::NewGuid().ToString('N') + '.html')
    try {
        $r = New-ClientReport -PostSnapshot $preSnap -OutputPath $out
        if (-not $r.Success) { throw 'New-ClientReport fallo' }
        [string] $html = Get-Content -LiteralPath $out -Raw -Encoding UTF8
        if ($html -match 'Informacion del equipo no disponible') {
            throw 'Salio el placeholder: el fallback al PRE no alimento la ficha'
        }
        if ($html -notmatch 'Ryzen 7 5800H') { throw 'La ficha no trae los datos del snapshot' }
        # Honestidad: sin Compare, el panel Antes/Despues DEBE seguir diciendo no disponible
        if ($html -notmatch 'Comparacion PRE/POST no disponible') {
            throw 'Sin Compare, el panel Antes/Despues no deberia mostrarse'
        }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

# ─── #3: salud del disco = enum crudo (health=0 con SSD sano) ────────────────
# El bug: Get-PhysicalDisk corre adentro del runspace de Invoke-WithTimeout y ahi
# HealthStatus/MediaType (MSFT_PhysicalDisk, UInt16) salen como NUMERO: 0=Healthy,
# 4=SSD. El snapshot guardaba '0' y el [8] pintaba un badge ROJO "0" a un disco
# sano; el prompt del LLM decia health=0. Las fixtures traian labels ('Healthy'),
# por eso el smoke no lo veia. Estos tests van por el camino real: el job de
# telemetria (que SOLO dot-sourcea Telemetry.ps1) -> Save-Snapshot -> JSON en
# disco -> el handler del [8] (Invoke-ClientReport). Y un snapshot VIEJO, guardado
# con el numero crudo, tiene que seguir mostrandose bien (compat hacia atras).

# Corre Save-Snapshot en un Start-Job como Start-TelemetryJob (runspace fresco,
# StrictMode, dot-source de Telemetry.ps1 y nada mas), con la raiz de salida
# redirigida a un temp. Devuelve el texto del JSON guardado. Se cachea: el job
# toma un snapshot real y no hace falta repetirlo por test.
$script:Hd3JobJson = $null
function Get-Hd3JobSnapshotJson {
    if ($null -ne $script:Hd3JobJson) { return $script:Hd3JobJson }
    [string] $modPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Telemetry.ps1'
    [string] $fakeRoot = Join-Path $env:TEMP ('pctk-hd3job-' + [System.Guid]::NewGuid().ToString('N'))
    $j = Start-Job -ScriptBlock {
        param([string] $ModPath, [string] $FakeRoot)
        Set-StrictMode -Version Latest
        . $ModPath
        # Save-Snapshot deriva output\snapshots de esta variable: se apunta al temp.
        $script:TelemetryModulePath = Join-Path $FakeRoot 'modules\Telemetry.ps1'
        Save-Snapshot -Phase Post
    } -ArgumentList @($modPath, $fakeRoot)
    try {
        if (-not (Wait-Job $j -Timeout 240)) { throw 'el job de telemetria no termino en 240 s' }
        $saved = Receive-Job $j -ErrorAction Stop
    } finally { Remove-Job $j -Force -ErrorAction SilentlyContinue }
    try {
        if ($null -eq $saved) { throw 'Save-Snapshot no devolvio resultado en el job' }
        [string] $savedPath = [string] $saved.FilePath
        if ($savedPath -notlike ($fakeRoot + '*')) { throw ('el snapshot no cayo en el temp: {0}' -f $savedPath) }
        if (-not (Test-Path -LiteralPath $savedPath)) { throw ('no existe el snapshot guardado: {0}' -f $savedPath) }
        $script:Hd3JobJson = Get-Content -LiteralPath $savedPath -Raw -Encoding UTF8
    } finally {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $script:Hd3JobJson
}

# Corre el HANDLER del [8] contra un snapshot dado como JSON en disco. Se sombrea
# solo el borde: la carpeta output\ (a un temp), Compare-Snapshot, el destino del
# HTML y Start-Process. New-ClientReport es el REAL. Devuelve el HTML.
function Invoke-Hd3ClientReportHarness {
    param([Parameter(Mandatory)] [string] $SnapshotJson)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-hd3cr-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $snapDir = Join-Path $tmpRoot 'snapshots'
    [string] $htmlOut = Join-Path $tmpRoot 'reporte-cliente.html'
    $null = New-Item -ItemType Directory -Path $snapDir -Force
    $SnapshotJson | Out-File -FilePath (Join-Path $snapDir '2026-10-14_120000_post.json') -Encoding UTF8
    $script:Hd3Opened = [System.Collections.Generic.List[string]]::new()
    $realRender = ${function:New-ClientReport}

    function Test-Path {
        [CmdletBinding()] param([Parameter(Position = 0)] [string] $Path, [string] $LiteralPath, [string] $PathType)
        [string] $p = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
        if ($p -match '[\\/]output[\\/](snapshots|reports)$') { return $true }
        return (Microsoft.PowerShell.Management\Test-Path @PSBoundParameters)
    }
    function Get-ChildItem {
        [CmdletBinding()] param([Parameter(Position = 0)] [string] $Path, [string] $Filter, [switch] $File)
        if ($Path -match '[\\/]output[\\/]snapshots$') { $PSBoundParameters['Path'] = $snapDir }
        Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
    }
    function Compare-Snapshot { return $null }
    function Start-Process { param([Parameter(Position = 0)] [string] $FilePath) $script:Hd3Opened.Add($FilePath) }
    function New-ClientReport {
        [CmdletBinding()] param(
            [object] $PostSnapshot, [object] $Compare, [object] $Result,
            [string] $OutputPath, [switch] $OpenAfter
        )
        $PSBoundParameters['OutputPath'] = $htmlOut
        & $realRender @PSBoundParameters
    }

    try {
        [PSCustomObject] $mp = [PSCustomObject]@{ IsLaptop = $false; RamMB = 8192; Tier = 'Mid'; IsHome = $true }
        Invoke-ClientReport -MachineProfile $mp | Out-Null
        if (-not (Test-Path -LiteralPath $htmlOut)) { throw 'el handler [8] no genero el HTML' }
        return (Get-Content -LiteralPath $htmlOut -Raw -Encoding UTF8)
    } finally {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Snapshot VIEJO tal como lo guardaba el job antes del fix: numeros como string.
# Un disco por cada valor del enum de MSFT_PhysicalDisk.HealthStatus (0/1/2/5).
$script:Hd3OldSnapJson = @'
{
  "Phase": "Post",
  "ComputerName": "PC-HD3-VIEJO",
  "CPU": { "Name": "AMD Ryzen 5 5600G", "Cores": 6, "Threads": 12 },
  "RamTotalGb": 16,
  "Disks": [
    { "Name": "SAMSUNG MZALQ512HBLU-00BL2", "MediaType": "4", "SizeGb": 476.94, "HealthStatus": "0", "TempC": null, "WearPct": null },
    { "Name": "ST9500325AS", "MediaType": "3", "SizeGb": 465.76, "HealthStatus": "1", "TempC": null, "WearPct": null },
    { "Name": "WDC ROTO", "MediaType": "3", "SizeGb": 931.51, "HealthStatus": "2", "TempC": null, "WearPct": null },
    { "Name": "DISCO RARO", "MediaType": "0", "SizeGb": 100, "HealthStatus": "5", "TempC": null, "WearPct": null }
  ]
}
'@

Test-SmokeFunction 'DiscoSalud' '#3 job real de telemetria (solo Telemetry.ps1): el snapshot guarda el label, no el enum crudo' {
    $ErrorActionPreference = 'Stop'
    [object] $snap = (Get-Hd3JobSnapshotJson) | ConvertFrom-Json
    [object[]] $disks = @($snap.Disks)
    if ($disks.Count -lt 1) { throw 'el job no trajo discos: sin disco no se ejercita la normalizacion' }
    foreach ($d in $disks) {
        [string] $h = [string] $d.HealthStatus
        [string] $m = [string] $d.MediaType
        if ($h -notin @('Healthy', 'Warning', 'Unhealthy', 'Unknown')) {
            throw ('HealthStatus "{0}" en {1}: se esperaba Healthy/Warning/Unhealthy/Unknown' -f $h, $d.Name)
        }
        # En ingles, como lo lee el CRM (que omite 'Unspecified' del renglon).
        if ($m -notin @('HDD', 'SSD', 'SCM', 'Unspecified')) { throw ('MediaType "{0}" en {1}: se esperaba HDD/SSD/SCM/Unspecified' -f $m, $d.Name) }
    }
}

Test-SmokeFunction 'DiscoSalud' '#3 job -> Save-Snapshot -> handler [8]: el badge del disco dice su estado en castellano' {
    [string] $html = Invoke-Hd3ClientReportHarness -SnapshotJson (Get-Hd3JobSnapshotJson)
    if ($html -match 'class="badge badge-\w+">\d+</span>') { throw 'el [8] pinta un badge con el numero crudo del enum' }
    if ($html -match 'GB\s+\[\d+\]') { throw 'el [8] muestra el tipo de disco como numero ([4]/[3])' }
    if ($html -notmatch 'class="badge badge-(ok|warn|bad|na)">(Sano|Con advertencias|Con fallas|Sin dato)</span>') {
        throw 'el [8] no muestra el estado del disco con su significado'
    }
}

Test-SmokeFunction 'DiscoSalud' '#3 snapshot VIEJO con enum crudo: el handler [8] muestra Sano/advertencias/fallas/sin dato (compat)' {
    [string] $html = Invoke-Hd3ClientReportHarness -SnapshotJson $script:Hd3OldSnapJson
    foreach ($want in @('badge-ok">Sano<', 'badge-warn">Con advertencias<', 'badge-bad">Con fallas<', 'badge-na">Sin dato<')) {
        if ($html -notmatch [regex]::Escape($want)) { throw ('falta {0} en el HTML del [8]' -f $want) }
    }
    if ($html -match 'class="badge badge-\w+">\d+</span>') { throw 'badge con numero crudo en el [8]' }
    if ($html -notmatch '\[SSD\]' -or $html -notmatch '\[HDD\]') { throw 'el tipo de disco no sale como SSD/HDD' }
    if ($html -match 'GB\s+\[\d+\]') { throw 'el tipo de disco sale como numero' }
}

Test-SmokeFunction 'DiscoSalud' '#3 snapshot VIEJO: el informe tecnico [I] y el prompt del LLM no dicen health=0' {
    $ErrorActionPreference = 'Stop'
    [object] $old = $script:Hd3OldSnapJson | ConvertFrom-Json
    if ($null -eq $script:_snapshotResult) { $script:_snapshotResult = Get-SystemSnapshot -Phase Pre }
    [PSCustomObject] $viejo = $script:_snapshotResult.PSObject.Copy()
    $viejo.Disks = @($old.Disks)

    [object] $ra = New-RawAuditReport -Snapshot $viejo
    try {
        if (-not $ra.Success) { throw 'New-RawAuditReport fallo con un snapshot viejo' }
        [string] $body = Get-Content -LiteralPath $ra.FilePath -Raw
        if ($body -match 'health=\d') { throw 'el informe [I] imprime health=<numero>' }
        if ($body -notmatch 'health=Healthy' -or $body -notmatch 'health=Unhealthy') { throw 'el informe [I] no traduce el estado del disco' }
        if ($body -match 'GB\s+\[\d+\]') { throw 'el informe [I] imprime el tipo de disco como numero' }
    } finally {
        if ($ra.FilePath -and (Test-Path -LiteralPath $ra.FilePath)) { Remove-Item -LiteralPath $ra.FilePath -Force -ErrorAction SilentlyContinue }
    }

    [object] $rp = New-ResearchPrompt -Template Optimization -Snapshot $old -MachineProfile ([PSCustomObject]@{ })
    try {
        if ($null -eq $rp -or -not $rp.Success) { throw 'New-ResearchPrompt fallo con un snapshot viejo' }
        [string] $prompt = Get-Content -LiteralPath $rp.FilePath -Raw -Encoding UTF8
        if ($prompt -match 'health=\d') { throw 'el prompt del LLM dice health=<numero>' }
        if ($prompt -notmatch '\[SSD\] health=Healthy') { throw 'el prompt del LLM no traduce el disco sano (SSD/Healthy)' }
    } finally {
        if ($null -ne $rp -and $rp.FilePath -and (Test-Path -LiteralPath $rp.FilePath)) { Remove-Item -LiteralPath $rp.FilePath -Force -ErrorAction SilentlyContinue }
    }
}

Test-SmokeFunction 'Diagnostics' 'BSOD: BsodCount y PowerCount se cuentan por separado' {
    $ErrorActionPreference = 'Stop'
    # Regresion del caso Olivo: 1 BSOD + 5 apagones se leia como "6 crashes".
    $d = Get-BsodHistory -Days 1
    foreach ($campo in @('BsodCount', 'PowerCount', 'TotalCrashes', 'ReadFailed')) {
        if (-not $d.PSObject.Properties[$campo]) { throw ("Falta el campo {0}" -f $campo) }
    }
    if ([int]$d.BsodCount + [int]$d.PowerCount -ne [int]$d.TotalCrashes) {
        throw ('BsodCount({0}) + PowerCount({1}) != TotalCrashes({2})' -f $d.BsodCount, $d.PowerCount, $d.TotalCrashes)
    }
    if ([bool]$d.ReadFailed -and [string]::IsNullOrEmpty($d.ReadError)) {
        throw 'ReadFailed=true pero sin ReadError: no se puede distinguir el fallo'
    }
}

# #88: [A][7] backup de drivers crasheaba con PropertyNotFoundStrict 'Total' (gate
# Sandbox v2.10.1). Backup-Drivers tenia 3 formas de retorno y solo la final traia
# Total; la de "0 candidatos" (Sandbox, o PC con DISM roto) va por la rama de exito
# del handler, que leia $r.Total bajo StrictMode.
# Los tests del handler le pasan las formas TAL COMO LAS DEVOLVIA Backup-Drivers
# antes del fix (sin Total en las ramas tempranas): el resultado viene serializado
# de un job, y el handler tiene que aguantar un objeto sin la propiedad aunque la
# funcion ya la traiga. Se sombrean el job, la espera, la auditoria y los renderers.
function Invoke-DriverBackupHarness {
    param([PSCustomObject] $Result)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $script:DbResult = $Result
    $script:DbOut    = [System.Collections.Generic.List[string]]::new()
    $script:DbAudit  = [System.Collections.Generic.List[string]]::new()
    function Start-DriverBackupJob { param($OutputRoot) 'job-falso' }
    function Invoke-JobWithProgress { param($Jobs, $Activity, $TimeoutSeconds) , @($script:DbResult) }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:DbAudit.Add(('{0}|{1}|{2}' -f $Action, $Status, $Summary)) }
    function Write-Host { $script:DbOut.Add(($args -join ' ')) }
    function Write-PctkWarn { param([AllowEmptyString()][string] $Text) $script:DbOut.Add(('warn:{0}' -f $Text)) }
    function Write-PctkHint { param([AllowEmptyString()][string] $Text) $script:DbOut.Add(('hint:{0}' -f $Text)) }
    function Write-PctkWork { param([AllowEmptyString()][string] $Text) $script:DbOut.Add(('work:{0}' -f $Text)) }
    function Write-PctkOk   { param([AllowEmptyString()][string] $Text) $script:DbOut.Add(('ok:{0}' -f $Text)) }
    Invoke-ActionDriverBackup -MachineProfile ([PSCustomObject]@{}) | Out-Null
    return [PSCustomObject]@{
        Text  = ($script:DbOut -join "`n")
        Audit = @($script:DbAudit)
    }
}
Test-SmokeFunction 'Diagnostics' 'handler [A][7] drivers: 0 candidatos sin Total no crashea y lo dice legible (#88)' {
    $r = Invoke-DriverBackupHarness -Result ([PSCustomObject]@{
        Success     = $true
        Destination = 'C:\x\driver_backup\2026'
        Exported    = 0
        Message     = 'No se encontraron drivers de terceros para exportar.'
    })
    if ($r.Text -notmatch 'No se encontraron drivers de terceros') { throw ('falta el mensaje legible de 0 drivers: ' + $r.Text) }
    if ($r.Text -match '0 drivers exportados de') { throw ('muestra el conteo crudo en vez del mensaje: ' + $r.Text) }
    if (-not ($r.Audit | Where-Object { $_ -like 'Drivers.Backup|Success|*' })) { throw ('sin auditoria Success: ' + ($r.Audit -join ' / ')) }
}
Test-SmokeFunction 'Diagnostics' 'handler [A][7] drivers: falla de carpeta va por la rama de falla (#88)' {
    $r = Invoke-DriverBackupHarness -Result ([PSCustomObject]@{
        Success     = $false
        Destination = 'C:\x\driver_backup\2026'
        Exported    = 0
        Message     = 'No se pudo crear la carpeta de destino: acceso denegado'
    })
    if ($r.Text -notmatch 'warn:.*No se pudo crear la carpeta') { throw ('falta el aviso de falla: ' + $r.Text) }
    if (-not ($r.Audit | Where-Object { $_ -like 'Drivers.Backup|Failed|*' })) { throw ('sin auditoria Failed: ' + ($r.Audit -join ' / ')) }
}
Test-SmokeFunction 'Diagnostics' 'handler [A][7] drivers: exito completo muestra exportados/candidatos (#88)' {
    $r = Invoke-DriverBackupHarness -Result ([PSCustomObject]@{
        Success     = $true
        Destination = 'C:\x\driver_backup\2026'
        Exported    = 5
        Total       = 7
        Message     = 'Backup completado.'
    })
    if ($r.Text -notmatch 'ok:.*5 drivers exportados de 7 candidatos') { throw ('falta el conteo 5/7: ' + $r.Text) }
    if (-not ($r.Audit | Where-Object { $_ -like 'Drivers.Backup|Success|5/7*' })) { throw ('auditoria sin 5/7: ' + ($r.Audit -join ' / ')) }
}
# La funcion: las 3 ramas devuelven la MISMA forma. Get-WindowsDriver / Export-WindowsDriver
# / New-Item sombreados; la carpeta real va a TEMP y se borra.
Test-SmokeFunction 'Diagnostics' 'Backup-Drivers: sin drivers de terceros devuelve Total=0 (#88)' {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    [string] $root = Join-Path $env:TEMP ('pctk-smoke-drv-' + [guid]::NewGuid().ToString('N'))
    try {
        function Get-WindowsDriver { param([switch] $Online, [switch] $All) }
        $d = Backup-Drivers -OutputRoot $root
        foreach ($campo in @('Success', 'Destination', 'Exported', 'Total', 'Message')) {
            if (-not $d.PSObject.Properties[$campo]) { throw ('Falta el campo {0}' -f $campo) }
        }
        if ([int] $d.Total -ne 0) { throw ('Total={0}, esperado 0' -f $d.Total) }
        if (-not $d.Success) { throw '0 candidatos deberia ser Success=$true' }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-SmokeFunction 'Diagnostics' 'Backup-Drivers: falla de carpeta y exito traen la misma forma (#88)' {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    [string[]] $forma = @('Success', 'Destination', 'Exported', 'Total', 'Message')
    # (b) falla de carpeta: New-Item tira.
    & {
        function New-Item { throw 'acceso denegado' }
        $d = Backup-Drivers -OutputRoot 'C:\no-existe-pctk'
        foreach ($campo in $forma) { if (-not $d.PSObject.Properties[$campo]) { throw ('falla de carpeta: falta {0}' -f $campo) } }
        if ($d.Success) { throw 'falla de carpeta con Success=$true' }
        if ([int] $d.Total -ne 0) { throw ('falla de carpeta: Total={0}, esperado 0' -f $d.Total) }
    }
    # (c) exito: 2 drivers OEM de terceros, Export-WindowsDriver no tira.
    [string] $root = Join-Path $env:TEMP ('pctk-smoke-drv-' + [guid]::NewGuid().ToString('N'))
    try {
        & {
            function Get-WindowsDriver { param([switch] $Online, [switch] $All)
                [PSCustomObject]@{ Driver = 'oem1.inf'; ProviderName = 'Realtek'; ClassName = 'Net' }
                [PSCustomObject]@{ Driver = 'oem2.inf'; ProviderName = 'NVIDIA';  ClassName = 'Display' }
            }
            function Export-WindowsDriver { param([switch] $Online, $Destination) }
            $d = Backup-Drivers -OutputRoot $root
            foreach ($campo in $forma) { if (-not $d.PSObject.Properties[$campo]) { throw ('exito: falta {0}' -f $campo) } }
            if (-not $d.Success -or [int] $d.Exported -ne 2 -or [int] $d.Total -ne 2) { throw ('exito: Success={0} Exported={1} Total={2}' -f $d.Success, $d.Exported, $d.Total) }
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'MachineProfile' '#28: expone Manufacturer / Model / SerialNumber' {
    $ErrorActionPreference = 'Stop'
    $mp = Get-MachineProfile
    foreach ($campo in @('Manufacturer', 'Model', 'SerialNumber')) {
        if (-not $mp.PSObject.Properties[$campo]) { throw ("Falta el campo {0}" -f $campo) }
        if ($null -eq $mp.$campo) { throw ("{0} es null (deberia ser '' si no hay dato)" -f $campo) }
    }
}

Test-SmokeFunction 'Router' 'Menu [I] informe tecnico cableado a Invoke-RawAuditReport' {
    if (-not (Get-Command -Name 'Invoke-RawAuditReport' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Invoke-RawAuditReport no esta definida'
    }
    if (-not (Get-Command -Name 'New-RawAuditReport' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'New-RawAuditReport no esta definida'
    }
    [object[]] $rows = Get-MainMenuRows
    if (-not @($rows | Where-Object { $_.Kind -eq 'Item' -and $_.Key -eq 'I' })) {
        throw 'El menu principal no tiene la tecla [I]'
    }
}

Test-SmokeFunction 'Router' 'Invoke-ClientReport corre bajo StrictMode sin snapshots (handler, no renderer)' {
    # POR QUE ESTE TEST: el de '#30 fallback al PRE' probaba New-ClientReport (el
    # renderer) y dejaba pasar un crash en Invoke-ClientReport (el HANDLER del [8]).
    # Real: quedo un `$null = $isPreFallback` leyendo una variable que solo se
    # asignaba dentro de un if -> sin snapshots, StrictMode tiraba VariableIsUndefined
    # y el [8] moria. Lo cazo Mateo probando a mano, no el smoke.
    # Este test ejercita el handler COMPLETO con StrictMode y sin snapshots (el peor
    # caso: ninguna rama del if se ejecuta).
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    # Shadowear el renderer y la apertura: nos interesa la logica del handler.
    function New-ClientReport {
        [CmdletBinding()] param(
            [object] $PostSnapshot, [object] $Compare, [object] $Result,
            [string] $OutputPath, [switch] $OpenAfter
        )
        return [PSCustomObject]@{ Success = $true; FilePath = 'fake.html' }
    }
    function Compare-Snapshot { throw 'sin snapshots' }

    [PSCustomObject] $mp = [PSCustomObject]@{
        IsLaptop = $false; RamMB = 8192; Tier = 'Mid'; IsHome = $true
    }
    # No debe tirar. Si vuelve a aparecer una variable leida sin asignar, explota aca.
    Invoke-ClientReport -MachineProfile $mp | Out-Null
}

Test-SmokeFunction 'Router' '#52: un handler que tira NO cierra PCTk (guard del dispatch)' {
    # POR QUE ESTE TEST: hasta v2.8.0 ningun dispatch tenia try/catch y main.ps1
    # corre con EAP='Stop' y un try/finally SIN catch -> cualquier excepcion de
    # cualquier handler cerraba PCTk entero, sin dejar el texto del error. Por eso
    # el crash del listado de apps (#52, campo 2026-08-24) se reporto "sin error":
    # la consola se cerraba antes de poder leerlo.
    # Se prueba por COMPORTAMIENTO (no buscando el try/catch en el texto del
    # archivo): si el guard se cae o el codigo se muda de archivo, este test falla
    # igual, en vez de quedar verde por vacuidad.
    $ErrorActionPreference = 'Stop'   # espejar main.ps1 (el smoke corre en Continue)
    Set-StrictMode -Version Latest

    # Secuencia del menu: '8' (listado de apps, que va a tirar) y despues 'B' (volver).
    $script:PctkSmokeChoiceQueue = [System.Collections.Generic.Queue[string]]::new()
    $script:PctkSmokeChoiceQueue.Enqueue('8')
    $script:PctkSmokeChoiceQueue.Enqueue('B')
    try {
        function Read-PctkMenuChoice { param($Rows, $RenderHeader) return $script:PctkSmokeChoiceQueue.Dequeue() }
        function Read-Host  { param([string]$Prompt) return '' }
        function Write-Host { }
        function Write-PctkErr  { }
        function Write-PctkHint { }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        # El handler explota, igual que en la PC de Lucio.
        function Invoke-ActionApps { param($MachineProfile) throw 'BOOM simulado del handler (#52)' }

        # Si el guard NO esta, el throw escapa hasta aca y el test da FAIL.
        Show-IndividualActionsSubmenu -MachineProfile ([PSCustomObject]@{ Dummy = $true })

        # Y ademas el loop tiene que haber seguido vivo: la 'B' se consumio.
        if ($script:PctkSmokeChoiceQueue.Count -ne 0) {
            throw ('el loop no siguio despues del crash: quedaron {0} opciones sin consumir' -f
                   $script:PctkSmokeChoiceQueue.Count)
        }
    }
    finally {
        Remove-Variable -Name 'PctkSmokeChoiceQueue' -Scope Script -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Router' '#52: el guard tambien cubre el menu PRINCIPAL, no solo el submenu [A]' {
    # Son dos loops distintos (Show-MainMenu y Show-IndividualActionsSubmenu) con dos
    # guards distintos. Si alguien saca el del principal, el test del submenu sigue
    # verde y no se entera nadie: por eso este cubre el otro loop aparte.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    # '8' = informe del cliente (lo hacemos tirar) y despues 'X' para salir del loop.
    $script:PctkSmokeChoiceQueue = [System.Collections.Generic.Queue[string]]::new()
    $script:PctkSmokeChoiceQueue.Enqueue('8')
    $script:PctkSmokeChoiceQueue.Enqueue('X')
    try {
        function Read-PctkMenuChoice { param($Rows, $RenderHeader) return $script:PctkSmokeChoiceQueue.Dequeue() }
        function Read-Host  { param([string]$Prompt) return '' }
        function Write-Host { }
        function Write-PctkErr  { }
        function Write-PctkHint { }
        function Write-PctkWork { }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        function Invoke-ClientReport { param($MachineProfile) throw 'BOOM simulado del handler (#52)' }

        [string] $salida = Show-MainMenu -MachineProfile ([PSCustomObject]@{ Dummy = $true })

        if ($salida -ne 'X') { throw ('el loop no llego a la salida limpia; devolvio "{0}"' -f $salida) }
        if ($script:PctkSmokeChoiceQueue.Count -ne 0) {
            throw ('el loop no siguio despues del crash: quedaron {0} opciones sin consumir' -f
                   $script:PctkSmokeChoiceQueue.Count)
        }
    }
    finally {
        Remove-Variable -Name 'PctkSmokeChoiceQueue' -Scope Script -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Apps' '#52: Invoke-ActionApps completo con el job REAL (handler, no la funcion pura)' {
    # POR QUE ESTE TEST: el smoke probaba Get-InstalledWin32Apps/UwpApps DIRECTO, que
    # es justo el camino que NO corre en produccion: el handler las manda a un
    # background job (lección del #24, CLAUDE.md "Testear el HANDLER, no solo la
    # funcion pura"). Este corre el job de verdad y el handler entero.
    $ErrorActionPreference = 'Stop'   # espejar main.ps1; el smoke corre en Continue
    Set-StrictMode -Version Latest

    function Read-Host { param([string]$Prompt) return 'V' }   # 'V' = volver; NO desinstala nada
    function Write-Host { }
    function Write-PctkWork { }
    function Write-PctkHint { }
    function Write-PctkWarn { }
    function Write-PctkLine { }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }

    # No debe tirar. Si el job muere o el formateo revienta, explota aca.
    Invoke-ActionApps -MachineProfile ([PSCustomObject]@{ Dummy = $true })
}

# ─── #77: desinstalador de Apps.ps1 (parser, 3010/1641, componentes del sistema, UI) ───
# Harness: corre el HANDLER REAL (Invoke-ActionApps) con Win32AppsJob/UwpAppsJob/
# Invoke-JobWithProgress, Read-Host, Confirm-Action, Start-Process y Write-* shadoweados.
# Invoke-Win32Uninstall, _Invoke-UninstallCommand y _Parse-UninstallCommand corren REALES.
function Invoke-Apps77Harness {
    param(
        [object[]]    $Win32,
        [string[]]    $Answers,
        [scriptblock] $ExitFor = { param($f, $a) 0 },
        [switch]      $Unattended,
        [object[]]    $Uwp = @()
    )
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $ev = [System.Collections.Generic.List[string]]::new()
    $script:Apps77 = @{
        Ev = $ev; Audit = [System.Collections.Generic.List[object]]::new()
        Sp = [System.Collections.Generic.List[object]]::new()
        Appx = [System.Collections.Generic.List[object]]::new()
        Jobs = [System.Collections.Generic.List[bool]]::new()
        Answers = [System.Collections.Generic.Queue[string]]::new()
        Win32 = $Win32; Uwp = $Uwp; ExitFor = $ExitFor
    }
    foreach ($x in $Answers) { $script:Apps77.Answers.Enqueue($x) }

    function Read-Host { param([string]$Prompt)
        if ($script:Apps77.Answers.Count -eq 0) { return 'V' }
        return $script:Apps77.Answers.Dequeue() }
    function Confirm-Action { param($Title, $Lines, $DefaultYes) return $true }
    function Write-Host { param($Object) $script:Apps77.Ev.Add('host:' + ($Object -join ' ')) }
    function Write-PctkWork { param($Text) $script:Apps77.Ev.Add('work:' + $Text) }
    function Write-PctkHint { param($Text) $script:Apps77.Ev.Add('hint:' + $Text) }
    function Write-PctkWarn { param($Text) $script:Apps77.Ev.Add('warn:' + $Text) }
    function Write-PctkOk   { param($Text) $script:Apps77.Ev.Add('ok:' + $Text) }
    function Write-PctkErr  { param($Text) $script:Apps77.Ev.Add('err:' + $Text) }
    function Write-PctkLine { param($Text, $Color, [switch]$NoNewline) $script:Apps77.Ev.Add('line:' + $Text) }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details)
        $script:Apps77.Audit.Add([PSCustomObject]@{ Action = $Action; Status = $Status; Summary = $Summary; Details = $Details }) }
    function Start-Win32AppsJob { param([switch]$IncludeSystemComponents)
        $script:Apps77.Jobs.Add([bool]$IncludeSystemComponents)
        return [PSCustomObject]@{ Kind = 'w32'; Sys = [bool]$IncludeSystemComponents } }
    function Start-UwpAppsJob { return [PSCustomObject]@{ Kind = 'uwp'; Sys = $false } }
    function Invoke-JobWithProgress { param($Jobs, $Activity, $TimeoutSeconds)
        $out = @()
        foreach ($j in @($Jobs)) {
            if ($j.Kind -eq 'w32') {
                $out += , @($script:Apps77.Win32 | Where-Object { $j.Sys -or -not $_.IsSystemComponent })
            } else { $out += , @($script:Apps77.Uwp) }
        }
        return , $out }
    # #83: nunca el Remove-AppxPackage real. Registra el $ProgressPreference que ve
    # el cmdlet al ser llamado (resolucion dinamica: el del scope de Invoke-UwpUninstall).
    function Remove-AppxPackage { [CmdletBinding()] param([string]$Package)   # CmdletBinding: acepta -ErrorAction
        $script:Apps77.Appx.Add([PSCustomObject]@{ Package = $Package; PP = [string] $ProgressPreference })
        $script:Apps77.Ev.Add('appx:' + $Package) }
    function Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
        $script:Apps77.Sp.Add([PSCustomObject]@{ FilePath = $FilePath; Args = $ArgumentList })
        $script:Apps77.Ev.Add('sp:' + $FilePath)
        return [PSCustomObject]@{ ExitCode = [int](& $script:Apps77.ExitFor $FilePath $ArgumentList) } }

    Invoke-ActionApps -MachineProfile ([PSCustomObject]@{ Dummy = $true }) -Unattended:$Unattended
    $res = $script:Apps77
    Remove-Variable -Name Apps77 -Scope Script -ErrorAction SilentlyContinue
    return $res
}

function New-Apps77Fixture {
    # Arbol real en %TEMP% con espacios en la ruta: "pctk 77 <guid>\Program Files X\Foo App\unins000.exe"
    [string] $root = Join-Path $env:TEMP ('pctk 77 ' + [guid]::NewGuid().ToString('N'))
    [string] $dir  = Join-Path $root 'Program Files X\Foo App'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [string] $exe = Join-Path $dir 'unins000.exe'
    [System.IO.File]::WriteAllBytes($exe, [byte[]](0x4D, 0x5A))
    return [PSCustomObject]@{ Root = $root; Exe = $exe }
}

function New-Apps77App {
    param([string]$Name, [string]$Uninstall, [string]$Quiet = '', [bool]$Sys = $false)
    return [PSCustomObject]@{ Name = $Name; Version = '1.0'; Publisher = 'Acme'; UninstallString = $Uninstall
                              QuietUninstallString = $Quiet; SizeMB = $null; IsSystemComponent = $Sys }
}

Test-SmokeFunction 'Apps' '#77 parser: ruta SIN comillas con espacios, con comillas, y MsiExec' {
    $ErrorActionPreference = 'Stop'
    $fx = New-Apps77Fixture
    try {
        # sin comillas, con espacios, con argumentos
        $p = _Parse-UninstallCommand -CmdStr ($fx.Exe + ' /S /norestart')
        if (-not $p.Success)            { throw ('sin comillas: Success=false ({0})' -f $p.Error) }
        if ($p.Executable -ne $fx.Exe)  { throw ('sin comillas: exe={0}' -f $p.Executable) }
        if ($p.Arguments -ne '/S /norestart') { throw ('sin comillas: args={0}' -f $p.Arguments) }
        # sin comillas, sin argumentos
        $p = _Parse-UninstallCommand -CmdStr $fx.Exe
        if (-not $p.Success -or $p.Executable -ne $fx.Exe -or $p.Arguments -ne '') { throw 'sin comillas ni args: mal parseado' }
        # con comillas: sin cambios
        $p = _Parse-UninstallCommand -CmdStr ('"' + $fx.Exe + '" /x')
        if (-not $p.Success -or $p.Executable -ne $fx.Exe -or $p.Arguments -ne '/x') { throw 'con comillas: mal parseado' }
        # ruta sin comillas que no existe: falla limpio (no inventa 'C:\Program')
        $p = _Parse-UninstallCommand -CmdStr 'C:\Program Files\NoExiste\x.exe /S'
        if ($p.Success) { throw 'ruta inexistente no debe dar Success' }
        # MsiExec: el preview lo toma como MSI con el GUID
        $pv = Get-Win32UninstallPreview -App (New-Apps77App 'M' 'MsiExec.exe /X{12345678-1234-1234-1234-1234567890AB}')
        if ($pv.Method -ne 'MSI' -or $pv.Arguments -notmatch '^/X\{12345678-1234-1234-1234-1234567890AB\} /qn') { throw ('MsiExec mal: {0} {1}' -f $pv.Method, $pv.Arguments) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'Apps' '#77 handler: sin comillas con espacios llega a Start-Process con el exe correcto' {
    $ErrorActionPreference = 'Stop'
    $fx = New-Apps77Fixture
    try {
        $app = New-Apps77App 'Foo' ($fx.Exe + ' /x')
        $r = Invoke-Apps77Harness -Win32 @($app) -Answers @('0')
        if ($r.Sp.Count -ne 1)                 { throw ('Start-Process x{0}, esperaba 1' -f $r.Sp.Count) }
        if ($r.Sp[0].FilePath -ne $fx.Exe)     { throw ('FilePath={0}' -f $r.Sp[0].FilePath) }
        if ($r.Sp[0].Args -ne '/x')            { throw ('Args={0}' -f $r.Sp[0].Args) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'Apps' '#77 handler: 3010 y 1641 = exito con UN aviso de reinicio; el audit distingue ok de ok-reinicio' {
    $ErrorActionPreference = 'Stop'
    $a1 = New-Apps77App 'A3010' 'MsiExec.exe /X{AAAAAAAA-1234-1234-1234-1234567890AB}'
    $a2 = New-Apps77App 'B1641' 'MsiExec.exe /X{BBBBBBBB-1234-1234-1234-1234567890AB}'
    $a3 = New-Apps77App 'C0'    'MsiExec.exe /X{CCCCCCCC-1234-1234-1234-1234567890AB}'
    $exit = { param($f, $a) if ($a -match 'AAAAAAAA') { 3010 } elseif ($a -match 'BBBBBBBB') { 1641 } else { 0 } }
    $r = Invoke-Apps77Harness -Win32 @($a1, $a2, $a3) -Answers @('0,1,2') -ExitFor $exit
    $per = @($r.Audit | Where-Object { $_.Action -eq 'Apps.Uninstall' })
    if ($per.Count -ne 3) { throw ('audit por app x{0}' -f $per.Count) }
    if (@($per | Where-Object { $_.Status -eq 'Success' }).Count -ne 3) { throw '3010/1641/0 deben ser Success' }
    if ($per[0].Details.Outcome -ne 'ok-reinicio' -or $per[1].Details.Outcome -ne 'ok-reinicio') { throw 'Outcome ok-reinicio faltante en 3010/1641' }
    if ($per[2].Details.Outcome -ne 'ok') { throw ('Outcome de exit 0 = {0}' -f $per[2].Details.Outcome) }
    $avisos = @($r.Ev | Where-Object { $_ -match 'REINICIAR' })
    if ($avisos.Count -ne 1) { throw ('aviso de reinicio x{0}, esperaba exactamente 1' -f $avisos.Count) }
    $batch = @($r.Audit | Where-Object { $_.Action -eq 'Apps.Uninstall.Batch' })[0]
    if ($batch.Summary -notmatch 'OK=3 .*OkReinicio=2') { throw ('batch: {0}' -f $batch.Summary) }
}

Test-SmokeFunction 'Apps' '#77 handler: exit de fallo real sigue siendo fallo, y sin reinicio no hay aviso' {
    $ErrorActionPreference = 'Stop'
    $a1 = New-Apps77App 'Rota' 'MsiExec.exe /X{DDDDDDDD-1234-1234-1234-1234567890AB}'
    $r = Invoke-Apps77Harness -Win32 @($a1) -Answers @('0') -ExitFor { param($f, $a) 1603 }   # coleccion de 1
    $per = @($r.Audit | Where-Object { $_.Action -eq 'Apps.Uninstall' })
    if ($per.Count -ne 1 -or $per[0].Status -ne 'Failed') { throw 'exit 1603 debe quedar Failed' }
    if (@($r.Ev | Where-Object { $_ -match 'REINICIAR' }).Count -ne 0) { throw 'aviso de reinicio sin 3010/1641' }
}

Test-SmokeFunction 'Apps' '#77 handler: desatendido NO lanza la UI (queda manual); interactivo avisa ANTES de lanzar' {
    $ErrorActionPreference = 'Stop'
    $fx = New-Apps77Fixture
    try {
        $app = New-Apps77App 'ConUI' ('"' + $fx.Exe + '"')   # solo UninstallString: prioridad 3
        # desatendido
        $u = Invoke-Apps77Harness -Win32 @($app) -Answers @('0') -Unattended
        if ($u.Sp.Count -ne 0) { throw ('desatendido llamo a Start-Process x{0}' -f $u.Sp.Count) }
        $man = @($u.Audit | Where-Object { $_.Action -eq 'Apps.Uninstall' -and $_.Status -eq 'Manual' })
        if ($man.Count -ne 1) { throw 'desatendido: falta audit Status=Manual' }
        if (@($u.Ev | Where-Object { $_ -match '^hint:\s+- ConUI' }).Count -ne 1) { throw 'desatendido: la app no figura en el resumen manual' }
        # interactivo
        $i = Invoke-Apps77Harness -Win32 @($app) -Answers @('0')
        if ($i.Sp.Count -ne 1) { throw ('interactivo Start-Process x{0}, esperaba 1' -f $i.Sp.Count) }
        [int] $iw = [array]::FindIndex([string[]]$i.Ev.ToArray(), [Predicate[string]]{ param($s) $s -match '^warn:.*Se va a abrir el desinstalador de ConUI' })
        [int] $isp = [array]::FindIndex([string[]]$i.Ev.ToArray(), [Predicate[string]]{ param($s) $s -like 'sp:*' })
        if ($iw -lt 0)    { throw 'interactivo: falta el aviso previo' }
        if ($iw -gt $isp) { throw 'interactivo: el aviso salio DESPUES de lanzar el desinstalador' }
        # y una app con metodo silencioso (MSI) se desinstala igual en desatendido
        $msi = New-Apps77App 'Msi' 'MsiExec.exe /X{EEEEEEEE-1234-1234-1234-1234567890AB}'
        $m = Invoke-Apps77Harness -Win32 @($msi) -Answers @('0') -Unattended
        if ($m.Sp.Count -ne 1) { throw 'desatendido: el MSI silencioso debe lanzarse igual' }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'Apps' '#77 handler: toggle [C] de componentes del sistema (off por default; ON los muestra marcados)' {
    $ErrorActionPreference = 'Stop'
    $n = New-Apps77App 'Normal App' 'x'
    $s = New-Apps77App 'Sys Comp'   'x' -Sys $true
    # off: no pide componentes, no los muestra
    $off = Invoke-Apps77Harness -Win32 @($n, $s) -Answers @('V')
    if ($off.Jobs.Count -ne 1 -or $off.Jobs[0]) { throw 'la carga inicial debe ser SIN componentes del sistema (off por default)' }
    if (@($off.Ev | Where-Object { $_ -match 'Sys Comp' }).Count -ne 0) { throw 'off: aparecio el componente del sistema' }
    # on: C + V -> recarga con el flag y lo muestra marcado
    $on = Invoke-Apps77Harness -Win32 @($n, $s) -Answers @('C', 'V')
    if ($on.Jobs.Count -ne 2 -or -not $on.Jobs[1]) { throw 'C debe recargar con -IncludeSystemComponents' }
    $row = @($on.Ev | Where-Object { $_ -match 'Sys Comp' })
    if ($row.Count -ne 1 -or $row[0] -notmatch 'componente del sistema') { throw 'on: falta la fila marcada como componente del sistema' }
    # C dos veces -> vuelve a off (la lista final vuelve a no tenerlo)
    $twice = Invoke-Apps77Harness -Win32 @($n, $s) -Answers @('C', 'C', 'V')
    if ($twice.Jobs.Count -ne 3 -or $twice.Jobs[2]) { throw 'segundo C debe recargar SIN el flag' }
}

Test-SmokeFunction 'Apps' '#83 handler: Remove-AppxPackage corre con progreso suprimido y $ProgressPreference no se filtra al llamador' {
    # POR QUE: un cliente real vio en [A][8] el bloque de progreso de deployment de
    # AppX dibujado encima del menu al volver. El fix suprime el progreso LOCAL a
    # Invoke-UwpUninstall. Corre el HANDLER (Invoke-ActionApps), no la funcion suelta.
    # (a) el cmdlet ve SilentlyContinue; (b) el llamador sigue viendo lo que veia
    # antes: ni $global: ni $script: cambiaron (un fix que se filtra apaga TODO el
    # progreso del toolkit de ahi en adelante).
    $ErrorActionPreference = 'Stop'
    [string] $prevGlobal = [string] $global:ProgressPreference
    $global:ProgressPreference = 'Continue'
    try {
        $sv = Get-Variable -Name ProgressPreference -Scope Script -ErrorAction SilentlyContinue
        [string] $scriptBefore = '<sin variable>'
        if ($null -ne $sv) { $scriptBefore = [string] $sv.Value }
        [string] $seenBefore = [string] $ProgressPreference

        $app = [PSCustomObject]@{ DisplayName = 'Foo UWP'; Name = 'Foo.Uwp'; IsMicrosoft = $false
                                  PackageFullName = 'Foo.Uwp_1.0.0.0_x64__8wekyb3d8bbwe' }
        $r = Invoke-Apps77Harness -Win32 @() -Uwp @($app) -Answers @('0')   # coleccion de 1

        if ($r.Appx.Count -ne 1) { throw ('Remove-AppxPackage x{0}, esperaba 1' -f $r.Appx.Count) }
        if ($r.Appx[0].Package -ne $app.PackageFullName) { throw ('Package={0}' -f $r.Appx[0].Package) }
        if ($r.Appx[0].PP -ne 'SilentlyContinue') {
            throw ('(a) Remove-AppxPackage vio $ProgressPreference={0}; esperaba SilentlyContinue' -f $r.Appx[0].PP)
        }

        $sv = Get-Variable -Name ProgressPreference -Scope Script -ErrorAction SilentlyContinue
        [string] $scriptAfter = '<sin variable>'
        if ($null -ne $sv) { $scriptAfter = [string] $sv.Value }
        if ([string] $global:ProgressPreference -ne 'Continue') {
            throw ('(b) se filtro a $global:ProgressPreference={0}' -f $global:ProgressPreference)
        }
        if ($scriptAfter -ne $scriptBefore) { throw ('(b) se filtro a $script:ProgressPreference: {0} -> {1}' -f $scriptBefore, $scriptAfter) }
        if ([string] $ProgressPreference -ne $seenBefore) { throw ('(b) el llamador veia {0} y ahora ve {1}' -f $seenBefore, $ProgressPreference) }

        $per = @($r.Audit | Where-Object { $_.Action -eq 'Apps.Uninstall' })
        if ($per.Count -ne 1 -or $per[0].Status -ne 'Success') { throw 'la desinstalacion UWP debe auditar Success' }
    }
    finally { $global:ProgressPreference = $prevGlobal }
}

Test-SmokeFunction 'Apps' '#77 Get-InstalledWin32Apps: SystemComponent fuera por default, dentro con el switch (coleccion de 1)' {
    $ErrorActionPreference = 'Stop'
    function Get-ItemProperty { param($Path, $ErrorAction)
        [PSCustomObject]@{ DisplayName = 'Visible App'; DisplayVersion = '1'; UninstallString = 'x' }
        [PSCustomObject]@{ DisplayName = 'Hidden Comp'; SystemComponent = 1; UninstallString = 'y' } }
    $off = @(Get-InstalledWin32Apps)
    if ($off.Count -ne 1 -or $off[0].Name -ne 'Visible App') { throw ('off: {0} items' -f $off.Count) }
    if ($off[0].IsSystemComponent) { throw 'Visible App marcada como componente' }
    $on = @(Get-InstalledWin32Apps -IncludeSystemComponents)
    if ($on.Count -ne 2) { throw ('on: {0} items' -f $on.Count) }
    $h = @($on | Where-Object Name -eq 'Hidden Comp')
    if ($h.Count -ne 1 -or -not $h[0].IsSystemComponent) { throw 'on: Hidden Comp no marcado' }
}

Test-SmokeFunction 'Apps' '#77 Start-Win32AppsJob -IncludeSystemComponents: el job REAL (clausura + interpolacion del flag)' {
    # POR QUE: el flag viaja por un here-string que se interpola ("Get-InstalledWin32Apps$sysFlag")
    # y corre en un runspace fresco. Probar Get-InstalledWin32Apps directo no lo ejercita
    # (CLAUDE.md: "serializar la clausura COMPLETA" / el test corre el job real).
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    function Get-JobErr { param($Job)
        [string[]] $e = @()
        foreach ($c in @($Job.ChildJobs)) { foreach ($er in @($c.Error)) { $e += [string]$er } }
        return $e
    }
    $jobOff = Start-Win32AppsJob
    $rOff = @((Invoke-JobWithProgress -Jobs @($jobOff) -Activity 'smoke #77 off' -TimeoutSeconds 120)[0])
    $jobOn = Start-Win32AppsJob -IncludeSystemComponents
    $rOn = @((Invoke-JobWithProgress -Jobs @($jobOn) -Activity 'smoke #77 on' -TimeoutSeconds 120)[0])
    foreach ($j in @($jobOff, $jobOn)) {
        $err = Get-JobErr $j
        foreach ($m in $err) {
            if ($m -match 'CommandNotFound|no se reconoce|ParameterBinding|no se encuentra un par|parameter cannot be found') { throw ('error en el job: ' + $m) }
        }
        if ($j.State -eq 'Failed') { throw 'el job termino Failed' }
    }
    if ($rOn.Count -eq 0 -or $null -eq $rOn[0]) { throw 'con el flag el job no devolvio apps (murio?)' }
    if ($null -eq $rOn[0].PSObject.Properties['IsSystemComponent']) { throw 'el resultado no trae IsSystemComponent' }
    if ($rOn.Count -lt $rOff.Count) { throw ('con flag {0} < sin flag {1}' -f $rOn.Count, $rOff.Count) }
}

Test-SmokeFunction 'Apps' '#52: SizeMB es numerico o null, nunca revienta por un EstimatedSize raro' {
    # EstimatedSize es DWORD por convencion pero el registro no lo garantiza: con
    # REG_BINARY / REG_MULTI_SZ la division tiraba ("no contiene op_Division") y con
    # un REG_SZ no numerico tiraba al convertir a Double, matando el job entero.
    # LIMITE CONOCIDO: no se puede inyectar un EstimatedSize corrupto sin escribir en
    # el registro real, asi que esto verifica la invariante sobre las entradas de ESTA
    # PC. Es una red que atrapa en la PC del cliente, no una prueba del caso raro.
    $ErrorActionPreference = 'Stop'
    foreach ($a in @(Get-InstalledWin32Apps)) {
        if ($null -eq $a.SizeMB) { continue }
        if (($a.SizeMB -isnot [double]) -and ($a.SizeMB -isnot [int]) -and ($a.SizeMB -isnot [decimal])) {
            throw ('SizeMB de "{0}" no es numerico: {1}' -f $a.Name, $a.SizeMB.GetType().Name)
        }
    }
}

Test-SmokeFunction 'Router' 'Defender [V]: lee .Paths del objeto, no imprime el objeto crudo' {
    # Get-CustomDefenderExclusions devuelve { Available; Paths[] }. Iterarlo como si
    # fuera un array de strings imprimia "@{Available=True; Paths=System.String[]}"
    # en pantalla (cazado por Mateo probando a mano, 2026-07-26).
    # Lee core\ entero: el handler vive en ActionHandlers.ps1 desde #26-B.
    [string] $router = Get-CoreSourceText
    if ($router -match '@\(Get-CustomDefenderExclusions\)') {
        throw 'El handler vuelve a envolver el objeto en @(): imprime el objeto crudo'
    }
    if ($router -notmatch "Properties\['Paths'\]") {
        throw 'El handler no lee la propiedad Paths'
    }
}

Test-SmokeFunction 'ClientReport' 'Datos del tecnico salen de data\tecnico.json (no hardcodeados)' {
    $ErrorActionPreference = 'Stop'
    [string] $tecPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\tecnico.json'
    if (-not (Test-Path -LiteralPath $tecPath)) { throw 'Falta data\tecnico.json' }
    $tec = Get-Content -LiteralPath $tecPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$tec.nombre)) { throw 'tecnico.json sin nombre' }
    # El modulo NO debe tener el nombre ni el telefono escritos a mano
    [string] $src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\ClientReport.ps1') -Raw -Encoding UTF8
    if ($src -match "'Mateo Villanueva'" -or $src -match "'387-515-0999'") {
        throw 'ClientReport.ps1 volvio a tener los datos del tecnico hardcodeados'
    }
}

Test-SmokeFunction 'ClientReport' 'Termica y plan de energia: salen con dato, se omiten sin dato' {
    $ErrorActionPreference = 'Stop'
    [string] $o1 = Join-Path $env:TEMP ('pctk-t1-' + [System.Guid]::NewGuid().ToString('N') + '.html')
    [string] $o2 = Join-Path $env:TEMP ('pctk-t2-' + [System.Guid]::NewGuid().ToString('N') + '.html')
    try {
        $conDatos = [PSCustomObject]@{
            ComputerName = 'PC'; RamTotalGb = 8.0
            CPU = [PSCustomObject]@{ Name = 'CPU'; Cores = 4; Threads = 8 }
            CpuTempC = 94.3
            PowerPlan = [PSCustomObject]@{ ActiveGuid = 'x'; ActiveName = 'Economizador' }
        }
        $null = New-ClientReport -PostSnapshot $conDatos -OutputPath $o1
        [string] $h1 = Get-Content -LiteralPath $o1 -Raw -Encoding UTF8
        if ($h1 -notmatch 'Temperatura')   { throw 'Falta el panel de temperatura con dato presente' }
        if ($h1 -notmatch 'pasta termica') { throw 'A 94 C deberia sugerir cambio de pasta' }
        if ($h1 -notmatch 'Economizador')  { throw 'Falta el plan de energia' }

        # Sin sensores (desktop tipico / VM): NO inventar secciones vacias
        $sinDatos = [PSCustomObject]@{
            ComputerName = 'PC'; RamTotalGb = 8.0
            CPU = [PSCustomObject]@{ Name = 'CPU'; Cores = 4; Threads = 8 }
        }
        $null = New-ClientReport -PostSnapshot $sinDatos -OutputPath $o2
        [string] $h2 = Get-Content -LiteralPath $o2 -Raw -Encoding UTF8
        if ($h2 -match 'Temperatura') { throw 'Dibujo el panel de temperatura sin dato' }
        if ($h2 -match 'Plan activo') { throw 'Dibujo el plan de energia sin dato' }
    } finally {
        Remove-Item -LiteralPath $o1, $o2 -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Debloat' 'Rollback + lista de UN elemento no crashea (trampa PS5.1)' {
    $ErrorActionPreference = 'Stop'
    # DOS cosas a la vez:
    # 1) El shape del rollback (estado previo para poder revertir).
    # 2) La trampa de CLAUDE.md: `$v = if (c) { $lista }` desenrolla una coleccion
    #    de UN elemento a escalar -> `.Count` tira PropertyNotFoundStrict. Antes de
    #    2026-07-25, pasar UN solo servicio crasheaba la funcion (y con ella el
    #    pipeline auto si una receta tenia un unico servicio a desactivar).
    #    Por eso la fixture es de largo 1: es el caso que rompe.
    $r = Disable-BloatServices -ServicesList @('PctkServicioQueNoExiste_ZZZ')
    if (-not $r.PSObject.Properties['Rollback']) { throw 'Falta el campo Rollback' }
    if ($null -eq $r.Rollback) { throw 'Rollback es null (deberia ser array vacio)' }
    if (@($r.Rollback).Count -ne 0) { throw 'No se toco nada: Rollback deberia estar vacio' }
    if ($r.TotalTargeted -ne 1) { throw ('TotalTargeted esperado 1; got {0}' -f $r.TotalTargeted) }
    if ($r.Skipped -ne 1) { throw ('El servicio inexistente deberia contar como Skipped; got {0}' -f $r.Skipped) }
}

Test-SmokeFunction 'JobManager' 'Invoke-ModuleJob borrado (dead code con Invoke-Expression)' {
    if (Get-Command -Name 'Invoke-ModuleJob' -CommandType Function -ErrorAction SilentlyContinue) {
        throw 'Invoke-ModuleJob volvio a existir: era dead code y usaba Invoke-Expression'
    }
}

Test-SmokeFunction 'Router' 'Huerfanas cableadas: Autoruns, exclusiones dev, grado de bufferbloat' {
    foreach ($fn in @('Open-Autoruns', 'Add-WslDefenderExclusions', 'Remove-WslDefenderExclusions',
                      'Get-CustomDefenderExclusions', 'Get-BufferbloatGrade')) {
        if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            throw ("{0} no esta definida" -f $fn)
        }
    }
    # Que esten LLAMADAS desde la capa de router, no solo definidas: es justo lo
    # que fallaba. Se lee core\ entero porque desde #26-B las llamadas viven en
    # ActionHandlers.ps1, no en Router.ps1.
    [string] $router = Get-CoreSourceText
    foreach ($fn in @('Open-Autoruns', 'Add-WslDefenderExclusions', 'Remove-WslDefenderExclusions',
                      'Get-CustomDefenderExclusions', 'Get-BufferbloatGrade')) {
        if ($router -notmatch [regex]::Escape($fn)) {
            throw ("{0} sigue huerfana: la capa de router no la llama" -f $fn)
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  v2.5.0 - unificacion [L]/[U] + #40 claves BitLocker + remate #28
# ═══════════════════════════════════════════════════════════════════════════════

Test-SmokeFunction 'ServiceState' 'el bundle se lleva la comparacion COMPLETA, no solo el puntaje' {
    # Compare-Snapshot arma la lista de mejoras en criollo. Hasta v2.7.0 se
    # corria, se tomaba SOLO el numero para el meta y la lista se tiraba -- asi
    # que del otro lado (el CRM) no habia con que armar el cajon "lo que mejoro"
    # y habria habido que RECALCULARLO en otro lenguaje. Dos definiciones de lo
    # mismo divergiendo en silencio, que es lo que ya paso con los mutex.
    #
    # Entra por Invoke-CloseService, el handler que corre cuando se aprieta [L].
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-cmp-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-cmpd-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-08-07.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }
        function Compare-Snapshot {
            [PSCustomObject]@{
                Score        = 2
                ScoreMax     = 6
                Improvements = @('Espacio liberado: 12,4 GB', 'Programas de inicio removidos: 3')
                TotalFreedGb = 12.4
            }
        }

        $r = Invoke-CloseService -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                 -TimestampOverride '20260807-100000'
        if ($r.Status -ne 'OK') { throw ('esperaba Status OK; got {0}' -f $r.Status) }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [string] $contenido = ''
        [bool]   $tieneCompare = $false
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try {
            foreach ($e in $za.Entries) {
                if ($e.FullName -match 'compare\.json$') {
                    $tieneCompare = $true
                    $sr = New-Object System.IO.StreamReader($e.Open())
                    try { $contenido = $sr.ReadToEnd() } finally { $sr.Dispose() }
                }
            }
        } finally { $za.Dispose() }

        if (-not $tieneCompare) { throw 'el ZIP no lleva compare.json: la lista de mejoras se sigue tirando' }
        if ($contenido -notmatch 'Espacio liberado') {
            throw 'compare.json no trae las mejoras en criollo, que es el punto'
        }
        # Y que sea JSON de verdad, no texto que parece.
        $obj = $contenido | ConvertFrom-Json
        if ($obj.Score -ne 2) { throw ('el Score no viajo bien; got {0}' -f $obj.Score) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'sin comparacion NO se escribe un compare.json vacio' {
    # Un diagnostico sin cierre no tiene antes/despues. Escribir el archivo igual
    # se leeria del otro lado como "no mejoro nada", que es distinto de "no habia
    # con que comparar". Es el caso de Guille Voss (03/08): compare_score N/A.
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-cmpn-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-cmpnd-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-08-07.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }
        function Compare-Snapshot { return $null }

        $r = Invoke-CloseService -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                 -TimestampOverride '20260807-110000'
        if ($r.Status -ne 'OK') { throw ('esperaba Status OK; got {0}' -f $r.Status) }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [bool] $tieneCompare = $false
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { foreach ($e in $za.Entries) { if ($e.FullName -match 'compare\.json$') { $tieneCompare = $true } } }
        finally { $za.Dispose() }

        if ($tieneCompare) { throw 'sin comparacion no tendria que haber compare.json' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'si la comparacion falla, el cierre NO se cae' {
    # Nunca traba el cierre de un service: es la misma regla que la subida al CRM.
    # Sin esto el bundle sale igual, sin el detalle.
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-cmpf-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-cmpfd-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-08-07.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }
        function Compare-Snapshot { throw 'la comparacion se rompio (simulado)' }

        $r = Invoke-CloseService -OutputRootOverride $tmpRoot -DestDirOverride $tmpDest `
                                 -TimestampOverride '20260807-120000'
        if ($r.Status -ne 'OK') { throw ('el cierre se cayo por la comparacion; Status={0}' -f $r.Status) }
        if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'no quedo el ZIP' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Marcador de bundle: round-trip, otro host no cuenta, JSON roto no tira' {
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-lb-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
    try {
        if (Test-BundleAlreadyTaken -OutputRootOverride $tmpRoot) { throw 'sin marcador debe dar $false' }

        [string] $p = Set-LastBundleMarker -ZipPath 'C:\Fake\Desktop\bundle.zip' `
                                           -OutputRootOverride $tmpRoot `
                                           -ClosedAtOverride '2026-07-26T10:00:00-03:00'
        if ([string]::IsNullOrEmpty($p))  { throw 'Set-LastBundleMarker no devolvio ruta' }
        if (-not (Test-Path -LiteralPath $p)) { throw 'el marcador no se escribio a disco' }

        $m = Get-LastBundleMarker -OutputRootOverride $tmpRoot
        if ($null -eq $m) { throw 'Get-LastBundleMarker devolvio $null' }
        if ([string]$m.zip_path -ne 'C:\Fake\Desktop\bundle.zip') { throw 'zip_path no round-trippea' }
        if (-not (Test-BundleAlreadyTaken -OutputRootOverride $tmpRoot)) { throw 'con marcador de esta PC debe dar $true' }

        # USB del tecnico que viene de OTRO cliente: ese marcador no cuenta.
        [string] $mp = Get-LastBundleMarkerPath -OutputRootOverride $tmpRoot
        Set-Content -LiteralPath $mp -Encoding UTF8 `
            -Value '{"schema_version":"1.0","hostname":"OTRA-PC","closed_at":"x","zip_path":"y"}'
        if (Test-BundleAlreadyTaken -OutputRootOverride $tmpRoot) { throw 'marcador de otro host NO debe contar' }

        # JSON corrupto: $null sin tirar, y no se toma como "ya empaquetado"
        # (equivocarse para ese lado deja al cliente sin paquete).
        Set-Content -LiteralPath $mp -Value '{"hostname": "roto' -Encoding UTF8
        if ($null -ne (Get-LastBundleMarker -OutputRootOverride $tmpRoot)) { throw 'JSON corrupto debe dar $null' }
        if (Test-BundleAlreadyTaken -OutputRootOverride $tmpRoot) { throw 'JSON corrupto no debe contar como tomado' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' '[L] y despues [U]: UN solo ZIP en el Escritorio del cliente' {
    # EL bug que motiva la unificacion: [L] cierra el service y [U] empaquetaba
    # igual, asi que el flujo natural (me llevo el paquete y dejo la PC limpia)
    # dejaba DOS ZIP, y el segundo peor -- sin POST, "bundle parcial".
    # Este test corre los DOS handlers reales, no los helpers.
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-lu-'      + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-lu-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'output\audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-07-26.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        # Sin POST real (requiere el sistema completo y muta output\snapshots\).
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }

        # --- [L] Cerrar service ---
        $rl = Invoke-CloseService -OutputRootOverride (Join-Path $tmpRoot 'output') `
                                  -ToolkitRootOverride $tmpRoot `
                                  -DestDirOverride $tmpDest `
                                  -TimestampOverride '20260726-100000' `
                                  -AnyDeskConfPaths @((Join-Path $env:TEMP 'no-existe\system.conf'))
        [string] $st = if ($null -eq $rl) { 'null' } else { [string]$rl.Status }
        if ($st -ne 'OK') { throw ('el [L] no armo el bundle (Status={0})' -f $st) }
        if (-not (Test-BundleAlreadyTaken -OutputRootOverride $tmpRoot)) {
            throw 'el [L] no dejo el marcador del bundle: el [U] va a re-empaquetar'
        }

        # --- [U] Desinstalar (la parte que preserva/empaqueta) ---
        $ru = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpDest
        if ($null -eq $ru) { throw 'Save-PreUninstallArtifacts devolvio $null' }

        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -ne 1) {
            throw ('Se esperaba UN solo ZIP tras [L]+[U]; hay {0}. Volvio el bug de los dos paquetes.' -f $zips.Count)
        }
        if ([string]$ru.ZipPath -ne [string]$rl.ZipPath) {
            throw ('El [U] deberia reportar el ZIP del [L]; got "{0}" vs "{1}"' -f $ru.ZipPath, $rl.ZipPath)
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' '[U] sin [L] previo: SI empaqueta (no romper el atajo)' {
    # La contracara del test de arriba: el [U] directo ("no hubo service, solo
    # saco el toolkit") tiene que seguir armando el paquete con lo que haya.
    $ErrorActionPreference = 'Stop'
    [string] $tmpRoot  = Join-Path $env:TEMP ('pctk-uonly-'      + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest  = Join-Path $env:TEMP ('pctk-uonly-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpRoot 'output\audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-07-26.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Start-TelemetryJob { param([string]$Phase); return $null }
        function Invoke-JobWithProgress { param([object[]]$Jobs, [string]$Activity, [int]$TimeoutSeconds); return @() }

        $ru = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpDest
        if ($null -eq $ru) { throw 'Save-PreUninstallArtifacts devolvio $null' }

        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -ne 1) { throw ('el [U] directo deberia dejar 1 ZIP; hay {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'Invoke-CloseService no pregunta por desinstalar (evita recursion con el [U])' {
    # Save-PreUninstallArtifacts (el [U]) llama a Invoke-CloseService para armar el
    # paquete. Si la pregunta "dejar PCTk instalado?" viviera adentro de
    # Invoke-CloseService, el [U] preguntaria por desinstalar en medio de una
    # desinstalacion -> recursion. Por eso vive en Invoke-ServiceClose (el Router).
    [string] $def = (Get-Command Invoke-CloseService -CommandType Function).Definition
    if ($def -match 'Invoke-UninstallToolkit') {
        throw 'Invoke-CloseService llama al [U]: recursion con Save-PreUninstallArtifacts'
    }
    [string] $router = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'core\Router.ps1') -Raw -Encoding UTF8
    # El [L] tiene que poder SALIR de PCTk: si desinstala sin cerrarse, el deleter
    # espera al PID 30s y despues intenta borrar una instalacion en uso.
    if ($router -notmatch "\`$choice -eq 'L'") {
        throw 'Show-MainMenu no intercepta la [L]: el [L] no puede cerrar PCTk al desinstalar'
    }
}

Test-SmokeFunction 'UninstallToolkit' '#40: con claves BitLocker guardadas el [U] frena (handler completo)' {
    # #40: Save-PreUninstallArtifacts preserva clients\ + audit\ + el ZIP, pero
    # output\recovery\ no aparecia en ningun lado y el deleter borra el InstallRoot
    # entero. Capturar una clave con [A][18][C] y desinstalar la destruia: si el
    # disco pide recovery despues, el cliente queda afuera de su propia PC.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-40-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path (Join-Path $tmpRoot 'core')            -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tmpRoot 'output\recovery') -ItemType Directory -Force | Out-Null
    try {
        # El handler valida que el root parezca una instalacion PCTk antes de nada.
        Set-Content -LiteralPath (Join-Path $tmpRoot 'main.ps1')        -Value '# fixture' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tmpRoot 'core\Router.ps1') -Value '# fixture' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tmpRoot 'output\recovery\bitlocker-recovery-PC.txt') `
                    -Value @('Key ID  : 1a2b3c4d', 'Clave   : 111111-222222-333333') -Encoding UTF8

        # El operador NO confirma que guardo la clave.
        function Read-Host { param([string]$Prompt) return 'siguiente' }
        # Redes: si el gate no frena, estas cazan el paso ANTES de que borre nada.
        function Confirm-Action { param([string]$Title, [string[]]$Lines, [bool]$DefaultYes = $true)
            throw 'el [U] paso el gate de claves BitLocker SIN confirmacion' }
        function Start-Process { throw 'el [U] lanzo el deleter con claves BitLocker sin confirmar' }

        [bool] $r = Invoke-UninstallToolkit -InstallRootOverride $tmpRoot
        if ($r) { throw 'el [U] devolvio $true: habria borrado la instalacion con la clave adentro' }
        if (-not (Test-Path -LiteralPath (Join-Path $tmpRoot 'output\recovery\bitlocker-recovery-PC.txt'))) {
            throw 'la clave se borro'
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallToolkit' '#40: sin claves guardadas el [U] sigue al flujo normal' {
    # La contracara: el gate no debe frenar una desinstalacion comun.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    [string] $tmpRoot = Join-Path $env:TEMP ('pctk-40b-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path (Join-Path $tmpRoot 'core') -ItemType Directory -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $tmpRoot 'main.ps1')        -Value '# fixture' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $tmpRoot 'core\Router.ps1') -Value '# fixture' -Encoding UTF8

        $script:pctk40Llego = $false
        function Confirm-Action { param([string]$Title, [string[]]$Lines, [bool]$DefaultYes = $true)
            $script:pctk40Llego = $true; return $false }
        function Read-Host { param([string]$Prompt) return '' }

        [bool] $r = Invoke-UninstallToolkit -InstallRootOverride $tmpRoot
        if (-not $script:pctk40Llego) { throw 'el gate #40 freno una desinstalacion sin claves guardadas' }
        if ($r) { throw 'se cancelo en la confirmacion: deberia devolver $false' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'MachineProfile' 'Get-OemDisplayValue: placeholders del SMBIOS -> fallback' {
    $ErrorActionPreference = 'Stop'
    foreach ($p in @('To Be Filled By O.E.M.', 'Default string', 'System Product Name',
                     'System Serial Number', 'None', 'Not Specified', '', '   ')) {
        [string] $got = Get-OemDisplayValue -Value $p
        if ($got -ne 'N/A') { throw ("placeholder '{0}' no se normalizo (got '{1}')" -f $p, $got) }
    }
    if ((Get-OemDisplayValue -Value '82K2')   -ne '82K2') { throw 'un modelo real no debe tocarse' }
    if ((Get-OemDisplayValue -Value ' 82K2 ') -ne '82K2') { throw 'deberia trimear' }
    # Match EXACTO: un modelo que contenga la palabra no es un placeholder.
    if ((Get-OemDisplayValue -Value 'Nonetype X1') -ne 'Nonetype X1') { throw 'match parcial: no debe normalizar' }
    if ((Get-OemDisplayValue -Value '' -Fallback '') -ne '') { throw 'el fallback debe ser configurable' }
}

Test-SmokeFunction 'Router' '#28: el banner muestra modelo y Service Tag (handler, no la funcion pura)' {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $script:pctkBannerRows = $null
    function Write-PctkMachineBanner { param([object[]]$Rows, [string]$Tier, [string]$VmLine = '')
        $script:pctkBannerRows = $Rows }

    [PSCustomObject] $mp = [PSCustomObject]@{
        IsWin11 = $true; IsHome = $false; Build = 22631; RamMB = 16384
        GpuNames = @('Intel UHD'); HasIGpuOnly = $true; HasDGpu = $false
        Manufacturer = 'LENOVO'; Tier = 'Mid'; CpuClass = 'Modern'
        Model = '82K2'; SerialNumber = 'PF3ABCDE'
    }
    Show-MachineBanner -MachineProfile $mp
    if ($null -eq $script:pctkBannerRows) { throw 'el banner no rendereo filas' }
    [object[]] $rows = @($script:pctkBannerRows)

    [object[]] $oem = @($rows | Where-Object { $_.Label -eq 'OEM' })
    if ($oem.Count -ne 1) { throw 'falta la fila OEM' }
    if ([string]$oem[0].Value -notmatch '82K2') { throw ('la fila OEM no muestra el modelo (#28): {0}' -f $oem[0].Value) }

    [object[]] $sn = @($rows | Where-Object { $_.Label -eq 'S/N' })
    if ($sn.Count -ne 1) { throw 'falta la fila S/N (#28)' }
    if ([string]$sn[0].Value -ne 'PF3ABCDE') { throw ('S/N incorrecto: {0}' -f $sn[0].Value) }

    # Perfil sparse (sin Model ni SerialNumber): no debe tirar bajo StrictMode.
    $script:pctkBannerRows = $null
    [PSCustomObject] $mpSparse = [PSCustomObject]@{
        IsWin11 = $false; IsHome = $true; Build = 19045; RamMB = 8192
        GpuNames = @(); HasIGpuOnly = $false; HasDGpu = $false; Manufacturer = ''
    }
    Show-MachineBanner -MachineProfile $mpSparse
    [object[]] $rows2 = @($script:pctkBannerRows)
    [object[]] $sn2 = @($rows2 | Where-Object { $_.Label -eq 'S/N' })
    if ($sn2.Count -ne 1)                  { throw 'la fila S/N desaparece con perfil sparse' }
    if ([string]$sn2[0].Value -ne 'N/A')   { throw ('sin serial deberia decir N/A; got {0}' -f $sn2[0].Value) }
}

# ─── #28 (remate): SystemSku + SystemFamily ──────────────────────────────────
# En Lenovo y HP el Model del SMBIOS viene enmascarado ("82K2", "15-fd0xxx") y
# no alcanza para identificar el equipo ni para auto-seleccionar un recipe.

Test-SmokeFunction 'MachineProfile' '#28 Get-ModelDisplayName: Lenovo real, SystemFamily ya viene limpio' {
    # Caso testigo MEDIDO en HW (notebook de Mateo, 2026-08-07).
    [string] $r = Get-ModelDisplayName -Model '82K2' -Family 'IdeaPad Gaming 3 15ACH6' `
                                       -Sku 'LENOVO_MT_82K2_BU_idea_FM_IdeaPad Gaming 3 15ACH6'
    if ($r -ne 'IdeaPad Gaming 3 15ACH6') { throw ('esperaba el nombre comercial; got {0}' -f $r) }
}

Test-SmokeFunction 'MachineProfile' '#28 Get-ModelDisplayName: sin Family cae al _FM_ del SKU' {
    [string] $r = Get-ModelDisplayName -Model '82K2' -Family '' `
                                       -Sku 'LENOVO_MT_82K2_BU_idea_FM_IdeaPad Gaming 3 15ACH6'
    if ($r -ne 'IdeaPad Gaming 3 15ACH6') { throw ('el respaldo del SKU no salio; got {0}' -f $r) }
}

Test-SmokeFunction 'MachineProfile' '#28 Get-ModelDisplayName: sin nada mejor devuelve el Model' {
    foreach ($caso in @(
        @{ M = 'Inspiron 15 3525'; F = '';                       S = ''; E = 'Inspiron 15 3525'; Q = 'Dell, sin family ni sku' },
        @{ M = '82K2';             F = '82K2';                   S = ''; E = '82K2';             Q = 'family que repite el model' },
        @{ M = 'Latitude 5420';    F = 'To Be Filled By O.E.M.'; S = ''; E = 'Latitude 5420';    Q = 'family placeholder del SMBIOS' },
        @{ M = '';                 F = '';                       S = ''; E = '';                 Q = 'todo vacio' }
    )) {
        [string] $r = Get-ModelDisplayName -Model $caso.M -Family $caso.F -Sku $caso.S
        if ($r -ne $caso.E) { throw ('{0}: esperaba "{1}"; got "{2}"' -f $caso.Q, $caso.E, $r) }
    }
}

Test-SmokeFunction 'Router' '#28 el banner muestra el nombre comercial Y el codigo entre parentesis' {
    # El nombre para que el operador sepa que equipo tiene delante; el codigo
    # porque ES lo que se tipea en el soporte del fabricante para sacar despiece.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $script:pctkBannerRows = $null
    function Write-PctkMachineBanner { param([object[]]$Rows, [string]$Tier, [string]$VmLine = '')
        $script:pctkBannerRows = $Rows }

    [PSCustomObject] $mp = [PSCustomObject]@{
        IsWin11 = $true; IsHome = $false; Build = 22631; RamMB = 16384
        GpuNames = @('NVIDIA RTX 3050'); HasIGpuOnly = $false; HasDGpu = $true
        Manufacturer = 'LENOVO'; Tier = 'Mid'; CpuClass = 'Modern'
        Model = '82K2'; SerialNumber = 'PF3ABCDE'
        SystemSku = 'LENOVO_MT_82K2_BU_idea_FM_IdeaPad Gaming 3 15ACH6'
        Family    = 'IdeaPad Gaming 3 15ACH6'
    }
    Show-MachineBanner -MachineProfile $mp

    [object[]] $rows = @($script:pctkBannerRows)
    [object[]] $oem  = @($rows | Where-Object { $_.Label -eq 'OEM' })
    if ($oem.Count -ne 1) { throw 'falta la fila OEM' }

    [string] $v = [string] $oem[0].Value
    if ($v -notmatch 'IdeaPad Gaming 3 15ACH6') { throw ('el banner no muestra el nombre comercial: {0}' -f $v) }
    if ($v -notmatch '\(82K2\)') { throw ('el banner perdio el codigo, que es lo que se tipea en el soporte: {0}' -f $v) }
}

Test-SmokeFunction 'ResearchPrompt' '#28 el prompt lleva el nombre comercial y SIGUE sin el Service Tag' {
    # Extiende el canario de arriba: al agregar campos nuevos al prompt, el
    # serial tiene que seguir afuera.
    $ErrorActionPreference = 'Stop'
    [PSCustomObject] $mp = [PSCustomObject]@{
        Manufacturer = 'LENOVO'; Model = '82K2'; SerialNumber = 'PF3ABCDE'
        SystemSku = 'LENOVO_MT_82K2_BU_idea_FM_IdeaPad Gaming 3 15ACH6'
        Family    = 'IdeaPad Gaming 3 15ACH6'
        Tier = 'Mid'; IsLaptop = $true; IsWin11 = $true; IsHome = $false; Build = 22631
    }
    [PSCustomObject] $snap = [PSCustomObject]@{
        ComputerName = 'PC-DEL-CLIENTE'; CPU = [PSCustomObject]@{ Name = 'i5' }
    }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r -or -not $r.Success) { throw 'New-ResearchPrompt fallo' }
    try {
        [string] $txt = Get-Content -LiteralPath $r.FilePath -Raw -Encoding UTF8
        if ($txt -notmatch 'IdeaPad Gaming 3 15ACH6') { throw 'el prompt no lleva el nombre comercial (#28)' }
        if ($txt -notmatch '82K2')                    { throw 'el prompt perdio el codigo del modelo' }
        if ($txt -match 'PF3ABCDE') { throw 'FUGA: el Service Tag salio en el prompt que se pega en un LLM externo' }
    } finally {
        Remove-Item -LiteralPath $r.FilePath -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'MachineProfile' '#28 el perfil expone SystemSku y Family' {
    $ErrorActionPreference = 'Stop'
    [object] $mp = Get-MachineProfile
    foreach ($campo in @('Model', 'SerialNumber', 'SystemSku', 'Family')) {
        if ($null -eq $mp.PSObject.Properties[$campo]) {
            throw ('falta el campo {0} en el machine profile' -f $campo)
        }
    }
}

Test-SmokeFunction 'ResearchPrompt' '#28: el prompt [R] lleva el modelo y NUNCA el Service Tag' {
    # El texto del [R] se copia al portapapeles para pegarlo en un LLM de terceros.
    # El modelo lo comparten millones de equipos; el serial identifica el del
    # cliente. Este canario existe para que nadie lo agregue "por completitud".
    $ErrorActionPreference = 'Stop'
    [PSCustomObject] $mp = [PSCustomObject]@{
        Manufacturer = 'LENOVO'; Model = '82K2'; SerialNumber = 'PF3ABCDE'
        Tier = 'Mid'; IsLaptop = $true; IsWin11 = $true; IsHome = $false; Build = 22631
    }
    [PSCustomObject] $snap = [PSCustomObject]@{
        ComputerName = 'PC-DEL-CLIENTE'; CPU = [PSCustomObject]@{ Name = 'i5' }
    }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r -or -not $r.Success) { throw 'New-ResearchPrompt fallo' }
    try {
        [string] $txt = Get-Content -LiteralPath $r.FilePath -Raw -Encoding UTF8
        if ($txt -notmatch '82K2')     { throw 'el prompt no lleva el modelo (#28)' }
        if ($txt -match 'PF3ABCDE')    { throw 'FUGA: el Service Tag salio en el prompt que se pega en un LLM externo' }
    } finally {
        Remove-Item -LiteralPath $r.FilePath -Force -ErrorAction SilentlyContinue
    }
}

# ─── #41: el bundle del [L] sube solo al CRM ──────────────────────────────────
# La regla que estos tests protegen es UNA: esto nunca traba el cierre de un
# service. Por eso casi todos afirman "no tiro y devolvio algo", no "funciono".

Test-SmokeFunction 'CrmUpload' 'el codigo de conexion se parsea y se rechaza lo dudoso' {
    $ok = ConvertFrom-CrmConnectionString -Text 'https://pctk-crm.ejemplo.workers.dev|UNTOKEN'
    if (-not $ok.Ok) { throw ('un codigo valido fue rechazado: {0}' -f $ok.Error) }
    if ($ok.Url -ne 'https://pctk-crm.ejemplo.workers.dev') { throw ('url mal parseada: {0}' -f $ok.Url) }
    if ($ok.Token -ne 'UNTOKEN') { throw 'token mal parseado' }

    # La barra de sobra se saca: si no, el endpoint queda con doble barra.
    $conBarra = ConvertFrom-CrmConnectionString -Text 'https://x.dev/|T'
    if ($conBarra.Url -ne 'https://x.dev') { throw ('no limpio la barra final: {0}' -f $conBarra.Url) }

    # http NO: el token viaja en una cabecera y en la casa de un cliente el que
    # esta en el medio puede ser cualquiera.
    if ((ConvertFrom-CrmConnectionString -Text 'http://x.dev|T').Ok) { throw 'acepto http' }
    if ((ConvertFrom-CrmConnectionString -Text 'https://x.dev').Ok)  { throw 'acepto un codigo sin token' }
    if ((ConvertFrom-CrmConnectionString -Text 'https://x.dev|').Ok) { throw 'acepto token vacio' }
    if ((ConvertFrom-CrmConnectionString -Text '').Ok)               { throw 'acepto vacio' }
}

Test-SmokeFunction 'CrmUpload' 'el id del bundle sale del nombre del ZIP y es estable' {
    # Estable = reintentar sube el MISMO id y el CRM contesta "ya lo tenia" en vez
    # de guardar una segunda copia. Con un id al azar, decir que no y subirlo
    # despues dejaria dos bundles iguales.
    [string] $a = Get-BundleUploadId -ZipPath 'C:\x\HOST_20260801-021500_cierre.zip'
    [string] $b = Get-BundleUploadId -ZipPath 'C:\otra\ruta\HOST_20260801-021500_cierre.zip'
    if ($a -ne $b) { throw 'el mismo nombre dio dos ids distintos' }
    if ($a -ne 'HOST_20260801-021500_cierre') { throw ('id inesperado: {0}' -f $a) }

    # Lo que el CRM descartaria de un id no puede quedar acá: si se fuera del
    # lado del servidor, dos ZIP distintos podrian colapsar en el mismo id.
    [string] $raro = Get-BundleUploadId -ZipPath 'C:\x\..\PC del cliente (1).zip'
    if ($raro -match '[^A-Za-z0-9._-]') { throw ('quedaron caracteres que el CRM tira: {0}' -f $raro) }
    if ($raro -match '\.\.')            { throw ('quedo un ".." adentro: {0}' -f $raro) }
}

Test-SmokeFunction 'CrmUpload' 'la config va y vuelve, y un JSON roto no tira' {
    [string] $tmp = Join-Path $env:TEMP ('pctk-smoke-crm-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        $null = New-Item -ItemType Directory -Path $tmp -Force

        if ($null -ne (Get-CrmConfig -OutputRootOverride $tmp)) { throw 'devolvio config donde no hay nada' }

        if (-not (Save-CrmConfig -Url 'https://x.dev' -Token 'TOK' -OutputRootOverride $tmp)) {
            throw 'Save-CrmConfig dijo que no pudo guardar'
        }
        $leida = Get-CrmConfig -OutputRootOverride $tmp
        if ($null -eq $leida)          { throw 'no releyo lo que acababa de guardar' }
        if ($leida.Token -ne 'TOK')    { throw 'el token no sobrevivio la vuelta' }

        # Un archivo corrupto tiene que dar $null y seguir, no tirar: si tirara,
        # un crm.json roto impediria cerrar un service.
        Set-Content -LiteralPath (Get-CrmConfigPath -OutputRootOverride $tmp) -Value '{ esto no es json' -Encoding UTF8
        if ($null -ne (Get-CrmConfig -OutputRootOverride $tmp)) { throw 'un JSON roto paso como config valida' }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'Send-BundleToCrm nunca tira: ni sin archivo ni sin servidor' {
    $sinArchivo = Send-BundleToCrm -ZipPath 'C:\no\existe\nada.zip' -Url 'https://x.dev' -Token 'T'
    if ($null -eq $sinArchivo)  { throw 'devolvio $null en vez de un resultado' }
    if ($sinArchivo.Ok)         { throw 'dijo que subio un archivo que no existe' }

    # Servidor inalcanzable (puerto 1 de loopback = conexion rechazada al toque).
    # Es el caso de la PC de un cliente sin internet, que tiene que terminar en un
    # aviso legible y no en una excepcion que corte el cierre del service.
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'contenido de prueba' -Encoding ASCII
        $sinRed = Send-BundleToCrm -ZipPath $zip -Url 'https://127.0.0.1:1' -Token 'T' -TimeoutSeconds 5
        if ($null -eq $sinRed) { throw 'devolvio $null con el servidor caido' }
        if ($sinRed.Ok)        { throw 'dijo que subio con el servidor caido' }
        if ([string]::IsNullOrWhiteSpace($sinRed.Message)) { throw 'fallo sin decir por que' }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'un 200 con HTML NO cuenta como subido (falso exito)' {
    # LA REGRESION QUE ESTE TEST CUIDA, cazada el 2026-08-01 probando contra el
    # CRM real: .NET sigue las redirecciones solo. Si la ruta de subida quedara
    # detras de Cloudflare Access, el 302 al login se seguiria hasta la pantalla
    # de Cloudflare, que contesta 200 con HTML -- y la version anterior de esto
    # tomaba cualquier 2xx como exito. O sea que le habria dicho al operador
    # "el paquete ya esta en el CRM" sin haber subido nada. Decir que algo se
    # guardo cuando no se guardo es peor que fallar: se descubre cuando vas a
    # buscar el bundle y no esta.
    $login = ConvertFrom-CrmRespuesta -Code 200 -Cuerpo '<html><body>Sign in with Google</body></html>'
    if ($login.Confirmado) { throw 'una pantalla de login paso como subida exitosa' }

    $vacio = ConvertFrom-CrmRespuesta -Code 200 -Cuerpo ''
    if ($vacio.Confirmado) { throw 'una respuesta vacia paso como subida exitosa' }

    $sinOk = ConvertFrom-CrmRespuesta -Code 200 -Cuerpo '{"algo":"otra cosa"}'
    if ($sinOk.Confirmado) { throw 'un JSON sin ok paso como subida exitosa' }

    $redir = ConvertFrom-CrmRespuesta -Code 302 -Cuerpo '{"ok":true}'
    if ($redir.Confirmado) { throw 'un 302 paso como subida exitosa' }

    # Y lo que SI tiene que pasar, con su detalle.
    $bueno = ConvertFrom-CrmRespuesta -Code 201 -Cuerpo '{"ok":true,"clave":"bundles/2026/08/x.zip","duplicado":false}'
    if (-not $bueno.Confirmado)                        { throw 'una subida buena no se reconocio' }
    if ($bueno.Key -ne 'bundles/2026/08/x.zip')        { throw 'perdio la clave' }
    if ($bueno.Duplicate)                              { throw 'marco duplicado una subida nueva' }

    $rep = ConvertFrom-CrmRespuesta -Code 200 -Cuerpo '{"ok":true,"clave":"k","duplicado":true}'
    if (-not $rep.Confirmado) { throw 'un reintento valido no se reconocio' }
    if (-not $rep.Duplicate)  { throw 'no marco el reintento como duplicado' }
}

Test-SmokeFunction 'CrmUpload' 'el aviso de "quedo detras del login" se entiende' {
    # El error mas confuso posible: parece del toolkit y es del servidor.
    [string] $m = Get-CrmMensajeDeRespuestaRara -Code 302 -Cuerpo ''
    if ($m -notmatch 'login')  { throw ('el mensaje no nombra el login: {0}' -f $m) }
    if ($m -notmatch 'Access') { throw ('el mensaje no dice donde mirar: {0}' -f $m) }

    # Si el CRM se tomo el trabajo de explicar el rechazo, gana su mensaje.
    [string] $propio = Get-CrmMensajeDeRespuestaRara -Code 401 -Cuerpo '{"error":"Token de subida invalido o dado de baja."}'
    if ($propio -ne 'Token de subida invalido o dado de baja.') { throw ('piso el mensaje del CRM: {0}' -f $propio) }
}

Test-SmokeFunction 'CrmUpload' 'decir que NO no intenta nada' {
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'contenido' -Encoding ASCII
        function Test-PctkInteractiveConsole { $true }
        function Read-Host { param([string] $Prompt) 'n' }

        $r = Invoke-CrmUploadOffer -ZipPath $zip
        if ($r.Intentado) { throw 'intento subir despues de que el operador dijo que no' }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'en consola no interactiva se saltea sin preguntar' {
    # Un Read-Host en un gate automatizado cuelga el proceso esperando a nadie.
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'contenido' -Encoding ASCII
        function Test-PctkInteractiveConsole { $false }
        function Read-Host { param([string] $Prompt) throw 'pregunto en una consola no interactiva' }

        $r = Invoke-CrmUploadOffer -ZipPath $zip
        if ($r.Motivo -ne 'no-interactiva') { throw ('motivo inesperado: {0}' -f $r.Motivo) }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'el HANDLER del [L] ofrece subir y no desinstala nada' {
    # Este es el test que importa: entra por Invoke-ServiceClose, el mismo camino
    # que corre cuando el operador aprieta [L]. Probar Invoke-CrmUploadOffer suelta
    # dejaria sin ejercitar el cableado, que es donde viven los bugs que llegan a
    # produccion (leccion del [A][5] D de v2.3.0: helpers verdes, wiring roto).
    #
    # SE SHADOWEA Send-BundleToCrm, Y NO ES OPCIONAL. Sin eso este test SUBE UN
    # PAQUETE AL CRM DE VERDAD en cuanto la PC donde corre el smoke tenga la
    # conexion configurada -- que es justo lo que pasa en la PC de Mateo desde el
    # 2026-08-01. El dia que se escribio, su PC todavia no la tenia y el test
    # pasaba por el camino de "codigo invalido"; el mismo test, sin tocar una
    # linea, se volvio peligroso solo. Un test que muta produccion segun el estado
    # de la maquina donde corre no es un test.
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'contenido' -Encoding ASCII

        function Invoke-CloseService { [PSCustomObject]@{ Status = 'OK'; ZipPath = $zip } }
        function Test-PctkInteractiveConsole { $true }
        function Invoke-UninstallToolkit { throw 'el handler lanzo el DESINSTALADOR en el smoke' }
        # Sin paquete pendiente: se ejercita el camino normal (empaquetar y ofrecer).
        function Get-BundlePendienteDeSubir { $null }
        function Send-BundleToCrm { throw 'el smoke intento SUBIR ALGO A LA RED' }
        function Read-Host { param([string] $Prompt) 'S' }

        [bool] $r = Invoke-ServiceClose
        if ($r) { throw 'Invoke-ServiceClose devolvio $true: habria cerrado PCTk para desinstalar' }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'con un paquete sin subir, el [L] ofrece ESE y no arma otro' {
    # El caso de campo del 2026-08-01: la subida no salio, el operador apreto [L]
    # otra vez y quedaron dos ZIP a 41 segundos uno del otro en el Escritorio del
    # cliente -- con la proteccion anti-duplicados del CRM sin poder ayudar,
    # porque el identificador sale del nombre del archivo.
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41p-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'el paquete que quedo sin subir' -Encoding ASCII
        $script:subidoDe = ''

        # #48: el paquete es de hace 7 dias, y ESO tiene que estar en pantalla
        # (no solo el nombre del archivo con la fecha embebida).
        $script:enPantalla = @()
        [string] $hace7 = (Get-Date).AddDays(-7).ToString('yyyy-MM-ddTHH:mm:sszzz')

        function Get-BundlePendienteDeSubir { [PSCustomObject]@{ ZipPath = $zip; ClosedAt = $hace7 } }
        function Write-PctkWarn { param([string] $Message) $script:enPantalla += $Message }
        function Write-PctkHint { param([string] $Message) $script:enPantalla += $Message }
        function Invoke-CrmUploadOffer { param([string] $ZipPath, [string] $OutputRootOverride = '')
            $script:subidoDe = $ZipPath
            return [PSCustomObject]@{ Intentado = $true; Ok = $true; Motivo = '' } }
        function Invoke-CloseService { throw 'RE-EMPAQUETO teniendo un paquete sin subir' }
        function Invoke-ExportClientLogs { throw 'RE-EMPAQUETO teniendo un paquete sin subir' }
        function Invoke-UninstallToolkit { throw 'el handler lanzo el DESINSTALADOR en el smoke' }
        function Read-Host { param([string] $Prompt) 'S' }

        [bool] $r = Invoke-ServiceClose
        if ($r) { throw 'Invoke-ServiceClose devolvio $true' }
        if ($script:subidoDe -ne $zip) {
            throw ('subio otra cosa (o nada): "{0}"' -f $script:subidoDe)
        }

        # #48 por el handler, no por el helper suelto (regla del repo).
        [string] $todo = $script:enPantalla -join ' | '
        if ($todo -notmatch 'hace 7 dias') { throw ('la edad del paquete no salio en pantalla: {0}' -f $todo) }
        if ($todo -notmatch 'NO se arma un paquete nuevo') { throw ('no avisa que aceptar termina ahi: {0}' -f $todo) }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'CrmUpload' 'decir que NO al pendiente vuelve a empaquetar (no se decide por el operador)' {
    [string] $zip = Join-Path $env:TEMP ('pctk-smoke-41n-{0}.zip' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -LiteralPath $zip -Value 'viejo' -Encoding ASCII
        $script:empaqueto = $false

        function Get-BundlePendienteDeSubir { [PSCustomObject]@{ ZipPath = $zip; ClosedAt = '' } }
        function Invoke-CloseService { $script:empaqueto = $true; [PSCustomObject]@{ Status = 'OK'; ZipPath = $zip } }
        function Test-PctkInteractiveConsole { $false }   # sin preguntas de subida
        function Invoke-UninstallToolkit { throw 'lanzo el DESINSTALADOR' }
        function Send-BundleToCrm { throw 'el smoke intento SUBIR ALGO A LA RED' }
        # 'N' al pendiente, y despues 'N' a "dejar PCTk instalado" seria desinstalar:
        # por eso el segundo prompt responde 'S'. El contador dice cual es cual.
        $script:prompts = 0
        function Read-Host { param([string] $Prompt) $script:prompts++; if ($script:prompts -eq 1) { 'N' } else { 'S' } }

        $null = Invoke-ServiceClose
        if (-not $script:empaqueto) { throw 'dijo que no al pendiente y tampoco empaqueto: se quedo sin hacer nada' }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' 'el marcador distingue "hecho" de "subido"' {
    [string] $tmp = Join-Path $env:TEMP ('pctk-smoke-mk-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    [string] $zip = Join-Path $tmp 'paquete.zip'
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'output\state') -Force
        Set-Content -LiteralPath $zip -Value 'x' -Encoding ASCII

        $null = Set-LastBundleMarker -ZipPath $zip -OutputRootOverride $tmp
        $p = Get-BundlePendienteDeSubir -OutputRootOverride $tmp
        if ($null -eq $p) { throw 'un paquete recien hecho y sin subir tiene que figurar como pendiente' }
        if ($p.ZipPath -ne $zip) { throw 'devolvio otra ruta' }

        if (-not (Set-BundleUploadedMarker -OutputRootOverride $tmp)) { throw 'no pudo anotar la subida' }
        if ($null -ne (Get-BundlePendienteDeSubir -OutputRootOverride $tmp)) {
            throw 'sigue figurando como pendiente despues de subirlo'
        }

        # Anotar la subida NO puede romper lo que el [U] lee del mismo archivo.
        $m = Get-LastBundleMarker -OutputRootOverride $tmp
        if ([string]$m.zip_path -ne $zip)                { throw 'se perdio zip_path' }
        if ([string]$m.hostname -ne $env:COMPUTERNAME)   { throw 'se perdio hostname' }
        if ([string]::IsNullOrWhiteSpace([string]$m.closed_at)) { throw 'se perdio closed_at' }
        if (-not (Test-BundleAlreadyTaken -OutputRootOverride $tmp)) { throw 'el [U] dejo de ver el marcador' }

        # Si el ZIP ya no esta (el operador se lo llevo y lo borro), no se ofrece
        # subir un archivo que no existe.
        $null = Set-LastBundleMarker -ZipPath $zip -OutputRootOverride $tmp
        Remove-Item -LiteralPath $zip -Force
        if ($null -ne (Get-BundlePendienteDeSubir -OutputRootOverride $tmp)) {
            throw 'ofrecio subir un ZIP que ya no esta'
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ServiceState' '#48: la edad del paquete pendiente se dice en criollo' {
    # Casos borde del helper (el camino por el handler ya se prueba arriba).
    [datetime] $hoy = [datetime]'2026-08-08'

    [string] $d = Get-BundlePendienteDescripcion -ClosedAt '2026-08-01T02:54:30-03:00' -Ahora $hoy
    if ($d -notmatch 'del 01/08' -or $d -notmatch 'hace 7 dias') { throw ('7 dias: "{0}"' -f $d) }

    $d = Get-BundlePendienteDescripcion -ClosedAt '2026-08-08T09:00:00-03:00' -Ahora $hoy
    if ($d -notmatch 'HOY') { throw ('hoy: "{0}"' -f $d) }

    $d = Get-BundlePendienteDescripcion -ClosedAt '2026-08-07T23:59:00-03:00' -Ahora $hoy
    if ($d -notmatch 'AYER') { throw ('ayer: "{0}"' -f $d) }

    # Sin fecha o con basura: NADA, no una edad inventada.
    if ((Get-BundlePendienteDescripcion -ClosedAt '') -ne '')          { throw 'sin fecha tiene que callar' }
    if ((Get-BundlePendienteDescripcion -ClosedAt 'no-es-fecha') -ne '') { throw 'con basura tiene que callar' }
}

Test-SmokeFunction 'CrmUpload' 'el [L] sigue cableado a la subida (no se desconecto sin querer)' {
    # Chequeo por AST, no por texto: busca la llamada de verdad adentro de
    # Invoke-ServiceClose. Si alguien saca esa linea, el [L] vuelve a dejar el ZIP
    # en el Escritorio y nadie se entera hasta que Mateo lo note en un cliente.
    [string] $routerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core\Router.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($routerPath, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Invoke-ServiceClose' }, $true)
    if ($null -eq $fn) { throw 'no encontre Invoke-ServiceClose en Router.ps1' }

    $llamada = $fn.Find({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-CrmUploadOffer' }, $true)
    if ($null -eq $llamada) { throw 'Invoke-ServiceClose ya no llama a Invoke-CrmUploadOffer' }
}

# ─── VaultUpload: el deposito de la clave de BitLocker en la boveda ──────────

Test-SmokeFunction 'VaultUpload' 'base64url de JWK -> bytes (el alfabeto con - y _)' {
    # Vector conocido: el exponente RSA estandar 65537 viaja en JWK como AQAB.
    [byte[]] $e = ConvertFrom-PctkBase64Url -Text 'AQAB'
    if ($e.Length -ne 3 -or $e[0] -ne 1 -or $e[1] -ne 0 -or $e[2] -ne 1) { throw 'AQAB tiene que dar 01 00 01' }

    # Y el alfabeto entero: 0..255 en base64 trae + y / seguro; la vuelta por
    # base64url (con - y _, sin relleno) tiene que devolver los mismos bytes.
    [byte[]] $todos = 0..255
    [string] $b64url = [Convert]::ToBase64String($todos).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [byte[]] $vuelta = ConvertFrom-PctkBase64Url -Text $b64url
    if ($vuelta.Length -ne 256) { throw ('se perdieron bytes: {0}' -f $vuelta.Length) }
    for ($i = 0; $i -lt 256; $i++) {
        if ($vuelta[$i] -ne $todos[$i]) { throw ('byte {0} distinto' -f $i) }
    }
}

Test-SmokeFunction 'VaultUpload' 'el sobre cierra con la publica JWK y abre con la privada (round-trip real)' {
    # Criptografia de verdad, no un doble: el mismo camino que va a correr en la
    # PC de un cliente. [RSA]::Create(2048) devuelve RSACng, que es el proveedor
    # que soporta OAEP-SHA256 (el default legacy revienta recien al ejecutar).
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($false)
        $jwk = [PSCustomObject]@{
            n = [Convert]::ToBase64String($p.Modulus).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            e = [Convert]::ToBase64String($p.Exponent).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }

        [string] $clave = '484934-291043-113355-002211-887766-554433-221100-998877'
        [string] $sobre = Protect-PctkSecret -Secret $clave -Publica $jwk

        # Un sobre RSA-2048 mide SIEMPRE 344 en base64: es la forma que el CRM
        # verifica para rechazar un secreto que llegue en claro.
        if ($sobre.Length -ne 344) { throw ('el sobre mide {0}, no 344' -f $sobre.Length) }
        if ($sobre.Contains($clave)) { throw 'el sobre contiene el secreto en claro' }

        [byte[]] $abierto = $rsa.Decrypt([Convert]::FromBase64String($sobre), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        if ([System.Text.Encoding]::UTF8.GetString($abierto) -ne $clave) { throw 'el secreto no volvio igual' }
    } finally {
        $rsa.Dispose()
    }
}

Test-SmokeFunction 'VaultUpload' 'un secreto de mas de 190 bytes falla CLARO, no se trunca' {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($false)
        $jwk = [PSCustomObject]@{
            n = [Convert]::ToBase64String($p.Modulus).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            e = [Convert]::ToBase64String($p.Exponent).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }

        [bool] $tiro = $false
        try {
            $null = Protect-PctkSecret -Secret ('x' * 191) -Publica $jwk
        } catch {
            $tiro = $true
            if ($_.Exception.Message -notmatch '190') { throw ('el error no dice el tope: {0}' -f $_.Exception.Message) }
            if ($_.Exception.Message -notmatch 'cort') { throw ('el error no dice que NO trunca: {0}' -f $_.Exception.Message) }
        }
        if (-not $tiro) { throw 'un secreto que no entra tiene que tirar, no truncarse' }
    } finally {
        $rsa.Dispose()
    }
}

Test-SmokeFunction 'VaultUpload' 'sin publica cargada no hay oferta (el archivo shippea en blanco)' {
    # NO se mira el data\vault-publica.json del repo: el dia que se cargue la
    # publica real, un test atado a ese archivo cambiaria de resultado solo.
    # Se prueban las DOS variantes con fixtures propias.
    [string] $tmp = Join-Path $env:TEMP ('pctk-smoke-vault-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'data') -Force
        [string] $f = Join-Path $tmp 'data\vault-publica.json'

        Set-Content -LiteralPath $f -Value '{"kty":"RSA","n":"","e":""}' -Encoding ASCII
        if ($null -ne (Get-VaultPublica -RootOverride $tmp)) { throw 'con n y e vacios tiene que dar $null' }

        Set-Content -LiteralPath $f -Value 'esto no es json' -Encoding ASCII
        if ($null -ne (Get-VaultPublica -RootOverride $tmp)) { throw 'ilegible tiene que dar $null, no tirar' }

        Set-Content -LiteralPath $f -Value '{"kty":"RSA","n":"abc123","e":"AQAB"}' -Encoding ASCII
        $pub = Get-VaultPublica -RootOverride $tmp
        if ($null -eq $pub -or $pub.n -ne 'abc123' -or $pub.e -ne 'AQAB') { throw 'una publica cargada tiene que volver' }

        # Y con la publica ausente, la oferta se saltea SIN preguntar ni salir a
        # la red -- la clave sigue en pantalla y en output\recovery\.
        function Get-VaultPublica { param([string] $RootOverride = '') $null }
        function Test-PctkInteractiveConsole { $true }
        function Read-Host { param([string] $Prompt) throw 'pregunto sin tener boveda configurada' }
        function Send-VaultSecretToCrm { throw 'salio a la red sin publica' }

        $r = Invoke-VaultDepositOffer -Keys @([PSCustomObject]@{ KeyId8 = 'AAAA1111'; RecoveryPassword = 'x' })
        if ($r.Motivo -ne 'sin-publica') { throw ('motivo inesperado: {0}' -f $r.Motivo) }
        if ($r.Intentado) { throw 'no tenia que intentar nada' }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'VaultUpload' 'la respuesta del CRM se juzga con la MISMA vara que los bundles' {
    # Send-VaultSecretToCrm reusa ConvertFrom-CrmRespuesta: un 2xx sin ok=true
    # (pantalla de login, portal de wifi) NO cuenta como depositado. Chequeo por
    # AST que la llamada siga ahi -- si alguien la reemplaza por un parseo
    # propio, las dos definiciones divergen en silencio.
    [string] $mod = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\VaultUpload.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($mod, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Send-VaultSecretToCrm' }, $true)
    if ($null -eq $fn) { throw 'no encontre Send-VaultSecretToCrm' }

    foreach ($compartida in @('ConvertFrom-CrmRespuesta', 'Get-CrmMensajeDeRespuestaRara')) {
        $llamada = $fn.Find({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq $compartida }, $true)
        if ($null -eq $llamada) { throw ('Send-VaultSecretToCrm dejo de usar {0}' -f $compartida) }
    }
}

Test-SmokeFunction 'VaultUpload' 'el HANDLER del [A][18][C] deposita y LO QUE VIAJA VA CIFRADO' {
    # El test que importa: entra por Invoke-ActionEncryption, el mismo camino que
    # corre cuando el operador aprieta [C] (los helpers verdes con el wiring roto
    # son la leccion repetida del repo). Y el assert central es el guard por
    # mutacion del plan: si a Protect-PctkSecret le sacaran el cifrado, aca lo
    # que viaja seria la clave pelada y este test se pone ROJO.
    #
    # SE SHADOWEA Send-VaultSecretToCrm, Y NO ES OPCIONAL: sin eso, en cuanto
    # esta PC tenga la conexion al CRM configurada, el smoke DEPOSITARIA un
    # sobre de verdad en la boveda (misma trampa que la subida de bundles).
    $ErrorActionPreference = 'Stop'   # espejo de main.ps1; el smoke corre igual

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($false)
        $script:jwkPrueba = [PSCustomObject]@{
            n = [Convert]::ToBase64String($p.Modulus).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            e = [Convert]::ToBase64String($p.Exponent).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }
        [string] $script:claveReal = '111111-222222-333333-444444-555555-666666-777777-888888'
        $script:sobreQueViajo = ''
        $script:etiquetaQueViajo = ''

        function Get-DiskEncryptionStatus { param([string] $DriveLetter = 'C:')
            [PSCustomObject]@{
                Encryptable = $true; IsEncrypted = $true; ConversionLabel = 'FullyEncrypted'
                EncryptionPct = 100; EncryptionMethod = 'XtsAes128'; ProtectionOn = $true
                HasRecoveryProtector = $true
            } }
        # OJO: sin coma adelante. La funcion real devuelve el array PLANO (el
        # pipeline lo desenrolla y el @() del handler lo vuelve a juntar); un
        # doble con `, @(...)` mete un array adentro de otro y el KeyId8 se
        # pierde en PSObject.Properties aunque RecoveryPassword resuelva por
        # enumeracion de miembros -- exactamente el FAIL que tuvo este test.
        function Get-BitLockerRecoveryKey { param([string] $DriveLetter = 'C:')
            @([PSCustomObject]@{ KeyProtectorId = '{ABCD}'; KeyId8 = 'ABCD1234'; RecoveryPassword = $script:claveReal }) }
        function Save-BitLockerRecoveryKey { param([object[]] $Keys, [string] $OutputRootOverride = '', [string] $TimestampOverride = '') '' }
        function Get-VaultPublica { param([string] $RootOverride = '') $script:jwkPrueba }
        function Get-CrmConfig { param([string] $OutputRootOverride = '')
            [PSCustomObject]@{ Url = 'https://crm.de.prueba'; Token = 'token-de-prueba' } }
        function Test-PctkInteractiveConsole { $true }
        function Send-VaultSecretToCrm { param([string] $Url, [string] $Token, [string] $Tipo, [string] $SobreB64, [string] $Etiqueta = '', [string] $ComputerNameOverride = '', [int] $TimeoutSeconds = 60)
            $script:sobreQueViajo = $SobreB64
            $script:etiquetaQueViajo = $Etiqueta
            [PSCustomObject]@{ Ok = $true; Duplicate = $false; Message = 'Depositado.'; StatusCode = 201 } }
        # Primer prompt: la opcion del submenu ([C]). Segundo: depositar? (S).
        $script:prompts = 0
        function Read-Host { param([string] $Prompt) $script:prompts++; if ($script:prompts -eq 1) { 'C' } else { 'S' } }

        Invoke-ActionEncryption -MachineProfile ([PSCustomObject]@{ IsHome = $false }) | Out-Null

        if ($script:sobreQueViajo -eq '') { throw 'el handler no ofrecio depositar (el wiring se corto)' }
        if ($script:sobreQueViajo.Length -ne 344) {
            throw ('lo que viajo NO es un sobre RSA-2048 (mide {0}, no 344)' -f $script:sobreQueViajo.Length)
        }
        if ($script:sobreQueViajo.Contains($script:claveReal)) { throw 'LA CLAVE VIAJO EN CLARO' }
        if ($script:etiquetaQueViajo -notmatch 'ABCD1234') { throw 'la etiqueta perdio el Key ID' }

        # Y el sobre abre con la privada del test: es EL secreto, cifrado, no
        # cualquier cosa de 344 caracteres.
        [byte[]] $abierto = $rsa.Decrypt([Convert]::FromBase64String($script:sobreQueViajo), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        if ([System.Text.Encoding]::UTF8.GetString($abierto) -ne $script:claveReal) { throw 'el sobre no contiene la clave capturada' }
    } finally {
        $rsa.Dispose()
    }
}

Test-SmokeFunction 'VaultUpload' 'en consola no interactiva el deposito se saltea sin preguntar' {
    function Test-PctkInteractiveConsole { $false }
    function Read-Host { param([string] $Prompt) throw 'pregunto en una consola no interactiva' }
    function Send-VaultSecretToCrm { throw 'el smoke intento salir a la red' }

    $r = Invoke-VaultDepositOffer -Keys @([PSCustomObject]@{ KeyId8 = 'AAAA1111'; RecoveryPassword = 'x' })
    if ($r.Motivo -ne 'no-interactiva') { throw ('motivo inesperado: {0}' -f $r.Motivo) }
}

Test-SmokeFunction 'VaultUpload' 'el [A][18][C] sigue cableado al deposito (no se desconecto sin querer)' {
    # Chequeo por AST y preguntandole a la CARPETA, no a un archivo puntual: el
    # guard atado a un path se vacia en silencio cuando el codigo se muda
    # (leccion del split de Router.ps1).
    [string] $coreDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
    $fn = $null
    foreach ($f in (Get-ChildItem -Path (Join-Path $coreDir '*.ps1') -File)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $hit = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-ActionEncryption' }, $true)
        if ($null -ne $hit) { $fn = $hit; break }
    }
    if ($null -eq $fn) { throw 'no encontre Invoke-ActionEncryption en core\' }

    $llamada = $fn.Find({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-VaultDepositOffer' }, $true)
    if ($null -eq $llamada) { throw 'Invoke-ActionEncryption ya no llama a Invoke-VaultDepositOffer' }
}

# --- tools al dia: manifest + runtime .NET 8 de BCU + checker -----------------
Test-SmokeFunction 'ToolsAlDia' 'manifest: sha256 solo en pinned; los 5 bumps pinneados llevan hash; "requires" conocido' {
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in @($m.tools)) {
        [string] $pol = if ($t.PSObject.Properties['updatePolicy']) { [string]$t.updatePolicy } else { 'latest' }
        [string] $sha = if ($t.PSObject.Properties['sha256']) { [string]$t.sha256 } else { '' }
        if ($pol -ne 'pinned' -and $sha -ne '') { throw ('{0}: sha256 en una entry {1} (un hash fijo rompe la descarga en la proxima version)' -f $t.name, $pol) }
        if ($sha -ne '' -and $sha -notmatch '^[0-9a-f]{64}$') { throw ('{0}: sha256 mal formado' -f $t.name) }
        if ($t.PSObject.Properties['requires'] -and @('dotnet-desktop-8') -notcontains [string]$t.requires) {
            throw ('{0}: requires desconocido "{1}"' -f $t.name, $t.requires)
        }
    }
    foreach ($n in @('bcu', 'bleachbit', 'presentmon', 'wiztree', 'cpuz')) {
        $t = @($m.tools | Where-Object { $_.name -eq $n }) | Select-Object -First 1
        if ($null -eq $t) { throw ('{0} no esta en el manifest' -f $n) }
        if ([string]$t.sha256 -notmatch '^[0-9a-f]{64}$') { throw ('{0}: pinned sin sha256' -f $n) }
    }
}

Test-SmokeFunction 'ToolsAlDia' 'manifest: bcu 6.3 net8 en la org nueva, con requires' {
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $t = @($m.tools | Where-Object { $_.name -eq 'bcu' }) | Select-Object -First 1
    if ([string]$t.url -notmatch '^https://github\.com/BCUninstaller/.*_net8\.0-windows.*\.zip$') { throw ('url inesperada: {0}' -f $t.url) }
    if ([string]$t.checkUpdate -notmatch 'repos/BCUninstaller/') { throw ('checkUpdate en la org vieja: {0}' -f $t.checkUpdate) }
    if ([string]$t.requires -ne 'dotnet-desktop-8') { throw 'bcu sin requires=dotnet-desktop-8' }
    if ([string]$t.version -ne '6.3.0') { throw ('version {0}' -f $t.version) }
}

function New-ToolsAlDiaFixture {
    param([string[]] $RuntimeVersions = @())
    [string] $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk-tad-' + [guid]::NewGuid().ToString('N'))
    [string] $bin  = Join-Path $root 'bin'
    [string] $dn   = Join-Path $root 'dotnet'
    New-Item -ItemType Directory -Path (Join-Path $bin 'BCUninstaller') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bin 'Plain') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'BCUninstaller\BCUninstaller.exe') -Value 'x'
    Set-Content -LiteralPath (Join-Path $bin 'Plain\plain.exe') -Value 'x'
    foreach ($v in $RuntimeVersions) {
        New-Item -ItemType Directory -Path (Join-Path $dn ('shared\Microsoft.WindowsDesktop.App\' + $v)) -Force | Out-Null
    }
    return [PSCustomObject]@{
        Root = $root; Bin = $bin; DotNet = $dn
        Bcu   = [PSCustomObject]@{ name = 'bcu';   launchExe = 'BCUninstaller\BCUninstaller.exe'; requires = 'dotnet-desktop-8' }
        Plain = [PSCustomObject]@{ name = 'plain'; launchExe = 'Plain\plain.exe' }
    }
}

Test-SmokeFunction 'ToolsAlDia' 'deteccion .NET Desktop: 0, 1 y 2+ carpetas de version (y 9.x no vale para 8)' {
    $f0 = New-ToolsAlDiaFixture
    $f1 = New-ToolsAlDiaFixture -RuntimeVersions @('8.0.11')
    $f2 = New-ToolsAlDiaFixture -RuntimeVersions @('8.0.11', '9.0.2')
    $f9 = New-ToolsAlDiaFixture -RuntimeVersions @('9.0.2')
    try {
        if ((Get-DotNetDesktopRuntimeVersion -DotNetRoot $f0.DotNet).Count -ne 0) { throw '0 carpetas: esperaba 0' }
        if ((Get-DotNetDesktopRuntimeVersion -DotNetRoot $f1.DotNet).Count -ne 1) { throw '1 carpeta: esperaba Count 1 (trampa @() de 1 elemento)' }
        if ((Get-DotNetDesktopRuntimeVersion -DotNetRoot $f2.DotNet).Count -ne 2) { throw '2 carpetas: esperaba 2' }
        if (Test-DotNetDesktopRuntime -Major 8 -DotNetRoot $f0.DotNet) { throw '0 carpetas: dijo que hay 8' }
        if (-not (Test-DotNetDesktopRuntime -Major 8 -DotNetRoot $f1.DotNet)) { throw '1 carpeta 8.0.11: dijo que no hay 8' }
        if (-not (Test-DotNetDesktopRuntime -Major 8 -DotNetRoot $f2.DotNet)) { throw '8+9: dijo que no hay 8' }
        if (Test-DotNetDesktopRuntime -Major 8 -DotNetRoot $f9.DotNet) { throw 'solo 9.x: acepto como 8 (BCU no tiene rollForward)' }
    } finally {
        foreach ($f in @($f0, $f1, $f2, $f9)) { Remove-Item -LiteralPath $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Handler: Invoke-ToolLaunch es lo que corre la flecha-derecha del selector.
# Se shadowean winget, Start-Process, Get-Command y Write-ActionAudit; NUNCA corre winget real.
Test-SmokeFunction 'ToolsAlDia' 'lanzador: runtime presente -> no instala y abre' {
    $fx = New-ToolsAlDiaFixture -RuntimeVersions @('8.0.11')
    $script:wgCalls = 0; $script:spCalls = 0
    function winget { $script:wgCalls++; $global:LASTEXITCODE = 0 }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Bcu -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'opened') { throw ('resultado {0}' -f $r) }
        if ($script:wgCalls -ne 0) { throw 'instalo con el runtime ya presente' }
        if ($script:spCalls -ne 1) { throw ('Start-Process x{0}' -f $script:spCalls) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'lanzador: ausente + winget ok + re-deteccion ok -> instala con los flags y abre' {
    $fx = New-ToolsAlDiaFixture
    $script:wgArgs = @(); $script:spCalls = 0; $script:audit = @()
    $script:dnRoot = $fx.DotNet
    function winget {
        $script:wgArgs = @($args)
        New-Item -ItemType Directory -Path (Join-Path $script:dnRoot 'shared\Microsoft.WindowsDesktop.App\8.0.11') -Force | Out-Null
        $global:LASTEXITCODE = 0
    }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:audit += ('{0}:{1}' -f $Action, $Status) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Bcu -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'opened') { throw ('resultado {0}' -f $r) }
        [string] $a = $script:wgArgs -join ' '
        foreach ($need in @('install', '--id Microsoft.DotNet.DesktopRuntime.8', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')) {
            if ($a -notmatch [regex]::Escape($need)) { throw ('a winget le falta "{0}": {1}' -f $need, $a) }
        }
        if ($script:spCalls -ne 1) { throw 'no abrio tras instalar' }
        if ($script:audit -notcontains 'Tools.RuntimeInstall:Success') { throw 'sin audit Success' }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'lanzador: ausente + winget exit != 0 -> NO abre (aunque EAP=Stop)' {
    $fx = New-ToolsAlDiaFixture
    $script:spCalls = 0; $script:audit = @()
    function winget { $global:LASTEXITCODE = 1603 }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) $script:audit += ('{0}:{1}' -f $Action, $Status) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Bcu -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'blocked') { throw ('resultado {0}' -f $r) }
        if ($script:spCalls -ne 0) { throw 'abrio BCU sin runtime' }
        if ($script:audit -notcontains 'Tools.RuntimeInstall:Failed') { throw 'sin audit Failed' }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'lanzador: winget "ok" pero el runtime no aparece -> NO abre (el exit code no alcanza)' {
    $fx = New-ToolsAlDiaFixture
    $script:spCalls = 0
    function winget { $global:LASTEXITCODE = 0 }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Bcu -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'blocked' -or $script:spCalls -ne 0) { throw ('resultado {0}, Start-Process x{1}' -f $r, $script:spCalls) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'lanzador: ausente sin winget -> NO abre' {
    $fx = New-ToolsAlDiaFixture
    $script:spCalls = 0; $script:wgCalls = 0
    function Get-Command { param($Name, $ErrorAction) if ($Name -eq 'winget') { return $null }; Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
    function winget { $script:wgCalls++ }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Bcu -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'blocked' -or $script:spCalls -ne 0 -or $script:wgCalls -ne 0) { throw ('resultado {0}, Start-Process x{1}, winget x{2}' -f $r, $script:spCalls, $script:wgCalls) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'lanzador: tool SIN requires abre como siempre, sin tocar winget' {
    $fx = New-ToolsAlDiaFixture
    $script:spCalls = 0; $script:wgCalls = 0
    function winget { $script:wgCalls++ }
    function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList) $script:spCalls++ }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    try {
        $r = Invoke-ToolLaunch -Tool $fx.Plain -BinDir $fx.Bin -DotNetRoot $fx.DotNet
        if ($r -ne 'opened' -or $script:spCalls -ne 1 -or $script:wgCalls -ne 0) { throw ('resultado {0}, Start-Process x{1}, winget x{2}' -f $r, $script:spCalls, $script:wgCalls) }
    } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-SmokeFunction 'ToolsAlDia' 'el selector (flecha-derecha) abre por Invoke-ToolLaunch, y nadie mas lanza launchExe' {
    [string] $root = Split-Path -Parent $PSScriptRoot
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'core\Router.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ToolsMenuInteractive' }, $true)
    if ($null -eq $fn) { throw 'no encontre Invoke-ToolsMenuInteractive' }
    $call = $fn.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ToolLaunch' }, $true)
    if ($null -eq $call) { throw 'el selector ya no abre por Invoke-ToolLaunch: se saltea el chequeo de requires' }
    [string[]] $otros = @()
    foreach ($d in @('core', 'modules', 'utils')) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $root $d) -Filter '*.ps1' -File)) {
            if ($f.Name -eq 'Router.ps1') { continue }
            if ((Get-Content -LiteralPath $f.FullName -Raw) -match 'launchExe') { $otros += $f.Name }
        }
    }
    if ($otros.Count -gt 0) { throw ('otro archivo toca launchExe sin pasar por Invoke-ToolLaunch: {0}' -f ($otros -join ', ')) }
}

Test-SmokeFunction 'ToolsAlDia' 'checker: reconoce el asset net8.0 de BCU 6.3 (y no el .7z ni el pack de idioma)' {
    [string] $chk = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Check-ToolUpdates.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($chk, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq '_Get-GithubAssetVersion' }, $true)
    if ($null -eq $fn) { throw 'no encontre _Get-GithubAssetVersion en Check-ToolUpdates.ps1' }
    . ([scriptblock]::Create($fn.Extent.Text))
    # nombres literales del release v6.3, con el .7z primero a proposito
    [string[]] $v63 = @('BCUninstaller_6.3.0_portable.7z', 'BCUninstaller_6.3.0_setup.exe', 'Localisation_Pack_6.3.0.zip', 'BCUninstaller_6.3.0_net8.0-windows10.0.18362.0.zip')
    $r = _Get-GithubAssetVersion -Assets $v63
    if ($null -eq $r -or $r.Version -ne '6.3.0') { throw 'no saco 6.3.0 del release 6.3' }
    if ($r.Asset -ne 'BCUninstaller_6.3.0_net8.0-windows10.0.18362.0.zip') { throw ('gano otro asset: {0}' -f $r.Asset) }
    $r = _Get-GithubAssetVersion -Assets @('BCUninstaller_6.1.0.1_portable.zip')
    if ($null -eq $r -or $r.Version -ne '6.1.0.1') { throw 'rompio el formato viejo _portable.zip (1 solo asset)' }
    if ($null -ne (_Get-GithubAssetVersion -Assets @('PresentMon-2.6.0-x64.exe'))) { throw 'matcheo un asset de otro repo (PresentMon)' }
    if ($null -ne (_Get-GithubAssetVersion -Assets @('BCUninstaller_6.3.0_portable.7z'))) { throw 'el .7z no debe ganar' }
    $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq '_Get-GithubAssetVersion' }, $true)
    if ($null -eq $call) { throw 'el checker ya no llama a _Get-GithubAssetVersion' }
}

# --- #86: rutas con espacios a Start-Process + guard StrictMode del menu de tools ---
# PS 5.1 une -ArgumentList con ' ' SIN comillas: una ruta con espacios (PCTk en una
# carpeta con espacios, un perfil de usuario "Juan Perez" en %TEMP%) le llega al
# exe partida en varios argumentos. Se prueba el HANDLER con Start-Process
# shadoweado, uniendo los argumentos como los une PS 5.1.
Test-SmokeFunction 'Robustez86' '#86a OOSU: el .cfg en ruta con espacios llega entrecomillado (Invoke-OOSU10Profile)' {
    [string] $cfg = 'C:\Carpeta Con Espacios\x.cfg'
    $script:r86SpArgs = $null
    function Get-ShutUp10Path { 'C:\fake\OOSU10.exe' }
    function Test-Path { param([string] $LiteralPath, [string] $Path) $true }
    function Start-Process {
        [CmdletBinding()]
        param($FilePath, $ArgumentList, [switch] $PassThru, $WindowStyle)
        $script:r86SpArgs = @($ArgumentList)
        $p = [PSCustomObject]@{ ExitCode = 0 }
        $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
        $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $p
    }
    $r = Invoke-OOSU10Profile -Path $cfg
    if ($null -eq $script:r86SpArgs) { throw ('no llamo a Start-Process (Reason: {0})' -f $r.Reason) }
    [string] $joined = $script:r86SpArgs -join ' '
    if (-not $joined.Contains(('"{0}"' -f $cfg))) { throw ('la ruta del .cfg llega partida a OOSU10: {0}' -f $joined) }
    if ($joined -notmatch '/quiet') { throw ('se perdio /quiet: {0}' -f $joined) }
    if (-not $r.Success) { throw ('Success=$false: {0}' -f $r.Reason) }
}

Test-SmokeFunction 'Robustez86' '#86a selector: una tool .ps1 en carpeta con espacios llega entrecomillada a -File (Invoke-ToolLaunch)' {
    [string] $bin = Join-Path ([System.IO.Path]::GetTempPath()) ('pctk 86 ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $bin -Force)
    [string] $ps1 = Join-Path $bin 'mi tool.ps1'
    [System.IO.File]::WriteAllText($ps1, '# fixture #86')
    $script:r86SpArgs = $null
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory) $script:r86SpArgs = @($ArgumentList) }
    function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
    try {
        $tool = [PSCustomObject]@{ name = 't86'; category = 'setup'; filename = 'mi tool.ps1' }
        $r = Invoke-ToolLaunch -Tool $tool -BinDir $bin
        if ($r -ne 'opened') { throw ('resultado {0}' -f $r) }
        [string] $joined = $script:r86SpArgs -join ' '
        if (-not $joined.Contains(('-File "{0}"' -f $ps1))) { throw ('la ruta del .ps1 llega partida a powershell -File: {0}' -f $joined) }
    } finally { Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction SilentlyContinue }
}

# El handler del [T] es Show-ToolsMenu. Bajo StrictMode, leer $manifest.tools o
# $t.category de un manifest que no los trae tira PropertyNotFoundStrict y se
# lleva el menu (y bajo EAP=Stop, el toolkit). Se shadowea la lectura del
# manifest, la consola (no interactiva) y el input ('B' = volver).
function New-R86ToolsMenuRun {
    param([string] $ManifestJson)
    Set-StrictMode -Version Latest
    $script:r86Json  = $ManifestJson
    $script:r86Lines = [System.Collections.Generic.List[string]]::new()
    $script:r86Warn  = [System.Collections.Generic.List[string]]::new()
    function Get-Content { param($Path, [switch] $Raw) $script:r86Json }
    function Test-PctkInteractiveConsole { $false }
    function Read-Host { param($Prompt) 'B' }
    function Write-Host { }
    function Write-PctkActionTitle { param($Title) }
    function Write-PctkLine { param([string] $Text, [string] $Kind) $script:r86Lines.Add($Text) }
    function Write-PctkWarn { param([string] $Text) $script:r86Warn.Add($Text) }
    function Write-PctkErr  { param([string] $Text) $script:r86Warn.Add($Text) }
    function Write-PctkHint { param([string] $Text) }
    Show-ToolsMenu -MachineProfile ([PSCustomObject]@{})
    return [PSCustomObject]@{ Lines = @($script:r86Lines); Warn = @($script:r86Warn) }
}

Test-SmokeFunction 'Robustez86' '#86b Show-ToolsMenu: manifest SIN tools degrada con aviso, no crashea (StrictMode)' {
    $o = New-R86ToolsMenuRun -ManifestJson '{ "version": 5 }'
    if (@($o.Warn).Count -lt 1) { throw 'no aviso que el manifest no trae herramientas' }
}

Test-SmokeFunction 'Robustez86' '#86b Show-ToolsMenu: tool SIN category se saltea con aviso; las sanas se listan (StrictMode)' {
    [string] $j = '{ "version": 5, "tools": [ { "name": "sana86", "category": "disco", "filename": "s.exe" }, { "name": "sincat86", "filename": "x.exe" } ] }'
    $o = New-R86ToolsMenuRun -ManifestJson $j
    if (-not (@($o.Lines) -match 'sana86'))    { throw 'la tool sana no se listo' }
    if (@($o.Lines) -match 'sincat86')         { throw 'la tool sin category se listo igual' }
    if (-not (@($o.Warn) -match 'sincat86'))   { throw 'no aviso que salteo la tool sin category' }
}

# Lint por AST (no por texto): un Start-Process cuyo -ArgumentList (nombrado o
# posicional, resuelto con StaticParameterBinder) lleva una variable o propiedad
# SUELTA -- sola o como elemento de un array -- pasa ese valor sin comillas. Si es
# una ruta, se parte en los espacios. Arreglo: ('"{0}"' -f $ruta).
# No mira splats (@params): ahi el binder no ve -ArgumentList (Apps.ps1, #77).
function Get-R86UnquotedStartProcessArg {
    param([System.Management.Automation.Language.Ast] $Ast, [string] $Label)
    [System.Collections.Generic.List[string]] $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        [string] $name = ''
        try { $name = [string] $c.GetCommandName() } catch { }
        if ($name -ne 'Start-Process') { continue }
        $b = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($c, $true)
        if ($null -eq $b -or -not $b.BoundParameters.ContainsKey('ArgumentList')) { continue }
        [System.Collections.Generic.List[object]] $pend = [System.Collections.Generic.List[object]]::new()
        $pend.Add($b.BoundParameters['ArgumentList'].Value)
        while ($pend.Count -gt 0) {
            $e = $pend[0]; $pend.RemoveAt(0)
            if ($e -is [System.Management.Automation.Language.VariableExpressionAst] -or
                $e -is [System.Management.Automation.Language.MemberExpressionAst]) {
                [void] $hits.Add(('{0}:{1} -> {2}' -f $Label, $e.Extent.StartLineNumber, $e.Extent.Text))
            } elseif ($e -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                foreach ($x in $e.Elements) { $pend.Add($x) }
            } elseif ($e -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                foreach ($s in $e.SubExpression.Statements) { $pend.Add($s) }
            } elseif ($e -is [System.Management.Automation.Language.PipelineAst]) {
                if ($e.PipelineElements.Count -eq 1 -and $e.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $pend.Add($e.PipelineElements[0].Expression)
                }
            }
        }
    }
    return $hits.ToArray()   # los que llaman envuelven en @(): 0/1/N
}

Test-SmokeFunction 'StaticCheck' '#86 lint Start-Process: tiene diente (marca suelta/posicional/en array; no marca entrecomillada)' {
    [string] $src = @'
Start-Process -FilePath $e -ArgumentList @($Path, '/quiet')
Start-Process explorer.exe $Dir
Start-Process powershell.exe -ArgumentList '-File', $f.FullName
Start-Process -FilePath $e -ArgumentList ('"{0}"' -f $Path)
Start-Process powershell.exe -ArgumentList @('-File', ('"{0}"' -f $p))
Start-Process -FilePath 'msiexec.exe' -ArgumentList "/X{$guid} /qn"
Start-Process @startParams
Start-Process $url
'@
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref] $null, [ref] $null)
    [string[]] $h = @(Get-R86UnquotedStartProcessArg -Ast $ast -Label 'fx')
    [string] $got = $h -join ' | '
    foreach ($need in @('fx:1 -> $Path', 'fx:2 -> $Dir', 'fx:3 -> $f.FullName')) {
        if ($h -notcontains $need) { throw ('no marco {0}; marco: {1}' -f $need, $got) }
    }
    if ($h.Count -ne 3) { throw ('falsos positivos: {0}' -f $got) }
}

Test-SmokeFunction 'StaticCheck' '#86 Start-Process -ArgumentList sin variables sueltas (rutas sin comillas) en core/modules/utils/raiz' {
    [string] $rRoot = Split-Path -Parent $PSScriptRoot
    [string[]] $patterns = @('core\*.ps1', 'modules\*.ps1', 'utils\*.ps1',
                             'main.ps1', 'Launch.ps1', 'Release.ps1', 'Bootstrap-Tools.ps1')
    [System.Collections.Generic.List[string]] $all = [System.Collections.Generic.List[string]]::new()
    [int] $files = 0
    foreach ($p in $patterns) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $rRoot $p) -File -ErrorAction SilentlyContinue)) {
            $files++
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $null)
            if ($null -eq $ast) { continue }
            foreach ($x in @(Get-R86UnquotedStartProcessArg -Ast $ast -Label $f.Name)) { [void] $all.Add($x) }
        }
    }
    if ($files -lt 20) { throw ('barrio solo {0} archivos: glob roto?' -f $files) }
    if ($all.Count -gt 0) {
        throw ('Start-Process con argumento suelto (una ruta con espacios se parte en PS 5.1): {0}. Usar (''"{{0}}"'' -f $ruta).' -f ($all -join ', '))
    }
}


# ─── Reporte ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '────────────────────────────────────────────────────────────────────'
Write-Host '  SMOKE TEST RESULTS'
Write-Host '────────────────────────────────────────────────────────────────────'

[int] $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count

# Guard: en headless TODO test corre. Un SKIP aca es un bug del mecanismo (una
# condicion de skip rota, o un test que se saltea solo) y vuelve rojo el smoke.
# No depende de la condicion de Test-SmokeFunction: cuenta lo que quedo registrado.
if ($script:SmokeHeadless -and $skipCount -gt 0) {
    $results.Add([PSCustomObject]@{
        Module     = 'SmokeHarness'
        Function   = 'corrida headless sin SKIP'
        Status     = 'FAIL'
        DurationMs = 0
        Error      = ('{0} test(s) en SKIP en una corrida headless: el mecanismo de skip esta roto' -f $skipCount)
    })
}

$results | Format-Table -AutoSize -Property Module, Function, Status, DurationMs

[int] $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
[int] $okCount   = @($results | Where-Object { $_.Status -eq 'OK' }).Count

# El resumen va a consola y, con -ResultPath, a archivo. SKIP se muestra SIEMPRE
# (tambien en 0): 'SKIP: 0' es la evidencia de que la corrida fue headless
# completa, y la linea tiene la misma forma en todo entorno (grepeable).
[string] $headlessCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/smoke.ps1 < /dev/null   (desde Bash)'
[System.Collections.Generic.List[string]] $summary = [System.Collections.Generic.List[string]]::new()
[void] $summary.Add(('  Entorno: {0} (stdin redirigido={1}, stdout redirigido={2}{3})' -f
    $(if ($script:SmokeHeadless) { 'headless' } else { 'consola interactiva' }),
    $script:SmokeInputRedirected, $script:SmokeOutputRedirected,
    $(if ($ForceInteractive) { ', simulada con -ForceInteractive' } else { '' })))
[void] $summary.Add(('  OK: {0}  FAIL: {1}  SKIP: {2}' -f $okCount, $failCount, $skipCount))
if ($skipCount -gt 0) {
    [void] $summary.Add('')
    if (-not $script:SmokeHeadless) {
        [void] $summary.Add(('  La corrida NO fue headless: {0} test(s) que asumen stdin/stdout redirigidos quedaron en SKIP.' -f $skipCount))
        [void] $summary.Add(('  Corrida canonica (todos corren): {0}' -f $headlessCmd))
    }
    [void] $summary.Add('  Salteados:')
    foreach ($s in @($results | Where-Object { $_.Status -eq 'SKIP' })) {
        [void] $summary.Add(('    [{0}::{1}] {2}' -f $s.Module, $s.Function, $s.Error))
    }
}
if ($failCount -gt 0) {
    [void] $summary.Add('')
    [void] $summary.Add('  Errores:')
    foreach ($f in @($results | Where-Object { $_.Status -eq 'FAIL' })) {
        [void] $summary.Add(('    [{0}::{1}] {2}' -f $f.Module, $f.Function, $f.Error))
    }
}

Write-Host ''
[string] $summaryColor = if ($failCount -gt 0) { 'Red' } elseif ($skipCount -gt 0) { 'Yellow' } else { 'Green' }
foreach ($line in $summary) { Write-Host $line -ForegroundColor $summaryColor }

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    try {
        [string[]] $fileLines = @(('PCTk smoke {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) + @($summary)
        # .NET resuelve rutas relativas contra el cwd del PROCESO, no el de PS.
        [string] $resultFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath)
        [System.IO.File]::WriteAllLines($resultFull, $fileLines, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ('  Resumen escrito en {0}' -f $resultFull) -ForegroundColor DarkGray
    } catch {
        Write-Host ('  No se pudo escribir el resumen en {0}: {1}' -f $ResultPath, $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

if ($failCount -gt 0) { exit 1 }

exit 0
