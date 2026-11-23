# --- #98: lector de eventos del sistema acotado (snapshot + [8] + [I] + [R]) ---
# Dot-sourceado por tests/smoke.ps1 (usa Test-SmokeFunction y los harness del
# smoke: Invoke-Hd3ClientReportHarness, Get-Hd3JobSnapshotJson, $script:Hd3OldSnapJson).
#
# Get-WinEvent se sombrea con eventos sinteticos (uno o mas por categoria). La
# definicion vive en UN here-string porque se usa en dos lugares: en el scope del
# test y adentro de un Start-Job que dot-sourcea SOLO Telemetry.ps1 (el camino real
# de Start-TelemetryJob, trampa #24: lo que no este en Telemetry.ps1 no existe ahi).

$script:EvShadowDef = @'
function New-EvFixtureEvents {
    [datetime] $now = Get-Date
    function _EvE {
        param([string] $Log, [string] $Prov, [int] $Id, [int] $Level, [int] $HoursAgo, [string] $Msg, [object[]] $Props = @())
        [object[]] $pp = @()
        foreach ($v in $Props) { $pp += [PSCustomObject]@{ Value = $v } }
        return [PSCustomObject]@{
            LogName = $Log; ProviderName = $Prov; Id = $Id; Level = $Level
            TimeCreated = $now.AddHours(-$HoursAgo); Message = $Msg; Properties = $pp
        }
    }
    @(
        (_EvE 'System' 'Microsoft-Windows-WHEA-Logger' 18 2 30 'A fatal hardware error has occurred. Component: Processor Core')
        (_EvE 'System' 'nvlddmkm' 13 2 5 'Graphics Exception: ESR 0x404490=0x80000002' @('\Device\Video3', 'Graphics Exception'))
        (_EvE 'System' 'amdkmdag' 10 2 50 'amdkmdag: el driver se reinicio' @('x'))
        (_EvE 'System' 'Display' 4101 3 70 'Display driver nvlddmkm stopped responding and has successfully recovered.' @('nvlddmkm', ''))
        (_EvE 'System' 'igfx' 1 4 2 'informativo de Intel (Level 4): NO cuenta')
        (_EvE 'Application' 'Windows Error Reporting' 1001 4 10 'Fault bucket LKD_0x141_Tdr:6_IMAGE_nvlddmkm.sys' @('0', '5', 'LiveKernelEvent', 'Not available', '0', '141', 'ffffd0019e4a6010', 'fffff80c3f1d5c60', '0', '0'))
        (_EvE 'Application' 'Windows Error Reporting' 1001 4 11 'APPCRASH de chrome: NO es LiveKernelEvent' @('123', '4', 'APPCRASH', 'Not available', '0', 'chrome.exe', '1.0', '0', '0', '0'))
        (_EvE 'Application' 'Windows Error Reporting' 1001 4 12 'LiveKernelEvent 1a8: NO cuenta' @('0', '5', 'LiveKernelEvent', 'Not available', '0', '1a8', 'x', 'x', '0', '0'))
        (_EvE 'System' 'disk' 7 2 20 'The device, \Device\Harddisk0\DR0, has a bad block.' @('\Device\Harddisk0\DR0'))
        (_EvE 'System' 'Ntfs' 55 2 21 'A corruption was discovered in the file system structure on volume C:.' @('C:'))
        (_EvE 'System' 'disk' 999 2 22 'id fuera de la lista: NO cuenta')
        (_EvE 'System' 'Microsoft-Windows-Kernel-Power' 41 1 40 'The system has rebooted without cleanly shutting down first.')
        (_EvE 'System' 'EventLog' 6008 2 41 'The previous system shutdown was unexpected.')
        (_EvE 'System' 'User32' 1074 4 3 'The process svchost.exe has initiated the restart.' @('C:\Windows\system32\svchost.exe (PC-EV)', 'PC-EV', 'Sistema operativo: Service pack (planeado)', '0x80020010', 'reiniciar', '', 'NT AUTHORITY\SYSTEM'))
        (_EvE 'Application' 'Application Error' 1000 2 6 'Faulting application name: chrome.exe' @('chrome.exe', '1.0'))
        (_EvE 'Application' 'Application Error' 1000 2 7 'Faulting application name: chrome.exe' @('chrome.exe', '1.0'))
        (_EvE 'Application' 'Application Error' 1000 2 8 'Faulting application name: juego.exe' @('juego.exe', '1.0'))
        (_EvE 'Application' 'Application Hang' 1002 2 9 'The program explorer.exe stopped interacting with Windows.' @('explorer.exe', '10.0'))
        (_EvE 'System' 'Service Control Manager' 7036 4 1 'ruido: NO cuenta')
        (_EvE 'System' 'Microsoft-Windows-WHEA-Logger' 17 3 960 'fuera de la ventana de 30 dias: NO cuenta')
    )
}
function Get-WinEvent {
    [CmdletBinding()]
    param([string] $LogName, [string] $FilterXPath, [int] $MaxEvents, [object] $FilterHashtable)
    @(New-EvFixtureEvents | Where-Object { $_.LogName -eq $LogName })
}
'@

