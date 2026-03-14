Set-StrictMode -Version Latest

function Invoke-AsyncToolkitJob {
    <#
    .SYNOPSIS
        Inicia un scriptblock de forma asíncrona mediante Start-Job y retorna el objeto del trabajo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [Parameter()]
        [string] $JobName,

        [Parameter()]
        [object[]] $ArgumentList
    )

    $params = @{ ScriptBlock = $ScriptBlock }

    if ($PSBoundParameters.ContainsKey('JobName') -and -not [string]::IsNullOrWhiteSpace($JobName)) {
        $params['Name'] = $JobName
    }

    if ($PSBoundParameters.ContainsKey('ArgumentList') -and $ArgumentList.Count -gt 0) {
        $params['ArgumentList'] = $ArgumentList
    }

    return Start-Job @params
}

function Wait-ToolkitJobs {
    <#
    .SYNOPSIS
        Espera a que un array de jobs finalice, mostrando un spinner visual en consola.
        Retorna la salida agregada de todos los trabajos al completarse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job[]] $Jobs
    )

    while ($true) {
        [System.Management.Automation.Job[]] $runningJobs = @($Jobs | Where-Object { $_.State -eq 'Running' })
        if ($runningJobs.Count -eq 0) {
            break
        }

        # Evitar render dinamico (spinner/progress) porque en algunas consolas VM
        # produce solapado visual con los menus y tablas.
        Start-Sleep -Milliseconds 120
    }

    $results = foreach ($job in $Jobs) {
        if ($job.State -eq 'Failed') {
            [object[]] $childErrors = @($job.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ })
            [string] $errMsg = if ($childErrors.Count -gt 0) { $childErrors[0].Exception.Message } else { 'Error desconocido' }
            Write-Host ("  [!] Trabajo '{0}' fallo: {1}" -f $job.Name, $errMsg) -ForegroundColor Red
            Receive-Job -Job $job -AutoRemoveJob -Wait -ErrorAction SilentlyContinue
        } else {
            Receive-Job -Job $job -AutoRemoveJob -Wait
        }
    }

    return $results
}