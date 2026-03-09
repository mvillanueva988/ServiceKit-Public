Set-StrictMode -Version Latest

function Repair-WindowsSystem {
    <#
    .SYNOPSIS
        Ejecuta DISM RestoreHealth y SFC scannow secuencialmente.
        Retorna un objeto con los códigos de salida de cada proceso.
    #>
    [CmdletBinding()]
    param()

    DISM /Online /Cleanup-Image /RestoreHealth *> $null
    $dismExitCode = $LASTEXITCODE

    sfc /scannow *> $null
    $sfcExitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        DismExitCode = $dismExitCode
        SfcExitCode  = $sfcExitCode
    }
}

function Start-MaintenanceProcess {
    <#
    .SYNOPSIS
        Empaqueta Repair-WindowsSystem en un job asíncrono mediante Invoke-AsyncToolkitJob
        y retorna el objeto de trabajo para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param()

    $fnBody   = ${Function:Repair-WindowsSystem}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function Repair-WindowsSystem {
$fnBody
}
Repair-WindowsSystem
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'SystemMaintenance'
}
