#Requires -Version 5.1

param(
    [string] $Version = '',
    [string] $Repo    = '',       # e.g. 'TU_USUARIO/TU_REPO' — si se omite, se lee de Launch.ps1
    [switch] $Publish             # Si se pasa: sube el ZIP a GitHub Releases (requiere $env:GITHUB_TOKEN)
)

Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Version)) {
    [string] $versionFile = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path $versionFile) {
        [string] $fileVersion = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($fileVersion)) {
            $Version = $fileVersion
        }
    }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        # Fallback legacy para no romper uso existente
        $Version = (Get-Date -Format 'yyyy.MM.dd')
        Write-Host "  [~] VERSION no definido; usando formato legacy $Version" -ForegroundColor Yellow
    }
}

# ── Rutas ─────────────────────────────────────────────────────────────────────
[string] $source  = $PSScriptRoot
[string] $staging = Join-Path $env:TEMP 'PCTk-release-staging'
[string] $outDir  = Join-Path $PSScriptRoot 'dist'
[string] $zipName = "PCTk-$Version.zip"
[string] $zipPath = Join-Path $outDir $zipName
[string] $shaName = "$zipName.sha256"
[string] $shaPath = Join-Path $outDir $shaName

# ── Limpiar y crear staging ───────────────────────────────────────────────────
Write-Host "  Preparando staging..." -ForegroundColor Cyan
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Copy-Item -Path $source -Destination $staging -Recurse

# ── Eliminar artifacts de desarrollo del staging ──────────────────────────────
[string[]] $excludeDirs = @('.git', '.claude', '.gsd', '.github', 'Logs', 'output', 'dist', 'memories', '_local-dev')
foreach ($dir in $excludeDirs) {
    [string] $p = Join-Path $staging $dir
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}

# tools\bin se preserva en la instalación (Launch.ps1 lo maneja), pero no se bundlea
[string] $toolsBin = Join-Path $staging 'tools\bin'
if (Test-Path $toolsBin) { Remove-Item $toolsBin -Recurse -Force }

# Archivos raíz que no se distribuyen
[string[]] $excludeFiles = @('Release.ps1', 'GSD-STYLE.md', 'CHANGELOG.md')
foreach ($file in $excludeFiles) {
    [string] $p = Join-Path $staging $file
    if (Test-Path $p) { Remove-Item $p -Force }
}
# Workspace files
Get-ChildItem -Path $staging -Filter '*.code-workspace' -File | Remove-Item -Force

# Rigs de test/sandbox (contienen paths absolutos de la máquina de desarrollo — inútiles para terceros)
[string] $testsDir = Join-Path $staging 'tests'
if (Test-Path $testsDir) {
    Get-ChildItem -Path $testsDir -Filter '*-sandbox*.wsb'            | Remove-Item -Force
    Get-ChildItem -Path $testsDir -Filter '*-sandbox-launcher.ps1'   | Remove-Item -Force
    Get-ChildItem -Path $testsDir -Filter 'snapshot-vm-validate.ps1' | Remove-Item -Force
    Get-ChildItem -Path $testsDir -Filter 'stage3-validate.ps1'      | Remove-Item -Force
    Get-ChildItem -Path $testsDir -Filter 'stage4-validate.ps1'      | Remove-Item -Force
    Get-ChildItem -Path $testsDir -Filter 'stage2-harness.ps1'       | Remove-Item -Force
}

# Recetas nombradas (T-S4): son datos de clientes reales. Solo viajan el
# placeholder y el fixture de smoke; cualquier <cliente>.json se excluye del ZIP.
[string] $namedDir = Join-Path (Join-Path (Join-Path $staging 'data') 'profiles') 'named'
if (Test-Path $namedDir) {
    Get-ChildItem -Path $namedDir -File | Where-Object {
        $_.Name -ne 'README.md' -and $_.Name -ne '_sample.json'
    } | Remove-Item -Force
}

# ── Generar ZIP ───────────────────────────────────────────────────────────────
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
if (Test-Path $shaPath) { Remove-Item $shaPath -Force }

