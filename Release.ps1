#Requires -Version 5.1

param(
    [string] $Version    = '',
    [string] $Repo       = '',          # e.g. 'TU_USUARIO/TU_REPO' (si se omite, se lee de Launch.ps1)
    [switch] $Publish,                  # Si se pasa: sube el ZIP a GitHub Releases (requiere $env:GITHUB_TOKEN)
    [switch] $AllowDirty                # Si se pasa: no aborta con arbol de trabajo sucio (ZIP sale de HEAD igual)
)

# P5 (2026-10-13): todo fallo termina con exit 1, y "publicado" se verifica contra
# la API, no contra la ausencia de excepciones.
#
# v2.7.0 quedo 9 dias como tag SIN release: el token de GitHub habia vencido, el
# catch del bloque -Publish imprimio un mensaje rojo y el script termino con exit 0.
# Nadie lo vio. Un mensaje rojo en una consola que nadie mira no es un fallo; un
# exit code distinto de cero si.
#
# Estructura: la logica vive en funciones y el cuerpo corre solo si el script NO
# fue dot-sourceado. Asi el smoke (y un chequeo manual de solo lectura) pueden
# cargar Test-PctkPublishedRelease sin empaquetar ni publicar nada:
#
#   . .\Release.ps1
#   Test-PctkPublishedRelease -Repo 'usuario/repo' -Version '2.10.0' -ZipPath dist\PCTk-2.10.0.zip -ShaPath dist\PCTk-2.10.0.zip.sha256

function Get-PctkReleaseProp {
    # Lee una propiedad de un objeto de la API sin tirar bajo StrictMode si falta.
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-PctkPublishedRelease {
    <#
    .SYNOPSIS
        Verifica contra la API de GitHub que la release v<Version> existe, no es
        draft y tiene el ZIP y su checksum subidos completos.
    .DESCRIPTION
        Solo lectura: un GET a /repos/<Repo>/releases/tags/v<Version>. El token es
        opcional (el repo es publico; con token sube el rate limit).
        Devuelve un objeto { Ok; Reason; Url }. No tira por un fallo de la
        verificacion: lo informa en Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [string] $ShaPath,
        [string] $Token = '',
        [int] $Attempts = 3,
        [int] $RetryDelaySeconds = 2
    )
    Set-StrictMode -Version Latest

    [string] $url = "https://api.github.com/repos/$Repo/releases/tags/v$Version"
    [hashtable] $headers = @{
        Accept       = 'application/vnd.github+json'
        'User-Agent' = 'PCTk-Release'
    }
    if (-not [string]::IsNullOrEmpty($Token)) { $headers['Authorization'] = "token $Token" }

    $fail = {
        param([string] $why)
        return [pscustomobject] @{ Ok = $false; Reason = $why; Url = $url }
    }

    # Lo esperado sale de los archivos locales: nombre y tamano exactos.
    [object[]] $expected = @()
    foreach ($p in @($ZipPath, $ShaPath)) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return (& $fail ("no existe el archivo local para comparar: $p"))
        }
        $item = Get-Item -LiteralPath $p
        $expected += [pscustomobject] @{ Name = $item.Name; Size = [long] $item.Length }
    }

    # Reintento corto SOLO si el GET tira (p. ej. un 404 por lag justo despues de
    # crear la release). Un asset faltante o de otro tamano no se reintenta: no es lag.
    $release = $null
    [string] $lastError = ''
    for ($i = 1; $i -le [Math]::Max(1, $Attempts); $i++) {
        try {
            $release = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
            break
        }
        catch {
            $lastError = $_.Exception.Message
            $release = $null
            if ($i -lt $Attempts) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }
    if ($null -eq $release) {
        return (& $fail ("GET $url fallo: $lastError"))
    }

    [string] $htmlUrl = [string] (Get-PctkReleaseProp $release 'html_url')
    if (-not [string]::IsNullOrWhiteSpace($htmlUrl)) { $url = $htmlUrl }

    if ((Get-PctkReleaseProp $release 'draft') -eq $true) {
        return (& $fail "la release v$Version existe pero es DRAFT (no la ve nadie)")
    }

    [object[]] $assets = @(Get-PctkReleaseProp $release 'assets' | Where-Object { $null -ne $_ })
    foreach ($e in $expected) {
        [object[]] $match = @($assets | Where-Object { [string] (Get-PctkReleaseProp $_ 'name') -eq $e.Name })
        if ($match.Count -eq 0) {
            [string] $seen = (@($assets | ForEach-Object { [string] (Get-PctkReleaseProp $_ 'name') }) -join ', ')
            if ([string]::IsNullOrEmpty($seen)) { $seen = '(ninguno)' }
            return (& $fail ("falta el asset $($e.Name) en la release v$Version (publicados: $seen)"))
        }
        $a = $match[0]
        [string] $state = [string] (Get-PctkReleaseProp $a 'state')
        if ($state -ne 'uploaded') {
            return (& $fail ("el asset $($e.Name) tiene state='$state', esperaba 'uploaded' (subida incompleta)"))
        }
        $sizeRaw = Get-PctkReleaseProp $a 'size'
        [long] $size = -1
        if ($null -ne $sizeRaw) { $size = [long] $sizeRaw }
        if ($size -ne $e.Size) {
            return (& $fail ("el asset $($e.Name) publicado pesa $size bytes y el local $($e.Size)"))
        }
    }

    return [pscustomobject] @{ Ok = $true; Reason = ''; Url = $url }
}

