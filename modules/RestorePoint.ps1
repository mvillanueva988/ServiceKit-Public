Set-StrictMode -Version Latest

function New-RestorePoint {
    [CmdletBinding()]
    param()

    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue

    try {
        Checkpoint-Computer -Description 'Toolkit Pre-Service' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop

        return [PSCustomObject]@{
            Success = [bool] $true
            Message = [string] 'Punto de restauracion creado exitosamente'
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = [bool] $false
            Message = [string] $_.Exception.Message
        }
    }
}

function Start-RestorePointProcess {
    [CmdletBinding()]
    param()

    $fnBody   = ${Function:New-RestorePoint}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function New-RestorePoint {
$fnBody
}
New-RestorePoint
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'RestorePoint'
}
