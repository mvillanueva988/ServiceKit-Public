Set-StrictMode -Version Latest

# ─── Confirm-Action (preview + S/n prompt centralizado) ──────────────────────
function Confirm-Action {
    <#
    .SYNOPSIS
        Imprime un preview de lo que la accion va a hacer y pide confirmacion.
        Retorna $true si el operador confirma, $false si cancela.

        Default es 'S' — Enter sin escribir nada = confirmar. Para no-default
        pasar -DefaultYes:$false. El prompt usa [S/n] o [s/N] segun.

    .EXAMPLE
        if (-not (Confirm-Action -Title 'Aplicar perfil Balanced?' -Lines @(
            'Visuales: 9 toggles',
            'PowerPlan: Balanced (previo: Ultimate Performance)',
            'Tweaks: hibernacion off, SvcHost, shutdown timeout, Game DVR off'
        ))) { return }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter()] [string[]] $Lines = @(),
        [Parameter()] [bool] $DefaultYes = $true
    )

    Write-Host ''
    Write-PctkWork ('  {0}' -f $Title)
    foreach ($l in $Lines) {
        Write-PctkHint ('    - {0}' -f $l)
    }
    [string] $defaultLabel = if ($DefaultYes) { '[S/n]' } else { '[s/N]' }
    [string] $ans = (Read-Host ('  Confirmar? ' + $defaultLabel)).Trim().ToUpperInvariant()

    if ($DefaultYes) {
        return ([string]::IsNullOrEmpty($ans) -or $ans -eq 'S' -or $ans -eq 'SI' -or $ans -eq 'Y' -or $ans -eq 'YES')
    } else {
        return ($ans -eq 'S' -or $ans -eq 'SI' -or $ans -eq 'Y' -or $ans -eq 'YES')
    }
}

# ─── Write-ActionAudit (helper centralizado) ──────────────────────────────────
function Write-ActionAudit {
    <#
    .SYNOPSIS
        Wrapper sobre Write-ToolkitAuditLog para handlers del Router.
        Marca cada accion del menu en output/audit/<date>.jsonl. Defensivo:
        si ToolkitSupport no esta dot-sourced (caso edge), no rompe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter()]          [string] $Status = 'Started',
        [Parameter()]          [string] $Summary = '',
        [Parameter()]          [object] $Details = $null
    )

    if (Get-Command -Name 'Write-ToolkitAuditLog' -CommandType Function -ErrorAction SilentlyContinue) {
        Write-ToolkitAuditLog -Action $Action -Status $Status -Summary $Summary -Details $Details
    }
}

# ─── Show-MachineBanner ───────────────────────────────────────────────────────
function Show-MachineBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    $osInfo  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    [string] $osName = if ($MachineProfile.IsWin11) { 'Win11' } else { 'Windows' }
    if ($MachineProfile.IsHome) { $osName = "$osName Home" }

    [string] $build = if ($MachineProfile.Build -gt 0) { [string] $MachineProfile.Build } else { 'N/A' }
    [string] $arch  = if ($osInfo -and $osInfo.OSArchitecture) { [string] $osInfo.OSArchitecture } else { 'x64' }

    [string] $cpuName    = if ($cpuInfo -and $cpuInfo.Name) { ([string]$cpuInfo.Name).Trim() } else { 'CPU no detectada' }
    [string] $cpuCores   = if ($cpuInfo -and $cpuInfo.NumberOfCores) { [string]$cpuInfo.NumberOfCores } else { '?' }
    [string] $cpuThreads = if ($cpuInfo -and $cpuInfo.NumberOfLogicalProcessors) { [string]$cpuInfo.NumberOfLogicalProcessors } else { '?' }

    [double] $ramTotalGb = [math]::Round(([double]$MachineProfile.RamMB / 1024), 2)
    [string] $ramTotalLabel = if ($MachineProfile.RamMB -gt 0) { ('{0:N2} GB total' -f $ramTotalGb) } else { 'N/A total' }

    [string] $ramFreeLabel = 'N/A disponible'
    if ($osInfo -and $osInfo.FreePhysicalMemory) {
        [double] $freeGb = [math]::Round((([double]$osInfo.FreePhysicalMemory * 1KB) / 1GB), 2)
        $ramFreeLabel = ('{0:N2} GB disponible' -f $freeGb)
    }

    [string[]] $gpuNames = @()
    if ($MachineProfile.PSObject.Properties['GpuNames']) {
        $gpuNames = @($MachineProfile.GpuNames)
    }
    [string] $gpuLabel = if ($gpuNames.Count -gt 0) { $gpuNames -join ' | ' } else { 'GPU no detectada' }
    if ($MachineProfile.HasIGpuOnly) {
        $gpuLabel = "$gpuLabel  [iGPU only]"
    }
    elseif ($MachineProfile.HasDGpu) {
        [string] $vramTag = ''
        if ($MachineProfile.PSObject.Properties['DGpuVramMb'] -and $MachineProfile.DGpuVramMb -gt 0) {
            $vramTag = (' {0} GB VRAM' -f [math]::Round($MachineProfile.DGpuVramMb / 1024, 1))
        }
        $gpuLabel = "$gpuLabel  [dGPU$vramTag]"
    }

    [string] $manufacturer = if ([string]::IsNullOrWhiteSpace([string]$MachineProfile.Manufacturer)) { 'Unknown' } else { [string]$MachineProfile.Manufacturer }
    [string] $oemSuffix = '  [sin catalogo OEM]'
    if ($MachineProfile.PSObject.Properties['OemCatalogPath'] -and -not [string]::IsNullOrWhiteSpace([string]$MachineProfile.OemCatalogPath)) {
        if (Test-Path -Path ([string]$MachineProfile.OemCatalogPath) -PathType Leaf) {
            $oemSuffix = '  [catalogo OEM disponible]'
        }
    }

    [string] $tierLabel = if ($MachineProfile.PSObject.Properties['Tier']) { [string]$MachineProfile.Tier } else { 'N/A' }
    [string] $cpuClass  = if ($MachineProfile.PSObject.Properties['CpuClass']) { [string]$MachineProfile.CpuClass } else { 'Unknown' }

    # Render via tema PCTk (banner block + caja doble). Si VT off -> estilo clasico.
    [object[]] $rows = @()
    $rows += [PSCustomObject]@{ Label = 'OS';  Value = ('{0} Build {1} {2}' -f $osName, $build, $arch) }
    $rows += [PSCustomObject]@{ Label = 'CPU'; Value = ('{0}  {1} nucleos / {2} hilos  [{3}]' -f $cpuName, $cpuCores, $cpuThreads, $cpuClass) }
    $rows += [PSCustomObject]@{ Label = 'RAM'; Value = ('{0}  |  {1}' -f $ramTotalLabel, $ramFreeLabel) }
    $rows += [PSCustomObject]@{ Label = 'GPU'; Value = [string]$gpuLabel }
    $rows += [PSCustomObject]@{ Label = 'OEM'; Value = ('{0}{1}' -f $manufacturer, $oemSuffix) }

    [string] $vmLine = ''
    if ($MachineProfile.PSObject.Properties['IsVirtualMachine'] -and [bool]$MachineProfile.IsVirtualMachine) {
        [string] $vmVendorLabel = if ($MachineProfile.PSObject.Properties['VmVendor'] -and -not [string]::IsNullOrWhiteSpace([string]$MachineProfile.VmVendor)) {
            [string]$MachineProfile.VmVendor
        } else { 'VM' }
        $vmLine = ('{0}  [modo VM - SMART/PnP/ACPI omitidos]' -f $vmVendorLabel)
    }

    Write-PctkMachineBanner -Rows $rows -Tier $tierLabel -VmLine $vmLine
}

# ─── Show-MainMenu ────────────────────────────────────────────────────────────
function Show-MainMenu {
    <#
    .SYNOPSIS
        Loop principal del menu. Layout Opcion A (decidido en plan-v2.md sec 11):
        cuatro secciones — PERFILES, DIAGNOSTICO, ACCIONES MANUALES, HERRAMIENTAS.
        Las 15 acciones individuales viejas viven detras de [A] (submenu).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    [object[]] $rows = Get-MainMenuRows
    # NO usar el closure dinamico (GetNewClosure): ata el scriptblock a un modulo que SOLO ve
    # funciones globales. Con '& main.ps1' (vs powershell -File) las funciones de
    # main.ps1 quedan en un script-scope hijo, no global -> el closure no resuelve
    # Show-MachineBanner (CommandNotFound). Scriptblock plano + $script:var: el lookup
    # dinamico camina la pila y encuentra la funcion; la var resuelve por script-scope.
    $script:PctkBannerProfile = $MachineProfile
    [scriptblock] $renderHeader = { Clear-Host; Show-MachineBanner -MachineProfile $script:PctkBannerProfile }

    do {
        [string] $choice = Read-PctkMenuChoice -Rows $rows -RenderHeader $renderHeader

        # Enter vacio = re-mostrar el menu
        if ([string]::IsNullOrEmpty($choice)) { continue }

        if ($choice -eq 'X') {
            Invoke-MainMenuDispatch -Choice $choice -MachineProfile $MachineProfile
            return 'X'
        }

        if ($choice -eq 'U') {
            [bool] $ok = Invoke-UninstallToolkit
            if ($ok) { return 'U' }
            Write-Host ''
            Read-Host '  [Enter] para continuar' | Out-Null
            continue
        }

        Invoke-MainMenuDispatch -Choice $choice -MachineProfile $MachineProfile
        Write-Host ''
        Read-Host '  [Enter] para continuar' | Out-Null
    }
    while ($true)
}

# ─── Invoke-MainMenuDispatch ──────────────────────────────────────────────────
function Invoke-MainMenuDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Choice,

        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    [string] $up = $Choice.ToUpperInvariant()

    switch ($up) {
        '1' {
            Invoke-ApplyAutoProfile -MachineProfile $MachineProfile
            return
        }
        '2' {
            Invoke-NamedProfileMenu -MachineProfile $MachineProfile
            return
        }
        '3' { Invoke-DiagnosticSnapshot -Phase Pre  -MachineProfile $MachineProfile; return }
        '4' { Invoke-DiagnosticSnapshot -Phase Post -MachineProfile $MachineProfile; return }
        '5' { Invoke-DiagnosticCompare  -MachineProfile $MachineProfile; return }
        '6' { Invoke-DiagnosticBsod     -MachineProfile $MachineProfile; return }
        '7' { Invoke-DiagnosticDiskHealth -MachineProfile $MachineProfile; return }
        'R' { Invoke-ResearchPrompt -MachineProfile $MachineProfile; return }
        'A' {
            Show-IndividualActionsSubmenu -MachineProfile $MachineProfile
            return
        }
        'L' { Invoke-ExportClientLogs; return }
        'T' { Show-ToolsMenu -MachineProfile $MachineProfile; return }
        'U' {
            $null = Invoke-UninstallToolkit
            return
        }
        'X' {
            Write-Host '  Saliendo de PCTk v2...' -ForegroundColor Cyan
            return
        }
        default {
            Write-Host '  Opcion invalida.' -ForegroundColor Red
            return
        }
    }
}

# ─── Diagnostic actions del menu principal ────────────────────────────────────

function Invoke-DiagnosticSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Pre', 'Post')] [string] $Phase,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )
    $null = $MachineProfile
    [string] $action = "Snapshot.$Phase"
    Write-ActionAudit -Action $action -Status 'Started'
    Write-Host ('  Capturando snapshot {0}-service...' -f $Phase) -ForegroundColor Cyan
    $job = Start-TelemetryJob -Phase $Phase
    $results = Invoke-JobWithProgress -Jobs @($job) -Activity ('Snapshot {0}' -f $Phase) -TimeoutSeconds 120
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        $r = $results[0]
        Write-Host ('  [OK] Snapshot guardado: {0}' -f $r.FileName) -ForegroundColor Green
        Write-Host ('       {0}' -f $r.FilePath) -ForegroundColor DarkGray
        Write-ActionAudit -Action $action -Status 'Success' -Summary $r.FileName -Details $r
    } else {
        Write-Host '  [!] No se obtuvo resultado del snapshot.' -ForegroundColor Yellow
        Write-ActionAudit -Action $action -Status 'Failed' -Summary 'No result'
    }
}

