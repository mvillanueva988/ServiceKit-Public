Set-StrictMode -Version Latest

# =============================================================================
# MedicionFps.ps1 - #90 (4): kit de medicion de FPS en CS2 con A/B
# =============================================================================
# La vara para decir "esto mejoro los FPS" con numeros que aguanten:
#   - captura de frametimes con PresentMon (tools\bin, del manifest) sobre cs2.exe
#   - resumen: FPS promedio, 1 % low, p99 de frametime, frames
#   - comparador A/B intercalado (base . variante . base) con umbral de ruido
#
# DEFINICIONES (unicas, se usan igual en todo el kit; son las del metodo medido
# en el bench de Minecraft, Exo/wiki/compu-vault/minecraft/scripts/mc-analizar.py):
#   FPS promedio  = 1000 / promedio(frametime ms)        (= frames / tiempo total)
#   p99 frametime = percentil 99 por rango cercano: ordenado[min(n-1, floor(n*0.99))]
#   1 % low       = 1000 / p99 frametime   (el FPS equivalente al percentil 99 del
#                   frametime; NO el promedio del 1 % de frames mas lentos)
#   valor de un lote = MEDIANA de sus pasadas validas
#   deriva base-base = |base2 - base1| / promedio(base1, base2) * 100
#   delta variante   = (variante - promedio(base1, base2)) / promedio(base1, base2) * 100
#
# Por que el umbral default es 10 %: en la PC de Mateo la deriva entre lotes con la
# MISMA config dio ~+-10 % (#79). Un efecto menor que eso no prueba nada.
#
# NUNCA corre sola: solo la dispara el operador desde [F] (o el gate HW). No se
# engancha al pipeline del [1]. No modifica el sistema: solo lee frames por ETW
# (PresentMon) y escribe en output\medicion-fps\.
#
# Costo cero al importar: este archivo solo define funciones. El Add-Type de
# SetThreadExecutionState corre recien al capturar.
# =============================================================================

# Columnas de frametime de PresentMon, en orden de preferencia:
#   FrameTime              -> 2.x con --v2_metrics (lo que usa este kit)
#   MsBetweenPresents      -> 1.x, --v1_metrics y el default de 2.6
#   MsBetweenDisplayChange -> ultimo recurso: solo frames mostrados (0 = no mostrado)
function Get-FpsFrametimeColumn {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Header)

    foreach ($c in @('FrameTime', 'MsBetweenPresents', 'MsBetweenDisplayChange')) {
        if ($Header -contains $c) { return $c }
    }
    return ''
}

function Read-PresentMonFrametimes {
    <#
    .SYNOPSIS
        CSV de PresentMon -> frametimes (ms) de la swapchain dominante.
    .DESCRIPTION
        Parser manual (no Import-Csv): una captura de minutos a 300+ fps son
        decenas de miles de filas. PresentMon escribe numeros con punto decimal
        (printf en locale C), asi que se parsea con InvariantCulture: con es-AR
        (coma decimal) la cultura actual leeria mal "10.4".
        Si hay mas de una swapchain (overlay, ventana secundaria), se queda con la
        que mas frames tiene: mezclarlas duplica frames y parte los frametimes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('No existe el CSV: {0}' -f $Path) }
    [string[]] $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -lt 1) { throw ('CSV vacio: {0}' -f $Path) }

    [string[]] $header = @($lines[0].Split(',') | ForEach-Object { $_.Trim() })
    [string] $col = Get-FpsFrametimeColumn -Header $header
    if ($col -eq '') {
        throw ('El CSV no tiene una columna de frametime conocida (FrameTime / MsBetweenPresents / MsBetweenDisplayChange). Columnas: {0}' -f ($header -join ', '))
    }
    [int] $ci = [Array]::IndexOf($header, $col)
    [int] $si = [Array]::IndexOf($header, 'SwapChainAddress')

    $inv    = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.NumberStyles]::Float
    $bySc   = @{}
    [int] $skipped = 0
    for ([int] $i = 1; $i -lt $lines.Count; $i++) {
        [string] $ln = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        [string[]] $f = $ln.Split(',')
        if ($f.Count -ne $header.Count) { $skipped++; continue }
        [double] $v = 0
        if (-not [double]::TryParse($f[$ci].Trim(), $styles, $inv, [ref] $v) -or $v -le 0) { $skipped++; continue }
        [string] $sc = if ($si -ge 0) { $f[$si].Trim() } else { '' }
        if (-not $bySc.ContainsKey($sc)) { $bySc[$sc] = [System.Collections.Generic.List[double]]::new() }
        $bySc[$sc].Add($v)
    }

    [double[]] $best = @()
    foreach ($k in @($bySc.Keys)) {
        if ($bySc[$k].Count -gt $best.Count) { $best = $bySc[$k].ToArray() }
    }
    return [PSCustomObject]@{
        Column       = $col
        FrameTimesMs = $best
        Skipped      = $skipped
        SwapChains   = $bySc.Count
    }
}

