# DefenderDiag.ps1 -- #54 (A): diagnostico de Defender en 4 pasos, SOLO LECTURA.
#
# Le pone un numero a "Defender me hace lenta la PC?":
#   1. Es un scan programado?            (Get-MpComputerStatus + event log 1000/1002)
#   2. Ratio user/kernel de MsMpEng      (Win32_Process: UserModeTime / KernelModeTime)
#   3. Causalidad contra baseline        (CPU de MsMpEng: idle / carga de archivos / carga de scripts)
#   4. CPU acumulada contra uptime       (el numero que se le muestra al cliente)
#
# Reglas: no cambia NADA de Defender (ni exclusiones, ni Tamper Protection). Lo unico que
# escribe es su carpeta de TEMP (borrada al final, SOLO esa) y el .txt/audit que arma el
# caller. Sin admin: lo que de acceso denegado o nulo reporta Skipped y los demas pasos siguen.
# Defender no disponible (AV de terceros) -> todo Skipped, sin crash.
#
# NO usa Get-Counter: los nombres de contadores estan traducidos en un Windows en espanol.
# La CPU se mide por delta de UserModeTime+KernelModeTime de Win32_Process.
#
# ASCII puro a proposito (sin BOM): no mezclar non-ASCII aca sin re-aplicar el BOM.

# --- Calculo puro ---------------------------------------------------------------
function Get-DefenderCpuShare {
    <#
    .SYNOPSIS
        % del CPU entero que representa un tiempo de CPU: cpu / (pared * cores) * 100.
        Pura: sin I/O, para poder probarla con numeros fijos.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $CpuSeconds,
        [Parameter(Mandatory)] [double] $WallSeconds,
        [Parameter(Mandatory)] [int]    $Cores
    )
    if ($WallSeconds -le 0 -or $Cores -lt 1) { return [double]0 }
    return [double](($CpuSeconds / ($WallSeconds * $Cores)) * 100)
}

function Format-DefenderNumber {
    <#
    .SYNOPSIS
        Numero a texto con cultura INVARIANTE (punto decimal siempre). < 1 lleva
        3 decimales (0.094), >= 1 lleva 1 (1.5).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $Value,
        [Parameter()] [int] $Decimals = -1
    )
    [string] $fmt = if ($Decimals -ge 0) { '0.' + ('0' * $Decimals) } elseif ([math]::Abs($Value) -lt 1) { '0.000' } else { '0.0' }
    if ($Decimals -eq 0) { $fmt = '0' }
    return $Value.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DefenderDiagUptimeLine {
    <#
    .SYNOPSIS
        Paso 4: "X min de CPU en Y h de uptime = Z % del CPU entero (N cores logicos)".
        Pura. Es el entregable que se le muestra al cliente.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $CpuMinutes,
        [Parameter(Mandatory)] [double] $UptimeHours,
        [Parameter(Mandatory)] [int]    $Cores
    )
    [double] $pct = Get-DefenderCpuShare -CpuSeconds ($CpuMinutes * 60) -WallSeconds ($UptimeHours * 3600) -Cores $Cores
    return ('{0} min de CPU en {1} h de uptime = {2} % del CPU entero ({3} cores logicos)' -f
        (Format-DefenderNumber -Value $CpuMinutes -Decimals 1),
        (Format-DefenderNumber -Value $UptimeHours -Decimals 1),
        (Format-DefenderNumber -Value $pct),
        $Cores)
}

function Get-DefenderUserKernelReading {
    <#
    .SYNOPSIS
        Paso 2: lectura del ratio user/kernel. user-heavy = analiza contenido en
        memoria (CPU alta con disco quieto); kernel-heavy = I/O real. Pura.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double] $UserMinutes,
        [Parameter(Mandatory)] [double] $KernelMinutes
    )
    [double] $total = $UserMinutes + $KernelMinutes
    if ($total -le 0) { return 'Sin CPU acumulada todavia: nada que leer.' }
    [double] $userShare = $UserMinutes / $total
    if ($userShare -ge 0.7) {
        return 'user-heavy: analiza contenido en memoria (CPU alta con disco casi quieto). No es "disco lento".'
    }
    if ($userShare -le 0.4) {
        return 'kernel-heavy: pasa su tiempo en I/O real (lectura de archivos).'
    }
    return 'mixto: ni claramente contenido ni claramente I/O.'
}

