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

    # #28: modelo y Service Tag a la vista. El perfil ya los traia (salen de las
    # mismas queries CIM que se hacian igual) pero no se mostraban en ningun lado:
    # con el modelo entras al soporte del fabricante a buscar drivers y despiece,
    # y con el Service Tag a la garantia y a la config con la que salio de fabrica.
    # Antes habia que sacarlos con wmic a mano en cada visita (caso Olivo).
    [string] $model = ''
    if ($MachineProfile.PSObject.Properties['Model']) {
        $model = Get-OemDisplayValue -Value ([string]$MachineProfile.Model) -Fallback ''
    }

    # #28 (remate): "82K2" no le dice nada a nadie. Con SystemFamily / el tramo
    # _FM_ del SKU el banner muestra el nombre comercial, y el codigo queda
    # entre parentesis porque ES lo que se tipea en el soporte del fabricante
    # para sacar el despiece. Un perfil viejo (sin estos campos) cae al Model de
    # siempre: se preguntan por PSObject.Properties, no se leen directo.
    [string] $family = ''
    [string] $sku    = ''
    if ($MachineProfile.PSObject.Properties['Family'])    { $family = [string] $MachineProfile.Family }
    if ($MachineProfile.PSObject.Properties['SystemSku']) { $sku    = [string] $MachineProfile.SystemSku }

    [string] $modelDisplay = Get-ModelDisplayName -Model $model -Family $family -Sku $sku

    [string] $modelLabel = $modelDisplay
    if (-not [string]::IsNullOrWhiteSpace($modelDisplay) -and
        -not [string]::IsNullOrWhiteSpace($model) -and
        $modelDisplay -ne $model) {
        $modelLabel = ('{0} ({1})' -f $modelDisplay, $model)
    }

    [string] $oemLabel = if ([string]::IsNullOrWhiteSpace($modelLabel)) { $manufacturer } else { ('{0} {1}' -f $manufacturer, $modelLabel) }

    [string] $serialLabel = 'N/A'
    if ($MachineProfile.PSObject.Properties['SerialNumber']) {
        $serialLabel = Get-OemDisplayValue -Value ([string]$MachineProfile.SerialNumber) -Fallback 'N/A'
    }

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
    $rows += [PSCustomObject]@{ Label = 'OEM'; Value = ('{0}{1}' -f $oemLabel, $oemSuffix) }
    $rows += [PSCustomObject]@{ Label = 'S/N'; Value = $serialLabel }

    # Indicador "ultimo PRE" (D2 recolector-plan): siempre visible en el banner.
    # Permite saber de un vistazo si ya se tomo el PRE en esta visita.
    # Get-ServiceState nunca tira (devuelve $null si no hay state o está roto).
    [string] $preLabel = 'sin PRE'
    if (Get-Command -Name 'Get-ServiceState' -CommandType Function -ErrorAction SilentlyContinue) {
        $svcState = Get-ServiceState
        if ($null -ne $svcState -and $null -ne $svcState.PSObject.Properties['pre_taken_at'] -and
            -not [string]::IsNullOrEmpty([string]$svcState.pre_taken_at) -and
            [string]$svcState.pre_taken_at -ne 'null') {
            # Mostrar solo fecha+hora (sin timezone) para que quepa en el banner
            [string] $rawPre = [string]$svcState.pre_taken_at
            # Formato ISO: "2026-06-14T10:05:00-03:00" -> tomar solo los primeros 16 chars
            [string] $preLabel = if ($rawPre.Length -ge 16) { $rawPre.Substring(0, 16).Replace('T', ' ') } else { $rawPre }
        }
    }
    $rows += [PSCustomObject]@{ Label = 'PRE'; Value = $preLabel }

    [string] $vmLine = ''
    if ($MachineProfile.PSObject.Properties['IsVirtualMachine'] -and [bool]$MachineProfile.IsVirtualMachine) {
        [string] $vmVendorLabel = if ($MachineProfile.PSObject.Properties['VmVendor'] -and -not [string]::IsNullOrWhiteSpace([string]$MachineProfile.VmVendor)) {
            [string]$MachineProfile.VmVendor
        } else { 'VM' }
        $vmLine = ('{0}  [modo VM - SMART/PnP/ACPI omitidos]' -f $vmVendorLabel)
    }

    Write-PctkMachineBanner -Rows $rows -Tier $tierLabel -VmLine $vmLine

    # #23b: avisos de HW (single-channel / XMP off / UMA chico). Cacheados en el
    # profile (cero costo por redibujo); solo aparecen cuando hay hallazgo.
    if ($MachineProfile.PSObject.Properties['Advisories']) {
        foreach ($adv in @($MachineProfile.Advisories)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$adv)) {
                Write-PctkWarn ('  [HW] {0}' -f [string]$adv)
            }
        }
    }
}