function Get-FpsSummary {
    <#
    .SYNOPSIS
        Frametimes (ms) -> FPS promedio, 1 % low, p99, frames. Pura.
        Definiciones en la cabecera del archivo. Menos de 100 frames = Valid $false
        (el percentil 99 de menos de 100 muestras es el maximo: no es un 1 % low).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [double[]] $FrameTimesMs)

    [int] $n = $FrameTimesMs.Count
    if ($n -eq 0) {
        return [PSCustomObject]@{ Frames = 0; AvgFps = 0.0; Low1Fps = 0.0; P99FrametimeMs = 0.0; DurationS = 0.0; Valid = $false; Reason = 'sin frames (cs2 no presento cuadros durante la captura)' }
    }
    [double] $sum = 0
    foreach ($x in $FrameTimesMs) { $sum += $x }
    [double] $mean = $sum / $n

    [double[]] $sorted = [double[]] $FrameTimesMs.Clone()
    [Array]::Sort($sorted)
    [int] $idx = [math]::Min($n - 1, [int][math]::Floor($n * 0.99))
    [double] $p99 = $sorted[$idx]

    [bool] $valid = $n -ge 100
    [string] $reason = if ($valid) { '' } else { ('solo {0} frames: hacen falta 100 o mas para un 1 % low' -f $n) }
    return [PSCustomObject]@{
        Frames         = $n
        AvgFps         = 1000.0 / $mean
        Low1Fps        = 1000.0 / $p99
        P99FrametimeMs = $p99
        DurationS      = $sum / 1000.0
        Valid          = $valid
        Reason         = $reason
    }
}

function Get-PresentMonCsvSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $r = Read-PresentMonFrametimes -Path $Path
    $s = Get-FpsSummary -FrameTimesMs $r.FrameTimesMs
    $s | Add-Member -NotePropertyName 'Column'  -NotePropertyValue $r.Column
    $s | Add-Member -NotePropertyName 'Skipped' -NotePropertyValue $r.Skipped
    $s | Add-Member -NotePropertyName 'CsvPath' -NotePropertyValue $Path
    return $s
}

function Get-FpsMedian {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [double[]] $Values)

    if ($Values.Count -eq 0) { throw 'mediana de un conjunto vacio' }
    [double[]] $s = [double[]] $Values.Clone()
    [Array]::Sort($s)
    [int] $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$m] }
    return ($s[$m - 1] + $s[$m]) / 2.0
}

function Get-FpsBatchValue {
    # Valor de un lote para una metrica = mediana de sus pasadas.
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Passes,
        [Parameter(Mandatory)] [string] $Metric
    )
    [System.Collections.Generic.List[double]] $v = [System.Collections.Generic.List[double]]::new()
    foreach ($p in @($Passes)) {
        if ($null -eq $p) { continue }
        $prop = $p.PSObject.Properties[$Metric]
        if ($null -eq $prop) { throw ('una pasada no tiene {0}' -f $Metric) }
        $v.Add([double] $prop.Value)
    }
    if ($v.Count -eq 0) { throw 'lote sin pasadas' }
    return (Get-FpsMedian -Values $v.ToArray())
}

function Compare-FpsAB {
    <#
    .SYNOPSIS
        A/B intercalado: lote base 1, lote variante, lote base 2 (en ese orden en
        el tiempo). Veredicto: 'mejora' / 'dentro del ruido' / 'empeora', o
        'medicion no confiable, repetir' si la deriva base-base supera el umbral.
    .DESCRIPTION
        La referencia es el promedio de las dos bases: encierra a la variante y
        cancela la deriva lineal (calor, carga de fondo) entre lotes. Si las dos
        bases difieren mas que el umbral, cualquier delta de la variante queda
        dentro de lo que la PC varia sola, y no se afirma nada.
        Bordes: delta == umbral es ruido; deriva == umbral todavia es confiable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Base1,
        [Parameter(Mandatory)] [object[]] $Variant,
        [Parameter(Mandatory)] [object[]] $Base2,
        [double] $ThresholdPct = 10,
        [ValidateSet('AvgFps', 'Low1Fps')] [string] $Metric = 'AvgFps'
    )

    [double] $b1 = Get-FpsBatchValue -Passes $Base1   -Metric $Metric
    [double] $va = Get-FpsBatchValue -Passes $Variant -Metric $Metric
    [double] $b2 = Get-FpsBatchValue -Passes $Base2   -Metric $Metric
    [double] $ref = ($b1 + $b2) / 2.0
    if ($ref -le 0) { throw 'las bases dieron 0 fps: no hay referencia' }

    [double] $drift = [math]::Abs($b2 - $b1) / $ref * 100.0
    [double] $delta = ($va - $ref) / $ref * 100.0
    [bool] $reliable = $drift -le $ThresholdPct

    [string] $verdict = 'dentro del ruido'
    if (-not $reliable)              { $verdict = 'medicion no confiable, repetir' }
    elseif ($delta -gt $ThresholdPct)  { $verdict = 'mejora' }
    elseif ($delta -lt -$ThresholdPct) { $verdict = 'empeora' }

    return [PSCustomObject]@{
        Verdict      = $verdict
        Metric       = $Metric
        ThresholdPct = $ThresholdPct
        Base1        = $b1
        Variant      = $va
        Base2        = $b2
        BaseRef      = $ref
        DeltaPct     = $delta
        DriftPct     = $drift
        Reliable     = $reliable
    }
}