function Invoke-DiagnosticCompare {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Started'
    try {
        $diff = Compare-Snapshot
        Show-SnapshotComparison -Diff $diff
        Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Success' -Summary ('Score {0}/{1}' -f $diff.Score, $diff.ScoreMax) -Details $diff
    }
    catch {
        Write-Host ('  [!] {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Failed' -Summary $_.Exception.Message
    }
}

function Invoke-DiagnosticBsod {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Started'
    Write-Host '  Analizando Event Log (ultimos 90 dias)...' -ForegroundColor Cyan
    $job = Start-BsodHistoryJob -Days 90
    $results = Invoke-JobWithProgress -Jobs @($job) -Activity 'Historial BSOD' -TimeoutSeconds 120
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        Show-BsodHistory -Data $results[0]
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Success' -Summary ('{0} eventos en {1} dias' -f $results[0].TotalCrashes, $results[0].DaysScanned)
    } else {
        Write-Host '  [!] No se pudo leer el Event Log.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Failed' -Summary 'No result'
    }
}

function Invoke-DiagnosticDiskHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Started'
    Write-Host '  Leyendo salud de discos (SMART / wear)...' -ForegroundColor Cyan
    try {
        $data = Get-DiskHealth
        Show-DiskHealth -Data $data
        Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Success' -Summary ('{0} discos, {1} alertas' -f @($data.Disks).Count, $data.AlertCount) -Details $data
    }
    catch {
        Write-Host ('  [!] {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Failed' -Summary $_.Exception.Message
    }
}

# ─── Research prompt handler ──────────────────────────────────────────────────

function Invoke-ResearchPrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)

    Write-Host '  PLANTILLAS DE PROMPT' -ForegroundColor DarkCyan
    [object[]] $templates = @(Get-ResearchPromptTemplates)
    for ([int] $i = 0; $i -lt $templates.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $templates[$i].Label)
        Write-Host ('      {0}' -f $templates[$i].Description) -ForegroundColor DarkGray
    }
    Write-Host ''
    [string] $choice = (Read-Host '  Numero de plantilla (Enter para cancelar)').Trim()
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    [int] $idx = -1
    if (-not [int]::TryParse($choice, [ref] $idx) -or $idx -lt 1 -or $idx -gt $templates.Count) {
        Write-Host '  Opcion invalida.' -ForegroundColor Red
        return
    }
    [string] $tplKey = $templates[$idx - 1].Key

    [string] $useCase = (Read-Host '  Use-case del cliente (opcional, Enter para skip)').Trim()
    [bool] $includeId = $false
    if ($MachineProfile.PSObject.Properties['IsHome'] -and -not [bool] $MachineProfile.IsHome) {
        Write-Host '  Privacy: identificadores se scrubean por default (OS no-Home).' -ForegroundColor DarkGray
        [string] $ans = (Read-Host '  Incluir identificadores reales? [s/N]').Trim().ToUpperInvariant()
        $includeId = ($ans -eq 'S')
    }

    Write-ActionAudit -Action 'Research.Prompt' -Status 'Started' -Summary $tplKey

    [hashtable] $params = @{
        Template       = $tplKey
        MachineProfile = $MachineProfile
    }
    if (-not [string]::IsNullOrWhiteSpace($useCase)) { $params['UseCase'] = $useCase }
    if ($includeId) { $params['IncludeIdentifiers'] = $true }

    Write-Host '  Generando snapshot + prompt (puede tardar ~30s)...' -ForegroundColor Cyan
    $r = New-ResearchPrompt @params

    if ($null -eq $r -or -not $r.Success) {
        Write-Host '  [!] No se pudo generar el prompt.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Research.Prompt' -Status 'Failed'
        return
    }

    Write-Host ('  [OK] Prompt generado: {0}' -f $r.FileName) -ForegroundColor Green
    Write-Host ('       {0}' -f $r.FilePath) -ForegroundColor DarkGray
    if ($r.ClipboardSet) {
        Write-Host '  [OK] Copiado al clipboard. Pegalo en Claude/ChatGPT/Perplexity con web search habilitado.' -ForegroundColor Green
    } else {
        Write-Host '  [!] No se pudo copiar al clipboard. Abri el archivo manualmente.' -ForegroundColor Yellow
    }
    if ($r.Scrubbed) {
        Write-Host '  [i] ComputerName/dominio scrubeados. Pasar -IncludeIdentifiers para incluirlos.' -ForegroundColor DarkGray
    }
    Write-ActionAudit -Action 'Research.Prompt' -Status 'Success' -Summary ('{0} ({1} bytes)' -f $tplKey, $r.FileSize) -Details $r
}

# ─── Helper: estado de instalacion liviano (D-TS1) ────────────────────────────
# Devuelve $true si la herramienta parece instalada en $BinDir, SIN descargar.
# Para tools tipo zip usa extractDir; para el resto usa filename.
function Get-ToolStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Tool,
        [Parameter(Mandatory)] [string]         $BinDir
    )
    $prop = $Tool.PSObject.Properties['extractDir']
    if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
        return [bool] (Test-Path (Join-Path $BinDir $prop.Value) -PathType Container)
    }
    return [bool] (Test-Path (Join-Path $BinDir $Tool.filename) -PathType Leaf)
}

# ─── Tools menu (selector interactivo D-TS1) ──────────────────────────────────
function Invoke-ToolsMenuInteractive {
    <#
    .SYNOPSIS
        Modo interactivo del menu de herramientas: multi-seleccion con flechas +
        Espacio (marca varias) + Enter (baja las marcadas). Mantiene F (toggle
        -Force), O (abrir carpeta), T (marca todas), B/Esc (volver). Reusa
        Read-PctkMultiChoice. El estado OK/falta se recalcula cada vuelta.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Tools,
        [Parameter(Mandatory)] [string]   $BinDir,
        [Parameter(Mandatory)] [string]   $Bootstrap
    )

    [bool[]] $checked = [bool[]]::new($Tools.Count)
    [bool]   $force   = $false
    [int]    $hi      = 0

    while ($true) {
        [object[]] $items = @()
        for ([int] $i = 0; $i -lt $Tools.Count; $i++) {
            $t   = $Tools[$i]
            $ok  = Get-ToolStatus -Tool $t -BinDir $BinDir
            [string] $lbl = ('[{0,2}] {1,-26} [{2,-12}] {3}' -f ($i + 1), $t.name, $t.category, $(if ($ok) { 'OK' } else { 'falta' }))
            $items += [PSCustomObject]@{ Label = $lbl; Color = $(if ($ok) { 'Green' } else { 'DarkYellow' }) }
        }
        [string] $legend = ('  Espacio/Num:marca  Enter:baja  ->:abre  [F]orce:{0}  [O]carpeta  [T]odas  [B]volver' -f $(if ($force) { 'ON' } else { 'off' }))
        [scriptblock] $rh = {
            Clear-Host
            Write-PctkActionTitle 'HERRAMIENTAS EXTERNAS'
        }

        $res = Read-PctkMultiChoice -Items $items -RenderHeader $rh -Checked $checked -InitialHighlight $hi -LegendLine $legend -ActionKeys @('F', 'O', 'T')
        $checked = $res.Checked
        $hi      = [int] $res.HiIdx

        switch ($res.Action) {
            'cancel'   { return }
            'fallback' { return }
            'F' { $force = -not $force; continue }
            'O' {
                if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
                Start-Process explorer.exe $BinDir
                continue
            }
            'open' {
                # flecha derecha: abrir la tool resaltada SI esta descargada; si no, nada.
                [int] $oi = [int] $res.HiIdx
                if ($oi -ge 0 -and $oi -lt $Tools.Count) {
                    $ot = $Tools[$oi]
                    if (Get-ToolStatus -Tool $ot -BinDir $BinDir) {
                        [string] $exeRel = if ($ot.PSObject.Properties['launchExe'] -and -not [string]::IsNullOrWhiteSpace([string]$ot.launchExe)) { [string]$ot.launchExe }
                                           elseif ($ot.PSObject.Properties['filename']) { [string]$ot.filename }
                                           else { '' }
                        if ($exeRel -ne '') {
                            [string] $exePath = Join-Path $BinDir $exeRel
                            if (Test-Path -LiteralPath $exePath -PathType Leaf) {
                                [string] $ext     = ([System.IO.Path]::GetExtension($exePath)).ToLowerInvariant()
                                [string] $workDir = Split-Path -Parent $exePath
                                try {
                                    if ($ext -eq '.ps1') {
                                        # un .ps1 se EJECUTA con powershell (Start-Process directo lo abriria en el editor)
                                        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exePath) -WorkingDirectory $workDir
                                    } else {
                                        Start-Process -FilePath $exePath -WorkingDirectory $workDir
                                    }
                                } catch {}
                            }
                        }
                    }
                }
                continue
            }
            'T' {
                for ([int] $i = 0; $i -lt $checked.Count; $i++) { $checked[$i] = $true }
                continue
            }
            'submit' {
                [System.Collections.Generic.List[int]] $sel = [System.Collections.Generic.List[int]]::new()
                for ([int] $i = 0; $i -lt $checked.Count; $i++) { if ($checked[$i]) { $sel.Add($i) } }
                if ($sel.Count -eq 0) { continue }
                if (-not (Test-Path $Bootstrap)) {
                    Write-PctkErr ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $Bootstrap)
                    Read-Host '  [Enter] para continuar' | Out-Null
                    continue
                }
                Clear-Host
                foreach ($idx in $sel) {
                    $t = $Tools[$idx]
                    Write-PctkWork ('  Procesando: {0}...' -f $t.name)
                    if ($force) { & $Bootstrap -ToolName $t.name -Force }
                    else        { & $Bootstrap -ToolName $t.name }
                }
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
                $checked = [bool[]]::new($Tools.Count)
                continue
            }
        }
    }
}