Write-Host "  Comprimiendo..." -ForegroundColor Cyan
Compress-Archive -Path "$staging\*" -DestinationPath $zipPath

# ── Generar checksum SHA-256 del ZIP ─────────────────────────────────────────
[string] $zipSha256 = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
[string] $shaLine   = '{0} *{1}' -f $zipSha256, $zipName
[System.IO.File]::WriteAllText($shaPath, $shaLine + [Environment]::NewLine)

# ── Limpiar staging ───────────────────────────────────────────────────────────
Remove-Item $staging -Recurse -Force

# ── Mostrar resultado ─────────────────────────────────────────────────────────
[double] $sizeMB = (Get-Item $zipPath).Length / 1MB
Write-Host ("  [v] {0}  ({1:N1} MB)" -f $zipName, $sizeMB) -ForegroundColor Green
Write-Host "      $zipPath" -ForegroundColor DarkGray
Write-Host ("  [v] {0}" -f $shaName) -ForegroundColor Green
Write-Host "      $shaPath" -ForegroundColor DarkGray

# ── Publicar a GitHub Releases (opcional) ────────────────────────────────────
if ($Publish) {
    # Verificar token
    if ([string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
        Write-Host '  [!] Falta $env:GITHUB_TOKEN. Sube el ZIP manualmente en GitHub UI.' -ForegroundColor Red
        Write-Host "      https://github.com/$Repo/releases/new" -ForegroundColor DarkGray
        return
    }

    # Leer $GitHubRepo de Launch.ps1 si no se pasó -Repo
    if ([string]::IsNullOrEmpty($Repo)) {
        [string] $launchPath = Join-Path $PSScriptRoot 'Launch.ps1'
        if (Test-Path $launchPath) {
            $repoLine = Get-Content $launchPath | Where-Object { $_ -match "\`$GitHubRepo\s*=" } | Select-Object -First 1
            if ($repoLine -match "=\s*'([^']+)'") { $Repo = $Matches[1] }
        }
    }
    if ([string]::IsNullOrEmpty($Repo) -or $Repo -eq 'TU_USUARIO/TU_REPO') {
        Write-Host '  [!] Configura $GitHubRepo en Launch.ps1 o pasa -Repo "usuario/repo".' -ForegroundColor Red
        return
    }

    [hashtable] $headers = @{
        Authorization = "token $env:GITHUB_TOKEN"
        Accept        = 'application/vnd.github+json'
    }

    # Crear release
    Write-Host "  Creando release v$Version en GitHub..." -ForegroundColor Cyan
    [hashtable] $body = @{
        tag_name         = "v$Version"
        name             = "v$Version"
        body             = "Release $Version"
        draft            = $false
        prerelease       = $false
    }
    try {
        $releaseResult = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Repo/releases" `
            -Method Post `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body ($body | ConvertTo-Json) `
            -ErrorAction Stop

        [string] $uploadUrl = $releaseResult.upload_url -replace '\{.*\}', ''

        # Subir ZIP asset
        Write-Host "  Subiendo $zipName..." -ForegroundColor Cyan
        $zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
        Invoke-RestMethod `
            -Uri "${uploadUrl}?name=$zipName" `
            -Method Post `
            -Headers $headers `
            -ContentType 'application/zip' `
            -Body $zipBytes `
            -ErrorAction Stop | Out-Null

        # Subir checksum SHA-256
        Write-Host "  Subiendo $shaName..." -ForegroundColor Cyan
        [byte[]] $shaBytes = [System.IO.File]::ReadAllBytes($shaPath)
        Invoke-RestMethod `
            -Uri "${uploadUrl}?name=$shaName" `
            -Method Post `
            -Headers $headers `
            -ContentType 'text/plain' `
            -Body $shaBytes `
            -ErrorAction Stop | Out-Null

        Write-Host "  [v] Release publicado: https://github.com/$Repo/releases/tag/v$Version" -ForegroundColor Green
    }
    catch {
        Write-Host "  [!] Error al publicar: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      Sube manualmente: $zipPath" -ForegroundColor DarkGray
        Write-Host "      https://github.com/$Repo/releases/new" -ForegroundColor DarkGray
    }
}