function Get-DefenderStopReason {
    <#
    .SYNOPSIS
        Saca el motivo literal de un evento 1002 (scan detenido). El motivo es la
        ultima linea "Etiqueta: valor" del mensaje (localizado: no se busca la
        etiqueta por nombre). Si no hay forma de aislarlo, devuelve el mensaje aplanado.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return '(sin mensaje)' }
    [string[]] $lines = @($Message -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return '(sin mensaje)' }
    [string] $last = $lines[$lines.Count - 1]
    [int] $idx = $last.IndexOf(':')
    if ($idx -ge 0 -and $idx -lt ($last.Length - 1)) { return $last.Substring($idx + 1).Trim() }
    return $last
}

# --- Lecturas (shadowables en el smoke) -------------------------------------------
function Get-DefenderDiagProp {
    # Lectura segura de una propiedad (StrictMode: una ausente tira PropertyNotFoundStrict).
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-DefenderEventReason {
    <#
    .SYNOPSIS
        Motivo literal de un evento 1002. Se prefiere la ULTIMA entrada de Properties
        (el stop reason sin adornos): en la PC de Mateo el Message viene con el formato
        "%x ... %y" pegado y sin saltos de linea (medido 19-10), asi que parsearlo es el
        plan B (Get-DefenderStopReason).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] $EventRecord)
    [object[]] $props = @()
    $pv = Get-DefenderDiagProp -Object $EventRecord -Name 'Properties'
    if ($null -ne $pv) { $props = @($pv) }
    if ($props.Count -ge 2) {
        $last = Get-DefenderDiagProp -Object $props[$props.Count - 1] -Name 'Value'
        if ($last -is [string] -and -not [string]::IsNullOrWhiteSpace($last)) { return $last.Trim() }
    }
    return (Get-DefenderStopReason -Message ([string](Get-DefenderDiagProp -Object $EventRecord -Name 'Message')))
}

function Get-DefenderDiagStatus {
    <#
    .SYNOPSIS
        Defender disponible? Get-MpComputerStatus tira (AV de terceros / politica) o
        AMServiceEnabled en false -> no disponible. Nunca lanza.
    #>
    [CmdletBinding()]
    param()
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Available = $false; Reason = ('Get-MpComputerStatus no disponible (probablemente AV de terceros activo): {0}' -f $_.Exception.Message); Status = $null }
    }
    if ($null -eq $s) {
        return [PSCustomObject]@{ Available = $false; Reason = 'Get-MpComputerStatus no devolvio datos (probablemente AV de terceros activo).'; Status = $null }
    }
    $am = Get-DefenderDiagProp -Object $s -Name 'AMServiceEnabled'
    if ($null -ne $am -and -not [bool]$am) {
        return [PSCustomObject]@{ Available = $false; Reason = 'El servicio de Defender (AMServiceEnabled) esta apagado.'; Status = $s }
    }
    return [PSCustomObject]@{ Available = $true; Reason = ''; Status = $s }
}

function Get-DefenderProcessTimes {
    <#
    .SYNOPSIS
        Tiempos de CPU acumulados de MsMpEng.exe (Win32_Process, unidades de 100 ns).
        Devuelve { Ok; Reason; UserSeconds; KernelSeconds; CreationDate }. Nunca lanza.
    #>
    [CmdletBinding()]
    param()
    try {
        [object[]] $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='MsMpEng.exe'" -ErrorAction Stop)
    } catch {
        return [PSCustomObject]@{ Ok = $false; Reason = ('no se pudo leer Win32_Process: {0}' -f $_.Exception.Message); UserSeconds = 0.0; KernelSeconds = 0.0; CreationDate = $null }
    }
    if ($procs.Count -eq 0 -or $null -eq $procs[0]) {
        return [PSCustomObject]@{ Ok = $false; Reason = 'MsMpEng.exe no esta corriendo (o no es visible sin admin).'; UserSeconds = 0.0; KernelSeconds = 0.0; CreationDate = $null }
    }
    $u = Get-DefenderDiagProp -Object $procs[0] -Name 'UserModeTime'
    $k = Get-DefenderDiagProp -Object $procs[0] -Name 'KernelModeTime'
    if ($null -eq $u -or $null -eq $k) {
        return [PSCustomObject]@{ Ok = $false; Reason = 'MsMpEng no expone UserModeTime/KernelModeTime sin admin (proceso protegido).'; UserSeconds = 0.0; KernelSeconds = 0.0; CreationDate = $null }
    }
    return [PSCustomObject]@{
        Ok            = $true
        Reason        = ''
        UserSeconds   = ([double]$u / 1e7)
        KernelSeconds = ([double]$k / 1e7)
        CreationDate  = (Get-DefenderDiagProp -Object $procs[0] -Name 'CreationDate')
    }
}

