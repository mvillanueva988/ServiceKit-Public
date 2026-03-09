# ServiceKit - Recopilacion info sistema COMPLETA
# @Mateo Villanueva
# Version: 1.0

param(
    [switch]$Debug,
    [switch]$Post
)

$ErrorActionPreference = if ($Debug) { "Continue" } else { "SilentlyContinue" }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SERVICEKIT - Recopilacion Sistema" -ForegroundColor Cyan
if ($Debug) {
    Write-Host "  [DEBUG MODE ENABLED]" -ForegroundColor Yellow
}
Write-Host "  @Mateo Villanueva" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$computerName = $env:COMPUTERNAME

# ============================================================
# HARDWARE - PowerShell nativo
# ============================================================

Write-Host "[1/20] Recopilando hardware info..." -ForegroundColor Yellow

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram_slots = Get-CimInstance Win32_PhysicalMemory
$ram_total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
# Priorizar GPU dedicada (NVIDIA/AMD RX)
$gpus_all = Get-CimInstance Win32_VideoController
$gpus_data = @()

foreach ($gpu_item in $gpus_all) {
    # Determinar tipo (integrada vs dedicada)
    $is_dedicated = $gpu_item.Name -match "NVIDIA|GeForce|RTX|GTX|Radeon RX|Radeon VII|Arc"
    $gpu_type = if ($is_dedicated) { "Dedicated" } else { "Integrated" }
    
    $gpus_data += @{
        name = $gpu_item.Name
        type = $gpu_type
        vram_bytes = $gpu_item.AdapterRAM
        vram_gb = [math]::Round($gpu_item.AdapterRAM / 1GB, 2)
        driver_version = $gpu_item.DriverVersion
        driver_date = $gpu_item.DriverDate
    }
}
$disks = Get-PhysicalDisk
$volumes = Get-Volume | Where-Object {$_.DriveLetter -ne $null}
$mobo = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS

$hardware = @{
    cpu = @{
        name = $cpu.Name.Trim()
        manufacturer = $cpu.Manufacturer
        cores = $cpu.NumberOfCores
        threads = $cpu.NumberOfLogicalProcessors
        base_clock_mhz = $cpu.MaxClockSpeed
        current_clock_mhz = $cpu.CurrentClockSpeed
        architecture = switch ($cpu.AddressWidth) {
            64 { "x64" }
            32 { "x86" }
            default { "Unknown" }
        }
    }
    ram = @{
        total_gb = [math]::Round($ram_total / 1GB, 2)
        slots = @()
    }
    gpus = $gpus_data
    storage = @()
    motherboard = @{
        manufacturer = $mobo.Manufacturer
        model = $mobo.Product
        serial = $mobo.SerialNumber
    }
    bios = @{
        manufacturer = $bios.Manufacturer
        version = $bios.SMBIOSBIOSVersion
        release_date = $bios.ReleaseDate
    }
}

# RAM slots
foreach ($slot in $ram_slots) {
    $hardware.ram.slots += @{
        device_locator = $slot.DeviceLocator
        manufacturer = $slot.Manufacturer
        part_number = $slot.PartNumber
        capacity_gb = [math]::Round($slot.Capacity / 1GB, 2)
        speed_mhz = $slot.Speed
        configured_speed_mhz = $slot.ConfiguredClockSpeed
    }
}

# Storage
foreach ($disk in $disks) {
    $reliability = $disk | Get-StorageReliabilityCounter
    
    $hardware.storage += @{
        friendly_name = $disk.FriendlyName
        media_type = $disk.MediaType
        bus_type = $disk.BusType
        size_gb = [math]::Round($disk.Size / 1GB, 2)
        health_status = $disk.HealthStatus
        operational_status = $disk.OperationalStatus
        temperature_c = $reliability.Temperature
        wear_percent = $reliability.Wear
        read_errors = $reliability.ReadErrorsTotal
        write_errors = $reliability.WriteErrorsTotal
    }
}

# ============================================================
# TEMPERATURAS AVANZADAS - Manual monitoring
# ============================================================

Write-Host "[2/20] Temperaturas avanzadas..." -ForegroundColor Yellow
Write-Host "  NOTA: HWiNFO CLI requiere version PRO (paga)" -ForegroundColor Gray
Write-Host "  Para temperaturas: Ejecutar HWiNFO64.exe manual desde menu" -ForegroundColor Gray