# Conteos que la fixture tiene que dar, por categoria.
$script:EvExpected = [ordered]@{
    Whea               = 1   # WHEA 18 (el 17 de hace 40 dias queda afuera)
    Video              = 3   # nvlddmkm + amdkmdag + Display 4101 (igfx Level 4 no)
    LiveKernel         = 1   # WER 1001 LiveKernelEvent 141 (el APPCRASH y el 1a8 no)
    Disk               = 2   # disk 7 + Ntfs 55 (disk 999 no)
    ShutdownUnexpected = 2   # 41 + 6008
    ShutdownRequested  = 1   # 1074
    AppCrash           = 4   # 3x Application Error + 1x Application Hang
}

function Get-EvCategory {
    param([Parameter(Mandatory)] [object] $Events, [Parameter(Mandatory)] [string] $Key)
    if ($null -eq $Events.PSObject.Properties['Categories']) { throw 'Events no trae Categories' }
    [object[]] $hit = @(@($Events.Categories) | Where-Object { $_.Key -eq $Key })
    if ($hit.Count -ne 1) { throw ('Events: la categoria {0} aparece {1} veces (esperaba 1)' -f $Key, $hit.Count) }
    return $hit[0]
}

function Assert-EvFixtureCounts {
    param([Parameter(Mandatory)] [object] $Events)
    foreach ($k in $script:EvExpected.Keys) {
        [object] $c = Get-EvCategory -Events $Events -Key $k
        if ([int] $c.Count -ne [int] $script:EvExpected[$k]) {
            throw ('categoria {0}: Count={1}, esperaba {2}' -f $k, $c.Count, $script:EvExpected[$k])
        }
    }
}

# Corre el lector con Get-WinEvent sombreado por la fixture (scope del caller).
function Get-EvSummaryFromFixture {
    . ([scriptblock]::Create($script:EvShadowDef))
    return (Get-SystemEventSummary)
}

# Corre el lector con un Get-WinEvent que SIEMPRE tira el error dado.
function Get-EvSummaryThrowing {
    param([Parameter(Mandatory)] [string] $Message)
    $script:EvThrowMsg = $Message
    function Get-WinEvent {
        [CmdletBinding()]
        param([string] $LogName, [string] $FilterXPath, [int] $MaxEvents, [object] $FilterHashtable)
        throw $script:EvThrowMsg
    }
    return (Get-SystemEventSummary)
}

# Snapshot minimo (como lo leeria el [8] de disco) con el Events dado.
function New-EvSnapshotJson {
    param([object] $Events)
    return ([PSCustomObject]@{
        Phase        = 'Post'
        ComputerName = 'PC-EV'
        CPU          = [PSCustomObject]@{ Name = 'AMD Ryzen 5 5600G'; Cores = 6; Threads = 12 }
        RamTotalGb   = 16
        Events       = $Events
    } | ConvertTo-Json -Depth 10)
}

