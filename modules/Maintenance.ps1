Set-StrictMode -Version Latest

function Repair-WindowsSystem {
    <#
    .SYNOPSIS
        Ejecuta DISM RestoreHealth y SFC scannow secuencialmente.
        Retorna un objeto con los códigos de salida de cada proceso.
    #>
    [CmdletBinding()]
    param()

    [string[]] $dismOutput = @(& dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1)
    [int] $dismExitCode    = $LASTEXITCODE

    [string[]] $sfcOutput = @(& sfc.exe /scannow 2>&1)
    [int] $sfcExitCode    = $LASTEXITCODE

    return [PSCustomObject]@{
        DismExitCode = $dismExitCode
        DismOutput   = $dismOutput
        SfcExitCode  = $sfcExitCode
        SfcOutput    = $sfcOutput
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
