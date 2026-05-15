Set-StrictMode -Version Latest

function Get-LatestRestorePoint {
    <#
    .SYNOPSIS
        Lee el ultimo punto de restauracion del sistema. Read-only. Si no
        hay ninguno o System Restore esta deshabilitado, retorna $null.
    #>
    [CmdletBinding()]
    param()

    [object[]] $existing = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) { return $null }

    $latest = $existing | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
    [datetime] $latestTime = [Management.ManagementDateTimeConverter]::ToDateTime($latest.CreationTime)
    [double] $hoursAgo = [math]::Round(([datetime]::Now - $latestTime).TotalHours, 1)

    return [PSCustomObject]@{
        SequenceNumber = [int]      $latest.SequenceNumber
        CreationTime   = [datetime] $latestTime
        Description    = [string]   $latest.Description
        HoursAgo       = [double]   $hoursAgo
    }
}

function New-RestorePoint {
    <#
    .SYNOPSIS
        Crea un punto de restauracion del sistema. Por default respeta el
        cooldown de Windows (un RP por cada 24h). Con -BypassCooldown
        modifica temporalmente el registry SystemRestorePointCreationFrequency
        para forzar la creacion incluso si hay otro reciente.

        Bypass es necesario cuando: el operador ya hizo un RP hoy y quiere
        otro antes de un cambio mayor; o cuando un instalador automatico
        de Windows acaba de crear uno y el toolkit no encuentra ventana.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $BypassCooldown
    )

    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue

    # Reportar siempre el ultimo RP encontrado (no solo en el caso cooldown).
    $latest = Get-LatestRestorePoint

    if (-not $BypassCooldown -and $null -ne $latest -and $latest.HoursAgo -lt 24) {
        return [PSCustomObject]@{
            Success    = $false
            CooldownActive = $true
            LatestRp   = $latest
            Reason     = ('Cooldown activo: hay un RP de hace {0}h ("{1}"). Pasar -BypassCooldown para forzar uno nuevo.' -f $latest.HoursAgo, $latest.Description)
        }
    }

    # Bypass: registry SystemRestorePointCreationFrequency = 0 desactiva el limite.
    # Se restaura al valor previo en el finally para no dejar el sistema
    # creando RPs en cascada despues.
    [string] $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    [Nullable[int]] $previousFreq = $null
    if ($BypassCooldown) {
        try {
            $existingValue = Get-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            if ($null -ne $existingValue -and $null -ne $existingValue.PSObject.Properties['SystemRestorePointCreationFrequency']) {
                $previousFreq = [int] $existingValue.SystemRestorePointCreationFrequency
            }
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction Stop
        }
        catch { }
    }

    try {
        Checkpoint-Computer -Description 'Toolkit Pre-Service' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop

        return [PSCustomObject]@{
            Success        = $true
            CooldownActive = $false
            LatestRp       = $latest
            Bypassed       = [bool] $BypassCooldown
            Message        = 'Punto de restauracion creado exitosamente'
        }
    }
    catch {
        return [PSCustomObject]@{
            Success        = $false
            CooldownActive = $false
            LatestRp       = $latest
            Bypassed       = [bool] $BypassCooldown
            Message        = $_.Exception.Message
        }
    }
    finally {
        # Restaurar el registry si lo tocamos
        if ($BypassCooldown) {
            try {
                if ($null -ne $previousFreq) {
                    Set-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -Value $previousFreq -Type DWord -ErrorAction SilentlyContinue
                } else {
                    Remove-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
}

function Start-RestorePointProcess {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $BypassCooldown
    )

    $fnBodyLatest = ${Function:Get-LatestRestorePoint}.ToString()
    $fnBodyNew    = ${Function:New-RestorePoint}.ToString()
    [string] $bypassArg = if ($BypassCooldown) { '-BypassCooldown' } else { '' }

    $jobBlock = [scriptblock]::Create(@"
function Get-LatestRestorePoint {
$fnBodyLatest
}
function New-RestorePoint {
$fnBodyNew
}
New-RestorePoint $bypassArg
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'RestorePoint'
}
