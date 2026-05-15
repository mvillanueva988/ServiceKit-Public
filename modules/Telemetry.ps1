Set-StrictMode -Version Latest

# Captura la ruta del módulo durante el dot-sourcing para usarla en jobs asincrónicos
[string] $script:TelemetryModulePath = $PSCommandPath

# ─── Get-SystemSnapshot ───────────────────────────────────────────────────────
function Get-SystemSnapshot {
    <#
    .SYNOPSIS
        Recopila el estado del sistema vía CIM/WMI y retorna un PSCustomObject estructurado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pre', 'Post')]
        [string] $Phase
    )

    # CPU
    $cpuRaw = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpu = if ($cpuRaw) {
        [PSCustomObject]@{
            Name    = [string] $cpuRaw.Name.Trim()
            Cores   = [int]    $cpuRaw.NumberOfCores
            Threads = [int]    $cpuRaw.NumberOfLogicalProcessors
        }
    } else {
        [PSCustomObject]@{ Name = 'Unknown'; Cores = 0; Threads = 0 }
    }

    # GPU — detecta dedicada vs integrada desde el nombre
    $gpus = @(
        Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{
                Name          = [string] $_.Name
                Type          = [string] $(if ($_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Radeon VII|Arc') { 'Dedicated' } else { 'Integrated' })
                DriverVersion = [string] $_.DriverVersion
            }
        }
    )

    # RAM total
    $csRaw = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $ramTotalGb = if ($csRaw) { [math]::Round($csRaw.TotalPhysicalMemory / 1GB, 2) } else { [double]0 }

    # RAM slots — excluye slots vacios
    $ramSlots = @(
        Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue |
            Where-Object { $_.Capacity -gt 0 } |
            ForEach-Object {
                [PSCustomObject]@{
                    Slot         = [string] $_.DeviceLocator
                    CapacityGb   = [double] [math]::Round($_.Capacity / 1GB, 2)
                    SpeedMhz     = [int]    $_.Speed
                    Manufacturer = [string] $_.Manufacturer
                }
            }
    )

    # Discos físicos + contadores SMART
    $diskList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($physDisk in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rel      = $physDisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $tempC    = $null
        $wearPct  = $null
        $readErr  = $null
        $writeErr = $null
        if ($rel) {
            if ([int]$rel.Temperature -gt 0) { $tempC   = [int]$rel.Temperature }
            if ($null -ne $rel.Wear)          { $wearPct = [int]$rel.Wear }
            $readErr  = $rel.ReadErrorsTotal
            $writeErr = $rel.WriteErrorsTotal
        }
        $diskList.Add([PSCustomObject]@{
            Name         = [string] $physDisk.FriendlyName
            MediaType    = [string] $physDisk.MediaType
            SizeGb       = [double] [math]::Round($physDisk.Size / 1GB, 2)
            HealthStatus = [string] $physDisk.HealthStatus
            TempC        = $tempC
            WearPct      = $wearPct
            ReadErrors   = $readErr
            WriteErrors  = $writeErr
        })
    }
    [PSCustomObject[]] $disks = $diskList.ToArray()

    # Volumenes — solo particiones fijas con letra, excluye EFI
    $volumes = @(
        Get-Volume |
            Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -ne 'FAT32' } |
            ForEach-Object {
                [double] $sizeGb = [math]::Round($_.Size / 1GB, 2)
                [double] $freeGb = [math]::Round($_.SizeRemaining / 1GB, 2)
                [PSCustomObject]@{
                    Letter  = [string] $_.DriveLetter
                    Label   = [string] $_.FileSystemLabel
                    SizeGb  = $sizeGb
                    FreeGb  = $freeGb
                    UsedPct = if ($sizeGb -gt 0) {
                        [double] [math]::Round((($sizeGb - $freeGb) / $sizeGb) * 100, 1)
                    } else { [double]0 }
                }
            }
    )

    # Page File — CurrentUsage y PeakUsage ya están en MB
    [object] $pfRaw = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
    [PSCustomObject] $pageFile = [PSCustomObject]@{
        CurrentUsageMb = if ($pfRaw) { [int]$pfRaw.CurrentUsage } else { $null }
        PeakUsageMb    = if ($pfRaw) { [int]$pfRaw.PeakUsage }    else { $null }
    }

    # Servicios en ejecución + detección de bloat
    [string[]] $bloatNames = @(
        'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
        'Spooler', 'PrintNotify', 'Fax', 'WMPNetworkSvc',
        'RemoteRegistry', 'RemoteAccess', 'DiagTrack', 'dmwappushservice'
    )
    [object[]] $runningSvcs  = @(Get-Service | Where-Object { $_.Status -eq 'Running' })
    [string[]] $bloatRunning = @(
        $runningSvcs | Where-Object { $_.Name -in $bloatNames } | Select-Object -ExpandProperty Name
    )
    [PSCustomObject] $services = [PSCustomObject]@{
        RunningCount = [int]      $runningSvcs.Count
        BloatRunning = [string[]] $bloatRunning
    }

    # Startup — solo registry y carpetas (sin scheduled tasks para velocidad)
    [int] $startupCount = 0
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )) {
        if (Test-Path $key) {
            $startupCount += @(
                (Get-ItemProperty $key).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
            ).Count
        }
    }
    foreach ($folder in @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )) {
        if (Test-Path $folder) { $startupCount += @(Get-ChildItem $folder -File -ErrorAction SilentlyContinue).Count }
    }

    # Top 5 procesos por WorkingSet
    [PSCustomObject[]] $topProcs = @(
        Get-Process |
            Sort-Object WorkingSet64 -Descending |
            Select-Object -First 5 |
            ForEach-Object {
                [PSCustomObject]@{
                    Name         = [string] $_.Name
                    WorkingSetMb = [double] [math]::Round($_.WorkingSet64 / 1MB, 1)
                }
            }
    )

    # Batería — solo en laptops (chassis types portátiles)
    [PSCustomObject] $battery = $null
    $encRaw = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    [int] $chassisType = if ($encRaw -and $encRaw.ChassisTypes.Count -gt 0) { [int]$encRaw.ChassisTypes[0] } else { 0 }
    if ($chassisType -in @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)) {
        [object] $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) {
            $battery = [PSCustomObject]@{
                ChargePercent = [int] $bat.EstimatedChargeRemaining
                HealthPercent = if ($bat.DesignCapacity -gt 0) {
                    [double] [math]::Round(($bat.FullChargeCapacity / $bat.DesignCapacity) * 100, 1)
                } else { $null }
                Status        = [string] $(switch ($bat.BatteryStatus) {
                    1 { 'Discharging' }  2 { 'AC' }  3 { 'FullyCharged' }
                    4 { 'Low' }          5 { 'Critical' }  default { 'Unknown' }
                })
            }
        }
    }

    # Antivirus — SecurityCenter2 (terceros) + Windows Defender
    [System.Collections.Generic.List[PSCustomObject]] $avList =
        [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        foreach ($av in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            [string] $hex     = [Convert]::ToString($av.productState, 16).PadLeft(6, '0')
            [bool]   $enabled = ($hex.Substring(2, 2) -eq '10')
            $avList.Add([PSCustomObject]@{
                Name     = [string] $av.displayName
                Enabled  = [bool]   $enabled
                IsNative = [bool]   $false
            })
        }
    } catch { }
    try {
        [object] $def = Get-MpComputerStatus -ErrorAction Stop
        $avList.Add([PSCustomObject]@{
            Name     = 'Windows Defender'
            Enabled  = [bool] $def.AntivirusEnabled
            IsNative = [bool] $true
        })
    } catch { }

    # Temperatura CPU — best-effort via ACPI (décimas de Kelvin → Celsius)
    [object] $cpuTempC = $null
    try {
        [object[]] $zones = @(
            Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        )
        if ($zones.Count -gt 0) {
            $cpuTempC = [math]::Round(($zones[0].CurrentTemperature - 2732) / 10.0, 1)
        }
    } catch { }

    # Uptime
    [object] $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    [double] $uptimeHours = if ($os) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { [double]0 }

    [bool] $multipleAv = (@($avList | Where-Object { $_.Enabled }).Count -gt 1)

    return [PSCustomObject]@{
        Phase             = [string]   $Phase
        Timestamp         = [string]   (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ComputerName      = [string]   $env:COMPUTERNAME
        CPU               = $cpu
        GPU               = $gpus
        RamTotalGb        = [double]   $ramTotalGb
        RamSlots          = $ramSlots
        Disks             = $disks
        Volumes           = $volumes
        PageFile          = $pageFile
        Services          = $services
        StartupCount      = [int]      $startupCount
        TopProcesses      = $topProcs
        Battery           = $battery
        Antivirus         = $avList.ToArray()
        MultipleAvProblem = [bool]     $multipleAv
        CpuTempC          = $cpuTempC
        UptimeHours       = [double]   $uptimeHours
    }
}