function Invoke-PctkRelease {
    <#
    .SYNOPSIS
        Cuerpo de Release.ps1. Devuelve el exit code: 0 = ZIP generado (y, con
        -Publish, release publicada Y verificada contra la API); 1 = cualquier fallo.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string] $Version = '',
        [string] $Repo = '',
        [switch] $Publish,
        [switch] $AllowDirty,
        [Parameter(Mandatory)] [string] $SourceRoot
    )
    Set-StrictMode -Version Latest

    if ([string]::IsNullOrWhiteSpace($Version)) {
        [string] $versionFile = Join-Path $SourceRoot 'VERSION'
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

    # -- Rutas -------------------------------------------------------------------
    [string] $source  = $SourceRoot
    [string] $outDir  = Join-Path $SourceRoot 'dist'
    [string] $zipName = "PCTk-$Version.zip"
    [string] $zipPath = Join-Path $outDir $zipName
    [string] $shaName = "$zipName.sha256"
    [string] $shaPath = Join-Path $outDir $shaName

    # -- Guard: arbol de trabajo sucio -------------------------------------------
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
            return 1
        }
    }

    # -- Generar ZIP via git archive ---------------------------------------------
    # git archive honra .gitattributes export-ignore: solo viajan archivos trackeados
    # y no marcados export-ignore. Basura/secretos untracked son imposible de filtrar.
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -ErrorAction Stop | Out-Null }
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction Stop }
    if (Test-Path $shaPath) { Remove-Item $shaPath -Force -ErrorAction Stop }

    Write-Host "  Comprimiendo (git archive HEAD)..." -ForegroundColor Cyan
    # | Out-Null: nada de stdout de git puede colarse en el exit code que devuelve esta funcion.
    & git -C $source archive --format=zip -o $zipPath HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] git archive fallo (exit $LASTEXITCODE). Verifica que el repo sea valido y HEAD exista." -ForegroundColor Red
        return 1
    }
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Write-Host "  [!] git archive termino sin error pero no dejo el ZIP en $zipPath." -ForegroundColor Red
        return 1
    }

    # -- Generar checksum SHA-256 del ZIP ----------------------------------------
    [string] $zipSha256 = (Get-FileHash -Path $zipPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    [string] $shaLine   = '{0} *{1}' -f $zipSha256, $zipName
    [System.IO.File]::WriteAllText($shaPath, $shaLine + [Environment]::NewLine)

    # -- Mostrar resultado -------------------------------------------------------
    [double] $sizeMB = (Get-Item $zipPath -ErrorAction Stop).Length / 1MB
    Write-Host ("  [v] {0}  ({1:N1} MB)" -f $zipName, $sizeMB) -ForegroundColor Green
    Write-Host "      $zipPath" -ForegroundColor DarkGray
    Write-Host ("  [v] {0}" -f $shaName) -ForegroundColor Green
    Write-Host "      $shaPath" -ForegroundColor DarkGray

    # -- SHA-256 de Launch.ps1 (pegar en README/release notes) --------------------
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
    [string] $launchPs1 = Join-Path $SourceRoot 'Launch.ps1'
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

    if (-not $Publish) { return 0 }

    # -- Publicar a GitHub Releases (opcional) -----------------------------------
    # Verificar token
    if ([string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
        Write-Host '  [!] Falta $env:GITHUB_TOKEN. Sube el ZIP manualmente en GitHub UI.' -ForegroundColor Red
        Write-Host "      https://github.com/$Repo/releases/new" -ForegroundColor DarkGray
        return 1
    }

    # Leer $GitHubRepo de Launch.ps1 si no se paso -Repo
    if ([string]::IsNullOrEmpty($Repo)) {
        [string] $launchPath = Join-Path $SourceRoot 'Launch.ps1'
        if (Test-Path $launchPath) {
            $repoLine = Get-Content $launchPath | Where-Object { $_ -match "\`$GitHubRepo\s*=" } | Select-Object -First 1
            if ($repoLine -match "=\s*'([^']+)'") { $Repo = $Matches[1] }
        }
    }
    if ([string]::IsNullOrEmpty($Repo) -or $Repo -eq 'TU_USUARIO/TU_REPO') {
        Write-Host '  [!] Configura $GitHubRepo en Launch.ps1 o pasa -Repo "usuario/repo".' -ForegroundColor Red
        return 1
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

        [string] $uploadUrl = [string] (Get-PctkReleaseProp $releaseResult 'upload_url') -replace '\{.*\}', ''
        if ([string]::IsNullOrWhiteSpace($uploadUrl)) {
            throw 'la API creo la release pero no devolvio upload_url'
        }

        # Subir ZIP asset
        Write-Host "  Subiendo $zipName..." -ForegroundColor Cyan
        [byte[]] $zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
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
    }
    catch {
        # Antes esto imprimia en rojo y el script terminaba con exit 0 (v2.7.0).
        Write-Host "  [!] Error al publicar: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      Revisa en https://github.com/$Repo/releases si quedo una release a medias (borrarla antes de reintentar)." -ForegroundColor Yellow
        Write-Host "      Sube manualmente: $zipPath" -ForegroundColor DarkGray
        Write-Host "      https://github.com/$Repo/releases/new" -ForegroundColor DarkGray
        return 1
    }

    # -- Verificar lo publicado contra la API ------------------------------------
    # Que ninguna llamada haya tirado no prueba que la release este: se pregunta.
    Write-Host "  Verificando la release publicada contra la API..." -ForegroundColor Cyan
    $check = Test-PctkPublishedRelease -Repo $Repo -Version $Version -ZipPath $zipPath -ShaPath $shaPath -Token $env:GITHUB_TOKEN
    if (-not $check.Ok) {
        Write-Host "  [!] La verificacion de la release FALLO: $($check.Reason)" -ForegroundColor Red
        Write-Host "      $($check.Url)" -ForegroundColor DarkGray
        return 1
    }

    Write-Host "  [v] Release publicado y verificado: $($check.Url)" -ForegroundColor Green
    return 0
}

# -- Cuerpo: solo si el script se EJECUTA (no si se dot-sourcea) -----------------
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    [int] $releaseExit = 1
    try {
        [object[]] $out = @(Invoke-PctkRelease -Version $Version -Repo $Repo -Publish:$Publish -AllowDirty:$AllowDirty -SourceRoot $PSScriptRoot)
        if ($out.Count -eq 1 -and $out[0] -is [int]) {
            $releaseExit = [int] $out[0]
        } else {
            Write-Host ("  [!] Release.ps1: el cuerpo devolvio {0} objetos en vez de un exit code; se trata como fallo." -f $out.Count) -ForegroundColor Red
        }
    }
    catch {
        Write-Host "  [!] Release.ps1 fallo: $($_.Exception.Message)" -ForegroundColor Red
        $releaseExit = 1
    }
    exit $releaseExit
}