Test-SmokeFunction 'Eventos' '#98 lector: la fixture da los conteos por categoria (marca, top 3 de apps, ultimo, mensaje recortado)' {
    [object] $ev = Get-EvSummaryFromFixture
    if ($null -eq $ev) { throw 'Get-SystemEventSummary devolvio $null' }
    Assert-EvFixtureCounts -Events $ev
    if ([int] $ev.WindowDays -ne 30) { throw ('WindowDays={0}, esperaba 30' -f $ev.WindowDays) }
    [object] $video = Get-EvCategory -Events $ev -Key 'Video'
    [string[]] $brands = @($video.Brands | Sort-Object)
    if (($brands -join ',') -ne 'AMD,NVIDIA') { throw ('Video.Brands=[{0}], esperaba AMD,NVIDIA' -f ($brands -join ',')) }
    if ([string] $video.LastProvider -ne 'nvlddmkm') { throw ('Video.LastProvider={0}, esperaba nvlddmkm (el mas nuevo)' -f $video.LastProvider) }
    [object] $apps = Get-EvCategory -Events $ev -Key 'AppCrash'
    [object[]] $top = @($apps.TopApps)
    if ($top.Count -ne 3) { throw ('AppCrash.TopApps tiene {0}, esperaba 3' -f $top.Count) }
    if ([string] $top[0].Name -ne 'chrome.exe' -or [int] $top[0].Count -ne 2) { throw ('top 1 = {0} ({1}), esperaba chrome.exe (2)' -f $top[0].Name, $top[0].Count) }
    foreach ($c in @($ev.Categories)) {
        if ([string] $c.LastMessage -and ([string] $c.LastMessage).Length -gt 203) { throw ('{0}: LastMessage de {1} caracteres (tope ~200)' -f $c.Key, ([string] $c.LastMessage).Length) }
    }
    [object] $req = Get-EvCategory -Events $ev -Key 'ShutdownRequested'
    if ([string] $req.LastMessage -notmatch 'Service pack') { throw ('ShutdownRequested.LastMessage no trae el motivo: {0}' -f $req.LastMessage) }
}

Test-SmokeFunction 'Eventos' '#98 lector: Get-WinEvent con "No events were found" -> conteo 0, sin excepcion y sin error' {
    [object] $ev = Get-EvSummaryThrowing -Message 'No events were found that match the specified selection criteria.'
    if ($null -eq $ev) { throw 'Get-SystemEventSummary devolvio $null' }
    foreach ($k in $script:EvExpected.Keys) {
        [object] $c = Get-EvCategory -Events $ev -Key $k
        if ([int] $c.Count -ne 0) { throw ('{0}: Count={1}, esperaba 0' -f $k, $c.Count) }
    }
    if (@($ev.Errors).Count -ne 0) { throw ('"No events were found" se reporto como error: {0}' -f (@($ev.Errors) -join ' | ')) }
}

Test-SmokeFunction 'Eventos' '#98 lector: un fallo REAL de lectura queda en Errors (no se disfraza de "0 eventos") y no tira' {
    [object] $ev = Get-EvSummaryThrowing -Message 'Acceso denegado al registro de eventos'
    if (@($ev.Errors).Count -lt 1) { throw 'un fallo real de lectura no quedo en Errors' }
    [object] $c = Get-EvCategory -Events $ev -Key 'Whea'
    if ([int] $c.Count -ne 0) { throw 'con fallo de lectura el conteo deberia ser 0' }
}

Test-SmokeFunction 'Eventos' '#98 job real (solo Telemetry.ps1 + Get-WinEvent sombreado adentro): el snapshot guardado trae Events con los conteos' {
    [string] $modPath  = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Telemetry.ps1'
    [string] $fakeRoot = Join-Path $env:TEMP ('pctk-ev98job-' + [System.Guid]::NewGuid().ToString('N'))
    $j = Start-Job -ScriptBlock {
        param([string] $ModPath, [string] $FakeRoot, [string] $ShadowDef)
        Set-StrictMode -Version Latest
        . $ModPath
        $script:TelemetryModulePath = Join-Path $FakeRoot 'modules\Telemetry.ps1'
        . ([scriptblock]::Create($ShadowDef))
        Save-Snapshot -Phase Post -Stamp '2026-11-23_120000'
    } -ArgumentList @($modPath, $fakeRoot, $script:EvShadowDef)
    try {
        if (-not (Wait-Job $j -Timeout 240)) { throw 'el job no termino en 240 s' }
        $saved = Receive-Job $j -ErrorAction Stop
    } finally { Remove-Job $j -Force -ErrorAction SilentlyContinue }
    try {
        if ($null -eq $saved) { throw 'Save-Snapshot no devolvio resultado en el job' }
        [string] $p = [string] $saved.FilePath
        if ($p -notlike ($fakeRoot + '*') -or -not (Test-Path -LiteralPath $p)) { throw ('snapshot fuera del temp o inexistente: {0}' -f $p) }
        [object] $snap = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $snap.PSObject.Properties['Events'] -or $null -eq $snap.Events) { throw 'el snapshot del job no trae Events (el lector no existe adentro del job?)' }
        Assert-EvFixtureCounts -Events $snap.Events
    } finally {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Eventos' '#98 job real SIN sombra (logs de esta PC): Events existe con las 7 categorias' {
    [object] $snap = (Get-Hd3JobSnapshotJson) | ConvertFrom-Json
    if ($null -eq $snap.PSObject.Properties['Events'] -or $null -eq $snap.Events) { throw 'el snapshot real del job no trae Events' }
    foreach ($k in $script:EvExpected.Keys) { $null = Get-EvCategory -Events $snap.Events -Key $k }
}

