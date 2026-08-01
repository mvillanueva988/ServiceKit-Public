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

# -- SHA-256 de Launch.ps1 (pegar en README/release notes) ----------------------
# #38 (2026-07-25): NO hashear el archivo del arbol de trabajo.
# El repo tiene core.autocrlf=true -> git ALMACENA con LF y CHECKOUTEA con CRLF.
# El usuario que sigue el paso de verificacion del README baja Launch.ps1 de
# raw.githubusercontent.com, que sirve el BLOB (LF). Hashear el archivo local (CRLF)
# publica un valor que NO coincide -> el usuario obtiene mismatch y concluye que el
# archivo fue adulterado. Publicar un hash equivocado es PEOR que no publicar ninguno:
# entrena a ignorar la verificacion.
# Medido en v2.4.0: working tree 4A8C5F... vs blob servido 8D138E... (181 bytes de
# diferencia = los 181 CR). Normalizar a LF reproduce EXACTO lo que sirve GitHub.
#
# 2026-08-01: el hash se calculaba bien y se IMPRIMIA para pegarlo a mano en las
# notas. Eso dependia de que el operador se acordara, y en v2.6.0 no pasó: las
# notas salieron sin ningun SHA-256 mientras el README manda a compararlo contra
# ellas. Lo cazó el pre-flight (T7). Un paso manual que hay que recordar en cada
# release no es un procedimiento, es una deuda: ahora el hash se EMBEBE en las
# notas y el paso desaparece.
[string] $launchSha = ''
[string] $launchPs1 = Join-Path $PSScriptRoot 'Launch.ps1'
if (Test-Path $launchPs1) {
    [byte[]] $launchBytes = [System.IO.File]::ReadAllBytes($launchPs1)
    [byte[]] $launchLf    = @($launchBytes | Where-Object { $_ -ne 13 })

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $launchSha = ([BitConverter]::ToString($sha256.ComputeHash($launchLf)) -replace '-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }

    [bool] $hadCrlf = ($launchBytes.Length -ne $launchLf.Length)
    Write-Host ''
    Write-Host '  SHA-256 de Launch.ps1 (pegar en README/release notes):' -ForegroundColor Cyan
    Write-Host "  $launchSha" -ForegroundColor White
    if ($hadCrlf) {
        Write-Host '  (normalizado a LF: es el hash del archivo COMO LO SIRVE GitHub,' -ForegroundColor DarkGray
        Write-Host '   no el del archivo local. El local tiene CRLF y da otro valor.)' -ForegroundColor DarkGray
    }
}

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

    # Notas de la release: llevan los hashes ADENTRO.
    #
    # El README manda a comparar el SHA-256 de Launch.ps1 "contra el valor
    # publicado en las release notes". Si las notas no lo traen, ese paso del
    # README apunta a la nada y el usuario que quiso verificar se queda sin poder.
    # Publicar un hash equivocado entrena a ignorar la verificacion (leccion de
    # #38); no publicar ninguno la vuelve imposible, que es igual de malo.
    [string[]] $notas = @("Release $Version", '')
    if (-not [string]::IsNullOrWhiteSpace($launchSha)) {
        $notas += @(
            '## Verificacion de integridad',
            '',
            'SHA-256 de `Launch.ps1` (lo que sirve raw.githubusercontent.com, el archivo del one-liner):',
            '',
            '```',
            $launchSha,
            '```',
            ''
        )
    }
    $notas += @(
        "SHA-256 de ``$zipName``:",
        '',
        '```',
        $zipSha256,
        '```'
    )

    # Crear release
    Write-Host "  Creando release v$Version en GitHub..." -ForegroundColor Cyan
    [hashtable] $body = @{
        tag_name         = "v$Version"
        name             = "v$Version"
        body             = ($notas -join "`n")
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
