Set-StrictMode -Version Latest

# ─── ServiceState.ps1 ──────────────────────────────────────────────────────────
# Maneja el "service" (de PRE hasta [L] Cerrar). Un service = la visita completa
# al cliente: empieza cuando se toma el PRE y termina cuando se cierra con [L].
# El estado se guarda en output\state\current-run.json para sobrevivir reinicios
# de la consola sin perder el hilo.
#
# Estructura del JSON:
# {
#   "schema_version": "1.0",
#   "hostname": "NOMBRE-PC",
#   "opened_at": "2026-06-14T10:00:00-03:00",
#   "pre_taken_at": "2026-06-14T10:05:00-03:00",   <- null si todavia no se tomó
#   "open": true
# }
#
# NOTA sobre EAP (ErrorActionPreference): todas las funciones son puro file-read/
# write (no llaman exe nativos), así que no hay riesgo de NativeCommandError bajo
# EAP=Stop de main.ps1. Igual usamos try/catch defensivo para no tirar ante un
# JSON corrupto o un directorio que no existe todavia.

function Get-ServiceStatePath {
    <#
    .SYNOPSIS
        Devuelve la ruta completa a output\state\current-run.json.
        Acepta un override para tests (sin tocar el output real).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $OutputRootOverride = ''
    )

    # PSScriptRoot acá es modules\, el padre es la raiz del toolkit.
    [string] $root = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Split-Path -Parent $PSScriptRoot
    } else {
        $OutputRootOverride
    }

    return (Join-Path $root 'output\state\current-run.json')
}

function Get-ServiceState {
    <#
    .SYNOPSIS
        Lee y devuelve el estado de service actual, o $null si no existe / está
        corrupto. Nunca tira excepción: el toolkit no debe morir por un JSON roto.
    .OUTPUTS
        [PSCustomObject] con campos: schema_version, hostname, opened_at,
        pre_taken_at, open. O $null si ausente/ilegible.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = ''
    )

    [string] $path = Get-ServiceStatePath -OutputRootOverride $OutputRootOverride

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        [string] $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        return $obj
    } catch {
        # JSON corrupto o archivo bloqueado: devolver $null sin tirar
        return $null
    }
}