# Placeholder vacÃ­o para mantener estructura JSON
$hwinfo_data = @{
    temperatures = @{
        note = "HWiNFO CLI no disponible en version gratuita. Ver temperaturas con opcion 14 del menu."
    }
    voltages = @()
    throttling = @()
}

# ============================================================
# WINDOWS
# ============================================================

Write-Host "[3/20] Recopilando info Windows..." -ForegroundColor Yellow

$os = Get-CimInstance Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime

$license = Get-CimInstance SoftwareLicensingProduct | 
    Where-Object {$_.PartialProductKey -and $_.Name -like "*Windows*"} |
    Select-Object -First 1

$windows = @{
    caption = $os.Caption
    version = $os.Version
    build = $os.BuildNumber
    architecture = $os.OSArchitecture
    activation_status = switch ($license.LicenseStatus) {
        0 { "Unlicensed" }
        1 { "Licensed" }
        2 { "OOBGrace" }
        3 { "OOTGrace" }
        4 { "NonGenuineGrace" }
        5 { "Notification" }
        6 { "ExtendedGrace" }
        default { "Unknown" }
    }
    install_date = $os.InstallDate
    last_boot = $os.LastBootUpTime
    uptime_hours = [math]::Round($uptime.TotalHours, 1)
}

# ============================================================
# DRIVERS
# ============================================================

Write-Host "[4/20] Recopilando drivers criticos..." -ForegroundColor Yellow

$all_drivers = Get-WindowsDriver -Online -All

# Filtrar solo drivers criticos
$critical_classes = @("Display", "MEDIA", "Net", "HDC", "System")
$drivers_critical = $all_drivers | Where-Object {$_.ClassName -in $critical_classes}

$drivers = @{
    total_count = $all_drivers.Count
    critical = @()
}

foreach ($drv in $drivers_critical) {
    $age_days = ((Get-Date) - $drv.Date).Days
    
    $drivers.critical += @{
        driver_name = $drv.Driver
        class_name = $drv.ClassName
        provider_name = $drv.ProviderName
        version = $drv.Version
        date = $drv.Date
        age_days = $age_days
        is_old = ($age_days -gt 365)
    }
}

# Devices con problemas
$problem_devices = Get-PnpDevice | Where-Object {$_.Status -ne "OK"}
$drivers.problem_devices = @()

foreach ($dev in $problem_devices) {
    $drivers.problem_devices += @{
        name = $dev.FriendlyName
        status = $dev.Status
        class = $dev.Class
    }
}

# ============================================================
# SERVICIOS
# ============================================================

Write-Host "[5/20] Analizando servicios..." -ForegroundColor Yellow

$services_all = Get-Service
$services_running = $services_all | Where-Object {$_.Status -eq "Running"}

$bloat_services = @(
    "XblAuthManager", "XblGameSave", "XboxNetApiSvc", "XboxGipSvc",
    "Spooler", "PrintNotify",
    "Fax", "WMPNetworkSvc",
    "RemoteRegistry", "RemoteAccess",
    "DiagTrack", "dmwappushservice"
)

$bloat_running = $services_running | Where-Object {$_.Name -in $bloat_services}

$services = @{
    total = $services_all.Count
    running = $services_running.Count
    bloat_detected = $bloat_running.Count
    bloat_list = @()
}

foreach ($svc in $bloat_running) {
    $services.bloat_list += @{
        name = $svc.Name
        display_name = $svc.DisplayName
        status = $svc.Status
    }
}

# ============================================================
# STARTUP PROGRAMS
# ============================================================

Write-Host "[6/20] Recopilando startup programs..." -ForegroundColor Yellow

$startup = @{
    registry = @()
    folder = @()
    tasks = @()
}

# Registry Run keys
$run_keys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)

foreach ($key in $run_keys) {
    if (Test-Path $key) {
        $props = Get-ItemProperty $key
        $props.PSObject.Properties | Where-Object {$_.Name -notlike "PS*"} | ForEach-Object {
            $startup.registry += @{
                name = $_.Name
                command = $_.Value
                location = $key
            }
        }
    }
}

# Startup folders
$startup_folders = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)

foreach ($folder in $startup_folders) {
    if (Test-Path $folder) {
        Get-ChildItem $folder | ForEach-Object {
            $startup.folder += @{
                name = $_.Name
                path = $_.FullName
            }
        }
    }
}

