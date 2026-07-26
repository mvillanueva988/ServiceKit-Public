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
            Write-PctkWarn ("  [!] Trabajo '{0}' excedio el timeout ({1}s) y sera detenido." -f $job.Name, $TimeoutSeconds)
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
            Write-PctkErr ("  [!] Trabajo '{0}' fallo: {1}" -f $job.Name, $errMsg)
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

# ─── Invoke-JobWithProgress ───────────────────────────────────────────────────
# Wrapper de accion suelta: habilita la barra de progreso indeterminada para
# llamadas fuera del pipeline auto/named (acciones del submenu individual).
# Contrato de retorno IDENTICO a Wait-ToolkitJobs: return ,$result (array
# siempre). El finally garantiza Write-Progress -Completed para que la barra
# no quede colgada al volver al menu. StrictMode-safe; costo-cero.
function Invoke-JobWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job[]] $Jobs,

        # Activity no puede ser vacio: Write-Progress lo requiere.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Activity,

        [Parameter()]
        [int] $TimeoutSeconds = 300
    )

    # Habilitar el flag de progreso para esta llamada standalone.
    # Save/restore: si $script:PctkProgressEnabled fue puesto $false por un
    # contexto -Unattended, se restaura en el finally.
    # $script:PctkProgressOk silencia la barra si el host no es interactivo
    # (primer Write-Progress fallido -> flag $false permanente, defensivo).
    [bool] $prevEnabled = $script:PctkProgressEnabled
    $script:PctkProgressEnabled = $true

    [object[]] $result = @()
    try {
        $result = Wait-ToolkitJobs -Jobs $Jobs -TimeoutSeconds $TimeoutSeconds `
                    -ShowProgress -ActivityLabel $Activity -PercentHint -1
    } finally {
        $script:PctkProgressEnabled = $prevEnabled
        # Nunca dejar la barra colgada al volver al menu.
        try { Write-Progress -Id 1 -Activity $Activity -Completed } catch { }
    }

    # Preservar el idiom de retorno: ',' evita que PowerShell unwrapee el array.
    # El caller usa [0] o itera sobre el resultado igual que con Wait-ToolkitJobs.
    return ,$result
}

# NOTA (2026-07-25): aca vivia Invoke-ModuleJob, un serializador generico de
# modulos a background job. Se BORRO: tenia CERO adopters (los ~14 sitios de job
# arman su here-string a mano) y ademas reconstituia las funciones dentro del job
# con Invoke-Expression. Mentia sobre ser el patron canonico y confundia al que
# lo leyera. Lo que SI cubre esta clase de bug es tests\job-closure.ps1 (#26-A1),
# la red estatica que verifica el cierre transitivo de cada sitio de serializacion.

# ─── Test-StepSucceeded ───────────────────────────────────────────────────────
# Helper compartido: Invoke-AutoProfile y Invoke-NamedProfile lo usan via adapter
# para determinar si un step de pipeline termino con exito real (no solo no-null).
# Orden de inspeccion (D-SD2 adapters, structural-debt-plan.md §ITEM C):
#   1. $null        -> fallo
#   2. prop .Success presente -> usarla (semantica explicita)
#   3. prop .Errors presente  -> @(.Errors).Count -eq 0
#   4. prop .Failed numerico  -> .Failed -eq 0
#   5. prop .Error no vacia   -> fallo
#   6. objeto presente y no-null -> exito best-effort
# NUNCA throw. StrictMode-safe: usa PSObject.Properties para chequear props.
function Test-StepSucceeded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()] [object] $StepResult
    )

    # (1) null -> fallo
    if ($null -eq $StepResult) { return $false }

    # (2) .Success presente -> usarla
    [object] $successProp = $StepResult.PSObject.Properties['Success']
    if ($null -ne $successProp) {
        return [bool]$successProp.Value
    }

    # (3) .Errors presente -> Count == 0
    [object] $errorsProp = $StepResult.PSObject.Properties['Errors']
    if ($null -ne $errorsProp) {
        return (@($errorsProp.Value).Count -eq 0)
    }

    # (4) .Failed numerico -> Failed == 0
    [object] $failedProp = $StepResult.PSObject.Properties['Failed']
    if ($null -ne $failedProp) {
        [int] $failedVal = 0
        if ([int]::TryParse([string]$failedProp.Value, [ref]$failedVal)) {
            return ($failedVal -eq 0)
        }
        # Si no parsea como int, tratar como desconocido -> fallo conservador
        return $false
    }

    # (5) .Error no vacio -> fallo
    [object] $errorProp = $StepResult.PSObject.Properties['Error']
    if ($null -ne $errorProp) {
        [string] $errVal = [string]$errorProp.Value
        if (-not [string]::IsNullOrWhiteSpace($errVal)) {
            return $false
        }
    }

    # (6) presente y no-null -> exito best-effort
    return $true
}
