#Requires -Version 5.1
Set-StrictMode -Version Latest

foreach ($folder in @('core', 'utils', 'modules')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    $scripts = Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($script in $scripts) {
        . $script.FullName
    }
}

function Show-MainMenu {
    :mainLoop while ($true) {
        Clear-Host
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host '        PC OPTIMIZACION TOOLKIT                 ' -ForegroundColor Cyan
        Write-Host '================================================' -ForegroundColor DarkCyan

        $regKey      = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        [string]$osInfo = if ($regKey) {
            'Sistema: {0} - Build {1}' -f $regKey.ProductName, $regKey.CurrentBuild
        } else {
            'Sistema: No disponible'
        }
        [string]$padded = $osInfo.PadLeft([int](($osInfo.Length + 48) / 2)).PadRight(48)
        Write-Host $padded -ForegroundColor Green

        Write-Host ''
        Write-Host '  [1]  Deshabilitar Servicios Bloat'
        Write-Host '  [2]  Limpieza de Temporales'
        Write-Host '  [3]  Mantenimiento del Sistema (DISM/SFC)'
        Write-Host '  [4]  Crear Punto de Restauracion'
        Write-Host '  [5]  Optimizar Red (Adaptadores + TCP/DNS)'
        Write-Host '  [6]  Rendimiento (Efectos Visuales + Plan de Energia)'
        Write-Host ''
        Write-Host '  [DIAGNOSTICO Y AUDITORIA]' -ForegroundColor DarkCyan
        Write-Host '  [7]  Snapshot PRE-service'
        Write-Host '  [8]  Snapshot POST-service'
        Write-Host '  [9]  Comparar PRE vs POST'
        Write-Host '  [10] Historial de BSOD / Crashes'
        Write-Host '  [11] Backup de Drivers'
        Write-Host '  [q]  Salir'
        Write-Host ''
        Write-Host '================================================' -ForegroundColor DarkCyan

        [string]$choice = (Read-Host '  Selecciona una opcion').Trim().ToLower()

        switch ($choice) {
            '1' {
                # Metadatos de servicios bloat
                $bloatCatalog = @(
                    [PSCustomObject]@{ Name = 'XblAuthManager';    Desc = 'Xbox Live Auth Manager';              Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'XblGameSave';       Desc = 'Xbox Live Game Save';                 Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'XboxNetApiSvc';     Desc = 'Xbox Live Networking';                Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'XboxGipSvc';        Desc = 'Xbox Accessory Management';           Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'Spooler';           Desc = 'Cola de impresion';                   Risk = 'Medio' }
                    [PSCustomObject]@{ Name = 'PrintNotify';       Desc = 'Notificaciones de impresora';         Risk = 'Medio' }
                    [PSCustomObject]@{ Name = 'Fax';               Desc = 'Servicio de Fax';                     Risk = 'Bajo'  }
                    [PSCustomObject]@{ Name = 'WMPNetworkSvc';     Desc = 'Windows Media Player Network Share';  Risk = 'Bajo'  }
                    [PSCustomObject]@{ Name = 'RemoteRegistry';    Desc = 'Registro remoto';                     Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'RemoteAccess';      Desc = 'Enrutamiento y acceso remoto';        Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'DiagTrack';         Desc = 'Telemetria y experiencias conectadas'; Risk = 'Alto'  }
                    [PSCustomObject]@{ Name = 'dmwappushservice';  Desc = 'WAP Push Message Routing';            Risk = 'Medio' }
                )

                # Escanear cuales existen en este sistema
                $present = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($entry in $bloatCatalog) {
                    $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
                    if ($svc) {
                        $present.Add([PSCustomObject]@{
                            Index  = $present.Count + 1
                            Name   = $entry.Name
                            Desc   = $entry.Desc
                            Risk   = $entry.Risk
                            Status = $svc.Status.ToString()
                        })
                    }
                }

                if ($present.Count -eq 0) {
                    Write-Host "`n  No se encontraron servicios bloat en este sistema." -ForegroundColor DarkYellow
                    break
                }

                # Mostrar tabla de servicios presentes
                Write-Host ''
                Write-Host ('  {0,-4} {1,-22} {2,-10} {3,-8} {4}' -f '#', 'Servicio', 'Estado', 'Riesgo', 'Descripcion') -ForegroundColor DarkCyan
                Write-Host ('  {0}' -f ('-' * 72)) -ForegroundColor DarkCyan
                foreach ($svc in $present) {
                    [string]$riskColor = switch ($svc.Risk) {
                        'Alto'  { 'Red'    }
                        'Medio' { 'Yellow' }
                        default { 'Gray'   }
                    }
                    [string]$statusColor = if ($svc.Status -eq 'Running') { 'Yellow' } else { 'DarkGray' }
                    Write-Host ('  {0,-4} {1,-22} ' -f $svc.Index, $svc.Name) -NoNewline
                    Write-Host ('{0,-10} ' -f $svc.Status) -NoNewline -ForegroundColor $statusColor
                    Write-Host ('{0,-8} ' -f $svc.Risk)   -NoNewline -ForegroundColor $riskColor
                    Write-Host $svc.Desc
                }
                Write-Host ''

                [string]$selection = (Read-Host '  Numeros a deshabilitar (ej: 1,3,5), [all] para todos, [q] para cancelar').Trim().ToLower()

                if ($selection -eq 'q' -or [string]::IsNullOrWhiteSpace($selection)) { break }

                [string[]]$chosenNames = if ($selection -eq 'all') {
                    $present | ForEach-Object { $_.Name }
                } else {
                    $parsed = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
                    $valid  = $parsed | ForEach-Object {
                        [int]$idx = [int]$_
                        $match = $present | Where-Object { $_.Index -eq $idx }
                        if ($match) { $match.Name }
                    }
                    @($valid)
                }

                if ($chosenNames.Count -eq 0) {
                    Write-Host "`n  Seleccion invalida. Volviendo al menu." -ForegroundColor Red
                    break
                }

                Write-Host ("`n  Deshabilitando {0} servicio(s)..." -f $chosenNames.Count) -ForegroundColor Cyan
                $job    = Start-DebloatProcess -ServicesList $chosenNames
                $result = Wait-ToolkitJobs -Jobs @($job)

                Write-Host ("  Servicios deshabilitados : {0}" -f $result.Disabled) -ForegroundColor Green
                if ($result.Failed -gt 0) {
                    Write-Host ("  Errores                  : {0}" -f $result.Failed) -ForegroundColor Yellow
                    foreach ($err in $result.Errors) {
                        Write-Host ("    - {0}" -f $err) -ForegroundColor DarkYellow
                    }
                }
            }
            '2' {
                Write-Host "`n  Escaneando carpetas temporales..." -ForegroundColor Cyan
                [PSCustomObject] $preview = Get-CleanupPreview

                if ($preview.Folders.Count -eq 0) {
                    Write-Host '  No se encontro basura que limpiar.' -ForegroundColor DarkYellow
                    break
                }

                Write-Host ''
                Write-Host ('  {0,-30} {1,10}' -f 'Carpeta', 'Tamanio') -ForegroundColor DarkCyan
                Write-Host ('  {0}' -f ('-' * 43)) -ForegroundColor DarkCyan
                foreach ($row in $preview.Folders) {
                    [string] $sizeLabel = if ($row.SizeMB -ge 1024) {
                        '{0:N2} GB' -f ($row.SizeBytes / 1GB)
                    } else {
                        '{0:N1} MB' -f $row.SizeMB
                    }
                    Write-Host ('  {0,-30} {1,10}' -f $row.Label, $sizeLabel)
                }
                Write-Host ('  {0}' -f ('-' * 43)) -ForegroundColor DarkCyan
                [string] $totalLabel = if ($preview.TotalGB -ge 1) {
                    '{0:N2} GB' -f $preview.TotalGB
                } else {
                    '{0:N1} MB' -f $preview.TotalMB
                }
                Write-Host ('  {0,-30} {1,10}' -f 'TOTAL estimado', $totalLabel) -ForegroundColor Yellow
                Write-Host ''

                [string] $confirm = (Read-Host '  Confirmar limpieza? [s] Si  [q] Cancelar').Trim().ToLower()
                if ($confirm -ne 's') { break }

                Write-Host "`n  Borrando archivos..." -ForegroundColor Cyan
                $job    = Start-CleanupProcess
                $result = Wait-ToolkitJobs -Jobs @($job)

                [string] $freed = if ($result.FreedGB -ge 1) {
                    '{0:N2} GB' -f $result.FreedGB
                } else {
                    '{0:N2} MB' -f $result.FreedMB
                }

                Write-Host ("  Espacio liberado  : {0}" -f $freed) -ForegroundColor Green
                if ($result.SoftErrors -gt 0) {
                    Write-Host ("  Advertencias      : {0} archivo(s) en uso o sin acceso." -f $result.SoftErrors) -ForegroundColor Yellow
                }
            }
            '3' {
                Write-Host "`n  Iniciando mantenimiento del sistema (puede tardar varios minutos)..." -ForegroundColor Cyan
                $job    = Start-MaintenanceProcess
                $result = Wait-ToolkitJobs -Jobs @($job)

                [string]$dismStatus = if ($result.DismExitCode -eq 0) { 'Exito' } else { 'Error (codigo {0})' -f $result.DismExitCode }
                [string]$sfcStatus  = if ($result.SfcExitCode  -eq 0) { 'Exito' } else { 'Error (codigo {0})' -f $result.SfcExitCode  }

                Write-Host ("  DISM RestoreHealth : {0}" -f $dismStatus) -ForegroundColor $(if ($result.DismExitCode -eq 0) { 'Green' } else { 'Red' })
                Write-Host ("  SFC /scannow       : {0}" -f $sfcStatus)  -ForegroundColor $(if ($result.SfcExitCode  -eq 0) { 'Green' } else { 'Red' })
                Write-Host "`n  Para ver detalles del SFC, revisa: C:\Windows\Logs\CBS\CBS.log" -ForegroundColor DarkGray
            }
            '4' {
                Write-Host "`n  Creando punto de restauracion (puede demorar un poco)..." -ForegroundColor Cyan
                $job    = Start-RestorePointProcess
                $result = Wait-ToolkitJobs -Jobs @($job)

                if ($result.Success) {
                    Write-Host ("  Exito: {0}" -f $result.Message) -ForegroundColor Green
                } else {
                    Write-Host ("  Fallo: {0}" -f $result.Message) -ForegroundColor Red
                    Write-Host "  (Nota: Windows por defecto permite crear solo 1 punto cada 24 horas)" -ForegroundColor DarkGray
                }
            }
            '5' {
                # Sub-loop para poder volver al menu de red luego de leer la info
                :networkLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '          OPTIMIZACION DE RED                   ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''
                    Write-Host '  Que se aplica a cada adaptador:' -ForegroundColor DarkCyan
                    Write-Host '    - Deshabilita EEE / Green Ethernet / Power Saving Mode (Registro NIC)'
                    Write-Host '  Que se aplica globalmente (siempre):' -ForegroundColor DarkCyan
                    Write-Host '    - TCP Auto-Tuning = Normal  (ancho de banda maximo en planes 300MB+)'
                    Write-Host '    - TCP Fast Open   = Enabled (reduce latencia de handshake)'
                    Write-Host '    - ipconfig /flushdns        (limpia cache DNS obsoleta)'
                    Write-Host ''

                    # Detectar adaptadores fisicos activos
                    [object[]] $netAdapters = @(
                        Get-NetAdapter -ErrorAction SilentlyContinue |
                            Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -in @('802.3', 'Native 802.11') } |
                            Select-Object -Property Name, InterfaceDescription, PhysicalMediaType
                    )

                    if ($netAdapters.Count -eq 0) {
                        Write-Host '  No se detectaron adaptadores Ethernet/Wi-Fi activos.' -ForegroundColor DarkYellow
                        break networkLoop
                    }

                    # Tabla de adaptadores
                    Write-Host ('  {0,-4} {1,-28} {2}' -f '#', 'Nombre', 'Descripcion') -ForegroundColor DarkCyan
                    Write-Host ('  {0}' -f ('-' * 66)) -ForegroundColor DarkCyan
                    [int] $adIdx = 0
                    foreach ($ad in $netAdapters) {
                        $adIdx++
                        [string] $mediaLabel = if ($ad.PhysicalMediaType -eq '802.3') { 'Ethernet' } else { 'Wi-Fi' }
                        Write-Host ('  {0,-4} {1,-28} {2} [{3}]' -f $adIdx, $ad.Name, $ad.InterfaceDescription, $mediaLabel)
                    }
                    Write-Host ''

                    [string] $selection = (Read-Host '  Numeros a optimizar (ej: 1,2), [all] para todos, [i] mas info, [q] cancelar').Trim().ToLower()

                    if ($selection -eq 'q' -or [string]::IsNullOrWhiteSpace($selection)) { break networkLoop }

                    if ($selection -eq 'i') {
                        Clear-Host
                        Get-ToolkitHelp -Topic 'Network'
                        Write-Host ''
                        Read-Host '  Presione Enter para volver'
                        continue networkLoop
                    }

                    [string[]] $chosenAdapters = if ($selection -eq 'all') {
                        $netAdapters | ForEach-Object { $_.Name }
                    } else {
                        $parsed = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
                        @($parsed | ForEach-Object {
                            [int] $i = [int]$_
                            if ($i -ge 1 -and $i -le $netAdapters.Count) { $netAdapters[$i - 1].Name }
                        })
                    }

                    if ($chosenAdapters.Count -eq 0) {
                        Write-Host "`n  Seleccion invalida. Volviendo al menu." -ForegroundColor Red
                        break networkLoop
                    }

                    Write-Host ("`n  Optimizando {0} adaptador(es) + configuracion global TCP/DNS..." -f $chosenAdapters.Count) -ForegroundColor Cyan
                    $job    = Start-NetworkProcess -AdapterNames $chosenAdapters
                    $result = Wait-ToolkitJobs -Jobs @($job)

                    Write-Host ''
                    foreach ($ad in $result.AdaptersOptimized) {
                        Write-Host ("  [OK] Adaptador : {0}" -f $ad) -ForegroundColor Green
                    }
                    Write-Host '  [OK] TCP Global Settings + DNS Flush' -ForegroundColor Green

                    if (-not $result.Success) {
                        Write-Host '  [!] Alguno de los comandos globales requirio privilegios de administrador.' -ForegroundColor Yellow
                    }

                    break networkLoop
                }
            }
            '6' {
                :perfLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '      RENDIMIENTO — EFECTOS VISUALES            ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''
                    Write-Host '  Selecciona un perfil de efectos visuales:' -ForegroundColor DarkCyan
                    Write-Host ''
                    Write-Host '  [1]  Balanceado        ' -NoNewline; Write-Host '(recomendado)' -ForegroundColor Green
                    Write-Host '       Desactiva animaciones y transparencias.'
                    Write-Host '       Preserva: ClearType, thumbnails, contenido al arrastrar.'
                    Write-Host ''
                    Write-Host '  [2]  Maximo Rendimiento' -NoNewline; Write-Host ' (agresivo)' -ForegroundColor Yellow
                    Write-Host '       Todo apagado. Igual a sysdm.cpl > Best Performance.'
                    Write-Host '       El sistema se ve basico pero es el mas rapido.'
                    Write-Host ''
                    Write-Host '  [3]  Restaurar Windows ' -NoNewline; Write-Host ' (deshacer)' -ForegroundColor DarkGray
                    Write-Host '       Reactiva todos los efectos. Igual a Best Appearance.'
                    Write-Host ''
                    Write-Host '  Todos los perfiles activan Ultimate Performance (o High Performance).' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [q]  Cancelar'
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $perfChoice = (Read-Host '  Selecciona una opcion').Trim().ToLower()

                    if ($perfChoice -eq 'q' -or [string]::IsNullOrWhiteSpace($perfChoice)) { break perfLoop }

                    [string] $visualProfile = switch ($perfChoice) {
                        '1' { 'Balanced' }
                        '2' { 'Full'     }
                        '3' { 'Restore'  }
                        default { '' }
                    }

                    if ([string]::IsNullOrEmpty($visualProfile)) {
                        Write-Host "`n  Opcion no valida." -ForegroundColor Red
                        Start-Sleep -Milliseconds 800
                        continue perfLoop
                    }

                    Write-Host "`n  Aplicando perfil '$visualProfile'..." -ForegroundColor Cyan
                    $job    = Start-PerformanceProcess -VisualProfile $visualProfile
                    $result = Wait-ToolkitJobs -Jobs @($job)

                    Write-Host ''
                    Write-Host '  Efectos Visuales:' -ForegroundColor DarkCyan
                    foreach ($item in $result.Visuals.Applied) {
                        [string] $itemColor = if     ($item -match '^\[ON\]' ) { 'Green'    }
                                              elseif ($item -match '^\[OFF\]') { 'DarkGray' }
                                              else                              { 'White'    }
                        Write-Host ("    {0}" -f $item) -ForegroundColor $itemColor
                    }
                    if (-not $result.Visuals.Success) {
                        foreach ($err in $result.Visuals.Errors) {
                            Write-Host ("    [!] {0}" -f $err) -ForegroundColor Red
                        }
                    }

                    Write-Host ''
                    Write-Host '  Plan de Energia:' -ForegroundColor DarkCyan
                    [string] $ppColor = if ($result.PowerPlan.Success) { 'Green' } else { 'Red' }
                    Write-Host ("    Activo : {0}" -f $result.PowerPlan.PlanName) -ForegroundColor $ppColor

                    Write-Host ''
                    Write-Host '  Nota: Cierra sesion o reinicia el Explorer para ver los cambios.' -ForegroundColor DarkGray

                    break perfLoop
                }
            }
            '7' {
                Write-Host "`n  Recopilando estado PRE-service (puede tardar un momento)..." -ForegroundColor Cyan
                $job    = Start-TelemetryJob -Phase 'Pre'
                $result = Wait-ToolkitJobs -Jobs @($job)

                Write-Host ("  Snapshot guardado : {0}" -f $result.FileName) -ForegroundColor Green
                Write-Host "  Realiza el service y luego ejecuta [8] para capturar el estado POST." -ForegroundColor DarkGray
            }
            '8' {
                Write-Host "`n  Recopilando estado POST-service (puede tardar un momento)..." -ForegroundColor Cyan
                $job    = Start-TelemetryJob -Phase 'Post'
                $result = Wait-ToolkitJobs -Jobs @($job)

                Write-Host ("  Snapshot guardado : {0}" -f $result.FileName) -ForegroundColor Green
                Write-Host "  Usa la opcion [9] para comparar PRE vs POST." -ForegroundColor DarkGray
            }
            '9' {
                try {
                    [PSCustomObject] $diff = Compare-Snapshot
                    Show-SnapshotComparison -Diff $diff
                } catch {
                    Write-Host ("`n  Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            '10' {
                Write-Host "`n  Leyendo Event Log (ultimos 90 dias)..." -ForegroundColor Cyan
                $job    = Start-BsodHistoryJob -Days 90
                $result = Wait-ToolkitJobs -Jobs @($job)
                Show-BsodHistory -Data $result
            }
            '11' {
                [string] $backupRoot = Join-Path $PSScriptRoot 'output\driver_backup'
                Write-Host ''
                Write-Host '  Se exportaran los siguientes drivers:' -ForegroundColor DarkCyan
                Write-Host '    - Todos los drivers de terceros (ProviderName != Microsoft)'
                Write-Host '    - Drivers de red (clase Net) independientemente del proveedor'
                Write-Host ('    Destino: {0}\<timestamp>' -f $backupRoot) -ForegroundColor DarkGray
                Write-Host ''

                [string] $confirm = (Read-Host '  Confirmar? [s] Exportar  [q] Cancelar').Trim().ToLower()
                if ($confirm -ne 's') { break }

                Write-Host "`n  Exportando drivers..." -ForegroundColor Cyan
                $job    = Start-DriverBackupJob -OutputRoot $backupRoot
                $result = Wait-ToolkitJobs -Jobs @($job)

                if ($result.Success) {
                    Write-Host ("  Drivers exportados : {0} / {1}" -f $result.Exported, $result.Total) -ForegroundColor Green
                    Write-Host ("  Destino            : {0}" -f $result.Destination) -ForegroundColor Green
                } else {
                    Write-Host ("  Error: {0}" -f $result.Message) -ForegroundColor Red
                }
            }
            'q' {
                Write-Host "`n  Hasta luego." -ForegroundColor Gray
                break mainLoop
            }
            default {
                Write-Host "`n  Opcion no valida. Intenta de nuevo." -ForegroundColor Red
            }
        }

        Write-Host ''
        Read-Host '  Presione Enter para continuar'
    }
}

Show-MainMenu   