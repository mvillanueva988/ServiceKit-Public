Set-StrictMode -Version Latest

# ─── Write-ActionAudit (helper centralizado) ──────────────────────────────────
function Write-ActionAudit {
    <#
    .SYNOPSIS
        Wrapper sobre Write-ToolkitAuditLog para handlers del Router.
        Marca cada accion del menu en output/audit/<date>.jsonl. Defensivo:
        si ToolkitSupport no esta dot-sourced (caso edge), no rompe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter()]          [string] $Status = 'Started',
        [Parameter()]          [string] $Summary = '',
        [Parameter()]          [object] $Details = $null
    )

    if (Get-Command -Name 'Write-ToolkitAuditLog' -CommandType Function -ErrorAction SilentlyContinue) {
        Write-ToolkitAuditLog -Action $Action -Status $Status -Summary $Summary -Details $Details
    }
}

# ─── Show-MachineBanner ───────────────────────────────────────────────────────
function Show-MachineBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    $osInfo  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    [string] $osName = if ($MachineProfile.IsWin11) { 'Win11' } else { 'Windows' }
    if ($MachineProfile.IsHome) { $osName = "$osName Home" }

    [string] $build = if ($MachineProfile.Build -gt 0) { [string] $MachineProfile.Build } else { 'N/A' }
    [string] $arch  = if ($osInfo -and $osInfo.OSArchitecture) { [string] $osInfo.OSArchitecture } else { 'x64' }

    [string] $cpuName    = if ($cpuInfo -and $cpuInfo.Name) { ([string]$cpuInfo.Name).Trim() } else { 'CPU no detectada' }
    [string] $cpuCores   = if ($cpuInfo -and $cpuInfo.NumberOfCores) { [string]$cpuInfo.NumberOfCores } else { '?' }
    [string] $cpuThreads = if ($cpuInfo -and $cpuInfo.NumberOfLogicalProcessors) { [string]$cpuInfo.NumberOfLogicalProcessors } else { '?' }

    [double] $ramTotalGb = [math]::Round(([double]$MachineProfile.RamMB / 1024), 2)
    [string] $ramTotalLabel = if ($MachineProfile.RamMB -gt 0) { ('{0:N2} GB total' -f $ramTotalGb) } else { 'N/A total' }

    [string] $ramFreeLabel = 'N/A disponible'
    if ($osInfo -and $osInfo.FreePhysicalMemory) {
        [double] $freeGb = [math]::Round((([double]$osInfo.FreePhysicalMemory * 1KB) / 1GB), 2)
        $ramFreeLabel = ('{0:N2} GB disponible' -f $freeGb)
    }

    [string[]] $gpuNames = @()
    if ($MachineProfile.PSObject.Properties['GpuNames']) {
        $gpuNames = @($MachineProfile.GpuNames)
    }
    [string] $gpuLabel = if ($gpuNames.Count -gt 0) { $gpuNames -join ' | ' } else { 'GPU no detectada' }
    if ($MachineProfile.HasIGpuOnly) {
        $gpuLabel = "$gpuLabel  [iGPU only]"
    }
    elseif ($MachineProfile.HasDGpu) {
        [string] $vramTag = ''
        if ($MachineProfile.PSObject.Properties['DGpuVramMb'] -and $MachineProfile.DGpuVramMb -gt 0) {
            $vramTag = (' {0} GB VRAM' -f [math]::Round($MachineProfile.DGpuVramMb / 1024, 1))
        }
        $gpuLabel = "$gpuLabel  [dGPU$vramTag]"
    }

    [string] $manufacturer = if ([string]::IsNullOrWhiteSpace([string]$MachineProfile.Manufacturer)) { 'Unknown' } else { [string]$MachineProfile.Manufacturer }
    [string] $oemSuffix = '  [sin catalogo OEM]'
    if ($MachineProfile.PSObject.Properties['OemCatalogPath'] -and -not [string]::IsNullOrWhiteSpace([string]$MachineProfile.OemCatalogPath)) {
        if (Test-Path -Path ([string]$MachineProfile.OemCatalogPath) -PathType Leaf) {
            $oemSuffix = '  [catalogo OEM disponible]'
        }
    }

    [string] $tierLabel = if ($MachineProfile.PSObject.Properties['Tier']) { [string]$MachineProfile.Tier } else { 'N/A' }
    [string] $cpuClass  = if ($MachineProfile.PSObject.Properties['CpuClass']) { [string]$MachineProfile.CpuClass } else { 'Unknown' }

    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host '                   PCTk v2' -ForegroundColor Cyan
    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host ("  OS   : {0} Build {1} {2}" -f $osName, $build, $arch)
    Write-Host ("  CPU  : {0}  {1} nucleos / {2} hilos  [{3}]" -f $cpuName, $cpuCores, $cpuThreads, $cpuClass)
    Write-Host ("  RAM  : {0}  |  {1}" -f $ramTotalLabel, $ramFreeLabel)
    Write-Host ("  GPU  : {0}" -f $gpuLabel)
    Write-Host ("  OEM  : {0}{1}" -f $manufacturer, $oemSuffix)
    Write-Host ("  TIER : {0}" -f $tierLabel) -ForegroundColor Yellow
    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# ─── Show-MainMenu ────────────────────────────────────────────────────────────