function Get-FpsBenchGuide {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        '  GUIA: benchmark repetible de CS2 (mapa de Workshop "CS2 FPS Benchmark")'
        ''
        '  1. Antes: suscribirse en el Workshop de Steam al mapa "CS2 FPS Benchmark" (de Angel;'
        '     hay variantes Dust2 y Ancient: usar SIEMPRE la misma). En CS2: Jugar > Mapas de'
        '     Workshop > elegir el mapa y esperar a que termine de cargar.'
        '  2. Settings fijos: misma resolucion, calidad, fps_max, Reflex y modo de pantalla en'
        '     todas las pasadas y en todos los lotes. Lo unico que cambia entre lotes es la'
        '     variante que se esta probando.'
        '  3. Apagar frame generation / NVIDIA Smooth Motion y overlays que dibujan: falsean la'
        '     lectura de frames.'
        '  4. La primera carga compila shaders: hacer una pasada de calentamiento y descartarla.'
        '  5. Cada pasada: [Enter] aca, volver a CS2 durante la espera y arrancar el recorrido'
        '     del benchmark (tecla E en el mapa). La captura arranca sola al terminar la espera'
        '     y tiene que caber entera dentro del recorrido: si el benchmark termina antes,'
        '     bajar los segundos de captura.'
        '  6. Durante la captura no toques nada: ni mouse, ni teclado, ni otras ventanas.'
        '  7. Metodo A/B: lote BASE, lote VARIANTE (el cambio a probar), lote BASE otra vez,'
        '     3 pasadas por lote como minimo. Despues [2] Comparar.'
        '  8. Si las dos bases difieren mas que el umbral, la PC varia sola mas que el cambio'
        '     probado: la medicion no sirve, repetir. Un efecto menor que el umbral no prueba'
        '     nada, para un lado ni para el otro.'
        '  9. Al terminar, el mapa muestra su propio promedio en la consola de CS2: sirve de'
        '     control cruzado con el numero de PresentMon.'
    )
}

function Show-FpsBenchGuide {
    [CmdletBinding()]
    param()
    foreach ($l in @(Get-FpsBenchGuide)) { Write-PctkHint $l }
}

# ─── Bordes con el sistema (cada uno shadowable en los tests) ─────────────────

function Get-FpsOutputRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $OutputRootOverride = '')
    [string] $root = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    } else { $OutputRootOverride }
    return (Join-Path $root 'medicion-fps')
}

function Get-FpsTargetProcess {
    [CmdletBinding()]
    param([string] $Name = 'cs2')
    [object[]] $p = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0 -or $null -eq $p[0]) { return $null }
    return $p[0]
}

function Test-FpsElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PresentMonExePath {
    <#
    .SYNOPSIS
        Ruta del PresentMon del manifest en tools\bin, o '' si no esta bajado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [string] $toolkitRoot = Split-Path -Parent $PSScriptRoot
    [string] $fileName = 'PresentMon.exe'
    [string] $manifest = Join-Path $toolkitRoot 'tools\manifest.json'
    if (Test-Path -LiteralPath $manifest) {
        try {
            $t = @((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).tools | Where-Object { $_.name -eq 'presentmon' }) | Select-Object -First 1
            if ($null -ne $t -and $t.PSObject.Properties['filename'] -and -not [string]::IsNullOrWhiteSpace([string]$t.filename)) { $fileName = [string]$t.filename }
        } catch { }
    }
    [string] $exe = Join-Path $toolkitRoot ('tools\bin\{0}' -f $fileName)
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    return ''
}

function Invoke-PresentMonDownload {
    <#
    .SYNOPSIS
        Baja PresentMon con Bootstrap-Tools.ps1 (version fijada + SHA256 del
        manifest). Devuelve la ruta del exe o ''. Unico cambio que el kit hace en
        la PC: un .exe portable en tools\bin.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [string] $bootstrap = Join-Path (Split-Path -Parent $PSScriptRoot) 'Bootstrap-Tools.ps1'
    if (-not (Test-Path -LiteralPath $bootstrap)) { return '' }
    try { & $bootstrap -ToolName 'presentmon' 2>&1 | Out-Null } catch { return '' }
    return (Get-PresentMonExePath)
}

function Set-FpsKeepAwake {
    <#
    .SYNOPSIS
        Que la pantalla no se apague durante un lote (el recorrido del benchmark
        corre sin input). SetThreadExecutionState, mismo patron que mc-bench.ps1:
        ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED al prender, y
        ES_CONTINUOUS solo al soltar. El Add-Type corre recien aca (costo cero al
        importar el modulo).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool] $On)
    try {
        if (-not ('PctkFps.Energia' -as [type])) {
            Add-Type -Namespace PctkFps -Name Energia -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
        }
        [uint32] $flags = if ($On) { [uint32] 2147483651 } else { [uint32] 2147483648 }
        $null = [PctkFps.Energia]::SetThreadExecutionState($flags)
    } catch { }
}