# Scheduled Tasks (startup type)
$tasks = Get-ScheduledTask | Where-Object {
    $_.Settings.Enabled -and 
    $_.Triggers.Enabled -and
    ($_.Triggers.CimClass.CimClassName -like "*LogonTrigger*" -or 
     $_.Triggers.CimClass.CimClassName -like "*BootTrigger*")
}

foreach ($task in $tasks) {
    $startup.tasks += @{
        name = $task.TaskName
        path = $task.TaskPath
        state = $task.State
    }
}

$startup.total = $startup.registry.Count + $startup.folder.Count + $startup.tasks.Count

# ============================================================
# NETWORK
# ============================================================

Write-Host "[7/20] Recopilando info red..." -ForegroundColor Yellow

$adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
$active_adapter = $adapters | Select-Object -First 1

if ($active_adapter) {
    $ip_config = Get-NetIPConfiguration | Where-Object {$_.InterfaceAlias -eq $active_adapter.Name}
    $dns_servers = (Get-DnsClientServerAddress -InterfaceAlias $active_adapter.Name -AddressFamily IPv4).ServerAddresses

    $network = @{
        active_adapter = $active_adapter.Name
        mac_address = $active_adapter.MacAddress
        link_speed = $active_adapter.LinkSpeed
        ip_address = ($ip_config.IPv4Address).IPAddress
        gateway = ($ip_config.IPv4DefaultGateway).NextHop
        dns_servers = $dns_servers
    }

    # Test connectivity
    $connectivity_test = Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Quiet
    $network.connectivity_ok = $connectivity_test
} else {
    $network = @{
        active_adapter = "None"
        connectivity_ok = $false
    }
}

# ============================================================
# POWER (Notebooks)
# ============================================================

Write-Host "[8/20] Verificando info energia..." -ForegroundColor Yellow

$chassis_type = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes[0]
$is_laptop = $chassis_type -in @(8,9,10,11,12,14,18,21,30,31,32)

if ($is_laptop) {
    $battery = Get-CimInstance Win32_Battery
    $power_plan_raw = powershell /getactivescheme
    $power_plan_name = if ($power_plan_raw) { ($power_plan_raw -split '\(')[1] -replace '\)','' } else { "Unknown" }
    
    $power = @{
        is_laptop = $true
        active_plan = $power_plan_name
        battery = @{
            name = $battery.Name
            status = switch ($battery.BatteryStatus) {
                1 { "Discharging" }
                2 { "AC" }
                3 { "Fully Charged" }
                4 { "Low" }
                5 { "Critical" }
                default { "Unknown" }
            }
            charge_percent = $battery.EstimatedChargeRemaining
            design_capacity = $battery.DesignCapacity
            full_charge_capacity = $battery.FullChargeCapacity
            health_percent = if ($battery.DesignCapacity -gt 0) {
                [math]::Round(($battery.FullChargeCapacity / $battery.DesignCapacity) * 100, 1)
            } else { 0 }
        }
    }
} else {
    $power = @{
        is_laptop = $false
    }
}

# ============================================================
# EVENT LOG
# ============================================================

Write-Host "[9/20] Analizando Event Log..." -ForegroundColor Yellow

$event_errors = Get-WinEvent -FilterHashtable @{
    LogName = 'System', 'Application'
    Level = 1,2
    StartTime = (Get-Date).AddDays(-7)
} -MaxEvents 100 -ErrorAction SilentlyContinue

$event_summary = $event_errors | Group-Object ProviderName | 
    Select-Object Count, Name | 
    Sort-Object Count -Descending |
    Select-Object -First 10

$event_log = @{
    critical_7days = ($event_errors | Where-Object {$_.Level -eq 1}).Count
    errors_7days = ($event_errors | Where-Object {$_.Level -eq 2}).Count
    top_sources = @()
}

foreach ($source in $event_summary) {
    $event_log.top_sources += @{
        source = $source.Name
        count = $source.Count
    }
}

# ============================================================
# STORAGE DETAILED
# ============================================================

Write-Host "[10/20] Analizando storage..." -ForegroundColor Yellow

$storage_detailed = @()

# Obtener volÃºmenes frescos, excluir particiones system/recovery
$volumes = Get-Volume | Where-Object {
    $_.DriveLetter -ne $null -and 
    $_.DriveType -eq 'Fixed' -and
    $_.FileSystem -ne 'FAT32'  # Excluir EFI partition
}