function Show-MainMenu {
    <#
    .SYNOPSIS
        Loop principal del menu. Layout Opcion A (decidido en plan-v2.md sec 11):
        cuatro secciones — PERFILES, DIAGNOSTICO, ACCIONES MANUALES, HERRAMIENTAS.
        Las 15 acciones individuales viejas viven detras de [A] (submenu).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    do {
        Clear-Host
        Show-MachineBanner -MachineProfile $MachineProfile

        Write-Host '  PERFILES' -ForegroundColor DarkCyan
        Write-Host '  [1]  Aplicar perfil automatico         (Office/Study/Multimedia/Generic)'
        Write-Host '  [2]  Receta nombrada                   (cliente especifico)'
        Write-Host ''
        Write-Host '  DIAGNOSTICO' -ForegroundColor DarkCyan
        Write-Host '  [3]  Snapshot PRE-service'
        Write-Host '  [4]  Snapshot POST-service'
        Write-Host '  [5]  Comparar PRE vs POST'
        Write-Host '  [6]  Historial de BSOD / Crashes'
        Write-Host '  [R]  Generar prompt de research        (para LLM con web search)'
        Write-Host ''
        Write-Host '  ACCIONES MANUALES' -ForegroundColor DarkCyan
        Write-Host '  [A]  Submenu: acciones individuales    (las 15 originales)'
        Write-Host ''
        Write-Host '  HERRAMIENTAS' -ForegroundColor DarkCyan
        Write-Host '  [T]  Herramientas externas'
        Write-Host '  [X]  Limpiar y salir' -ForegroundColor DarkRed
        Write-Host ''

        [string] $choice = (Read-Host '  Selecciona una opcion').Trim().ToUpperInvariant()

        if ($choice -eq 'X') {
            Invoke-MainMenuDispatch -Choice $choice -MachineProfile $MachineProfile
            return 'X'
        }

        Invoke-MainMenuDispatch -Choice $choice -MachineProfile $MachineProfile
        Write-Host ''
        Read-Host '  [Enter] para continuar' | Out-Null
    }
    while ($true)
}

# ─── Invoke-MainMenuDispatch ──────────────────────────────────────────────────
function Invoke-MainMenuDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Choice,

        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    [string] $up = $Choice.ToUpperInvariant()

    switch ($up) {
        '1' {
            Write-Host '  [Aplicar perfil automatico] [pendiente Stage 2: ProfileEngine + recetas auto]' -ForegroundColor DarkYellow
            return
        }
        '2' {
            Write-Host '  [Receta nombrada] [pendiente Stage 4: editor de recetas + toggles]' -ForegroundColor DarkYellow
            return
        }
        '3' { Invoke-DiagnosticSnapshot -Phase Pre  -MachineProfile $MachineProfile; return }
        '4' { Invoke-DiagnosticSnapshot -Phase Post -MachineProfile $MachineProfile; return }
        '5' { Invoke-DiagnosticCompare  -MachineProfile $MachineProfile; return }
        '6' { Invoke-DiagnosticBsod     -MachineProfile $MachineProfile; return }
        'R' {
            Write-Host '  [Generar prompt de research] [pendiente C8: ResearchPrompt.ps1]' -ForegroundColor DarkYellow
            return
        }
        'A' {
            Show-IndividualActionsSubmenu -MachineProfile $MachineProfile
            return
        }
        'T' { Show-ToolsMenu -MachineProfile $MachineProfile; return }
        'X' {
            Write-Host '  Saliendo de PCTk v2...' -ForegroundColor Cyan
            return
        }
        default {
            Write-Host '  Opcion invalida.' -ForegroundColor Red
            return
        }
    }
}

