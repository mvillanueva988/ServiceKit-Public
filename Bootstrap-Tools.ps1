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
    .\Bootstrap-Tools.ps1 -RequireHash         # exige SHA-256 en manifest para cada descarga
#>

[CmdletBinding()]
param(
    [switch] $Force,
    [string] $ToolName = '',
    [switch] $RequireHash
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

    if ($isZip) {
        # Para ZIPs, verificar que el launchExe exista dentro del extractDir
        if ($Tool.PSObject.Properties['launchExe'] -and $Tool.launchExe) {
            $launchPath = Join-Path $binDir $Tool.launchExe
            return Test-Path $launchPath
        }
        if ($Tool.PSObject.Properties['extractDir'] -and $Tool.extractDir) {
            return Test-Path (Join-Path $binDir $Tool.extractDir)
        }
        # ZIP sin launchExe ni extractDir: el .zip es borrado post-extraccion → asumir no instalado
        return $false
    }

    # Para EXEs: verificar existencia Y tamaño mínimo
    $exePath = Join-Path $binDir $Tool.filename
    if (-not (Test-Path $exePath)) { return $false }

    # Si el manifest declara approxSizeMB, verificar que el archivo tenga al menos 50% de ese tamaño
    if ($Tool.PSObject.Properties['approxSizeMB'] -and $Tool.approxSizeMB -gt 0) {
        [long] $minBytes = [long]($Tool.approxSizeMB * 0.5 * 1MB)
        [long] $actual   = (Get-Item $exePath).Length
        if ($actual -lt $minBytes) {
            Write-Host ("  [!] {0}: archivo incompleto ({1:N1} MB de ~{2} MB esperados), forzando re-descarga" -f `
                $Tool.name, ($actual / 1MB), $Tool.approxSizeMB) -ForegroundColor Yellow
            return $false
        }
    }

    return $true
}

# ─── Proceso principal ────────────────────────────────────────────────────────
[int] $ok      = 0
[int] $skipped = 0
[int] $failed  = 0

foreach ($tool in $toolsToProcess) {
    [bool] $isZip = ($tool.PSObject.Properties['type'] -and $tool.type -eq 'zip') -or
                    ($tool.filename -like '*.zip')

    # Saltar herramientas sin URL configurada (ej: winslop privado)
    if ([string]::IsNullOrWhiteSpace($tool.url)) {
        Write-Host ("  [~] {0,-16} URL no configurada, omitiendo." -f $tool.name) -ForegroundColor DarkGray
        $skipped++
        continue
    }

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
        [string] $expected = $tool.sha256.Trim().ToUpperInvariant()
        [string] $actual = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            Write-Host ("  [!] {0}: hash no coincide. Esperado: {1}  Obtenido: {2}" -f $tool.name, $tool.sha256.ToUpper(), $actual) -ForegroundColor Red
            Remove-Item $destFile -Force
            $failed++
            continue
        }
        Write-Host ("  [v] {0}: hash OK" -f $tool.name) -ForegroundColor Green
    }
    elseif ($RequireHash) {
        Write-Host ("  [!] {0}: hash requerido pero no definido en manifest.json" -f $tool.name) -ForegroundColor Red
        if (Test-Path $destFile) { Remove-Item $destFile -Force }
        $failed++
        continue
    }
    else {
        Write-Host ("  [~] {0}: sin SHA-256 en manifest (descarga no verificada)" -f $tool.name) -ForegroundColor Yellow
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
if ($RequireHash) {
    Write-Host '  Modo estricto SHA-256: activo.' -ForegroundColor DarkGray
}
