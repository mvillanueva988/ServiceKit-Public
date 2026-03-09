# ServiceKit - Generate Report (JSON to Markdown)
# @Mateo Villanueva
# Version: 1.1 (GPU Array Support)

param(
    [Parameter(Mandatory=$true)]
    [string]$JsonPath
)

# ConfiguraciÃ³n de codificaciÃ³n para evitar problemas con caracteres
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path $JsonPath)) {
    Write-Error "JSON no encontrado: $JsonPath"
    exit 1
}

# Leer JSON
try {
    $jsonContent = Get-Content -Path $JsonPath -Raw -Encoding UTF8
    $data = $jsonContent | ConvertFrom-Json
} catch {
    Write-Error "Error al leer o parsear el JSON: $_"
    exit 1
}

# Construir rutas de salida en carpeta reports
$jsonFileName = Split-Path $JsonPath -Leaf
$reportFileName = $jsonFileName.Replace(".json", ".md")
$htmlFileName = $jsonFileName.Replace(".json", ".html")

$reportsDir = Join-Path $PSScriptRoot "..\output\reports"
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

$mdPath = Join-Path $reportsDir $reportFileName
$htmlPath = Join-Path $reportsDir $htmlFileName

# Inicializar StringBuilder
$sb = [System.Text.StringBuilder]::new()

# ============================================================
# HEADER
# ============================================================
[void]$sb.AppendLine("# SYSTEM DIAGNOSTIC REPORT")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**Computer**: $($data.computer_name)")
[void]$sb.AppendLine("**Date**: $($data.timestamp)")
[void]$sb.AppendLine("**Technician**: ServiceKit Auto-Report")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# HARDWARE
# ============================================================
[void]$sb.AppendLine("## HARDWARE")
[void]$sb.AppendLine("")

# CPU
[void]$sb.AppendLine("### CPU")
[void]$sb.AppendLine("- **Model**: $($data.hardware.cpu.name)")
[void]$sb.AppendLine("- **Cores/Threads**: $($data.hardware.cpu.cores)C / $($data.hardware.cpu.threads)T")
[void]$sb.AppendLine("- **Base Clock**: $($data.hardware.cpu.base_clock_mhz) MHz")
[void]$sb.AppendLine("- **Architecture**: $($data.hardware.cpu.architecture)")
[void]$sb.AppendLine("")

# RAM
[void]$sb.AppendLine("### RAM")
[void]$sb.AppendLine("- **Total**: $($data.hardware.ram.total_gb) GB")
[void]$sb.AppendLine("- **Slots occupied**: $($data.hardware.ram.slots.Count)")
[void]$sb.AppendLine("")
foreach ($slot in $data.hardware.ram.slots) {
    [void]$sb.AppendLine("- DIMM $($slot.device_locator): $($slot.capacity_gb)GB @ $($slot.speed_mhz)MHz ($($slot.manufacturer))")
}
[void]$sb.AppendLine("")

# GPU (CORREGIDO PARA ARRAY Y TIPOS)
[void]$sb.AppendLine("### GPU")
[void]$sb.AppendLine("")

if ($data.hardware.gpus) {
    foreach ($gpu in $data.hardware.gpus) {
        # Determinar etiqueta de tipo
        $typeTag = if ($gpu.type) { "[$($gpu.type.ToUpper())]" } else { "[GPU]" }
        
        # Formato solicitado: [TIPO] Nombre
        [void]$sb.AppendLine("**$typeTag $($gpu.name)**")
        
        # Detalles VRAM
        if ($gpu.vram_gb) {
            [void]$sb.AppendLine("- VRAM: $($gpu.vram_gb) GB")
        } else {
            [void]$sb.AppendLine("- VRAM: Shared/Unknown")
        }
        
        # Detalles Driver
        [void]$sb.AppendLine("- Driver: $($gpu.driver_version)")
        
        # Espacio entre GPUs
        [void]$sb.AppendLine("") 
    }
} else {
    [void]$sb.AppendLine("**[WARNING]** No GPU information detected in JSON.")
    [void]$sb.AppendLine("")
}

# Storage
[void]$sb.AppendLine("### Storage")
[void]$sb.AppendLine("")