function Show-ToolsMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    [string] $toolkitRoot  = Split-Path -Parent $PSScriptRoot
    [string] $binDir       = Join-Path $toolkitRoot 'tools\bin'
    [string] $bootstrap    = Join-Path $toolkitRoot 'Bootstrap-Tools.ps1'
    [string] $manifestPath = Join-Path $toolkitRoot 'tools\manifest.json'
    [bool]   $forceToggle  = $false

    if (-not (Test-Path $manifestPath)) {
        Write-Host ('  [!] tools\manifest.json no encontrado en {0}' -f $manifestPath) -ForegroundColor Red
        return
    }

    $manifest = $null
    try   { $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json }
    catch { Write-Host ('  [!] Error leyendo manifest.json: {0}' -f $_.Exception.Message) -ForegroundColor Red; return }

    [object[]] $tools = @($manifest.tools)
    if ($tools.Count -eq 0) {
        Write-Host '  [!] manifest.json no contiene herramientas.' -ForegroundColor Yellow
        return
    }

    # Consola interactiva -> multi-seleccion con flechas. Si no (headless/smoke/
    # redirigido) -> cae al loop tipeado original de abajo (cero regresion).
    if (Test-PctkInteractiveConsole) {
        Invoke-ToolsMenuInteractive -Tools $tools -BinDir $binDir -Bootstrap $bootstrap
        return
    }

    do {
        Write-Host ''
        Write-Host '  HERRAMIENTAS EXTERNAS' -ForegroundColor DarkCyan
        Write-Host '  ====================='
        Write-Host ''

        for ([int] $i = 0; $i -lt $tools.Count; $i++) {
            $t     = $tools[$i]
            $ok    = Get-ToolStatus -Tool $t -BinDir $binDir
            $label = if ($ok) { 'OK   ' } else { 'falta' }
            $clr   = if ($ok) { 'Green' } else { 'DarkYellow' }
            Write-Host ('  [{0,2}]  {1,-26}  [{2,-12}]  {3}' -f ($i + 1), $t.name, $t.category, $label) -ForegroundColor $clr
        }

        Write-Host ''
        [string] $fLabel = if ($forceToggle) { 'ON ' } else { 'off' }
        Write-Host ('  [T] Todas  [F] -Force: {0}  [O] Abrir carpeta  [B] Volver' -f $fLabel)
        Write-Host ('  Binarios: {0}' -f $binDir) -ForegroundColor DarkGray
        Write-Host ''
        [string] $raw = (Read-Host '  Seleccion (numero/s, T/F/O/B)').Trim()

        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        [string] $up = $raw.ToUpperInvariant()

        if ($up -eq 'B') { return }

        if ($up -eq 'F') {
            $forceToggle = -not $forceToggle
            Write-Host ('  -Force: {0}' -f $(if ($forceToggle) { 'ON' } else { 'off' })) -ForegroundColor Cyan
            continue
        }

        if ($up -eq 'O') {
            if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
            Start-Process explorer.exe $binDir
            continue
        }

        if ($up -eq 'T') {
            if (-not (Test-Path $bootstrap)) {
                Write-Host ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $bootstrap) -ForegroundColor Red
            } elseif ($forceToggle) {
                & $bootstrap -Force
            } else {
                & $bootstrap
            }
            continue
        }

        # Parsear numero/s: "1,3,5" o "1 3 5" o mezcla
        [string[]] $tokens = $raw -split '[,\s]+' | Where-Object { $_ -ne '' }
        [System.Collections.Generic.List[int]] $sel = [System.Collections.Generic.List[int]]::new()
        [bool] $valid = $true
        foreach ($tok in $tokens) {
            [int] $n = 0
            if ([int]::TryParse($tok, [ref] $n) -and $n -ge 1 -and $n -le $tools.Count) {
                if (-not $sel.Contains($n - 1)) { $sel.Add($n - 1) }
            } else {
                Write-Host ('  [!] "{0}" no valido (1-{1}, T, F, O, B).' -f $tok, $tools.Count) -ForegroundColor Red
                $valid = $false; break
            }
        }
        if (-not $valid -or $sel.Count -eq 0) { continue }

        if (-not (Test-Path $bootstrap)) {
            Write-Host ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $bootstrap) -ForegroundColor Red
            continue
        }

        foreach ($idx in $sel) {
            $t = $tools[$idx]
            Write-Host ('  Procesando: {0}...' -f $t.name) -ForegroundColor Cyan
            if ($forceToggle) { & $bootstrap -ToolName $t.name -Force }
            else              { & $bootstrap -ToolName $t.name }
        }

    } while ($true)
}

# ─── Show-IndividualActionsSubmenu ────────────────────────────────────────────
function Show-IndividualActionsSubmenu {
    <#
    .SYNOPSIS
        Submenu [A] con las acciones individuales del PCTk v1. No se mostraban
        antes desde el menu principal porque competian con los perfiles, pero
        siguen siendo utiles cuando el operador quiere correr SOLO una accion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $MachineProfile
    )

    [object[]] $rows = Get-IndividualActionRows
    $script:PctkBannerProfile = $MachineProfile   # ver nota en Show-MainMenu (no GetNewClosure)
    [scriptblock] $renderHeader = { Clear-Host; Show-MachineBanner -MachineProfile $script:PctkBannerProfile }

    do {
        [string] $choice = Read-PctkMenuChoice -Rows $rows -RenderHeader $renderHeader

        # Enter vacio = re-mostrar el submenu
        if ([string]::IsNullOrEmpty($choice)) { continue }

        if ($choice -eq 'B' -or $choice -eq 'X') {
            return
        }

        Invoke-IndividualActionDispatch -Choice $choice -MachineProfile $MachineProfile
        Write-Host ''
        Read-Host '  [Enter] para continuar' | Out-Null
    }
    while ($true)
}

# ─── Invoke-IndividualActionDispatch ──────────────────────────────────────────
function Invoke-IndividualActionDispatch {
    <#
    .SYNOPSIS
        Cablea cada opcion del submenu a su modulo. Cada handler usa el
        JobManager (Start-* / Wait-ToolkitJobs) para correr async y mostrar
        el resumen al final.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Choice,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [string] $up = $Choice.ToUpperInvariant()
    switch ($up) {
        '1'  { Invoke-ActionDebloat        -MachineProfile $MachineProfile; return }
        '2'  { Invoke-ActionCleanup        -MachineProfile $MachineProfile; return }
        '3'  { Invoke-ActionMaintenance    -MachineProfile $MachineProfile; return }
        '4'  { Invoke-ActionRestorePoint   -MachineProfile $MachineProfile; return }
        '5'  { Invoke-ActionNetwork        -MachineProfile $MachineProfile; return }
        '6'  { Invoke-ActionPerformance    -MachineProfile $MachineProfile; return }
        '7'  { Invoke-ActionDriverBackup   -MachineProfile $MachineProfile; return }
        '8'  { Invoke-ActionApps           -MachineProfile $MachineProfile; return }
        '9'  { Invoke-ActionPrivacy        -MachineProfile $MachineProfile; return }
        '10' { Invoke-ActionStartup        -MachineProfile $MachineProfile; return }
        '11' { Invoke-ActionWindowsUpdate  -MachineProfile $MachineProfile; return }
        '12' { Invoke-ActionCoreIsolation   -MachineProfile $MachineProfile; return }
        '13' { Invoke-ActionHags            -MachineProfile $MachineProfile; return }
        '14' { Invoke-ActionTimerResolution -MachineProfile $MachineProfile; return }
        '15' { Invoke-ActionProcessPriority -MachineProfile $MachineProfile; return }
        '16' { Invoke-ActionUsbPower        -MachineProfile $MachineProfile; return }
        default {
            Write-Host '  Opcion invalida.' -ForegroundColor Red
        }
    }
}

# ─── Action handlers (Stage 1 C6) ─────────────────────────────────────────────
# Cada handler es defensivo (try/catch) y reporta success/failure de manera
# uniforme. Audit log per-action se distribuye en C7.

function Invoke-ActionDebloat {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    [string[]] $bloatList = @(
        'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
        'Spooler (cola de impresion)', 'PrintNotify', 'Fax', 'WMPNetworkSvc',
        'RemoteRegistry', 'RemoteAccess', 'DiagTrack (telemetria)', 'dmwappushservice'
    )
    if (-not (Confirm-Action -Title 'Aplicar Debloat: deshabilitar 12 servicios bloat?' -Lines @(
        ($bloatList -join ', '),
        'Reversible: Set-Service -Name <X> -StartupType Automatic; Start-Service <X>',
        'OJO con Spooler/PrintNotify si imprimis desde esta PC.'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Debloat' -Status 'Cancelled'
        return
    }

    Write-ActionAudit -Action 'Debloat' -Status 'Started'
    Write-Host '  Deshabilitando servicios bloat...' -ForegroundColor Cyan
    $job = Start-DebloatProcess
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Debloat' -TimeoutSeconds 120)[0]
    if ($null -eq $r) {
        Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Debloat' -Status 'Failed' -Summary 'No result'
        return
    }
    Write-Host ('  Servicios objetivo: {0}' -f $r.TotalTargeted) -ForegroundColor Cyan
    Write-Host ('    [OK]            Deshabilitados ahora:   {0}' -f $r.Disabled) -ForegroundColor Green
    Write-Host ('    [SKIP]          Ya estaban disabled:    {0}' -f $r.AlreadyDisabled) -ForegroundColor DarkGray
    Write-Host ('    [SKIP]          No existen en sistema:  {0}' -f $r.Skipped) -ForegroundColor DarkGray
    Write-Host ('    [FAIL]          Errores:                {0}' -f $r.Failed) -ForegroundColor $(if ($r.Failed -gt 0) { 'Yellow' } else { 'DarkGray' })
    if ($r.SkippedNames.Count -gt 0) {
        Write-Host ('  Omitidos (no existen): {0}' -f ($r.SkippedNames -join ', ')) -ForegroundColor DarkGray
    }
    if ($r.Errors.Count -gt 0) {
        Write-Host '  Errores:' -ForegroundColor Yellow
        foreach ($e in $r.Errors) { Write-Host ('    - {0}' -f $e) -ForegroundColor DarkGray }
    }
    Write-ActionAudit -Action 'Debloat' -Status 'Success' -Summary ('Disabled={0} AlreadyDisabled={1} Skipped={2} Failed={3}' -f $r.Disabled, $r.AlreadyDisabled, $r.Skipped, $r.Failed) -Details $r
}

function Invoke-ActionCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-PctkValue '  [P]review (escanea sin borrar)  /  [R]un (borra)  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()

    if ($sub -eq 'P') {
        Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Started'
        Write-PctkWork '  Escaneando rutas de limpieza...'
        $job = Start-CleanupPreviewJob
        $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Escaneo temporales' -TimeoutSeconds 180)[0]
        if ($null -eq $r) { Write-PctkWarn '  [!] Sin resultado.'; Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Failed'; return }
        Write-PctkOk ('  Total a liberar: {0} MB ({1} GB)' -f $r.TotalMB, $r.TotalGB)
        foreach ($f in $r.Folders) {
            Write-PctkValue ('    {0,-50}  {1,8} MB' -f $f.Label, $f.SizeMB)
        }
        Write-ActionAudit -Action 'Cleanup.Preview' -Status 'Success' -Summary ('Estimate {0} MB' -f $r.TotalMB) -Details $r
        return
    }
    if ($sub -eq 'R') {
        Write-ActionAudit -Action 'Cleanup.Run' -Status 'Started'
        Write-PctkWork '  Limpiando temporales y caches...'
        $job = Start-CleanupProcess
        $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Limpieza de disco' -TimeoutSeconds 300)[0]
        if ($null -eq $r) { Write-PctkWarn '  [!] Sin resultado.'; Write-ActionAudit -Action 'Cleanup.Run' -Status 'Failed'; return }
        Write-PctkOk ('  [OK] Liberado: {0} MB ({1} GB)  |  Errores: {2}' -f $r.FreedMB, $r.FreedGB, $r.SoftErrors)
        Write-ActionAudit -Action 'Cleanup.Run' -Status 'Success' -Summary ('Freed {0} MB' -f $r.FreedMB) -Details $r
        return
    }
}

function Invoke-ActionMaintenance {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-Host '  DISM + SFC toma 10-20 minutos. Confirma [S/n]:' -ForegroundColor Yellow
    [string] $ans = (Read-Host).Trim().ToUpperInvariant()
    if ($ans -ne 'S' -and $ans -ne '') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; Write-ActionAudit -Action 'Maintenance' -Status 'Cancelled'; return }
    Write-ActionAudit -Action 'Maintenance' -Status 'Started'
    Write-Host '  Ejecutando DISM RestoreHealth + SFC scannow...' -ForegroundColor Cyan
    $job = Start-MaintenanceProcess
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'DISM + SFC' -TimeoutSeconds 1800)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Maintenance' -Status 'Failed'; return }
    Write-Host ('  [OK] DISM exit={0}  SFC exit={1}' -f $r.DismExitCode, $r.SfcExitCode) -ForegroundColor Green
    Write-ActionAudit -Action 'Maintenance' -Status 'Success' -Summary ('DISM={0} SFC={1}' -f $r.DismExitCode, $r.SfcExitCode)
}