function Invoke-PresentMonCapture {
    <#
    .SYNOPSIS
        Una captura: PresentMon sobre el proceso, espera -DelaySeconds y graba
        -Seconds. Devuelve { Success, CsvPath, ExitCode, Error }.
    .DESCRIPTION
        Patron del ayudante medido (mc-ayudante.ps1):
        - antes de arrancar se corta una sesion ETW colgada con el mismo nombre
          (--terminate_existing_session): si quedo una, PresentMon no arranca;
        - el corte ordenado es por sesion, no matando el proceso (matarlo puede
          perder el final del CSV). Stop-Process solo si no cierra en 60 s.
        PresentMon se lanza ANTES de que el tecnico vuelva a CS2 y la espera la
        hace el propio PresentMon (--delay; el --timed cuenta desde que empieza a
        grabar, verificado en MainThread.cpp de v2.6.0). Asi ningun proceso nuevo
        aparece mientras CS2 tiene el foco: la leccion del foco del bench de
        Minecraft (una consola elevada que aparece se queda con el foco).
        Start-Process y no '&': el stderr de PresentMon no entra al pipeline (con
        EAP=Stop seria NativeCommandError terminante).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [Parameter(Mandatory)] [string] $OutputCsv,
        [Parameter(Mandatory)] [int]    $Seconds,
        [int]    $DelaySeconds = 10,
        [string] $ProcessName  = 'cs2.exe',
        [string] $SessionName  = 'pctk_fps'
    )

    try {
        $t = Start-Process -FilePath $ExePath -ArgumentList ('--terminate_existing_session --session_name {0}' -f $SessionName) -WindowStyle Hidden -PassThru
        if ($null -ne $t -and -not $t.WaitForExit(15000)) { try { Stop-Process -Id $t.Id -Force -ErrorAction SilentlyContinue } catch { } }
    } catch { }

    $p = $null
    try {
        $p = Start-Process -FilePath $ExePath -ArgumentList ('--process_name {0} --v2_metrics --session_name {1} --output_file "{2}" --delay {3} --timed {4} --terminate_after_timed --no_console_stats' -f $ProcessName, $SessionName, $OutputCsv, $DelaySeconds, $Seconds) -WindowStyle Hidden -PassThru
    } catch {
        return [PSCustomObject]@{ Success = $false; CsvPath = $OutputCsv; ExitCode = -1; Error = ('no se pudo lanzar PresentMon: {0}' -f $_.Exception.Message) }
    }

    [int] $budgetMs = ($DelaySeconds + $Seconds + 30) * 1000
    if (-not $p.WaitForExit($budgetMs)) {
        try {
            $t = Start-Process -FilePath $ExePath -ArgumentList ('--terminate_existing_session --session_name {0}' -f $SessionName) -WindowStyle Hidden -PassThru
            if ($null -ne $t) { $null = $t.WaitForExit(15000) }
        } catch { }
        if (-not $p.WaitForExit(60000)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    }
    [int] $code = -1
    try { $code = [int] $p.ExitCode } catch { }

    if (-not (Test-Path -LiteralPath $OutputCsv -PathType Leaf) -or (Get-Item -LiteralPath $OutputCsv).Length -eq 0) {
        return [PSCustomObject]@{ Success = $false; CsvPath = $OutputCsv; ExitCode = $code; Error = ('PresentMon no genero el CSV (codigo {0}). Consola sin admin, o CS2 no estaba presentando cuadros.' -f $code) }
    }
    return [PSCustomObject]@{ Success = $true; CsvPath = $OutputCsv; ExitCode = $code; Error = '' }
}

# ─── Handlers del operador ────────────────────────────────────────────────────

function Read-FpsNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [double] $Default,
        [double] $Min = 0,
        [double] $Max = [double]::MaxValue
    )
    [string] $raw = [string](Read-Host $Prompt)
    [double] $v = 0
    if ([double]::TryParse($raw.Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $v) -and $v -ge $Min -and $v -le $Max) {
        return $v
    }
    return $Default
}

function ConvertTo-FpsLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)
    [string] $s = ([string]$Text).Trim().ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 32) { $s = $s.Substring(0, 32).Trim('-') }
    if ($s -eq '') { $s = 'lote' }
    return $s
}

function Format-FpsPassLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Summary)
    return ('{0:N1} fps prom | 1 % low {1:N1} fps | p99 {2:N2} ms | {3} frames en {4:N1} s ({5})' -f
        $Summary.AvgFps, $Summary.Low1Fps, $Summary.P99FrametimeMs, $Summary.Frames, $Summary.DurationS, $Summary.Column)
}