# ─── Diagnostic actions del menu principal ────────────────────────────────────

function Invoke-DiagnosticSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Pre', 'Post')] [string] $Phase,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )
    $null = $MachineProfile
    [string] $action = "Snapshot.$Phase"
    Write-ActionAudit -Action $action -Status 'Started'
    Write-Host ('  Capturando snapshot {0}-service...' -f $Phase) -ForegroundColor Cyan
    $job = Start-TelemetryJob -Phase $Phase
    $results = Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 180
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        $r = $results[0]
        Write-Host ('  [OK] Snapshot guardado: {0}' -f $r.FileName) -ForegroundColor Green
        Write-Host ('       {0}' -f $r.FilePath) -ForegroundColor DarkGray
        Write-ActionAudit -Action $action -Status 'Success' -Summary $r.FileName -Details $r
    } else {
        Write-Host '  [!] No se obtuvo resultado del snapshot.' -ForegroundColor Yellow
        Write-ActionAudit -Action $action -Status 'Failed' -Summary 'No result'
    }
}

function Invoke-DiagnosticCompare {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Started'
    try {
        $diff = Compare-Snapshot
        Show-SnapshotComparison -Diff $diff
        Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Success' -Summary ('Score {0}/{1}' -f $diff.Score, $diff.ScoreMax) -Details $diff
    }
    catch {
        Write-Host ('  [!] {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Failed' -Summary $_.Exception.Message
    }
}

function Invoke-DiagnosticBsod {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Started'
    Write-Host '  Analizando Event Log (ultimos 90 dias)...' -ForegroundColor Cyan
    $job = Start-BsodHistoryJob -Days 90
    $results = Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 120
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        Show-BsodHistory -Data $results[0]
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Success' -Summary ('{0} eventos en {1} dias' -f $results[0].TotalCrashes, $results[0].DaysScanned)
    } else {
        Write-Host '  [!] No se pudo leer el Event Log.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Failed' -Summary 'No result'
    }
}

# ─── Tools menu (basico — Stage 1: lanza Bootstrap-Tools o abre tools\bin) ────

function Show-ToolsMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    [string] $toolkitRoot = Split-Path -Parent $PSScriptRoot
    [string] $binDir = Join-Path $toolkitRoot 'tools\bin'
    [string] $bootstrap = Join-Path $toolkitRoot 'Bootstrap-Tools.ps1'

    Write-Host '  HERRAMIENTAS EXTERNAS' -ForegroundColor DarkCyan
    Write-Host '  ====================='
    Write-Host ('  Binarios en: {0}' -f $binDir)
    Write-Host ''
    Write-Host '  [1]  Descargar/actualizar todas las herramientas (Bootstrap-Tools.ps1)'
    Write-Host '  [2]  Abrir carpeta tools\bin'
    Write-Host '  [B]  Volver al menu principal' -ForegroundColor DarkYellow
    Write-Host ''
    [string] $choice = (Read-Host '  Selecciona una opcion').Trim().ToUpperInvariant()

    switch ($choice) {
        '1' {
            if (Test-Path $bootstrap) {
                & $bootstrap
            } else {
                Write-Host ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $bootstrap) -ForegroundColor Red
            }
        }
        '2' {
            if (-not (Test-Path $binDir)) {
                New-Item -ItemType Directory -Path $binDir -Force | Out-Null
            }
            Start-Process explorer.exe $binDir
        }
    }
}

