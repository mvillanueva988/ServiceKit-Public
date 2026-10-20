# DefenderPaths.ps1 -- #54 (B)+(C): rutas caras de Defender por GRABACION REAL + menu de exclusiones medidas.
#
# (A) (DefenderDiag.ps1) dice CUANTO cuesta Defender. Esto dice DONDE: graba N segundos de la
# actividad real que reproduce el operador (New-MpPerformanceRecording), saca el top de carpetas
# por costo de escaneo (Get-MpPerformanceReport -TopPaths -Raw) y le OFRECE a Mateo excluir las que
# el tilde, con el numero medido al lado. Nada se aplica sin que tilde Y confirme.
#
# Reglas: solo -ExclusionPath (nada de proceso/extension), no apaga Defender, no toca Tamper
# Protection, nunca entra al [1] ni a recetas (guard por AST en el smoke). El .etl vive en una
# carpeta propia de TEMP (pctk-defrec-<sello>) que se borra por la ruta guardada antes de preguntar:
# no queda en la PC del cliente. Lo aplicado queda en el audit (Defender.Exclusions.Measured).
#
# Forma del reporte (-Raw), leida del modulo de Windows (ConfigDefenderPerformance,
# MSFT_MpPerformanceRecording.psm1: ConvertTo-DefenderScanStats / ConvertTo-DefenderScannedPathsStats):
# duraciones en ticks de 100 ns (uint64); TopPaths = lista de { Path; Count; TotalDuration; ...;
# Folder[] opcional con los hijos }. Se aplana a las hojas. El parser es TOLERANTE (un solo elemento,
# TimeSpan ya convertido): lo que arma MpCmdRun en cada nivel se confirma en el gate HW elevado.
#
# ASCII puro a proposito (sin BOM): no mezclar non-ASCII aca sin re-aplicar el BOM.

