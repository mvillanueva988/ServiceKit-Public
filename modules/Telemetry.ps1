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

    # Antivirus — SecurityCenter2 (terceros) + Windows Defender.
    # IsActive es lo que cuenta para detectar conflictos: cuando hay un AV
    # de terceros corriendo, Defender entra automaticamente en Passive Mode
    # y sigue reportando AntivirusEnabled=$true pero NO escanea activamente.
    # Distinguimos:
    #   Enabled  = el motor esta habilitado (puede estar pasivo)
    #   IsActive = esta protegiendo en tiempo real ahora mismo
    #
    # SecurityCenter2 enumera TODOS los AV registrados, incluido Windows
    # Defender. Para evitar duplicado al agregar despues via Get-MpComputerStatus,
    # skipeamos Defender en este loop (matching por displayName o por
    # pathToSignedReportingExe). El MpComputerStatus tiene info mas rica
    # (AMRunningMode) y debe ser la fuente unica de verdad para Defender.
    [System.Collections.Generic.List[PSCustomObject]] $avList =
        [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        foreach ($av in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            [string] $displayName = [string] $av.displayName
            [string] $exePath = ''
            if ($null -ne $av.PSObject.Properties['pathToSignedReportingExe']) {
                $exePath = [string] $av.pathToSignedReportingExe
            }
            # Skip Defender — sera agregado abajo con info detallada.
            if ($displayName -match '(?i)Windows\s*Defender|Microsoft\s*Defender' -or
                $exePath -match '(?i)\\Windows Defender\\|\\MsMpeng\.exe') {
                continue
            }

            # Decode productState para AVs de terceros:
            # bit 0x1000 del DWORD = "product enabled". Mas confiable que el
            # substring approach previo, que asumia un nibble especifico.
            [bool] $enabled = (([int64] $av.productState -band 0x1000) -ne 0)

            $avList.Add([PSCustomObject]@{
                Name           = $displayName
                Enabled        = $enabled
                IsActive       = $enabled
                IsNative       = $false
                AMRunningMode  = $null
            })
        }
    } catch { }
    try {
        [object] $def = Get-MpComputerStatus -ErrorAction Stop
        # AMRunningMode: 'Normal' | 'Passive Mode' | 'SxS Passive Mode' |
        # 'EDR Block Mode'. Solo 'Normal' significa que Defender esta
        # escaneando en tiempo real; los modos pasivos son explicitos
        # "otro AV se hizo cargo".
        [string] $runningMode = ''
        if ($null -ne $def.PSObject.Properties['AMRunningMode']) {
            $runningMode = [string] $def.AMRunningMode
        }
        [bool] $defEnabled = [bool] $def.AntivirusEnabled
        [bool] $defActive  = $defEnabled -and ($runningMode -eq 'Normal' -or [string]::IsNullOrEmpty($runningMode))
        $avList.Add([PSCustomObject]@{
            Name           = 'Windows Defender'
            Enabled        = $defEnabled
            IsActive       = $defActive
            IsNative       = [bool] $true
            AMRunningMode  = $runningMode
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

    # Multiple AV problem real = mas de un motor escaneando ACTIVAMENTE.
    # Defender en Passive Mode no cuenta: es el comportamiento esperado
    # cuando hay un AV de terceros instalado y no genera conflicto.
    [bool] $multipleAv = (@($avList | Where-Object { $_.IsActive }).Count -gt 1)

    # ── Device Guard / VBS / HVCI status (inline, sin dependency externa) ─────
    # Se inlinea aca en lugar de llamar a Get-CoreIsolationStatus porque
    # Start-TelemetryJob solo dot-sourcea Telemetry.ps1 en el job runspace.
    [PSCustomObject] $deviceGuard = $null
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                              -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($null -ne $dg) {
            [int] $vbsStatus = 0
            if ($null -ne $dg.PSObject.Properties['VirtualizationBasedSecurityStatus']) {
                $vbsStatus = [int] $dg.VirtualizationBasedSecurityStatus
            }
            [int[]] $svcRunning = @()
            if ($null -ne $dg.PSObject.Properties['SecurityServicesRunning']) {
                $svcRunning = @($dg.SecurityServicesRunning | ForEach-Object { [int] $_ })
            }
            $deviceGuard = [PSCustomObject]@{
                VbsConfigured     = ($vbsStatus -ge 1)
                VbsRunning        = ($vbsStatus -eq 2)
                HvciRunning       = ($svcRunning -contains 2)
                CredentialGuardRunning = ($svcRunning -contains 1)
            }
        }
    } catch { }

    # ── USB + HID devices (categoria, no enumeracion completa) ────────────────
    [PSCustomObject[]] $usbDevices = @()
    [PSCustomObject[]] $hidDevices = @()
    try {
        $usbDevices = @(
            Get-PnpDevice -Class USB -Status OK -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [PSCustomObject]@{
                        FriendlyName = [string] $_.FriendlyName
                        InstanceId   = [string] $_.InstanceId
                    }
                }
        )
    } catch { }
    try {
        $hidDevices = @(
            Get-PnpDevice -Class HIDClass -Status OK -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [PSCustomObject]@{
                        FriendlyName = [string] $_.FriendlyName
                        Manufacturer = [string] $_.Manufacturer
                    }
                }
        )
    } catch { }

    # ── DNS servers IPv4 por adapter activo ───────────────────────────────────
    [hashtable] $dnsServers = @{}
    try {
        foreach ($entry in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
                              Where-Object { $_.AddressFamily -eq 2 -and $_.ServerAddresses.Count -gt 0 })) {
            $dnsServers[$entry.InterfaceAlias] = [string[]] @($entry.ServerAddresses)
        }
    } catch { }

    # ── Thermal zones detalladas (no solo CPU temp) ──────────────────────────
    [PSCustomObject[]] $thermalZones = @()
    try {
        $thermalZones = @(
            Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
                ForEach-Object {
                    [PSCustomObject]@{
                        Zone  = [string] $_.InstanceName
                        TempC = [double] [math]::Round(($_.CurrentTemperature - 2732) / 10.0, 1)
                    }
                }
        )
    } catch { }

    # ── Programas instalados — filtrados por vendors relevantes ───────────────
    # Filter regex matches OEM utilities, drivers, dev tools, gaming clients,
    # browsers, hardware monitors — todo lo que un tecnico de service quiere ver.
    [string] $vendorFilter = 'AMD|NVIDIA|Intel|Steam|Discord|Chrome|Edge|Firefox|HP|Lenovo|Dell|Asus|MSI|Logitech|Razer|Realtek|Visual Studio|Office|WhatsApp|OBS|7-Zip|WinRAR|Notepad\+\+|Git for|Docker|Python|Node|VLC|Spotify|Adobe'
    [PSCustomObject[]] $installedRelevant = @()
    try {
        [string[]] $uninstallHives = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installedRelevant = @(
            Get-ItemProperty $uninstallHives -ErrorAction SilentlyContinue |
                Where-Object {
                    $null -ne $_.PSObject.Properties['DisplayName'] -and
                    -not [string]::IsNullOrWhiteSpace($_.DisplayName) -and
                    $_.DisplayName -match $vendorFilter
                } |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name      = [string] $_.DisplayName
                        Version   = if ($null -ne $_.PSObject.Properties['DisplayVersion']) { [string] $_.DisplayVersion } else { '' }
                        Publisher = if ($null -ne $_.PSObject.Properties['Publisher']) { [string] $_.Publisher } else { '' }
                    }
                } |
                Sort-Object Name -Unique
        )
    } catch { }

    # ── Steam / CS2 detection + cfg parsing ───────────────────────────────────
    [PSCustomObject] $steam = $null
    try {
        $steamReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
        if ($null -ne $steamReg -and $null -ne $steamReg.PSObject.Properties['InstallPath']) {
            [string] $steamPath = [string] $steamReg.InstallPath
            [string] $cs2Path = Join-Path $steamPath 'steamapps\common\Counter-Strike Global Offensive'
            [bool] $cs2Installed = Test-Path -Path $cs2Path -PathType Container

            [string[]] $autoexecLines = @()
            if ($cs2Installed) {
                [string] $autoexecPath = Join-Path $cs2Path 'game\csgo\cfg\autoexec.cfg'
                if (Test-Path $autoexecPath) {
                    $autoexecLines = @(Get-Content -LiteralPath $autoexecPath -ErrorAction SilentlyContinue)
                }
            }

            [string] $launchOptions = ''
            [string] $userdataDir = Join-Path $steamPath 'userdata'
            if (Test-Path $userdataDir) {
                foreach ($userDir in @(Get-ChildItem -Path $userdataDir -Directory -ErrorAction SilentlyContinue)) {
                    [string] $localCfg = Join-Path $userDir.FullName 'config\localconfig.vdf'
                    if (Test-Path $localCfg) {
                        [string] $raw = Get-Content -LiteralPath $localCfg -Raw -ErrorAction SilentlyContinue
                        if ($raw -match '"730"\s*\{[^}]*"LaunchOptions"\s*"([^"]*)"') {
                            $launchOptions = $Matches[1]
                            break
                        }
                    }
                }
            }

            $steam = [PSCustomObject]@{
                Installed       = $true
                Path            = $steamPath
                Cs2Installed    = $cs2Installed
                Cs2Path         = if ($cs2Installed) { $cs2Path } else { '' }
                AutoexecLines   = $autoexecLines
                Cs2LaunchOptions = $launchOptions
            }
        }
    } catch { }

    # ── Power plan activo ────────────────────────────────────────────────────
    # El header de "powercfg /getactivescheme" varia por locale:
    #   en-US: "Power Scheme GUID:"
    #   es-AR: "GUID de plan de energía:"  (NO "esquema" como en versiones viejas)
    #   pt-BR: "GUID do Esquema de Energia:"
    # En vez de listar todas, usamos regex agnostico al idioma que matchea el
    # formato comun: cualquier texto antes de ":" seguido del GUID con paren.
    [PSCustomObject] $powerPlan = $null
    try {
        [string] $activeOut = (& powercfg /getactivescheme 2>&1) -join "`n"
        [string] $activeGuid = ''
        [string] $activeName = ''
        if ($activeOut -match ':\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\(([^)]+)\)') {
            $activeGuid = $Matches[1]
            $activeName = $Matches[2].Trim()
        }
        $powerPlan = [PSCustomObject]@{
            ActiveGuid = $activeGuid
            ActiveName = $activeName
        }
    } catch { }

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
        # ── Campos nuevos PR4 (ver audit.ps1 de Mateo + research prompt) ──────
        DeviceGuard       = $deviceGuard
        UsbDevices        = $usbDevices
        HidDevices        = $hidDevices
        DnsServers        = $dnsServers
        ThermalZones      = $thermalZones
        InstalledPrograms = $installedRelevant
        Steam             = $steam
        PowerPlan         = $powerPlan
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
    # PS5.1 + StrictMode: Measure-Object sobre coleccion vacia devuelve $null
    # (no un MeasureInfo), y .Sum sobre $null tira PropertyNotFoundException.
    # $volDiff queda vacia cuando ningun volumen matchea entre PRE/POST (VMs,
    # cambios de letra). Guard explicito.
    [double] $totalFreedGb = 0
    if ($volDiff.Count -gt 0) {
        $sumInfo = $volDiff | Measure-Object -Property SpaceFreedGb -Sum
        if ($null -ne $sumInfo -and $null -ne $sumInfo.Sum) {
            $totalFreedGb = [math]::Round([double] $sumInfo.Sum, 2)
        }
    }

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
