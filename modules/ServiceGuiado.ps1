Set-StrictMode -Version Latest

# ─── ServiceGuiado.ps1 (#136) ──────────────────────────────────────────────────
# El [1] del menu principal: una lista en el orden de campo que llama a las
# teclas que ya existen. Cero tweaks propios: cada paso es una entrada de
# Get-ServiceGuiadoSpec (utils\ConsoleMenu.ps1) que invoca un handler existente.
#
# Sin auto-avance: cada paso corre solo por tecla; al terminar el operador dice
# como quedo (hecho / salteado / no lo hice, #139) y se vuelve a la lista con la
# marca '>' en el primer paso pendiente.
#
# DONDE VIVE EL ESTADO. El service no tiene carpeta propia: es
# output\state\current-run.json (modules\ServiceState.ps1), que abre el PRE ([3]
# o el paso 1) y borra el [L] (o el paso 10). Por eso el hecho/salteado va a un
# archivo hermano, output\state\guiado.json, atado al service por
# hostname + opened_at: un service nuevo no matchea y arranca con la lista limpia.
# Lo que el disco ya dice no se guarda: el paso 1 sale hecho si el service tiene
# pre_taken_at, aunque el PRE se haya tomado por el [3] suelto. Sin service
# abierto, el estado vive en memoria ($script:PctkGuiadoMem) y, si despues se
# abre un service (el paso 1), pasa a ese service.

function Get-PaqueteCampo {
    <#
    .SYNOPSIS
        El paquete de campo (data\paquete-campo.json): las tools que el paso 4
        premarca en [T]. Devuelve [object[]] de @{ Id; Nombre } (Id = name del
        manifest). Archivo ausente o roto -> lista vacia, nunca tira.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    [string] $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\paquete-campo.json'
    [object[]] $out = @()
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $j -and $null -ne $j.PSObject.Properties['tools']) {
            foreach ($t in @($j.tools)) {
                if ($null -eq $t -or $null -eq $t.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$t.id)) { continue }
                [string] $nombre = [string]$t.id
                if ($null -ne $t.PSObject.Properties['nombre'] -and -not [string]::IsNullOrWhiteSpace([string]$t.nombre)) { $nombre = [string]$t.nombre }
                $out += [PSCustomObject]@{ Id = [string]$t.id; Nombre = $nombre }
            }
        }
    } catch { }
    # Sin la coma: el caller lo pasa por el pipeline (Get-PaqueteCampo | ForEach-Object)
    # y con ', $out' le llegaria el array entero como UN objeto.
    return $out
}

function Get-ServiceGuiadoStatePath {
    <#
    .SYNOPSIS
        output\state\guiado.json: al lado de current-run.json (mismo directorio
        que Get-ServiceStatePath).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path (Split-Path -Parent (Get-ServiceStatePath)) 'guiado.json')
}

function Get-ServiceGuiadoService {
    # El service abierto de ESTA PC como @{ Id; Host; OpenedAt; PreTaken }, o $null.
    [CmdletBinding()]
    param()
    $st = $null
    try { $st = Get-ServiceState } catch { $st = $null }
    if ($null -eq $st) { return $null }
    try { if (Test-ServiceStateStale) { return $null } } catch { }
    if ($null -ne $st.PSObject.Properties['open'] -and -not [bool]$st.open) { return $null }
    [string] $hostName = if ($null -ne $st.PSObject.Properties['hostname']) { [string]$st.hostname } else { $env:COMPUTERNAME }
    [string] $opened   = if ($null -ne $st.PSObject.Properties['opened_at']) { [string]$st.opened_at } else { '' }
    [bool] $pre = $false
    if ($null -ne $st.PSObject.Properties['pre_taken_at']) {
        [string] $p = [string]$st.pre_taken_at
        $pre = (-not [string]::IsNullOrWhiteSpace($p) -and $p -ne 'null')
    }
    return [PSCustomObject]@{ Id = ('{0}|{1}' -f $hostName, $opened); Host = $hostName; OpenedAt = $opened; PreTaken = $pre }
}