# ─── Show-IndividualActionsSubmenu ────────────────────────────────────────────
function Show-IndividualActionsSubmenu {
    <#
    .SYNOPSIS
        Submenu [A] con las acciones individuales del PCTk v1. No se mostraban
        antes desde el menu principal porque competian con los perfiles, pero
        siguen siendo utiles cuando el operador quiere correr SOLO una accion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    do {
        Clear-Host
        Show-MachineBanner -MachineProfile $MachineProfile

        Write-Host '  ACCIONES INDIVIDUALES' -ForegroundColor DarkCyan
        Write-Host '  ====================='
        Write-Host '  [1]  Debloat de Servicios'
        Write-Host '  [2]  Limpieza de Disco'
        Write-Host '  [3]  Mantenimiento del Sistema (DISM + SFC)'
        Write-Host '  [4]  Crear Punto de Restauracion'
        Write-Host '  [5]  Optimizar Red'
        Write-Host '  [6]  Rendimiento (visuales + power plan + tweaks)'
        Write-Host '  [7]  Backup de Drivers'
        Write-Host '  [8]  Apps Win32 + UWP'
        Write-Host '  [9]  Privacidad (registry o OOSU10)'
        Write-Host '  [10] Inicio del Sistema'
        Write-Host '  [11] Actualizaciones de Windows'
        Write-Host ''
        Write-Host '  [B]  Volver al menu principal' -ForegroundColor DarkYellow
        Write-Host ''

        [string] $choice = (Read-Host '  Selecciona una opcion').Trim().ToUpperInvariant()

        if ($choice -eq 'B' -or $choice -eq 'X') {
            return
        }

        Invoke-IndividualActionDispatch -Choice $choice -MachineProfile $MachineProfile
        Write-Host ''
        Read-Host '  [Enter] para continuar' | Out-Null
    }
    while ($true)
}

# ─── Invoke-IndividualActionDispatch ──────────────────────────────────────────
function Invoke-IndividualActionDispatch {
    <#
    .SYNOPSIS
        Cablea cada opcion del submenu a su modulo. Cada handler usa el
        JobManager (Start-* / Wait-ToolkitJobs) para correr async y mostrar
        el resumen al final.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Choice,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [string] $up = $Choice.ToUpperInvariant()
    switch ($up) {
        '1'  { Invoke-ActionDebloat        -MachineProfile $MachineProfile; return }
        '2'  { Invoke-ActionCleanup        -MachineProfile $MachineProfile; return }
        '3'  { Invoke-ActionMaintenance    -MachineProfile $MachineProfile; return }
        '4'  { Invoke-ActionRestorePoint   -MachineProfile $MachineProfile; return }
        '5'  { Invoke-ActionNetwork        -MachineProfile $MachineProfile; return }
        '6'  { Invoke-ActionPerformance    -MachineProfile $MachineProfile; return }
        '7'  { Invoke-ActionDriverBackup   -MachineProfile $MachineProfile; return }
        '8'  { Invoke-ActionApps           -MachineProfile $MachineProfile; return }
        '9'  { Invoke-ActionPrivacy        -MachineProfile $MachineProfile; return }
        '10' { Invoke-ActionStartup        -MachineProfile $MachineProfile; return }
        '11' { Invoke-ActionWindowsUpdate  -MachineProfile $MachineProfile; return }
        default {
            Write-Host '  Opcion invalida.' -ForegroundColor Red
        }
    }
}

# ─── Action handlers (Stage 1 C6) ─────────────────────────────────────────────
# Cada handler es defensivo (try/catch) y reporta success/failure de manera
# uniforme. Audit log per-action se distribuye en C7.

function Invoke-ActionDebloat {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Debloat' -Status 'Started'
    Write-Host '  Deshabilitando servicios bloat...' -ForegroundColor Cyan
    $job = Start-DebloatProcess
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 120)[0]
    if ($null -eq $r) {
        Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Debloat' -Status 'Failed' -Summary 'No result'
        return
    }
    Write-Host ('  [OK] Deshabilitados: {0}  |  Fallaron: {1}' -f $r.Disabled, $r.Failed) -ForegroundColor Green
    if ($r.Errors.Count -gt 0) {
        Write-Host '  Errores:' -ForegroundColor Yellow
        foreach ($e in $r.Errors) { Write-Host ('    - {0}' -f $e) -ForegroundColor DarkGray }
    }
    Write-ActionAudit -Action 'Debloat' -Status 'Success' -Summary ('Disabled={0} Failed={1}' -f $r.Disabled, $r.Failed) -Details $r
}

