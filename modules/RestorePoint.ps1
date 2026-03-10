Set-StrictMode -Version Latest

function New-RestorePoint {
    [CmdletBinding()]
    param()

    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue

    [object[]] $existing = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $latest = $existing | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
        [datetime] $latestTime = [Management.ManagementDateTimeConverter]::ToDateTime($latest.CreationTime)
        if (([datetime]::Now - $latestTime).TotalHours -lt 24) {
            return [PSCustomObject]@{
                Success = [bool] $false
                Reason  = [string] 'Cooldown activo: el ultimo punto de restauracion fue creado hace menos de 24 horas. Windows no permite crear otro.'
            }
        }
    }

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