function Read-ServiceGuiadoFile {
    # El estado guardado para ESE service (hashtable paso -> hecho/salteado); @{} si no hay o es de otro.
    param([Parameter(Mandatory)] [object] $Service)
    [hashtable] $h = @{}
    try {
        [string] $path = Get-ServiceGuiadoStatePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $h }
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $j -or $null -eq $j.PSObject.Properties['service'] -or [string]$j.service -ne [string]$Service.Id) { return $h }
        if ($null -ne $j.PSObject.Properties['pasos'] -and $null -ne $j.pasos) {
            foreach ($p in @($j.pasos.PSObject.Properties)) {
                if ([string]$p.Value -in @('hecho', 'salteado')) { $h[[string]$p.Name] = [string]$p.Value }
            }
        }
    } catch { }
    return $h
}

function Save-ServiceGuiadoFile {
    param([Parameter(Mandatory)] [object] $Service, [Parameter(Mandatory)] [hashtable] $Estado)
    try {
        [string] $path = Get-ServiceGuiadoStatePath
        [string] $dir  = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        $obj = [ordered]@{ schema_version = '1.0'; service = [string]$Service.Id; pasos = $Estado }
        ($obj | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-PctkWarn ('  [!] No se pudo guardar el estado del guiado: {0}' -f $_.Exception.Message)
    }
}

function Resolve-ServiceGuiadoEstado {
    # El estado que vale ahora para $Service (o sin service), y deja la memoria al dia.
    param([object] $Service)
    [hashtable] $estado = @{}
    # Get-Variable y no $script:PctkGuiadoMem: la primera vez que se entra al
    # guiado la variable no existe y StrictMode tira VariableIsUndefined.
    $mem = $null
    $memVar = Get-Variable -Name 'PctkGuiadoMem' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $memVar) { $mem = $memVar.Value }
    if ($null -ne $Service) {
        if ($null -ne $mem -and [string]$mem.Service -eq [string]$Service.Id) {
            $estado = $mem.Estado
        } else {
            $estado = Read-ServiceGuiadoFile -Service $Service
            # Lo hecho en este proceso ANTES de abrir el service es de esta visita.
            if ($estado.Count -eq 0 -and $null -ne $mem -and [string]$mem.Service -eq '') { $estado = $mem.Estado }
        }
        $script:PctkGuiadoMem = @{ Service = [string]$Service.Id; Estado = $estado }
    } else {
        if ($null -ne $mem -and [string]$mem.Service -eq '') { $estado = $mem.Estado }
        $script:PctkGuiadoMem = @{ Service = ''; Estado = $estado }
    }
    return $estado
}

function Set-ServiceGuiadoPaso {
    # Marca un paso (hecho/salteado) y lo persiste si hay service abierto. Valor ''
    # borra la marca (#139: re-correr un paso y contestar "no lo hice" lo deja
    # pendiente). Si el paso cerro el service (paso 10 / [L]), la lista vuelve a
    # arrancar limpia.
    param([Parameter(Mandatory)] [string] $Paso, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Valor, [object] $Antes)
    $svc = Get-ServiceGuiadoService
    if ($null -ne $Antes -and ($null -eq $svc -or [string]$svc.Id -ne [string]$Antes.Id)) {
        $script:PctkGuiadoMem = @{ Service = ''; Estado = @{} }
        return
    }
    [hashtable] $estado = Resolve-ServiceGuiadoEstado -Service $svc
    if ([string]::IsNullOrEmpty($Valor)) { $estado.Remove($Paso) } else { $estado[$Paso] = $Valor }
    if ($null -ne $svc) { Save-ServiceGuiadoFile -Service $svc -Estado $estado }
}

function Get-ServiceGuiadoMarca {
    # 'hecho' | 'salteado' | '' para un paso, con lo que dice el disco primero.
    param([int] $Paso, [hashtable] $Estado, [object] $Service)
    if ($Paso -eq 1 -and $null -ne $Service -and $Service.PreTaken) { return 'hecho' }
    [string] $k = [string]$Paso
    if ($Estado.ContainsKey($k)) { return [string]$Estado[$k] }
    return ''
}

