#Requires -Version 5.1
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Descarga y verifica las herramientas externas declaradas en tools/manifest.json.
    Los binarios se almacenan en tools/bin/ (excluido de git por .gitignore).
.EXAMPLE
    .\Bootstrap-Tools.ps1                      # descarga todas
    .\Bootstrap-Tools.ps1 -ToolName shutup10   # descarga solo una
    .\Bootstrap-Tools.ps1 -Force               # re-descarga aunque ya existan
#>

[CmdletBinding()]
param(
    [switch] $Force,
    [string] $ToolName = ''
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

# Filtrar por -ToolName si se especifico
[object[]] $toolsToProcess = if (-not [string]::IsNullOrWhiteSpace($ToolName)) {
    $filtered = @($manifest.tools | Where-Object { $_.name -eq $ToolName })
    if ($filtered.Count -eq 0) {
        Write-Error "Herramienta '$ToolName' no encontrada en manifest.json"
        exit 1
    }
    $filtered
} else {
    @($manifest.tools)
}

# ─── Descarga con barra de progreso ──────────────────────────────────────────
function Invoke-ToolDownload {
    [CmdletBinding()]
    param(
        [string] $Url,
        [string] $Dest,
        [string] $DisplayName
    )

    $request            = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $request.Timeout    = 30000

    $response   = $request.GetResponse()
    [long] $total = $response.ContentLength
    $netStream  = $response.GetResponseStream()
    $fileStream = [System.IO.FileStream]::new($Dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $buffer     = [byte[]]::new(65536)
    [long] $recv = 0

    try {
        while (($read = $netStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $recv += $read
            if ($total -gt 0) {
                [int] $pct = [int](($recv / $total) * 100)
                Write-Progress -Activity "Descargando $DisplayName" `
                               -PercentComplete $pct `
                               -Status ('{0:N1} / {1:N1} MB' -f ($recv / 1MB), ($total / 1MB))
            } else {
                Write-Progress -Activity "Descargando $DisplayName" `
                               -PercentComplete 0 `
                               -Status ('{0:N1} MB...' -f ($recv / 1MB))
            }
        }
    }
    finally {
        $fileStream.Dispose()
        $netStream.Dispose()
        $response.Dispose()
        Write-Progress -Activity "Descargando $DisplayName" -Completed
    }
}

# ─── Verificar si una herramienta ya esta instalada ──────────────────────────
function Test-ToolInstalled {
    param([object] $Tool)
    $isZip = ($Tool.PSObject.Properties['type'] -and $Tool.type -eq 'zip') -or
             ($Tool.filename -like '*.zip')
    if ($isZip -and $Tool.PSObject.Properties['extractDir'] -and $Tool.extractDir) {
        return Test-Path (Join-Path $binDir $Tool.extractDir)
    }
    return Test-Path (Join-Path $binDir $Tool.filename)
}

# ─── Proceso principal ────────────────────────────────────────────────────────
[int] $ok      = 0
[int] $skipped = 0
[int] $failed  = 0

foreach ($tool in $toolsToProcess) {
    [bool] $isZip = ($tool.PSObject.Properties['type'] -and $tool.type -eq 'zip') -or
                    ($tool.filename -like '*.zip')

    # Chequeo "ya existe"
    if (-not $Force -and (Test-ToolInstalled -Tool $tool)) {
        Write-Host ("  [=] {0,-16} ya esta descargado, omitiendo." -f $tool.name) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    Write-Host ("  [+] Descargando {0}..." -f $tool.name) -ForegroundColor Cyan

    [string] $destFile = Join-Path $binDir $tool.filename

    try {
        Invoke-ToolDownload -Url $tool.url -Dest $destFile -DisplayName $tool.name
    }
    catch {
        Write-Host ("  [!] Error al descargar {0}: {1}" -f $tool.name, $_.Exception.Message) -ForegroundColor Red
        if (Test-Path $destFile) { Remove-Item $destFile -Force }
        $failed++
        continue
    }

    # Verificar SHA-256 si el manifest lo define
    if (-not [string]::IsNullOrWhiteSpace($tool.sha256)) {
        [string] $actual = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
        if ($actual -ne $tool.sha256.ToUpper()) {
            Write-Host ("  [!] {0}: hash no coincide. Esperado: {1}  Obtenido: {2}" -f $tool.name, $tool.sha256.ToUpper(), $actual) -ForegroundColor Red
            Remove-Item $destFile -Force
            $failed++
            continue
        }
        Write-Host ("  [v] {0}: hash OK" -f $tool.name) -ForegroundColor Green
    }

    # Extraer ZIP si corresponde
    if ($isZip) {
        [string] $extractDir = if ($tool.PSObject.Properties['extractDir'] -and $tool.extractDir) {
            Join-Path $binDir $tool.extractDir
        } else {
            $binDir
        }

        Write-Host ("  [~] Extrayendo {0}..." -f $tool.name) -ForegroundColor Cyan
        try {
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            Expand-Archive -Path $destFile -DestinationPath $extractDir -Force
            Remove-Item $destFile -Force   # limpiar el zip
            Write-Host ("  [v] {0}: extraido en {1}" -f $tool.name, $extractDir) -ForegroundColor Green
        }
        catch {
            Write-Host ("  [!] Error al extraer {0}: {1}" -f $tool.name, $_.Exception.Message) -ForegroundColor Red
            $failed++
            continue
        }
    } else {
        Write-Host ("  [v] {0}: descargado" -f $tool.name) -ForegroundColor $(if ($tool.sha256) { 'Green' } else { 'Yellow' })
    }

    $ok++
}

Write-Host ''
Write-Host ("  Resultado: {0} descargado(s), {1} omitido(s), {2} fallido(s)." -f $ok, $skipped, $failed) `
           -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("  Binarios en: {0}" -f $binDir) -ForegroundColor DarkGray
