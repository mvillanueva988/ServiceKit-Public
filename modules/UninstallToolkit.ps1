Set-StrictMode -Version Latest

# --- New-PctkUninstallScript ---------------------------------------------------
# Devuelve el texto del script de limpieza desprendido como [string].
# Funcion PURA: no escribe, no ejecuta, no spawnea nada.
# El handler Invoke-UninstallToolkit es quien escribe el texto a disco y lanza.
function New-PctkUninstallScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [Parameter(Mandatory)] [int]    $PctkPid
    )

    return @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'

# Esperar a que PCTk (PID $PctkPid) termine (max 30s)
`$waited = 0
while (`$waited -lt 30) {
    if (`$null -eq (Get-Process -Id $PctkPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
    `$waited++
}

# Borrar root de instalacion
Remove-Item -LiteralPath '$InstallRoot' -Recurse -Force -ErrorAction SilentlyContinue

# Borrar artefactos temporales PCTk-*
Get-ChildItem -Path `$env:TEMP -Filter 'PCTk-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Auto-borrar este script
Start-Sleep -Seconds 1
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@
}

# --- Invoke-UninstallToolkit --------------------------------------------------
# Handler del menu [U]. Devuelve $true si el deleter fue spawneado (el caller
# debe salir inmediatamente). Devuelve $false si fue cancelado o fallo (continuar
# en el menu sin borrar nada).
function Invoke-UninstallToolkit {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Resolver root: mismo idiom que Show-ToolsMenu / Invoke-ActionDriverBackup.
    # Este modulo vive en <root>\modules\, asi que $PSScriptRoot = <root>\modules
    # y Split-Path -Parent da <root>.
    [string] $installRoot = Split-Path -Parent $PSScriptRoot

    # Guard obligatorio (ss 6.2): verificar que el root parece una instalacion PCTk
    # antes de generar cualquier Remove-Item -Recurse -Force.
    if (-not (Test-Path (Join-Path $installRoot 'main.ps1') -PathType Leaf) -or
        -not (Test-Path (Join-Path $installRoot 'core\Router.ps1') -PathType Leaf)) {
        Write-Host '  [!] No se pudo validar la instalacion de PCTk.' -ForegroundColor Red
        Write-Host ("      Ruta resuelta: {0}" -f $installRoot) -ForegroundColor DarkGray
        Write-Host '  Abortando sin borrar nada.' -ForegroundColor DarkGray
        return $false
    }

    # Primera confirmacion (ss 6.3): DefaultYes:$false = Enter aborta.
    if (-not (Confirm-Action -Title 'DESINSTALAR PCTk de esta PC?' -Lines @(
        ('Instalacion : {0}' -f $installRoot),
        ('Temporales  : {0}\PCTk-*' -f $env:TEMP),
        'El historial de clientes (output\clients\) se puede copiar antes.',
        'ESTA ACCION ES IRREVERSIBLE.'
    ) -DefaultYes:$false)) {
        Write-Host '  Desinstalacion cancelada.' -ForegroundColor DarkGray
        return $false
    }

    # Segunda confirmacion (ss 6.3): tipear BORRAR exacto.
    Write-Host ''
    Write-Host '  Para confirmar, escribe exactamente: BORRAR' -ForegroundColor Yellow
    [string] $gate2 = (Read-Host '  >').Trim().ToUpperInvariant()
    if ($gate2 -ne 'BORRAR') {
        Write-Host '  Desinstalacion cancelada.' -ForegroundColor DarkGray
        return $false
    }

    # Preservar output\clients\ fuera del root ANTES de borrar.
    [string] $clientsDir  = Join-Path $installRoot 'output\clients'
    [string] $preserveDest = ''
    if (Test-Path $clientsDir -PathType Container) {
        [string] $defaultDest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PCTk-historial-clientes'
        Write-Host ''
        Write-Host ('  Historial de clientes: {0}' -f $clientsDir) -ForegroundColor Cyan
        [string] $rawDest = (Read-Host ("  Ruta de copia (Enter = {0})" -f $defaultDest)).Trim()
        $preserveDest = if ([string]::IsNullOrWhiteSpace($rawDest)) { $defaultDest } else { $rawDest }

        try {
            if (Test-Path $preserveDest) { Remove-Item $preserveDest -Recurse -Force }
            Copy-Item -Path $clientsDir -Destination $preserveDest -Recurse -Force
            Write-Host ('  [OK] Historial copiado a: {0}' -f $preserveDest) -ForegroundColor Green
        } catch {
            Write-Host ('  [!] No se pudo copiar el historial: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Abortando sin borrar nada.' -ForegroundColor DarkGray
            return $false
        }
    }

    # Generar el script desprendido (funcion pura, sin side-effects).
    [string] $ts          = (Get-Date -Format 'yyyyMMdd-HHmmss')
    [string] $deleterPath = Join-Path $env:TEMP ('pctk-uninstall-' + $ts + '.ps1')
    [string] $deleterText = New-PctkUninstallScript -InstallRoot $installRoot -PctkPid $PID

    # Escribir el script a disco.
    try {
        [System.IO.File]::WriteAllText($deleterPath, $deleterText, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Host ('  [!] No se pudo crear el script de desinstalacion: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host '  Abortando sin borrar nada.' -ForegroundColor DarkGray
        return $false
    }

    # Lanzar detached: Hidden, fuera del proceso PCTk, sin bloquear.
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-NonInteractive', '-File', $deleterPath
        ) -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-Host ('  [!] No se pudo lanzar el desinstalador: {0}' -f $_.Exception.Message) -ForegroundColor Red
        if (Test-Path $deleterPath) { Remove-Item $deleterPath -Force -ErrorAction SilentlyContinue }
        return $false
    }

    # Audit escrita ANTES de copiar output\audit\ para que Toolkit.Uninstall
    # quede incluida en el export (si no se preservo, queda solo en el root borrado).
    [string] $auditSummary = if ([string]::IsNullOrWhiteSpace($preserveDest)) { 'sin preservar' } else { $preserveDest }
    Write-ActionAudit -Action 'Toolkit.Uninstall' -Status 'Started' -Summary $auditSummary

    # Preservar output\audit\ al mismo destino que clients (misma logica condicional).
    # El deleter ya fue lanzado: si falla el copy, avisar pero no abortar.
    if (-not [string]::IsNullOrWhiteSpace($preserveDest)) {
        [string] $auditDir = Join-Path $installRoot 'output\audit'
        if (Test-Path $auditDir -PathType Container) {
            try {
                [string] $auditExportDest = Join-Path $preserveDest 'audit'
                Copy-Item -Path $auditDir -Destination $auditExportDest -Recurse -Force
                Write-Host ('  [OK] Audit copiado a: {0}' -f $auditExportDest) -ForegroundColor Green
            } catch {
                Write-Host ('  [!] No se pudo copiar el audit: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''
    Write-Host '  PCTk cerrara ahora. El desinstalador borrara la carpeta en segundo plano.' -ForegroundColor Yellow
    return $true
}