function Show-ServiceGuiadoList {
    # Dibuja la lista (sin leer teclas). Devuelve el paso marcado (0 = ninguno pendiente).
    param([object] $Spec, [hashtable] $Estado, [object] $Service, [string] $Aviso = '')
    [int] $marcado = 0
    foreach ($p in @($Spec.Pasos)) {
        if ((Get-ServiceGuiadoMarca -Paso ([int]$p.Paso) -Estado $Estado -Service $Service) -eq '') { $marcado = [int]$p.Paso; break }
    }
    [string] $cab = '  SERVICE GUIADO  -  sin service abierto'
    if ($null -ne $Service) {
        [string] $cuando = [string]$Service.OpenedAt
        [DateTimeOffset] $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($cuando, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref] $dto)) {
            $cuando = $dto.ToString('dd/MM HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $cab = ('  SERVICE GUIADO  -  equipo: {0}  -  service abierto {1}' -f [string]$Service.Host, $cuando)
    }
    Clear-Host
    Write-Host ''
    Write-PctkLine -Text $cab -Kind 'section'
    Write-Host ''
    [int] $ancho = [int]$Spec.AnchoTexto
    foreach ($p in @($Spec.Pasos)) {
        [int] $n = [int]$p.Paso
        [string] $marca = Get-ServiceGuiadoMarca -Paso $n -Estado $Estado -Service $Service
        [string] $caja = switch ($marca) { 'hecho' { '[x]' } 'salteado' { '[-]' } default { '[ ]' } }
        [string] $pre = if ($n -eq $marcado) { ' > ' } else { '   ' }
        [string] $texto = [string]$p.Texto
        [string] $linea = $pre + $caja + ' ' + ([string]$n).PadRight(2) + ' ' + $texto
        [string] $extra = ''
        if ($marca -eq 'salteado') { $extra = 'salteado' }
        elseif (-not [string]::IsNullOrEmpty([string]$p.Aclaracion)) { $extra = '(' + [string]$p.Aclaracion + ')' }
        if ($extra -ne '') {
            [int] $relleno = 2
            if ($texto.Length -lt $ancho) { $relleno = $ancho - $texto.Length }
            $linea = $linea + (' ' * $relleno) + $extra
        }
        [string] $kind = 'value'
        if ($marca -eq 'hecho') { $kind = 'ok' } elseif ($marca -eq 'salteado') { $kind = 'hint' } elseif ($n -eq $marcado) { $kind = 'white' }
        Write-PctkLine -Text $linea -Kind $kind
    }
    Write-Host ''
    Write-PctkHint ('  [Enter] hacer el marcado   [S] saltear   [1-{0}] ir a un paso   [B] volver al menu' -f @($Spec.Pasos).Count)
    if (-not [string]::IsNullOrEmpty($Aviso)) { Write-PctkWarn $Aviso }
    return $marcado
}

