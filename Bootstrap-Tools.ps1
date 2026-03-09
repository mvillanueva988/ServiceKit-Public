#Requires -Version 5.1
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Descarga y verifica las herramientas externas declaradas en tools/manifest.json.
    Ejecutar una sola vez al configurar el toolkit en una maquina nueva.
    Los binarios se almacenan en tools/bin/ (excluido de git por .gitignore).
.EXAMPLE
    .\Bootstrap-Tools.ps1
    .\Bootstrap-Tools.ps1 -Force   # Re-descarga aunque ya existan
#>

[CmdletBinding()]
param(
    [switch] $Force
)

[string] $manifestPath = Join-Path $PSScriptRoot 'tools\manifest.json'
[string] $binDir       = Join-Path $PSScriptRoot 'tools\bin'

if (-not (Test-Path $manifestPath)) {
    Write-Error "No se encontro tools\manifest.json en $PSScriptRoot"
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

if (-not (Test-Path $binDir)) {
    [void] (New-Item -ItemType Directory -Path $binDir)
}

[int] $ok      = 0
[int] $skipped = 0
[int] $failed  = 0

foreach ($tool in $manifest.tools) {
    [string] $dest = Join-Path $binDir $tool.filename

    if ((Test-Path $dest) -and -not $Force) {
        Write-Host ("  [=] {0,-20} ya existe, omitiendo." -f $tool.name) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host ("  [+] Descargando {0}..." -f $tool.name) -ForegroundColor Cyan
    try {
        [System.Net.WebClient] $wc = [System.Net.WebClient]::new()
        $wc.DownloadFile($tool.url, $dest)
        $wc.Dispose()
    }
    catch {
        Write-Host ("  [!] Error al descargar {0}: {1}" -f $tool.name, $_.Exception.Message) -ForegroundColor Red
        $failed++
        continue
    }

    # Verificar SHA-256 si el manifest lo define
    if (-not [string]::IsNullOrWhiteSpace($tool.sha256)) {
        [string] $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
        if ($actual -ne $tool.sha256.ToUpper()) {
            Write-Host ("  [!] {0}: hash no coincide. Esperado: {1}  Obtenido: {2}" -f $tool.name, $tool.sha256.ToUpper(), $actual) -ForegroundColor Red
            Remove-Item $dest -Force
            $failed++
            continue
        }
        Write-Host ("  [v] {0}: hash OK" -f $tool.name) -ForegroundColor Green
    }
    else {
        Write-Host ("  [v] {0}: descargado (sin verificacion de hash)" -f $tool.name) -ForegroundColor Yellow
    }
    $ok++
}

Write-Host ''
Write-Host ("  Resultado: {0} descargados, {1} omitidos, {2} fallidos." -f $ok, $skipped, $failed) -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("  Binarios en: {0}" -f $binDir) -ForegroundColor DarkGray
