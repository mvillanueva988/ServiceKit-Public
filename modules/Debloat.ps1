Set-StrictMode -Version Latest

function Disable-BloatServices {
    <#
    .SYNOPSIS
        Detiene y deshabilita la lista canónica de servicios bloat de Windows.
        Acepta una lista personalizada; si se omite, usa la lista por defecto.
        Retorna un objeto con contadores de éxito y errores.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $ServicesList
    )

    $defaultServices = @(
        'XblAuthManager',
        'XblGameSave',
        'XboxNetApiSvc',
        'XboxGipSvc',
        'Spooler',
        'PrintNotify',
        'Fax',
        'WMPNetworkSvc',
        'RemoteRegistry',
        'RemoteAccess',
        'DiagTrack',
        'dmwappushservice'
    )

    $targetServices = if ($ServicesList -and $ServicesList.Count -gt 0) { $ServicesList } else { $defaultServices }

    $disabled         = 0
    $failed           = 0
    $skipped          = 0  # servicio no existe en este sistema
    $alreadyDisabled  = 0  # ya estaba deshabilitado de antes
    $errors           = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $skippedNames = [System.Collections.Generic.List[string]]::new()

    foreach ($svcName in $targetServices) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop

            # Ya estaba disabled? Contar separado para distinguir "no hizo falta" vs "lo hicimos ahora"
            if ($svc.StartType -eq 'Disabled') {
                $alreadyDisabled++
                continue
            }

            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
            }

            Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
            $disabled++
        }
        catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
            # Servicio no existe en este sistema — comun en Windows Sandbox,
            # LTSC, o instalaciones minimal sin Xbox/Cortana/etc.
            $skipped++
            $skippedNames.Add($svcName)
        }
        catch {
            $failed++
            $errors.Add("$svcName : $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        Disabled        = $disabled
        AlreadyDisabled = $alreadyDisabled
        Skipped         = $skipped
        SkippedNames    = $skippedNames.ToArray()
        Failed          = $failed
        Errors          = $errors.ToArray()
        TotalTargeted   = $targetServices.Count
    }
}

function Start-DebloatProcess {
    <#
    .SYNOPSIS
        Empaqueta Disable-BloatServices en un job asíncrono mediante Invoke-AsyncToolkitJob
        y retorna el objeto de trabajo para su seguimiento con Wait-ToolkitJobs.
        Acepta una lista personalizada de servicios; si se omite, Disable-BloatServices usa su lista por defecto.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $ServicesList
    )

    # Serializar la función para que esté disponible en el runspace aislado del job
    $fnBody   = ${Function:Disable-BloatServices}.ToString()
    $jobBlock = [scriptblock]::Create(@"
param([string[]]`$ServicesList)
function Disable-BloatServices {
$fnBody
}
Disable-BloatServices -ServicesList `$ServicesList
"@)

    $argList = @(, [string[]]$(if ($ServicesList -and $ServicesList.Count -gt 0) { $ServicesList } else { @() }))

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DebloatServices' -ArgumentList $argList
}