# --- Cargas del paso 3 (shadowables: el smoke no genera 1500 archivos) ------------
function Invoke-DefenderDiagFileLoad {
    <#
    .SYNOPSIS
        Carga de archivos: crea N archivos chicos de texto en UNA carpeta propia bajo
        TempRoot (pctk-defdiag-<sello>), los lee, y al terminar borra ESA carpeta
        (ruta guardada en variable; nunca por patron). Devuelve la ruta que uso.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $TempRoot,
        [Parameter()] [int] $Count = 1500
    )
    [string] $dir = Join-Path $TempRoot ('pctk-defdiag-{0}' -f (Get-PctkStamp -Seconds))
    if (Test-Path -LiteralPath $dir) { $dir = '{0}-{1}' -f $dir, ([guid]::NewGuid().ToString('N').Substring(0, 6)) }
    $null = New-Item -ItemType Directory -Path $dir -ErrorAction Stop
    try {
        [string] $body = 'pctk defender diag ' + ('lorem ipsum dolor sit amet ' * 8)
        for ($i = 1; $i -le $Count; $i++) {
            [System.IO.File]::WriteAllText((Join-Path $dir ('f{0:D5}.txt' -f $i)), ('{0} #{1}' -f $body, $i))
            if (($i % 100) -eq 0) { Write-Progress -Id 54 -Activity 'Defender: carga de archivos' -Status ('escribiendo {0}/{1}' -f $i, $Count) -PercentComplete ([int](50 * $i / $Count)) }
        }
        [int] $n = 0
        foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
            $null = [System.IO.File]::ReadAllText($f)
            $n++
            if (($n % 100) -eq 0) { Write-Progress -Id 54 -Activity 'Defender: carga de archivos' -Status ('leyendo {0}/{1}' -f $n, $Count) -PercentComplete ([int](50 + 50 * $n / $Count)) }
        }
    } finally {
        # SOLO la carpeta que se creo arriba (ruta en $dir). Nada de globs.
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath $dir)) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Progress -Id 54 -Activity 'Defender: carga de archivos' -Completed
    }
    return $dir
}

function Invoke-DefenderDiagScriptLoad {
    <#
    .SYNOPSIS
        Carga de scripts: N invocaciones cortas de powershell.exe (dispara AMSI).
        Exe nativo: EAP neutralizado localmente (main.ps1 corre con Stop).
    #>
    [CmdletBinding()]
    param([Parameter()] [int] $Count = 25)
    $ErrorActionPreference = 'Continue'
    for ($i = 1; $i -le $Count; $i++) {
        & powershell.exe -NoProfile -Command 'exit 0' 2>&1 | Out-Null
        Write-Progress -Id 54 -Activity 'Defender: carga de scripts' -Status ('{0}/{1}' -f $i, $Count) -PercentComplete ([int](100 * $i / $Count))
    }
    Write-Progress -Id 54 -Activity 'Defender: carga de scripts' -Completed
}

# --- Medicion de una tanda ----------------------------------------------------------
function Measure-DefenderPhase {
    <#
    .SYNOPSIS
        % de CPU entero que gasta MsMpEng mientras corre $Work: delta de
        (User+Kernel) entre dos lecturas / (tiempo de pared x cores logicos).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Work,
        [Parameter(Mandatory)] [int] $Cores
    )
    $a = Get-DefenderProcessTimes
    if (-not $a.Ok) { return [PSCustomObject]@{ Ok = $false; Reason = $a.Reason; Percent = 0.0; WallSeconds = 0.0 } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Work
    $sw.Stop()
    $b = Get-DefenderProcessTimes
    if (-not $b.Ok) { return [PSCustomObject]@{ Ok = $false; Reason = $b.Reason; Percent = 0.0; WallSeconds = 0.0 } }
    [double] $cpu = ($b.UserSeconds + $b.KernelSeconds) - ($a.UserSeconds + $a.KernelSeconds)
    if ($cpu -lt 0) { $cpu = 0 }   # MsMpEng se reinicio a mitad de la tanda
    [double] $wall = $sw.Elapsed.TotalSeconds
    return [PSCustomObject]@{
        Ok          = $true
        Reason      = ''
        Percent     = (Get-DefenderCpuShare -CpuSeconds $cpu -WallSeconds $wall -Cores $Cores)
        WallSeconds = $wall
    }
}