# ─── Invoke-ServiceClose ([L]) ────────────────────────────────────────────────
function Invoke-ServiceClose {
    <#
    .SYNOPSIS
        Handler del [L]: cierra el service (POST automatico + bundle + cierra el
        estado) y despues ofrece dejar la PC limpia en el mismo movimiento.

        POR QUE la pregunta vive ACA y no adentro de Invoke-CloseService:
        Save-PreUninstallArtifacts (o sea, el [U]) llama a Invoke-CloseService
        para armar el paquete. Si la pregunta viviera ahi, el [U] preguntaria
        "desinstalar?" en medio de una desinstalacion -> recursion.

        Y POR QUE captura el resultado: Invoke-CloseService devuelve un objeto de
        datos. Llamarlo suelto en el dispatch lo imprimia crudo en la consola del
        cliente (misma clase de bug que el [A][19][V]).
    .OUTPUTS
        [bool] $true si se lanzo el desinstalador y PCTk tiene que cerrarse ya.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # ── Backlog #41: reintentar la subida SIN armar otro paquete ──────────────
    #
    # EL CASO REAL, medido en la notebook de Mateo el 2026-08-01: la subida no
    # salio (todavia no estaba el codigo de conexion pegado), y para reintentar
    # apreto el [L] de nuevo. Eso arma un paquete NUEVO -> dos ZIP a 41 segundos
    # uno del otro en el Escritorio del cliente. Y peor: la proteccion
    # anti-duplicados del CRM no puede ayudar, porque el identificador sale del
    # nombre del archivo y el archivo es otro.
    #
    # Asi que antes de empaquetar se mira si ya hay un paquete de ESTA PC sin
    # subir. Si lo hay, se ofrece subir ESE. Re-empaquetar sigue disponible
    # contestando que no: no se decide por el operador, se le muestra la opcion
    # barata primero.
    if ((Get-Command -Name 'Get-BundlePendienteDeSubir' -CommandType Function -ErrorAction SilentlyContinue) -and
        (Get-Command -Name 'Invoke-CrmUploadOffer' -CommandType Function -ErrorAction SilentlyContinue)) {

        $pendiente = Get-BundlePendienteDeSubir
        if ($null -ne $pendiente) {
            Write-Host ''
            Write-PctkWarn '  Hay un paquete de esta PC que todavia no subiste al CRM.'
            # #48: la EDAD a la vista, no solo el nombre del archivo (la fecha
            # embebida en MATEO-NOTEBOOK_20260801-... hay que decodificarla
            # leyendo, y asi se subio un paquete de hacia una semana creyendo
            # que era el de hoy).
            if (Get-Command -Name 'Get-BundlePendienteDescripcion' -CommandType Function -ErrorAction SilentlyContinue) {
                [string] $edadPend = Get-BundlePendienteDescripcion -ClosedAt ([string]$pendiente.ClosedAt)
                if (-not [string]::IsNullOrWhiteSpace($edadPend)) { Write-PctkWarn ('  {0}' -f $edadPend) }
            }
            Write-PctkHint ('  {0}' -f (Split-Path -Leaf ([string]$pendiente.ZipPath)))
            # Y decir que aceptar TERMINA ACA: subir el viejo no arma otro nuevo.
            Write-PctkHint '  Si lo subis, el cierre termina aca: NO se arma un paquete nuevo de hoy.'
            [string] $ansPend = (Read-Host '  Subir ESE en vez de armar otro? [S/n]').Trim().ToUpperInvariant()

            if ($ansPend -ne 'N') {
                $null = Invoke-CrmUploadOffer -ZipPath ([string]$pendiente.ZipPath)

                Write-Host ''
                Write-PctkHint '  Podes dejar la PC del cliente limpia ahora.'
                [string] $ansU = (Read-Host '  Dejar PCTk instalado en esta PC? [S/n]').Trim().ToUpperInvariant()
                if ($ansU -ne 'N') { return $false }
                return (Invoke-UninstallToolkit)
            }
        }
    }

    $result = $null
    if (Get-Command -Name 'Invoke-CloseService' -CommandType Function -ErrorAction SilentlyContinue) {
        $result = Invoke-CloseService
    } else {
        $result = Invoke-ExportClientLogs
    }

    [string] $status = if ($null -ne $result -and $null -ne $result.PSObject.Properties['Status']) {
        [string] $result.Status
    } else { '' }

    # Si el bundle no salio, el service queda ABIERTO para reintentar el [L].
    # Ofrecer desinstalar ahi seria ofrecer perder el service.
    if ($status -ne 'OK') { return $false }

    # Backlog #41: ofrecer subir el paquete al CRM antes de preguntar por la
    # desinstalacion. El orden importa -- si se preguntara despues, el operador
    # que dice "no dejes PCTk instalado" se llevaria la PC sin la chance de subir,
    # y la configuracion del CRM vive en output\state\, que el [U] borra.
    #
    # POR QUE ACA Y NO ADENTRO DE Invoke-CloseService: por lo mismo que la
    # pregunta de la desinstalacion (ver el SYNOPSIS). El [U] llama a
    # Invoke-CloseService para armar su paquete; si la subida viviera ahi,
    # preguntaria en medio de una desinstalacion.
    #
    # Todo lo que puede salir mal adentro es un aviso, nunca un throw: el ZIP ya
    # esta hecho y el cierre del service no se negocia por un problema de red.
    if (Get-Command -Name 'Invoke-CrmUploadOffer' -CommandType Function -ErrorAction SilentlyContinue) {
        [string] $zipPath = ''
        if ($null -ne $result -and $null -ne $result.PSObject.Properties['ZipPath']) {
            $zipPath = [string]$result.ZipPath
        }
        if (-not [string]::IsNullOrWhiteSpace($zipPath)) {
            $null = Invoke-CrmUploadOffer -ZipPath $zipPath
        }
    }

    Write-Host ''
    Write-PctkHint '  El paquete ya esta hecho. Podes dejar la PC del cliente limpia ahora.'
    [string] $ans = (Read-Host '  Dejar PCTk instalado en esta PC? [S/n]').Trim().ToUpperInvariant()
    if ($ans -ne 'N') { return $false }

    # El [U] NO re-empaqueta: el marcador que acaba de dejar el cierre se lo dice.
    return (Invoke-UninstallToolkit)
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
    [scriptblock] $renderHeader = {
        Clear-Host
        Show-MachineBanner -MachineProfile $script:PctkBannerProfile

        # Pieza B (recolector): evaluacion del estado del service al redibujar el menu.
        # Muestra UNA linea debajo del banner con el estado actual, sin bloquear el flujo.
        if (Get-Command -Name 'Get-ServiceState' -CommandType Function -ErrorAction SilentlyContinue) {
            $pctkSvcState = Get-ServiceState
            if ($null -eq $pctkSvcState) {
                # Sin state: recomendar tomar PRE antes de trabajar
                Write-PctkWarn '  Sin PRE para esta PC. Recomendado: tomar PRE [3] antes de trabajar.'
            } elseif (Get-Command -Name 'Test-ServiceStateStale' -CommandType Function -ErrorAction SilentlyContinue) {
                if (Test-ServiceStateStale) {
                    # State de otra PC: cerrar el stale y avisar
                    Write-PctkWarn '  Service de otra PC detectado; se cierra para empezar limpio. Recomendado PRE nuevo [3].'
                    if (Get-Command -Name 'Close-ServiceState' -CommandType Function -ErrorAction SilentlyContinue) {
                        try { Close-ServiceState -WriteClosedLog $false } catch { }
                    }
                } else {
                    # Service abierto para esta PC: mostrar desde cuando
                    [string] $pctkOpenedAt = if ($null -ne $pctkSvcState.PSObject.Properties['opened_at']) {
                        $pctkSvcState.opened_at
                    } else { '?' }
                    [string] $pctkPreAt = if ($null -ne $pctkSvcState.PSObject.Properties['pre_taken_at'] -and
                                                -not [string]::IsNullOrEmpty([string]$pctkSvcState.pre_taken_at) -and
                                                [string]$pctkSvcState.pre_taken_at -ne 'null') {
                        [string]$pctkSvcState.pre_taken_at
                    } else { 'sin PRE' }
                    Write-PctkHint ('  Service en curso desde {0}  (PRE: {1}).' -f $pctkOpenedAt, $pctkPreAt)
                }
            }
        }
    }

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

        # El [L] se maneja aca (no en el dispatch) por la misma razon que el [U]:
        # puede terminar en desinstalacion, y ahi PCTk tiene que CERRARSE para que
        # el deleter pueda borrar la instalacion (espera al PID, max 30s).
        if ($choice -eq 'L') {
            [bool] $okClose = Invoke-ServiceClose
            if ($okClose) { return 'U' }
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
        '8' { Invoke-ClientReport -MachineProfile $MachineProfile; return }
        'I' { Invoke-RawAuditReport -MachineProfile $MachineProfile; return }
        'R' { Invoke-ResearchPrompt -MachineProfile $MachineProfile; return }
        'A' {
            Show-IndividualActionsSubmenu -MachineProfile $MachineProfile
            return
        }
        'L' {
            # Pieza C (recolector): [L] = Cerrar service. Incluye POST auto + meta.json.
            # El camino real pasa por Show-MainMenu, que intercepta la 'L' antes de
            # llegar aca porque necesita poder SALIR si el operador desinstala.
            # Este caso queda como red por si alguien despacha 'L' directo.
            # El $null = es obligatorio: sin el, el objeto de resultado se imprime
            # crudo en la consola del cliente.
            $null = Invoke-ServiceClose
            return
        }
        'T' { Show-ToolsMenu -MachineProfile $MachineProfile; return }
        'U' {
            $null = Invoke-UninstallToolkit
            return
        }
        'X' {
            Write-PctkWork '  Saliendo de PCTk v2...'
            return
        }
        default {
            Write-PctkErr '  Opcion invalida.'
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
    Write-PctkWork ('  Capturando snapshot {0}-service...' -f $Phase)
    $job = Start-TelemetryJob -Phase $Phase
    $results = Invoke-JobWithProgress -Jobs @($job) -Activity ('Snapshot {0}' -f $Phase) -TimeoutSeconds 120
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        $r = $results[0]
        Write-PctkOk ('  [OK] Snapshot guardado: {0}' -f $r.FileName)
        Write-PctkHint ('       {0}' -f $r.FilePath)
        Write-ActionAudit -Action $action -Status 'Success' -Summary $r.FileName -Details $r

        # Pieza B (recolector): al tomar el PRE, abrir el service y sellar pre_taken_at.
        # Esto registra el inicio del service para el flujo [L] Cerrar service.
        # Get-ServiceState/Open-ServiceState nunca tiran (defensivas).
        if ($Phase -eq 'Pre' -and
            (Get-Command -Name 'Open-ServiceState' -CommandType Function -ErrorAction SilentlyContinue)) {
            try {
                $null = Open-ServiceState
                $null = Set-ServiceStatePreTaken
            } catch {
                # El service no es critico: si falla el registro, el snapshot ya se guardo
                Write-PctkHint ('  [i] Service state no actualizado: {0}' -f $_.Exception.Message)
            }
        }
    } else {
        Write-PctkWarn '  [!] No se obtuvo resultado del snapshot.'
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
        Write-PctkWarn ('  [!] {0}' -f $_.Exception.Message)
        Write-ActionAudit -Action 'Snapshot.Compare' -Status 'Failed' -Summary $_.Exception.Message
    }
}

function Invoke-DiagnosticBsod {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Started'
    Write-PctkWork '  Analizando Event Log (ultimos 90 dias)...'
    $job = Start-BsodHistoryJob -Days 90
    $results = Invoke-JobWithProgress -Jobs @($job) -Activity 'Historial BSOD' -TimeoutSeconds 120
    if ($null -ne $results -and $results.Count -gt 0 -and $null -ne $results[0]) {
        $bsodData = $results[0]
        Show-BsodHistory -Data $bsodData

        # PERSISTIR el detalle (2026-07-25). Antes solo se pintaba en consola y el
        # audit guardaba un resumen de UNA linea sin -Details: al cerrar la consola
        # se perdian los stop codes y los nombres de los minidumps, y habia que
        # re-sacarlos a mano con Get-WinEvent (paso con Olivo). El handler de disco
        # ya pasaba -Details; esto lo empareja.
        [int] $bsodN  = if ($bsodData.PSObject.Properties['BsodCount'])  { [int] $bsodData.BsodCount }  else { -1 }
        [int] $powerN = if ($bsodData.PSObject.Properties['PowerCount']) { [int] $bsodData.PowerCount } else { -1 }
        [string] $sum = 'BSOD={0} Apagones={1} TotalEventos={2} en {3} dias' -f `
            $bsodN, $powerN, $bsodData.TotalCrashes, $bsodData.DaysScanned
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Success' -Summary $sum -Details $bsodData
    } else {
        Write-PctkWarn '  [!] No se pudo leer el Event Log.'
        Write-ActionAudit -Action 'Diagnostics.BsodHistory' -Status 'Failed' -Summary 'No result'
    }
}

function Invoke-RawAuditReport {
    <#
    .SYNOPSIS
        Menu [I]: informe tecnico legible del equipo (.txt).

        POR QUE EXISTE ESTE HANDLER: `New-RawAuditReport` (modules\RawAudit.ps1)
        estaba escrito, funcionando y COMPLETAMENTE HUERFANO -- ni menu, ni caller,
        ni test. 230 lineas que vuelcan CPU/RAM/discos/termica/USB/programas/Steam
        a un .txt legible, apagadas. Cableado el 2026-07-25 tras el mapa del codigo.

        Se diferencia del [8]: el [8] es el reporte para EL CLIENTE (HTML, 3 paneles
        honestos, imprimible). Este es para EL TECNICO: crudo, completo, sin maquillar.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-ActionAudit -Action 'Report.RawAudit' -Status 'Started'
    Write-PctkWork '  Generando informe tecnico (toma ~30-60s, escanea el equipo)...'

    try {
        $r = New-RawAuditReport -OpenAfter
        if ($null -ne $r -and $r.Success) {
            Write-PctkOk  ('  [OK] Informe generado: {0}' -f $r.FileName)
            Write-PctkHint ('       {0}  ({1} KB)' -f $r.FilePath, [math]::Round($r.FileSize / 1KB, 1))
            Write-ActionAudit -Action 'Report.RawAudit' -Status 'Success' -Summary $r.FilePath
        } else {
            Write-PctkWarn '  [!] No se pudo generar el informe.'
            Write-ActionAudit -Action 'Report.RawAudit' -Status 'Failed' -Summary 'Sin resultado'
        }
    } catch {
        Write-PctkWarn ('  [!] Error al generar el informe: {0}' -f $_.Exception.Message)
        Write-ActionAudit -Action 'Report.RawAudit' -Status 'Failed' -Summary $_.Exception.Message
    }
}

function Invoke-DiagnosticDiskHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile
    Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Started'
    Write-PctkWork '  Leyendo salud de discos (SMART / wear)...'
    try {
        $data = Get-DiskHealth
        Show-DiskHealth -Data $data
        Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Success' -Summary ('{0} discos, {1} alertas' -f @($data.Disks).Count, $data.AlertCount) -Details $data
    }
    catch {
        Write-PctkWarn ('  [!] {0}' -f $_.Exception.Message)
        Write-ActionAudit -Action 'Diagnostics.DiskHealth' -Status 'Failed' -Summary $_.Exception.Message
    }
}

# ─── Reporte cliente handler (menu [8]) ──────────────────────────────────────

function Invoke-ClientReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    $null = $MachineProfile

    Write-ActionAudit -Action 'Report.Client' -Status 'Started'
    Write-PctkWork '  Preparando reporte para el cliente...'

    # Directorio de salida
    [string] $reportsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\reports'
    if (-not (Test-Path -LiteralPath $reportsDir)) {
        $null = New-Item -ItemType Directory -Path $reportsDir -Force
    }
    [string] $stamp    = (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    [string] $outPath  = Join-Path $reportsDir ('reporte-cliente_{0}.html' -f $stamp)

    # Intentar Compare desde ultimos PRE/POST
    [PSCustomObject] $compareResult = $null
    try {
        $compareResult = Compare-Snapshot
    } catch {
        Write-PctkHint ('  [i] Compare no disponible: {0}' -f $_.Exception.Message)
    }

    # Leer el snapshot mas reciente para la ficha del equipo.
    # #29/#30: se prefiere el POST, pero si no hay (visita de DIAGNOSTICO, sin
    # pipeline auto) se cae al PRE. El PRE trae exactamente la misma ficha del
    # equipo (CPU, RAM, discos, bateria, servicios), asi que el reporte pasa de
    # inservible a entregable en el caso mas comun de la primera visita.
    # HONESTIDAD (regla de New-ClientReport: "nunca se fabrica un delta"): esto
    # SOLO alimenta la ficha del equipo. El panel Antes/Despues depende del
    # Compare, que sin POST sigue diciendo "no disponible" -- y esta bien, porque
    # no hubo servicio que comparar.
    # NOTA: no hace falta re-rotular el panel. El titulo "Tu equipo" es honesto con
    # PRE o con POST (es la ficha del equipo, no un "despues"), y "Antes y despues"
    # sigue diciendo "no disponible" solo. El fallback alcanza.
    [PSCustomObject] $postSnap = $null
    try {
        [string] $snapshotsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\snapshots'
        if (Test-Path -LiteralPath $snapshotsDir) {
            [object[]] $postFiles = @(Get-ChildItem -Path $snapshotsDir -Filter '*_post.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            if ($postFiles.Count -gt 0) {
                $postSnap = Get-Content -LiteralPath $postFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            } else {
                [object[]] $preFiles = @(Get-ChildItem -Path $snapshotsDir -Filter '*_pre.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)
                if ($preFiles.Count -gt 0) {
                    $postSnap = Get-Content -LiteralPath $preFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    Write-PctkHint '  [i] Sin snapshot POST: la ficha del equipo sale del PRE (estado actual).'
                }
            }
        }
    } catch {
        Write-PctkHint ('  [i] Snapshot no encontrado: {0}' -f $_.Exception.Message)
    }

    try {
        $r = New-ClientReport `
            -PostSnapshot $postSnap `
            -Compare      $compareResult `
            -OutputPath   $outPath `
            -OpenAfter

        if ($r.Success) {
            Write-PctkOk ('  [OK] Reporte generado: {0}' -f $r.FilePath)
            Write-ActionAudit -Action 'Report.Client' -Status 'Success' -Summary $r.FilePath
        } else {
            Write-PctkWarn '  [!] El reporte no pudo generarse.'
            Write-ActionAudit -Action 'Report.Client' -Status 'Failed' -Summary 'New-ClientReport retorno Success=false'
        }
    } catch {
        Write-PctkWarn ('  [!] Error al generar reporte: {0}' -f $_.Exception.Message)
        Write-ActionAudit -Action 'Report.Client' -Status 'Failed' -Summary $_.Exception.Message
    }
}

# ─── Research prompt handler ──────────────────────────────────────────────────

function Invoke-ResearchPrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)

    Write-PctkSection '  PLANTILLAS DE PROMPT'
    [object[]] $templates = @(Get-ResearchPromptTemplates)
    for ([int] $i = 0; $i -lt $templates.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $templates[$i].Label)
        Write-PctkHint ('      {0}' -f $templates[$i].Description)
    }
    Write-Host ''
    [string] $choice = (Read-Host '  Numero de plantilla (Enter para cancelar)').Trim()
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    [int] $idx = -1
    if (-not [int]::TryParse($choice, [ref] $idx) -or $idx -lt 1 -or $idx -gt $templates.Count) {
        Write-PctkErr '  Opcion invalida.'
        return
    }
    [string] $tplKey = $templates[$idx - 1].Key

    [string] $useCase = (Read-Host '  Use-case del cliente (opcional, Enter para skip)').Trim()
    # Privacidad: este prompt sale de la PC del CLIENTE y termina pegado en un LLM
    # de terceros (ademas del archivo, se copia al portapapeles). Lleva datos reales
    # del equipo. Hasta 2026-07-25 solo se preguntaba si el OS NO era Home -- o sea,
    # en la mayoria de las PCs de cliente (Home) el nombre del equipo salia en claro
    # SIN avisar. Ahora se pregunta SIEMPRE y el default es scrubear.
    Write-PctkWarn '  Este prompt se copia al portapapeles para pegarlo en un LLM externo.'
    Write-PctkHint '  Incluye datos reales del equipo del cliente (hardware, programas, antivirus).'
    [string] $ans = (Read-Host '  Incluir identificadores del equipo (nombre de PC)? [s/N]').Trim().ToUpperInvariant()
    [bool] $includeId = ($ans -eq 'S')
    if (-not $includeId) {
        Write-PctkHint '  Identificadores scrubeados.'
    }

    Write-ActionAudit -Action 'Research.Prompt' -Status 'Started' -Summary $tplKey

    [hashtable] $params = @{
        Template       = $tplKey
        MachineProfile = $MachineProfile
    }
    if (-not [string]::IsNullOrWhiteSpace($useCase)) { $params['UseCase'] = $useCase }
    if ($includeId) { $params['IncludeIdentifiers'] = $true }

    Write-PctkWork '  Generando snapshot + prompt (puede tardar ~30s)...'
    $r = New-ResearchPrompt @params

    if ($null -eq $r -or -not $r.Success) {
        Write-PctkWarn '  [!] No se pudo generar el prompt.'
        Write-ActionAudit -Action 'Research.Prompt' -Status 'Failed'
        return
    }

    Write-PctkOk ('  [OK] Prompt generado: {0}' -f $r.FileName)
    Write-PctkHint ('       {0}' -f $r.FilePath)
    if ($r.ClipboardSet) {
        Write-PctkOk '  [OK] Copiado al clipboard. Pegalo en Claude/ChatGPT/Perplexity con web search habilitado.'
    } else {
        Write-PctkWarn '  [!] No se pudo copiar al clipboard. Abri el archivo manualmente.'
    }
    if ($r.Scrubbed) {
        Write-PctkHint '  [i] ComputerName/dominio scrubeados. Pasar -IncludeIdentifiers para incluirlos.'
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
        Write-PctkErr ('  [!] tools\manifest.json no encontrado en {0}' -f $manifestPath)
        return
    }

    $manifest = $null
    try   { $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json }
    catch { Write-PctkErr ('  [!] Error leyendo manifest.json: {0}' -f $_.Exception.Message); return }

    [object[]] $tools = @($manifest.tools)
    if ($tools.Count -eq 0) {
        Write-PctkWarn '  [!] manifest.json no contiene herramientas.'
        return
    }

    # Consola interactiva -> multi-seleccion con flechas. Si no (headless/smoke/
    # redirigido) -> cae al loop tipeado original de abajo (cero regresion).
    if (Test-PctkInteractiveConsole) {
        Invoke-ToolsMenuInteractive -Tools $tools -BinDir $binDir -Bootstrap $bootstrap
        return
    }

    do {
        Write-PctkActionTitle 'HERRAMIENTAS EXTERNAS'

        for ([int] $i = 0; $i -lt $tools.Count; $i++) {
            $t     = $tools[$i]
            $ok    = Get-ToolStatus -Tool $t -BinDir $binDir
            $label = if ($ok) { 'OK   ' } else { 'falta' }
            $clr   = if ($ok) { 'ok' } else { 'warn' }
            Write-PctkLine ('  [{0,2}]  {1,-26}  [{2,-12}]  {3}' -f ($i + 1), $t.name, $t.category, $label) $clr
        }

        Write-Host ''
        [string] $fLabel = if ($forceToggle) { 'ON ' } else { 'off' }
        Write-Host ('  [T] Todas  [F] -Force: {0}  [O] Abrir carpeta  [B] Volver' -f $fLabel)
        Write-PctkHint ('  Binarios: {0}' -f $binDir)
        Write-Host ''
        [string] $raw = (Read-Host '  Seleccion (numero/s, T/F/O/B)').Trim()

        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        [string] $up = $raw.ToUpperInvariant()

        if ($up -eq 'B') { return }

        if ($up -eq 'F') {
            $forceToggle = -not $forceToggle
            Write-PctkWork ('  -Force: {0}' -f $(if ($forceToggle) { 'ON' } else { 'off' }))
            continue
        }

        if ($up -eq 'O') {
            if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
            Start-Process explorer.exe $binDir
            continue
        }

        if ($up -eq 'T') {
            if (-not (Test-Path $bootstrap)) {
                Write-PctkErr ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $bootstrap)
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
                Write-PctkErr ('  [!] "{0}" no valido (1-{1}, T, F, O, B).' -f $tok, $tools.Count)
                $valid = $false; break
            }
        }
        if (-not $valid -or $sel.Count -eq 0) { continue }

        if (-not (Test-Path $bootstrap)) {
            Write-PctkErr ('  [!] Bootstrap-Tools.ps1 no encontrado en {0}' -f $bootstrap)
            continue
        }

        foreach ($idx in $sel) {
            $t = $tools[$idx]
            Write-PctkWork ('  Procesando: {0}...' -f $t.name)
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
        '17' { Invoke-ActionDiskMaintenance -MachineProfile $MachineProfile; return }
        '18' { Invoke-ActionEncryption      -MachineProfile $MachineProfile; return }
        '19' { Invoke-ActionDefenderScan    -MachineProfile $MachineProfile; return }
        default {
            Write-PctkErr '  Opcion invalida.'
        }
    }
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

    Write-PctkActionTitle 'APLICAR PERFIL AUTOMATICO'
    Write-PctkWarn ("  Tier detectado: {0}" -f $detectedTier)
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
        default { Write-PctkErr '  Opcion invalida.'; return }
    }

    # ── Cargar receta para el use-case (v2.0: sin tier en el path) ────────────
    [string] $profPath = Get-AutoProfilePath -UseCase $useCase

    [string] $auditAction = ('Profile.Apply.' + (([string]$useCase).Substring(0,1).ToUpperInvariant() + ([string]$useCase).Substring(1)))

    [PSCustomObject] $profile = $null
    try {
        $profile = Import-AutoProfile -Path $profPath
    } catch {
        Write-PctkErr ("  [!] No se pudo cargar la receta: {0}" -f $_.Exception.Message)
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
    Write-PctkHint ("  Cliente: {0}" -f $clientSlug)

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
    Write-PctkWork '  Iniciando pipeline...'
    $result = Invoke-AutoProfile `
        -Profile       $profile `
        -MachineProfile $MachineProfile `
        -ClientSlug    $clientSlug `
        -SkipRestorePoint:(-not $createRp) `
        -ShowProgress

    # ── Mostrar resumen final ─────────────────────────────────────────────────
    Write-Host ''
    [string] $statusKind = switch ($result.Status) {
        'Success' { 'ok'   }
        'Partial' { 'warn' }
        default   { 'err'  }
    }
    Write-PctkLine ('  === Resultado: {0} | Duracion: {1}s ===' -f $result.Status, $result.DurationSec) $statusKind

    [object] $crDir = $result.ClientRun.PSObject.Properties['Dir']
    if ($null -ne $crDir -and -not [string]::IsNullOrWhiteSpace([string]$crDir.Value)) {
        Write-PctkWork ('  Carpeta de run: {0}' -f [string]$crDir.Value)
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
        [string] $npKind = switch ($st) { 'Success' { 'ok' } 'Partial' { 'warn' } default { 'err' } }
        Write-Host ''
        Write-PctkLine ('  === Resultado receta nombrada: {0} ===' -f $st) $npKind
        if ($null -ne $r -and $r.PSObject.Properties['RebootNeeded'] -and [bool]$r.RebootNeeded) {
            Write-PctkWarn '  [i] Requiere REINICIO para efecto pleno (HVCI/HAGS).'
        }
        if ($null -ne $r -and $r.PSObject.Properties['ClientRun'] -and $null -ne $r.ClientRun) {
            [object] $d = $r.ClientRun.PSObject.Properties['Dir']
            if ($null -ne $d -and -not [string]::IsNullOrWhiteSpace([string]$d.Value)) {
                Write-PctkWork ('  Carpeta de run: {0}' -f [string]$d.Value)
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
        Write-PctkOk ('  [OK] Guardada: {0}' -f $path)
        if (Confirm-Action -Title 'Aplicar la receta ahora?' -DefaultYes:$true) {
            [string] $cs = _Np_ClientSlug
            [bool]   $rp = _Np_RpGate
            Write-Host ''
            Write-PctkWork '  Iniciando pipeline (core + gaming_tweaks)...'
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
            Write-PctkWarn '  No hay recetas nombradas guardadas.'
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
            Write-PctkWork ('  Ultima receta: {0}  (last_applied: {1})' -f $sel.Name, $(if ($sel.LastApplied) { $sel.LastApplied } else { 'nunca' }))
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
                Write-PctkErr '  Seleccion invalida.'
                return
            }
            $sel = $list[$idx - 1]
        }

        [PSCustomObject] $prof = $null
        try {
            $prof = Import-NamedProfile -Path $sel.Path
        } catch {
            Write-PctkErr ('  [!] No se pudo cargar: {0}' -f $_.Exception.Message)
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
        Write-PctkWork '  Iniciando pipeline (core + gaming_tweaks)...'
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

    Write-PctkErr '  Opcion invalida.'
}
