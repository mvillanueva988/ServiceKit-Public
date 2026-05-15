Set-StrictMode -Version Latest

function Invoke-AsyncToolkitJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [Parameter()]
        [string] $JobName,

        [Parameter()]
        [object[]] $ArgumentList
    )

    $startJobParams = @{ ScriptBlock = $ScriptBlock }

    if ($PSBoundParameters.ContainsKey('JobName') -and -not [string]::IsNullOrWhiteSpace($JobName)) {
        $startJobParams['Name'] = $JobName
    }

    if ($PSBoundParameters.ContainsKey('ArgumentList') -and $null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
        $startJobParams['ArgumentList'] = $ArgumentList
    }

    return Start-Job @startJobParams
}

function Wait-ToolkitJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job[]] $Jobs,

        [Parameter()]
        [int] $TimeoutSeconds = 300
    )

    if ($null -eq $Jobs -or $Jobs.Count -eq 0) {
        # ',' fuerza que el caller reciba un array vacio, no $null.
        # Sin la coma, PowerShell unwrapea y el caller ve $null cuando
        # asigna `$x = Wait-ToolkitJobs ...`, rompiendo .Count y [0].
        return ,@()
    }

    $null = $Jobs | Wait-Job -Timeout $TimeoutSeconds

    [System.Management.Automation.Job[]] $unfinishedJobs = @($Jobs | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' })
    if ($unfinishedJobs.Count -gt 0) {
        foreach ($job in $unfinishedJobs) {
            Write-Host ("  [!] Trabajo '{0}' excedio el timeout ({1}s) y sera detenido." -f $job.Name, $TimeoutSeconds) -ForegroundColor Yellow
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
    }

    # Acumular en List<object> en vez de capturar el output de un foreach.
    # El patron `$results = foreach (...)` produce un array PERO al hacer
    # `return $results` PowerShell unwrapea si tiene 1 solo elemento, y
    # el caller termina con un objeto suelto sin .Count. List<object> +
    # ToArray() + ',' previene el unwrap.
    [System.Collections.Generic.List[object]] $resultsList = [System.Collections.Generic.List[object]]::new()
    foreach ($job in $Jobs) {
        [object] $r = if ($job.State -eq 'Failed') {
            [object[]] $childErrors = @($job.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ })
            [string] $errMsg = if ($childErrors.Count -gt 0) { $childErrors[0].Exception.Message } else { 'Error desconocido' }
            Write-Host ("  [!] Trabajo '{0}' fallo: {1}" -f $job.Name, $errMsg) -ForegroundColor Red
            Receive-Job -Job $job -AutoRemoveJob -Wait -ErrorAction SilentlyContinue
        }
        elseif ($job.State -eq 'Stopped') {
            Receive-Job -Job $job -AutoRemoveJob -Wait -ErrorAction SilentlyContinue
        }
        else {
            Receive-Job -Job $job -AutoRemoveJob -Wait
        }
        $resultsList.Add($r)
    }

    # ',' garantiza que se retorne el array como UN solo objeto que el
    # caller des-empaqueta de vuelta al array. Es el idiom PowerShell.
    return ,$resultsList.ToArray()
}

function Invoke-ModuleJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EntryPoint,

        [Parameter(Mandatory)]
        [scriptblock[]] $Functions,

        [Parameter()]
        [hashtable] $Params = @{},

        [Parameter()]
        [string] $JobName = $EntryPoint
    )

    if ([string]::IsNullOrWhiteSpace($EntryPoint)) {
        throw 'EntryPoint no puede estar vacio.'
    }

    if ($null -eq $Functions -or $Functions.Count -eq 0) {
        throw 'Debe proveer al menos una funcion para serializar en el job.'
    }

    [string[]] $functionDefinitions = @()

    for ($i = 0; $i -lt $Functions.Count; $i++) {
        [scriptblock] $fn = $Functions[$i]
        if ($null -eq $fn) {
            continue
        }

        [string] $fnText = $fn.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($fnText)) {
            continue
        }

        # Si ya viene como definicion completa (function Nombre { ... }), se usa tal cual.
        if ($fnText -match '^\s*function\s+[A-Za-z_][A-Za-z0-9_-]*\s*\{') {
            $functionDefinitions += $fnText
            continue
        }

        # Para compatibilidad con ${Function:Nombre}, ToString() devuelve el body.
        # El primer bloque se envuelve con el nombre del EntryPoint.
        if ($i -eq 0) {
            $functionDefinitions += ("function {0} {{`n{1}`n}}" -f $EntryPoint, $fnText)
            continue
        }

        throw 'Solo la primera funcion puede venir como body suelto. Las funciones auxiliares deben incluir declaracion completa: function Nombre { ... }'
    }

    if ($functionDefinitions.Count -eq 0) {
        throw 'No se pudo construir ninguna definicion de funcion valida para el job.'
    }

    $jobScript = {
        param(
            [string[]] $SerializedFunctions,
            [string] $SerializedEntryPoint,
            [hashtable] $SerializedParams
        )

        Set-StrictMode -Version Latest

        foreach ($fnDef in $SerializedFunctions) {
            Invoke-Expression $fnDef
        }

        if (-not (Get-Command -Name $SerializedEntryPoint -CommandType Function -ErrorAction SilentlyContinue)) {
            throw ("EntryPoint '{0}' no existe dentro del job." -f $SerializedEntryPoint)
        }

        if ($null -eq $SerializedParams) {
            $SerializedParams = @{}
        }

        return & $SerializedEntryPoint @SerializedParams
    }

    return Invoke-AsyncToolkitJob -ScriptBlock $jobScript -JobName $JobName -ArgumentList @($functionDefinitions, $EntryPoint, $Params)
}
