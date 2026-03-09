# ServiceKit - Comparar Pre/Post Service
# @Mateo Villanueva

param(
    [Parameter(Mandatory=$false)]
    [string]$PreJson,
    
    [Parameter(Mandatory=$false)]
    [string]$PostJson
)

$ErrorActionPreference = "SilentlyContinue"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  COMPARAR PRE/POST SERVICE" -ForegroundColor Cyan
Write-Host "  @Mateo Villanueva" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# BUSCAR JSONS AUTOMATICAMENTE SI NO SE ESPECIFICARON
# ============================================================

if (-not $PreJson) {
    $preFiles = Get-ChildItem "$PSScriptRoot\..\output\pre_service\*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
    
    if ($preFiles.Count -eq 0) {
        Write-Host "ERROR: No se encontraron JSONs en output\pre_service\" -ForegroundColor Red
        Write-Host "Ejecuta primero: Opcion 1 - Recopilar info sistema" -ForegroundColor Yellow
        pause
        exit 1
    }
    
    $PreJson = $preFiles[0].FullName
    Write-Host "Pre-service detectado: $($preFiles[0].Name)" -ForegroundColor Gray
}

if (-not $PostJson) {
    $postFiles = Get-ChildItem "$PSScriptRoot\..\output\post_service\*.json" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending
    
    if ($postFiles.Count -eq 0) {
        Write-Host "ERROR: No se encontraron JSONs en output\post_service\" -ForegroundColor Red
        Write-Host ""
        Write-Host "Para generar post-service:" -ForegroundColor Yellow
        Write-Host "1. Realizar service (mantenimiento, limpieza, etc)" -ForegroundColor Gray
        Write-Host "2. Ejecutar Opcion 1 - Recopilar info sistema" -ForegroundColor Gray
        Write-Host "3. Mover JSON generado de pre_service\ a post_service\" -ForegroundColor Gray
        Write-Host ""
        pause
        exit 1
    }
    
    $PostJson = $postFiles[0].FullName
    Write-Host "Post-service detectado: $($postFiles[0].Name)" -ForegroundColor Gray
}

Write-Host ""

# ============================================================
# CARGAR JSONS
# ============================================================

Write-Host "Cargando JSONs..." -ForegroundColor Yellow

if (-not (Test-Path $PreJson)) {
    Write-Host "ERROR: Pre-service JSON no encontrado: $PreJson" -ForegroundColor Red
    pause
    exit 1
}

if (-not (Test-Path $PostJson)) {
    Write-Host "ERROR: Post-service JSON no encontrado: $PostJson" -ForegroundColor Red
    pause
    exit 1
}

$pre = Get-Content $PreJson -Raw | ConvertFrom-Json
$post = Get-Content $PostJson -Raw | ConvertFrom-Json

Write-Host "JSONs cargados correctamente" -ForegroundColor Green
Write-Host ""

# ============================================================
# COMPARAR STORAGE
# ============================================================

Write-Host "Comparando metricas..." -ForegroundColor Yellow
Write-Host ""

$storage_comparison = @()

foreach ($vol_post in $post.storage) {
    $vol_pre = $pre.storage | Where-Object { $_.drive_letter -eq $vol_post.drive_letter } | Select-Object -First 1
    
    if ($vol_pre) {
        $space_freed = $vol_post.free_gb - $vol_pre.free_gb
        $used_change = $vol_pre.used_percent - $vol_post.used_percent
        
        $storage_comparison += @{
            drive = $vol_post.drive_letter
            pre_free = $vol_pre.free_gb
            post_free = $vol_post.free_gb
            space_freed = $space_freed
            pre_used_percent = $vol_pre.used_percent
            post_used_percent = $vol_post.used_percent
            improved = ($space_freed -gt 0)
        }
    }
}

# ============================================================
# COMPARAR SERVICIOS
# ============================================================

$services_comparison = @{
    pre_total = $pre.services.total
    post_total = $post.services.total
    pre_running = $pre.services.running
    post_running = $post.services.running
    services_stopped = $pre.services.running - $post.services.running
    pre_bloat = $pre.services.bloat_detected
    post_bloat = $post.services.bloat_detected
    bloat_disabled = $pre.services.bloat_detected - $post.services.bloat_detected
}

