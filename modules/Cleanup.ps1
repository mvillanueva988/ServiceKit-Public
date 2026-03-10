Set-StrictMode -Version Latest

# ─── _Get-CleanupPaths ────────────────────────────────────────────────────────
# Fuente única de rutas. Llamada en tiempo de ejecución para que los paths de
# entorno ($env:*) se resuelvan correctamente dentro del job asíncrono.
function _Get-CleanupPaths {
    [OutputType([PSCustomObject[]])]
    param()

    $paths = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Rutas estáticas
    foreach ($entry in @(
        [PSCustomObject]@{ Label = 'Windows Temp';          Path = "$env:SystemRoot\Temp" }
        [PSCustomObject]@{ Label = 'Windows Prefetch';      Path = "$env:SystemRoot\Prefetch" }
        [PSCustomObject]@{ Label = 'Windows Update Cache';  Path = "$env:SystemRoot\SoftwareDistribution\Download" }
        [PSCustomObject]@{ Label = 'Usuario Temp';          Path = "$env:TEMP" }
        [PSCustomObject]@{ Label = 'LocalAppData Temp';     Path = "$env:LOCALAPPDATA\Temp" }
        [PSCustomObject]@{ Label = 'Chrome Cache';          Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache" }
        [PSCustomObject]@{ Label = 'Edge Cache';            Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" }
        [PSCustomObject]@{ Label = 'Brave Cache';           Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache" }
        [PSCustomObject]@{ Label = 'Opera Cache';           Path = "$env:LOCALAPPDATA\Opera Software\Opera Stable\Cache" }
        [PSCustomObject]@{ Label = 'Opera GX Cache';        Path = "$env:LOCALAPPDATA\Opera Software\Opera GX Stable\Cache" }
    )) { $paths.Add($entry) }

    # Firefox — enumerar perfiles dinámicamente desde %APPDATA%
    [string] $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffRoot -PathType Container) {
        Get-ChildItem -Path $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            [string] $cache2 = Join-Path $_.FullName 'cache2'
            if (Test-Path $cache2 -PathType Container) {
                $paths.Add([PSCustomObject]@{
                    Label = 'Firefox Cache ({0})' -f $_.Name
                    Path  = $cache2
                })
            }
        }
    }

    return $paths.ToArray()
}

function Clear-TempFiles {
    <#
    .SYNOPSIS
        Borra archivos temporales de rutas estándar de Windows, usuario y navegadores.
        Retorna un objeto con el espacio liberado y la cantidad de errores no críticos.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject[]] $cleanPaths = _Get-CleanupPaths

    $totalFreedBytes = [long]0
    $softErrors      = 0

    foreach ($entry in $cleanPaths) {
        [string] $path = $entry.Path
        if (-not (Test-Path -Path $path -PathType Container)) { continue }

        $isWU = $path -like '*SoftwareDistribution*'
        if ($isWU) {
            Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
        }

        try {
            $files     = Get-ChildItem -Path $path -Recurse -Force -File -ErrorAction SilentlyContinue
            $measured  = $files | Measure-Object -Property Length -Sum
            $pathBytes = if ($measured.Sum) { [long]$measured.Sum } else { [long]0 }

            Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue

            $totalFreedBytes += $pathBytes
        }
        catch {
            $softErrors++
        }
        finally {
            if ($isWU) {
                Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
            }
        }
    }

    return [PSCustomObject]@{
        FreedBytes = $totalFreedBytes
        FreedMB    = [math]::Round($totalFreedBytes / 1MB, 2)
        FreedGB    = [math]::Round($totalFreedBytes / 1GB, 2)
        SoftErrors = $softErrors
    }
}

function Get-CleanupPreview {
    <#
    .SYNOPSIS
        Escanea las rutas de limpieza y calcula el espacio que se liberaría
        sin borrar nada. Retorna una lista de objetos por carpeta y el total.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject[]] $cleanPaths = _Get-CleanupPaths

    [System.Collections.Generic.List[PSCustomObject]] $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    [long] $totalBytes = 0

    foreach ($entry in $cleanPaths) {
        if (-not (Test-Path -Path $entry.Path -PathType Container)) { continue }

        $files = Get-ChildItem -Path $entry.Path -Recurse -Force -File -ErrorAction SilentlyContinue
        [long] $bytes = if ($files) { ($files | Measure-Object -Property Length -Sum).Sum } else { 0 }

        if ($bytes -gt 0) {
            $rows.Add([PSCustomObject]@{
                Label     = $entry.Label
                Path      = $entry.Path
                SizeBytes = $bytes
                SizeMB    = [math]::Round($bytes / 1MB, 2)
            })
            $totalBytes += $bytes
        }
    }

    return [PSCustomObject]@{
        Folders    = $rows.ToArray()
        TotalBytes = $totalBytes
        TotalMB    = [math]::Round($totalBytes / 1MB, 2)
        TotalGB    = [math]::Round($totalBytes / 1GB, 2)
    }
}

function Start-CleanupProcess {
    <#
    .SYNOPSIS
        Empaqueta Clear-TempFiles en un job asíncrono mediante Invoke-AsyncToolkitJob
        y retorna el objeto de trabajo para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param()

    $fnBodyPaths = ${Function:_Get-CleanupPaths}.ToString()
    $fnBodyClean = ${Function:Clear-TempFiles}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function _Get-CleanupPaths {
$fnBodyPaths
}
function Clear-TempFiles {
$fnBodyClean
}
Clear-TempFiles
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DiskCleanup'
}
