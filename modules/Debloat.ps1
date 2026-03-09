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

    $disabled = 0
    $failed   = 0
    $errors   = [System.Collections.Generic.List[string]]::new()

    foreach ($svcName in $targetServices) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop

            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
            }

            Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
            $disabled++
        }
        catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
            # Servicio no existe en este sistema — omitir silenciosamente
        }
        catch {
            $failed++
            $errors.Add("$svcName : $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        Disabled = $disabled
        Failed   = $failed
        Errors   = $errors.ToArray()
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