function Open-ServiceState {
    <#
    .SYNOPSIS
        Crea o actualiza current-run.json con hostname + opened_at.
        Idempotente: si ya existe un service abierto para ESTA PC, no lo pisa
        (para no borrar el pre_taken_at que ya estaba). Crea el directorio
        output\state\ si no existe todavia.
    .OUTPUTS
        [PSCustomObject] el estado resultante (recien guardado).
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = '',
        # Override de hora de apertura (para tests reproducibles)
        [string] $OpenedAtOverride = ''
    )

    [string] $path     = Get-ServiceStatePath -OutputRootOverride $OutputRootOverride
    [string] $stateDir = Split-Path -Parent $path

    # Crear el directorio si no existe (primera vez que se usa el service)
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop
    }

    # Si ya hay un service abierto para ESTA PC, no sobreescribimos
    # (podría perder el pre_taken_at ya registrado)
    $existing = Get-ServiceState -OutputRootOverride $OutputRootOverride
    if ($null -ne $existing -and
        $null -ne $existing.PSObject.Properties['hostname'] -and
        [string]$existing.hostname -eq $env:COMPUTERNAME -and
        $null -ne $existing.PSObject.Properties['open'] -and
        [bool]$existing.open -eq $true) {
        return $existing
    }

    [string] $now = if ([string]::IsNullOrEmpty($OpenedAtOverride)) {
        (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } else {
        $OpenedAtOverride
    }

    # Armamos el objeto de estado con valores iniciales
    $state = [ordered]@{
        schema_version = '1.0'
        hostname       = $env:COMPUTERNAME
        opened_at      = $now
        pre_taken_at   = $null
        open           = $true
    }

    try {
        ($state | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Si no se puede guardar, devolver igual el objeto (el service "esta en memoria")
        Write-PctkWarn ('  [!] No se pudo guardar el estado del service: {0}' -f $_.Exception.Message)
    }

    return ($state | ConvertTo-Json -Depth 3 | ConvertFrom-Json)
}

function Set-ServiceStatePreTaken {
    <#
    .SYNOPSIS
        Sella pre_taken_at = ahora en current-run.json. Llamar despues de que
        el PRE se guardó correctamente (Open-ServiceState + esta funcion forman
        la secuencia "apertura del service con PRE").
        Si no hay state abierto, crea uno (el PRE = inicio del service).
    .OUTPUTS
        [PSCustomObject] el estado actualizado, o $null si no se pudo guardar.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = '',
        [string] $PreTakenAtOverride = ''
    )

    # Asegurar que el service esté abierto antes de sellar el PRE
    $null = Open-ServiceState -OutputRootOverride $OutputRootOverride

    [string] $path = Get-ServiceStatePath -OutputRootOverride $OutputRootOverride

    $state = Get-ServiceState -OutputRootOverride $OutputRootOverride
    if ($null -eq $state) { return $null }

    [string] $now = if ([string]::IsNullOrEmpty($PreTakenAtOverride)) {
        (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } else {
        $PreTakenAtOverride
    }

    # Leer los campos existentes y actualizar solo pre_taken_at
    [string] $schVer    = if ($null -ne $state.PSObject.Properties['schema_version']) { [string]$state.schema_version } else { '1.0' }
    [string] $hostname  = if ($null -ne $state.PSObject.Properties['hostname'])       { [string]$state.hostname }       else { $env:COMPUTERNAME }
    [string] $openedAt  = if ($null -ne $state.PSObject.Properties['opened_at'])      { [string]$state.opened_at }      else { $now }

    $updated = [ordered]@{
        schema_version = $schVer
        hostname       = $hostname
        opened_at      = $openedAt
        pre_taken_at   = $now
        open           = $true
    }

    try {
        ($updated | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-PctkWarn ('  [!] No se pudo actualizar pre_taken_at: {0}' -f $_.Exception.Message)
        return $null
    }

    return ($updated | ConvertTo-Json -Depth 3 | ConvertFrom-Json)
}

function Test-ServiceStateStale {
    <#
    .SYNOPSIS
        Devuelve $true si el state.json existe y el hostname registrado es
        DISTINTO de este equipo. Esto pasa cuando el USB del técnico se
        conecta a otra PC sin haber cerrado el service de la anterior.
        Devuelve $false si no hay state, si el host coincide, o si el JSON está roto.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $OutputRootOverride = ''
    )

    $state = Get-ServiceState -OutputRootOverride $OutputRootOverride
    if ($null -eq $state) { return $false }
    if ($null -eq $state.PSObject.Properties['hostname']) { return $false }
    # Si el hostname es distinto = state de otra PC (stale)
    return ([string]$state.hostname -ne $env:COMPUTERNAME)
}

function Close-ServiceState {
    <#
    .SYNOPSIS
        Cierra el service: borra current-run.json (el bundle ZIP ya contiene todo,
        es el registro definitivo). Opcionalmente agrega una linea a closed-runs.log
        para historial liviano.
        Seguro de llamar aunque no haya state (no tira, solo avisa).
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = '',
        # Pasar $false en tests para no escribir el log de historial
        [bool]   $WriteClosedLog = $true
    )

    [string] $path     = Get-ServiceStatePath -OutputRootOverride $OutputRootOverride
    [string] $stateDir = Split-Path -Parent $path

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        # No hay state que cerrar; no es un error
        return
    }

    # Antes de borrar, leer el estado para el log de historial
    $state = Get-ServiceState -OutputRootOverride $OutputRootOverride

    # Borrar el archivo de estado activo (D3: borramos, el ZIP es el registro)
    try {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    } catch {
        Write-PctkWarn ('  [!] No se pudo borrar el state file: {0}' -f $_.Exception.Message)
        return
    }

    # Historial liviano en closed-runs.log (una linea por service cerrado)
    # Útil para ver cuántos services se hicieron desde este USB sin abrir cada ZIP.
    if ($WriteClosedLog -and $null -ne $state) {
        [string] $logPath = Join-Path $stateDir 'closed-runs.log'
        try {
            [string] $openedAt   = if ($null -ne $state.PSObject.Properties['opened_at'])    { [string]$state.opened_at }    else { 'unknown' }
            [string] $preAt      = if ($null -ne $state.PSObject.Properties['pre_taken_at']) { [string]$state.pre_taken_at } else { 'sin-pre' }
            [string] $closedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            [string] $hostname   = if ($null -ne $state.PSObject.Properties['hostname'])     { [string]$state.hostname }     else { $env:COMPUTERNAME }
            [string] $logLine    = ('{0} | host={1} | opened={2} | pre={3} | closed={4}' -f $closedAt, $hostname, $openedAt, $preAt, $closedAt)
            Add-Content -LiteralPath $logPath -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            # El log de historial es opcional; si falla, no importa
        }
    }
}