foreach ($vol in $volumes) {
    # Forzar refresh del objeto antes de leer
    $vol = Get-Volume -DriveLetter $vol.DriveLetter
    
    $size_gb = [math]::Round($vol.Size / 1GB, 2)
    $free_gb = [math]::Round($vol.SizeRemaining / 1GB, 2)
    $used_gb = $size_gb - $free_gb
    $used_percent = if ($size_gb -gt 0) {
        [math]::Round(($used_gb / $size_gb) * 100, 1)
    } else { 0 }
    
    $storage_detailed += @{
        drive_letter = $vol.DriveLetter
        label = $vol.FileSystemLabel
        filesystem = $vol.FileSystem
        size_gb = $size_gb
        used_gb = $used_gb
        free_gb = $free_gb
        used_percent = $used_percent
        health = $vol.HealthStatus
    }
}

# ============================================================
# INSTALLED APPLICATIONS
# ============================================================

Write-Host "[11/20] Recopilando aplicaciones instaladas..." -ForegroundColor Yellow

$apps_64 = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
    Where-Object {$_.DisplayName} |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, EstimatedSize

$apps_32 = Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
    Where-Object {$_.DisplayName} |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, EstimatedSize

$all_apps = ($apps_64 + $apps_32) | Sort-Object DisplayName -Unique

# Bloatware detection
$bloatware_patterns = @(
    @{name="CCleaner"; reason="Agresivo, modifica registry, innecesario en Windows moderno"},
    @{name="McAfee"; reason="Preinstalado OEM, dificil desinstalar, consume recursos"},
    @{name="Norton"; reason="Consume muchos recursos, dificil remover completamente"},
    @{name="Avast Free"; reason="Adware agresivo, telemetria excesiva"},
    @{name="AVG Free"; reason="Adware agresivo, telemetria excesiva"},
    @{name="PC Cleaner"; reason="Scareware, falsos positivos"},
    @{name="Driver Booster"; reason="Instala drivers incorrectos, causa problemas"},
    @{name="Advanced SystemCare"; reason="Registry cleaner agresivo, falsos positivos"},
    @{name="Chromium"; reason="Si no instalado por usuario, probablemente malware"},
    @{name="Conduit"; reason="Toolbar/adware"},
    @{name="Ask Toolbar"; reason="Toolbar/adware"}
)

$bloatware_detected = @()
foreach ($pattern in $bloatware_patterns) {
    $matches = $all_apps | Where-Object {$_.DisplayName -like "*$($pattern.name)*"}
    foreach ($match in $matches) {
        $bloatware_detected += @{
            name = $match.DisplayName
            publisher = $match.Publisher
            reason = $pattern.reason
        }
    }
}

$applications = @{
    total_count = $all_apps.Count
    bloatware_detected = $bloatware_detected
    bloatware_count = $bloatware_detected.Count
    top_largest = @()
}

# Top 10 apps mas grandes
$largest = $all_apps | 
    Where-Object {$_.EstimatedSize -gt 0} |
    Sort-Object EstimatedSize -Descending |
    Select-Object -First 10

foreach ($app in $largest) {
    $applications.top_largest += @{
        name = $app.DisplayName
        size_mb = [math]::Round($app.EstimatedSize / 1024, 1)
        publisher = $app.Publisher
    }
}

# ============================================================
# ANTIVIRUS / SECURITY
# ============================================================

Write-Host "[12/20] Detectando software antivirus..." -ForegroundColor Yellow

$antivirus_products = @()

# SecurityCenter2 (third party antivirus)
try {
    $av_wmi = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
    foreach ($av in $av_wmi) {
        # Parse hex state para determinar enabled/disabled
        $hex = [Convert]::ToString($av.productState, 16).PadLeft(6, '0')
        $enabled = $hex.Substring(2,2) -eq "10"
        
        $antivirus_products += @{
            name = $av.displayName
            publisher = if ($av.pathToSignedReportingExe) { Split-Path $av.pathToSignedReportingExe -Parent } else { "Unknown" }
            state = if ($enabled) { "Enabled" } else { "Disabled" }
            state_code = $av.productState
        }
    }
} catch {
    Write-Host "  ADVERTENCIA: No se pudo acceder SecurityCenter2" -ForegroundColor Red
}