# ─── Save-Snapshot ────────────────────────────────────────────────────────────
function Save-Snapshot {
    <#
    .SYNOPSIS
        Ejecuta Get-SystemSnapshot y persiste el resultado como JSON en output\snapshots\.
        Retorna un objeto con Phase, FilePath y FileName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pre', 'Post')]
        [string] $Phase
    )

    [string] $toolkitRoot = Split-Path (Split-Path $script:TelemetryModulePath -Parent) -Parent
    [string] $outputDir   = Join-Path $toolkitRoot 'output\snapshots'

    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }

    [PSCustomObject] $snapshot = Get-SystemSnapshot -Phase $Phase
    [string] $filename = '{0}_{1}.json' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $Phase.ToLower()
    [string] $filePath = Join-Path $outputDir $filename

    $snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding UTF8

    return [PSCustomObject]@{
        Phase    = [string] $Phase
        FilePath = [string] $filePath
        FileName = [string] $filename
    }
}

# ─── Compare-Snapshot ─────────────────────────────────────────────────────────
function Compare-Snapshot {
    <#
    .SYNOPSIS
        Carga los JSONs PRE y POST más recientes (o los indicados) y retorna un diff estructurado.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $PrePath,
        [Parameter()] [string] $PostPath
    )

    [string] $snapshotsDir = Join-Path (Split-Path (Split-Path $script:TelemetryModulePath -Parent) -Parent) 'output\snapshots'

    if (-not $PSBoundParameters.ContainsKey('PrePath')) {
        [object[]] $preFiles = @(
            Get-ChildItem -Path $snapshotsDir -Filter '*_pre.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
        )
        if ($preFiles.Count -eq 0) {
            throw 'No se encontro snapshot PRE. Usa la opcion [7] antes del service.'
        }
        $PrePath = $preFiles[0].FullName
    }

    if (-not $PSBoundParameters.ContainsKey('PostPath')) {
        [object[]] $postFiles = @(
            Get-ChildItem -Path $snapshotsDir -Filter '*_post.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
        )
        if ($postFiles.Count -eq 0) {
            throw 'No se encontro snapshot POST. Usa la opcion [8] despues del service.'
        }
        $PostPath = $postFiles[0].FullName
    }

    [PSCustomObject] $pre  = Get-Content $PrePath  -Raw | ConvertFrom-Json
    [PSCustomObject] $post = Get-Content $PostPath -Raw | ConvertFrom-Json

    # Diff de volúmenes — join por letra de unidad
    [System.Collections.Generic.List[PSCustomObject]] $volDiff =
        [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($pv in $post.Volumes) {
        [object] $rv = $pre.Volumes | Where-Object { $_.Letter -eq $pv.Letter } | Select-Object -First 1
        if ($rv) {
            $volDiff.Add([PSCustomObject]@{
                Letter       = [string] $pv.Letter
                SpaceFreedGb = [double] [math]::Round($pv.FreeGb - $rv.FreeGb, 2)
                PreFreeGb    = [double] $rv.FreeGb
                PostFreeGb   = [double] $pv.FreeGb
                PreUsedPct   = [double] $rv.UsedPct
                PostUsedPct  = [double] $pv.UsedPct
            })
        }
    }
    [double] $totalFreedGb = [math]::Round(
        ($volDiff | Measure-Object -Property SpaceFreedGb -Sum).Sum, 2
    )

    # Diff de servicios
    [int]      $servicesDelta = $pre.Services.RunningCount - $post.Services.RunningCount
    [string[]] $bloatFixed    = @(
        $pre.Services.BloatRunning | Where-Object { $_ -notin @($post.Services.BloatRunning) }
    )

    # Diff de startup
    [int] $startupDelta = $pre.StartupCount - $post.StartupCount

    # Diff de batería (solo laptops)
    [PSCustomObject] $batteryDiff = $null
    if ($pre.Battery -and $post.Battery) {
        $batteryDiff = [PSCustomObject]@{
            PreCharge  = $pre.Battery.ChargePercent
            PostCharge = $post.Battery.ChargePercent
            PreHealth  = $pre.Battery.HealthPercent
            PostHealth = $post.Battery.HealthPercent
        }
    }

    # Score (6 áreas)
    [int] $score = 0
    [System.Collections.Generic.List[string]] $improvements =
        [System.Collections.Generic.List[string]]::new()

    if ($totalFreedGb -gt 0.1)      { $score++; $improvements.Add("Espacio liberado: $([math]::Round($totalFreedGb, 2)) GB") }
    if ($servicesDelta -gt 0)        { $score++; $improvements.Add("Servicios detenidos: $servicesDelta") }
    if ($bloatFixed.Count -gt 0)     { $score++; $improvements.Add("Bloat deshabilitado: $($bloatFixed -join ', ')") }
    if ($startupDelta -gt 0)         { $score++; $improvements.Add("Programas de inicio removidos: $startupDelta") }
    [bool] $avFixed  = $pre.MultipleAvProblem -and -not $post.MultipleAvProblem
    if ($avFixed)                    { $score++; $improvements.Add("Conflicto de antivirus resuelto") }
    [bool] $rebooted = $post.UptimeHours -lt $pre.UptimeHours
    if ($rebooted)                   { $score++; $improvements.Add("Sistema reiniciado correctamente") }

    return [PSCustomObject]@{
        PreFile          = [string]   (Split-Path $PrePath  -Leaf)
        PostFile         = [string]   (Split-Path $PostPath -Leaf)
        PreTimestamp     = [string]   $pre.Timestamp
        PostTimestamp    = [string]   $post.Timestamp
        PreUptimeHours   = [double]   $pre.UptimeHours
        PostUptimeHours  = [double]   $post.UptimeHours
        ComputerName     = [string]   $post.ComputerName
        VolumeDiff       = $volDiff.ToArray()
        TotalFreedGb     = [double]   $totalFreedGb
        PreRunningCount  = [int]      $pre.Services.RunningCount
        PostRunningCount = [int]      $post.Services.RunningCount
        ServicesDelta    = [int]      $servicesDelta
        BloatFixed       = [string[]] $bloatFixed
        PreStartupCount  = [int]      $pre.StartupCount
        PostStartupCount = [int]      $post.StartupCount
        StartupDelta     = [int]      $startupDelta
        BatteryDiff      = $batteryDiff
        AvFixed          = [bool]     $avFixed
        Rebooted         = [bool]     $rebooted
        Score            = [int]      $score
        ScoreMax         = [int]      6
        Improvements     = $improvements.ToArray()
    }
}

