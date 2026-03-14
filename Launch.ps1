#Requires -Version 5.1
Set-StrictMode -Version Latest

# ── CONFIGURAR ANTES DE USAR ──────────────────────────────────────────────────
[string] $GitHubRepo  = 'mvillanueva988/ServiceKit-Public'
[string] $InstallPath = 'C:\PCTk'
# ─────────────────────────────────────────────────────────────────────────────

# ── Pre-flight: validar que el repo fue configurado ───────────────────────────
if ($GitHubRepo -match 'TU_' -or $GitHubRepo -eq '') {
    Write-Host ''
    Write-Host '  [!] Launch.ps1 no esta configurado.' -ForegroundColor Red
    Write-Host '      Edita Launch.ps1 y reemplaza $GitHubRepo con tu repositorio.' -ForegroundColor DarkGray
    Write-Host '      Ejemplo: $GitHubRepo = "tu-usuario/pc-toolkit"' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Presiona Enter para salir'
    exit 1
}
# ─────────────────────────────────────────────────────────────────────────────

[string] $zipDest     = Join-Path $env:TEMP 'PCTk-update.zip'
[string] $shaDest     = Join-Path $env:TEMP 'PCTk-update.zip.sha256'
[string] $toolsBinSrc = Join-Path $InstallPath 'tools\bin'
[string] $toolsBinBak = Join-Path $env:TEMP   'PCTk-toolsbin-backup'

# Forzar TLS 1.2 antes de cualquier llamada de red (Windows 7/8 defaultean a TLS 1.0)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ExpectedSha256FromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) { return '' }

    [string] $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

    [string] $trimmed = $raw.Trim()
    if ($trimmed -match '([A-Fa-f0-9]{64})') {
        return $Matches[1].ToUpperInvariant()
    }

    return ''
}

function Invoke-ToolkitMain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) {
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path
}

function Invoke-Launch {
    # ── Intentar descarga desde GitHub Releases ───────────────────────────────
    [string] $downloadUrl = ''
    [string] $shaUrl      = ''
    [string] $zipName     = ''
    try {
        [string] $apiUrl  = "https://api.github.com/repos/$GitHubRepo/releases/latest"
        $release          = Invoke-RestMethod -Uri $apiUrl -UserAgent 'PCTk-Launcher' -ErrorAction Stop
        $asset            = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($null -eq $asset) { throw 'No ZIP asset found in latest release.' }
        $downloadUrl      = $asset.browser_download_url
        $zipName          = [string] $asset.name

        $shaAsset         = $release.assets | Where-Object { $_.name -eq ($zipName + '.sha256') } | Select-Object -First 1
        if ($null -eq $shaAsset) { throw 'No SHA-256 asset found for ZIP release.' }
        $shaUrl = $shaAsset.browser_download_url
    }
    catch {
        # Fallback: si ya hay versión local, usarla
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] No se pudo descargar actualizacion. Lanzando version local...' -ForegroundColor Yellow
            Invoke-ToolkitMain -Path (Join-Path $InstallPath 'main.ps1')
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
        Invoke-WebRequest -Uri $shaUrl -OutFile $shaDest -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    }
    catch {
        Write-Host "  [!] Error al descargar: $($_.Exception.Message)" -ForegroundColor Red
        # Intentar fallback local
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] Lanzando version local...' -ForegroundColor Yellow
            Invoke-ToolkitMain -Path (Join-Path $InstallPath 'main.ps1')
        }
        else {
            Write-Host '  [!] Sin version local disponible.' -ForegroundColor Red
            Write-Host "      https://github.com/$GitHubRepo/releases" -ForegroundColor DarkGray
        }
        return
    }

    # ── Verificar SHA-256 del ZIP ─────────────────────────────────────────────
    [string] $expectedSha = Get-ExpectedSha256FromFile -Path $shaDest
    [string] $actualSha   = (Get-FileHash -Path $zipDest -Algorithm SHA256).Hash.ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($expectedSha)) {
        Write-Host '  [!] Checksum SHA-256 invalido o vacio.' -ForegroundColor Red
        if (Test-Path $zipDest) { Remove-Item $zipDest -Force }
        if (Test-Path $shaDest) { Remove-Item $shaDest -Force }
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] Lanzando version local...' -ForegroundColor Yellow
            Invoke-ToolkitMain -Path (Join-Path $InstallPath 'main.ps1')
        }
        return
    }

    if ($expectedSha -ne $actualSha) {
        Write-Host '  [!] Checksum SHA-256 no coincide. Se cancela la instalacion.' -ForegroundColor Red
        Write-Host ("      Esperado: {0}" -f $expectedSha) -ForegroundColor DarkGray
        Write-Host ("      Obtenido: {0}" -f $actualSha) -ForegroundColor DarkGray
        if (Test-Path $zipDest) { Remove-Item $zipDest -Force }
        if (Test-Path $shaDest) { Remove-Item $shaDest -Force }
        if (Test-Path (Join-Path $InstallPath 'main.ps1')) {
            Write-Host '  [!] Lanzando version local...' -ForegroundColor Yellow
            Invoke-ToolkitMain -Path (Join-Path $InstallPath 'main.ps1')
        }
        return
    }

    if (Test-Path $shaDest) { Remove-Item $shaDest -Force }

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
    Invoke-ToolkitMain -Path (Join-Path $InstallPath 'main.ps1')
}

Invoke-Launch