# Windows Defender
try {
    $defender = Get-MpComputerStatus -ErrorAction Stop
    $antivirus_products += @{
        name = "Windows Defender"
        publisher = "Microsoft"
        state = if ($defender.AntivirusEnabled) { "Enabled" } else { "Disabled" }
        realtime_protection = $defender.RealTimeProtectionEnabled
        definitions_updated = $defender.AntivirusSignatureLastUpdated
    }
} catch {
    Write-Host "  ADVERTENCIA: No se pudo leer estado Windows Defender" -ForegroundColor Red
}

$security = @{
    antivirus_count = $antivirus_products.Count
    antivirus_products = $antivirus_products
    multiple_av_problem = ($antivirus_products.Count -gt 1)
}

# ============================================================
# PAGE FILE
# ============================================================

Write-Host "[13/20] Analizando Page File..." -ForegroundColor Yellow

$pagefile_settings = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
$pagefile_usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue

if ($pagefile_settings) {
    $pf_type = if ($pagefile_settings.InitialSize -eq 0 -and $pagefile_settings.MaximumSize -eq 0) {
        "System managed"
    } else {
        "Custom"
    }
    
    $pagefile = @{
        exists = $true
        type = $pf_type
        location = $pagefile_settings.Name
        initial_size_mb = $pagefile_settings.InitialSize
        max_size_mb = $pagefile_settings.MaximumSize
        current_usage_mb = if ($pagefile_usage) { $pagefile_usage.CurrentUsage } else { 0 }
        peak_usage_mb = if ($pagefile_usage) { $pagefile_usage.PeakUsage } else { 0 }
    }
} else {
    $pagefile = @{
        exists = $false
        type = "Disabled"
        warning = "Page file deshabilitado - puede causar crashes si RAM se llena"
    }
}

# ============================================================
# WINDOWS UPDATE STATUS
# ============================================================

Write-Host "[14/20] Verificando Windows Update..." -ForegroundColor Yellow
Write-Host "  NOTA: Puede tardar 30-60 segundos si WU service lento..." -ForegroundColor Gray

# Ultimo hotfix instalado
$last_update = Get-HotFix | 
    Sort-Object InstalledOn -Descending | 
    Select-Object -First 1

$days_since_update = if ($last_update.InstalledOn) {
    ((Get-Date) - $last_update.InstalledOn).Days
} else {
    999
}

# Verificar si Windows Update service esta corriendo
$wu_service = Get-Service wuauserv

# Intentar detectar updates pendientes (requiere permisos)
$pending_updates = "Unknown"
try {
    $update_session = New-Object -ComObject Microsoft.Update.Session
    $update_searcher = $update_session.CreateUpdateSearcher()
    $search_result = $update_searcher.Search("IsInstalled=0")
    $pending_updates = $search_result.Updates.Count
} catch {
    # Silenciar error si no hay permisos
}

$windows_update = @{
    last_update_kb = $last_update.HotFixID
    last_update_date = $last_update.InstalledOn
    days_since_last = $days_since_update
    service_status = $wu_service.Status
    pending_count = $pending_updates
    outdated = ($days_since_update -gt 60)
}

# ============================================================
# SYSTEM RESTORE
# ============================================================

Write-Host "[15/20] Verificando System Restore..." -ForegroundColor Yellow

$restore_points = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
$restore_enabled = $false

try {
    $vss = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop
    $restore_enabled = ($vss.Count -gt 0)
} catch {
    # Alternativa: check registry
    $sp_status = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name DisableSR -ErrorAction SilentlyContinue
    $restore_enabled = ($sp_status.DisableSR -eq 0)
}

