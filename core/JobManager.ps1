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

    $spinnerFrames = @('|', '/', '-', '\')
    $frameIndex    = 0

    while ($Jobs | Where-Object { $_.State -eq 'Running' }) {
        $frame  = $spinnerFrames[$frameIndex % $spinnerFrames.Length]
        $frameIndex++

        $running = @($Jobs | Where-Object { $_.State -eq 'Running' }).Count
        Write-Host -NoNewline ("`r  {0}  Ejecutando trabajos... ({1} activos)" -f $frame, $running)

        Start-Sleep -Milliseconds 120
    }

    # Limpiar línea del spinner
    Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline

    $results = foreach ($job in $Jobs) {
        Receive-Job -Job $job -AutoRemoveJob -Wait
    }

    return $results
}