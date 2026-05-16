Set-StrictMode -Version Latest

# R4: flags script-scope inicializados siempre post Set-StrictMode.
# PctkProgressEnabled: el engine lo pone $true al arrancar un run con -ShowProgress,
# $false si -Unattended o sin -ShowProgress, y lo resetea a $false al cerrar.
# PctkProgressOk: al primer fallo de Write-Progress -> $false; no se reintenta.
$script:PctkProgressEnabled = $false
$script:PctkProgressOk      = $true

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
        [int] $TimeoutSeconds = 300,

        # R3: opt-IN; solo el engine auto/named lo pasa.
        # Las ~13 llamadas de Router.ps1 quedan intactas (sin barra).
        [Parameter()]
        [switch] $ShowProgress,

        # R5: Activity no puede ser vacio; default no-vacio garantizado.
        [Parameter()]
        [string] $ActivityLabel = 'PCTk',

        # R8: el engine pasa el % de la fase; -1 = indeterminado (sin PercentComplete).
        [Parameter()]
        [int] $PercentHint = -1
    )

    if ($null -eq $Jobs -or $Jobs.Count -eq 0) {
        # ',' fuerza que el caller reciba un array vacio, no $null.
        # Sin la coma, PowerShell unwrapea y el caller ve $null cuando
        # asigna `$x = Wait-ToolkitJobs ...`, rompiendo .Count y [0].
        return ,@()
    }

    # R4/R5: mostrar barra solo si el caller opto-in Y el engine habilito el flag Y
    # Write-Progress no fallo antes (host no interactivo).
    # R6/D2: usar Wait-Job -Any -Timeout 1 en lugar de Start-Sleep 750ms para
    # eliminar la regresion de latencia (~4.5s en pipeline completo). Wait-Job -Any
    # bloquea eficiente en wait-handles .NET (CPU cero, no busy-wait) y despierta
    # apenas termina un job -> latencia agregada nula + refresco responsivo.
    [int] $PollSeconds = 1
    [System.Diagnostics.Stopwatch] $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        [int] $running = @($Jobs | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' }).Count
        if ($running -eq 0) { break }

        # R4: triple guarda antes de Write-Progress
        if ($ShowProgress -and $script:PctkProgressEnabled -and $script:PctkProgressOk) {
            # R5: Activity siempre no-vacio; PercentComplete solo si PercentHint >= 0
            [string] $actLabel = if ([string]::IsNullOrWhiteSpace($ActivityLabel)) { 'PCTk' } else { $ActivityLabel }
            [string] $statusTxt = ('En curso... {0}s ({1} trabajo/s)' -f [int]$sw.Elapsed.TotalSeconds, $running)
            [hashtable] $wpSplat = @{
                Id       = 1
                Activity = $actLabel
                Status   = $statusTxt
            }
            if ($PercentHint -ge 0) { $wpSplat['PercentComplete'] = $PercentHint }
            try {
                Write-Progress @wpSplat
            } catch {
                # R4: primer fallo -> silenciar permanentemente; nunca throw
                $script:PctkProgressOk = $false
            }
        }

        # Esperar hasta que algun job termine o se cumpla el poll window
        $Jobs | Wait-Job -Any -Timeout $PollSeconds | Out-Null

    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds)

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