# --- Calculo puro ---------------------------------------------------------------
function ConvertTo-DefenderPathKey {
    <#
    .SYNOPSIS
        Clave de comparacion de una ruta: minusculas, barra normal -> invertida, sin barra final
        (la raiz de unidad queda como "c:"). Pura.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    [string] $k = $Path.Trim().Replace('/', '\').ToLowerInvariant()
    while ($k.Length -gt 0 -and $k.EndsWith('\')) { $k = $k.Substring(0, $k.Length - 1) }
    return $k
}

function Test-DefenderPathUnder {
    # $true si $Key es $Root o cuelga de $Root (ambos ya normalizados).
    param([string] $Key, [string] $Root)
    if ($Key -eq '' -or $Root -eq '') { return $false }
    return ($Key -eq $Root -or $Key.StartsWith($Root + '\'))
}

function Test-DefenderPathOfferable {
    <#
    .SYNOPSIS
        Se le ofrece esta ruta al operador para excluirla? Devuelve { Offerable; Reason }.
        Pura: las raices entran por parametro (el smoke pasa raices fijas; produccion, las del
        entorno). Comparacion sin distinguir mayusculas y sin barra final.
        NO se ofrece: Windows y lo que cuelga; la raiz de Program Files; la raiz del perfil; TEMP y lo
        que cuelga; Descargas y lo que cuelga; la raiz de una unidad; cualquier ANCESTRO de las
        protegidas (C:\Users); lo ya excluido.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [Parameter()] [string]   $WindowsDir = $env:windir,
        [Parameter()] [string[]] $ProgramFilesDir = @($env:ProgramFiles, ${env:ProgramFiles(x86)}),
        [Parameter()] [string]   $UserProfile = $env:USERPROFILE,
        [Parameter()] [string[]] $TempDir = @($env:TEMP),
        [Parameter()] [string[]] $DownloadsDir = @(),
        [Parameter()] [string[]] $ExcludedPath = @()
    )
    [string] $k = ConvertTo-DefenderPathKey -Path $Path
    [string] $win = ConvertTo-DefenderPathKey -Path $WindowsDir
    [string] $prof = ConvertTo-DefenderPathKey -Path $UserProfile
    # Descargas: la del perfil SIEMPRE, mas la known folder si esta redirigida (D:\Descargas, OneDrive).
    [string[]] $dls = @($DownloadsDir | ForEach-Object { ConvertTo-DefenderPathKey -Path $_ } | Where-Object { $_ -ne '' })
    if ($prof -ne '') { $dls = @($dls) + @($prof + '\downloads') }
    [string[]] $pf = @($ProgramFilesDir | ForEach-Object { ConvertTo-DefenderPathKey -Path $_ } | Where-Object { $_ -ne '' })
    [string[]] $tmp = @($TempDir | ForEach-Object { ConvertTo-DefenderPathKey -Path $_ } | Where-Object { $_ -ne '' })
    [string[]] $exc = @($ExcludedPath | ForEach-Object { ConvertTo-DefenderPathKey -Path $_ } | Where-Object { $_ -ne '' })

    if ($k -eq '') { return [PSCustomObject]@{ Offerable = $false; Reason = 'ruta vacia' } }
    if ($k -match '^[a-z]:$') { return [PSCustomObject]@{ Offerable = $false; Reason = 'raiz de unidad' } }
    if (-not ($k -match '^[a-z]:\\' -or $k.StartsWith('\\'))) { return [PSCustomObject]@{ Offerable = $false; Reason = 'ruta no absoluta' } }
    if (Test-DefenderPathUnder -Key $k -Root $win) { return [PSCustomObject]@{ Offerable = $false; Reason = 'Windows' } }
    foreach ($p in $pf) {
        if ($k -eq $p) { return [PSCustomObject]@{ Offerable = $false; Reason = 'raiz de Program Files' } }
    }
    if ($prof -ne '' -and $k -eq $prof) { return [PSCustomObject]@{ Offerable = $false; Reason = 'raiz del perfil' } }
    foreach ($t in $tmp) {
        if (Test-DefenderPathUnder -Key $k -Root $t) { return [PSCustomObject]@{ Offerable = $false; Reason = 'TEMP' } }
    }
    foreach ($d in $dls) {
        if (Test-DefenderPathUnder -Key $k -Root $d) { return [PSCustomObject]@{ Offerable = $false; Reason = 'Descargas' } }
    }
    # Ancestro de cualquier protegida (C:\Users, C:\Users\x\AppData\Local, ...).
    [string[]] $protected = @($win, $prof) + $dls + $pf + $tmp
    foreach ($root in $protected) {
        if ($root -ne '' -and $root.StartsWith($k + '\')) { return [PSCustomObject]@{ Offerable = $false; Reason = 'ancestro de una ruta protegida' } }
    }
    foreach ($e in $exc) {
        if (Test-DefenderPathUnder -Key $k -Root $e) { return [PSCustomObject]@{ Offerable = $false; Reason = 'ya excluida' } }
    }
    return [PSCustomObject]@{ Offerable = $true; Reason = '' }
}

function Get-DefenderPathsReasonText {
    # El porque de cada regla (se imprime una vez debajo de la tabla).
    param([string] $Reason)
    switch ($Reason) {
        'Windows'                         { return 'Windows y todo lo que cuelga de el: excluirlo deja al sistema sin escaneo.' }
        'raiz de Program Files'           { return 'La raiz de Program Files es demasiado amplia (sus subcarpetas SI se ofrecen).' }
        'raiz del perfil'                 { return 'La raiz del perfil es demasiado amplia (sus subcarpetas SI se ofrecen).' }
        'TEMP'                            { return 'TEMP: es por donde entra lo que se baja o se ejecuta sin revisar.' }
        'Descargas'                       { return 'Descargas: es por donde entra lo que baja el usuario.' }
        'raiz de unidad'                  { return 'La raiz de una unidad equivale a apagar Defender en ese disco.' }
        'ancestro de una ruta protegida'  { return 'Contiene una ruta protegida (Windows, perfil, TEMP, Descargas): excluirla las arrastra.' }
        'ya excluida'                     { return 'Ya esta excluida (o cuelga de una exclusion existente).' }
        'ruta no absoluta'                { return 'El reporte no trajo la ruta completa: excluirla tal cual no apunta a la carpeta medida.' }
        default                           { return $Reason }
    }
}

function ConvertTo-DefenderDurationMs {
    <#
    .SYNOPSIS
        Duracion del reporte a milisegundos. -Raw trae ticks de 100 ns (numero); tambien
        acepta TimeSpan y texto. Pura. Lo ilegible da 0.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter()] $Value)
    if ($null -eq $Value) { return [double]0 }
    if ($Value -is [timespan]) { return [double]$Value.TotalMilliseconds }
    if ($Value -is [string]) {
        [timespan] $ts = [timespan]::Zero
        if ([timespan]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ts) -and $Value.Contains(':')) { return [double]$ts.TotalMilliseconds }
        [double] $d = 0
        if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return ($d / 10000.0) }
        return [double]0
    }
    try { return ([double]$Value / 10000.0) } catch { return [double]0 }
}

function ConvertTo-DefenderPerfList {
    # Un valor del reporte (array, UN objeto suelto, o un contenedor Items/Entries) a object[].
    param($Value)
    [object[]] $out = @()
    if ($null -eq $Value) { return , $out }
    [bool] $isArray = ($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])
    if (-not $isArray) {
        foreach ($wrap in @('Items', 'Entries', 'Paths', 'Extensions')) {
            $inner = Get-DefenderDiagProp -Object $Value -Name $wrap
            if ($null -ne $inner -and $null -eq (Get-DefenderDiagProp -Object $Value -Name 'Path') -and $null -eq (Get-DefenderDiagProp -Object $Value -Name 'Extension')) {
                $out = @($inner)
                return , $out
            }
        }
    }
    $out = @($Value)
    return , $out
}

function Get-DefenderPerfPathLeaves {
    <#
    .SYNOPSIS
        TopPaths puede venir en ARBOL: cada nodo trae Folder[] con sus hijos (lo arma MpCmdRun; el
        mapeo esta en ConvertTo-DefenderScannedPathsStats de MSFT_MpPerformanceRecording.psm1). Se
        aplana a las HOJAS, la agrupacion mas especifica (la exclusion mas angosta). Un hijo con
        ruta relativa se cuelga de la del padre. Devuelve { Path; Node }[]. Pura.
    #>
    param([object[]] $Nodes = @(), [string] $ParentPath = '')
    [System.Collections.Generic.List[object]] $leaves = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $Nodes) {
        if ($null -eq $node) { continue }
        [string] $nodePath = [string](Get-DefenderDiagProp -Object $node -Name 'Path')
        if ($ParentPath -ne '' -and $nodePath -ne '' -and -not ($nodePath -match '^[A-Za-z]:' -or $nodePath.StartsWith('\\'))) {
            $nodePath = $ParentPath.TrimEnd('\') + '\' + $nodePath.TrimStart('\')
        }
        [object[]] $kids = ConvertTo-DefenderPerfList -Value (Get-DefenderDiagProp -Object $node -Name 'Folder')
        if ($kids.Count -gt 0) {
            foreach ($leaf in (Get-DefenderPerfPathLeaves -Nodes $kids -ParentPath $nodePath)) { $leaves.Add($leaf) }
        } else {
            $leaves.Add([PSCustomObject]@{ Path = $nodePath; Node = $node })
        }
    }
    return , $leaves.ToArray()
}

function ConvertFrom-DefenderPerfReport {
    <#
    .SYNOPSIS
        Reporte de Get-MpPerformanceReport -Raw -> { Rows[]; Extensions[]; TotalMs }.
        Filas { Path; Count; TotalMs; AvgMs; Percent } ordenadas por costo; el % es sobre la suma
        de las filas devueltas. Extensiones { Extension; Count; TotalMs; AvgMs }. Pura.
    #>
    [CmdletBinding()]
    param([Parameter()] $Report)
    [System.Collections.Generic.List[object]] $rows = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[object]] $exts = [System.Collections.Generic.List[object]]::new()

    [object[]] $paths = ConvertTo-DefenderPerfList -Value (Get-DefenderDiagProp -Object $Report -Name 'TopPaths')
    foreach ($leaf in (Get-DefenderPerfPathLeaves -Nodes $paths)) {
        $p = $leaf.Node
        [string] $path = $leaf.Path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $dur = Get-DefenderDiagProp -Object $p -Name 'TotalDuration'
        if ($null -eq $dur) { $dur = Get-DefenderDiagProp -Object $p -Name 'Duration' }
        $cnt = Get-DefenderDiagProp -Object $p -Name 'Count'
        [double] $count = 0
        if ($null -ne $cnt) { try { $count = [double]$cnt } catch { $count = 0 } }
        [double] $ms = ConvertTo-DefenderDurationMs -Value $dur
        [double] $avg = 0
        if ($count -gt 0) { $avg = $ms / $count }
        $rows.Add([PSCustomObject]@{ Path = $path; Count = [int64]$count; TotalMs = $ms; AvgMs = $avg; Percent = 0.0 })
    }
    [double] $total = 0
    foreach ($r in $rows) { $total += $r.TotalMs }
    [object[]] $sorted = @($rows | Sort-Object -Property TotalMs -Descending)
    foreach ($r in $sorted) {
        if ($total -gt 0) { $r.Percent = ($r.TotalMs / $total) * 100 }
    }

    [object[]] $extIn = ConvertTo-DefenderPerfList -Value (Get-DefenderDiagProp -Object $Report -Name 'TopExtensions')
    foreach ($e in $extIn) {
        [string] $name = [string](Get-DefenderDiagProp -Object $e -Name 'Extension')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $dur = Get-DefenderDiagProp -Object $e -Name 'TotalDuration'
        if ($null -eq $dur) { $dur = Get-DefenderDiagProp -Object $e -Name 'Duration' }
        $cnt = Get-DefenderDiagProp -Object $e -Name 'Count'
        [double] $count = 0
        if ($null -ne $cnt) { try { $count = [double]$cnt } catch { $count = 0 } }
        [double] $ms = ConvertTo-DefenderDurationMs -Value $dur
        [double] $avg = 0
        if ($count -gt 0) { $avg = $ms / $count }
        $exts.Add([PSCustomObject]@{ Extension = $name; Count = [int64]$count; TotalMs = $ms; AvgMs = $avg })
    }
    [object[]] $extSorted = @($exts | Sort-Object -Property TotalMs -Descending)
    return [PSCustomObject]@{ Rows = $sorted; Extensions = $extSorted; TotalMs = $total }
}