Test-SmokeFunction 'Eventos' '#98 handler [8]: seccion en llano, sin jerga (WHEA / nvlddmkm / 4101 / LiveKernelEvent)' {
    [string] $html = Invoke-Hd3ClientReportHarness -SnapshotJson (New-EvSnapshotJson -Events (Get-EvSummaryFromFixture))
    if ($html -notmatch 'Errores registrados') { throw 'el [8] no tiene la seccion de errores registrados' }
    if ($html -notmatch 'Cuelgues del driver de video: 3 en 30 d') { throw 'el [8] no dice "Cuelgues del driver de video: 3 en 30 dias"' }
    if ($html -notmatch 'Apagados inesperados[^<]*: 2 en 30 d') { throw 'el [8] no dice los apagados inesperados (2)' }
    foreach ($jerga in @('WHEA', 'nvlddmkm', '4101', 'LiveKernel', 'amdkmdag', 'Kernel-Power', '6008')) {
        if ($html -match [regex]::Escape($jerga)) { throw ('el [8] (para el cliente) muestra jerga: {0}' -f $jerga) }
    }
    if ($html -match 'Sin errores graves') { throw 'con errores el [8] dice "sin errores graves"' }
}

Test-SmokeFunction 'Eventos' '#98 handler [8]: todo en 0 -> una linea "Sin errores graves registrados en los ultimos 30 dias"' {
    [object] $ev = Get-EvSummaryThrowing -Message 'No events were found that match the specified selection criteria.'
    [string] $html = Invoke-Hd3ClientReportHarness -SnapshotJson (New-EvSnapshotJson -Events $ev)
    if ($html -notmatch 'Sin errores graves registrados en los .ltimos 30 d.as') { throw 'con todo en 0 falta la linea de "sin errores graves"' }
    if ($html -match 'Cuelgues del driver de video') { throw 'con todo en 0 igual lista categorias' }
}

Test-SmokeFunction 'Eventos' '#98 handler [8]: snapshot viejo sin Events -> sin seccion y sin romper bajo StrictMode' {
    [string] $html = Invoke-Hd3ClientReportHarness -SnapshotJson $script:Hd3OldSnapJson
    if ($html -match 'Errores registrados|Sin errores graves') { throw 'un snapshot sin Events no deberia dibujar la seccion' }
}