# --- Pasos --------------------------------------------------------------------------
function New-DefenderDiagStep {
    param([int] $Step, [string] $Name, [string] $Status, [string] $Reason, [string[]] $Lines, $Data)
    return [PSCustomObject]@{ Step = $Step; Name = $Name; Status = $Status; Reason = $Reason; Lines = @($Lines); Data = $Data }
}

function Get-DefenderDiagStep1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $DefStatus, [Parameter()] [int] $Days = 7)
    [string] $name = 'Es un scan programado?'
    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()
    $s = $DefStatus.Status

    foreach ($pair in @(
        @('Ultimo quick scan', 'QuickScanEndTime'),
        @('Ultimo full scan ', 'FullScanEndTime'))) {
        $v = Get-DefenderDiagProp -Object $s -Name $pair[1]
        [string] $txt = 'sin dato'
        if ($v -is [datetime] -and $v.Year -gt 2000) {
            $txt = $v.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $lines.Add(('{0}: {1}' -f $pair[0], $txt))
    }
    $fsa = Get-DefenderDiagProp -Object $s -Name 'FullScanAge'
    if ($null -ne $fsa -and "$fsa" -match '^\d+$' -and [uint32]$fsa -lt 4294967295) { $lines.Add(('Antiguedad del full scan: {0} dias' -f $fsa)) }

    [object[]] $events = @()
    [string] $evNote = ''
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Windows Defender/Operational'
            Id        = 1000, 1002
            StartTime = (Get-Date).AddDays(-$Days)
        } -ErrorAction Stop)
    } catch {
        [string] $fq = [string](Get-DefenderDiagProp -Object $_ -Name 'FullyQualifiedErrorId')
        if ($fq -like 'NoMatchingEventsFound*') {
            $events = @()
        } else {
            $evNote = ('event log no legible ({0})' -f $_.Exception.Message)
        }
    }

    [int] $started = 0
    [System.Collections.Generic.List[object]] $stopped = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $events) {
        [int] $id = [int](Get-DefenderDiagProp -Object $e -Name 'Id')
        if ($id -eq 1000) { $started++ } elseif ($id -eq 1002) { $stopped.Add($e) }
    }
    if ($evNote -ne '') {
        $lines.Add(('Eventos 1000/1002 (ultimos {0} dias): {1}' -f $Days, $evNote))
        return (New-DefenderDiagStep -Step 1 -Name $name -Status 'Ok' -Reason $evNote -Lines $lines -Data ([PSCustomObject]@{ Started = 0; Stopped = 0; EventsReadable = $false }))
    }
    $lines.Add(('Scans iniciados (id 1000, ultimos {0} dias): {1}' -f $Days, $started))
    $lines.Add(('Scans detenidos (id 1002, ultimos {0} dias): {1}' -f $Days, $stopped.Count))
    if ($stopped.Count -gt 0) {
        [object[]] $groups = @($stopped | ForEach-Object { Get-DefenderEventReason -EventRecord $_ } |
            Group-Object | Sort-Object Count -Descending)
        foreach ($g in $groups) { $lines.Add(('  {0}x  motivo: {1}' -f $g.Count, $g.Name)) }
        $lines.Add('=> Hubo scans cortados: mirar el motivo antes de culpar al disco.')
    } else {
        $lines.Add('=> Sin scans cortados en el periodo.')
    }
    return (New-DefenderDiagStep -Step 1 -Name $name -Status 'Ok' -Reason '' -Lines $lines -Data ([PSCustomObject]@{ Started = $started; Stopped = $stopped.Count; EventsReadable = $true }))
}