function Format-DefenderPathsExtLine {
    <#
    .SYNOPSIS
        Una linea con el top de extensiones (archivos y ms promedio): la lectura vendible, el
        costo es por archivo y no por tamano. Cultura invariante. Pura.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [object[]] $Extensions = @(), [Parameter()] [int] $Max = 6)
    if (@($Extensions).Count -eq 0) { return '' }
    [string[]] $parts = @(@($Extensions) | Select-Object -First $Max | ForEach-Object {
        '{0} {1} arch / {2} ms prom' -f $_.Extension, $_.Count, (Format-DefenderNumber -Value ([double]$_.AvgMs) -Decimals 1)
    })
    return ('Extensiones mas caras: ' + ($parts -join ' | '))
}

# --- Lecturas / acciones (shadowables en el smoke) ----------------------------------
function Test-DefenderPathsElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-DefenderPathsCapture {
    <#
    .SYNOPSIS
        Graba $Seconds s en una carpeta propia <TempRoot>\pctk-defrec-<sello>, pide el reporte
        y BORRA esa carpeta (ruta guardada, nunca por patron), tambien si algo tira.
        Devuelve { Ok; Reason; Report }. Nunca lanza.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Seconds,
        [Parameter(Mandatory)] [string] $TempRoot,
        [Parameter()] [int] $TopPaths = 15,
        [Parameter()] [int] $TopPathsDepth = 5,
        [Parameter()] [int] $TopExtensions = 10
    )
    [string] $dir = Join-Path $TempRoot ('pctk-defrec-{0}' -f (Get-PctkStamp -Seconds))
    if (Test-Path -LiteralPath $dir) { $dir = '{0}-{1}' -f $dir, ([guid]::NewGuid().ToString('N').Substring(0, 6)) }
    [string] $etl = Join-Path $dir 'grabacion.etl'
    try {
        $null = New-Item -ItemType Directory -Path $dir -ErrorAction Stop
        New-MpPerformanceRecording -RecordTo $etl -Seconds $Seconds -ErrorAction Stop
        $rep = Get-MpPerformanceReport -Path $etl -TopPaths $TopPaths -TopPathsDepth $TopPathsDepth -TopExtensions $TopExtensions -Raw -ErrorAction Stop
        return [PSCustomObject]@{ Ok = $true; Reason = ''; Report = $rep }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Reason = $_.Exception.Message; Report = $null }
    } finally {
        # SOLO la carpeta creada arriba (ruta en $dir). Nada de globs.
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath $dir)) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DefenderPathsDownloadsDir {
    # Descargas real del usuario: la known folder puede estar redirigida. Solo lectura; nunca lanza.
    try {
        $shell = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $v = Get-DefenderDiagProp -Object $shell -Name '{374DE290-123F-4565-9164-39C4925E467B}'
        if ($null -ne $v) { return [Environment]::ExpandEnvironmentVariables([string]$v) }
    } catch { }
    return ''
}