function Invoke-ActionCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-Host '  [P]review (escanea sin borrar)  /  [R]un (borra)  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()

    if ($sub -eq 'P') {
        Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Started'
        Write-Host '  Escaneando rutas de limpieza...' -ForegroundColor Cyan
        $job = Start-CleanupPreviewJob
        $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 180)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Failed'; return }
        Write-Host ('  Total a liberar: {0} MB ({1} GB)' -f $r.TotalMB, $r.TotalGB) -ForegroundColor Green
        foreach ($f in $r.Folders) {
            Write-Host ('    {0,-50}  {1,8} MB' -f $f.Label, $f.SizeMB)
        }
        Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Success' -Summary ('Estimate {0} MB' -f $r.TotalMB) -Details $r
        return
    }
    if ($sub -eq 'R') {
        Write-ActionAudit -Action 'Cleanup.Run' -Status 'Started'
        Write-Host '  Limpiando temporales y caches...' -ForegroundColor Cyan
        $job = Start-CleanupProcess
        $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 300)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Cleanup.Run' -Status 'Failed'; return }
        Write-Host ('  [OK] Liberado: {0} MB ({1} GB)  |  Errores: {2}' -f $r.FreedMB, $r.FreedGB, $r.SoftErrors) -ForegroundColor Green
        Write-ActionAudit -Action 'Cleanup.Run' -Status 'Success' -Summary ('Freed {0} MB' -f $r.FreedMB) -Details $r
        return
    }
}

function Invoke-ActionMaintenance {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-Host '  DISM + SFC toma 10-20 minutos. Confirma [S/n]:' -ForegroundColor Yellow
    [string] $ans = (Read-Host).Trim().ToUpperInvariant()
    if ($ans -ne 'S' -and $ans -ne '') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; Write-ActionAudit -Action 'Maintenance' -Status 'Cancelled'; return }
    Write-ActionAudit -Action 'Maintenance' -Status 'Started'
    Write-Host '  Ejecutando DISM RestoreHealth + SFC scannow...' -ForegroundColor Cyan
    $job = Start-MaintenanceProcess
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 1800)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Maintenance' -Status 'Failed'; return }
    Write-Host ('  [OK] DISM exit={0}  SFC exit={1}' -f $r.DismExitCode, $r.SfcExitCode) -ForegroundColor Green
    Write-ActionAudit -Action 'Maintenance' -Status 'Success' -Summary ('DISM={0} SFC={1}' -f $r.DismExitCode, $r.SfcExitCode)
}

function Invoke-ActionRestorePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'RestorePoint' -Status 'Started'
    Write-Host '  Creando punto de restauracion...' -ForegroundColor Cyan
    $job = Start-RestorePointProcess
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 180)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'RestorePoint' -Status 'Failed'; return }
    if ($r.Success) {
        Write-Host ('  [OK] {0}' -f $r.Message) -ForegroundColor Green
        Write-ActionAudit -Action 'RestorePoint' -Status 'Success' -Summary $r.Message
    } else {
        [string] $msg = if ($r.PSObject.Properties['Reason']) { $r.Reason } else { $r.Message }
        Write-Host ('  [!] {0}' -f $msg) -ForegroundColor Yellow
        Write-ActionAudit -Action 'RestorePoint' -Status 'Failed' -Summary $msg
    }
}

function Invoke-ActionNetwork {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-Host '  [D]iagnostico (read-only)  /  [O]ptimizar  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()

    if ($sub -eq 'D') {
        Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Started'
        Write-Host '  Recopilando diagnostico de red...' -ForegroundColor Cyan
        $job = Start-NetworkDiagnosticsProcess
        $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 60)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Failed'; return }
        Write-Host ('  TCP AutoTuning : {0}' -f $r.TcpAutoTuning)
        Write-Host ('  Ping 8.8.8.8   : {0} ms' -f $r.PingMs)
        foreach ($a in $r.Adapters) { Write-Host ('  Adapter        : {0,-25} {1,-15} [{2}]' -f $a.Name, $a.LinkSpeed, $a.MediaType) }
        foreach ($k in $r.DnsServers.Keys) { Write-Host ('  DNS {0,-15}: {1}' -f $k, ($r.DnsServers[$k] -join ', ')) }
        Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Success' -Summary ('Tuning={0} Ping={1}ms' -f $r.TcpAutoTuning, $r.PingMs) -Details $r
        return
    }
    if ($sub -eq 'O') {
        Write-ActionAudit -Action 'Network.Optimize' -Status 'Started'
        Write-Host '  Optimizando red (NIC power props + TCP global)...' -ForegroundColor Cyan
        $job = Start-NetworkProcess
        $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 120)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Network.Optimize' -Status 'Failed'; return }
        foreach ($a in $r.AdaptersOptimized) {
            Write-Host ('  [{0}] {1}  changes={2}' -f $(if ($a.ChangesMade -gt 0) { 'OK' } else { '--' }), $a.Name, $a.ChangesMade)
        }
        if ($r.PSObject.Properties['NetshIssues'] -and $r.NetshIssues.Count -gt 0) {
            foreach ($i in $r.NetshIssues) { Write-Host ('  [!] {0}' -f $i) -ForegroundColor Yellow }
        }
        Write-ActionAudit -Action 'Network.Optimize' -Status 'Success' -Summary ('{0} adapters' -f $r.AdaptersOptimized.Count) -Details $r
        return
    }
}

