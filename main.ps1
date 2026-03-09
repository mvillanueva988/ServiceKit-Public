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
        Write-Host ''
        Write-Host '  [1]  Deshabilitar Servicios Bloat'
        Write-Host '  [2]  Limpieza de Temporales'
        Write-Host '  [3]  Mantenimiento del Sistema (DISM/SFC)'
        Write-Host '  [q]  Salir'
        Write-Host ''
        Write-Host '================================================' -ForegroundColor DarkCyan

        [string]$choice = (Read-Host '  Selecciona una opcion').Trim().ToLower()

        switch ($choice) {
            '1' {
                Write-Host "`n  Iniciando proceso de debloat..." -ForegroundColor Cyan
                $job    = Start-DebloatProcess
                $result = Wait-ToolkitJobs -Jobs @($job)

                if ($result.Disabled -eq 0 -and $result.Failed -eq 0) {
                    Write-Host '  No se encontraron servicios bloat activos.' -ForegroundColor DarkYellow
                } else {
                    Write-Host ("  Servicios deshabilitados : {0}" -f $result.Disabled) -ForegroundColor Green
                    if ($result.Failed -gt 0) {
                        Write-Host ("  Errores                  : {0}" -f $result.Failed) -ForegroundColor Yellow
                        foreach ($err in $result.Errors) {
                            Write-Host ("    - {0}" -f $err) -ForegroundColor DarkYellow
                        }
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