function Read-DefenderPathsSeconds {
    # Segundos a grabar: Enter = 60, rango 10-300; fuera de rango o no numerico -> se pide UNA vez mas, despues 60.
    [CmdletBinding()]
    [OutputType([int])]
    param()
    for ($try = 1; $try -le 2; $try++) {
        [string] $ans = ([string](Read-Host '  Segundos a grabar (Enter = 60, rango 10-300)')).Trim()
        if ($ans -eq '') { return 60 }
        [int] $n = 0
        if ([int]::TryParse($ans, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge 10 -and $n -le 300) { return $n }
        Write-PctkWarn ('  [!] "{0}" no sirve (10-300).' -f $ans)
    }
    return 60
}

# --- Orquestador (lo llama el handler de [A][19]) ----------------------------------
function Show-DefenderPaths {
    <#
    .SYNOPSIS
        [A][19] [G]rabar rutas caras y ofrecer exclusiones: graba la actividad real, muestra el
        top de carpetas por costo con su numero medido, deja output\defender\rutas_<sello>.txt
        y el audit (Defender.Paths) ANTES de preguntar, y recien ahi ofrece tildar. Aplica solo
        lo tildado Y confirmado (Defender.Exclusions.Measured). Requiere admin para grabar.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $OutputRootOverride = '',
        [Parameter()] [string] $TempRootOverride = '',
        [Parameter()] [int] $TopPaths = 15,
        # Profundidad del agrupado de -TopPathsDepth (segmentos de ruta). 5 deja C:\Users\<u>\Documents\Dev
        # como fila propia; la unidad exacta de la doc se confirma en el gate HW.
        [Parameter()] [int] $TopPathsDepth = 5
    )
    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'output' } else { $OutputRootOverride }
    [string] $tempRoot = if ([string]::IsNullOrEmpty($TempRootOverride)) { $env:TEMP } else { $TempRootOverride }

    Write-PctkSection '  DEFENDER: RUTAS CARAS (grabacion real) + EXCLUSIONES MEDIDAS'

    # 1. Precondiciones: Skipped con motivo, audit Info, sin crash.
    $def = Get-DefenderDiagStatus
    if (-not $def.Available) {
        Write-PctkWarn ('  [!] Skipped: {0}' -f $def.Reason)
        Write-ActionAudit -Action 'Defender.Paths' -Status 'Info' -Summary ('skipped: {0}' -f $def.Reason)
        return
    }
    if (-not (Test-DefenderPathsElevated)) {
        Write-PctkWarn '  [!] Skipped: grabar pide administrador (esta sesion no lo es). No se grabo nada.'
        Write-ActionAudit -Action 'Defender.Paths' -Status 'Info' -Summary 'skipped: grabar pide admin'
        return
    }
    if (-not (Get-Command -Name 'New-MpPerformanceRecording' -ErrorAction SilentlyContinue) -or -not (Get-Command -Name 'Get-MpPerformanceReport' -ErrorAction SilentlyContinue)) {
        Write-PctkWarn '  [!] Skipped: este Defender no trae New-MpPerformanceRecording / Get-MpPerformanceReport (version vieja).'
        Write-ActionAudit -Action 'Defender.Paths' -Status 'Info' -Summary 'skipped: cmdlets de performance ausentes'
        return
    }

    # 2-3. Duracion y actividad real.
    [int] $seconds = Read-DefenderPathsSeconds
    Write-PctkHint '  Reproduci AHORA lo que el cliente siente lento (abrir el proyecto, compilar, lanzar el juego).'
    Write-PctkHint '  Una carga sintetica solo mediria TEMP. No cambia nada de Defender; solo lee.'
    $null = Read-Host '  Enter para empezar a grabar'

    # 4-5. Grabacion + reporte; la carpeta propia se borra adentro.
    Write-PctkWork ('  Grabando {0} s...' -f $seconds)
    $cap = Invoke-DefenderPathsCapture -Seconds $seconds -TempRoot $tempRoot -TopPaths $TopPaths -TopPathsDepth $TopPathsDepth
    if (-not $cap.Ok) {
        Write-PctkWarn ('  [!] La grabacion fallo: {0}' -f $cap.Reason)
        Write-ActionAudit -Action 'Defender.Paths' -Status 'Failed' -Summary $cap.Reason
        return
    }
    $parsed = ConvertFrom-DefenderPerfReport -Report $cap.Report
    # Aplanado el arbol puede haber mas hojas que $TopPaths: la tabla muestra las $TopPaths mas caras.
    [int] $measured = @($parsed.Rows).Count
    [object[]] $rows0 = @($parsed.Rows | Select-Object -First $TopPaths)
    if ($rows0.Count -eq 0) {
        Write-PctkWarn '  [!] La grabacion no registro escaneos por carpeta. Reproduci actividad real y repeti.'
        Write-ActionAudit -Action 'Defender.Paths' -Status 'Info' -Summary 'grabacion sin filas de TopPaths'
        return
    }

    # 6-7. Filas + se ofrece / por que.
    $exObj = Get-CustomDefenderExclusions
    [string[]] $excluded = @()
    if ($null -ne $exObj -and $exObj.Available) { $excluded = @($exObj.Paths) }
    [string] $winDir = [string]$env:windir
    [string[]] $tempDirs = @($env:TEMP)
    if ($winDir -ne '') { $tempDirs += (Join-Path $winDir 'Temp') }
    [string] $downloads = Get-DefenderPathsDownloadsDir
    [System.Collections.Generic.List[object]] $offer = [System.Collections.Generic.List[object]]::new()
    [int] $n = 0
    foreach ($r in $rows0) {
        $n++
        $verdict = Test-DefenderPathOfferable -Path $r.Path -WindowsDir $winDir -ProgramFilesDir @($env:ProgramFiles, ${env:ProgramFiles(x86)}) `
            -UserProfile $env:USERPROFILE -TempDir $tempDirs -DownloadsDir @($downloads) -ExcludedPath $excluded
        $offer.Add([PSCustomObject]@{ Index = $n; Path = $r.Path; Count = $r.Count; TotalMs = $r.TotalMs; AvgMs = $r.AvgMs; Percent = $r.Percent; Offerable = [bool]$verdict.Offerable; Reason = [string]$verdict.Reason })
    }

    [System.Collections.Generic.List[object]] $out = [System.Collections.Generic.List[object]]::new()
    $out.Add([PSCustomObject]@{ Kind = 'section'; Text = 'PCTk - Rutas caras de Defender' })
    $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ('Equipo: {0}   Fecha: {1}   Grabado: {2} s' -f $env:COMPUTERNAME, (Get-PctkStamp), $seconds) })
    $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ('El % es del costo de escaneo grabado en {0} s (suma de las {1} carpetas medidas).' -f $seconds, $measured) })
    foreach ($o in $offer) {
        [string] $line = '[{0}] {1} | {2} % | {3} archivos | {4} ms prom/archivo' -f $o.Index, $o.Path,
            (Format-DefenderNumber -Value ([double]$o.Percent) -Decimals 1), $o.Count, (Format-DefenderNumber -Value ([double]$o.AvgMs) -Decimals 1)
        if ($o.Offerable) {
            $out.Add([PSCustomObject]@{ Kind = 'value'; Text = $line })
        } else {
            $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ($line + '  -> NO se ofrece: ' + $o.Reason) })
        }
    }
    [string] $extLine = Format-DefenderPathsExtLine -Extensions @($parsed.Extensions)
    if ($extLine -ne '') { $out.Add([PSCustomObject]@{ Kind = 'ok'; Text = $extLine }) }
    $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = 'El costo es por archivo (~10 ms c/u), no por tamano: una carpeta con miles de archivos chicos pesa mas que un video grande.' })
    [string[]] $whyReasons = @($offer | Where-Object { -not $_.Offerable } | ForEach-Object { $_.Reason } | Select-Object -Unique)
    foreach ($w in $whyReasons) { $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ('  {0}: {1}' -f $w, (Get-DefenderPathsReasonText -Reason $w)) }) }

    foreach ($o in $out) {
        switch ($o.Kind) {
            'section' { Write-PctkSection ('  {0}' -f $o.Text) }
            'ok'      { Write-PctkOk ('  {0}' -f $o.Text) }
            'hint'    { Write-PctkHint ('  {0}' -f $o.Text) }
            default   { Write-PctkValue ('  {0}' -f $o.Text) }
        }
    }

    # 8. Evidencia ANTES de preguntar: .txt (UTF-8 con BOM) + audit.
    [string] $txtPath = ''
    try {
        [string] $dir = Join-Path $outputRoot 'defender'
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $txtPath = Join-Path $dir ('rutas_{0}.txt' -f (Get-PctkStamp))
        [System.IO.File]::WriteAllLines($txtPath, [string[]]@($out | ForEach-Object { $_.Text }), (New-Object System.Text.UTF8Encoding($true)))
        Write-PctkHint ('  Guardado en {0}' -f $txtPath)
    } catch {
        $txtPath = ''
        Write-PctkWarn ('  [!] No se pudo guardar el .txt: {0}' -f $_.Exception.Message)
    }
    $evidence = [PSCustomObject]@{
        Seconds = $seconds
        TxtPath = $txtPath
        Top     = @($offer | ForEach-Object { [PSCustomObject]@{ Path = $_.Path; Percent = [math]::Round([double]$_.Percent, 1); Files = $_.Count; AvgMs = [math]::Round([double]$_.AvgMs, 1); Offerable = $_.Offerable; Reason = $_.Reason } })
    }
    Write-ActionAudit -Action 'Defender.Paths' -Status 'Success' -Summary ('top {0} rutas en {1} s; primera: {2}' -f $offer.Count, $seconds, $offer[0].Path) -Details $evidence

    # 9. Seleccion.
    [string] $sel = ([string](Read-Host '  Numeros a excluir separados por coma (Enter = ninguno)')).Trim()
    [System.Collections.Generic.List[object]] $chosen = [System.Collections.Generic.List[object]]::new()
    if ($sel -ne '') {
        foreach ($tok in @($sel -split '[,\s]+' | Where-Object { $_ -ne '' })) {
            [int] $num = 0
            if (-not [int]::TryParse($tok, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
                Write-PctkWarn ('  [!] Numero "{0}": no es un numero. No se aplica.' -f $tok); continue
            }
            if ($num -lt 1 -or $num -gt $offer.Count) {
                Write-PctkWarn ('  [!] Numero {0}: no existe en la tabla. No se aplica.' -f $num); continue
            }
            $row = $offer[$num - 1]
            if (-not $row.Offerable) {
                Write-PctkWarn ('  [!] Numero {0}: no se ofrece ({1}). No se aplica.' -f $num, $row.Reason); continue
            }
            if (@($chosen | Where-Object { $_.Index -eq $num }).Count -eq 0) { $chosen.Add($row) }
        }
    }
    if ($chosen.Count -eq 0) {
        Write-PctkHint '  Nada para excluir.'
        Write-ActionAudit -Action 'Defender.Exclusions.Measured' -Status 'Cancelled' -Summary 'sin seleccion valida'
        return
    }

    # 10. Confirmacion (default NO) con el % medido y el undo literal.
    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $chosen) {
        $lines.Add(("{0}: {1} % del costo medido en {2} s | undo: Remove-MpPreference -ExclusionPath '{0}'" -f $c.Path, (Format-DefenderNumber -Value ([double]$c.Percent) -Decimals 1), $seconds))
    }
    $lines.Add('Proteccion en tiempo real y Tamper Protection siguen ON.')
    if (-not (Confirm-Action -Title 'Excluir de Defender estas rutas?' -Lines $lines.ToArray() -DefaultYes:$false)) {
        Write-PctkHint '  Cancelado. No se aplico nada.'
        Write-ActionAudit -Action 'Defender.Exclusions.Measured' -Status 'Cancelled' -Summary 'confirmacion negada'
        return
    }

    # 11. Aplicar con la pieza existente (Privacy.ps1).
    $res = Add-CustomDefenderExclusion -Path @($chosen | ForEach-Object { $_.Path })
    if ($res.Skipped) {
        Write-PctkWarn ('  [!] {0}' -f $res.Reason)
        Write-ActionAudit -Action 'Defender.Exclusions.Measured' -Status 'Info' -Summary ('skipped: {0}' -f $res.Reason)
        return
    }
    [string[]] $applied = @($res.Applied)
    [string[]] $errs = @($res.Errors)
    foreach ($a in $applied) { Write-PctkOk ('  [OK] {0}' -f $a) }
    foreach ($e in $errs) { Write-PctkWarn ('  [!] {0}' -f $e) }
    [System.Collections.Generic.List[object]] $detail = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $chosen) {
        [string] $result = 'aplicada'
        if ($applied -notcontains ('Path: {0}' -f $c.Path)) {
            [string[]] $mine = @($errs | Where-Object { $_.StartsWith(('Path {0} :' -f $c.Path)) })
            $result = if ($mine.Count -gt 0) { $mine[0] } else { 'sin resultado' }
        }
        $detail.Add([PSCustomObject]@{
            Path = $c.Path; Percent = [math]::Round([double]$c.Percent, 1); Seconds = $seconds; Result = $result
            Undo = ("Remove-MpPreference -ExclusionPath '{0}'" -f $c.Path)
        })
    }
    [string] $status = 'Success'
    if ($errs.Count -gt 0) { $status = $(if ($applied.Count -gt 0) { 'Partial' } else { 'Failed' }) }
    Write-ActionAudit -Action 'Defender.Exclusions.Measured' -Status $status -Summary ('{0} aplicadas, {1} con error' -f $applied.Count, $errs.Count) -Details ([PSCustomObject]@{ Seconds = $seconds; Paths = $detail.ToArray() })
}