# ─── Marcador del ultimo bundle ────────────────────────────────────────────────
# POR QUE EXISTE: el [L] cierra el service borrando current-run.json, asi que
# despues del cierre "nunca hubo service" y "el service ya se cerro" se ven
# IGUAL. El [U] usaba eso para decidir si empaquetar -> hacer [L] y despues [U]
# (el flujo natural: me llevo el paquete y dejo la PC limpia) dejaba DOS ZIP en
# el Escritorio del cliente, y el segundo peor (sin POST, "bundle parcial").
# Este marcador es el dato que faltaba: quien cerro, cuando, y donde quedo el ZIP.

function Get-LastBundleMarkerPath {
    <#
    .SYNOPSIS
        Ruta de output\state\last-bundle.json.
        OJO con $OutputRootOverride: igual que Get-ServiceStatePath, recibe la
        RAIZ DEL TOOLKIT (le agrega 'output\state'), NO la carpeta output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $OutputRootOverride = ''
    )

    [string] $root = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Split-Path -Parent $PSScriptRoot
    } else {
        $OutputRootOverride
    }

    return (Join-Path $root 'output\state\last-bundle.json')
}

function Set-LastBundleMarker {
    <#
    .SYNOPSIS
        Sella "el bundle de esta PC ya se genero" con la ruta del ZIP.
        Lo llama Invoke-CloseService cuando el paquete salio OK. Nunca tira: si
        no se puede escribir, el peor caso es que el [U] vuelva a empaquetar
        (molesto, no destructivo).
    .OUTPUTS
        [string] la ruta del marcador escrito, o '' si no se pudo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [string] $OutputRootOverride = '',
        [string] $ClosedAtOverride   = ''
    )

    [string] $path     = Get-LastBundleMarkerPath -OutputRootOverride $OutputRootOverride
    [string] $stateDir = Split-Path -Parent $path

    try {
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop
        }

        [string] $closedAt = if ([string]::IsNullOrEmpty($ClosedAtOverride)) {
            (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        } else {
            $ClosedAtOverride
        }

        $marker = [ordered]@{
            schema_version = '1.0'
            hostname       = $env:COMPUTERNAME
            closed_at      = $closedAt
            zip_path       = $ZipPath
        }

        ($marker | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
        return $path
    } catch {
        return ''
    }
}

function Get-LastBundleMarker {
    <#
    .SYNOPSIS
        Lee el marcador, o $null si no existe / esta corrupto. Nunca tira.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = ''
    )

    [string] $path = Get-LastBundleMarkerPath -OutputRootOverride $OutputRootOverride
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        [string] $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-BundleAlreadyTaken {
    <#
    .SYNOPSIS
        $true si YA se genero el bundle para ESTA PC (marcador presente y
        hostname coincidente). Un marcador de otra PC (USB del tecnico que viene
        de otro cliente) NO cuenta: ahi hay que empaquetar igual.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $OutputRootOverride = ''
    )

    $marker = Get-LastBundleMarker -OutputRootOverride $OutputRootOverride
    if ($null -eq $marker) { return $false }
    if ($null -eq $marker.PSObject.Properties['hostname']) { return $false }
    return ([string]$marker.hostname -eq $env:COMPUTERNAME)
}

# ─── Si el paquete ya viajo al CRM ────────────────────────────────────────────
# POR QUE EXISTE (backlog #41, cazado en campo 2026-08-01): el marcador decia
# que el paquete se HIZO, pero no si se SUBIO. Sin ese dato, la unica forma de
# reintentar una subida que fallo era apretar el [L] otra vez -- y eso arma un
# paquete NUEVO, con otro nombre y otra hora. Consecuencias medidas en la
# notebook de Mateo: dos ZIP a 41 segundos uno del otro en el Escritorio, y la
# proteccion anti-duplicados del CRM sin poder ayudar, porque el identificador
# sale del nombre del archivo y el archivo era otro.

