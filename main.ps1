#Requires -Version 5.1
Set-StrictMode -Version Latest

[System.Collections.Generic.List[string]] $script:_loadErrors = [System.Collections.Generic.List[string]]::new()
foreach ($folder in @('core', 'utils', 'modules')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    $scripts = Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($moduleScript in $scripts) {
        try   { . $moduleScript.FullName }
        catch { $script:_loadErrors.Add("$($moduleScript.Name): $($_.Exception.Message)") }
    }
}

function Show-MainMenu {
    :mainLoop while ($true) {
        Clear-Host
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host '        PC OPTIMIZACION TOOLKIT                 ' -ForegroundColor Cyan
        Write-Host '================================================' -ForegroundColor DarkCyan

        if ($script:_loadErrors.Count -gt 0) {
            Write-Host '  [!] Errores al cargar modulos:' -ForegroundColor Red
            foreach ($e in $script:_loadErrors) {
                Write-Host "      $e" -ForegroundColor Red
            }
            Write-Host ''
        }

        $regKey      = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        [string]$osInfo = if ($regKey) {
            'Sistema: {0} - Build {1}' -f $regKey.ProductName, $regKey.CurrentBuild
        } else {
            'Sistema: No disponible'
        }
        [string]$padded = $osInfo.PadLeft([int](($osInfo.Length + 48) / 2)).PadRight(48)
        Write-Host $padded -ForegroundColor Green

        Write-Host ''
        Write-Host '  [OPTIMIZACION]' -ForegroundColor DarkCyan
        Write-Host '  [1]  Deshabilitar Servicios Bloat'
        Write-Host '       Detecta y deshabilita servicios innecesarios: Xbox, telemetria,' -ForegroundColor DarkGray
        Write-Host '       Remote Registry, Fax, etc. Seleccion granular por item.' -ForegroundColor DarkGray
        Write-Host '  [2]  Limpieza de Temporales'
        Write-Host '       Escanea y borra archivos temp de Windows, navegadores y Update.' -ForegroundColor DarkGray
        Write-Host '       Muestra preview con MB/GB a liberar antes de confirmar.' -ForegroundColor DarkGray
        Write-Host '  [3]  Mantenimiento del Sistema'
        Write-Host '       Ejecuta DISM RestoreHealth + SFC /scannow en secuencia.' -ForegroundColor DarkGray
        Write-Host '       Repara archivos del sistema corruptos o faltantes.' -ForegroundColor DarkGray
        Write-Host '  [4]  Crear Punto de Restauracion'
        Write-Host '       Crea un checkpoint de System Restore antes de hacer cambios.' -ForegroundColor DarkGray
        Write-Host '       Habilita System Restore en C:\ si estaba desactivado.' -ForegroundColor DarkGray
        Write-Host '  [5]  Optimizar Red'
        Write-Host '       Deshabilita power saving en adaptadores Ethernet/Wi-Fi activos.' -ForegroundColor DarkGray
        Write-Host '       Aplica TCP Auto-Tuning, Fast Open y flush de cache DNS.' -ForegroundColor DarkGray
        Write-Host '  [6]  Rendimiento'
        Write-Host '       Perfiles de efectos visuales (Balanceado/Maximo/Restaurar).' -ForegroundColor DarkGray
        Write-Host '       Activa Ultimate Performance plan. Tweaks: GameDVR, timeouts, SvcHost.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [DIAGNOSTICO Y AUDITORIA]' -ForegroundColor DarkCyan
        Write-Host '  [7]  Snapshot PRE-service'
        Write-Host '       Foto del estado actual: servicios, startup, disco, bateria, AV.' -ForegroundColor DarkGray
        Write-Host '       Guardar antes de hacer el service para comparar despues.' -ForegroundColor DarkGray
        Write-Host '  [8]  Snapshot POST-service'
        Write-Host '       Segunda foto despues de aplicar los cambios.' -ForegroundColor DarkGray
        Write-Host '  [9]  Comparar PRE vs POST'
        Write-Host '       Score de mejoras: espacio liberado, servicios, startup, AV, uptime.' -ForegroundColor DarkGray
        Write-Host '  [10] Historial de BSOD / Crashes'
        Write-Host '       Lee el Event Log (90 dias): Kernel-Power, BugCheck, apagados abruptos.' -ForegroundColor DarkGray
        Write-Host '       Muestra stop codes y guia de diagnostico segun patron.' -ForegroundColor DarkGray
        Write-Host '  [11] Backup de Drivers'
        Write-Host '       Exporta drivers de terceros y de red a output\driver_backup\.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [APLICACIONES]' -ForegroundColor DarkCyan
        Write-Host '  [12] Apps Win32 + UWP'
        Write-Host '       Lista programas clasicos instalados (navegadores, juegos, drivers).' -ForegroundColor DarkGray
        Write-Host '       Desinstalacion MSI silenciosa cuando es posible. Tambien apps Store.' -ForegroundColor DarkGray
        Write-Host '  [13] Privacidad'
        Write-Host '       Perfiles Basic / Medio / Agresivo via registro. Sin dependencias externas.' -ForegroundColor DarkGray
        Write-Host '       ShutUp10++ disponible como opcion avanzada en el sub-menu.' -ForegroundColor DarkGray
        Write-Host '  [14] Inicio del Sistema'
        Write-Host '       Lista entradas Run/RunOnce del registro y carpetas de Startup.' -ForegroundColor DarkGray
        Write-Host '       Deshabilita/habilita por indice. Abre Autoruns GUI para auditoria completa.' -ForegroundColor DarkGray
        Write-Host '  [15] Actualizaciones de Windows'
        Write-Host '       Muestra ultima actualizacion instalada y KBs recientes.' -ForegroundColor DarkGray
        Write-Host '       Abre Windows Update en Configuracion para buscar actualizaciones.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [HERRAMIENTAS EXTERNAS]' -ForegroundColor DarkCyan
        Write-Host '  [T]  Herramientas'
        Write-Host '       Autoruns, ShutUp10++, BCUninstaller, Process Monitor, TCPView, etc.' -ForegroundColor DarkGray
        Write-Host '       Descarga bajo demanda con barra de progreso. Lanza directo desde el menu.' -ForegroundColor DarkGray
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
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
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
                    Write-Host ('  {0,-36} {1,10}' -f $row.Label, $sizeLabel)
                }
                Write-Host ('  {0}' -f ('-' * 50)) -ForegroundColor DarkCyan
                [string] $totalLabel = if ($preview.TotalGB -ge 1) {
                    '{0:N2} GB' -f $preview.TotalGB
                } else {
                    '{0:N1} MB' -f $preview.TotalMB
                }
                Write-Host ('  {0,-36} {1,10}' -f 'TOTAL estimado', $totalLabel) -ForegroundColor Yellow
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
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
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
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
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
                    Write-Host ''
                    Read-Host '  [Enter] para continuar' | Out-Null

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
                    Write-Host '  [4]  Tweaks del sistema  ' -NoNewline; Write-Host ' (sin tocar visuales)' -ForegroundColor Cyan
                    Write-Host '       Deshabilita hibernacion y Game DVR.'
                    Write-Host '       Reduce shutdown timeout. Ajusta SvcHost threshold segun RAM.'
                    Write-Host ''
                    Write-Host '  Los perfiles 1-3 incluyen tambien: Power Plan + Tweaks del sistema.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [q]  Cancelar'
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $perfChoice = (Read-Host '  Selecciona una opcion').Trim().ToLower()

                    if ($perfChoice -eq 'q' -or [string]::IsNullOrWhiteSpace($perfChoice)) { break perfLoop }

                    [string] $visualProfile = switch ($perfChoice) {
                        '1' { 'Balanced'   }
                        '2' { 'Full'       }
                        '3' { 'Restore'    }
                        '4' { 'TweaksOnly' }
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
                    if ($null -ne $result.Visuals) {
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
                    }

                    Write-Host '  Tweaks del Sistema:' -ForegroundColor DarkCyan
                    foreach ($item in $result.Tweaks.Applied) {
                        Write-Host ("    [OK] {0}" -f $item) -ForegroundColor Green
                    }
                    if (-not $result.Tweaks.Success) {
                        foreach ($err in $result.Tweaks.Errors) {
                            Write-Host ("    [!] {0}" -f $err) -ForegroundColor Red
                        }
                    }

                    if ($null -ne $result.PowerPlan) {
                        Write-Host ''
                        Write-Host '  Plan de Energia:' -ForegroundColor DarkCyan
                        [string] $ppColor = if ($result.PowerPlan.Success) { 'Green' } else { 'Red' }
                        Write-Host ("    Activo : {0}" -f $result.PowerPlan.PlanName) -ForegroundColor $ppColor
                    }

                    Write-Host ''
                    Write-Host '  Nota: Cierra sesion o reinicia el Explorer para ver los cambios.' -ForegroundColor DarkGray
                    Write-Host ''
                    Read-Host '  [Enter] para continuar' | Out-Null

                    break perfLoop
                }
            }
            '7' {
                Write-Host "`n  Recopilando estado PRE-service (puede tardar un momento)..." -ForegroundColor Cyan
                $job    = Start-TelemetryJob -Phase 'Pre'
                $result = Wait-ToolkitJobs -Jobs @($job)

                Write-Host ("  Snapshot guardado : {0}" -f $result.FileName) -ForegroundColor Green
                Write-Host "  Realiza el service y luego ejecuta [8] para capturar el estado POST." -ForegroundColor DarkGray
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
            }
            '8' {
                Write-Host "`n  Recopilando estado POST-service (puede tardar un momento)..." -ForegroundColor Cyan
                $job    = Start-TelemetryJob -Phase 'Post'
                $result = Wait-ToolkitJobs -Jobs @($job)

                Write-Host ("  Snapshot guardado : {0}" -f $result.FileName) -ForegroundColor Green
                Write-Host "  Usa la opcion [9] para comparar PRE vs POST." -ForegroundColor DarkGray
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
            }
            '9' {
                try {
                    [PSCustomObject] $diff = Compare-Snapshot
                    Show-SnapshotComparison -Diff $diff
                } catch {
                    Write-Host ("`n  Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
            }
            '10' {
                Write-Host "`n  Leyendo Event Log (ultimos 90 dias)..." -ForegroundColor Cyan
                $job    = Start-BsodHistoryJob -Days 90
                $result = Wait-ToolkitJobs -Jobs @($job)
                Show-BsodHistory -Data $result
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
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
                Write-Host ''
                Read-Host '  [Enter] para continuar' | Out-Null
            }
            '12' {
                :appsLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '           APLICACIONES INSTALADAS              ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''
                    Write-Host '  [1]  Apps Win32 / Escritorio'
                    Write-Host '       Programas clasicos: browsers, juegos, drivers, herramientas.' -ForegroundColor DarkGray
                    Write-Host '       Lee el registro directamente (mismo origen que Panel de Control).' -ForegroundColor DarkGray
                    Write-Host '       Desinstalacion MSI silenciosa o interactiva segun el instalador.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [2]  Apps UWP / Microsoft Store'
                    Write-Host '       Paquetes AppX del usuario: apps de Store, bloatware de Windows.' -ForegroundColor DarkGray
                    Write-Host '       Incluye apps Microsoft (Xbox, Cortana, etc.) para seleccion.' -ForegroundColor DarkGray
                    Write-Host '       Eliminacion via Remove-AppxPackage.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [q]  Volver' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $appsChoice = (Read-Host '  Selecciona una opcion').Trim().ToLower()

                    switch ($appsChoice) {
                        '1' {
                            [string] $win32Filter = ''
                            :win32Loop while ($true) {
                                Clear-Host
                                Write-Host '================================================' -ForegroundColor DarkCyan
                                Write-Host '        APPS WIN32 / ESCRITORIO                 ' -ForegroundColor Cyan
                                Write-Host '================================================' -ForegroundColor DarkCyan
                                Write-Host ''

                                [PSCustomObject[]] $win32Apps = Get-InstalledWin32Apps -Filter $win32Filter

                                if ($win32Filter) {
                                    Write-Host ('  Filtro: "{0}" — {1} resultado(s).' -f $win32Filter, $win32Apps.Count) -ForegroundColor Yellow
                                } else {
                                    Write-Host ('  {0} apps instaladas.' -f $win32Apps.Count) -ForegroundColor DarkGray
                                }
                                Write-Host '  Filtra con [f texto]. Busca por nombre o publisher.' -ForegroundColor DarkGray
                                Write-Host ''

                                if ($win32Apps.Count -gt 0) {
                                    Write-Host ('  {0,-4} {1,-42} {2,-18} {3,7}' -f '#', 'Nombre', 'Version', 'Tamano') -ForegroundColor DarkCyan
                                    Write-Host ('  {0}' -f ('-' * 75)) -ForegroundColor DarkCyan
                                    [int] $idx = 0
                                    foreach ($app in $win32Apps) {
                                        $idx++
                                        [string] $shortName = if ($app.Name.Length -gt 41) { $app.Name.Substring(0, 38) + '...' } else { $app.Name }
                                        [string] $shortVer  = if ($app.Version.Length -gt 17) { $app.Version.Substring(0, 14) + '...' } else { $app.Version }
                                        [string] $sizeStr   = if ($app.SizeMB) { '{0} MB' -f $app.SizeMB } else { '?' }
                                        Write-Host ('  {0,-4} {1,-42} {2,-18} {3,7}' -f $idx, $shortName, $shortVer, $sizeStr)
                                    }
                                } else {
                                    Write-Host '  Sin resultados.' -ForegroundColor DarkYellow
                                }

                                Write-Host ''
                                [string] $w32sel = (Read-Host '  [numero] desinstalar  [f texto] filtrar  [c] limpiar filtro  [q] volver').Trim().ToLower()

                                if ($w32sel -eq 'q' -or [string]::IsNullOrWhiteSpace($w32sel))  { break win32Loop }

                                if ($w32sel -eq 'c') {
                                    $win32Filter = ''
                                    continue win32Loop
                                }

                                if ($w32sel -match '^f (.+)$') {
                                    $win32Filter = $Matches[1].Trim()
                                    continue win32Loop
                                }

                                if ($w32sel -match '^\.+$' -or $w32sel -match '^\d+$') {
                                    [int] $selIdx = 0
                                    if (-not [int]::TryParse($w32sel, [ref] $selIdx) -or $selIdx -lt 1 -or $selIdx -gt $win32Apps.Count) {
                                        Write-Host '  Numero fuera de rango.' -ForegroundColor Red
                                        Start-Sleep -Milliseconds 700
                                        continue win32Loop
                                    }

                                    [PSCustomObject] $selApp = $win32Apps[$selIdx - 1]

                                    [string] $methodLabel = if (-not [string]::IsNullOrWhiteSpace($selApp.QuietUninstallString)) {
                                        'Silencioso (QuietUninstallString)'
                                    } elseif ($selApp.UninstallString -match 'MsiExec') {
                                        'MSI silencioso (/qn /norestart)'
                                    } elseif (-not [string]::IsNullOrWhiteSpace($selApp.UninstallString)) {
                                        'Interactivo — se abrira el desinstalador'
                                    } else {
                                        'Sin metodo disponible'
                                    }

                                    Write-Host ''
                                    Write-Host ('  Nombre    : {0}' -f $selApp.Name) -ForegroundColor White
                                    if ($selApp.Version)   { Write-Host ('  Version   : {0}' -f $selApp.Version)   -ForegroundColor DarkGray }
                                    if ($selApp.Publisher) { Write-Host ('  Publisher : {0}' -f $selApp.Publisher) -ForegroundColor DarkGray }
                                    if ($selApp.SizeMB)    { Write-Host ('  Tamano    : {0} MB' -f $selApp.SizeMB)  -ForegroundColor DarkGray }
                                    Write-Host ('  Metodo    : {0}' -f $methodLabel) -ForegroundColor $(if ($methodLabel -match 'Interactivo') { 'Yellow' } else { 'Cyan' })
                                    Write-Host ''

                                    [string] $confirm = (Read-Host '  Confirmar desinstalacion? [s] Si  [q] Cancelar').Trim().ToLower()
                                    if ($confirm -ne 's') { continue win32Loop }

                                    Write-Host "`n  Desinstalando..." -ForegroundColor Cyan
                                    [PSCustomObject] $unResult = Invoke-Win32Uninstall -App $selApp

                                    if ($unResult.Success) {
                                        Write-Host ('  [OK] {0} desinstalado correctamente.' -f $unResult.App) -ForegroundColor Green
                                    } else {
                                        [string] $errMsg = if ($unResult.Error) { $unResult.Error } else { 'Codigo de salida: {0}' -f $unResult.ExitCode }
                                        Write-Host ('  [!]  Error: {0}' -f $errMsg) -ForegroundColor Red
                                    }
                                    Write-Host ''
                                    Read-Host '  Presione Enter para continuar'
                                }
                            }
                        }
                        '2' {
                            [string] $uwpFilter = ''
                            :uwpLoop while ($true) {
                                Clear-Host
                                Write-Host '================================================' -ForegroundColor DarkCyan
                                Write-Host '        APPS UWP / MICROSOFT STORE              ' -ForegroundColor Cyan
                                Write-Host '================================================' -ForegroundColor DarkCyan
                                Write-Host ''

                                [PSCustomObject[]] $uwpApps = Get-InstalledUwpApps -Filter $uwpFilter

                                if ($uwpFilter) {
                                    Write-Host ('  Filtro: "{0}" — {1} resultado(s).' -f $uwpFilter, $uwpApps.Count) -ForegroundColor Yellow
                                } else {
                                    Write-Host ('  {0} paquetes AppX encontrados. Apps Microsoft en gris.' -f $uwpApps.Count) -ForegroundColor DarkGray
                                }
                                Write-Host '  Filtra con [f texto]. Ej: [f xbox], [f candy], [f spotify].' -ForegroundColor DarkGray
                                Write-Host ''

                                if ($uwpApps.Count -gt 0) {
                                    Write-Host ('  {0,-4} {1,-48} {2}' -f '#', 'Paquete', 'Version') -ForegroundColor DarkCyan
                                    Write-Host ('  {0}' -f ('-' * 70)) -ForegroundColor DarkCyan
                                    [int] $idx = 0
                                    foreach ($app in $uwpApps) {
                                        $idx++
                                        [string] $shortDisplay = if ($app.DisplayName.Length -gt 47) { $app.DisplayName.Substring(0, 44) + '...' } else { $app.DisplayName }
                                        [string] $rowColor     = if ($app.IsMicrosoft) { 'DarkGray' } else { 'White' }
                                        Write-Host ('  {0,-4} {1,-48} {2}' -f $idx, $shortDisplay, $app.Version) -ForegroundColor $rowColor
                                    }
                                } else {
                                    Write-Host '  Sin resultados.' -ForegroundColor DarkYellow
                                }

                                Write-Host ''
                                [string] $uwpSel = (Read-Host '  [numero] eliminar  [f texto] filtrar  [c] limpiar filtro  [q] volver').Trim().ToLower()

                                if ($uwpSel -eq 'q' -or [string]::IsNullOrWhiteSpace($uwpSel)) { break uwpLoop }

                                if ($uwpSel -eq 'c') {
                                    $uwpFilter = ''
                                    continue uwpLoop
                                }

                                if ($uwpSel -match '^f (.+)$') {
                                    $uwpFilter = $Matches[1].Trim()
                                    continue uwpLoop
                                }

                                if ($uwpSel -match '^\d+$') {
                                    [int] $selIdx = 0
                                    if (-not [int]::TryParse($uwpSel, [ref] $selIdx) -or $selIdx -lt 1 -or $selIdx -gt $uwpApps.Count) {
                                        Write-Host '  Numero fuera de rango.' -ForegroundColor Red
                                        Start-Sleep -Milliseconds 700
                                        continue uwpLoop
                                    }

                                    [PSCustomObject] $selUwp = $uwpApps[$selIdx - 1]

                                    Write-Host ''
                                    Write-Host ('  Paquete   : {0}' -f $selUwp.Name)      -ForegroundColor White
                                    Write-Host ('  Version   : {0}' -f $selUwp.Version)   -ForegroundColor DarkGray
                                    Write-Host ('  Publisher : {0}' -f $selUwp.Publisher) -ForegroundColor DarkGray
                                    if ($selUwp.IsMicrosoft) {
                                        Write-Host '  [!] Este es un paquete de Microsoft. Asegurate de no necesitarlo.' -ForegroundColor Yellow
                                    }
                                    Write-Host ''

                                    [string] $confirm = (Read-Host '  Confirmar eliminacion? [s] Si  [q] Cancelar').Trim().ToLower()
                                    if ($confirm -ne 's') { continue uwpLoop }

                                    try {
                                        Remove-AppxPackage -Package $selUwp.PackageFullName -ErrorAction Stop
                                        Write-Host ('  [OK] {0} eliminado.' -f $selUwp.DisplayName) -ForegroundColor Green
                                    }
                                    catch {
                                        Write-Host ('  [!]  Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
                                    }
                                    Write-Host ''
                                    Read-Host '  Presione Enter para continuar'
                                }
                            }
                        }
                        'q'     { break appsLoop }
                        default {
                            Write-Host '  Opcion no valida.' -ForegroundColor Red
                            Start-Sleep -Milliseconds 700
                        }
                    }
                }
            }
            '13' {
                :privacyLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '        PRIVACIDAD                              ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''
                    Write-Host '  Tweaks via registro de Windows. Sin dependencias externas.' -ForegroundColor DarkGray
                    Write-Host '  Los cambios son permanentes hasta revertirlos manualmente.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [1]  Basico'
                    Write-Host '       Telemetria, Advertising ID, Bing en Start, Feedback, Activity Feed.' -ForegroundColor DarkGray
                    Write-Host '  [2]  Medio' -ForegroundColor Yellow
                    Write-Host '       Basico + ubicacion global, experiencias personalizadas,' -ForegroundColor DarkGray
                    Write-Host '       sugerencias de inicio, apps silenciosas de MS, mapas.' -ForegroundColor DarkGray
                    Write-Host '  [3]  Agresivo' -ForegroundColor Red
                    Write-Host '       Medio + OneDrive (policy), Edge startup/background,' -ForegroundColor DarkGray
                    Write-Host '       consumer features, tips, Error Reporting.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [T]  Abrir ShutUp10++ GUI (200+ tweaks avanzados)' -ForegroundColor DarkGray
                    Write-Host '       Requiere descarga previa desde [T] Herramientas.' -ForegroundColor DarkGray
                    Write-Host '  [q]  Volver'
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $privChoice = (Read-Host '  Selecciona un perfil').Trim().ToLower()

                    switch ($privChoice) {
                        { $_ -in '1', '2', '3' } {
                            [string] $profileName = switch ($_) {
                                '1' { 'Basic'      }
                                '2' { 'Medium'     }
                                '3' { 'Aggressive' }
                            }
                            [string] $profileLabel = switch ($_) {
                                '1' { 'Basico'   }
                                '2' { 'Medio'    }
                                '3' { 'Agresivo' }
                            }

                            Write-Host ''
                            Write-Host ('  Perfil seleccionado : {0}' -f $profileLabel) -ForegroundColor Cyan
                            Write-Host '  Los tweaks son permanentes hasta revertirlos manualmente.' -ForegroundColor Yellow
                            Write-Host ''
                            [string] $privConfirm = (Read-Host '  Confirmar? [s] Aplicar  [q] Cancelar').Trim().ToLower()
                            if ($privConfirm -ne 's') { continue privacyLoop }

                            Write-Host ''
                            Write-Host ("  Aplicando perfil {0}..." -f $profileLabel) -ForegroundColor Cyan

                            [System.Management.Automation.Job] $job    = Start-PrivacyJob -Profile $profileName
                            [PSCustomObject]                   $result = Wait-ToolkitJobs -Jobs @($job)

                            Write-Host ''
                            Write-Host ("  Perfil aplicado : {0}" -f $result.Profile) -ForegroundColor Cyan
                            Write-Host ("  Tweaks aplicados: {0}" -f $result.Applied.Count) -ForegroundColor Green
                            foreach ($item in $result.Applied) {
                                Write-Host ("    + {0}" -f $item) -ForegroundColor DarkGray
                            }
                            if ($result.Errors.Count -gt 0) {
                                Write-Host ("  Errores         : {0}" -f $result.Errors.Count) -ForegroundColor Yellow
                                foreach ($err in $result.Errors) {
                                    Write-Host ("    - {0}" -f $err) -ForegroundColor DarkYellow
                                }
                            }
                            Write-Host ''
                            Read-Host '  [Enter] para continuar' | Out-Null
                            break privacyLoop
                        }
                        't' {
                            [bool] $ooAvailable = Test-ShutUp10Available
                            if (-not $ooAvailable) {
                                Write-Host ''
                                Write-Host '  [!] ShutUp10++ no esta descargado.' -ForegroundColor Yellow
                                Write-Host '      Ve a [T] Herramientas y descarga shutup10.' -ForegroundColor DarkGray
                                Write-Host ''
                            } else {
                                $r = Open-ShutUp10
                                if ($r.Success) {
                                    Write-Host '  Abriendo O&O ShutUp10++...' -ForegroundColor Cyan
                                } else {
                                    Write-Host ("  [!] Error: {0}" -f $r.Error) -ForegroundColor Red
                                }
                            }
                        }
                        'q'     { break privacyLoop }
                        default { }
                    }
                }
            }
            '14' {
                :startupLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '        INICIO DEL SISTEMA                      ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''

                    [PSCustomObject[]] $startupEntries = @(Get-StartupEntries)

                    if ($startupEntries.Count -eq 0) {
                        Write-Host '  Sin entradas de inicio encontradas.' -ForegroundColor DarkGray
                    } else {
                        [int] $enabledCount  = @($startupEntries | Where-Object { $_.Enabled }).Count
                        [int] $disabledCount = $startupEntries.Count - $enabledCount
                        Write-Host ('  {0} entradas  |  {1} activas  |  {2} deshabilitadas' -f
                            $startupEntries.Count, $enabledCount, $disabledCount) -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host ('  {0,-4} {1,-6} {2,-28} {3,-16} {4}' -f
                            '#', 'Estado', 'Nombre', 'Ubicacion', 'Comando') -ForegroundColor DarkCyan
                        Write-Host ('  ' + ('-' * 82)) -ForegroundColor DarkCyan

                        for ([int] $si = 0; $si -lt $startupEntries.Count; $si++) {
                            $se    = $startupEntries[$si]
                            [string] $icon  = if ($se.Enabled) { '[ON] ' } else { '[OFF]' }
                            [string] $color = if ($se.Enabled) { 'White' } else { 'DarkGray' }
                            [string] $note  = if (-not $se.CanToggle) { ' (RunOnce)' } else { '' }

                            # Truncar comando para que quepa en pantalla
                            [string] $shortCmd = $se.Command
                            if ($shortCmd.Length -gt 40) { $shortCmd = '...' + $shortCmd.Substring($shortCmd.Length - 37) }

                            Write-Host ('  {0,-4} {1,-6} {2,-28} {3,-16} {4}{5}' -f
                                ($si + 1), $icon,
                                ($se.Name -replace '[^\w\s\-\.\(\)]',''),
                                $se.Location, $shortCmd, $note) -ForegroundColor $color
                        }
                    }

                    Write-Host ''
                    Write-Host '  [D #]   Deshabilitar entrada (ej: D 3)' -ForegroundColor DarkGray
                    Write-Host '  [E #]   Habilitar entrada   (ej: E 2)' -ForegroundColor DarkGray
                    Write-Host '  [A]     Abrir Autoruns GUI' -ForegroundColor DarkGray
                    Write-Host '  [q]     Volver' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $sc = (Read-Host '  Selecciona').Trim().ToLower()

                    if ($sc -eq 'q' -or [string]::IsNullOrWhiteSpace($sc)) { break startupLoop }

                    if ($sc -eq 'a') {
                        $ar = Open-Autoruns
                        if ($ar.Success) {
                            Write-Host '  Abriendo Autoruns...' -ForegroundColor Cyan
                        } else {
                            Write-Host ("  [!] {0}" -f $ar.Error) -ForegroundColor Yellow
                        }
                        Start-Sleep -Milliseconds 900
                        continue startupLoop
                    }

                    # Comandos D # y E #
                    if ($sc -match '^([de])\s+(\d+)$') {
                        [string] $action = $Matches[1]
                        [int]    $idx    = [int] $Matches[2] - 1

                        if ($idx -lt 0 -or $idx -ge $startupEntries.Count) {
                            Write-Host '  Numero fuera de rango.' -ForegroundColor Red
                            Start-Sleep -Milliseconds 700
                            continue startupLoop
                        }

                        $target  = $startupEntries[$idx]
                        [bool] $setEnabled = ($action -eq 'e')

                        $sr = Set-StartupEntry -Entry $target -Enabled $setEnabled

                        if ($sr.Success) {
                            if ($sr.PSObject.Properties['AlreadySet'] -and $sr.AlreadySet) {
                                Write-Host ('  Ya estaba en ese estado: {0}' -f $target.Name) -ForegroundColor DarkGray
                            } else {
                                [string] $verb = if ($setEnabled) { 'habilitada' } else { 'deshabilitada' }
                                Write-Host ('  [OK] {0} {1}.' -f $target.Name, $verb) -ForegroundColor Green
                            }
                        } else {
                            Write-Host ('  [!] Error: {0}' -f $sr.Error) -ForegroundColor Red
                        }

                        Start-Sleep -Milliseconds 900
                        continue startupLoop
                    }

                    Write-Host '  Opcion no valida.' -ForegroundColor Red
                    Start-Sleep -Milliseconds 700
                }
            }
            '15' {
                :wuLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '      ACTUALIZACIONES DE WINDOWS                ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''

                    # Fechas de ultima instalacion y revision desde registro
                    [string] $lastInstall = 'Desconocida'
                    [string] $lastCheck   = 'Desconocida'
                    try {
                        $regInstall = Get-ItemProperty `
                            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' `
                            -ErrorAction SilentlyContinue
                        if ($regInstall -and $regInstall.PSObject.Properties['LastSuccessTime']) {
                            $lastInstall = $regInstall.LastSuccessTime
                        }
                        $regCheck = Get-ItemProperty `
                            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect' `
                            -ErrorAction SilentlyContinue
                        if ($regCheck -and $regCheck.PSObject.Properties['LastSuccessTime']) {
                            $lastCheck = $regCheck.LastSuccessTime
                        }
                    } catch { }

                    [string] $installColor = if ($lastInstall -eq 'Desconocida') { 'DarkGray' } else { 'White' }
                    Write-Host ('  Ultima actualizacion instalada : {0}' -f $lastInstall) -ForegroundColor $installColor
                    Write-Host ('  Ultima busqueda de updates     : {0}' -f $lastCheck)   -ForegroundColor DarkGray
                    Write-Host ''

                    # Ultimos KBs via CIM (rapido, no requiere privilegios)
                    [object[]] $recentKBs = @(
                        Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSObject.Properties['InstalledOn'] -and $_.InstalledOn } |
                            Sort-Object InstalledOn -Descending |
                            Select-Object -First 5
                    )

                    if ($recentKBs.Count -gt 0) {
                        Write-Host '  Ultimas actualizaciones instaladas:' -ForegroundColor DarkCyan
                        Write-Host ('  {0,-12} {1,-14} {2}' -f 'Fecha', 'KB', 'Descripcion') -ForegroundColor DarkCyan
                        Write-Host ('  {0}' -f ('-' * 55)) -ForegroundColor DarkCyan
                        foreach ($kb in $recentKBs) {
                            [string] $kbDate = try { $kb.InstalledOn.ToString('yyyy-MM-dd') } catch { '?' }
                            Write-Host ('  {0,-12} {1,-14} {2}' -f $kbDate, $kb.HotFixID, $kb.Description) -ForegroundColor DarkGray
                        }
                        Write-Host ''
                    } else {
                        Write-Host '  Sin historial de KBs disponible via CIM.' -ForegroundColor DarkGray
                        Write-Host ''
                    }

                    Write-Host '  [Enter]  Abrir Windows Update en Configuracion' -ForegroundColor Cyan
                    Write-Host '  [q]      Volver' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $wuChoice = (Read-Host '  Selecciona').Trim().ToLower()

                    if ($wuChoice -eq 'q') { break wuLoop }

                    Write-Host "`n  Abriendo Windows Update..." -ForegroundColor Cyan
                    Start-Process 'ms-settings:windowsupdate'
                    Start-Sleep -Milliseconds 800
                    break wuLoop
                }
            }
            'q' {
                Write-Host "`n  Hasta luego." -ForegroundColor Gray
                break mainLoop
            }
            't' {
                [string] $manifestPath = Join-Path $PSScriptRoot 'tools\manifest.json'
                [string] $binDir       = Join-Path $PSScriptRoot 'tools\bin'

                if (-not (Test-Path $manifestPath)) {
                    Write-Host '  [!] tools\manifest.json no encontrado.' -ForegroundColor Red
                    break
                }

                :toolsLoop while ($true) {
                    Clear-Host
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host '        HERRAMIENTAS EXTERNAS                   ' -ForegroundColor Cyan
                    Write-Host '================================================' -ForegroundColor DarkCyan
                    Write-Host ''

                    $mf    = Get-Content $manifestPath -Raw | ConvertFrom-Json
                    [object[]] $allTools = @($mf.tools)

                    # Calcular estado de cada herramienta
                    [PSCustomObject[]] $toolRows = @($allTools | ForEach-Object {
                        $t = $_
                        [bool] $installed = if (
                            $t.PSObject.Properties['extractDir'] -and
                            -not [string]::IsNullOrWhiteSpace($t.extractDir)
                        ) {
                            Test-Path (Join-Path $binDir $t.extractDir)
                        } else {
                            Test-Path (Join-Path $binDir $t.filename)
                        }
                        [PSCustomObject]@{ Tool = $t; Installed = $installed }
                    })

                    # Numerar despues de construir el array
                    for ([int] $ri = 0; $ri -lt $toolRows.Count; $ri++) {
                        $toolRows[$ri] | Add-Member -NotePropertyName Index -NotePropertyValue ($ri + 1) -Force
                    }

                    [int] $installedCount = @($toolRows | Where-Object { $_.Installed }).Count
                    Write-Host ('  {0}/{1} herramientas descargadas.' -f $installedCount, $toolRows.Count) -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host ('  {0,-6} {1,-4} {2,-12} {3,-16} {4,-7} {5}' -f 'Estado', '#', 'Categoria', 'Nombre', 'Peso', 'Descripcion corta') -ForegroundColor DarkCyan
                    Write-Host ('  {0}' -f ('-' * 90)) -ForegroundColor DarkCyan

                    [string] $lastCat = ''
                    foreach ($row in $toolRows) {
                        [string] $cat = if ($row.Tool.PSObject.Properties['category']) { $row.Tool.category } else { '---' }
                        if ($cat -ne $lastCat) {
                            if ($lastCat -ne '') { Write-Host '' }
                            $lastCat = $cat
                        }
                        [string] $icon  = if ($row.Installed) { '[OK] ' } else { '[--] ' }
                        [string] $color = if ($row.Installed) { 'Green' } else { 'DarkGray' }
                        [string] $sizeStr = if ($row.Tool.PSObject.Properties['approxSizeMB'] -and $row.Tool.approxSizeMB) {
                            '~{0}MB' -f $row.Tool.approxSizeMB
                        } else { '---' }
                        # Descripcion corta: hasta el primer guion largo
                        [string] $fullDesc = $row.Tool.description
                        [string] $shortDesc = if ($fullDesc -match '^([^-]+)-') { $Matches[1].Trim() } else { $fullDesc }
                        if ($shortDesc.Length -gt 48) { $shortDesc = $shortDesc.Substring(0, 46) + '...' }
                        Write-Host ('  {0,-6} {1,-4} {2,-12} {3,-16} {4,-7} {5}' -f $icon, $row.Index, $cat, $row.Tool.name, $sizeStr, $shortDesc) -ForegroundColor $color
                    }

                    Write-Host ''
                    Write-Host '  [numero]    Abrir herramienta (requiere estar descargada)' -ForegroundColor DarkGray
                    Write-Host '  [D numero]  Descargar herramienta especifica'              -ForegroundColor DarkGray
                    Write-Host '  [DA]        Descargar todas las faltantes'                -ForegroundColor DarkGray
                    Write-Host '  [q]         Volver'                                       -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '================================================' -ForegroundColor DarkCyan

                    [string] $tc = (Read-Host '  Selecciona').Trim().ToLower()

                    if ($tc -eq 'q' -or [string]::IsNullOrWhiteSpace($tc)) { break toolsLoop }

                    # [DA] — descargar todas las faltantes
                    if ($tc -eq 'da') {
                        [PSCustomObject[]] $missing = @($toolRows | Where-Object { -not $_.Installed })
                        if ($missing.Count -eq 0) {
                            Write-Host '`n  Todas las herramientas ya estan descargadas.' -ForegroundColor Green
                            Start-Sleep -Milliseconds 1200
                        } else {
                            foreach ($row in $missing) {
                                Write-Host ("`n  [{0}/{1}] Descargando: {2}" -f ($missing.IndexOf($row) + 1), $missing.Count, $row.Tool.name) -ForegroundColor Cyan
                                & (Join-Path $PSScriptRoot 'Bootstrap-Tools.ps1') -ToolName $row.Tool.name
                            }
                            Write-Host ''
                            Read-Host '  Presione Enter para continuar'
                        }
                        continue toolsLoop
                    }

                    # [D numero] — descargar una especifica
                    if ($tc -match '^d\s*(\d+)$') {
                        [int] $didx = [int]$Matches[1]
                        [PSCustomObject] $drow = $toolRows | Where-Object { $_.Index -eq $didx } | Select-Object -First 1
                        if (-not $drow) {
                            Write-Host '  Numero invalido.' -ForegroundColor Red ; Start-Sleep -Milliseconds 700 ; continue toolsLoop
                        }
                        Write-Host ("`n  Descargando: {0}..." -f $drow.Tool.name) -ForegroundColor Cyan
                        & (Join-Path $PSScriptRoot 'Bootstrap-Tools.ps1') -ToolName $drow.Tool.name -Force
                        Write-Host ''
                        Read-Host '  Presione Enter para continuar'
                        continue toolsLoop
                    }

                    # [numero] — abrir herramienta
                    if ($tc -match '^\d+$') {
                        [int] $oidx = [int]$tc
                        [PSCustomObject] $orow = $toolRows | Where-Object { $_.Index -eq $oidx } | Select-Object -First 1
                        if (-not $orow) {
                            Write-Host '  Numero invalido.' -ForegroundColor Red ; Start-Sleep -Milliseconds 700 ; continue toolsLoop
                        }
                        if (-not $orow.Installed) {
                            Write-Host ('  {0} no esta descargado. Usa [D {1}] para descargarlo.' -f $orow.Tool.name, $oidx) -ForegroundColor Yellow
                            Start-Sleep -Milliseconds 1200
                            continue toolsLoop
                        }

                        [string] $exeRel = if (
                            $orow.Tool.PSObject.Properties['launchExe'] -and
                            -not [string]::IsNullOrWhiteSpace($orow.Tool.launchExe)
                        ) { $orow.Tool.launchExe } else { $orow.Tool.filename }

                        [string] $exePath = Join-Path $binDir $exeRel

                        if (-not (Test-Path $exePath)) {
                            Write-Host ('  Ejecutable no encontrado: {0}' -f $exePath) -ForegroundColor Red
                            Start-Sleep -Milliseconds 1200 ; continue toolsLoop
                        }

                        Write-Host ("  Abriendo {0}..." -f $orow.Tool.name) -ForegroundColor Cyan
                        Start-Process -FilePath $exePath
                        Start-Sleep -Milliseconds 600
                        continue toolsLoop
                    }

                    Write-Host '  Opcion no valida.' -ForegroundColor Red
                    Start-Sleep -Milliseconds 700
                }
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