function Get-DefenderDiagStep2 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Times)
    [string] $name = 'Ratio user/kernel de MsMpEng'
    if (-not $Times.Ok) { return (New-DefenderDiagStep -Step 2 -Name $name -Status 'Skipped' -Reason $Times.Reason -Lines @() -Data $null) }
    [double] $um = $Times.UserSeconds / 60
    [double] $km = $Times.KernelSeconds / 60
    [string[]] $lines = @(
        ('CPU user  : {0} min' -f (Format-DefenderNumber -Value $um -Decimals 1)),
        ('CPU kernel: {0} min' -f (Format-DefenderNumber -Value $km -Decimals 1)),
        ('=> {0}' -f (Get-DefenderUserKernelReading -UserMinutes $um -KernelMinutes $km))
    )
    return (New-DefenderDiagStep -Step 2 -Name $name -Status 'Ok' -Reason '' -Lines $lines -Data ([PSCustomObject]@{ UserMinutes = $um; KernelMinutes = $km }))
}

function Get-DefenderDiagStep3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Cores,
        [Parameter(Mandatory)] [string] $TempRoot,
        [Parameter()] [int] $IdleSeconds = 5
    )
    [string] $name = 'Causalidad contra baseline'
    Write-Progress -Id 54 -Activity 'Defender: baseline (idle)' -Status ('{0} s sin carga' -f $IdleSeconds) -PercentComplete 0
    $idle = Measure-DefenderPhase -Cores $Cores -Work { Start-Sleep -Seconds $IdleSeconds }
    Write-Progress -Id 54 -Activity 'Defender: baseline (idle)' -Completed
    if (-not $idle.Ok) { return (New-DefenderDiagStep -Step 3 -Name $name -Status 'Skipped' -Reason $idle.Reason -Lines @() -Data $null) }

    $files = Measure-DefenderPhase -Cores $Cores -Work {
        $null = Invoke-DefenderDiagFileLoad -TempRoot $TempRoot
        Start-Sleep -Seconds 2   # el scan de lo recien escrito termina un poco despues
    }
    $scripts = Measure-DefenderPhase -Cores $Cores -Work { Invoke-DefenderDiagScriptLoad }
    if (-not $files.Ok -or -not $scripts.Ok) {
        [string] $why = if (-not $files.Ok) { $files.Reason } else { $scripts.Reason }
        return (New-DefenderDiagStep -Step 3 -Name $name -Status 'Skipped' -Reason $why -Lines @() -Data $null)
    }
    [double] $dFiles   = $files.Percent - $idle.Percent
    [double] $dScripts = $scripts.Percent - $idle.Percent
    [string[]] $lines = @(
        ('Idle              : {0} %  (de {1} cores logicos)' -f (Format-DefenderNumber -Value $idle.Percent), $Cores),
        ('Carga de archivos : {0} %  (~1500 archivos chicos)' -f (Format-DefenderNumber -Value $files.Percent)),
        ('Carga de scripts  : {0} %  (~25 powershell.exe)' -f (Format-DefenderNumber -Value $scripts.Percent)),
        $(if ($dFiles -ge 10) { '=> Archivos: Defender SI reacciona (escaneo por archivo). El costo escala con el conteo de archivos.' } else { '=> Archivos: Defender casi no reacciona a esta carga.' }),
        $(if ($dScripts -ge 5) { '=> Scripts: sube con la carga de scripts (AMSI cuenta).' } else { '=> Scripts: no sube: AMSI no es el problema.' })
    )
    return (New-DefenderDiagStep -Step 3 -Name $name -Status 'Ok' -Reason '' -Lines $lines -Data ([PSCustomObject]@{ Idle = $idle.Percent; Files = $files.Percent; Scripts = $scripts.Percent }))
}