$system_restore = @{
    enabled = $restore_enabled
    restore_points_count = if ($restore_points) { $restore_points.Count } else { 0 }
    newest_point = if ($restore_points) { 
        ($restore_points | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime 
    } else { 
        $null 
    }
}

# ============================================================
# FAST STARTUP
# ============================================================

Write-Host "[16/20] Verificando Fast Startup..." -ForegroundColor Yellow

$hiberboot = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue

$fast_startup = @{
    enabled = ($hiberboot.HiberbootEnabled -eq 1)
}

# ============================================================
# TPM + SECURE BOOT
# ============================================================

Write-Host "[17/20] Verificando TPM y Secure Boot..." -ForegroundColor Yellow

$tpm_info = Get-Tpm -ErrorAction SilentlyContinue
$secure_boot = $null

try {
    $secure_boot = Confirm-SecureBootUEFI -ErrorAction Stop
} catch {
    $secure_boot = $false
}

$tpm_version = "Unknown"
if ($tpm_info.ManufacturerVersion) {
    # Extraer version major (2.0, 1.2, etc)
    if ($tpm_info.ManufacturerVersion -match "^(\d+\.\d+)") {
        $tpm_version = $matches[1]
    }
}

$win11_requirements = @{
    tpm = @{
        present = $tpm_info.TpmPresent
        ready = $tpm_info.TpmReady
        enabled = $tpm_info.TpmEnabled
        version = $tpm_version
    }
    secure_boot = @{
        enabled = $secure_boot
    }
    win11_compatible = ($tpm_info.TpmPresent -and $tpm_info.TpmReady -and $secure_boot)
}

# ============================================================
# WINDOWS FEATURES
# ============================================================

Write-Host "[18/20] Verificando Windows Features..." -ForegroundColor Yellow

$features_enabled = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | 
    Where-Object {$_.State -eq "Enabled"}

$notable_features = @(
    "Microsoft-Hyper-V",
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform",
    "TelnetClient",
    "SMB1Protocol",
    "TFTP",
    "TIFFIFilter"
)

$features = @{
    total_enabled = $features_enabled.Count
    notable = @()
}

foreach ($feat_name in $notable_features) {
    $feat = $features_enabled | Where-Object {$_.FeatureName -eq $feat_name}
    if ($feat) {
        $note = switch ($feat_name) {
            "SMB1Protocol" { "SEGURIDAD - SMB1 es obsoleto y vulnerable, deshabilitar" }
            "TelnetClient" { "SEGURIDAD - Telnet es inseguro, usar SSH" }
            "Microsoft-Hyper-V" { "Virtualization habilitado" }
            "Microsoft-Windows-Subsystem-Linux" { "WSL habilitado" }
            default { "" }
        }
        
        $features.notable += @{
            name = $feat.DisplayName
            feature_name = $feat.FeatureName
            note = $note
        }
    }
}

# ============================================================
# ISSUES DETECTION
# ============================================================

Write-Host "[19/20] Detectando issues..." -ForegroundColor Yellow

$issues = @()

# BIOS antiguo
$bios_age_days = ((Get-Date) - $bios.ReleaseDate).Days
if ($bios_age_days -gt 730) {
    $issues += @{
        severity = "medium"
        category = "bios"
        description = "BIOS tiene $([math]::Round($bios_age_days/365, 1)) aÃ±os"
        recommendation = "Verificar actualizaciones BIOS para seguridad/estabilidad"
    }
}

# Drivers antiguos
$old_drivers = $drivers.critical | Where-Object {$_.is_old}
foreach ($drv in $old_drivers) {
    $issues += @{
        severity = "medium"
        category = "drivers"
        description = "$($drv.class_name) driver antiguo: $($drv.driver_name) ($([math]::Round($drv.age_days/365, 1)) aÃ±os)"
        recommendation = "Actualizar desde web fabricante"
    }
}

# Uptime alto
if ($windows.uptime_hours -gt 168) {
    $issues += @{
        severity = "low"
        category = "windows"
        description = "Uptime alto: $($windows.uptime_hours) horas sin reiniciar"
        recommendation = "Reiniciar para aplicar updates y liberar RAM"
    }
}

# Storage casi lleno
foreach ($vol in $storage_detailed) {
    if ($vol.used_percent -gt 85) {
        $issues += @{
            severity = "high"
            category = "storage"
            description = "Disco $($vol.drive_letter): $($vol.used_percent)% usado ($($vol.free_gb)GB libres)"
            recommendation = "Liberar espacio con Disk Cleanup o eliminar archivos"
        }
    }
}

# Servicios bloat
if ($services.bloat_detected -gt 0) {
    $issues += @{
        severity = "low"
        category = "services"
        description = "$($services.bloat_detected) servicios bloat corriendo"
        recommendation = "Deshabilitar servicios innecesarios"
    }
}

# Devices con problemas
if ($drivers.problem_devices.Count -gt 0) {
    $issues += @{
        severity = "high"
        category = "hardware"
        description = "$($drivers.problem_devices.Count) dispositivos con problemas en Device Manager"
        recommendation = "Revisar Device Manager y actualizar drivers"
    }
}

# Bloatware
if ($applications.bloatware_count -gt 0) {
    $bloat_names = ($applications.bloatware_detected | Select-Object -First 3 | ForEach-Object { $_.name }) -join ", "
    $issues += @{
        severity = "medium"
        category = "bloatware"
        description = "$($applications.bloatware_count) aplicaciones bloatware detectadas: $bloat_names..."
        recommendation = "Desinstalar usando BCU o Panel Control"
    }
}

# Multiples antivirus
if ($security.multiple_av_problem) {
    $av_list = ($security.antivirus_products | ForEach-Object { $_.name }) -join ", "
    $issues += @{
        severity = "high"
        category = "security"
        description = "Multiples antivirus instalados: $av_list"
        recommendation = "CRITICO - Desinstalar todos excepto uno. Causan conflictos y lentitud extrema"
    }
}

# Sin antivirus
if ($security.antivirus_count -eq 0) {
    $issues += @{
        severity = "critical"
        category = "security"
        description = "Sin antivirus detectado"
        recommendation = "URGENTE - Verificar Windows Defender. Sistema vulnerable"
    }
}

# Page file deshabilitado
if (-not $pagefile.exists) {
    $issues += @{
        severity = "high"
        category = "system"
        description = "Page file deshabilitado"
        recommendation = "Habilitar System managed page file para prevenir crashes"
    }
}

# Windows Update desactualizado
if ($windows_update.outdated) {
    $issues += @{
        severity = "high"
        category = "security"
        description = "Windows sin updates por $($windows_update.days_since_last) dias"
        recommendation = "Ejecutar Windows Update inmediatamente - vulnerabilidades conocidas"
    }
}

# System Restore deshabilitado
if (-not $system_restore.enabled) {
    $issues += @{
        severity = "medium"
        category = "system"
        description = "System Restore deshabilitado"
        recommendation = "Habilitar para poder hacer rollback si algo sale mal"
    }
}

# Fast Startup ON (informativo)
if ($fast_startup.enabled) {
    $issues += @{
        severity = "info"
        category = "system"
        description = "Fast Startup habilitado"
        recommendation = "Considerar deshabilitar si cliente reporta problemas USB o dual boot"
    }
}

# SMB1 habilitado
$smb1_feature = $features.notable | Where-Object {$_.feature_name -eq "SMB1Protocol"}
if ($smb1_feature) {
    $issues += @{
        severity = "high"
        category = "security"
        description = "SMB1 protocol habilitado"
        recommendation = "SEGURIDAD - Deshabilitar SMB1, es obsoleto y vulnerable (WannaCry exploit)"
    }
}

# Win11 incompatible (si es Win10)
if ($windows.caption -like "*Windows 10*" -and -not $win11_requirements.win11_compatible) {
    $reasons = @()
    if (-not $win11_requirements.tpm.present) { $reasons += "Sin TPM" }
    if (-not $win11_requirements.secure_boot.enabled) { $reasons += "Secure Boot disabled" }
    
    $issues += @{
        severity = "info"
        category = "compatibility"
        description = "No cumple requisitos Windows 11: $($reasons -join ', ')"
        recommendation = "Si planea upgrade Win11, verificar BIOS settings o hardware upgrade"
    }
}

# ============================================================
# BUILD JSON
# ============================================================

Write-Host "[20/20] Generando output JSON..." -ForegroundColor Yellow

$output = @{
    scan_timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    computer_name = $computerName
    hardware = $hardware
    temperatures = $hwinfo_data.temperatures
    voltages = $hwinfo_data.voltages
    throttling = $hwinfo_data.throttling
    windows = $windows
    drivers = $drivers
    services = $services
    startup = $startup
    network = $network
    power = $power
    event_log = $event_log
    storage = $storage_detailed
    applications = $applications
    security = $security
    pagefile = $pagefile
    windows_update = $windows_update
    system_restore = $system_restore
    fast_startup = $fast_startup
    win11_requirements = $win11_requirements
    features = $features
    issues_detected = $issues
}

# CONVERTIR A JSON (ESTA ES LA LINEA QUE FALTA)
$json_output = $output | ConvertTo-Json -Depth 100

# Save JSON
$folder = if ($Post) { "post_service" } else { "pre_service" }
$json_path = "$PSScriptRoot\..\output\$folder\${timestamp}_${computerName}.json"

# Crear directorios
New-Item -ItemType Directory -Path "$PSScriptRoot\..\output\$folder" -Force | Out-Null

# Guardar
$json_output | Out-File -FilePath $json_path -Encoding UTF8

Write-Host ""
Write-Host "JSON guardado: $json_path" -ForegroundColor Green