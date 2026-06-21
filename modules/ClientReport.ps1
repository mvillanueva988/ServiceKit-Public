Set-StrictMode -Version Latest

# Buffer de render compartido entre New-ClientReport y sus helpers internos.
# Se inicializa al comienzo de cada llamada a New-ClientReport y no se expone.
[System.Collections.Generic.List[string]] $script:_crBuf = $null

# ─── Helpers internos de render (acceden a $script:_crBuf) ───────────────────

function _CR_H {
    param([string] $line)
    $script:_crBuf.Add($line)
}

function _CR_Esc {
    param([string] $s)
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    $s = $s -replace '"', '&quot;'
    return $s
}

function _CR_Row {
    param([string] $label, [string] $value)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '0' -or $value -eq '-') { return }
    _CR_H ('        <tr><td class="lbl">{0}</td><td>{1}</td></tr>' -f (_CR_Esc $label), (_CR_Esc $value))
}

function _CR_CheckItem {
    param([string] $text, [bool] $done)
    [string] $cls  = if ($done) { 'check-ok' } else { 'check-skip' }
    [string] $mark = if ($done) { '&check;' } else { '&#8211;' }
    _CR_H ('        <li class="{0}"><span class="mark">{1}</span> {2}</li>' -f $cls, $mark, (_CR_Esc $text))
}

function _CR_DeltaRow {
    param([string] $label, [string] $before, [string] $after, [string] $note)
    _CR_H '        <tr>'
    _CR_H ('          <td class="lbl">{0}</td>'          -f (_CR_Esc $label))
    _CR_H ('          <td class="before">{0}</td>'       -f (_CR_Esc $before))
    _CR_H ('          <td class="after">{0}</td>'        -f (_CR_Esc $after))
    [string] $noteTd = if ([string]::IsNullOrWhiteSpace($note)) { '' } else { _CR_Esc $note }
    _CR_H ('          <td class="delta-note">{0}</td>'   -f $noteTd)
    _CR_H '        </tr>'
}