function Invoke-FpsCaptureBatch {
    <#
    .SYNOPSIS
        Captura un LOTE (N pasadas con la misma config) y lo guarda en
        output\medicion-fps\<timestamp>_<etiqueta>\ (pasada-N.csv crudo +
        lote.json + resumen.txt). Devuelve el lote o $null si no se pudo.
    #>
    [CmdletBinding()]
    param(
        [string] $Label = '',
        [int]    $Passes = 0,
        [int]    $Seconds = 0,
        [int]    $DelaySeconds = 10,
        [string] $OutputRootOverride = '',
        [switch] $NoPrompt,
        [switch] $AutoDownload
    )

    if ($null -eq (Get-FpsTargetProcess -Name 'cs2')) {
        Write-PctkWarn '  [!] CS2 no esta abierto (no hay cs2.exe corriendo).'
        Write-PctkHint '      Abri CS2, carga el mapa de Workshop "CS2 FPS Benchmark" y volve a esta opcion.'
        Write-ActionAudit -Action 'Fps.Capture' -Status 'Skipped' -Summary 'cs2.exe no esta corriendo'
        return $null
    }
    if (-not (Test-FpsElevated)) {
        Write-PctkErr '  [!] PresentMon necesita consola de administrador (lee frames por ETW).'
        Write-ActionAudit -Action 'Fps.Capture' -Status 'Failed' -Summary 'sin admin'
        return $null
    }
    [string] $exe = Get-PresentMonExePath
    if ($exe -eq '') {
        [bool] $go = [bool] $AutoDownload
        if (-not $go -and -not $NoPrompt) {
            $go = Confirm-Action -Title 'PresentMon no esta en tools\bin. Bajarlo ahora?' -Lines @('Version fijada del manifest, verificada por SHA256 (~1 MB).')
        }
        if ($go) {
            Write-PctkWork '  Bajando PresentMon...'
            $exe = Invoke-PresentMonDownload
        }
        if ($exe -eq '') {
            Write-PctkErr '  [!] PresentMon no disponible. Bajarlo desde [T] Herramientas externas.'
            Write-ActionAudit -Action 'Fps.Capture' -Status 'Failed' -Summary 'PresentMon ausente'
            return $null
        }
    }

    if (-not $NoPrompt) {
        Write-PctkHint '  Lote = N pasadas con la MISMA config. Para A/B: base, variante, base. [3] = guia.'
        if ($Label -eq '')  { $Label = [string](Read-Host '  Etiqueta del lote (ej. base, reflex-on) [lote]') }
        if ($Passes -le 0)  { $Passes = [int](Read-FpsNumber -Prompt '  Pasadas [3]' -Default 3 -Min 1 -Max 10) }
        if ($Seconds -le 0) { $Seconds = [int](Read-FpsNumber -Prompt '  Segundos de captura por pasada [60]' -Default 60 -Min 10 -Max 600) }
    }
    if ($Passes -le 0)  { $Passes = 3 }
    if ($Seconds -le 0) { $Seconds = 60 }
    $Label = ConvertTo-FpsLabel -Text $Label

    [string] $root = Get-FpsOutputRoot -OutputRootOverride $OutputRootOverride
    [string] $base = Join-Path $root ('{0}_{1}' -f (Get-PctkStamp), $Label)   # minutos: la colision se resuelve con -2, -3 (#42)
    [string] $dir  = $base
    [int] $k = 2
    while (Test-Path -LiteralPath $dir) { $dir = '{0}-{1}' -f $base, $k; $k++ }
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    Write-ActionAudit -Action 'Fps.Capture' -Status 'Started' -Summary ('{0}: {1} pasadas x {2} s' -f $Label, $Passes, $Seconds)
    [System.Collections.Generic.List[object]] $done = [System.Collections.Generic.List[object]]::new()
    Set-FpsKeepAwake -On $true
    try {
        for ([int] $i = 1; $i -le $Passes; $i++) {
            if ($null -eq (Get-FpsTargetProcess -Name 'cs2')) {
                Write-PctkWarn ('  [!] CS2 se cerro: el lote queda con {0} pasada(s).' -f $done.Count)
                break
            }
            if (-not $NoPrompt) {
                $null = Read-Host ('  Pasada {0}/{1}: [Enter], volve a CS2 y arranca el recorrido (E). Graba {2} s despues de {3} s' -f $i, $Passes, $Seconds, $DelaySeconds)
            }
            Write-PctkWork ('  Pasada {0}/{1}: espera {2} s + captura {3} s. No toques nada.' -f $i, $Passes, $DelaySeconds, $Seconds)
            [string] $csv = Join-Path $dir ('pasada-{0}.csv' -f $i)
            $cap = Invoke-PresentMonCapture -ExePath $exe -OutputCsv $csv -Seconds $Seconds -DelaySeconds $DelaySeconds
            if (-not $cap.Success) { Write-PctkWarn ('  [!] Pasada {0}: {1}' -f $i, $cap.Error); continue }
            $s = $null
            try { $s = Get-PresentMonCsvSummary -Path $csv }
            catch { Write-PctkWarn ('  [!] Pasada {0}: {1}' -f $i, $_.Exception.Message); continue }
            $s | Add-Member -NotePropertyName 'Pass' -NotePropertyValue $i
            $done.Add($s)
            if ($s.Valid) { Write-PctkOk ('  Pasada {0}/{1}: {2}' -f $i, $Passes, (Format-FpsPassLine -Summary $s)) }
            else          { Write-PctkWarn ('  Pasada {0}/{1} NO VALIDA: {2}' -f $i, $Passes, $s.Reason) }
            if ($s.Valid -and $s.DurationS -lt ($Seconds * 0.8)) {
                Write-PctkWarn ('      La captura cubrio {0:N1} s de {1}: el benchmark termino antes o CS2 dejo de dibujar.' -f $s.DurationS, $Seconds)
            }
        }
    }
    finally { Set-FpsKeepAwake -On $false }

    [object[]] $valid = @($done | Where-Object { $_.Valid })
    $lote = [PSCustomObject]@{
        Label        = $Label
        CreatedAt    = (Get-Date).ToString('o')
        Target       = 'cs2.exe'
        Seconds      = $Seconds
        DelaySeconds = $DelaySeconds
        Definition   = '1 % low = 1000 / p99 frametime (rango cercano); valor del lote = mediana de las pasadas validas'
        Passes       = [object[]] $done.ToArray()
        ValidPasses  = $valid.Count
        AvgFps       = 0.0
        Low1Fps      = 0.0
        SpreadPct    = 0.0
        Dir          = $dir
    }
    if ($valid.Count -gt 0) {
        $lote.AvgFps  = Get-FpsBatchValue -Passes $valid -Metric 'AvgFps'
        $lote.Low1Fps = Get-FpsBatchValue -Passes $valid -Metric 'Low1Fps'
        [double[]] $avgs = @($valid | ForEach-Object { [double] $_.AvgFps })
        [double] $mx = ($avgs | Measure-Object -Maximum).Maximum
        [double] $mn = ($avgs | Measure-Object -Minimum).Minimum
        if ($lote.AvgFps -gt 0) { $lote.SpreadPct = ($mx - $mn) / $lote.AvgFps * 100.0 }
    }
    $lote | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'lote.json') -Encoding UTF8

    [string] $line = ('Lote "{0}": {1}/{2} pasadas validas | FPS prom (mediana) {3:N1} | 1 % low {4:N1} | dispersion entre pasadas {5:N1} %' -f
        $Label, $valid.Count, $Passes, $lote.AvgFps, $lote.Low1Fps, $lote.SpreadPct)
    [string[]] $txt = @($line) + @($done | ForEach-Object { ('  pasada {0}: {1}' -f $_.Pass, $(if ($_.Valid) { Format-FpsPassLine -Summary $_ } else { 'no valida: ' + $_.Reason })) })
    $txt | Set-Content -LiteralPath (Join-Path $dir 'resumen.txt') -Encoding UTF8

    Write-Host ''
    if ($valid.Count -gt 0) { Write-PctkOk ('  ' + $line) } else { Write-PctkWarn ('  ' + $line) }
    if ($lote.SpreadPct -gt 10) { Write-PctkWarn '  [!] Las pasadas de este lote se dispersan mas de 10 %: un A/B con este lote va a ser ruidoso.' }
    Write-PctkHint ('       {0}' -f $dir)
    Write-ActionAudit -Action 'Fps.Capture' -Status $(if ($valid.Count -gt 0) { 'Success' } else { 'Failed' }) -Summary $line
    return $lote
}