# ─── Show-SnapshotComparison ──────────────────────────────────────────────────
function Show-SnapshotComparison {
    <#
    .SYNOPSIS
        Muestra el diff de Compare-Snapshot en consola con colores semanticos.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Diff
    )

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '    COMPARACION PRE/POST SERVICE' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host "    PC      : $($Diff.ComputerName)"  -ForegroundColor Gray
    Write-Host "    Pre     : $($Diff.PreTimestamp)"  -ForegroundColor DarkGray
    Write-Host "    Post    : $($Diff.PostTimestamp)" -ForegroundColor DarkGray
    Write-Host ''

    # Almacenamiento
    Write-Host '  [ALMACENAMIENTO]' -ForegroundColor DarkCyan
    foreach ($vol in $Diff.VolumeDiff) {
        [string] $ind   = if ($vol.SpaceFreedGb -gt 0.1) { '[+]' } elseif ($vol.SpaceFreedGb -lt -0.1) { '[-]' } else { '[ ]' }
        [string] $clr   = if ($vol.SpaceFreedGb -gt 0.1) { 'Green' } elseif ($vol.SpaceFreedGb -lt -0.1) { 'Red' } else { 'DarkGray' }
        [string] $sign  = if ($vol.SpaceFreedGb -ge 0) { '+' } else { '' }
        [string] $delta = "$sign$($vol.SpaceFreedGb.ToString('0.00')) GB"
        Write-Host "    $ind $($vol.Letter):  $($vol.PreFreeGb.ToString('0.00')) GB libre -> $($vol.PostFreeGb.ToString('0.00')) GB libre  ($delta)" -ForegroundColor $clr
    }
    [string] $totalClr = if ($Diff.TotalFreedGb -gt 0.1) { 'Green' } else { 'DarkGray' }
    Write-Host "         Total liberado: $($Diff.TotalFreedGb.ToString('0.00')) GB" -ForegroundColor $totalClr
    Write-Host ''

    # Servicios
    Write-Host '  [SERVICIOS]' -ForegroundColor DarkCyan
    [string] $svcInd  = if ($Diff.ServicesDelta -gt 0) { '[+]' } elseif ($Diff.ServicesDelta -lt 0) { '[-]' } else { '[ ]' }
    [string] $svcClr  = if ($Diff.ServicesDelta -gt 0) { 'Green' } elseif ($Diff.ServicesDelta -lt 0) { 'Red' } else { 'DarkGray' }
    [string] $svcSign = if ($Diff.ServicesDelta -gt 0) { '-' } elseif ($Diff.ServicesDelta -lt 0) { '+' } else { '' }
    Write-Host "    $svcInd En ejecucion: $($Diff.PreRunningCount) -> $($Diff.PostRunningCount)  (${svcSign}$([math]::Abs($Diff.ServicesDelta)))" -ForegroundColor $svcClr
    if ($Diff.BloatFixed.Count -gt 0) {
        Write-Host "    [+] Bloat deshabilitado: $($Diff.BloatFixed -join ', ')" -ForegroundColor Green
    }
    Write-Host ''

    # Inicio del sistema
    Write-Host '  [INICIO DEL SISTEMA]' -ForegroundColor DarkCyan
    [string] $stInd  = if ($Diff.StartupDelta -gt 0) { '[+]' } elseif ($Diff.StartupDelta -lt 0) { '[-]' } else { '[ ]' }
    [string] $stClr  = if ($Diff.StartupDelta -gt 0) { 'Green' } elseif ($Diff.StartupDelta -lt 0) { 'Red' } else { 'DarkGray' }
    [string] $stSign = if ($Diff.StartupDelta -gt 0) { '-' } elseif ($Diff.StartupDelta -lt 0) { '+' } else { '' }
    Write-Host "    $stInd Programas de inicio: $($Diff.PreStartupCount) -> $($Diff.PostStartupCount)  (${stSign}$([math]::Abs($Diff.StartupDelta)))" -ForegroundColor $stClr
    Write-Host ''

    # Bateria (solo laptops)
    if ($Diff.BatteryDiff) {
        Write-Host '  [BATERIA]' -ForegroundColor DarkCyan
        Write-Host "    [ ] Carga  : $($Diff.BatteryDiff.PreCharge)% -> $($Diff.BatteryDiff.PostCharge)%" -ForegroundColor DarkGray
        [string] $healthClr = if ($Diff.BatteryDiff.PostHealth -lt ($Diff.BatteryDiff.PreHealth - 5)) { 'Red' } else { 'DarkGray' }
        Write-Host "    [ ] Salud  : $($Diff.BatteryDiff.PreHealth)% -> $($Diff.BatteryDiff.PostHealth)%" -ForegroundColor $healthClr
        Write-Host ''
    }

    # Antivirus (auditoria de estado, no escaneo)
    Write-Host '  [ANTIVIRUS]' -ForegroundColor DarkCyan
    Write-Host '    [i] Auditoria de estado (sin escaneo activo)' -ForegroundColor DarkGray
    if ($Diff.AvFixed) {
        Write-Host '    [+] Conflicto de antivirus resuelto' -ForegroundColor Green
    } else {
        Write-Host '    [ ] Sin cambios en antivirus' -ForegroundColor DarkGray
    }
    Write-Host ''

    # Sistema
    Write-Host '  [SISTEMA]' -ForegroundColor DarkCyan
    Write-Host ('    [i] Uptime PRE/POST: {0}h -> {1}h' -f $Diff.PreUptimeHours.ToString('0.0'), $Diff.PostUptimeHours.ToString('0.0')) -ForegroundColor DarkGray
    if ($Diff.Rebooted) {
        Write-Host '    [+] Sistema reiniciado correctamente' -ForegroundColor Green
    } else {
        Write-Host '    [!] Sistema NO reiniciado (recomendado para aplicar cambios)' -ForegroundColor Yellow
    }
    Write-Host ''

    # Score final
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    [string] $scoreClr = if ($Diff.Score -ge 5) { 'Green' } elseif ($Diff.Score -ge 3) { 'Yellow' } else { 'Red' }
    Write-Host "    EFECTIVIDAD DEL SERVICE: $($Diff.Score)/$($Diff.ScoreMax)" -ForegroundColor $scoreClr
    if ($Diff.Improvements.Count -gt 0) {
        Write-Host ''
        foreach ($imp in $Diff.Improvements) {
            Write-Host "    [OK] $imp" -ForegroundColor Green
        }
    }
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# ─── Start-TelemetryJob ───────────────────────────────────────────────────────
function Start-TelemetryJob {
    <#
    .SYNOPSIS
        Ejecuta Save-Snapshot de forma asincrónica. El job dot-sourcea este mismo módulo
        para tener acceso a todas las funciones necesarias.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pre', 'Post')]
        [string] $Phase
    )

    [string] $modPath = $script:TelemetryModulePath

    return Invoke-AsyncToolkitJob -JobName "Telemetry_$Phase" -ScriptBlock {
        param([string] $ModPath, [string] $Ph)
        Set-StrictMode -Version Latest
        . $ModPath
        Save-Snapshot -Phase $Ph
    } -ArgumentList @($modPath, $Phase)
}