function Set-BundleUploadedMarker {
    <#
    .SYNOPSIS
        Anota en el marcador que ESE paquete ya esta en el CRM.

        Lee y reescribe conservando lo que habia: el marcador tambien es lo que
        usa el [U] para no re-empaquetar, asi que pisarlo con un objeto nuevo
        romperia esa otra funcion desde el costado.
    .OUTPUTS
        [bool] $true si quedo anotado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $OutputRootOverride = '',
        [string] $UploadedAtOverride = ''
    )

    $marker = Get-LastBundleMarker -OutputRootOverride $OutputRootOverride
    if ($null -eq $marker) { return $false }

    [string] $cuando = ''
    if ([string]::IsNullOrEmpty($UploadedAtOverride)) {
        $cuando = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } else {
        $cuando = $UploadedAtOverride
    }

    try {
        $marker | Add-Member -NotePropertyName 'subido_en' -NotePropertyValue $cuando -Force
        [string] $path = Get-LastBundleMarkerPath -OutputRootOverride $OutputRootOverride
        ($marker | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        # Perder esta anotacion no pierde nada: el paquete YA se subio. Lo peor
        # que pasa es que la proxima vez se vuelva a ofrecer subirlo, y el CRM
        # conteste "ya lo tenia" sin duplicar.
        return $false
    }
}

function Get-BundlePendienteDeSubir {
    <#
    .SYNOPSIS
        El paquete de ESTA PC que existe en disco y todavia NO viajo al CRM.
        $null si no hay ninguno.

        LAS TRES CONDICIONES SON LAS TRES NECESARIAS:
        · de esta PC   -- un marcador de otro cliente no se ofrece jamas;
        · el ZIP existe -- si el operador ya se lo llevo y lo borro, ofrecer
                          subir un archivo que no esta seria una promesa vacia;
        · sin subir     -- si ya viajo, no hay nada que reintentar.
    .OUTPUTS
        [PSCustomObject] con ZipPath y ClosedAt, o $null.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = ''
    )

    $marker = Get-LastBundleMarker -OutputRootOverride $OutputRootOverride
    if ($null -eq $marker) { return $null }

    if ($null -eq $marker.PSObject.Properties['hostname']) { return $null }
    if ([string]$marker.hostname -ne $env:COMPUTERNAME) { return $null }

    if ($null -ne $marker.PSObject.Properties['subido_en'] -and
        -not [string]::IsNullOrWhiteSpace([string]$marker.subido_en)) {
        return $null
    }

    if ($null -eq $marker.PSObject.Properties['zip_path']) { return $null }
    [string] $zip = [string]$marker.zip_path
    if ([string]::IsNullOrWhiteSpace($zip)) { return $null }
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { return $null }

    [string] $closedAt = ''
    if ($null -ne $marker.PSObject.Properties['closed_at']) { $closedAt = [string]$marker.closed_at }

    return [PSCustomObject]@{ ZipPath = $zip; ClosedAt = $closedAt }
}

function Get-BundlePendienteDescripcion {
    <#
    .SYNOPSIS
        Cuando es el paquete pendiente, en criollo ("Es del 01/08, hace 7 dias").

        Backlog #48, cazado en uso: la pregunta del [L] mostraba SOLO el nombre
        del archivo (MATEO-NOTEBOOK_20260801-025514_...), con la fecha embebida
        en un formato que hay que decodificar leyendo. Mateo subio un paquete de
        hacia una semana creyendo que era el de hoy, y quedo pensando que la
        subida estaba rota. Con la edad a la vista, la respuesta habria sido otra.

        Devuelve '' si la fecha no se puede leer: mejor no decir nada que decir
        una edad inventada.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [string] $ClosedAt,
        [datetime] $Ahora = (Get-Date)
    )

    if ([string]::IsNullOrWhiteSpace($ClosedAt)) { return '' }

    $cuando = [System.DateTimeOffset]::MinValue
    if (-not [System.DateTimeOffset]::TryParse($ClosedAt, [ref]$cuando)) { return '' }

    [datetime] $dia = $cuando.ToLocalTime().Date
    [int] $dias = ($Ahora.Date - $dia).Days

    if ($dias -le 0) { return 'Es de HOY.' }
    if ($dias -eq 1) { return ('Es de AYER ({0}).' -f $dia.ToString('dd/MM')) }
    return ('Es del {0} (hace {1} dias).' -f $dia.ToString('dd/MM'), $dias)
}