function Invoke-ServiceGuiado {
    <#
    .SYNOPSIS
        Handler del [1] (#136): el service guiado.
    .DESCRIPTION
        Teclas: Enter corre el paso marcado; S lo saltea; un numero corre ese paso
        (aunque este hecho o salteado); B o X vuelven al menu principal.
        Al terminar un paso el guiado pregunta como quedo (#139): [H] hecho,
        [S] salteado, [N] o Enter no lo hice (queda pendiente; si tenia marca,
        se borra). Volver de un handler sin excepcion no lo marca hecho solo.
        Un paso que revienta queda auditado (Write-DispatchCrash, #52) y pendiente,
        sin preguntar; el guiado sigue.
    .OUTPUTS
        [bool] $true si el paso 10 lanzo la desinstalacion y PCTk tiene que
        cerrarse (el menu principal devuelve 'U', igual que con [L]); si no, $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)

    $spec = Get-ServiceGuiadoSpec
    [string] $aviso = ''
    while ($true) {
        $svc = Get-ServiceGuiadoService
        [hashtable] $estado = Resolve-ServiceGuiadoEstado -Service $svc
        [int] $marcado = Show-ServiceGuiadoList -Spec $spec -Estado $estado -Service $svc -Aviso $aviso
        $aviso = ''

        [string] $raw = ([string](Read-Host '  Opcion')).Trim().ToUpperInvariant()
        if ($raw -eq 'B' -or $raw -eq 'X') { return $false }

        [int] $n = 0
        if ($raw -eq '' -or $raw -eq 'S') {
            if ($marcado -eq 0) { $aviso = '  No quedan pasos pendientes: [B] para volver al menu.'; continue }
            if ($raw -eq 'S') {
                Set-ServiceGuiadoPaso -Paso ([string]$marcado) -Valor 'salteado' -Antes $svc
                continue
            }
            $n = $marcado
        } elseif (-not [int]::TryParse($raw, [ref] $n) -or $n -lt 1 -or $n -gt @($spec.Pasos).Count) {
            $aviso = ('  Opcion invalida: {0}' -f $raw)
            continue
        }

        $paso = @($spec.Pasos | Where-Object { [int]$_.Paso -eq $n })[0]
        Clear-Host
        [bool] $ok = $false
        [object[]] $res = @()
        try {
            if ([string]$paso.Salida -eq 'TerminaSiTrue') {
                $res = @(& $paso.Accion $MachineProfile)
            } else {
                # Lo que un handler deje en el pipeline se ve, pero no sale del guiado.
                & $paso.Accion $MachineProfile | Out-Host
            }
            $ok = $true
        }
        catch { Write-DispatchCrash -ErrorRecord $_ -Choice ([string]$n) -MenuLabel 'service guiado' }

        if ($ok -and [string]$paso.Salida -eq 'TerminaSiTrue' -and $res.Count -gt 0 -and $res[$res.Count - 1] -is [bool] -and $res[$res.Count - 1]) {
            return $true
        }
        if (-not $ok) {
            Write-Host ''
            Read-Host '  [Enter] para volver a la lista' | Out-Null
            continue
        }
        # #139: el estado lo dice el operador, no la ausencia de excepcion.
        [string] $valor = Read-ServiceGuiadoResultado -Paso $n
        Set-ServiceGuiadoPaso -Paso ([string]$n) -Valor $valor -Antes $svc
    }
}

function Read-ServiceGuiadoResultado {
    # #139: como quedo el paso que se acaba de correr. 'hecho' | 'salteado' | ''
    # (no lo hice: queda pendiente). Enter sin nada = no lo hice; otra tecla repregunta.
    param([int] $Paso)
    Write-Host ''
    Write-PctkHint ('  Como quedo el paso {0}?' -f $Paso)
    while ($true) {
        [string] $r = ([string](Read-Host '  [H] hecho   [S] salteado   [N] no lo hice (Enter = no lo hice)')).Trim().ToUpperInvariant()
        if ($r -eq 'H') { return 'hecho' }
        if ($r -eq 'S') { return 'salteado' }
        if ($r -eq '' -or $r -eq 'N') { return '' }
        Write-PctkWarn ('  Opcion invalida: {0}. Elegi H, S o N.' -f $r)
    }
}

function Invoke-ServiceGuiadoApps {
    <#
    .SYNOPSIS
        Paso 6 del guiado: elegir con que se desinstala. [1] la lista de PCTk
        (Invoke-ActionApps, el [A][8]) o [2] BCUninstaller (lo baja si falta y lo
        abre, con el mismo mecanismo que [T]).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    Write-PctkActionTitle 'DESINSTALAR APPS'
    Write-Host '  [1]  Lista de PCTk     (Win32 + UWP, se desinstala desde aca)'
    Write-Host '  [2]  BCUninstaller     (lo baja si falta y lo abre)'
    Write-Host '  [B]  Volver'
    Write-Host ''
    [string] $c = ([string](Read-Host '  Selecciona')).Trim().ToUpperInvariant()
    switch ($c) {
        '1' { Invoke-ActionApps -MachineProfile $MachineProfile }
        '2' { $null = Invoke-ToolFetchAndLaunch -Name 'bcu' }
        default { }
    }
}