# ============================================================
# COMPARAR STARTUP
# ============================================================

$startup_comparison = @{
    pre_total = $pre.startup.total
    post_total = $post.startup.total
    items_removed = $pre.startup.total - $post.startup.total
}

# ============================================================
# COMPARAR APLICACIONES
# ============================================================

$apps_comparison = @{
    pre_total = $pre.applications.total_count
    post_total = $post.applications.total_count
    apps_removed = $pre.applications.total_count - $post.applications.total_count
    pre_bloat = $pre.applications.bloatware_count
    post_bloat = $post.applications.bloatware_count
    bloat_removed = $pre.applications.bloatware_count - $post.applications.bloatware_count
}

# ============================================================
# COMPARAR ISSUES
# ============================================================

$issues_comparison = @{
    pre_total = $pre.issues_detected.Count
    post_total = $post.issues_detected.Count
    issues_fixed = $pre.issues_detected.Count - $post.issues_detected.Count
    pre_critical = ($pre.issues_detected | Where-Object { $_.severity -eq "critical" }).Count
    post_critical = ($post.issues_detected | Where-Object { $_.severity -eq "critical" }).Count
    pre_high = ($pre.issues_detected | Where-Object { $_.severity -eq "high" }).Count
    post_high = ($post.issues_detected | Where-Object { $_.severity -eq "high" }).Count
    pre_medium = ($pre.issues_detected | Where-Object { $_.severity -eq "medium" }).Count
    post_medium = ($post.issues_detected | Where-Object { $_.severity -eq "medium" }).Count
}

# ============================================================
# COMPARAR UPTIME (verificar si reinicio)
# ============================================================

$uptime_comparison = @{
    pre_hours = $pre.windows.uptime_hours
    post_hours = $post.windows.uptime_hours
    system_rebooted = ($post.windows.uptime_hours -lt $pre.windows.uptime_hours)
}

# ============================================================
# COMPARAR DRIVERS ACTUALIZADOS
# ============================================================

$drivers_updated = @()

foreach ($drv_post in $post.drivers.critical) {
    $drv_pre = $pre.drivers.critical | Where-Object { $_.driver_name -eq $drv_post.driver_name } | Select-Object -First 1
    
    if ($drv_pre -and $drv_post.version -ne $drv_pre.version) {
        $drivers_updated += @{
            name = $drv_post.driver_name
            class = $drv_post.class_name
            pre_version = $drv_pre.version
            post_version = $drv_post.version
            pre_date = $drv_pre.date
            post_date = $drv_post.date
        }
    }
}

# ============================================================
# GENERAR REPORT MD
# ============================================================

Write-Host "Generando report comparativo..." -ForegroundColor Yellow

$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine("# SERVICE COMPARISON REPORT")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**Computer**: $($post.computer_name)")
[void]$sb.AppendLine("**Pre-service**: $($pre.scan_timestamp)")
[void]$sb.AppendLine("**Post-service**: $($post.scan_timestamp)")
[void]$sb.AppendLine("**Technician**: Mateo Villanueva")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# STORAGE
[void]$sb.AppendLine("## STORAGE")
[void]$sb.AppendLine("")

$total_freed = ($storage_comparison | Measure-Object -Property space_freed -Sum).Sum

foreach ($vol in $storage_comparison) {
    $status = if ($vol.improved) { "[IMPROVED]" } else { "[NO CHANGE]" }
    $arrow = if ($vol.improved) { "→" } else { "=" }
    
    [void]$sb.AppendLine("### Drive $($vol.drive): $status")
    [void]$sb.AppendLine("- Free space: $($vol.pre_free) GB $arrow $($vol.post_free) GB")
    [void]$sb.AppendLine("- Space freed: **$([math]::Round($vol.space_freed, 2)) GB**")
    [void]$sb.AppendLine("- Used: $($vol.pre_used_percent)% $arrow $($vol.post_used_percent)%")
    [void]$sb.AppendLine("")
}

