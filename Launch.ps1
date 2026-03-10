#Requires -Version 5.1
Set-StrictMode -Version Latest

# ── CONFIGURAR ANTES DE USAR ──────────────────────────────────────────────────
[string] $GitHubRepo  = 'TU_USUARIO/TU_REPO'   # <-- cambiar esto
[string] $InstallPath = 'C:\PCTk'
# ─────────────────────────────────────────────────────────────────────────────

[string] $zipDest     = Join-Path $env:TEMP 'PCTk-update.zip'
[string] $toolsBinSrc = Join-Path $InstallPath 'tools\bin'
[string] $toolsBinBak = Join-Path $env:TEMP   'PCTk-toolsbin-backup'

# Forzar TLS 1.2 antes de cualquier llamada de red (Windows 7/8 defaultean a TLS 1.0)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Invoke-Launch {
    # ── Intentar descarga desde GitHub Releases ───────────────────────────────
    [string] $downloadUrl = ''
    try {
        [string] $apiUrl  = "https://api.github.com/repos/$GitHubRepo/releases/latest"
        $release          = Invoke-RestMethod -Uri $apiUrl -UserAgent 'PCTk-Launcher' -ErrorAction Stop
        $asset            = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($null -eq $asset) { throw 'No ZIP asset found in latest release.' }
        $downloadUrl      = $asset.browser_download_url
    }
    catch {
        # Fallback: si ya hay versión local, usarla
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] No se pudo descargar actualizacion. Lanzando version local...' -ForegroundColor Yellow
            & (Join-Path $InstallPath 'main.ps1')
            return
        }
        # Error fatal: sin internet y sin versión local
        Write-Host '  [!] Sin conexion y sin version local. Descarga el toolkit manualmente.' -ForegroundColor Red
        Write-Host "      https://github.com/$GitHubRepo/releases" -ForegroundColor DarkGray
        return
    }

    # ── Descargar ZIP ─────────────────────────────────────────────────────────
    Write-Host '  Descargando toolkit...' -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipDest -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    }
    catch {
        Write-Host "  [!] Error al descargar: $($_.Exception.Message)" -ForegroundColor Red
        # Intentar fallback local
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] Lanzando version local...' -ForegroundColor Yellow
            & (Join-Path $InstallPath 'main.ps1')
        }
        else {
            Write-Host '  [!] Sin version local disponible.' -ForegroundColor Red
            Write-Host "      https://github.com/$GitHubRepo/releases" -ForegroundColor DarkGray
        }
        return
    }

    # ── Preservar tools\bin\ ──────────────────────────────────────────────────
    [bool] $hadToolsBin = $false
    if (Test-Path $toolsBinSrc) {
        if (Test-Path $toolsBinBak) { Remove-Item $toolsBinBak -Recurse -Force }
        Move-Item -Path $toolsBinSrc -Destination $toolsBinBak
        $hadToolsBin = $true
    }

    # ── Extraer ZIP ───────────────────────────────────────────────────────────
    Write-Host '  Instalando...' -ForegroundColor Cyan
    if (Test-Path $InstallPath) { Remove-Item $InstallPath -Recurse -Force }
    Expand-Archive -Path $zipDest -DestinationPath $InstallPath -Force
    Remove-Item $zipDest -Force

    # ── Restaurar tools\bin\ ──────────────────────────────────────────────────
    if ($hadToolsBin -and (Test-Path $toolsBinBak)) {
        [string] $toolsBinTarget = Join-Path $InstallPath 'tools\bin'
        if (-not (Test-Path (Join-Path $InstallPath 'tools'))) {
            New-Item -ItemType Directory -Path (Join-Path $InstallPath 'tools') | Out-Null
        }
        Move-Item -Path $toolsBinBak -Destination $toolsBinTarget
    }

    # ── Lanzar ───────────────────────────────────────────────────────────────
    Write-Host '  Listo.' -ForegroundColor Green
    & (Join-Path $InstallPath 'main.ps1')
}

Invoke-Launch
