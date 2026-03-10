Set-StrictMode -Version Latest

# ─── _Get-CleanupPaths ────────────────────────────────────────────────────────
# Fuente única de rutas. Llamada en tiempo de ejecución para que los paths de
# entorno ($env:*) se resuelvan correctamente dentro del job asíncrono.
function _Get-CleanupPaths {
    [OutputType([PSCustomObject[]])]
    param()

    $paths = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ── Rutas de sistema (independientes del usuario) ──────────────────────────
    foreach ($entry in @(
        [PSCustomObject]@{ Label = 'Windows Temp';     Path = "$env:SystemRoot\Temp" }
        [PSCustomObject]@{ Label = 'Windows Prefetch'; Path = "$env:SystemRoot\Prefetch" }
        [PSCustomObject]@{ Label = 'WU Cache';         Path = "$env:SystemRoot\SoftwareDistribution\Download" }
    )) { $paths.Add($entry) }

    # ── Enumerar todos los perfiles de usuario del equipo ──────────────────────
    # Win32_UserProfile primero (incluye perfiles de dominio con rutas no-estándar),
    # fallback a C:\Users\ si CIM no devuelve nada.
    [System.Collections.Generic.List[string]] $profileRoots =
        [System.Collections.Generic.List[string]]::new()

    [object[]] $wmiProfiles = @(
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) }
    )
    foreach ($p in $wmiProfiles) { $profileRoots.Add($p.LocalPath) }

    if ($profileRoots.Count -eq 0) {
        [System.Collections.Generic.HashSet[string]] $excluded =
            [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@('Public', 'Default', 'Default User', 'All Users'),
                [System.StringComparer]::OrdinalIgnoreCase
            )
        Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not $excluded.Contains($_.Name) } |
            ForEach-Object { $profileRoots.Add($_.FullName) }
    }

    foreach ($root in $profileRoots) {
        [string] $user  = Split-Path $root -Leaf
        [string] $local = Join-Path $root 'AppData\Local'
        [string] $roam  = Join-Path $root 'AppData\Roaming'

        # Temp del perfil
        [string] $tempPath = Join-Path $local 'Temp'
        if (Test-Path $tempPath -PathType Container) {
            $paths.Add([PSCustomObject]@{ Label = "Temp ($user)"; Path = $tempPath })
        }

        # Chromium-based: enumerar TODOS los perfiles del navegador (Default, Profile 1, Profile 2, ...)
        foreach ($br in @(
            [PSCustomObject]@{ Short = 'Chrome';   Base = "$local\Google\Chrome\User Data" }
            [PSCustomObject]@{ Short = 'Edge';     Base = "$local\Microsoft\Edge\User Data" }
            [PSCustomObject]@{ Short = 'Brave';    Base = "$local\BraveSoftware\Brave-Browser\User Data" }
            [PSCustomObject]@{ Short = 'Opera';    Base = "$local\Opera Software\Opera Stable" }
            [PSCustomObject]@{ Short = 'Opera GX'; Base = "$local\Opera Software\Opera GX Stable" }
        )) {
            if (-not (Test-Path $br.Base -PathType Container)) { continue }

            Get-ChildItem -Path $br.Base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' } |
                ForEach-Object {
                    [string] $profTag = if ($_.Name -eq 'Default') { '' } else { "/$($_.Name)" }
                    foreach ($cdir in @('Cache', 'Cache2', 'GPUCache')) {
                        [string] $cp = Join-Path $_.FullName $cdir
                        if (Test-Path $cp -PathType Container) {
                            $paths.Add([PSCustomObject]@{
                                Label = "$($br.Short)$profTag/$cdir ($user)"
                                Path  = $cp
                            })
                        }
                    }
                }
        }

        # Firefox — perfiles dinámicos desde %APPDATA%\Mozilla\Firefox\Profiles
        [string] $ffRoot = "$roam\Mozilla\Firefox\Profiles"
        if (Test-Path $ffRoot -PathType Container) {
            Get-ChildItem -Path $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                [string] $cache2 = Join-Path $_.FullName 'cache2'
                if (Test-Path $cache2 -PathType Container) {
                    [string] $ffShort = $_.Name
                    if ($ffShort.Length -gt 14) { $ffShort = $ffShort.Substring(0, 14) }
                    $paths.Add([PSCustomObject]@{
                        Label = "Firefox/$ffShort ($user)"
                        Path  = $cache2
                    })
                }
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

function Start-CleanupPreviewJob {
    <#
    .SYNOPSIS
        Escanea las rutas de limpieza de forma asíncrona y retorna el preview
        sin borrar nada.
    #>
    [CmdletBinding()]
    param()

    [string] $fnBodyPaths   = ${Function:_Get-CleanupPaths}.ToString()
    [string] $fnBodyPreview = ${Function:Get-CleanupPreview}.ToString()
    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function _Get-CleanupPaths {
$fnBodyPaths
}
function Get-CleanupPreview {
$fnBodyPreview
}
Get-CleanupPreview
"@)
    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'CleanupPreview'
}