function Get-DefenderDiagStep4 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Times, [Parameter(Mandatory)] [int] $Cores)
    [string] $name = 'CPU acumulada contra uptime'
    if (-not $Times.Ok) { return (New-DefenderDiagStep -Step 4 -Name $name -Status 'Skipped' -Reason $Times.Reason -Lines @() -Data $null) }
    try {
        $os = @(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)[0]
        $boot = Get-DefenderDiagProp -Object $os -Name 'LastBootUpTime'
    } catch {
        return (New-DefenderDiagStep -Step 4 -Name $name -Status 'Skipped' -Reason ('no se pudo leer el uptime: {0}' -f $_.Exception.Message) -Lines @() -Data $null)
    }
    if ($boot -isnot [datetime]) {
        return (New-DefenderDiagStep -Step 4 -Name $name -Status 'Skipped' -Reason 'Win32_OperatingSystem no devolvio LastBootUpTime.' -Lines @() -Data $null)
    }
    [double] $upH = ((Get-Date) - $boot).TotalHours
    if ($upH -le 0) {
        return (New-DefenderDiagStep -Step 4 -Name $name -Status 'Skipped' -Reason 'uptime no positivo (reloj raro).' -Lines @() -Data $null)
    }
    [double] $cpuMin = ($Times.UserSeconds + $Times.KernelSeconds) / 60
    [string] $line = Get-DefenderDiagUptimeLine -CpuMinutes $cpuMin -UptimeHours $upH -Cores $Cores
    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($line)
    if ($Times.CreationDate -is [datetime] -and $Times.CreationDate -gt $boot.AddMinutes(10)) {
        $lines.Add('(MsMpEng arranco despues del boot: el porcentaje real es algo mayor)')
    }
    return (New-DefenderDiagStep -Step 4 -Name $name -Status 'Ok' -Reason '' -Lines $lines -Data ([PSCustomObject]@{ Line = $line; CpuMinutes = $cpuMin; UptimeHours = $upH; Cores = $Cores }))
}

# --- Orquestador --------------------------------------------------------------------
function Invoke-DefenderDiag {
    <#
    .SYNOPSIS
        Corre los 4 pasos y devuelve { Available; Reason; Steps[]; Step4Line; Cores }.
        No imprime ni escribe archivos (eso es de Show-DefenderDiag). Sin admin.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $TempRoot = $env:TEMP,
        [Parameter()] [int] $Days = 7,
        [Parameter()] [int] $IdleSeconds = 5,
        [Parameter()] [int] $Cores = [Environment]::ProcessorCount
    )
    $def = Get-DefenderDiagStatus
    if (-not $def.Available) {
        [string] $why = $def.Reason
        $steps = @(
            (New-DefenderDiagStep -Step 1 -Name 'Es un scan programado?' -Status 'Skipped' -Reason $why -Lines @() -Data $null),
            (New-DefenderDiagStep -Step 2 -Name 'Ratio user/kernel de MsMpEng' -Status 'Skipped' -Reason $why -Lines @() -Data $null),
            (New-DefenderDiagStep -Step 3 -Name 'Causalidad contra baseline' -Status 'Skipped' -Reason $why -Lines @() -Data $null),
            (New-DefenderDiagStep -Step 4 -Name 'CPU acumulada contra uptime' -Status 'Skipped' -Reason $why -Lines @() -Data $null)
        )
        return [PSCustomObject]@{ Available = $false; Reason = $why; Steps = $steps; Step4Line = ''; Cores = $Cores }
    }

    $times = Get-DefenderProcessTimes
    $s1 = Get-DefenderDiagStep1 -DefStatus $def -Days $Days
    $s2 = Get-DefenderDiagStep2 -Times $times
    $s3 = Get-DefenderDiagStep3 -Cores $Cores -TempRoot $TempRoot -IdleSeconds $IdleSeconds
    # Paso 4 con una lectura FRESCA: la CPU acumulada incluye lo que gasto la carga del paso 3.
    $s4 = Get-DefenderDiagStep4 -Times (Get-DefenderProcessTimes) -Cores $Cores
    [string] $l4 = ''
    if ($s4.Status -eq 'Ok') { $l4 = [string]$s4.Data.Line }
    return [PSCustomObject]@{ Available = $true; Reason = ''; Steps = @($s1, $s2, $s3, $s4); Step4Line = $l4; Cores = $Cores }
}