function Get-FpsBatches {
    [CmdletBinding()]
    param([string] $OutputRootOverride = '')
    [string] $root = Get-FpsOutputRoot -OutputRootOverride $OutputRootOverride
    [System.Collections.Generic.List[object]] $out = [System.Collections.Generic.List[object]]::new()
    # Devuelve los lotes ENUMERADOS (sin la coma): el caller envuelve en @() para
    # 0/1/N. Con 'return , $x' + '@()' del caller el array queda anidado (1 elemento).
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        [string] $j = Join-Path $d.FullName 'lote.json'
        if (-not (Test-Path -LiteralPath $j -PathType Leaf)) { continue }
        try {
            $o = Get-Content -LiteralPath $j -Raw | ConvertFrom-Json
            $o | Add-Member -NotePropertyName 'DirName' -NotePropertyValue $d.Name -Force
            $out.Add($o)
        } catch { }
    }
    return @($out | Sort-Object -Property @{ Expression = { [string] $_.CreatedAt } }, DirName)
}

function Invoke-FpsCompareMenu {
    <#
    .SYNOPSIS
        Elige 3 lotes guardados (base 1, variante, base 2), corre Compare-FpsAB
        para FPS promedio y 1 % low, lo muestra y lo guarda en
        output\medicion-fps\comparacion-<timestamp>.txt.
    #>
    [CmdletBinding()]
    param([string] $OutputRootOverride = '')

    [object[]] $lotes = @(Get-FpsBatches -OutputRootOverride $OutputRootOverride)
    if ($lotes.Count -lt 3) {
        Write-PctkWarn ('  [!] Hay {0} lote(s) guardado(s). El A/B necesita 3: base, variante, base (en ese orden).' -f $lotes.Count)
        return $null
    }
    Write-PctkSection '  LOTES GUARDADOS (del mas viejo al mas nuevo)'
    for ([int] $i = 0; $i -lt $lotes.Count; $i++) {
        $l = $lotes[$i]
        Write-PctkValue ('  [{0,2}] {1,-40} {2:N1} fps | 1 % low {3:N1} | {4} pasadas validas' -f ($i + 1), $l.DirName, [double]$l.AvgFps, [double]$l.Low1Fps, [int]$l.ValidPasses)
    }
    [int] $n = $lotes.Count
    [int] $i1 = [int](Read-FpsNumber -Prompt ('  Lote BASE 1 [{0}]' -f ($n - 2)) -Default ($n - 2) -Min 1 -Max $n)
    [int] $iv = [int](Read-FpsNumber -Prompt ('  Lote VARIANTE [{0}]' -f ($n - 1)) -Default ($n - 1) -Min 1 -Max $n)
    [int] $i2 = [int](Read-FpsNumber -Prompt ('  Lote BASE 2 [{0}]' -f $n) -Default $n -Min 1 -Max $n)
    [double] $thr = Read-FpsNumber -Prompt '  Umbral de ruido en % [10]' -Default 10 -Min 0.1 -Max 100

    $l1 = $lotes[$i1 - 1]; $lv = $lotes[$iv - 1]; $l2 = $lotes[$i2 - 1]
    [object[]] $p1 = @(@($l1.Passes) | Where-Object { $null -ne $_ -and $_.Valid })
    [object[]] $pv = @(@($lv.Passes) | Where-Object { $null -ne $_ -and $_.Valid })
    [object[]] $p2 = @(@($l2.Passes) | Where-Object { $null -ne $_ -and $_.Valid })
    if ($p1.Count -eq 0 -or $pv.Count -eq 0 -or $p2.Count -eq 0) {
        Write-PctkWarn '  [!] Alguno de los lotes elegidos no tiene pasadas validas.'
        return $null
    }

    $rAvg = Compare-FpsAB -Base1 $p1 -Variant $pv -Base2 $p2 -ThresholdPct $thr -Metric 'AvgFps'
    $rLow = Compare-FpsAB -Base1 $p1 -Variant $pv -Base2 $p2 -ThresholdPct $thr -Metric 'Low1Fps'

    [string[]] $lines = @(
        ('Comparacion A/B - {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
        ('Base 1   : {0}  ({1} pasadas)' -f $l1.DirName, $p1.Count)
        ('Variante : {0}  ({1} pasadas)' -f $lv.DirName, $pv.Count)
        ('Base 2   : {0}  ({1} pasadas)' -f $l2.DirName, $p2.Count)
        ('Umbral   : {0:N1} %' -f $thr)
        ''
        ('FPS promedio : base1 {0:N1} | variante {1:N1} | base2 {2:N1} | deriva base-base {3:N1} % | delta {4:+0.0;-0.0;0.0} % -> {5}' -f $rAvg.Base1, $rAvg.Variant, $rAvg.Base2, $rAvg.DriftPct, $rAvg.DeltaPct, $rAvg.Verdict)
        ('1 % low      : base1 {0:N1} | variante {1:N1} | base2 {2:N1} | deriva base-base {3:N1} % | delta {4:+0.0;-0.0;0.0} % -> {5}' -f $rLow.Base1, $rLow.Variant, $rLow.Base2, $rLow.DriftPct, $rLow.DeltaPct, $rLow.Verdict)
        ''
        'Definiciones: valor del lote = mediana de sus pasadas; 1 % low = 1000 / p99 frametime;'
        'referencia = promedio de las dos bases; deriva base-base > umbral = medicion no confiable.'
    )
    Write-Host ''
    foreach ($ln in $lines) {
        if ($ln -match '-> (mejora)$') { Write-PctkOk ('  ' + $ln) }
        elseif ($ln -match '-> (empeora|medicion no confiable, repetir)$') { Write-PctkWarn ('  ' + $ln) }
        else { Write-PctkValue ('  ' + $ln) }
    }
    [string] $root = Get-FpsOutputRoot -OutputRootOverride $OutputRootOverride
    [string] $cmpStamp = Get-PctkStamp -Seconds
    [string] $file = Join-Path $root ('comparacion-{0}.txt' -f $cmpStamp)
    [int] $cmpN = 2
    while (Test-Path -LiteralPath $file) { $file = Join-Path $root ('comparacion-{0}-{1}.txt' -f $cmpStamp, $cmpN); $cmpN++ }
    $lines | Set-Content -LiteralPath $file -Encoding UTF8
    Write-PctkHint ('       {0}' -f $file)
    Write-ActionAudit -Action 'Fps.Compare' -Status 'Success' -Summary ('avg {0} / 1% low {1}' -f $rAvg.Verdict, $rLow.Verdict)
    return [PSCustomObject]@{ Avg = $rAvg; Low = $rLow; File = $file }
}

function Get-FpsMenuRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    [object[]] $rows = @()
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  MEDICION DE FPS (CS2 + PresentMon, A/B base-variante-base)'; Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '1';   Label = '  [1]  Capturar un lote                  (N pasadas con la misma config)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '2';   Label = '  [2]  Comparar A/B                      (base, variante, base)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '3';   Label = '  [3]  Guia del benchmark'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'B';   Label = '  [B]  Volver al menu principal'; Color = 'DarkYellow' }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    return $rows
}

