#Requires -Version 5.1

param(
    [string] $Version    = '',
    [string] $Repo       = '',          # e.g. 'TU_USUARIO/TU_REPO' (si se omite, se lee de Launch.ps1)
    [switch] $Publish,                  # Si se pasa: sube el ZIP a GitHub Releases (requiere $env:GITHUB_TOKEN)
    [switch] $AllowDirty                # Si se pasa: no aborta con arbol de trabajo sucio (ZIP sale de HEAD igual)
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

# -- Rutas -----------------------------------------------------------------------
[string] $source  = $PSScriptRoot
[string] $outDir  = Join-Path $PSScriptRoot 'dist'
[string] $zipName = "PCTk-$Version.zip"
[string] $zipPath = Join-Path $outDir $zipName
[string] $shaName = "$zipName.sha256"
[string] $shaPath = Join-Path $outDir $shaName

# -- Guard: arbol de trabajo sucio -----------------------------------------------
# git archive empaqueta HEAD; cambios sin commitear NO entran al ZIP.
# Abortar a menos que el operador pase -AllowDirty explicitamente.
if (-not $AllowDirty) {
    [string] $dirtyStatus = (& git -C $source status --porcelain 2>&1)
    if (-not [string]::IsNullOrWhiteSpace($dirtyStatus)) {
        Write-Host '  [!] El arbol de trabajo tiene cambios sin commitear.' -ForegroundColor Red
        Write-Host '      El ZIP sale de HEAD; los cambios pendientes NO entraran.' -ForegroundColor Yellow
        Write-Host '      Commitea o stashea antes de release, o pasa -AllowDirty para ignorar este guard.' -ForegroundColor Yellow
        Write-Host '      Archivos modificados/sin trackear:' -ForegroundColor DarkGray
        Write-Host "      $dirtyStatus" -ForegroundColor DarkGray
        return
    }
}

# -- Generar ZIP via git archive -------------------------------------------------
# git archive honra .gitattributes export-ignore: solo viajan archivos trackeados
# y no marcados export-ignore. Basura/secretos untracked son imposible de filtrar.
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
if (Test-Path $shaPath) { Remove-Item $shaPath -Force }

Write-Host "  Comprimiendo (git archive HEAD)..." -ForegroundColor Cyan
& git -C $source archive --format=zip -o $zipPath HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [!] git archive fallo (exit $LASTEXITCODE). Verifica que el repo sea valido y HEAD exista." -ForegroundColor Red
    return
}

# -- Generar checksum SHA-256 del ZIP --------------------------------------------
[string] $zipSha256 = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
[string] $shaLine   = '{0} *{1}' -f $zipSha256, $zipName
[System.IO.File]::WriteAllText($shaPath, $shaLine + [Environment]::NewLine)

# -- Mostrar resultado -----------------------------------------------------------
[double] $sizeMB = (Get-Item $zipPath).Length / 1MB
Write-Host ("  [v] {0}  ({1:N1} MB)" -f $zipName, $sizeMB) -ForegroundColor Green
Write-Host "      $zipPath" -ForegroundColor DarkGray
Write-Host ("  [v] {0}" -f $shaName) -ForegroundColor Green
Write-Host "      $shaPath" -ForegroundColor DarkGray

# -- Publicar a GitHub Releases (opcional) ---------------------------------------
if ($Publish) {
    # Verificar token
    if ([string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
        Write-Host '  [!] Falta $env:GITHUB_TOKEN. Sube el ZIP manualmente en GitHub UI.' -ForegroundColor Red
        Write-Host "      https://github.com/$Repo/releases/new" -ForegroundColor DarkGray
        return
    }

    # Leer $GitHubRepo de Launch.ps1 si no se paso -Repo
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