Test-SmokeFunction 'Eventos' '#98 handler [I]: el informe tecnico trae el detalle (categoria, IDs, proveedor, conteo, top de apps)' {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    if ($null -eq $script:_snapshotResult) { $script:_snapshotResult = Get-SystemSnapshot -Phase Pre }
    [object] $snap = $script:_snapshotResult.PSObject.Copy()
    $snap | Add-Member -NotePropertyName Events -NotePropertyValue (Get-EvSummaryFromFixture) -Force
    $script:EvRawOpened = [System.Collections.Generic.List[string]]::new()
    function Get-SystemSnapshot { param([string] $Phase) return $snap }
    function Start-Process { param([Parameter(Position = 0)] [string] $FilePath, [object] $ArgumentList) $script:EvRawOpened.Add(([string] $ArgumentList).Trim('"')) }
    [PSCustomObject] $mp = [PSCustomObject]@{ IsLaptop = $false; RamMB = 8192; Tier = 'Mid'; IsHome = $true }
    Invoke-RawAuditReport -MachineProfile $mp | Out-Null
    if ($script:EvRawOpened.Count -ne 1) { throw 'el handler [I] no genero/abrio el informe' }
    [string] $path = $script:EvRawOpened[0]
    try {
        [string] $txt = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        foreach ($need in @('SYSTEM EVENTS', 'WHEA-Logger', 'nvlddmkm', '4101', 'LiveKernelEvent', 'chrome.exe (2)', 'Service pack')) {
            if ($txt -notmatch [regex]::Escape($need)) { throw ('el [I] no trae "{0}"' -f $need) }
        }
        if ($txt -notmatch '\[Video\][^\r\n]*count=3') { throw 'el [I] no trae la linea de Video con count=3' }
        if ($txt -notmatch '\[AppCrash\][^\r\n]*count=4') { throw 'el [I] no trae la linea de AppCrash con count=4' }
    } finally {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Eventos' '#98 prompt [R]: una linea por categoria con > 0 (y nada para las que dan 0)' {
    $ErrorActionPreference = 'Stop'
    function Set-Clipboard { param([object] $Value) }
    [object] $ev = Get-EvSummaryFromFixture
    $snap = [PSCustomObject]@{ CPU = [PSCustomObject]@{ Name = 'x' }; Events = $ev }
    $r = New-ResearchPrompt -Template Troubleshooting -Snapshot $snap -MachineProfile ([PSCustomObject]@{ IsHome = $true })
    try {
        [string] $txt = Get-Content -LiteralPath $r.FilePath -Raw -Encoding UTF8
        if ($txt -notmatch '## Eventos del sistema') { throw 'el prompt no trae la seccion de eventos' }
        if ($txt -notmatch 'nvlddmkm|Cuelgues del driver de video[^\r\n]*3') { throw 'el prompt no trae la linea de video' }
        [object] $ev0 = Get-EvSummaryThrowing -Message 'No events were found that match the specified selection criteria.'
        $snap0 = [PSCustomObject]@{ CPU = [PSCustomObject]@{ Name = 'x' }; Events = $ev0 }
        $r0 = New-ResearchPrompt -Template Troubleshooting -Snapshot $snap0 -MachineProfile ([PSCustomObject]@{ IsHome = $true })
        [string] $txt0 = Get-Content -LiteralPath $r0.FilePath -Raw -Encoding UTF8
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $r0.FilePath -Force -ErrorAction SilentlyContinue
        if ($txt0 -match 'Cuelgues del driver de video') { throw 'con 0 eventos el prompt igual lista la categoria' }
    } finally {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $r.FilePath -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'Eventos' '#98 Compare-Snapshot: la clave Events no cambia el Score ni rompe' {
    [string] $tmp = Join-Path $env:TEMP ('pctk-ev98cmp-' + [System.Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    try {
        $base = [ordered]@{
            Phase = 'Pre'; Timestamp = '2026-11-23 10:00:00'; ComputerName = 'PC-EV'; UptimeHours = 10
            Volumes = @([PSCustomObject]@{ Letter = 'C'; FreeGb = 50; UsedPct = 50 })
            Services = [PSCustomObject]@{ RunningCount = 100; BloatRunning = @('DiagTrack') }
            StartupCount = 8; Battery = $null; MultipleAvProblem = $false
        }
        $post = [ordered]@{} + $base
        $post.Phase = 'Post'; $post.UptimeHours = 1
        $post.Services = [PSCustomObject]@{ RunningCount = 90; BloatRunning = @() }
        [string] $pre = Join-Path $tmp 'pre.json'
        [string] $p1  = Join-Path $tmp 'post1.json'
        [string] $p2  = Join-Path $tmp 'post2.json'
        ([PSCustomObject] $base) | ConvertTo-Json -Depth 10 | Out-File -FilePath $pre -Encoding UTF8
        ([PSCustomObject] $post) | ConvertTo-Json -Depth 10 | Out-File -FilePath $p1 -Encoding UTF8
        $post.Events = Get-EvSummaryFromFixture
        ([PSCustomObject] $post) | ConvertTo-Json -Depth 10 | Out-File -FilePath $p2 -Encoding UTF8
        $c1 = Compare-Snapshot -PrePath $pre -PostPath $p1
        $c2 = Compare-Snapshot -PrePath $pre -PostPath $p2
        if ($c1.Score -ne $c2.Score) { throw ('Score sin Events={0}, con Events={1}' -f $c1.Score, $c2.Score) }
        if ($c2.Score -lt 1) { throw 'fixture mal armada: el Score deberia ser > 0' }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