function Invoke-ActionRestorePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'RestorePoint' -Status 'Started'
    Write-Host '  Creando punto de restauracion...' -ForegroundColor Cyan
    $job = Start-RestorePointProcess
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Restore Point' -TimeoutSeconds 180)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'RestorePoint' -Status 'Failed'; return }

    if ($r.Success) {
        Write-Host ('  [OK] {0}' -f $r.Message) -ForegroundColor Green
        if ($r.Bypassed) {
            Write-Host '  (Cooldown bypaseado via registry temporal)' -ForegroundColor DarkGray
        }
        Write-ActionAudit -Action 'RestorePoint' -Status 'Success' -Summary $r.Message -Details $r
        return
    }

    # Caso cooldown: mostrar info del RP existente y ofrecer bypass.
    if ($r.PSObject.Properties['CooldownActive'] -and $r.CooldownActive -and $null -ne $r.LatestRp) {
        Write-Host ('  [!] Cooldown activo: ya hay un RP reciente.') -ForegroundColor Yellow
        Write-Host ('       Ultimo RP: "{0}" creado hace {1} horas (SequenceNumber={2})' -f $r.LatestRp.Description, $r.LatestRp.HoursAgo, $r.LatestRp.SequenceNumber) -ForegroundColor DarkGray
        Write-Host ('       CreationTime: {0}' -f $r.LatestRp.CreationTime) -ForegroundColor DarkGray
        Write-Host ''
        if (Confirm-Action -Title 'Forzar creacion de RP nuevo? (bypass cooldown via registry temporal)' -Lines @(
            'Va a modificar HKLM\...\SystemRestore\SystemRestorePointCreationFrequency=0 temporalmente',
            'Despues de crear el RP, el registry se restaura al valor previo',
            'El RP existente queda intacto, se suma uno nuevo'
        ) -DefaultYes $false) {
            Write-Host '  Forzando nuevo RP...' -ForegroundColor Cyan
            $bypassJob = Start-RestorePointProcess -BypassCooldown
            $r2 = (Invoke-JobWithProgress -Jobs @($bypassJob) -Activity 'Restore Point bypass' -TimeoutSeconds 180)[0]
            if ($null -ne $r2 -and $r2.Success) {
                Write-Host ('  [OK] {0}  (bypass aplicado)' -f $r2.Message) -ForegroundColor Green
                Write-ActionAudit -Action 'RestorePoint' -Status 'Success' -Summary 'Created with bypass' -Details $r2
            } else {
                [string] $em = if ($null -ne $r2) { $r2.Message } else { 'sin resultado' }
                Write-Host ('  [!] Bypass fallo: {0}' -f $em) -ForegroundColor Yellow
                Write-ActionAudit -Action 'RestorePoint' -Status 'Failed' -Summary ('Bypass failed: ' + $em)
            }
        } else {
            Write-Host '  OK, te quedas con el RP existente como fallback.' -ForegroundColor DarkGray
            Write-ActionAudit -Action 'RestorePoint' -Status 'Cancelled' -Summary 'Cooldown - operator kept existing RP' -Details $r
        }
        return
    }

    # Cualquier otro fallo (System Restore disabled, etc.)
    [string] $msg = if ($r.PSObject.Properties['Reason']) { $r.Reason } else { $r.Message }
    Write-Host ('  [!] {0}' -f $msg) -ForegroundColor Yellow
    Write-ActionAudit -Action 'RestorePoint' -Status 'Failed' -Summary $msg
}

function Invoke-ActionNetwork {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-Host '  [D]iagnostico (read-only)  /  [O]ptimizar  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()

    if ($sub -eq 'D') {
        Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Started'
        Write-Host '  Recopilando diagnostico de red...' -ForegroundColor Cyan
        $job = Start-NetworkDiagnosticsProcess
        $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Diagnostico de red' -TimeoutSeconds 60)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Failed'; return }
        Write-Host ('  TCP AutoTuning : {0}' -f $r.TcpAutoTuning)
        Write-Host ('  Ping 8.8.8.8   : {0} ms' -f $r.PingMs)
        foreach ($a in $r.Adapters) { Write-Host ('  Adapter        : {0,-25} {1,-15} [{2}]' -f $a.Name, $a.LinkSpeed, $a.MediaType) }
        foreach ($k in $r.DnsServers.Keys) { Write-Host ('  DNS {0,-15}: {1}' -f $k, ($r.DnsServers[$k] -join ', ')) }
        Write-ActionAudit -Action 'Network.Diagnostics' -Status 'Success' -Summary ('Tuning={0} Ping={1}ms' -f $r.TcpAutoTuning, $r.PingMs) -Details $r
        return
    }
    if ($sub -eq 'O') {
        # Listar adapters fisicos detectados para preview
        [string[]] $eligible = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -in @('802.3', 'Native 802.11') } |
                ForEach-Object { ('{0} ({1})' -f $_.Name, $_.PhysicalMediaType) }
        )
        [string[]] $previewLines = @(
            ('Adapters fisicos activos: {0}' -f $(if ($eligible.Count -gt 0) { $eligible -join ', ' } else { '(ninguno detectado)' })),
            'Va a deshabilitar en cada adapter (si aplica): EEE, Green Ethernet, PowerSavingMode, EnablePME, ULPMode',
            'TCP global: autotuninglevel=normal (skip si ya es normal), fastopen=enabled (best-effort)',
            'ipconfig /flushdns',
            'Reversible manual: Device Manager > adapter > Advanced/Power Management.'
        )
        if (-not (Confirm-Action -Title 'Aplicar Network Optimize?' -Lines $previewLines)) {
            Write-Host '  Cancelado.' -ForegroundColor DarkGray
            Write-ActionAudit -Action 'Network.Optimize' -Status 'Cancelled'
            return
        }
        Write-ActionAudit -Action 'Network.Optimize' -Status 'Started'
        Write-Host '  Optimizando red (NIC power props + TCP global)...' -ForegroundColor Cyan
        $job = Start-NetworkProcess
        $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Optimizar red' -TimeoutSeconds 120)[0]
        if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Network.Optimize' -Status 'Failed'; return }
        if ($r.AdaptersOptimized.Count -eq 0) {
            Write-Host '  [i] No se encontraron adapters fisicos (802.3 Ethernet / Wi-Fi 802.11) para optimizar.' -ForegroundColor DarkYellow
            Write-Host '      Esto es esperable en Windows Sandbox o VMs (solo tienen adapter virtual).' -ForegroundColor DarkGray
        } else {
            foreach ($a in $r.AdaptersOptimized) {
                Write-Host ('  [{0}] {1}  changes={2}' -f $(if ($a.ChangesMade -gt 0) { 'OK' } else { '--' }), $a.Name, $a.ChangesMade)
            }
        }
        if ($r.PSObject.Properties['NetshIssues'] -and $r.NetshIssues.Count -gt 0) {
            foreach ($i in $r.NetshIssues) { Write-Host ('  [!] {0}' -f $i) -ForegroundColor Yellow }
        }
        Write-ActionAudit -Action 'Network.Optimize' -Status 'Success' -Summary ('{0} adapters' -f $r.AdaptersOptimized.Count) -Details $r
        return
    }
}

function Invoke-ActionPerformance {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)

    [string] $defaultProfile = if ($MachineProfile.IsLowRam) { 'Full' } else { 'Balanced' }
    Write-Host ('  Perfiles disponibles: [B]alanced  [F]ull (max performance)  [R]estore (defaults)  [T]weaksOnly (sin visuales)')
    Write-Host ('  Default sugerido segun tu hardware: {0}' -f $defaultProfile) -ForegroundColor DarkGray
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    [string] $vp = switch ($sub) {
        'B' { 'Balanced' }
        'F' { 'Full' }
        'R' { 'Restore' }
        'T' { 'TweaksOnly' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($vp)) { Write-Host '  Opcion invalida o cancelada.' -ForegroundColor DarkGray; return }

    # Mostrar plan de energia actual ANTES de tocar nada — el usuario lo necesita para revertir si no le gusta.
    [string] $currentPlanLabel = '(desconocido)'
    try {
        [string] $activeOut = (& powercfg /getactivescheme 2>&1) -join "`n"
        if ($activeOut -match ':\s*([0-9a-f-]{36})\s*\(([^)]+)\)') {
            $currentPlanLabel = ('{0}  (GUID: {1})' -f $Matches[2].Trim(), $Matches[1])
        }
    } catch { }

    [string] $targetPlanHint = if ($MachineProfile.IsLaptop) { 'Balanced (laptop con TDP locked)' } else { 'Ultimate Performance o High Performance (desktop)' }
    [string[]] $visualsDescription = switch ($vp) {
        'Balanced'   { @('Deshabilita animaciones, sombras, transparencias. Conserva ClearType, thumbnails, drag-fullwindow.') }
        'Full'       { @('Max Performance: TODO el efecto visual off. Equivale a "Adjust for best performance".') }
        'Restore'    { @('Restaura visuales a Windows defaults (efectos activos).') }
        'TweaksOnly' { @('NO toca visuales. Solo aplica system tweaks + power plan.') }
    }

    if (-not (Confirm-Action -Title ('Aplicar perfil Performance: {0}?' -f $vp) -Lines @(
        ('Plan de energia actual: {0}' -f $currentPlanLabel),
        ('Plan de energia objetivo: {0}' -f $targetPlanHint),
        ('Visuales: ' + ($visualsDescription -join ' / ')),
        'System tweaks: hibernacion off, SvcHost (si RAM<=8GB), shutdown timeout 2000ms, Game DVR off',
        'Reversible: re-correr con [R]estore para volver a defaults.',
        'Plan de energia previo se imprime al terminar (anotalo).'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Performance' -Status 'Cancelled' -Summary $vp
        return
    }

    Write-ActionAudit -Action 'Performance' -Status 'Started' -Summary ('Profile={0}' -f $vp)
    Write-Host ('  Aplicando perfil {0} + power plan + system tweaks...' -f $vp) -ForegroundColor Cyan
    $job = Start-PerformanceProcess -VisualProfile $vp
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Rendimiento' -TimeoutSeconds 120)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Performance' -Status 'Failed'; return }
    if ($null -ne $r.Visuals)    { Write-Host ('  Visuales:  Success={0}  Applied={1}' -f $r.Visuals.Success, $r.Visuals.Applied.Count) }
    if ($null -ne $r.PowerPlan)  {
        Write-Host ('  PowerPlan: {0}  ({1})' -f $r.PowerPlan.PlanName, $r.PowerPlan.Reason)
        if (-not [string]::IsNullOrWhiteSpace($r.PowerPlan.PreviousName)) {
            Write-Host ('             Plan previo: {0}  (GUID: {1})' -f $r.PowerPlan.PreviousName, $r.PowerPlan.PreviousGuid) -ForegroundColor DarkGray
            Write-Host ('             Para revertir: powercfg /setactive {0}' -f $r.PowerPlan.PreviousGuid) -ForegroundColor DarkGray
        }
    }
    if ($null -ne $r.Tweaks)     { Write-Host ('  Tweaks:    Success={0}  Applied={1}' -f $r.Tweaks.Success, $r.Tweaks.Applied.Count) }
    Write-ActionAudit -Action 'Performance' -Status 'Success' -Summary $vp -Details $r
}

function Invoke-ActionDriverBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    [string] $toolkitRoot = Split-Path -Parent $PSScriptRoot
    [string] $outDir = Join-Path $toolkitRoot 'output\driver_backup'
    Write-ActionAudit -Action 'Drivers.Backup' -Status 'Started'
    Write-Host ('  Exportando drivers a {0}...' -f $outDir) -ForegroundColor Cyan
    $job = Start-DriverBackupJob -OutputRoot $outDir
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Backup drivers' -TimeoutSeconds 600)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Drivers.Backup' -Status 'Failed'; return }
    if ($r.Success) {
        Write-Host ('  [OK] {0} drivers exportados de {1} candidatos. {2}' -f $r.Exported, $r.Total, $r.Message) -ForegroundColor Green
        Write-Host ('       {0}' -f $r.Destination) -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Drivers.Backup' -Status 'Success' -Summary ('{0}/{1} drivers' -f $r.Exported, $r.Total) -Details $r
    } else {
        Write-Host ('  [!] {0}' -f $r.Message) -ForegroundColor Yellow
        Write-ActionAudit -Action 'Drivers.Backup' -Status 'Failed' -Summary $r.Message
    }
}