function Invoke-ActionPerformance {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)

    [string] $defaultProfile = if ($MachineProfile.IsLowRam) { 'Full' } else { 'Balanced' }
    Write-Host ('  Perfiles disponibles: [B]alanced  [F]ull (max performance)  [R]estore (defaults)  [T]weaksOnly (sin visuales)')
    Write-Host ('  Default sugerido segun tu hardware: {0}' -f $defaultProfile) -ForegroundColor DarkGray
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    [string] $vp = switch ($sub) {
        'B' { 'Balanced' }
        'F' { 'Full' }
        'R' { 'Restore' }
        'T' { 'TweaksOnly' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($vp)) { Write-Host '  Opcion invalida o cancelada.' -ForegroundColor DarkGray; return }

    Write-ActionAudit -Action 'Performance' -Status 'Started' -Summary ('Profile={0}' -f $vp)
    Write-Host ('  Aplicando perfil {0} + power plan + system tweaks...' -f $vp) -ForegroundColor Cyan
    $job = Start-PerformanceProcess -VisualProfile $vp
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 120)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Performance' -Status 'Failed'; return }
    if ($null -ne $r.Visuals)    { Write-Host ('  Visuales:  Success={0}  Applied={1}' -f $r.Visuals.Success, $r.Visuals.Applied.Count) }
    if ($null -ne $r.PowerPlan)  { Write-Host ('  PowerPlan: {0}  ({1})' -f $r.PowerPlan.PlanName, $r.PowerPlan.Reason) }
    if ($null -ne $r.Tweaks)     { Write-Host ('  Tweaks:    Success={0}  Applied={1}' -f $r.Tweaks.Success, $r.Tweaks.Applied.Count) }
    Write-ActionAudit -Action 'Performance' -Status 'Success' -Summary $vp -Details $r
}

function Invoke-ActionDriverBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    [string] $toolkitRoot = Split-Path -Parent $PSScriptRoot
    [string] $outDir = Join-Path $toolkitRoot 'output\driver_backup'
    Write-ActionAudit -Action 'Drivers.Backup' -Status 'Started'
    Write-Host ('  Exportando drivers a {0}...' -f $outDir) -ForegroundColor Cyan
    $job = Start-DriverBackupJob -OutputRoot $outDir
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 600)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Drivers.Backup' -Status 'Failed'; return }
    if ($r.Success) {
        Write-Host ('  [OK] {0} drivers exportados de {1} candidatos. {2}' -f $r.Exported, $r.Total, $r.Message) -ForegroundColor Green
        Write-Host ('       {0}' -f $r.Destination) -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Drivers.Backup' -Status 'Success' -Summary ('{0}/{1} drivers' -f $r.Exported, $r.Total) -Details $r
    } else {
        Write-Host ('  [!] {0}' -f $r.Message) -ForegroundColor Yellow
        Write-ActionAudit -Action 'Drivers.Backup' -Status 'Failed' -Summary $r.Message
    }
}

