Set-StrictMode -Version Latest

# Captura la ruta del módulo durante el dot-sourcing para usarla en jobs asincrónicos
[string] $script:TelemetryModulePath = $PSCommandPath

# ─── Invoke-WithTimeout ───────────────────────────────────────────────────────
# Helper interno (T-N1): DEBE vivir en Telemetry.ps1 porque el runspace del job
# de telemetría solo dot-sourcea este archivo. NO mover a ToolkitSupport ni afuera.
# Para queries no-CIM que no soportan -OperationTimeoutSec nativo.
function Invoke-WithTimeout {
    <#
    .SYNOPSIS
        Ejecuta un ScriptBlock en un runspace separado con timeout.
        Retorna el resultado del ScriptBlock, o $Default si vence el timeout o lanza.
    .NOTES
        T-N3: el ScriptBlock debe ser autocontenido (solo cmdlets built-in, args
        explícitos via -ArgumentList). No puede hacer closure sobre el scope padre.
        T-N4: Stop()+Dispose() garantizan que el snapshot siga; NO garantizan que
        el hilo WMI nativo muera inmediatamente. Defensa primaria = VM-skip (§3a).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [Parameter(Mandatory)]
        [int] $TimeoutSeconds,

        [Parameter()]
        [object] $Default = $null,

        [Parameter()]
        [object[]] $ArgumentList = @()
    )

    $ps = $null
    try {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $null = $ps.AddScript($ScriptBlock.ToString())
        foreach ($arg in $ArgumentList) {
            $null = $ps.AddArgument($arg)
        }

        $async = $ps.BeginInvoke()
        if ($async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            try {
                $out = @($ps.EndInvoke($async))
                if ($out.Count -eq 1) { return $out[0] }
                return $out
            } catch {
                return $Default
            }
        } else {
            # Timeout: detener y retornar Default (T-N4: el hilo nativo puede seguir)
            try { $ps.Stop() } catch { }
            return $Default
        }
    } catch {
        return $Default
    } finally {
        if ($null -ne $ps) { $ps.Dispose() }
    }
}

# ─── Test-IsVirtualMachine ────────────────────────────────────────────────────
# Helper interno (T-N1): DEBE vivir en Telemetry.ps1. MachineProfile.ps1 tiene
# su propia detección thin con la misma lista de firmas (DD4 / T-N1 — duplicación
# intencional y acotada, mismo patrón que DeviceGuard inline).
function Test-IsVirtualMachine {
    <#
    .SYNOPSIS
        Detecta si el sistema corre en una máquina virtual usando firmas CIM.
        Retorna PSCustomObject @{ IsVirtual = [bool]; Vendor = [string] }.
        Defensivo: cualquier error → IsVirtual=$false (asumir físico).
    .PARAMETER ComputerSystem
        Win32_ComputerSystem ya consultado (opcional, evita re-query).
    .PARAMETER Bios
        Win32_BIOS ya consultado (opcional, evita re-query).
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [object] $ComputerSystem = $null,
        [Parameter()] [object] $Bios           = $null
    )

    try {
        if ($null -eq $ComputerSystem) {
            $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem `
                -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
        }
        if ($null -eq $Bios) {
            $Bios = Get-CimInstance -ClassName Win32_BIOS `
                -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
        }

        [string] $csManufacturer = if ($ComputerSystem) { [string]$ComputerSystem.Manufacturer } else { '' }
        [string] $csModel        = if ($ComputerSystem) { [string]$ComputerSystem.Model }        else { '' }
        [string] $biosManuf      = if ($Bios)           { [string]$Bios.Manufacturer }           else { '' }
        [string] $biosSerial     = if ($Bios)           { [string]$Bios.SerialNumber }           else { '' }
        [string] $biosVersion    = if ($Bios)           { [string]$Bios.Version }                else { '' }

        # ── Tabla de firmas §3a (case-insensitive) ─────────────────────────────
        # Hyper-V / Windows Sandbox
        if ($csModel -match '(?i)Virtual Machine' -and $csManufacturer -match '(?i)Microsoft') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Hyper-V' }
        }
        if ($csModel -match '(?i)Virtual Machine') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Hyper-V' }
        }

        # VMware
        if ($csManufacturer -match '(?i)VMware' -or $csModel -match '(?i)VMware' -or
            $biosManuf -match '(?i)VMware') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'VMware' }
        }

        # VirtualBox
        if ($csManufacturer -match '(?i)innotek' -or $csModel -match '(?i)VirtualBox' -or
            $biosManuf -match '(?i)VBOX' -or $biosVersion -match '(?i)VBOX') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'VirtualBox' }
        }

        # KVM/QEMU
        if ($csManufacturer -match '(?i)QEMU' -or
            $csModel -match '(?i)Standard PC \(Q35|(?i)KVM' -or
            $biosManuf -match '(?i)SeaBIOS') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'KVM/QEMU' }
        }

        # Xen
        if ($csManufacturer -match '(?i)Xen' -or $csModel -match '(?i)Xen') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Xen' }
        }

        # Parallels
        if ($csManufacturer -match '(?i)Parallels' -or $csModel -match '(?i)Parallels') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Parallels' }
        }

        # Fallback genérico — model matchea \bvirtual\b y ninguna firma anterior
        if ($csModel -match '(?i)\bvirtual\b') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Virtual' }
        }

        return [PSCustomObject]@{ IsVirtual = $false; Vendor = '' }

    } catch {
        # Defensivo: asumir físico ante incertidumbre
        return [PSCustomObject]@{ IsVirtual = $false; Vendor = '' }
    }
}

