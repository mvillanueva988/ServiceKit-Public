Set-StrictMode -Version Latest

function Show-MainMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    do {
        Clear-Host

        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        [string] $osName = if ($MachineProfile.IsWin11) { 'Win11' } else { 'Windows' }
        if ($MachineProfile.IsHome) { $osName = "$osName Home" }

        [string] $build = if ($MachineProfile.Build -gt 0) { [string] $MachineProfile.Build } else { 'N/A' }
        [string] $arch = if ($osInfo -and $osInfo.OSArchitecture) { [string] $osInfo.OSArchitecture } else { 'x64' }

        [string] $cpuName = if ($cpuInfo -and $cpuInfo.Name) { ([string]$cpuInfo.Name).Trim() } else { 'CPU no detectada' }
        [string] $cpuCores = if ($cpuInfo -and $cpuInfo.NumberOfCores) { [string]$cpuInfo.NumberOfCores } else { '?' }
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
            $gpuLabel = "$gpuLabel  [dGPU detectada]"
        }

        [string] $manufacturer = if ([string]::IsNullOrWhiteSpace([string]$MachineProfile.Manufacturer)) { 'Unknown' } else { [string]$MachineProfile.Manufacturer }
        [string] $oemSuffix = '  [sin catálogo OEM]'
        if ($MachineProfile.PSObject.Properties['OemCatalogPath'] -and -not [string]::IsNullOrWhiteSpace([string]$MachineProfile.OemCatalogPath)) {
            if (Test-Path -Path ([string]$MachineProfile.OemCatalogPath) -PathType Leaf) {
                $oemSuffix = '  [catálogo OEM disponible]'
            }
        }

        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host '               SERVICEKIT v2' -ForegroundColor Cyan
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host ("  OS   : {0} Build {1} {2}" -f $osName, $build, $arch)
        Write-Host ("  CPU  : {0}  {1} nucleos / {2} hilos" -f $cpuName, $cpuCores, $cpuThreads)
        Write-Host ("  RAM  : {0}  |  {1}" -f $ramTotalLabel, $ramFreeLabel)
        Write-Host ("  GPU  : {0}" -f $gpuLabel)
        Write-Host ("  OEM  : {0}{1}" -f $manufacturer, $oemSuffix)
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host ''

        Write-Host '  [1]  Debloat de Servicios'
        Write-Host '  [2]  Limpieza de Disco'
        Write-Host '  [3]  Mantenimiento del Sistema'
        Write-Host '  [4]  Crear Punto de Restauracion'
        Write-Host '  [5]  Optimizar Red'
        Write-Host '  [6]  Rendimiento'
        Write-Host '  [7]  Snapshot PRE-service'
        Write-Host '  [8]  Snapshot POST-service'
        Write-Host '  [9]  Comparar PRE vs POST'
        Write-Host '  [10] Historial de BSOD / Crashes'
        Write-Host '  [11] Backup de Drivers'
        Write-Host '  [12] Apps Win32 + UWP'
        Write-Host '  [13] Privacidad'
        Write-Host '  [14] Inicio del Sistema'
        Write-Host '  [15] Actualizaciones de Windows'
        Write-Host '  [T]  Herramientas'
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

function Invoke-MainMenuDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Choice,

        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    $null = $MachineProfile

    [string] $routeName = switch ($Choice.ToUpperInvariant()) {
        '1'  { 'Debloat de Servicios' }
        '2'  { 'Limpieza de Disco' }
        '3'  { 'Mantenimiento del Sistema' }
        '4'  { 'Crear Punto de Restauracion' }
        '5'  { 'Optimizar Red' }
        '6'  { 'Rendimiento' }
        '7'  { 'Snapshot PRE-service' }
        '8'  { 'Snapshot POST-service' }
        '9'  { 'Comparar PRE vs POST' }
        '10' { 'Historial de BSOD / Crashes' }
        '11' { 'Backup de Drivers' }
        '12' { 'Apps Win32 + UWP' }
        '13' { 'Privacidad' }
        '14' { 'Inicio del Sistema' }
        '15' { 'Actualizaciones de Windows' }
        'T'  { 'Herramientas' }
        'X'  { 'Salir' }
        default { '' }
    }

    if ([string]::IsNullOrWhiteSpace($routeName)) {
        Write-Host '  Opcion invalida.' -ForegroundColor Red
        Write-Host '  [stub — Sprint 3]' -ForegroundColor DarkYellow
        return
    }

    if ($Choice.ToUpperInvariant() -eq 'X') {
        Write-Host '  Saliendo de ServiceKit v2...' -ForegroundColor Cyan
        return
    }

    Write-Host ("  [{0}] [stub — Sprint 3]" -f $routeName) -ForegroundColor DarkYellow
}