[void]$sb.AppendLine("**Total space freed: $([math]::Round($total_freed, 2)) GB**")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# SERVICES
[void]$sb.AppendLine("## SERVICES")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Metric | Pre-service | Post-service | Change |")
[void]$sb.AppendLine("|--------|-------------|--------------|--------|")
[void]$sb.AppendLine("| Total services | $($services_comparison.pre_total) | $($services_comparison.post_total) | - |")
[void]$sb.AppendLine("| Running services | $($services_comparison.pre_running) | $($services_comparison.post_running) | **-$($services_comparison.services_stopped)** |")
[void]$sb.AppendLine("| Bloat services detected | $($services_comparison.pre_bloat) | $($services_comparison.post_bloat) | **-$($services_comparison.bloat_disabled)** |")
[void]$sb.AppendLine("")

if ($services_comparison.services_stopped -gt 0) {
    [void]$sb.AppendLine("[IMPROVED] $($services_comparison.services_stopped) servicios deshabilitados")
} else {
    [void]$sb.AppendLine("[NO CHANGE] No se deshabilitaron servicios")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# STARTUP
[void]$sb.AppendLine("## STARTUP PROGRAMS")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("- Pre-service: $($startup_comparison.pre_total) programs")
[void]$sb.AppendLine("- Post-service: $($startup_comparison.post_total) programs")
[void]$sb.AppendLine("- **Removed: $($startup_comparison.items_removed)**")
[void]$sb.AppendLine("")

if ($startup_comparison.items_removed -gt 0) {
    [void]$sb.AppendLine("[IMPROVED] Boot time deberia ser mas rapido")
} else {
    [void]$sb.AppendLine("[NO CHANGE] No se removieron programas startup")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# APPLICATIONS
[void]$sb.AppendLine("## APPLICATIONS")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Metric | Pre-service | Post-service | Change |")
[void]$sb.AppendLine("|--------|-------------|--------------|--------|")
[void]$sb.AppendLine("| Total installed | $($apps_comparison.pre_total) | $($apps_comparison.post_total) | **-$($apps_comparison.apps_removed)** |")
[void]$sb.AppendLine("| Bloatware detected | $($apps_comparison.pre_bloat) | $($apps_comparison.post_bloat) | **-$($apps_comparison.bloat_removed)** |")
[void]$sb.AppendLine("")

if ($apps_comparison.bloat_removed -gt 0) {
    [void]$sb.AppendLine("[IMPROVED] $($apps_comparison.bloat_removed) aplicaciones bloatware removidas")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# ISSUES
[void]$sb.AppendLine("## ISSUES DETECTED")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| Severity | Pre-service | Post-service | Change |")
[void]$sb.AppendLine("|----------|-------------|--------------|--------|")
[void]$sb.AppendLine("| Critical | $($issues_comparison.pre_critical) | $($issues_comparison.post_critical) | **-$($issues_comparison.pre_critical - $issues_comparison.post_critical)** |")
[void]$sb.AppendLine("| High | $($issues_comparison.pre_high) | $($issues_comparison.post_high) | **-$($issues_comparison.pre_high - $issues_comparison.post_high)** |")
[void]$sb.AppendLine("| Medium | $($issues_comparison.pre_medium) | $($issues_comparison.post_medium) | **-$($issues_comparison.pre_medium - $issues_comparison.post_medium)** |")
[void]$sb.AppendLine("| **TOTAL** | **$($issues_comparison.pre_total)** | **$($issues_comparison.post_total)** | **-$($issues_comparison.issues_fixed)** |")
[void]$sb.AppendLine("")

if ($issues_comparison.issues_fixed -gt 0) {
    [void]$sb.AppendLine("[IMPROVED] $($issues_comparison.issues_fixed) issues resueltos")
} elseif ($issues_comparison.issues_fixed -lt 0) {
    [void]$sb.AppendLine("[WARNING] $([math]::Abs($issues_comparison.issues_fixed)) nuevos issues detectados")
} else {
    [void]$sb.AppendLine("[NO CHANGE] Mismos issues detectados")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# DRIVERS
if ($drivers_updated.Count -gt 0) {
    [void]$sb.AppendLine("## DRIVERS UPDATED")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Driver | Class | Pre-version | Post-version |")
    [void]$sb.AppendLine("|--------|-------|-------------|--------------|")
    
    foreach ($drv in $drivers_updated) {
        [void]$sb.AppendLine("| $($drv.name) | $($drv.class) | $($drv.pre_version) | $($drv.post_version) |")
    }
    
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("[IMPROVED] $($drivers_updated.Count) drivers actualizados")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
}

# UPTIME
[void]$sb.AppendLine("## SYSTEM UPTIME")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("- Pre-service: $($uptime_comparison.pre_hours) hours")
[void]$sb.AppendLine("- Post-service: $($uptime_comparison.post_hours) hours")
[void]$sb.AppendLine("")

if ($uptime_comparison.system_rebooted) {
    [void]$sb.AppendLine("[INFO] Sistema reiniciado durante service (recomendado)")
} else {
    [void]$sb.AppendLine("[INFO] Sistema NO reiniciado (considerar reiniciar para aplicar cambios)")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# SUMMARY
[void]$sb.AppendLine("## SUMMARY")
[void]$sb.AppendLine("")

$improvements = 0
if ($total_freed -gt 0) { $improvements++ }
if ($services_comparison.services_stopped -gt 0) { $improvements++ }
if ($startup_comparison.items_removed -gt 0) { $improvements++ }
if ($apps_comparison.bloat_removed -gt 0) { $improvements++ }
if ($issues_comparison.issues_fixed -gt 0) { $improvements++ }
if ($drivers_updated.Count -gt 0) { $improvements++ }

[void]$sb.AppendLine("**Service effectiveness: $improvements/6 areas improved**")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Improvements made:")

if ($total_freed -gt 0) { [void]$sb.AppendLine("- [OK] Storage: $([math]::Round($total_freed, 2)) GB freed") }
if ($services_comparison.services_stopped -gt 0) { [void]$sb.AppendLine("- [OK] Services: $($services_comparison.services_stopped) disabled") }
if ($startup_comparison.items_removed -gt 0) { [void]$sb.AppendLine("- [OK] Startup: $($startup_comparison.items_removed) programs removed") }
if ($apps_comparison.bloat_removed -gt 0) { [void]$sb.AppendLine("- [OK] Bloatware: $($apps_comparison.bloat_removed) apps removed") }
if ($issues_comparison.issues_fixed -gt 0) { [void]$sb.AppendLine("- [OK] Issues: $($issues_comparison.issues_fixed) fixed") }
if ($drivers_updated.Count -gt 0) { [void]$sb.AppendLine("- [OK] Drivers: $($drivers_updated.Count) updated") }

if ($improvements -eq 0) {
    [void]$sb.AppendLine("- [NO CHANGE] No measurable improvements detected")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**Generated by**: ServiceKit v1.0 - @Mateo Villanueva")

$md = $sb.ToString()

# ============================================================
# GUARDAR REPORT
# ============================================================

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$md_filename = "${timestamp}_comparison.md"
$md_path = "$PSScriptRoot\..\output\reports\$md_filename"

New-Item -ItemType Directory -Path "$PSScriptRoot\..\output\reports" -Force | Out-Null
$md | Out-File -FilePath $md_path -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  COMPARISON REPORT GENERADO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Ubicacion: $md_path" -ForegroundColor White
Write-Host ""
Write-Host "Resumen rapido:" -ForegroundColor Yellow
Write-Host "- Espacio liberado: $([math]::Round($total_freed, 2)) GB" -ForegroundColor $(if ($total_freed -gt 0) { "Green" } else { "Gray" })
Write-Host "- Servicios deshabilitados: $($services_comparison.services_stopped)" -ForegroundColor $(if ($services_comparison.services_stopped -gt 0) { "Green" } else { "Gray" })
Write-Host "- Apps removidas: $($apps_comparison.apps_removed)" -ForegroundColor $(if ($apps_comparison.apps_removed -gt 0) { "Green" } else { "Gray" })
Write-Host "- Issues resueltos: $($issues_comparison.issues_fixed)" -ForegroundColor $(if ($issues_comparison.issues_fixed -gt 0) { "Green" } else { "Gray" })
Write-Host "- Efectividad: $improvements/6 areas mejoradas" -ForegroundColor $(if ($improvements -ge 3) { "Green" } elseif ($improvements -gt 0) { "Yellow" } else { "Red" })
Write-Host ""

pause