function Invoke-FpsMeasurement {
    <#
    .SYNOPSIS
        Entrada del operador: menu principal [F]. Submenu de captura / A/B / guia.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile,
        [string] $OutputRootOverride = ''
    )
    $null = $MachineProfile
    [object[]] $rows = Get-FpsMenuRows
    [scriptblock] $hdr = { Clear-Host; Write-Host '' }
    do {
        [string] $choice = [string](Read-PctkMenuChoice -Rows $rows -RenderHeader $hdr)
        if ([string]::IsNullOrEmpty($choice)) { continue }
        [string] $up = $choice.ToUpperInvariant()
        if ($up -eq 'B') { return }
        try {
            switch ($up) {
                '1' { $null = Invoke-FpsCaptureBatch -OutputRootOverride $OutputRootOverride }
                '2' { $null = Invoke-FpsCompareMenu -OutputRootOverride $OutputRootOverride }
                '3' { Show-FpsBenchGuide }
                default { Write-PctkErr '  Opcion invalida.' }
            }
        }
        catch {
            if (Get-Command -Name 'Write-DispatchCrash' -CommandType Function -ErrorAction SilentlyContinue) {
                Write-DispatchCrash -ErrorRecord $_ -Choice $choice -MenuLabel 'submenu [F]'
            } else { Write-PctkErr ('  [!] {0}' -f $_.Exception.Message) }
        }
        Write-Host ''
        $null = Read-Host '  [Enter] para continuar'
    }
    while ($true)
}