function Invoke-ActionApps {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-ActionAudit -Action 'Apps.List' -Status 'Started'
    Write-Host '  Listando apps Win32 + UWP (puede tardar)...' -ForegroundColor Cyan
    $win32Job   = Start-Win32AppsJob
    $uwpJob     = Start-UwpAppsJob
    $jobResults = Invoke-JobWithProgress -Jobs @($win32Job, $uwpJob) -Activity 'Listado de apps' -TimeoutSeconds 180

    [PSCustomObject[]] $win32 = @()
    [PSCustomObject[]] $uwp   = @()
    if ($jobResults.Count -ge 1 -and $null -ne $jobResults[0]) { $win32 = @($jobResults[0]) }
    if ($jobResults.Count -ge 2 -and $null -ne $jobResults[1]) { $uwp   = @($jobResults[1]) }
    Write-ActionAudit -Action 'Apps.List' -Status 'Success' -Summary ('Win32={0} UWP={1}' -f $win32.Count, $uwp.Count)

    if ($win32.Count -eq 0 -and $uwp.Count -eq 0) {
        Write-Host '  Sin apps instaladas detectadas.' -ForegroundColor Yellow
        return
    }

    # Build unified index list: Win32 first, UWP after
    [System.Collections.Generic.List[PSCustomObject]] $allApps =
        [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($a in $win32) { $allApps.Add([PSCustomObject]@{ Type = 'Win32'; App = $a }) }
    foreach ($a in $uwp)   { $allApps.Add([PSCustomObject]@{ Type = 'UWP';   App = $a }) }

    Write-Host ''
    if ($win32.Count -gt 0) {
        Write-Host ('  Win32 ({0}):' -f $win32.Count) -ForegroundColor Cyan
        for ([int] $i = 0; $i -lt $win32.Count; $i++) {
            $a = $win32[$i]
            [string] $nm  = ($a.Name -replace '[\r\n]', ' ')
            if ($nm.Length -gt 38) { $nm = $nm.Substring(0, 35) + '...' }
            [string] $ver = if (-not [string]::IsNullOrWhiteSpace($a.Version))   { $a.Version.Substring(0, [Math]::Min($a.Version.Length, 12)) }   else { '' }
            [string] $pub = if (-not [string]::IsNullOrWhiteSpace($a.Publisher)) { $a.Publisher.Substring(0, [Math]::Min($a.Publisher.Length, 28)) } else { '' }
            Write-Host ('  [{0,3}] {1,-38}  {2,-12}  {3}' -f $i, $nm, $ver, $pub)
        }
    }

    [int] $uwpOffset = $win32.Count
    if ($uwp.Count -gt 0) {
        Write-Host ''
        Write-Host ('  UWP ({0}):' -f $uwp.Count) -ForegroundColor Cyan
        for ([int] $i = 0; $i -lt $uwp.Count; $i++) {
            $a       = $uwp[$i]
            [int]    $idx   = $uwpOffset + $i
            [string] $dn    = ($a.DisplayName -replace '[\r\n]', ' ')
            if ($dn.Length -gt 38) { $dn = $dn.Substring(0, 35) + '...' }
            [string] $msLbl = if ($a.IsMicrosoft) { '  (MS)' } else { '' }
            Write-Host ('  [{0,3}] {1}{2}' -f $idx, $dn, $msLbl)
        }
    }

    Write-Host ''
    Write-Host ('  Total: {0} Win32 + {1} UWP = {2}. Numeros, lista (3,7), rango (4-8) o V para volver:' -f $win32.Count, $uwp.Count, $allApps.Count) -ForegroundColor DarkGray
    [string] $raw = (Read-Host '  >').Trim()
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.ToUpperInvariant() -eq 'V') { return }

    # Parse multi-selection: numeros sueltos, lista con coma/espacio, rangos N-M
    [string[]] $tokens = $raw -split '[,\s]+' | Where-Object { $_ -ne '' }
    [System.Collections.Generic.List[int]] $selIdx = [System.Collections.Generic.List[int]]::new()
    foreach ($tok in $tokens) {
        [int] $n = 0
        if ([int]::TryParse($tok, [ref] $n)) {
            if ($n -ge 0 -and $n -lt $allApps.Count) {
                if (-not $selIdx.Contains($n)) { $selIdx.Add($n) }
            } else {
                Write-Host ('  [!] "{0}" fuera de rango (0-{1}), ignorado.' -f $tok, ($allApps.Count - 1)) -ForegroundColor Yellow
            }
        } elseif ($tok -match '^\d+-\d+$') {
            [string[]] $parts = $tok -split '-'
            [int] $from = [int] $parts[0]
            [int] $to   = [int] $parts[1]
            if ($from -gt $to) { [int] $tmp = $from; $from = $to; $to = $tmp }
            for ([int] $r = $from; $r -le $to; $r++) {
                if ($r -ge 0 -and $r -lt $allApps.Count) {
                    if (-not $selIdx.Contains($r)) { $selIdx.Add($r) }
                } else {
                    Write-Host ('  [!] Indice {0} fuera de rango (0-{1}), ignorado.' -f $r, ($allApps.Count - 1)) -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host ('  [!] "{0}" no valido, ignorado.' -f $tok) -ForegroundColor Yellow
        }
    }
    if ($selIdx.Count -eq 0) {
        Write-Host '  Sin seleccion valida. Cancelado.' -ForegroundColor DarkGray
        return
    }

    # Preview por app seleccionada
    Write-Host ''
    Write-Host '  Preview:' -ForegroundColor Cyan
    [System.Collections.Generic.List[PSCustomObject]] $queue = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($idx in @($selIdx | Sort-Object)) {
        $entry = $allApps[$idx]
        if ($entry.Type -eq 'Win32') {
            $preview = Get-Win32UninstallPreview -App $entry.App
            [string] $appName = $entry.App.Name
        } else {
            $preview = Get-UwpUninstallPreview -App $entry.App
            [string] $appName = $entry.App.DisplayName
        }
        Write-Host ('  [{0,3}] {1}' -f $idx, ($appName -replace '[\r\n]', ' ')) -ForegroundColor White
        Write-Host ('         Metodo:  {0}' -f $preview.MethodLabel) -ForegroundColor DarkGray
        Write-Host ('         Comando: {0}' -f $preview.CommandLine) -ForegroundColor DarkGray
        if (-not $preview.Success) {
            Write-Host ('         AVISO:   {0}' -f $preview.Error) -ForegroundColor Yellow
        }
        $queue.Add([PSCustomObject]@{ Idx = $idx; Entry = $entry; Preview = $preview; AppName = $appName })
    }

    # Confirmacion unica — DefaultYes=$false (Enter = NO, seguro para PC de cliente)
    [string[]] $confirmLines = @($queue | ForEach-Object {
        [string]('{0} ({1}) via {2}' -f $_.AppName, $_.Entry.Type, $_.Preview.MethodLabel)
    })
    Write-Host ''
    if (-not (Confirm-Action -Title ('Desinstalar {0} app(s)?' -f $queue.Count) `
                             -Lines $confirmLines -DefaultYes $false)) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Apps.Uninstall' -Status 'Cancelled' -Summary ('Seleccion={0}' -f $queue.Count)
        return
    }

    # Desinstalar app por app
    Write-Host ''
    [int] $okCount   = 0
    [int] $failCount = 0
    foreach ($item in $queue) {
        Write-Host ('  Desinstalando: {0}...' -f $item.AppName) -ForegroundColor Cyan -NoNewline
        if ($item.Entry.Type -eq 'Win32') {
            $r = Invoke-Win32Uninstall -App $item.Entry.App
        } else {
            $r = Invoke-UwpUninstall -App $item.Entry.App
        }
        if ($r.Success) {
            $okCount++
            Write-Host ' [OK]' -ForegroundColor Green
            Write-ActionAudit -Action 'Apps.Uninstall' -Status 'Success' `
                -Summary ('{0} via {1}' -f $item.AppName, $r.Method) -Details $r
        } else {
            $failCount++
            Write-Host (' [!] {0}' -f $r.Error) -ForegroundColor Red
            Write-ActionAudit -Action 'Apps.Uninstall' -Status 'Failed' `
                -Summary ('{0} via {1}' -f $item.AppName, $r.Method) -Details $r
        }
    }

    # Resumen + audit batch
    Write-Host ''
    [string] $summaryColor = if ($failCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ('  Resultado: {0} OK / {1} fallidas' -f $okCount, $failCount) -ForegroundColor $summaryColor
    Write-ActionAudit -Action 'Apps.Uninstall.Batch' -Status 'Success' `
        -Summary ('OK={0} Failed={1}' -f $okCount, $failCount)
}

function Invoke-ActionPrivacy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-Host '  Modo: [B]asic  [M]edium  [A]ggressive  [O]OSU10 GUI  [V]olver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -eq 'O') {
        Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Started'
        if (Test-ShutUp10Available) {
            $r = Open-ShutUp10
            if ($r.Success) { Write-Host ('  [OK] OOSU10 abierto: {0}' -f $r.Path) -ForegroundColor Green; Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Success' -Summary $r.Path }
            else            { Write-Host ('  [!] {0}' -f $r.Error) -ForegroundColor Yellow; Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Failed' -Summary $r.Error }
        } else {
            Write-Host '  [!] OOSU10.exe no esta descargado. Usa [T] Herramientas para bajarlo.' -ForegroundColor Yellow
            Write-ActionAudit -Action 'Privacy.OOSU10' -Status 'Failed' -Summary 'OOSU10 not installed'
        }
        return
    }
    [string] $profile = switch ($sub) {
        'B' { 'Basic' }
        'M' { 'Medium' }
        'A' { 'Aggressive' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($profile)) { return }

    [string[]] $profileDescription = switch ($profile) {
        'Basic' {
            @(
                'Telemetria (AllowTelemetry=0)',
                'Advertising ID off',
                'Bing en busqueda de inicio off',
                'Cortana consent off',
                'Feedback de Windows off',
                'Activity Feed off'
            )
        }
        'Medium' {
            @(
                'Todos los Basic',
                'Ubicacion global del sistema off',
                'Experiencias personalizadas con telemetria off',
                'Sugerencias en panel Inicio off',
                'Apps silenciosas instaladas por Microsoft off',
                'Actualizacion automatica de mapas off'
            )
        }
        'Aggressive' {
            @(
                'Todos los Medium',
                'OneDrive sync DESHABILITADO (policy) — OJO si usas OneDrive!',
                'Edge Startup Boost off',
                'Edge background mode off',
                'Consumer features de Windows off',
                'Tips y sugerencias de apps off',
                'Windows Error Reporting off'
            )
        }
    }
    Write-Host ''
    Write-Host '  [!] DEPRECATED: esta accion aplica tweaks privacy NATIVOS' -ForegroundColor Yellow
    Write-Host '       (registry hardcoded por el toolkit, NO mantenido upstream).' -ForegroundColor Yellow
    Write-Host '       Recomendado: usar [1] perfil automatico, que aplica' -ForegroundColor Yellow
    Write-Host '       OOSU10 con .cfg curadas (mantenido por el proyecto OOSU).' -ForegroundColor Yellow
    Write-Host ''
    [string] $depConfirm = (Read-Host '  Continuar con tweaks nativos igual? [s/N]').Trim().ToUpperInvariant()
    if ($depConfirm -ne 'S' -and $depConfirm -ne 'SI') {
        Write-Host '  Cancelado (recomendado).' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Privacy.Apply' -Status 'Cancelled' `
            -Summary ('DEPRECATED-skip: {0}' -f $profile)
        return
    }

    if (-not (Confirm-Action -Title ('Aplicar Privacy: perfil {0}?' -f $profile) -Lines $profileDescription)) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Privacy.Apply' -Status 'Cancelled' -Summary $profile
        return
    }

    Write-ActionAudit -Action 'Privacy.Apply' -Status 'Started' -Summary ('Profile={0}' -f $profile)
    Write-Host ('  Aplicando perfil {0} (registry tweaks)...' -f $profile) -ForegroundColor Cyan
    $job = Start-PrivacyJob -Profile $profile
    $r = (Invoke-JobWithProgress -Jobs @($job) -Activity 'Privacidad' -TimeoutSeconds 120)[0]
    if ($null -eq $r) { Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow; Write-ActionAudit -Action 'Privacy.Apply' -Status 'Failed'; return }
    Write-Host ('  [OK] Aplicados: {0}  |  Errores: {1}' -f $r.Applied.Count, $r.Errors.Count) -ForegroundColor Green
    Write-ActionAudit -Action 'Privacy.Apply' -Status 'Success' -Summary ('{0}: Applied={1} Errors={2}' -f $profile, $r.Applied.Count, $r.Errors.Count) -Details $r
}

function Invoke-ActionStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-ActionAudit -Action 'Startup.List' -Status 'Started'
    [int]  $toggleCount = 0
    [bool] $listed      = $false

    do {
        [object[]] $entriesRaw = @(Get-StartupEntries)
        if ($entriesRaw.Count -eq 0) {
            Write-PctkHint '  Sin entradas de inicio.'
            if (-not $listed) { Write-ActionAudit -Action 'Startup.List' -Status 'Success' -Summary '0 entries' }
            return
        }

        # Agrupar: ON primero, OFF despues. Where-Object preserva el orden de
        # deteccion dentro de cada grupo (estable; Sort-Object -Stable no existe en
        # PS5.1). El indice [i] que tipea el operador sigue mapeando a $entries.
        [object[]] $on  = @($entriesRaw | Where-Object { $_.Enabled })
        [object[]] $off = @($entriesRaw | Where-Object { -not $_.Enabled })
        [object[]] $entries = @($on + $off)
        [int] $onCount = $on.Count

        Write-PctkActionTitle ('INICIO DEL SISTEMA  ({0} entradas detectadas)' -f $entries.Count)
        for ([int] $i = 0; $i -lt $entries.Count; $i++) {
            if ($i -eq 0 -and $onCount -gt 0)            { Write-PctkSection ('  ACTIVAS  ({0})' -f $onCount) }
            if ($i -eq $onCount -and $off.Count -gt 0)   { Write-Host ''; Write-PctkSection ('  DESACTIVADAS  ({0})' -f $off.Count) }
            [PSCustomObject] $e = $entries[$i]
            [string] $state = if ($e.Enabled) { 'ON ' } else { 'OFF' }
            [string] $extra = if (-not $e.CanToggle) { '  (RunOnce - no editable)' } else { '' }
            [string] $desc  = Get-StartupDescription -Name ([string]$e.Name)
            [string] $descTag = if (-not [string]::IsNullOrEmpty($desc)) { '  - ' + $desc } else { '' }
            # fila coloreada por estado: habilitada = slate (normal), deshabilitada = dim.
            [string] $row = ('  [{0,3}] {1}  {2,-16}  {3}{4}{5}' -f $i, $state, $e.Location, $e.Name, $extra, $descTag)
            if ($e.Enabled) { Write-PctkValue $row } else { Write-PctkHint $row }
        }
        if (-not $listed) {
            Write-ActionAudit -Action 'Startup.List' -Status 'Success' -Summary ('{0} entries' -f $entries.Count)
            $listed = $true
        }
        Write-Host ''
        Write-PctkHint '  Indice/s (ej: 3  o  1,4  o  2-5), V para volver:'
        [string] $raw = (Read-Host '  >').Trim().ToUpperInvariant()

        if ($raw -eq 'V' -or [string]::IsNullOrEmpty($raw)) { break }

        # Parsear seleccion: individual, lista o rango
        [int[]] $selRaw = @()
        foreach ($part in ($raw -split ',')) {
            [string] $p = $part.Trim()
            if ($p -match '^(\d+)-(\d+)$') {
                [int] $from = [int] $Matches[1]
                [int] $to   = [int] $Matches[2]
                if ($from -gt $to) { [int] $tmp = $from; $from = $to; $to = $tmp }
                for ([int] $j = $from; $j -le $to; $j++) { $selRaw += $j }
            } elseif ($p -match '^\d+$') {
                $selRaw += [int] $p
            }
        }
        [object[]] $selIdx = @($selRaw | Sort-Object -Unique | Where-Object { $_ -ge 0 -and $_ -lt $entries.Count })
        if ($selIdx.Count -eq 0) {
            Write-PctkErr ('  [!] Sin indices validos entre 0 y {0}.' -f ($entries.Count - 1))
            continue
        }

        # Separar toggleables de no-toggleables
        [object[]] $toToggle = @($selIdx | ForEach-Object { $entries[$_] } | Where-Object { $_.CanToggle })
        [object[]] $skipped  = @($selIdx | ForEach-Object { $entries[$_] } | Where-Object { -not $_.CanToggle })
        foreach ($sk in $skipped) {
            Write-PctkHint ('  [skip] {0} ({1}): no se puede modificar.' -f $sk.Name, $sk.Location)
        }
        if ($toToggle.Count -eq 0) { continue }

        # Confirmar si alguna entrada va a deshabilitarse
        [object[]] $willDisable = @($toToggle | Where-Object { $_.Enabled })
        if ($willDisable.Count -gt 0) {
            [string[]] $confirmLines = @($toToggle | ForEach-Object {
                [string] $dir = if ($_.Enabled) { 'ON -> OFF' } else { 'OFF -> ON' }
                ('{0}  [{1}]  {2}' -f $dir, $_.Location, $_.Name)
            })
            if (-not (Confirm-Action -Title ('Alternar {0} entrada(s) de inicio?' -f $toToggle.Count) `
                                     -Lines $confirmLines -DefaultYes $false)) {
                Write-PctkHint '  Cancelado.'
                continue
            }
        }

        foreach ($entry in $toToggle) {
            [bool]           $target = -not $entry.Enabled
            [PSCustomObject] $r      = Set-StartupEntry -Entry $entry -Enabled $target

            if ($r.Success) {
                [string] $newState = if ($target) { 'ON' } else { 'OFF' }
                Write-PctkOk ('  [OK] {0} {1} -> {2}' -f $entry.Location, $entry.Name, $newState)
                $toggleCount++
                Write-ActionAudit -Action 'Startup.Toggle' -Status 'Success' `
                    -Summary ('{0} {1} -> {2}' -f $entry.Location, $entry.Name, $(if ($target) { 'ON' } else { 'OFF' })) `
                    -Details $r
            }
            else {
                Write-PctkErr ('  [!] {0}: {1}' -f $entry.Name, $r.Error)
                Write-ActionAudit -Action 'Startup.Toggle' -Status 'Failed' `
                    -Summary ('{0} {1}' -f $entry.Location, $entry.Name) -Details $r
            }
        }

    } while ($true)

    Write-ActionAudit -Action 'Startup.Toggle.Session' -Status 'Success' `
        -Summary ('{0} cambios en esta sesion' -f $toggleCount)
}

function Invoke-ActionWindowsUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    [bool] $isLtsc = $false
    if ($MachineProfile.PSObject.Properties['IsHome']) { $isLtsc = $false }
    Write-ActionAudit -Action 'WindowsUpdate.Status' -Status 'Started'
    $status = Get-WindowsUpdateStatus -IsLtsc $isLtsc
    Write-Host '  ESTADO DE WINDOWS UPDATE' -ForegroundColor DarkCyan
    Write-Host ('  Ultima instalacion: {0}' -f $status.LastInstall)
    Write-Host ('  Ultima busqueda  : {0}' -f $status.LastCheck)
    Write-Host ('  Fuente           : {0}' -f $status.Source)
    Write-ActionAudit -Action 'WindowsUpdate.Status' -Status 'Success' -Summary ('LastInstall={0}' -f $status.LastInstall) -Details $status
}

# ─── Show-OrphanModuleResult (reporte uniforme de los handlers #11) ──────────
# Los 5 modulos huerfanos devuelven la misma forma: Success / Applied[] /
# Errors[] / RestartRequired / Reason (+ Skipped opcional). Reporter comun.
function Show-OrphanModuleResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter()]          [object] $Result
    )
    if ($null -eq $Result) {
        Write-Host '  [!] Sin resultado.' -ForegroundColor Yellow
        Write-ActionAudit -Action $Action -Status 'Failed' -Summary 'No result'
        return
    }
    if ($Result.PSObject.Properties['Skipped'] -and $Result.Skipped) {
        Write-Host ('  [SKIP] {0}' -f $Result.Reason) -ForegroundColor DarkYellow
        Write-ActionAudit -Action $Action -Status 'Skipped' -Summary $Result.Reason -Details $Result
        return
    }
    foreach ($a in $Result.Applied) { Write-Host ('  [OK]   {0}' -f $a) -ForegroundColor Green }
    foreach ($e in $Result.Errors)  { Write-Host ('  [FAIL] {0}' -f $e) -ForegroundColor Yellow }
    if ($Result.RestartRequired) {
        Write-Host '  [i] Reinicio requerido para que el cambio tome efecto.' -ForegroundColor Cyan
    }
    if (-not [string]::IsNullOrWhiteSpace($Result.Reason)) {
        Write-Host ('  {0}' -f $Result.Reason) -ForegroundColor DarkGray
    }
    [string] $st = if ($Result.Success) { 'Success' } else { 'Failed' }
    Write-ActionAudit -Action $Action -Status $st -Summary ('Applied={0} Errors={1}' -f $Result.Applied.Count, $Result.Errors.Count) -Details $Result
}

# ─── Action handlers: modulos huerfanos expuestos en [A] (backlog #11) ───────
# CoreIsolation / HAGS / TimerResolution / ProcessPriority / UsbPower. Reusan
# las funciones Set de cada modulo DIRECTAMENTE (registry/powercfg sincrono,
# sub-segundo). NO usan JobManager: esos modulos no exponen wrappers
# Start-*Process; envolverlos en jobs seria logica nueva, fuera de scope #11.
function Invoke-ActionCoreIsolation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    $st = Get-CoreIsolationStatus
    Write-Host '  CORE ISOLATION / MEMORY INTEGRITY (HVCI)' -ForegroundColor DarkCyan
    Write-Host ('  VBS  : configurado={0}  corriendo={1}' -f $st.VbsConfigured, $st.VbsRunning)
    Write-Host ('  HVCI : configurado={0}  corriendo={1}  (Memory Integrity)' -f $st.HvciConfigured, $st.HvciRunning)
    Write-Host ('  Hypervisor presente: {0}  (WSL2/Hyper-V dependen de esto, NO de HVCI)' -f $st.HypervisorPresent) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [D]eshabilitar HVCI (preserva VBS -> WSL2/Hyper-V intactos)  /  [E]nable HVCI+VBS  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()

    if ($sub -eq 'D') {
        [string] $vbsAns = (Read-Host '  Tambien deshabilitar VBS? (rompe WSL2 si lo usas) [s/N]').Trim().ToUpperInvariant()
        [bool] $vbsToo = ($vbsAns -eq 'S' -or $vbsAns -eq 'SI' -or $vbsAns -eq 'Y' -or $vbsAns -eq 'YES')
        [string[]] $lines = @(
            'Registry: DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity Enabled=0',
            'Reinicio requerido para tomar efecto.'
        )
        if ($vbsToo) { $lines += 'TAMBIEN VBS=0: WSL2/Hyper-V se rompen si dependian de VBS.' }
        else         { $lines += 'VBS preservado: WSL2/Hyper-V siguen funcionando.' }
        if (-not (Confirm-Action -Title 'Deshabilitar HVCI (Memory Integrity)?' -Lines $lines -DefaultYes $false)) {
            Write-Host '  Cancelado.' -ForegroundColor DarkGray
            Write-ActionAudit -Action 'CoreIsolation' -Status 'Cancelled'
            return
        }
        Write-ActionAudit -Action 'CoreIsolation' -Status 'Started' -Summary ('Disable HVCI VbsToo={0}' -f $vbsToo)
        Write-Host '  Deshabilitando HVCI...' -ForegroundColor Cyan
        if ($vbsToo) { $r = Disable-Hvci -DisableVbsToo } else { $r = Disable-Hvci }
        Show-OrphanModuleResult -Action 'CoreIsolation' -Result $r
        return
    }
    if ($sub -eq 'E') {
        if (-not (Confirm-Action -Title 'Re-habilitar HVCI + VBS (Memory Integrity)?' -Lines @(
            'Registry: HypervisorEnforcedCodeIntegrity Enabled=1 + EnableVirtualizationBasedSecurity=1',
            'Reinicio requerido. Memory Integrity activo tras el reboot.'
        ))) {
            Write-Host '  Cancelado.' -ForegroundColor DarkGray
            Write-ActionAudit -Action 'CoreIsolation' -Status 'Cancelled'
            return
        }
        Write-ActionAudit -Action 'CoreIsolation' -Status 'Started' -Summary 'Enable HVCI+VBS'
        Write-Host '  Habilitando HVCI + VBS...' -ForegroundColor Cyan
        $r = Enable-Hvci
        Show-OrphanModuleResult -Action 'CoreIsolation' -Result $r
        return
    }
    Write-Host '  Cancelado.' -ForegroundColor DarkGray
}

function Invoke-ActionHags {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    $st = Get-HagsStatus
    [string] $rawTxt = if ($null -ne $st.RawValue) { [string]$st.RawValue } else { '(sin valor)' }
    Write-Host '  HAGS - HARDWARE-ACCELERATED GPU SCHEDULING' -ForegroundColor DarkCyan
    Write-Host ('  Estado actual: {0}  (HwSchMode={1})' -f $st.Mode, $rawTxt)
    Write-Host '  Trade-off: HAGS reserva ~1GB VRAM. Off recomendado en GPUs <8GB sin DLSS Frame Gen;' -ForegroundColor DarkGray
    Write-Host '             On requerido para DLSS Frame Generation (RTX 40+).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [E]nable (HwSchMode=2)  /  [D]eshabilitar (=1)  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -ne 'E' -and $sub -ne 'D') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; return }

    [bool] $enable = ($sub -eq 'E')
    [string] $title = if ($enable) { 'Habilitar HAGS (HwSchMode=2)?' } else { 'Deshabilitar HAGS (HwSchMode=1)?' }
    if (-not (Confirm-Action -Title $title -Lines @(
        'Registry: GraphicsDrivers\HwSchMode (1=Off, 2=On)',
        'Reinicio requerido para tomar efecto.'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'Hags' -Status 'Cancelled'
        return
    }
    [string] $verb = if ($enable) { 'Enable' } else { 'Disable' }
    Write-ActionAudit -Action 'Hags' -Status 'Started' -Summary $verb
    Write-Host '  Aplicando HAGS...' -ForegroundColor Cyan
    if ($enable) { $r = Enable-Hags } else { $r = Disable-Hags }
    Show-OrphanModuleResult -Action 'Hags' -Result $r
}

function Invoke-ActionTimerResolution {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    $st = Get-TimerResolutionStatus
    Write-Host '  TIMER RESOLUTION GLOBAL (solo Win11)' -ForegroundColor DarkCyan
    Write-Host ('  Estado actual: Enabled={0}  (build Windows={1})' -f $st.Enabled, $st.WinBuild)
    if (-not $st.GateWin11) {
        Write-Host ('  [SKIP] Solo Win11 (build >= 22000). En esta PC (build {0}) GlobalTimerResolutionRequests' -f $st.WinBuild) -ForegroundColor DarkYellow
        Write-Host '         no tiene efecto documentado. No se aplica nada.' -ForegroundColor DarkYellow
        Write-ActionAudit -Action 'TimerResolution' -Status 'Skipped' -Summary ('build {0} sin gate Win11' -f $st.WinBuild)
        return
    }
    Write-Host '  Cost-zero: solo registry, sin proceso residente. Reinicio para efecto pleno.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [O]n  /  [F] off  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -ne 'O' -and $sub -ne 'F') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; return }

    [string] $state = if ($sub -eq 'O') { 'on' } else { 'off' }
    if (-not (Confirm-Action -Title ('Timer Resolution global = {0}?' -f $state) -Lines @(
        'Registry: Session Manager\kernel\GlobalTimerResolutionRequests',
        'Reinicio requerido para efecto pleno. Cost-zero (sin proceso residente).'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'TimerResolution' -Status 'Cancelled'
        return
    }
    Write-ActionAudit -Action 'TimerResolution' -Status 'Started' -Summary $state
    Write-Host '  Aplicando Timer Resolution...' -ForegroundColor Cyan
    $r = Set-TimerResolutionRegistry -State $state
    Show-OrphanModuleResult -Action 'TimerResolution' -Result $r
}

function Invoke-ActionProcessPriority {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    $current = Get-ProcessPriorityIFEO
    Write-Host '  PRIORIDAD DE PROCESO POR .EXE (IFEO)' -ForegroundColor DarkCyan
    Write-Host '  AVISO: prioridad estatica via registry IFEO. NO es Process Lasso,' -ForegroundColor DarkGray
    Write-Host '         sin ProBalance dinamico, sin proceso residente (cost-zero).' -ForegroundColor DarkGray
    Write-Host ''
    if ($current.Count -gt 0) {
        Write-Host '  Entradas actuales:'
        foreach ($k in ($current.Keys | Sort-Object)) {
            Write-Host ('    {0,-28} {1}' -f $k, $current[$k])
        }
    } else {
        Write-Host '  (sin entradas IFEO de prioridad configuradas)' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  [A]gregar/cambiar prioridad de un .exe  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -ne 'A') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; return }

    [string] $exe = (Read-Host '  Nombre del ejecutable (ej. valorant.exe)').Trim()
    if ([string]::IsNullOrWhiteSpace($exe)) { Write-Host '  Nombre vacio, cancelado.' -ForegroundColor DarkGray; return }
    if ($exe -notmatch '(?i)\.exe$')        { Write-Host '  Debe terminar en .exe, cancelado.' -ForegroundColor Yellow; return }

    Write-Host '  Clase: [H]igh (maximo seguro)  /  [A]boveNormal  /  [N]ormal (default; resetea)'
    [string] $clsSub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    [string] $cls = switch ($clsSub) { 'H' { 'High' } 'A' { 'AboveNormal' } 'N' { 'Normal' } default { '' } }
    if ([string]::IsNullOrWhiteSpace($cls)) { Write-Host '  Clase invalida, cancelado.' -ForegroundColor DarkGray; return }

    if (-not (Confirm-Action -Title ('Setear prioridad IFEO {0} -> {1}?' -f $exe, $cls) -Lines @(
        'Registry: Image File Execution Options\<exe>\PerfOptions\CpuPriorityClass',
        'Prioridad estatica: Windows la aplica al arrancar el proceso. Sin reinicio.',
        'NO es Process Lasso / sin ProBalance dinamico.'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'ProcessPriority' -Status 'Cancelled'
        return
    }
    Write-ActionAudit -Action 'ProcessPriority' -Status 'Started' -Summary ('{0}={1}' -f $exe, $cls)
    Write-Host '  Aplicando prioridad IFEO...' -ForegroundColor Cyan
    [hashtable] $map = @{}
    $map[$exe] = $cls
    $r = Set-ProcessPriorityIFEO -PriorityMap $map
    Show-OrphanModuleResult -Action 'ProcessPriority' -Result $r
}

function Invoke-ActionUsbPower {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    $st = Get-UsbSelectiveSuspendStatus
    [string] $acTxt  = if ($null -ne $st.AcValueIndex)           { [string]$st.AcValueIndex }           else { '-' }
    [string] $dcTxt  = if ($null -ne $st.DcValueIndex)           { [string]$st.DcValueIndex }           else { '-' }
    [string] $regTxt = if ($null -ne $st.RegistryGlobalDisabled) { [string]$st.RegistryGlobalDisabled } else { '(sin valor)' }
    Write-Host '  USB SELECTIVE SUSPEND' -ForegroundColor DarkCyan
    Write-Host ('  Plan activo: AC={0}  DC={1}   (0=disabled, 1=enabled, - =oculto)' -f $acTxt, $dcTxt)
    Write-Host ('  Registry global DisableSelectiveSuspend: {0}' -f $regTxt) -ForegroundColor DarkGray
    if ($st.IsHiddenInGui) { Write-Host '  (El setting esta oculto en Power Options; Win11 24H2 lo oculta por default)' -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  [D]eshabilitar (off - dongles 2.4GHz/HID/latencia)  /  [E]nable (default Windows)  /  [B]volver'
    [string] $sub = (Read-Host '  Opcion').Trim().ToUpperInvariant()
    if ($sub -ne 'D' -and $sub -ne 'E') { Write-Host '  Cancelado.' -ForegroundColor DarkGray; return }

    [bool] $disable = ($sub -eq 'D')
    [string] $title = if ($disable) { 'Deshabilitar USB Selective Suspend?' } else { 'Re-habilitar USB Selective Suspend (default Windows)?' }
    if (-not (Confirm-Action -Title $title -Lines @(
        'powercfg: AC + DC value index del setting USB Selective Suspend',
        'Registry: Services\USB\DisableSelectiveSuspend',
        'Sin reinicio. Win11 24H2 oculta el setting; el modulo lo des-oculta para tocarlo.'
    ))) {
        Write-Host '  Cancelado.' -ForegroundColor DarkGray
        Write-ActionAudit -Action 'UsbPower' -Status 'Cancelled'
        return
    }
    [string] $verb = if ($disable) { 'Disable' } else { 'Enable' }
    Write-ActionAudit -Action 'UsbPower' -Status 'Started' -Summary $verb
    Write-Host '  Aplicando USB Selective Suspend...' -ForegroundColor Cyan
    if ($disable) { $r = Disable-UsbSelectiveSuspend } else { $r = Enable-UsbSelectiveSuspend }
    Show-OrphanModuleResult -Action 'UsbPower' -Result $r
}

# ─── Invoke-ApplyAutoProfile (handler [1] del menu principal) ────────────────
function Invoke-ApplyAutoProfile {
    <#
    .SYNOPSIS
        Handler del menu principal [1]. Muestra selector de use-case, carga la receta
        segun el tier detectado, pide confirmacion y ejecuta Invoke-AutoProfile.
        Separacion UI/orquestacion: este handler NO hace las mutaciones — se las delega
        al engine (ProfileEngine.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [string] $detectedTier = 'Mid'
    [object] $tierProp = $MachineProfile.PSObject.Properties['Tier']
    if ($null -ne $tierProp) { $detectedTier = [string]$tierProp.Value }

    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '    APLICAR PERFIL AUTOMATICO' -ForegroundColor Cyan
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host ("  Tier detectado: {0}" -f $detectedTier) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  [1]  Generic         (PC de servicio sin contexto claro)'
    Write-Host '  [2]  Work            (oficina/estudio: Office/Outlook/Teams, browser, impresion)'
    Write-Host '  [3]  Multimedia      (streaming: series/deportes/peliculas, Game Pass casual)'
    Write-Host '  [B]  Volver'
    Write-Host ''
    [string] $ucChoice = (Read-Host '  Selecciona').Trim().ToUpperInvariant()

    [string] $useCase = ''
    switch ($ucChoice) {
        'B'     { return }
        '1'     { $useCase = 'generic' }
        '2'     { $useCase = 'work' }
        '3'     { $useCase = 'multimedia' }
        default { Write-Host '  Opcion invalida.' -ForegroundColor Red; return }
    }

    # ── Cargar receta para el use-case (v2.0: sin tier en el path) ────────────
    [string] $profPath = Get-AutoProfilePath -UseCase $useCase

    [string] $auditAction = ('Profile.Apply.' + (([string]$useCase).Substring(0,1).ToUpperInvariant() + ([string]$useCase).Substring(1)))

    [PSCustomObject] $profile = $null
    try {
        $profile = Import-AutoProfile -Path $profPath
    } catch {
        Write-Host ("  [!] No se pudo cargar la receta: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-ActionAudit -Action $auditAction -Status 'Failed' -Summary $_.Exception.Message
        return
    }

    # ── Preview + Confirm ─────────────────────────────────────────────────────
    [string[]] $previewLines = Get-AutoProfilePreviewLines -Profile $profile -MachineProfile $MachineProfile
    [string] $useCaseLabel = ([string]$useCase).Substring(0,1).ToUpperInvariant() + ([string]$useCase).Substring(1)
    if (-not (Confirm-Action -Title ('Aplicar perfil {0} ({1})?' -f $useCaseLabel, $detectedTier) -Lines $previewLines)) {
        Write-ActionAudit -Action $auditAction -Status 'Cancelled'
        return
    }

    # ── Identificador de cliente ──────────────────────────────────────────────
    Write-Host ''
    [string] $rawSlug = (Read-Host '  Identificador del cliente (ej. juan-perez, Enter para autogenerar)').Trim()
    [string] $clientSlug = ''
    if ([string]::IsNullOrWhiteSpace($rawSlug)) {
        $clientSlug = 'cliente-' + $env:COMPUTERNAME.ToLowerInvariant()
    } else {
        $clientSlug = $rawSlug.ToLowerInvariant()
        $clientSlug = $clientSlug -replace '\s+', '-'
        $clientSlug = $clientSlug -replace '[^a-z0-9-]', ''
        $clientSlug = ($clientSlug -replace '-{2,}', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($clientSlug)) {
            $clientSlug = 'cliente-' + $env:COMPUTERNAME.ToLowerInvariant()
        }
    }
    Write-Host ("  Cliente: {0}" -f $clientSlug) -ForegroundColor DarkGray

    # ── Gate Restore Point ────────────────────────────────────────────────────
    [bool] $createRp = Confirm-Action `
        -Title 'Crear Restore Point automaticamente?' `
        -Lines @(
            'Crea un punto de restauracion de Windows antes de aplicar la receta.',
            'Permite revertir los cambios con System Restore si algo sale mal.',
            'Recomendado para la mayoria de los servicios.'
        ) `
        -DefaultYes:$true

    # ── Ejecutar pipeline ─────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Iniciando pipeline...' -ForegroundColor Cyan
    $result = Invoke-AutoProfile `
        -Profile       $profile `
        -MachineProfile $MachineProfile `
        -ClientSlug    $clientSlug `
        -SkipRestorePoint:(-not $createRp) `
        -ShowProgress

    # ── Mostrar resumen final ─────────────────────────────────────────────────
    Write-Host ''
    [string] $statusColor = switch ($result.Status) {
        'Success' { 'Green'  }
        'Partial' { 'Yellow' }
        default   { 'Red'    }
    }
    Write-Host ('  === Resultado: {0} | Duracion: {1}s ===' -f $result.Status, $result.DurationSec) -ForegroundColor $statusColor

    [object] $crDir = $result.ClientRun.PSObject.Properties['Dir']
    if ($null -ne $crDir -and -not [string]::IsNullOrWhiteSpace([string]$crDir.Value)) {
        Write-Host ('  Carpeta de run: {0}' -f [string]$crDir.Value) -ForegroundColor Cyan
    }
}

# ─── Invoke-NamedProfileMenu (handler [2] — receta nombrada / gaming) ─────────
function Invoke-NamedProfileMenu {
    <#
    .SYNOPSIS
        Submenu de recetas nombradas (Stage 4): Nueva / Cargar / Reaplicar
        ultima. Reusa Confirm-Action, prompt de cliente y gate RP (mismo patron
        que Invoke-ApplyAutoProfile). Invoke-NamedProfile escribe la entrada de
        audit consolidada; aca solo se auditan Cancelled/Failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    function script:_Np_ClientSlug {
        [string] $raw = (Read-Host '  Identificador del cliente (Enter para autogenerar)').Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'cliente-' + $env:COMPUTERNAME.ToLowerInvariant() }
        [string] $s = $raw.ToLowerInvariant()
        $s = $s -replace '\s+', '-'
        $s = $s -replace '[^a-z0-9-]', ''
        $s = ($s -replace '-{2,}', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($s)) { return 'cliente-' + $env:COMPUTERNAME.ToLowerInvariant() }
        return $s
    }
    function script:_Np_RpGate {
        return (Confirm-Action -Title 'Crear Restore Point automaticamente?' -Lines @(
            'Crea un punto de restauracion antes de aplicar la receta.',
            'Permite revertir con System Restore si algo sale mal.',
            'Recomendado.') -DefaultYes:$true)
    }
    function script:_Np_ShowResult($r) {
        [string] $st = if ($null -ne $r -and $r.PSObject.Properties['NamedStatus']) { [string]$r.NamedStatus }
                       elseif ($null -ne $r -and $r.PSObject.Properties['Status']) { [string]$r.Status }
                       else { 'Unknown' }
        [string] $clr = switch ($st) { 'Success' { 'Green' } 'Partial' { 'Yellow' } default { 'Red' } }
        Write-Host ''
        Write-Host ('  === Resultado receta nombrada: {0} ===' -f $st) -ForegroundColor $clr
        if ($null -ne $r -and $r.PSObject.Properties['RebootNeeded'] -and [bool]$r.RebootNeeded) {
            Write-Host '  [i] Requiere REINICIO para efecto pleno (HVCI/HAGS).' -ForegroundColor Yellow
        }
        if ($null -ne $r -and $r.PSObject.Properties['ClientRun'] -and $null -ne $r.ClientRun) {
            [object] $d = $r.ClientRun.PSObject.Properties['Dir']
            if ($null -ne $d -and -not [string]::IsNullOrWhiteSpace([string]$d.Value)) {
                Write-Host ('  Carpeta de run: {0}' -f [string]$d.Value) -ForegroundColor Cyan
            }
        }
    }

    $script:PctkBannerProfile = $MachineProfile   # ver nota en Show-MainMenu (no GetNewClosure)
    [scriptblock] $npRenderHeader = { Clear-Host; Show-MachineBanner -MachineProfile $script:PctkBannerProfile }
    [string] $c = Read-PctkMenuChoice -Rows (Get-NamedProfileRows) -RenderHeader $npRenderHeader

    if ($c -eq 'B') { return }

    if ($c -eq '1') {
        [bool] $useGamingPreset = [bool] (Confirm-Action -Title 'Usar preset gaming HW-smart? (pre-llena los toggles segun tu hardware; podes sobreescribir cada uno)' -DefaultYes:$true)
        [PSCustomObject] $prof = New-NamedProfileInteractive -MachineProfile $MachineProfile -UseGamingPreset:$useGamingPreset
        [string[]] $lines = Get-NamedProfilePreviewLines -Profile $prof -MachineProfile $MachineProfile
        if (-not (Confirm-Action -Title ("Guardar receta '{0}'?" -f [string]$prof._name) -Lines $lines)) {
            Write-ActionAudit -Action 'Profile.Apply.Named' -Status 'Cancelled'
            return
        }
        [string] $slug = (Read-Host '  Nombre de archivo (slug, ej. pc-carlos-cs2)').Trim()
        [string] $path = Save-NamedProfile -Profile $prof -Slug $slug
        Write-Host ('  [OK] Guardada: {0}' -f $path) -ForegroundColor Green
        if (Confirm-Action -Title 'Aplicar la receta ahora?' -DefaultYes:$true) {
            [string] $cs = _Np_ClientSlug
            [bool]   $rp = _Np_RpGate
            Write-Host ''
            Write-Host '  Iniciando pipeline (core + gaming_tweaks)...' -ForegroundColor Cyan
            $r = Invoke-NamedProfile -Profile $prof -MachineProfile $MachineProfile `
                -ClientSlug $cs -SourcePath $path -SkipRestorePoint:(-not $rp) -ShowProgress
            _Np_ShowResult $r
        }
        return
    }

    if ($c -eq '2' -or $c -eq '3') {
        [object[]] $list = @(Get-NamedProfileList)
        if ($c -eq '3') { $list = @($list | Where-Object { -not $_.IsSample }) }
        if ($list.Count -eq 0) {
            Write-Host '  No hay recetas nombradas guardadas.' -ForegroundColor Yellow
            return
        }

        [PSCustomObject] $sel = $null
        if ($c -eq '3') {
            # Reaplicar ultima: la de _last_applied mas reciente; si ninguna se
            # aplico, la de archivo mas nuevo.
            [object[]] $applied = @($list | Where-Object { $null -ne $_.LastApplied -and -not [string]::IsNullOrWhiteSpace([string]$_.LastApplied) })
            if ($applied.Count -gt 0) {
                $sel = ($applied | Sort-Object { [string]$_.LastApplied } -Descending | Select-Object -First 1)
            } else {
                $sel = ($list | Sort-Object { (Get-Item -LiteralPath $_.Path).LastWriteTime } -Descending | Select-Object -First 1)
            }
            Write-Host ('  Ultima receta: {0}  (last_applied: {1})' -f $sel.Name, $(if ($sel.LastApplied) { $sel.LastApplied } else { 'nunca' })) -ForegroundColor Cyan
        } else {
            Write-Host ''
            for ($i = 0; $i -lt $list.Count; $i++) {
                [string] $tag = if ($list[$i].IsSample) { '  [fixture]' } else { '' }
                Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $list[$i].Name, $tag)
            }
            Write-Host ''
            [string] $pick = (Read-Host '  Numero de receta').Trim()
            [int] $idx = 0
            if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $list.Count) {
                Write-Host '  Seleccion invalida.' -ForegroundColor Red
                return
            }
            $sel = $list[$idx - 1]
        }

        [PSCustomObject] $prof = $null
        try {
            $prof = Import-NamedProfile -Path $sel.Path
        } catch {
            Write-Host ('  [!] No se pudo cargar: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-ActionAudit -Action 'Profile.Apply.Named' -Status 'Failed' -Summary $_.Exception.Message
            return
        }

        [string[]] $lines = Get-NamedProfilePreviewLines -Profile $prof -MachineProfile $MachineProfile
        if (-not (Confirm-Action -Title ("Aplicar receta '{0}'?" -f [string]$prof._name) -Lines $lines)) {
            Write-ActionAudit -Action 'Profile.Apply.Named' -Status 'Cancelled'
            return
        }

        [string] $cs = _Np_ClientSlug
        Write-Host ''
        Write-Host '  Iniciando pipeline (core + gaming_tweaks)...' -ForegroundColor Cyan
        if ($c -eq '3') {
            # Reaplicar = headless (prereq #3): -Unattended evita que la falla
            # dura de RP cuelgue. RP igual se intenta (no -SkipRestorePoint).
            $r = Invoke-NamedProfile -Profile $prof -MachineProfile $MachineProfile `
                -ClientSlug $cs -SourcePath $sel.Path -Unattended
        } else {
            [bool] $rp = _Np_RpGate
            $r = Invoke-NamedProfile -Profile $prof -MachineProfile $MachineProfile `
                -ClientSlug $cs -SourcePath $sel.Path -SkipRestorePoint:(-not $rp) -ShowProgress
        }
        _Np_ShowResult $r
        return
    }

    Write-Host '  Opcion invalida.' -ForegroundColor Red
}
