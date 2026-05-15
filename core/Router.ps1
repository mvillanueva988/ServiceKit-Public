Set-StrictMode -Version Latest

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
        '3' {
            Write-Host '  [Snapshot PRE-service] [pendiente C6: cablear a Telemetry.Save-Snapshot]' -ForegroundColor DarkYellow
            return
        }
        '4' {
            Write-Host '  [Snapshot POST-service] [pendiente C6: cablear a Telemetry.Save-Snapshot]' -ForegroundColor DarkYellow
            return
        }
        '5' {
            Write-Host '  [Comparar PRE vs POST] [pendiente C6: cablear a Telemetry.Compare-Snapshot]' -ForegroundColor DarkYellow
            return
        }
        '6' {
            Write-Host '  [Historial de BSOD / Crashes] [pendiente C6: cablear a Diagnostics.Get-BsodHistory]' -ForegroundColor DarkYellow
            return
        }
        'R' {
            Write-Host '  [Generar prompt de research] [pendiente C8: ResearchPrompt.ps1]' -ForegroundColor DarkYellow
            return
        }
        'A' {
            Show-IndividualActionsSubmenu -MachineProfile $MachineProfile
            return
        }
        'T' {
            Write-Host '  [Herramientas externas] [pendiente C6: cablear a Bootstrap-Tools / launcher de tools/bin]' -ForegroundColor DarkYellow
            return
        }
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
        Cablea cada opcion del submenu a su modulo. Stage 1 C5 deja stubs
        explicitos por opcion; C6 los reemplaza por invocaciones reales.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Choice,

        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    [string] $up = $Choice.ToUpperInvariant()
    [string] $label = switch ($up) {
        '1'  { 'Debloat de Servicios' }
        '2'  { 'Limpieza de Disco' }
        '3'  { 'Mantenimiento del Sistema' }
        '4'  { 'Crear Punto de Restauracion' }
        '5'  { 'Optimizar Red' }
        '6'  { 'Rendimiento' }
        '7'  { 'Backup de Drivers' }
        '8'  { 'Apps Win32 + UWP' }
        '9'  { 'Privacidad' }
        '10' { 'Inicio del Sistema' }
        '11' { 'Actualizaciones de Windows' }
        default { '' }
    }

    if ([string]::IsNullOrWhiteSpace($label)) {
        Write-Host '  Opcion invalida.' -ForegroundColor Red
        return
    }

    Write-Host ('  [{0}] [pendiente C6: cablear a modulo]' -f $label) -ForegroundColor DarkYellow
}