function Show-DefenderDiag {
    <#
    .SYNOPSIS
        [A][19] [M]edir costo de Defender: corre el diagnostico, lo muestra con el
        vocabulario del menu, deja output\defender\diagnostico_<sello>.txt y escribe
        el audit (Defender.Diag). Sin admin; solo lectura sobre la config del equipo.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $OutputRootOverride = '',
        [Parameter()] [string] $TempRootOverride = ''
    )
    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'output' } else { $OutputRootOverride }
    [string] $tempRoot = if ([string]::IsNullOrEmpty($TempRootOverride)) { $env:TEMP } else { $TempRootOverride }

    Write-ActionAudit -Action 'Defender.Diag' -Status 'Started'
    Write-PctkSection '  DEFENDER: COSTO REAL (4 pasos, solo lectura, sin admin)'
    Write-PctkHint '  Dura < 1 minuto. No cambia nada de Defender.'

    $r = $null
    try {
        $r = Invoke-DefenderDiag -TempRoot $tempRoot
    } catch {
        Write-PctkWarn ('  [!] El diagnostico fallo: {0}' -f $_.Exception.Message)
        Write-ActionAudit -Action 'Defender.Diag' -Status 'Failed' -Summary $_.Exception.Message
        return
    }

    # (Kind, Text): la misma lista alimenta la pantalla y el .txt.
    [System.Collections.Generic.List[object]] $out = [System.Collections.Generic.List[object]]::new()
    $out.Add([PSCustomObject]@{ Kind = 'section'; Text = 'PCTk - Diagnostico de Defender' })
    $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ('Equipo: {0}   Fecha: {1}   Cores logicos: {2}' -f $env:COMPUTERNAME, (Get-PctkStamp), $r.Cores) })
    foreach ($st in $r.Steps) {
        $out.Add([PSCustomObject]@{ Kind = 'section'; Text = ('Paso {0}. {1}' -f $st.Step, $st.Name) })
        if ($st.Status -eq 'Skipped') {
            $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = ('  Skipped: {0}' -f $st.Reason) })
            continue
        }
        foreach ($l in $st.Lines) {
            [string] $k = if ($st.Step -eq 4 -and $l -eq $r.Step4Line) { 'ok' } else { 'value' }
            $out.Add([PSCustomObject]@{ Kind = $k; Text = ('  {0}' -f $l) })
        }
    }
    if ($r.Step4Line -ne '') {
        $out.Add([PSCustomObject]@{ Kind = 'hint'; Text = 'Lectura para el cliente: este es el porcentaje del CPU entero que Defender consumio desde que se prendio la PC.' })
    }

    foreach ($o in $out) {
        switch ($o.Kind) {
            'section' { Write-PctkSection ('  {0}' -f $o.Text) }
            'ok'      { Write-PctkOk $o.Text }
            'hint'    { Write-PctkHint ('  {0}' -f $o.Text) }
            default   { Write-PctkValue $o.Text }
        }
    }

    # .txt
    [string] $txtPath = ''
    try {
        [string] $dir = Join-Path $outputRoot 'defender'
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $txtPath = Join-Path $dir ('diagnostico_{0}.txt' -f (Get-PctkStamp))
        [System.IO.File]::WriteAllLines($txtPath, [string[]]@($out | ForEach-Object { $_.Text }), (New-Object System.Text.UTF8Encoding($true)))
        Write-PctkHint ('  Guardado en {0}' -f $txtPath)
    } catch {
        $txtPath = ''
        Write-PctkWarn ('  [!] No se pudo guardar el .txt: {0}' -f $_.Exception.Message)
    }

    [int] $skipped = @($r.Steps | Where-Object { $_.Status -eq 'Skipped' }).Count
    [string] $status = 'Success'
    [string] $summary = ''
    if (-not $r.Available) {
        $status = 'Info'
        $summary = 'skipped: defender no disponible'
    } elseif ($r.Step4Line -ne '') {
        $summary = $r.Step4Line
        if ($skipped -gt 0) { $summary = '{0} (pasos skipped: {1})' -f $summary, $skipped }
    } else {
        $status = 'Partial'
        $summary = ('sin numero del paso 4 (pasos skipped: {0})' -f $skipped)
    }
    $details = [PSCustomObject]@{
        Available = $r.Available
        Cores     = $r.Cores
        Step4     = $r.Step4Line
        Steps     = @($r.Steps | ForEach-Object { [PSCustomObject]@{ Step = $_.Step; Status = $_.Status; Reason = $_.Reason } })
        TxtPath   = $txtPath
    }
    Write-ActionAudit -Action 'Defender.Diag' -Status $status -Summary $summary -Details $details
}