function Invoke-ActionApps {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Apps.List' -Status 'Started'
    Write-Host '  Listando apps Win32 + UWP (puede tardar)...' -ForegroundColor Cyan
    $win32Job = Start-Win32AppsJob
    $uwpJob   = Start-UwpAppsJob
    $results  = Wait-ToolkitJobs -Jobs @($win32Job, $uwpJob) -TimeoutSeconds 180
    $win32 = @(); $uwp = @()
    if ($results.Count -ge 1 -and $null -ne $results[0]) { $win32 = @($results[0]) }
    if ($results.Count -ge 2 -and $null -ne $results[1]) { $uwp   = @($results[1]) }
    Write-Host ('  Win32 instaladas: {0}' -f $win32.Count) -ForegroundColor Green
    Write-Host ('  UWP   instaladas: {0}' -f $uwp.Count)   -ForegroundColor Green
    Write-Host '  (UI completa de uninstall: Stage 2+ extiende este handler)'
    Write-ActionAudit -Action 'Apps.List' -Status 'Success' -Summary ('Win32={0} UWP={1}' -f $win32.Count, $uwp.Count)
}

function Invoke-ActionPrivacy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-Host '  Modo: [B]asic  [M]edium  [A]ggressive  [O]OSU10 GUI  [V]olver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -eq 'O') {
        Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Started'
        if (Test-ShutUp10Available) {
            $r = Open-ShutUp10
            if ($r.Success) { Write-Host ('  [OK] OOSU10 abierto: {0}' -f $r.Path) -ForegroundColor Green; Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Success' -Summary $r.Path }
            else            { Write-Host ('  [!] {0}' -f $r.Error) -ForegroundColor Yellow; Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Failed' -Summary $r.Error }
        } else {
            Write-Host '  [!] OOSU10.exe no esta descargado. Usa [T] Herramientas para bajarlo.' -ForegroundColor Yellow
            Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Failed' -Summary 'OOSU10 not installed'
        }
        return
    }
    [string] $profile = switch ($sub) {
        'B' { 'Basic' }
        'M' { 'Medium' }
        'A' { 'Aggressive' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($profile)) { return }
    Write-ActionAudit -Action 'Privacy.Apply' -Status 'Started' -Summary ('Profile={0}' -f $profile)
    Write-Host ('  Aplicando perfil {0} (registry tweaks)...' -f $profile) -ForegroundColor Cyan
    $job = Start-PrivacyJob -Profile $profile
    $r = (Wait-ToolkitJobs -Jobs @($job) -TimeoutSeconds 120)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Privacy.Apply' -Status 'Failed'; return }
    Write-Host ('  [OK] Aplicados: {0}  |  Errores: {1}' -f $r.Applied.Count, $r.Errors.Count) -ForegroundColor Green
    Write-ActionAudit -Action 'Privacy.Apply' -Status 'Success' -Summary ('{0}: Applied={1} Errors={2}' -f $profile, $r.Applied.Count, $r.Errors.Count) -Details $r
}

function Invoke-ActionStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Startup.List' -Status 'Started'
    [object[]] $entries = @(Get-StartupEntries)
    if ($entries.Count -eq 0) { Write-Host '  Sin entradas de inicio.' -ForegroundColor DarkGray; Write-ActionAudit -Action 'Startup.List' -Status 'Success' -Summary '0 entries'; return }
    Write-Host ('  Entradas de inicio detectadas: {0}' -f $entries.Count) -ForegroundColor Green
    for ([int] $i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        [string] $state = if ($e.Enabled) { 'ON ' } else { 'OFF' }
        Write-Host ('  [{0,3}] {1}  {2,-25}  {3,-30}' -f $i, $state, $e.Location, $e.Name)
    }
    Write-Host ''
    Write-Host '  (Toggle interactivo: Stage 2+ extiende este handler)'
    Write-ActionAudit -Action 'Startup.List' -Status 'Success' -Summary ('{0} entries' -f $entries.Count)
}

function Invoke-ActionWindowsUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    [bool] $isLtsc = $false
    if ($MachineProfile.PSObject.Properties['IsHome']) { $isLtsc = $false }
    Write-ActionAudit -Action 'WindowsUpdate.Status' -Status 'Started'
    $status = Get-WindowsUpdateStatus -IsLtsc $isLtsc
    Write-Host '  ESTADO DE WINDOWS UPDATE' -ForegroundColor DarkCyan
    Write-Host ('  Ultima instalacion: {0}' -f $status.LastInstall)
    Write-Host ('  Ultima busqueda  : {0}' -f $status.LastCheck)
    Write-Host ('  Fuente           : {0}' -f $status.Source)
    Write-ActionAudit -Action 'WindowsUpdate.Status' -Status 'Success' -Summary ('LastInstall={0}' -f $status.LastInstall) -Details $status
}