# ─── New-ClientReport ─────────────────────────────────────────────────────────
function New-ClientReport {
    <#
    .SYNOPSIS
        Genera un reporte HTML autocontenido para mostrarle al cliente al cierre
        del servicio. Sin internet, sin JS, sin dependencias externas.
        Imprimible a PDF via Ctrl+P del navegador.

        3 paneles honestos:
          1. Tu equipo       - ficha del snapshot POST
          2. Que hicimos     - checklist del run (solo lo que realmente corrio)
          3. Antes y despues - deltas reales del Compare

        Si faltan datos (no hay Compare, no hay POST) los paneles se omiten
        con una nota suave. Nunca se fabrica un delta.

    .PARAMETER Result
        El objeto de Invoke-AutoProfile ($fullResult). Opcional. Si se omite,
        se usan PostSnapshot y Compare directamente.

    .PARAMETER PostSnapshot
        Objeto del snapshot POST. Opcional; si falta se lee post.json del
        directorio Result.ClientRun.Dir.

    .PARAMETER Compare
        Objeto Compare-Snapshot. Opcional; si falta se toma de Result.Compare.

    .PARAMETER OutputPath
        Ruta donde escribir el .html. Obligatorio.

    .PARAMETER OpenAfter
        Si esta presente, abre el .html en el navegador predeterminado.

    .OUTPUTS
        PSCustomObject con Success / FilePath.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCustomObject] $Result = $null,

        [Parameter()]
        [PSCustomObject] $PostSnapshot = $null,

        [Parameter()]
        [PSCustomObject] $Compare = $null,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [Parameter()]
        [switch] $OpenAfter
    )

    # Inicializar buffer de render
    $script:_crBuf = [System.Collections.Generic.List[string]]::new()

    # ── Resolver PostSnapshot ─────────────────────────────────────────────────
    if ($null -eq $PostSnapshot -and $null -ne $Result) {
        # Intentar desde Result.PostSnapshot
        [object] $psObj = $Result.PSObject.Properties['PostSnapshot']
        if ($null -ne $psObj -and $null -ne $psObj.Value) {
            [PSCustomObject] $psVal = $psObj.Value
            if ($null -ne $psVal.PSObject.Properties['Ok'] -and $psVal.Ok -and
                $null -ne $psVal.PSObject.Properties['FilePath'] -and
                (Test-Path -LiteralPath ([string]$psVal.FilePath))) {
                try {
                    $PostSnapshot = Get-Content -LiteralPath ([string]$psVal.FilePath) -Raw -Encoding UTF8 | ConvertFrom-Json
                } catch { $PostSnapshot = $null }
            }
        }
        # Fallback: post.json en la carpeta de run
        if ($null -eq $PostSnapshot) {
            [object] $crObj = $Result.PSObject.Properties['ClientRun']
            if ($null -ne $crObj -and $null -ne $crObj.Value) {
                [string] $runDir = [string]$crObj.Value.Dir
                if (-not [string]::IsNullOrEmpty($runDir)) {
                    [string] $postPath = Join-Path $runDir 'post.json'
                    if (Test-Path -LiteralPath $postPath) {
                        try {
                            $PostSnapshot = Get-Content -LiteralPath $postPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        } catch { $PostSnapshot = $null }
                    }
                }
            }
        }
    }

    # ── Resolver Compare ──────────────────────────────────────────────────────
    if ($null -eq $Compare -and $null -ne $Result) {
        [object] $cmpObj = $Result.PSObject.Properties['Compare']
        if ($null -ne $cmpObj) { $Compare = $cmpObj.Value }
    }

    # ── Metadata del run ──────────────────────────────────────────────────────
    [string] $pcName     = if ($null -ne $PostSnapshot) { [string]$PostSnapshot.ComputerName } else { $env:COMPUTERNAME }
    [string] $reportDate = (Get-Date -Format 'dd/MM/yyyy HH:mm')
    # Datos del tecnico: salen de data\tecnico.json, no del codigo (2026-07-25).
    # Antes estaban hardcodeados aca: cambiar un telefono obligaba a tocar un modulo
    # y re-releasear. Degradacion: si el archivo falta o esta roto, el reporte se
    # genera igual y el bloque del tecnico queda vacio -- nunca se rompe el entregable.
    [string] $techName  = ''
    [string] $techPhone = ''
    try {
        [string] $tecPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\tecnico.json'
        if (Test-Path -LiteralPath $tecPath -PathType Leaf) {
            $tec = Get-Content -LiteralPath $tecPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $tec) {
                if ($tec.PSObject.Properties['nombre']   -and $null -ne $tec.nombre)   { $techName  = ([string]$tec.nombre).Trim() }
                if ($tec.PSObject.Properties['telefono'] -and $null -ne $tec.telefono) { $techPhone = ([string]$tec.telefono).Trim() }
            }
        }
    } catch {
        # JSON roto o ilegible: seguir sin datos del tecnico, no abortar el reporte.
        $techName = ''; $techPhone = ''
    }

    # ─────────────────────────────────────────────────────────────────────────
    # HTML: cabecera + estilos
    # ─────────────────────────────────────────────────────────────────────────
    _CR_H '<!DOCTYPE html>'
    _CR_H '<html lang="es">'
    _CR_H '<head>'
    _CR_H '  <meta charset="utf-8">'
    _CR_H '  <meta name="viewport" content="width=device-width, initial-scale=1">'
    _CR_H ('  <title>Reporte de servicio - {0}</title>' -f (_CR_Esc $pcName))
    _CR_H '  <style>'
    _CR_H '    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }'
    _CR_H '    body {'
    _CR_H '      font-family: "Segoe UI", Calibri, Arial, sans-serif;'
    _CR_H '      font-size: 14px;'
    _CR_H '      color: #1a1a1a;'
    _CR_H '      background: #f5f5f5;'
    _CR_H '      padding: 24px;'
    _CR_H '    }'
    _CR_H '    .page {'
    _CR_H '      max-width: 800px;'
    _CR_H '      margin: 0 auto;'
    _CR_H '      background: #fff;'
    _CR_H '      padding: 32px 36px;'
    _CR_H '      border-radius: 6px;'
    _CR_H '      box-shadow: 0 1px 6px rgba(0,0,0,.12);'
    _CR_H '    }'
    _CR_H '    /* Encabezado */'
    _CR_H '    .report-header {'
    _CR_H '      display: flex;'
    _CR_H '      justify-content: space-between;'
    _CR_H '      align-items: flex-start;'
    _CR_H '      border-bottom: 2px solid #1a73e8;'
    _CR_H '      padding-bottom: 16px;'
    _CR_H '      margin-bottom: 24px;'
    _CR_H '    }'
    _CR_H '    .brand { font-size: 22px; font-weight: 700; color: #1a73e8; display: flex; align-items: center; gap: 10px; }'
    _CR_H '    .brand-logo { width: 40px; height: 40px; flex: 0 0 auto; }'
    _CR_H '    .brand small { font-size: 13px; font-weight: 400; color: #555; display: block; margin-top: 2px; }'
    _CR_H '    .meta-block { text-align: right; font-size: 12.5px; color: #555; line-height: 1.6; }'
    _CR_H '    .meta-block strong { color: #1a1a1a; }'
    _CR_H '    /* Paneles */'
    _CR_H '    .panel {'
    _CR_H '      margin-bottom: 28px;'
    _CR_H '      border: 1px solid #e0e0e0;'
    _CR_H '      border-radius: 5px;'
    _CR_H '      overflow: hidden;'
    _CR_H '    }'
    _CR_H '    .panel-title {'
    _CR_H '      background: #f0f4ff;'
    _CR_H '      padding: 10px 16px;'
    _CR_H '      font-size: 13.5px;'
    _CR_H '      font-weight: 700;'
    _CR_H '      color: #1a1a1a;'
    _CR_H '      border-bottom: 1px solid #d0d8f0;'
    _CR_H '      letter-spacing: .3px;'
    _CR_H '    }'
    _CR_H '    .panel-body { padding: 14px 16px; }'
    _CR_H '    /* Tabla de ficha del equipo */'
    _CR_H '    table.info-table {'
    _CR_H '      width: 100%;'
    _CR_H '      border-collapse: collapse;'
    _CR_H '      font-size: 13px;'
    _CR_H '    }'
    _CR_H '    table.info-table td { padding: 5px 8px; vertical-align: top; }'
    _CR_H '    table.info-table tr:nth-child(even) td { background: #f8f9ff; }'
    _CR_H '    td.lbl { color: #555; width: 38%; font-weight: 500; }'
    _CR_H '    /* Checklist */'
    _CR_H '    ul.checklist { list-style: none; padding: 0; }'
    _CR_H '    ul.checklist li { padding: 6px 0; border-bottom: 1px solid #f0f0f0; font-size: 13px; display: flex; align-items: baseline; gap: 8px; }'
    _CR_H '    ul.checklist li:last-child { border-bottom: none; }'
    _CR_H '    .check-ok   { color: #1a1a1a; }'
    _CR_H '    .check-skip { color: #aaa; }'
    _CR_H '    .mark { font-size: 16px; min-width: 18px; display: inline-block; }'
    _CR_H '    .check-ok   .mark { color: #1e8e3e; }'
    _CR_H '    .check-skip .mark { color: #ccc; }'
    _CR_H '    /* Tabla antes/despues */'
    _CR_H '    table.delta-table {'
    _CR_H '      width: 100%;'
    _CR_H '      border-collapse: collapse;'
    _CR_H '      font-size: 13px;'
    _CR_H '    }'
    _CR_H '    table.delta-table th {'
    _CR_H '      background: #f0f4ff;'
    _CR_H '      padding: 6px 10px;'
    _CR_H '      text-align: left;'
    _CR_H '      font-weight: 600;'
    _CR_H '      border-bottom: 1px solid #d0d8f0;'
    _CR_H '      color: #333;'
    _CR_H '    }'
    _CR_H '    table.delta-table td { padding: 6px 10px; vertical-align: top; border-bottom: 1px solid #f0f0f0; }'
    _CR_H '    table.delta-table tr:last-child td { border-bottom: none; }'
    _CR_H '    td.before { color: #888; }'
    _CR_H '    td.after  { color: #1e8e3e; font-weight: 600; }'
    _CR_H '    td.delta-note { color: #555; font-size: 12px; }'
    _CR_H '    /* Subtitulo de seccion dentro de panel */'
    _CR_H '    .sub-title { font-size: 12.5px; font-weight: 600; color: #444; margin: 12px 0 6px; text-transform: uppercase; letter-spacing: .4px; }'
    _CR_H '    /* Nota suave */'
    _CR_H '    .soft-note { color: #888; font-size: 12.5px; font-style: italic; padding: 6px 0; }'
    _CR_H '    /* Health badge */'
    _CR_H '    .badge {'
    _CR_H '      display: inline-block;'
    _CR_H '      padding: 2px 8px;'
    _CR_H '      border-radius: 3px;'
    _CR_H '      font-size: 11.5px;'
    _CR_H '      font-weight: 700;'
    _CR_H '      letter-spacing: .3px;'
    _CR_H '    }'
    _CR_H '    .badge-ok   { background: #e6f4ea; color: #1e8e3e; }'
    _CR_H '    .badge-warn { background: #fef7e0; color: #b06000; }'
    _CR_H '    .badge-bad  { background: #fce8e6; color: #d32f2f; }'
    _CR_H '    /* Pie */'
    _CR_H '    .report-footer {'
    _CR_H '      margin-top: 28px;'
    _CR_H '      padding-top: 14px;'
    _CR_H '      border-top: 1px solid #e0e0e0;'
    _CR_H '      font-size: 11.5px;'
    _CR_H '      color: #888;'
    _CR_H '      text-align: center;'
    _CR_H '    }'
    _CR_H '    /* Impresion */'
    _CR_H '    @media print {'
    _CR_H '      body { background: #fff; padding: 0; font-size: 12px; }'
    _CR_H '      .page { box-shadow: none; border-radius: 0; padding: 0; }'
    _CR_H '      .panel { break-inside: avoid; }'
    _CR_H '    }'
    _CR_H '  </style>'
    _CR_H '</head>'
    _CR_H '<body>'
    _CR_H '<div class="page">'

    # ── Encabezado ────────────────────────────────────────────────────────────
    _CR_H '  <div class="report-header">'
    _CR_H '    <div>'
    _CR_H '      <div class="brand"><img src="data:image/png;base64,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" class="brand-logo" alt=""><span>PCTk<small>Reporte de servicio</small></span></div>'
    _CR_H '    </div>'
    _CR_H '    <div class="meta-block">'
    _CR_H ('      <strong>{0}</strong><br>' -f (_CR_Esc $pcName))
    _CR_H ('      Fecha: {0}<br>' -f (_CR_Esc $reportDate))
    # Condicionales: sin data\tecnico.json no se imprime una etiqueta huerfana
    # ("Tecnico:" seguido de nada) en el papel que ve el cliente.
    if (-not [string]::IsNullOrWhiteSpace($techName)) {
        _CR_H ('      Tecnico: {0}<br>' -f (_CR_Esc $techName))
    }
    if (-not [string]::IsNullOrWhiteSpace($techPhone)) {
        _CR_H ('      Tel: {0}' -f (_CR_Esc $techPhone))
    }
    _CR_H '    </div>'
    _CR_H '  </div>'

    # ── Panel 1: Tu equipo ─────────────────────────────────────────────────────
    if ($null -ne $PostSnapshot) {
        _CR_H '  <div class="panel">'
        _CR_H '    <div class="panel-title">Tu equipo</div>'
        _CR_H '    <div class="panel-body">'

        # CPU
        [string] $cpuName = ''
        [object] $cpuObj = $PostSnapshot.PSObject.Properties['CPU']
        if ($null -ne $cpuObj -and $null -ne $cpuObj.Value) {
            $cpuName = [string]$cpuObj.Value.Name
            [string] $cores   = [string]$cpuObj.Value.Cores
            [string] $threads = [string]$cpuObj.Value.Threads
            if (-not [string]::IsNullOrWhiteSpace($cores) -and $cores -ne '0') {
                $cpuName = ('{0} ({1}C/{2}T)' -f $cpuName, $cores, $threads)
            }
        }

        # RAM
        [string] $ramDesc = ''
        [object] $ramTotObj = $PostSnapshot.PSObject.Properties['RamTotalGb']
        if ($null -ne $ramTotObj) {
            $ramDesc = ('{0} GB' -f [string]$ramTotObj.Value)
        }
        [object] $slotsObj = $PostSnapshot.PSObject.Properties['RamSlots']
        if ($null -ne $slotsObj -and $null -ne $slotsObj.Value) {
            [object[]] $slots = @($slotsObj.Value)
            if ($slots.Count -gt 0) {
                [string] $speed = [string]$slots[0].SpeedMhz
                [string] $ch    = if ($slots.Count -ge 2) { 'dual channel' } else { 'single channel' }
                if (-not [string]::IsNullOrWhiteSpace($speed) -and $speed -ne '0') {
                    $ramDesc = ('{0} - {1} @ {2} MHz' -f $ramDesc, $ch, $speed)
                } else {
                    $ramDesc = ('{0} - {1}' -f $ramDesc, $ch)
                }
            }
        }

        # GPU
        [object[]] $gpuList = @()
        [object] $gpuObj = $PostSnapshot.PSObject.Properties['GPU']
        if ($null -ne $gpuObj -and $null -ne $gpuObj.Value) {
            $gpuList = @($gpuObj.Value)
        }

        _CR_H '      <table class="info-table">'
        _CR_Row 'Procesador' $cpuName
        _CR_Row 'Memoria RAM' $ramDesc

        foreach ($gpu in $gpuList) {
            [string] $gName = [string]$gpu.Name
            [string] $gType = if ($null -ne $gpu.PSObject.Properties['Type']) { [string]$gpu.Type } else { '' }
            [string] $gDrv  = if ($null -ne $gpu.PSObject.Properties['DriverVersion']) { [string]$gpu.DriverVersion } else { '' }
            [string] $gDesc = $gName
            if (-not [string]::IsNullOrWhiteSpace($gDrv)) { $gDesc = ('{0}  (driver {1})' -f $gDesc, $gDrv) }
            if (-not [string]::IsNullOrWhiteSpace($gType) -and $gType -ne 'Unknown') { $gDesc = ('{0}  [{1}]' -f $gDesc, $gType) }
            _CR_Row 'Tarjeta grafica' $gDesc
        }

        _CR_H '      </table>'

        # Discos
        [object] $disksObj = $PostSnapshot.PSObject.Properties['Disks']
        if ($null -ne $disksObj -and $null -ne $disksObj.Value) {
            [object[]] $disks = @($disksObj.Value)
            if ($disks.Count -gt 0) {
                _CR_H '      <div class="sub-title">Almacenamiento</div>'
                _CR_H '      <table class="info-table">'
                foreach ($d in $disks) {
                    [string] $dName   = if ($null -ne $d.PSObject.Properties['Name'])       { [string]$d.Name }       else { 'Disco' }
                    [string] $dType   = if ($null -ne $d.PSObject.Properties['MediaType'])   { [string]$d.MediaType }  else { '' }
                    [string] $dSize   = if ($null -ne $d.PSObject.Properties['SizeGb'])      { [string]$d.SizeGb }     else { '' }
                    [string] $dHealth = if ($null -ne $d.PSObject.Properties['HealthStatus']) { [string]$d.HealthStatus } else { '' }
                    [string] $dTemp   = if ($null -ne $d.PSObject.Properties['TempC'] -and [int]$d.TempC -gt 0)  { ('{0} C' -f [string]$d.TempC)    } else { '' }
                    [string] $dWear   = if ($null -ne $d.PSObject.Properties['WearPct'] -and [int]$d.WearPct -gt 0) { ('{0}%' -f [string]$d.WearPct) } else { '' }

                    # Badge de salud
                    [string] $healthBadge = ''
                    if (-not [string]::IsNullOrWhiteSpace($dHealth)) {
                        [string] $hLow = $dHealth.ToLowerInvariant()
                        [string] $badgeCls = if ($hLow -eq 'healthy' -or $hLow -eq 'ok' -or $hLow -eq 'bueno') {
                            'badge-ok'
                        } elseif ($hLow -eq 'warning' -or $hLow -eq 'advertencia' -or $hLow -eq 'caution') {
                            'badge-warn'
                        } else {
                            'badge-bad'
                        }
                        $healthBadge = (' <span class="badge {0}">{1}</span>' -f $badgeCls, (_CR_Esc $dHealth))
                    }

                    [string] $diskLabel = $dName
                    [string] $diskDesc  = ''
                    if (-not [string]::IsNullOrWhiteSpace($dSize))   { $diskDesc += ('{0} GB' -f $dSize) }
                    if (-not [string]::IsNullOrWhiteSpace($dType))   { $diskDesc += ('  [{0}]' -f $dType) }
                    if (-not [string]::IsNullOrWhiteSpace($dTemp))   { $diskDesc += ('  temp: {0}' -f $dTemp) }
                    if (-not [string]::IsNullOrWhiteSpace($dWear))   { $diskDesc += ('  desgaste: {0}' -f $dWear) }

                    if (-not [string]::IsNullOrWhiteSpace($diskDesc) -or -not [string]::IsNullOrWhiteSpace($healthBadge)) {
                        _CR_H ('        <tr><td class="lbl">{0}</td><td>{1}{2}</td></tr>' -f (_CR_Esc $diskLabel), (_CR_Esc $diskDesc.Trim()), $healthBadge)
                    }
                }
                _CR_H '      </table>'
            }
        }

        # Bateria (solo laptops)
        [object] $batObj = $PostSnapshot.PSObject.Properties['Battery']
        if ($null -ne $batObj -and $null -ne $batObj.Value) {
            [PSCustomObject] $bat = $batObj.Value
            [string] $batCharge = if ($null -ne $bat.PSObject.Properties['ChargePercent']) { [string]$bat.ChargePercent } else { '' }
            [string] $batHealth = if ($null -ne $bat.PSObject.Properties['HealthPercent']) { [string]$bat.HealthPercent } else { '' }
            [string] $batStatus = if ($null -ne $bat.PSObject.Properties['Status'])        { [string]$bat.Status }        else { '' }
            if (-not [string]::IsNullOrWhiteSpace($batCharge) -or -not [string]::IsNullOrWhiteSpace($batHealth)) {
                _CR_H '      <div class="sub-title">Bateria</div>'
                _CR_H '      <table class="info-table">'
                # PS5.1: un `if` como ARGUMENTO de comando (_CR_Row '...' (if ...)) se
                # parsea como el cmdlet 'if' y crashea el reporte en laptops. La forma
                # de ASIGNACION ($x = if ...) si es valida -> temp vars. (Bug campo 2026-06-18.)
                [string] $batChargeTd = if (-not [string]::IsNullOrWhiteSpace($batCharge)) { ('{0}%' -f $batCharge) } else { '' }
                [string] $batHealthTd = if (-not [string]::IsNullOrWhiteSpace($batHealth)) { ('{0}%' -f $batHealth) } else { '' }
                _CR_Row 'Carga actual' $batChargeTd
                _CR_Row 'Salud'        $batHealthTd
                _CR_Row 'Estado'        $batStatus
                _CR_H '      </table>'
            }
        }

        # ── Temperatura (2026-07-25) ──────────────────────────────────────────
        # El snapshot YA capturaba CpuTempC y ThermalZones y el reporte nunca los
        # miraba. La termica es el diagnostico que mas veces aparece en campo (caso
        # Ignacio: CPU tocando TjMax, medido a mano con HWiNFO). Si el equipo no
        # reporta sensores (comun en desktops y en VM), la seccion no se dibuja.
        [string] $cpuTempStr = ''
        [object] $tempObj = $PostSnapshot.PSObject.Properties['CpuTempC']
        if ($null -ne $tempObj -and $null -ne $tempObj.Value) {
            [double] $tC = 0
            if ([double]::TryParse([string]$tempObj.Value, [ref] $tC) -and $tC -gt 0) {
                $cpuTempStr = '{0} C' -f [math]::Round($tC, 1)
                if ($tC -ge 90) {
                    $cpuTempStr += ' — alta: conviene limpieza y cambio de pasta termica'
                } elseif ($tC -ge 80) {
                    $cpuTempStr += ' — elevada'
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($cpuTempStr)) {
            _CR_H '      <div class="sub-title">Temperatura</div>'
            _CR_H '      <table class="info-table">'
            _CR_Row 'CPU en reposo' $cpuTempStr
            _CR_H '      </table>'
        }

        # ── Plan de energia (2026-07-25) ──────────────────────────────────────
        # PowerPlan tambien se capturaba y se ignoraba. Un equipo en "Economizador"
        # explica media consulta de lentitud sin tocar una sola linea de registro.
        [string] $planStr = ''
        [object] $ppObj = $PostSnapshot.PSObject.Properties['PowerPlan']
        if ($null -ne $ppObj -and $null -ne $ppObj.Value) {
            [object] $pp = $ppObj.Value
            if ($null -ne $pp.PSObject.Properties['ActiveName'] -and
                -not [string]::IsNullOrWhiteSpace([string]$pp.ActiveName)) {
                $planStr = [string] $pp.ActiveName
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($planStr)) {
            _CR_H '      <div class="sub-title">Energia</div>'
            _CR_H '      <table class="info-table">'
            _CR_Row 'Plan activo' $planStr
            _CR_H '      </table>'
        }

        _CR_H '    </div>'
        _CR_H '  </div>'
    } else {
        _CR_H '  <div class="panel">'
        _CR_H '    <div class="panel-title">Tu equipo</div>'
        _CR_H '    <div class="panel-body">'
        _CR_H '      <p class="soft-note">Informacion del equipo no disponible en este reporte.</p>'
        _CR_H '    </div>'
        _CR_H '  </div>'
    }

    # ── Panel 2: Que hicimos ───────────────────────────────────────────────────
    # Solo se muestra si Result tiene datos del run
    [bool] $hasRunData = $null -ne $Result
    if ($hasRunData) {
        _CR_H '  <div class="panel">'
        _CR_H '    <div class="panel-title">Que hicimos</div>'
        _CR_H '    <div class="panel-body">'
        _CR_H '      <ul class="checklist">'

        # Punto de restauracion
        [bool] $rpDone = $false
        [object] $rpObj = $Result.PSObject.Properties['RestorePoint']
        if ($null -ne $rpObj -and $null -ne $rpObj.Value) {
            $rpDone = [bool]$rpObj.Value.Done
        }
        _CR_CheckItem 'Punto de restauracion del sistema creado' $rpDone

        # Servicios innecesarios
        [string] $debloatText = 'Servicios innecesarios desactivados'
        [bool]   $debloatDone = $false
        [object] $dbObj = $Result.PSObject.Properties['Debloat']
        if ($null -ne $dbObj -and $null -ne $dbObj.Value) {
            [object] $disabledProp = $dbObj.Value.PSObject.Properties['Disabled']
            [object] $totalProp    = $dbObj.Value.PSObject.Properties['TotalTargeted']
            if ($null -ne $disabledProp -and [int]$disabledProp.Value -gt 0) {
                $debloatDone = $true
                $debloatText = ('Servicios innecesarios desactivados ({0} de {1})' -f [string]$disabledProp.Value, [string]$totalProp.Value)
            } elseif ($null -ne $disabledProp) {
                $debloatDone = $false
                $debloatText = 'Servicios innecesarios: ninguno requirio cambio'
            }
        }
        _CR_CheckItem $debloatText $debloatDone

        # Limpieza de temporales
        [string] $cleanText = 'Limpieza de archivos temporales'
        [bool]   $cleanDone = $false
        [object] $clObj = $Result.PSObject.Properties['Cleanup']
        if ($null -ne $clObj -and $null -ne $clObj.Value) {
            [object] $gbProp = $clObj.Value.PSObject.Properties['FreedGB']
            if ($null -ne $gbProp) {
                [double] $gbVal = [double]$gbProp.Value
                $cleanDone = $gbVal -gt 0
                if ($cleanDone) {
                    $cleanText = ('Limpieza de archivos temporales ({0:F1} GB liberados)' -f $gbVal)
                }
            }
        }
        _CR_CheckItem $cleanText $cleanDone

        # Privacidad
        [string] $privText = 'Ajustes de privacidad (se desactivo el envio de datos de uso y publicidad)'
        [bool]   $privDone = $false
        [object] $privObj = $Result.PSObject.Properties['Privacy']
        if ($null -ne $privObj -and $null -ne $privObj.Value) {
            [object] $privSucc = $privObj.Value.PSObject.Properties['Success']
            if ($null -ne $privSucc) { $privDone = [bool]$privSucc.Value }
        }
        _CR_CheckItem $privText $privDone

        # Rendimiento
        [string] $perfText = 'Optimizacion de rendimiento aplicada'
        [bool]   $perfDone = $false
        [object] $perfObj = $Result.PSObject.Properties['Performance']
        if ($null -ne $perfObj -and $null -ne $perfObj.Value) {
            $perfDone = $true
        }
        _CR_CheckItem $perfText $perfDone

        # Programas de inicio (solo informativo en auto; removidos solo si delta > 0)
        [object] $stObj = $Result.PSObject.Properties['Startup']
        if ($null -ne $stObj -and $null -ne $stObj.Value) {
            [object] $cntProp = $stObj.Value.PSObject.Properties['Count']
            if ($null -ne $cntProp -and [int]$cntProp.Value -ge 0) {
                [string] $startText = ('Programas de inicio detectados: {0}' -f [string]$cntProp.Value)
                _CR_CheckItem $startText $true
            }
        }
        # Si Compare tiene StartupDelta > 0, mostrar cuantos se removieron
        if ($null -ne $Compare) {
            [object] $sdObj = $Compare.PSObject.Properties['StartupDelta']
            if ($null -ne $sdObj -and [int]$sdObj.Value -gt 0) {
                _CR_CheckItem ('Programas de inicio removidos: {0}' -f [string]$sdObj.Value) $true
            }
        }

        _CR_H '      </ul>'
        _CR_H '    </div>'
        _CR_H '  </div>'
    }

    # ── Panel 3: Antes y despues ──────────────────────────────────────────────
    if ($null -ne $Compare) {
        _CR_H '  <div class="panel">'
        _CR_H '    <div class="panel-title">Antes y despues</div>'
        _CR_H '    <div class="panel-body">'
        _CR_H '      <table class="delta-table">'
        _CR_H '        <thead>'
        _CR_H '          <tr><th>Que mejoro</th><th>Antes</th><th>Ahora</th><th>Detalle</th></tr>'
        _CR_H '        </thead>'
        _CR_H '        <tbody>'

        # Espacio liberado por volumen
        [object] $volDiffObj = $Compare.PSObject.Properties['VolumeDiff']
        if ($null -ne $volDiffObj -and $null -ne $volDiffObj.Value) {
            [object[]] $vols = @($volDiffObj.Value)
            foreach ($v in $vols) {
                [string] $letter = if ($null -ne $v.PSObject.Properties['Letter']) { [string]$v.Letter } else { '?' }
                [object] $freedProp = $v.PSObject.Properties['SpaceFreedGb']
                if ($null -ne $freedProp -and [double]$freedProp.Value -gt 0.05) {
                    [string] $preFree  = if ($null -ne $v.PSObject.Properties['PreFreeGb'])  { ('{0:F1} GB libres' -f [double]$v.PreFreeGb) }  else { '-' }
                    [string] $postFree = if ($null -ne $v.PSObject.Properties['PostFreeGb']) { ('{0:F1} GB libres' -f [double]$v.PostFreeGb) } else { '-' }
                    [string] $freed    = ('+{0:F1} GB' -f [double]$freedProp.Value)
                    _CR_DeltaRow ('Espacio libre disco {0}:' -f $letter) $preFree $postFree $freed
                }
            }
        }

        # Servicios en ejecucion
        [object] $preRunObj  = $Compare.PSObject.Properties['PreRunningCount']
        [object] $postRunObj = $Compare.PSObject.Properties['PostRunningCount']
        if ($null -ne $preRunObj -and $null -ne $postRunObj) {
            [int] $preRun  = [int]$preRunObj.Value
            [int] $postRun = [int]$postRunObj.Value
            if ($preRun -gt 0 -or $postRun -gt 0) {
                [string] $deltaNote = if ($preRun -gt $postRun) { ('-{0} servicios activos' -f ($preRun - $postRun)) } else { '' }
                _CR_DeltaRow 'Servicios en ejecucion' ('{0} servicios' -f $preRun) ('{0} servicios' -f $postRun) $deltaNote
            }
        }

        # Conflicto de antivirus resuelto
        [object] $avObj = $Compare.PSObject.Properties['AvFixed']
        if ($null -ne $avObj -and [bool]$avObj.Value) {
            _CR_DeltaRow 'Conflicto de antivirus' 'Problema detectado' 'Resuelto' 'Se elimino conflicto entre 2 antivirus activos'
        }

        # Reinicio
        [object] $rebootObj = $Compare.PSObject.Properties['Rebooted']
        if ($null -ne $rebootObj) {
            [bool] $rebooted = [bool]$rebootObj.Value
            [string] $rebootBefore = if ($rebooted) { 'Sin reiniciar' } else { 'En ejecucion' }
            [string] $rebootAfter  = if ($rebooted) { 'Reiniciado correctamente' } else { 'Pendiente de reinicio' }
            _CR_DeltaRow 'Estado del sistema' $rebootBefore $rebootAfter ''
        }

        _CR_H '        </tbody>'
        _CR_H '      </table>'
        _CR_H '    </div>'
        _CR_H '  </div>'
    } else {
        _CR_H '  <div class="panel">'
        _CR_H '    <div class="panel-title">Antes y despues</div>'
        _CR_H '    <div class="panel-body">'
        _CR_H '      <p class="soft-note">Comparacion PRE/POST no disponible para este servicio.</p>'
        _CR_H '    </div>'
        _CR_H '  </div>'
    }

    # ── Pie ───────────────────────────────────────────────────────────────────
    _CR_H '  <div class="report-footer">'
    [string] $pieTec = if (-not [string]::IsNullOrWhiteSpace($techName)) {
        ' &bull; Tecnico: ' + (_CR_Esc $techName)
    } else { '' }
    _CR_H ('    PCTk &bull; Reporte generado el {0}{1}' -f (_CR_Esc $reportDate), $pieTec)
    _CR_H '  </div>'

    _CR_H '</div>'
    _CR_H '</body>'
    _CR_H '</html>'

    # ── Escribir archivo ──────────────────────────────────────────────────────
    # UTF-8 con BOM para compatibilidad con caracteres acentuados
    [string] $content = $script:_crBuf -join "`r`n"
    [System.IO.File]::WriteAllText($OutputPath, $content, [System.Text.UTF8Encoding]::new($true))

    # Limpiar buffer
    $script:_crBuf = $null

    if ($OpenAfter) {
        try { Start-Process $OutputPath } catch { }
    }

    return [PSCustomObject]@{
        Success  = $true
        FilePath = $OutputPath
    }
}