foreach ($disk in $data.hardware.storage) {
    $health_icon = if ($disk.health_status -eq "Healthy") { "[OK]" } else { "[WARNING]" }
    [void]$sb.AppendLine("- **$($disk.friendly_name)** $health_icon")
    [void]$sb.AppendLine("  - Type: $($disk.media_type) | Size: $($disk.size_gb)GB | Health: $($disk.health_status)")
    
    # Manejo de temperatura si existe
    if ($disk.temperature_c -and $disk.temperature_c -gt 0) {
        [void]$sb.AppendLine("  - Temperature: $($disk.temperature_c)C | Wear: $($disk.wear_percent)%")
    } else {
        [void]$sb.AppendLine("  - Temperature: N/A | Wear: $($disk.wear_percent)%")
    }
}
[void]$sb.AppendLine("")

# Motherboard & BIOS
[void]$sb.AppendLine("### Motherboard")
[void]$sb.AppendLine("- **Manufacturer**: $($data.hardware.motherboard.manufacturer)")
[void]$sb.AppendLine("- **Model**: $($data.hardware.motherboard.model)")
[void]$sb.AppendLine("")

[void]$sb.AppendLine("### BIOS")
[void]$sb.AppendLine("- **Version**: $($data.hardware.bios.version)")
[void]$sb.AppendLine("- **Date**: $($data.hardware.bios.release_date)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# WINDOWS
# ============================================================
[void]$sb.AppendLine("## WINDOWS")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("- **Edition**: $($data.windows.caption)")
[void]$sb.AppendLine("- **Version**: $($data.windows.version) (Build $($data.windows.build))")
[void]$sb.AppendLine("- **Activation**: $($data.windows.activation_status)")
[void]$sb.AppendLine("- **Uptime**: $($data.windows.uptime_hours) hours")
[void]$sb.AppendLine("- **Install Date**: $($data.windows.install_date)")
[void]$sb.AppendLine("")

[void]$sb.AppendLine("### Windows Update")
if ($data.windows.last_update) {
    [void]$sb.AppendLine("- **Last Update**: $($data.windows.last_update)")
    [void]$sb.AppendLine("- **Days since last**: $($data.windows.days_since_update) days")
    
    if ($data.windows.days_since_update -gt 60) {
        [void]$sb.AppendLine("- **Status**: [CRITICAL] System outdated (60+ days)")
    } elseif ($data.windows.days_since_update -gt 30) {
        [void]$sb.AppendLine("- **Status**: [WARNING] Updates pending (30+ days)")
    } else {
        [void]$sb.AppendLine("- **Status**: [OK] Up to date")
    }
} else {
    [void]$sb.AppendLine("- **Status**: [UNKNOWN] Could not determine last update.")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**What this means**: Windows Update mantiene el sistema seguro con parches de seguridad y bug fixes. Si no se actualiza por 60+ dias, el sistema es vulnerable a exploits conocidos.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# SECURITY
# ============================================================
[void]$sb.AppendLine("## SECURITY")
[void]$sb.AppendLine("")

[void]$sb.AppendLine("### Antivirus")
$av_count = $data.security.antivirus.Count

if ($av_count -eq 0) {
    [void]$sb.AppendLine("[CRITICAL] - NO ANTIVIRUS DETECTED")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Risk**: El sistema esta totalmente expuesto a malware.")
} elseif ($av_count -gt 1) {
    # Check if multiple are enabled
    $enabled_count = 0
    foreach ($av in $data.security.antivirus) {
        # Simple heuristic for 'Enabled' string check
        if ($av -match "Enabled" -or $av -match "On") { $enabled_count++ }
    }

    if ($enabled_count -gt 1) {
        [void]$sb.AppendLine("[WARNING] - MULTIPLES ANTIVIRUS ACTIVOS")
        [void]$sb.AppendLine("")
        foreach ($av in $data.security.antivirus) {
            [void]$sb.AppendLine("- $av")
        }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("**Why this is a problem**: Multiples antivirus causan conflictos severos, lentitud extrema (cada uno escanea archivos simultaneamente), y paradojicamente reducen la efectividad de proteccion.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("**Recommendation**: Desinstalar todos excepto uno. Windows Defender es suficiente para mayoria usuarios.")
    } else {
         foreach ($av in $data.security.antivirus) {
            [void]$sb.AppendLine("- $av")
        }
    }
} else {
    # Just one AV
    [void]$sb.AppendLine("- $($data.security.antivirus[0])")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# STORAGE USAGE
# ============================================================
[void]$sb.AppendLine("## STORAGE USAGE")
[void]$sb.AppendLine("")

foreach ($vol in $data.storage_analysis.volumes) {
    $status = "[OK]"
    if ($vol.free_percent -lt 10) { $status = "[CRITICAL] Low Space" }
    elseif ($vol.free_percent -lt 20) { $status = "[WARNING]" }

    [void]$sb.AppendLine("### Drive $($vol.letter) $status")
    [void]$sb.AppendLine("- **Label**: $($vol.label)")
    [void]$sb.AppendLine("- **Total**: $($vol.total_gb)GB | **Used**: $($vol.used_gb)GB | **Free**: $($vol.free_gb)GB ($($vol.free_percent)%)")
    [void]$sb.AppendLine("")
}

if ($data.storage_analysis.temp_files.total_mb -gt 1000) {
    [void]$sb.AppendLine("**Temp Files Detected**: [HIGH] $([math]::Round($data.storage_analysis.temp_files.total_mb / 1024, 2)) GB reclaimable space.")
} else {
    [void]$sb.AppendLine("**Temp Files**: [OK] $([math]::Round($data.storage_analysis.temp_files.total_mb, 0)) MB.")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# SERVICES & STARTUP
# ============================================================
[void]$sb.AppendLine("## PERFORMANCE & BLOATWARE")
[void]$sb.AppendLine("")

# Services
[void]$sb.AppendLine("### Bloatware Services")
if ($data.services.bloat_detected -gt 0) {
    [void]$sb.AppendLine("[WARNING] Found $($data.services.bloat_detected) unnecessary services running.")
    [void]$sb.AppendLine("")
    foreach ($svc in $data.services.bloat_list) {
        [void]$sb.AppendLine("- **$($svc.name)** ($($svc.display_name))")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Recommendation**: Ejecutar script 'Deshabilitar servicios bloat' del toolkit.")
} else {
    [void]$sb.AppendLine("[OK] No common bloatware services detected.")
}
[void]$sb.AppendLine("")

# Startup
[void]$sb.AppendLine("### Startup Apps")
[void]$sb.AppendLine("Total apps starting with Windows: $($data.startup.total)")
[void]$sb.AppendLine("")
if ($data.startup.total -gt 10) {
    [void]$sb.AppendLine("**Note**: [HIGH] High number of startup apps may slow down boot time.")
}

[void]$sb.AppendLine("**Registry Run**:")
foreach ($item in $data.startup.registry) {
    [void]$sb.AppendLine("- $($item.name)")
}

if ($data.startup.folder.Count -gt 0) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Startup Folder**:")
    foreach ($item in $data.startup.folder) {
        [void]$sb.AppendLine("- $($item.name)")
    }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ============================================================
# DRIVERS & ERRORS
# ============================================================
[void]$sb.AppendLine("## SYSTEM HEALTH")
[void]$sb.AppendLine("")

# Drivers
[void]$sb.AppendLine("### Drivers")
$old_drivers = 0
foreach ($drv in $data.drivers.critical) {
    if ($drv.is_old) { $old_drivers++ }
}

if ($old_drivers -gt 0) {
    [void]$sb.AppendLine("[WARNING] Found $old_drivers critical drivers older than 1 year.")
} else {
    [void]$sb.AppendLine("[OK] Critical drivers seem up to date.")
}

if ($data.drivers.problem_devices.Count -gt 0) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**[CRITICAL] Problem Devices Detected (Device Manager)**:")
    foreach ($dev in $data.drivers.problem_devices) {
        [void]$sb.AppendLine("- **$($dev.name)**: $($dev.status)")
    }
}
[void]$sb.AppendLine("")

# Event Log
[void]$sb.AppendLine("### System Errors (Last 24h)")
if ($data.event_log.errors.Count -gt 0) {
    [void]$sb.AppendLine("[WARNING] Found $($data.event_log.unique_errors) unique error types.")
    [void]$sb.AppendLine("")
    foreach ($err in $data.event_log.errors) {
        [void]$sb.AppendLine("- **$($err.source)** (Count: $($err.count)): $($err.message)")
    }
} else {
    [void]$sb.AppendLine("[OK] No critical system errors found in last 24h.")
}

# ============================================================
# WRITE OUTPUT
# ============================================================
$sb.ToString() | Out-File -FilePath $mdPath -Encoding UTF8
Write-Host "Reporte MD generado: $mdPath" -ForegroundColor Green