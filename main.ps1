#Requires -Version 5.1
Set-StrictMode -Version Latest

foreach ($folder in @('core', 'modules')) {
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
                Write-Host "`n  Iniciando limpieza de temporales..." -ForegroundColor Cyan
                $job    = Start-CleanupProcess
                $result = Wait-ToolkitJobs -Jobs @($job)

                [string]$freed = if ($result.FreedGB -ge 1) {
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
                Clear-Host
                Write-Host '================================================' -ForegroundColor DarkCyan
                Write-Host '               GUIA TECNICA DE RED              ' -ForegroundColor Cyan
                Write-Host '================================================' -ForegroundColor DarkCyan
                Write-Host ''
                Write-Host ' 1. Ahorro de Energia: SIEMPRE APAGAR.' -ForegroundColor White
                Write-Host '    Evita micro-cortes y latencia en Wi-Fi/Ethernet.' -ForegroundColor Gray
                Write-Host ''
                Write-Host ' 2. TCP Auto-Tuning (Normal): RECOMENDADO.' -ForegroundColor White
                Write-Host '    Mantiene el ancho de banda maximo en planes de 300MB+.' -ForegroundColor Gray
                Write-Host ''
                Write-Host ' 3. DNS Flush: UTIL.' -ForegroundColor White
                Write-Host '    Limpia rutas viejas o errores de "Sin Internet".' -ForegroundColor Gray
                Write-Host ''
                Write-Host ' 4. Interrupt Moderation: SOLO GAMING EXTREMO.' -ForegroundColor White
                Write-Host '    Baja el ping pero sube el uso de CPU. (No incluido en Auto).' -ForegroundColor Gray
                Write-Host ''
                Write-Host '================================================' -ForegroundColor DarkCyan
                
                $confirm = Read-Host '  ¿Aplicar optimizacion estandar? (s/n)'
                if ($confirm.ToLower() -eq 's') {
                    Write-Host "`n  Optimizando stack de red..." -ForegroundColor Cyan
                    $job    = Start-NetworkProcess
                    $result = Wait-ToolkitJobs -Jobs @($job)
                    
                    Write-Host "`n  Resultado:" -ForegroundColor Green
                    foreach ($adapter in $result.AdaptersOptimized) {
                        Write-Host "    [OK] $adapter" -ForegroundColor Gray
                    }
                    Write-Host "  TCP Global Settings y DNS: OK" -ForegroundColor Gray
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