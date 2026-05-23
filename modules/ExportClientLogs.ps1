Set-StrictMode -Version Latest

function Invoke-ExportClientLogs {
    [CmdletBinding()]
    param(
        # Sobreescrito en tests para no tocar la instalacion real
        [Parameter()] [string] $OutputRootOverride = '',
        [Parameter()] [string] $DestDirOverride    = '',
        [Parameter()] [string] $TimestampOverride  = '',
        [Parameter()] [string] $TagOverride        = ''
    )

    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    } else {
        $OutputRootOverride
    }

    # Paso 1: output\ ausente
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        Write-Host '  [!] No hay output\ -- nada que empaquetar.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Logs.Export' -Status 'Empty' -Summary 'output dir missing'
        return [PSCustomObject]@{ Status = 'Empty'; ZipPath = '' }
    }

    # Paso 2: detectar subdirs candidatos (research excluido por decision explicita)
    [string] $auditDir     = Join-Path $outputRoot 'audit'
    [string] $snapshotsDir = Join-Path $outputRoot 'snapshots'

    [bool] $auditOk = (Test-Path -LiteralPath $auditDir -PathType Container) -and
                      ($null -ne (Get-ChildItem -LiteralPath $auditDir -Recurse -File -ErrorAction SilentlyContinue |
                                  Select-Object -First 1))
    [bool] $snapshotsOk = (Test-Path -LiteralPath $snapshotsDir -PathType Container) -and
                          ($null -ne (Get-ChildItem -LiteralPath $snapshotsDir -Recurse -File -ErrorAction SilentlyContinue |
                                      Select-Object -First 1))

    # Paso 3: ninguno poblado
    if (-not $auditOk -and -not $snapshotsOk) {
        Write-Host '  [!] output\ esta vacio -- nada que empaquetar.' -ForegroundColor Yellow
        Write-ActionAudit -Action 'Logs.Export' -Status 'Empty' -Summary 'no populated subdirs'
        return [PSCustomObject]@{ Status = 'Empty'; ZipPath = '' }
    }

    # Paso 4: tag opcional
    [string] $rawTag = if ($PSBoundParameters.ContainsKey('TagOverride')) {
        $TagOverride
    } else {
        (Read-Host '  Tag para el zip (Enter para omitir)').Trim()
    }
    [string] $tag    = $rawTag -replace '[^A-Za-z0-9_-]', ''
    if ($tag.Length -gt 32) { $tag = $tag.Substring(0, 32) }

    # Paso 5: componer nombre
    [string] $hostname = $env:COMPUTERNAME
    [string] $ts       = if ($TimestampOverride) { $TimestampOverride } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    [string] $base     = if ($tag) { '{0}-{1}_{2}' -f $hostname, $tag, $ts }
                         else      { '{0}_{1}'      -f $hostname,      $ts }

    # Paso 6: resolver destino
    [string] $desktop = if (-not [string]::IsNullOrEmpty($DestDirOverride)) {
        $DestDirOverride
    } else {
        [Environment]::GetFolderPath('Desktop')
    }

    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        $desktop = $env:TEMP
        Write-Host ("  [!] Desktop no resoluble -- usando {0}" -f $desktop) -ForegroundColor Yellow
    }

    # Paso 7: manejar colision (cap a 10 intentos)
    [string] $zipPath = Join-Path $desktop "$base.zip"
    if (Test-Path -LiteralPath $zipPath) {
        [int] $suffix = 2
        while ($suffix -le 10) {
            [string] $candidate = Join-Path $desktop ('{0}_{1}.zip' -f $base, $suffix)
            if (-not (Test-Path -LiteralPath $candidate)) {
                $zipPath = $candidate
                break
            }
            $suffix++
        }
    }

    # Paso 8: construir lista de paths (PS5.1: [object[]] inicializado antes de conditionals)
    [object[]] $items = @()
    if ($auditOk)     { $items += $auditDir }
    if ($snapshotsOk) { $items += $snapshotsDir }

    try {
        Compress-Archive -LiteralPath $items -DestinationPath $zipPath -Force -ErrorAction Stop
    } catch {
        [string] $errMsg = $_.Exception.Message
        Write-Host ('  [!] Error al comprimir: {0}' -f $errMsg) -ForegroundColor Red
        Write-ActionAudit -Action 'Logs.Export' -Status 'Failed' -Summary $errMsg
        return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = $errMsg }
    }

    # Paso 9: verificar resultado
    if (-not (Test-Path -LiteralPath $zipPath) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
        [string] $errMsg = 'Zip no fue creado o tiene tamanio cero'
        Write-Host ('  [!] {0}' -f $errMsg) -ForegroundColor Red
        Write-ActionAudit -Action 'Logs.Export' -Status 'Failed' -Summary $errMsg
        return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = $errMsg }
    }

    # Contar archivos incluidos para el reporte
    [object[]] $auditFiles    = @()
    [object[]] $snapshotFiles = @()
    if ($auditOk)     { $auditFiles    = @(Get-ChildItem -LiteralPath $auditDir     -Recurse -File -ErrorAction SilentlyContinue) }
    if ($snapshotsOk) { $snapshotFiles = @(Get-ChildItem -LiteralPath $snapshotsDir -Recurse -File -ErrorAction SilentlyContinue) }
    [long] $totalBytes = (Get-Item -LiteralPath $zipPath).Length
    [int]  $totalFiles = $auditFiles.Count + $snapshotFiles.Count

    # Paso 10: reporte al usuario
    [string] $sizeMb = '{0:0.##}' -f ($totalBytes / 1MB)
    [object[]] $includeLines = @()
    if ($auditOk)     { $includeLines += ('audit ({0} archivos)'     -f $auditFiles.Count) }
    if ($snapshotsOk) { $includeLines += ('snapshots ({0} archivos)' -f $snapshotFiles.Count) }

    Write-Host ''
    Write-Host '  [OK] Logs empaquetados:' -ForegroundColor Green
    Write-Host ('       Archivo : {0}' -f $zipPath)
    Write-Host ('       Tamanio : {0} MB' -f $sizeMb)
    Write-Host ('       Incluye : {0}' -f ($includeLines -join ', '))
    Write-Host '  Llevatelo en USB / AnyDesk / cloud.' -ForegroundColor Cyan

    # Paso 11: audit final
    Write-ActionAudit -Action 'Logs.Export' -Status 'OK' -Summary ([System.IO.Path]::GetFileName($zipPath)) -Details @{
        Hostname = $hostname
        Tag      = $tag
        Bytes    = $totalBytes
        Files    = $totalFiles
    }

    return [PSCustomObject]@{ Status = 'OK'; ZipPath = $zipPath }
}
