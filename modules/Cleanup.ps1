Set-StrictMode -Version Latest

function Clear-TempFiles {
    <#
    .SYNOPSIS
        Borra archivos temporales de rutas estándar de Windows, usuario y navegadores.
        Retorna un objeto con el espacio liberado y la cantidad de errores no críticos.
    #>
    [CmdletBinding()]
    param()

    $paths = @(
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\Prefetch",
        "$env:SystemRoot\SoftwareDistribution\Download",
        "$env:TEMP",
        "$env:LOCALAPPDATA\Temp",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Opera Software\Opera Stable\Cache",
        "$env:LOCALAPPDATA\Opera Software\Opera GX Stable\Cache",
        "$env:SystemRoot\Logs"
    )

    $totalFreedBytes = [long]0
    $softErrors      = 0

    foreach ($path in $paths) {
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

function Start-CleanupProcess {
    <#
    .SYNOPSIS
        Empaqueta Clear-TempFiles en un job asíncrono mediante Invoke-AsyncToolkitJob
        y retorna el objeto de trabajo para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param()

    $fnBody   = ${Function:Clear-TempFiles}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function Clear-TempFiles {
$fnBody
}
Clear-TempFiles
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DiskCleanup'
}