# ─── Get-SystemSnapshot ───────────────────────────────────────────────────────
function Get-SystemSnapshot {
    <#
    .SYNOPSIS
        Recopila el estado del sistema vía CIM/WMI y retorna un PSCustomObject estructurado.
        Garantía de partial-snapshot (§3c): SIEMPRE retorna aunque alguna query falle/timeout/skip.
        Campos nuevos: IsVirtualMachine, VmVendor, QueryTimings (§5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pre', 'Post')]
        [string] $Phase
    )

    # ── QueryTimings: hashtable para registrar ms / 'timeout' / 'skipped' por query ──
    [hashtable] $qt = @{}
    [System.Diagnostics.Stopwatch] $sw = [System.Diagnostics.Stopwatch]::new()

    # ── VM detection (usa Win32_ComputerSystem que consultamos de todos modos) ──
    # T-N1: Test-IsVirtualMachine esta definida en este mismo archivo.
    $csRaw = $null
    try {
        $sw.Restart()
        $csRaw = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 2 -ErrorAction SilentlyContinue
        $qt['Win32_ComputerSystem'] = [int] $sw.ElapsedMilliseconds
    } catch { $qt['Win32_ComputerSystem'] = 'timeout' }

    $vmInfo = Test-IsVirtualMachine -ComputerSystem $csRaw
    [bool]   $isVM    = $vmInfo.IsVirtual
    [string] $vmVendor = $vmInfo.Vendor

    # ── CPU (keep — CIM rapido) ──────────────────────────────────────────────
    $cpu = [PSCustomObject]@{ Name = 'Unknown'; Cores = 0; Threads = 0 }
    try {
        $sw.Restart()
        $cpuRaw = Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 2 -ErrorAction Stop | Select-Object -First 1
        $qt['Win32_Processor'] = [int] $sw.ElapsedMilliseconds
        if ($cpuRaw) {
            $cpu = [PSCustomObject]@{
                Name    = [string] $cpuRaw.Name.Trim()
                Cores   = [int]    $cpuRaw.NumberOfCores
                Threads = [int]    $cpuRaw.NumberOfLogicalProcessors
            }
        }
    } catch { $qt['Win32_Processor'] = 'timeout' }

    # ── GPU (keep — CIM rapido) ───────────────────────────────────────────────
    $gpus = @()
    try {
        $sw.Restart()
        $gpus = @(
            Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 2 -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{
                    Name          = [string] $_.Name
                    Type          = [string] $(if ($_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Radeon VII|Arc') { 'Dedicated' } else { 'Integrated' })
                    DriverVersion = [string] $_.DriverVersion
                }
            }
        )
        $qt['Win32_VideoController'] = [int] $sw.ElapsedMilliseconds
    } catch { $qt['Win32_VideoController'] = 'timeout' }

    # ── RAM total (reusar $csRaw ya consultado) ───────────────────────────────
    $ramTotalGb = if ($csRaw) { [math]::Round($csRaw.TotalPhysicalMemory / 1GB, 2) } else { [double]0 }

    # ── RAM slots (keep — CIM rapido) ─────────────────────────────────────────
    $ramSlots = @()
    try {
        $sw.Restart()
        $ramSlots = @(
            Get-CimInstance -ClassName Win32_PhysicalMemory -OperationTimeoutSec 2 -ErrorAction Stop |
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
        $qt['Win32_PhysicalMemory'] = [int] $sw.ElapsedMilliseconds
    } catch { $qt['Win32_PhysicalMemory'] = 'timeout' }

    # ── Discos físicos (keep — Get-PhysicalDisk anda en VM) ───────────────────
    # SMART (Get-StorageReliabilityCounter) skip en VM (§3d): cuelga en disco virtual.
    $diskList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $sw.Restart()
    $physDisks = Invoke-WithTimeout -TimeoutSeconds 10 -Default @() -ScriptBlock {
        @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    }
    $qt['Get-PhysicalDisk'] = [int] $sw.ElapsedMilliseconds
    foreach ($physDisk in @($physDisks)) {
        $tempC    = $null
        $wearPct  = $null
        $readErr  = $null
        $writeErr = $null
        if (-not $isVM) {
            # SMART solo en HW físico
            $sw.Restart()
            $rel = Invoke-WithTimeout -TimeoutSeconds 8 -Default $null -ScriptBlock {
                param($d)
                $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            } -ArgumentList @($physDisk)
            $qt['Get-StorageReliabilityCounter'] = [int] $sw.ElapsedMilliseconds
            if ($rel) {
                if ($null -ne $rel.PSObject.Properties['Temperature'] -and [int]$rel.Temperature -gt 0) {
                    $tempC = [int]$rel.Temperature
                }
                if ($null -ne $rel.PSObject.Properties['Wear'] -and $null -ne $rel.Wear) {
                    $wearPct = [int]$rel.Wear
                }
                $readErr  = if ($null -ne $rel.PSObject.Properties['ReadErrorsTotal'])  { $rel.ReadErrorsTotal  } else { $null }
                $writeErr = if ($null -ne $rel.PSObject.Properties['WriteErrorsTotal']) { $rel.WriteErrorsTotal } else { $null }
            }
        } else {
            $qt['Get-StorageReliabilityCounter'] = 'skipped'
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

    # ── Volumenes (keep — no se cuelga, base del Compare) ────────────────────
    $volumes = @()
    $sw.Restart()
    $volumes = Invoke-WithTimeout -TimeoutSeconds 5 -Default @() -ScriptBlock {
        @(
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
    }
    $qt['Get-Volume'] = [int] $sw.ElapsedMilliseconds

    # ── Page File (keep — CIM rapido) ─────────────────────────────────────────
    [PSCustomObject] $pageFile = [PSCustomObject]@{ CurrentUsageMb = $null; PeakUsageMb = $null }
    try {
        $sw.Restart()
        [object] $pfRaw = Get-CimInstance -ClassName Win32_PageFileUsage -OperationTimeoutSec 2 -ErrorAction Stop
        $qt['Win32_PageFileUsage'] = [int] $sw.ElapsedMilliseconds
        $pageFile = [PSCustomObject]@{
            CurrentUsageMb = if ($pfRaw) { [int]$pfRaw.CurrentUsage } else { $null }
            PeakUsageMb    = if ($pfRaw) { [int]$pfRaw.PeakUsage }    else { $null }
        }
    } catch { $qt['Win32_PageFileUsage'] = 'timeout' }

    # ── Servicios (keep — base del Compare) ───────────────────────────────────
    [string[]] $bloatNames = @(
        'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
        'Spooler', 'PrintNotify', 'Fax', 'WMPNetworkSvc',
        'RemoteRegistry', 'RemoteAccess', 'DiagTrack', 'dmwappushservice'
    )
    [PSCustomObject] $services = [PSCustomObject]@{ RunningCount = 0; BloatRunning = [string[]]@() }
    $sw.Restart()
    $svcResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default $null -ScriptBlock {
        param([string[]] $bNames)
        $running = @(Get-Service | Where-Object { $_.Status -eq 'Running' })
        $bloat   = @($running | Where-Object { $_.Name -in $bNames } | Select-Object -ExpandProperty Name)
        [PSCustomObject]@{ RunningCount = [int]$running.Count; BloatRunning = [string[]]$bloat }
    } -ArgumentList @(,$bloatNames)
    $qt['Get-Service'] = [int] $sw.ElapsedMilliseconds
    if ($null -ne $svcResult) { $services = $svcResult }

    # ── Startup (keep — registry, rapido) ─────────────────────────────────────
    [int] $startupCount = 0
    try {
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
    } catch { }

    # ── Top procesos (keep) ───────────────────────────────────────────────────
    [PSCustomObject[]] $topProcs = @()
    $sw.Restart()
    $procsResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default @() -ScriptBlock {
        @(
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
    }
    $qt['Get-Process'] = [int] $sw.ElapsedMilliseconds
    $topProcs = @($procsResult)

    # ── Chassis / Batería ─────────────────────────────────────────────────────
    # Chassis: keep (CIM rapido). Batería: skip en VM (§3d).
    [PSCustomObject] $battery = $null
    $encRaw = $null
    try {
        $sw.Restart()
        $encRaw = Get-CimInstance -ClassName Win32_SystemEnclosure -OperationTimeoutSec 2 -ErrorAction Stop
        $qt['Win32_SystemEnclosure'] = [int] $sw.ElapsedMilliseconds
    } catch { $qt['Win32_SystemEnclosure'] = 'timeout' }

    [int] $chassisType = if ($encRaw -and $encRaw.ChassisTypes.Count -gt 0) { [int]$encRaw.ChassisTypes[0] } else { 0 }
    if (-not $isVM -and $chassisType -in @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)) {
        try {
            $sw.Restart()
            [object] $bat = Get-CimInstance -ClassName Win32_Battery -OperationTimeoutSec 2 -ErrorAction Stop
            $qt['Win32_Battery'] = [int] $sw.ElapsedMilliseconds
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
        } catch { $qt['Win32_Battery'] = 'timeout' }
    } else {
        if ($isVM) { $qt['Win32_Battery'] = 'skipped' }
    }

    # ── Antivirus — SecurityCenter2 (skip en VM) + Defender (skip en VM) ─────
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
    if (-not $isVM) {
        try {
            $sw.Restart()
            foreach ($av in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct `
                              -OperationTimeoutSec 5 -ErrorAction Stop)) {
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
            $qt['root/SecurityCenter2'] = [int] $sw.ElapsedMilliseconds
        } catch { $qt['root/SecurityCenter2'] = 'timeout' }

        # Defender
        $sw.Restart()
        $defResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default $null -ScriptBlock {
            Get-MpComputerStatus -ErrorAction Stop
        }
        $qt['Get-MpComputerStatus'] = [int] $sw.ElapsedMilliseconds
        if ($null -ne $defResult) {
            # AMRunningMode: 'Normal' | 'Passive Mode' | 'SxS Passive Mode' |
            # 'EDR Block Mode'. Solo 'Normal' significa que Defender esta
            # escaneando en tiempo real; los modos pasivos son explicitos
            # "otro AV se hizo cargo".
            [string] $runningMode = ''
            if ($null -ne $defResult.PSObject.Properties['AMRunningMode']) {
                $runningMode = [string] $defResult.AMRunningMode
            }
            [bool] $defEnabled = [bool] $defResult.AntivirusEnabled
            [bool] $defActive  = $defEnabled -and ($runningMode -eq 'Normal' -or [string]::IsNullOrEmpty($runningMode))
            $avList.Add([PSCustomObject]@{
                Name           = 'Windows Defender'
                Enabled        = $defEnabled
                IsActive       = $defActive
                IsNative       = [bool] $true
                AMRunningMode  = $runningMode
            })
        }
    } else {
        $qt['root/SecurityCenter2']  = 'skipped'
        $qt['Get-MpComputerStatus']  = 'skipped'
    }

    # ── Temperatura CPU + Thermal zones — DEDUPE: 1 sola query, derivar ambos campos ──
    # Skip en VM (§3d): sin ACPI thermal en VM.
    [object] $cpuTempC = $null
    [PSCustomObject[]] $thermalZones = @()
    if (-not $isVM) {
        try {
            $sw.Restart()
            [object[]] $zones = @(
                Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature `
                    -OperationTimeoutSec 5 -ErrorAction Stop
            )
            $qt['MSAcpi_ThermalZoneTemperature'] = [int] $sw.ElapsedMilliseconds
            if ($zones.Count -gt 0) {
                $cpuTempC = [math]::Round(($zones[0].CurrentTemperature - 2732) / 10.0, 1)
                $thermalZones = @(
                    $zones | ForEach-Object {
                        [PSCustomObject]@{
                            Zone  = [string] $_.InstanceName
                            TempC = [double] [math]::Round(($_.CurrentTemperature - 2732) / 10.0, 1)
                        }
                    }
                )
            }
        } catch { $qt['MSAcpi_ThermalZoneTemperature'] = 'timeout' }
    } else {
        $qt['MSAcpi_ThermalZoneTemperature'] = 'skipped'
    }

    # ── Uptime (keep — CIM rapido) ─────────────────────────────────────────────
    [double] $uptimeHours = 0
    try {
        $sw.Restart()
        [object] $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 2 -ErrorAction Stop
        $qt['Win32_OperatingSystem'] = [int] $sw.ElapsedMilliseconds
        if ($os) { $uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) }
    } catch { $qt['Win32_OperatingSystem'] = 'timeout' }

    # ── Multiple AV ───────────────────────────────────────────────────────────
    [bool] $multipleAv = (@($avList | Where-Object { $_.IsActive }).Count -gt 1)

    # ── Device Guard / VBS / HVCI status (inline, sin dependency externa) ─────
    # Se inlinea aca en lugar de llamar a Get-CoreIsolationStatus porque
    # Start-TelemetryJob solo dot-sourcea Telemetry.ps1 en el job runspace.
    # keep en VM (DeviceGuard puede estar configurado incluso en VM).
    [PSCustomObject] $deviceGuard = $null
    try {
        $sw.Restart()
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                              -ClassName Win32_DeviceGuard -OperationTimeoutSec 2 -ErrorAction Stop
        $qt['Win32_DeviceGuard'] = [int] $sw.ElapsedMilliseconds
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
                VbsConfigured          = ($vbsStatus -ge 1)
                VbsRunning             = ($vbsStatus -eq 2)
                HvciRunning            = ($svcRunning -contains 2)
                CredentialGuardRunning = ($svcRunning -contains 1)
            }
        }
    } catch { $qt['Win32_DeviceGuard'] = 'timeout' }

    # ── USB + HID devices (skip en VM — §3d) ─────────────────────────────────
    [PSCustomObject[]] $usbDevices = @()
    [PSCustomObject[]] $hidDevices = @()
    if (-not $isVM) {
        $sw.Restart()
        $usbResult = Invoke-WithTimeout -TimeoutSeconds 6 -Default @() -ScriptBlock {
            @(
                Get-PnpDevice -Class USB -Status OK -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [PSCustomObject]@{
                            FriendlyName = [string] $_.FriendlyName
                            InstanceId   = [string] $_.InstanceId
                        }
                    }
            )
        }
        $qt['Get-PnpDevice-USB'] = [int] $sw.ElapsedMilliseconds
        $usbDevices = @($usbResult)

        $sw.Restart()
        $hidResult = Invoke-WithTimeout -TimeoutSeconds 6 -Default @() -ScriptBlock {
            @(
                Get-PnpDevice -Class HIDClass -Status OK -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [PSCustomObject]@{
                            FriendlyName = [string] $_.FriendlyName
                            Manufacturer = [string] $_.Manufacturer
                        }
                    }
            )
        }
        $qt['Get-PnpDevice-HID'] = [int] $sw.ElapsedMilliseconds
        $hidDevices = @($hidResult)
    } else {
        $qt['Get-PnpDevice-USB'] = 'skipped'
        $qt['Get-PnpDevice-HID'] = 'skipped'
    }

    # ── DNS servers IPv4 por adapter activo (keep) ────────────────────────────
    [hashtable] $dnsServers = @{}
    $sw.Restart()
    $dnsResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default $null -ScriptBlock {
        $h = @{}
        foreach ($entry in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
                              Where-Object { $_.AddressFamily -eq 2 -and $_.ServerAddresses.Count -gt 0 })) {
            $h[$entry.InterfaceAlias] = [string[]] @($entry.ServerAddresses)
        }
        $h
    }
    $qt['Get-DnsClientServerAddress'] = [int] $sw.ElapsedMilliseconds
    if ($null -ne $dnsResult) { $dnsServers = $dnsResult }

    # ── Programas instalados (keep) ───────────────────────────────────────────
    # Filter regex matches OEM utilities, drivers, dev tools, gaming clients,
    # browsers, hardware monitors — todo lo que un tecnico de service quiere ver.
    [string] $vendorFilter = 'AMD|NVIDIA|Intel|Steam|Discord|Chrome|Edge|Firefox|HP|Lenovo|Dell|Asus|MSI|Logitech|Razer|Realtek|Visual Studio|Office|WhatsApp|OBS|7-Zip|WinRAR|Notepad\+\+|Git for|Docker|Python|Node|VLC|Spotify|Adobe'
    [PSCustomObject[]] $installedRelevant = @()
    $sw.Restart()
    $installedResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default @() -ScriptBlock {
        param([string] $vFilter)
        [string[]] $hives = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        @(
            Get-ItemProperty $hives -ErrorAction SilentlyContinue |
                Where-Object {
                    $null -ne $_.PSObject.Properties['DisplayName'] -and
                    -not [string]::IsNullOrWhiteSpace($_.DisplayName) -and
                    $_.DisplayName -match $vFilter
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
    } -ArgumentList @($vendorFilter)
    $qt['InstalledPrograms'] = [int] $sw.ElapsedMilliseconds
    $installedRelevant = @($installedResult)

    # ── Steam / CS2 detection + cfg parsing (keep — condicional) ─────────────
    [PSCustomObject] $steam = $null
    $sw.Restart()
    $steamResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default $null -ScriptBlock {
        try {
            $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
            if ($null -eq $reg -or $null -eq $reg.PSObject.Properties['InstallPath']) { return $null }
            [string] $sp = [string] $reg.InstallPath
            [string] $cs2p = Join-Path $sp 'steamapps\common\Counter-Strike Global Offensive'
            [bool] $cs2i = Test-Path -Path $cs2p -PathType Container

            [string[]] $autoLines = @()
            if ($cs2i) {
                [string] $aePath = Join-Path $cs2p 'game\csgo\cfg\autoexec.cfg'
                if (Test-Path $aePath) {
                    $autoLines = @(Get-Content -LiteralPath $aePath -ErrorAction SilentlyContinue)
                }
            }

            [string] $launchOpts = ''
            [string] $udDir = Join-Path $sp 'userdata'
            if (Test-Path $udDir) {
                foreach ($uDir in @(Get-ChildItem -Path $udDir -Directory -ErrorAction SilentlyContinue)) {
                    [string] $lcfg = Join-Path $uDir.FullName 'config\localconfig.vdf'
                    if (Test-Path $lcfg) {
                        [string] $raw = Get-Content -LiteralPath $lcfg -Raw -ErrorAction SilentlyContinue
                        if ($raw -match '"730"\s*\{[^}]*"LaunchOptions"\s*"([^"]*)"') {
                            $launchOpts = $Matches[1]
                            break
                        }
                    }
                }
            }

            [PSCustomObject]@{
                Installed        = $true
                Path             = $sp
                Cs2Installed     = $cs2i
                Cs2Path          = if ($cs2i) { $cs2p } else { '' }
                AutoexecLines    = $autoLines
                Cs2LaunchOptions = $launchOpts
            }
        } catch { $null }
    }
    $qt['Steam'] = [int] $sw.ElapsedMilliseconds
    $steam = $steamResult

    # ── Power plan activo (keep) ──────────────────────────────────────────────
    # El header de "powercfg /getactivescheme" varia por locale:
    #   en-US: "Power Scheme GUID:"
    #   es-AR: "GUID de plan de energía:"  (NO "esquema" como en versiones viejas)
    #   pt-BR: "GUID do Esquema de Energia:"
    # En vez de listar todas, usamos regex agnostico al idioma que matchea el
    # formato comun: cualquier texto antes de ":" seguido del GUID con paren.
    [PSCustomObject] $powerPlan = $null
    $sw.Restart()
    $ppResult = Invoke-WithTimeout -TimeoutSeconds 5 -Default $null -ScriptBlock {
        try {
            [string] $out = (& powercfg /getactivescheme 2>&1) -join "`n"
            [string] $guid = ''
            [string] $name = ''
            if ($out -match ':\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\(([^)]+)\)') {
                $guid = $Matches[1]
                $name = $Matches[2].Trim()
            }
            [PSCustomObject]@{ ActiveGuid = $guid; ActiveName = $name }
        } catch { $null }
    }
    $qt['powercfg'] = [int] $sw.ElapsedMilliseconds
    $powerPlan = $ppResult

    # ── Retorno garantizado (§3c: partial-snapshot invariant) ─────────────────
    # T-N2: shape invariante — NUNCA renombrar ni remover campos existentes.
    # Campos nuevos agregados al final.
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
        # ── Campos nuevos snapshot-vm-plan §5 ─────────────────────────────────
        IsVirtualMachine  = [bool]      $isVM
        VmVendor          = [string]    $vmVendor
        QueryTimings      = [hashtable] $qt
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