function Invoke-FpsGate {
    <#
    .SYNOPSIS
        Gate HW (#90 (4)): con CS2 abierto en el mapa de benchmark, 3 capturas
        seguidas sin preguntar nada y PASS/FAIL + resumen a
        output\medicion-fps\gate-<timestamp>.txt. Lo corre tests\fps-gate.ps1.
    .DESCRIPTION
        PASS = las 3 pasadas validas (>= 100 frames, columna reconocida) y cada una
        cubre entre 80 % y 120 % de los segundos pedidos (eso valida tambien que
        --delay/--timed hacen lo que el kit asume). La deriva entre pasadas se
        informa (repetibilidad) pero no decide el PASS: es dato de la PC, no del kit.
    #>
    [CmdletBinding()]
    param(
        [int]    $Seconds = 30,
        [int]    $DelaySeconds = 5,
        [string] $OutputRootOverride = ''
    )
    [string] $root = Get-FpsOutputRoot -OutputRootOverride $OutputRootOverride
    if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    [string] $report = Join-Path $root ('gate-{0}.txt' -f (Get-PctkStamp))
    [System.Collections.Generic.List[string]] $fails = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $body  = [System.Collections.Generic.List[string]]::new()
    $lote = $null

    if ($null -eq (Get-FpsTargetProcess -Name 'cs2')) {
        $fails.Add('CS2 no esta abierto: abri CS2 en el mapa "CS2 FPS Benchmark" y volve a correr el gate.')
    } elseif (-not (Test-FpsElevated)) {
        $fails.Add('hace falta una consola de ADMINISTRADOR (PresentMon lee frames por ETW).')
    } else {
        $lote = Invoke-FpsCaptureBatch -Label 'gate' -Passes 3 -Seconds $Seconds -DelaySeconds $DelaySeconds -OutputRootOverride $OutputRootOverride -NoPrompt -AutoDownload
        if ($null -eq $lote) {
            $fails.Add('no se pudo capturar (PresentMon ausente o CS2 se cerro).')
        } else {
            [object[]] $ps = @($lote.Passes)
            if ($ps.Count -ne 3) { $fails.Add(('se esperaban 3 pasadas; salieron {0}' -f $ps.Count)) }
            foreach ($p in $ps) {
                $body.Add(('pasada {0}: {1}' -f $p.Pass, $(if ($p.Valid) { Format-FpsPassLine -Summary $p } else { 'NO VALIDA: ' + $p.Reason })))
                if (-not $p.Valid) { $fails.Add(('pasada {0} no valida: {1}' -f $p.Pass, $p.Reason)); continue }
                if ($p.DurationS -lt ($Seconds * 0.8) -or $p.DurationS -gt ($Seconds * 1.2 + 0.5)) {
                    $fails.Add(('pasada {0}: cubrio {1:N1} s de {2} pedidos (fuera de 80-120 %)' -f $p.Pass, $p.DurationS, $Seconds))
                }
            }
            [object[]] $okp = @($ps | Where-Object { $_.Valid })
            if ($okp.Count -eq 3) {
                $r = Compare-FpsAB -Base1 $okp[0] -Variant $okp[1] -Base2 $okp[2]
                $body.Add(('repetibilidad (misma config, pasada 1 vs 3): deriva {0:N1} %; pasada 2 vs referencia {1:+0.0;-0.0;0.0} % -> {2}' -f $r.DriftPct, $r.DeltaPct, $r.Verdict))
            }
            $body.Add(('CSV crudos: {0}' -f $lote.Dir))
        }
    }

    [bool] $pass = $fails.Count -eq 0
    [System.Collections.Generic.List[string]] $out = [System.Collections.Generic.List[string]]::new()
    $out.Add(('PCTk gate #90 (4) medicion de FPS - {0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME))
    $out.Add(('RESULTADO: {0}' -f $(if ($pass) { 'PASS' } else { 'FAIL' })))
    foreach ($f in $fails) { $out.Add(('  FAIL: {0}' -f $f)) }
    foreach ($b in $body)  { $out.Add(('  {0}' -f $b)) }
    $out.ToArray() | Set-Content -LiteralPath $report -Encoding UTF8

    foreach ($l in $out) { if ($pass) { Write-PctkOk ('  ' + $l) } else { Write-PctkWarn ('  ' + $l) } }
    Write-PctkHint ('  Reporte: {0}' -f $report)
    return [PSCustomObject]@{ Pass = $pass; ReportPath = $report; Batch = $lote }
}
