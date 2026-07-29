#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-flight del gate de release: verifica el ARTEFACTO PUBLICADO, no el repo local.

.DESCRIPTION
    Corre contra lo que GitHub sirve de verdad: descarga el ZIP de la release, lo
    extrae y lo audita. NO necesita Windows Sandbox ni permisos de admin.

    POR QUE EXISTE: el gate en Sandbox limpia cazo 3 releases rotas que el smoke,
    el code-review y los resumenes dejaron pasar. Dos de esas tres eran defectos
    del ARTEFACTO, no del comportamiento -- se pueden verificar sin arrancar una
    maquina virtual:
      · BOM faltante en .ps1 dentro del ZIP  -> T4
      · el SHA-256 publicado de Launch.ps1 no coincidia con el que sirve GitHub
        (#38, v2.4.0)                        -> T7
    Y de paso cubre dos formas de publicar mal que ya pasaron:
      · marcar la release como "Pre-release" la deja invisible al instalador,
        que consulta releases/latest  -> T1
      · el one-liner del README apuntando al tag anterior -> T8

    LO QUE ESTE SCRIPT NO PUEDE VER (y por lo tanto NO reemplaza al gate en
    Sandbox): que el toolkit ANDE. Instalacion real desde cero, Execution Policy
    de una maquina nueva, los caminos que mutan el sistema, y el render de la
    consola. Un PASS aca significa "el paquete esta bien armado", nunca
    "la release esta lista".

.PARAMETER Version
    Version a verificar (ej. 2.5.0). Si se omite, se lee del archivo VERSION.

.PARAMETER Repo
    usuario/repo. Si se omite, se lee de $GitHubRepo en Launch.ps1.

.PARAMETER OutFile
    Si se pasa, escribe el reporte a ese archivo ademas de la consola.

.EXAMPLE
    .\tests\release-preflight.ps1
    .\tests\release-preflight.ps1 -Version 2.5.0 -OutFile C:\temp\preflight.txt
#>

[CmdletBinding()]
param(
    [string] $Version = '',
    [string] $Repo    = '',
    [string] $OutFile = '',
    [switch] $KeepFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# TLS 1.2: Win10 viejo negocia TLS 1.0 por default y la API de GitHub lo rechaza.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

[string] $repoRoot = Split-Path -Parent $PSScriptRoot

# ─── Resultados ───────────────────────────────────────────────────────────────
[System.Collections.Generic.List[PSCustomObject]] $checks =
    [System.Collections.Generic.List[PSCustomObject]]::new()
[System.Collections.Generic.List[string]] $log =
    [System.Collections.Generic.List[string]]::new()

function Write-Both {
    param([string] $Message, [string] $Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    [void] $log.Add($Message)
}

function Add-Check {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')] [string] $Status,
        [string] $Detail = ''
    )
    [void] $checks.Add([PSCustomObject]@{ Id = $Id; Name = $Name; Status = $Status; Detail = $Detail })
    [string] $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
    Write-Both ('  [{0}] {1}  {2}' -f $Status, $Id, $Name) $color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Both ('         {0}' -f $Detail) 'DarkGray' }
}

# ─── Resolver version y repo ──────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Version)) {
    [string] $versionFile = Join-Path $repoRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $Version = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host '  [!] No se pudo resolver la version. Pasar -Version.' -ForegroundColor Red
    exit 2
}

if ([string]::IsNullOrWhiteSpace($Repo)) {
    [string] $launchPath = Join-Path $repoRoot 'Launch.ps1'
    if (Test-Path -LiteralPath $launchPath) {
        $repoLine = Get-Content -LiteralPath $launchPath |
                    Where-Object { $_ -match "\`$GitHubRepo\s*=" } | Select-Object -First 1
        if ($repoLine -match "=\s*'([^']+)'") { $Repo = $Matches[1] }
    }
}
if ([string]::IsNullOrWhiteSpace($Repo)) {
    Write-Host '  [!] No se pudo resolver el repo. Pasar -Repo "usuario/repo".' -ForegroundColor Red
    exit 2
}

[string] $tag     = 'v' + $Version
[string] $workDir = Join-Path $env:TEMP ('pctk-preflight-' + $tag + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $workDir -Force

Write-Both ''
Write-Both '════════════════════════════════════════════════════════════════════'
Write-Both ('  PRE-FLIGHT DE RELEASE  ·  {0}  ·  {1}' -f $tag, $Repo)
Write-Both '════════════════════════════════════════════════════════════════════'
Write-Both ('  Verifica el artefacto PUBLICADO. No reemplaza el gate en Sandbox.')
Write-Both ('  Trabajo en: {0}' -f $workDir)
Write-Both ''

# ─── T1: la release existe, es Latest, no es draft ni prerelease ──────────────
$release = $null
try {
    $release = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/tags/{1}' -f $Repo, $tag) `
                                 -Headers @{ Accept = 'application/vnd.github+json' } -ErrorAction Stop
} catch {
    Add-Check -Id 'T1' -Name 'La release existe en GitHub' -Status 'FAIL' `
              -Detail ('No se pudo leer la release {0}: {1}' -f $tag, $_.Exception.Message)
}

if ($null -ne $release) {
    [bool] $isDraft = [bool] $release.draft
    [bool] $isPre   = [bool] $release.prerelease
    if ($isDraft -or $isPre) {
        Add-Check -Id 'T1' -Name 'La release es publica y estable (no draft, no prerelease)' -Status 'FAIL' `
                  -Detail ('draft={0} prerelease={1}. El instalador consulta releases/latest: una pre-release queda INVISIBLE.' -f $isDraft, $isPre)
    } else {
        Add-Check -Id 'T1' -Name 'La release es publica y estable (no draft, no prerelease)' -Status 'PASS'
    }

    # Que ademas sea la que sirve /latest (es la que baja el instalador).
    try {
        $latest = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $Repo) `
                                    -Headers @{ Accept = 'application/vnd.github+json' } -ErrorAction Stop
        if ([string]$latest.tag_name -eq $tag) {
            Add-Check -Id 'T2' -Name 'releases/latest apunta a este tag' -Status 'PASS'
        } else {
            Add-Check -Id 'T2' -Name 'releases/latest apunta a este tag' -Status 'FAIL' `
                      -Detail ('latest = {0}, esperado {1}. El instalador va a bajar la otra.' -f $latest.tag_name, $tag)
        }
    } catch {
        Add-Check -Id 'T2' -Name 'releases/latest apunta a este tag' -Status 'FAIL' `
                  -Detail $_.Exception.Message
    }
}

# ─── T3: el ZIP y su .sha256 estan publicados y el hash coincide ──────────────
[string] $zipLocal = ''
if ($null -ne $release) {
    [object[]] $assets = @()
    if ($null -ne $release.PSObject.Properties['assets']) { $assets = @($release.assets) }

    [string] $zipName = ('PCTk-{0}.zip' -f $Version)
    [object[]] $zipAsset = @($assets | Where-Object { [string]$_.name -eq $zipName })
    [object[]] $shaAsset = @($assets | Where-Object { [string]$_.name -eq ($zipName + '.sha256') })

    if ($zipAsset.Count -ne 1 -or $shaAsset.Count -ne 1) {
        Add-Check -Id 'T3' -Name 'ZIP + .sha256 publicados y coincidentes' -Status 'FAIL' `
                  -Detail ('Faltan assets. Encontrados: {0}' -f (($assets | ForEach-Object { $_.name }) -join ', '))
    } else {
        try {
            $zipLocal = Join-Path $workDir $zipName
            [string] $shaLocal = Join-Path $workDir ($zipName + '.sha256')
            Invoke-WebRequest -Uri ([string]$zipAsset[0].browser_download_url) -OutFile $zipLocal -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri ([string]$shaAsset[0].browser_download_url) -OutFile $shaLocal -UseBasicParsing -ErrorAction Stop

            [string] $actual   = (Get-FileHash -Path $zipLocal -Algorithm SHA256).Hash.ToUpperInvariant()
            [string] $declared = (Get-Content -LiteralPath $shaLocal -Raw).Trim()
            # El .sha256 puede venir como "<hash>  <archivo>" o solo el hash.
            if ($declared -match '([0-9A-Fa-f]{64})') { $declared = $Matches[1].ToUpperInvariant() }

            if ($actual -eq $declared) {
                Add-Check -Id 'T3' -Name 'ZIP + .sha256 publicados y coincidentes' -Status 'PASS' `
                          -Detail $actual
            } else {
                Add-Check -Id 'T3' -Name 'ZIP + .sha256 publicados y coincidentes' -Status 'FAIL' `
                          -Detail ('ZIP={0} vs .sha256={1}' -f $actual, $declared)
            }
        } catch {
            Add-Check -Id 'T3' -Name 'ZIP + .sha256 publicados y coincidentes' -Status 'FAIL' `
                      -Detail $_.Exception.Message
        }
    }
}

# ─── T4-T6: auditar el contenido del ZIP ──────────────────────────────────────
[string] $extractDir = Join-Path $workDir 'extract'
[bool] $extracted = $false
if (-not [string]::IsNullOrWhiteSpace($zipLocal) -and (Test-Path -LiteralPath $zipLocal)) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipLocal, $extractDir)
        $extracted = $true
    } catch {
        Add-Check -Id 'T4' -Name 'El ZIP se extrae' -Status 'FAIL' -Detail $_.Exception.Message
    }
}

if ($extracted) {
    # T4: BOM + parseo de TODOS los .ps1 del paquete.
    # Es el chequeo que mas veces salvo la ropa: PS5.1 en es-AR lee un .ps1 sin
    # BOM con la code page del sistema y revienta el parser a mitad de un string.
    [System.Collections.Generic.List[string]] $sinBom = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $noParsea = [System.Collections.Generic.List[string]]::new()
    [object[]] $ps1 = @(Get-ChildItem -LiteralPath $extractDir -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)

    foreach ($f in $ps1) {
        [byte[]] $b = [System.IO.File]::ReadAllBytes($f.FullName)
        [bool] $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
        if (-not $hasBom) {
            [bool] $nonAscii = $false
            foreach ($byte in $b) { if ($byte -gt 127) { $nonAscii = $true; break } }
            if ($nonAscii) { [void] $sinBom.Add($f.FullName.Substring($extractDir.Length + 1)) }
        }
        $perr = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $perr)
        if ($null -ne $perr -and @($perr).Count -gt 0) {
            [void] $noParsea.Add(('{0}: {1}' -f $f.FullName.Substring($extractDir.Length + 1), $perr[0].Message))
        }
    }

    if ($sinBom.Count -eq 0 -and $noParsea.Count -eq 0) {
        Add-Check -Id 'T4' -Name 'Todos los .ps1 del ZIP: BOM presente y parseo limpio' -Status 'PASS' `
                  -Detail ('{0} archivos verificados' -f $ps1.Count)
    } else {
        # OJO: temp vars, NO un `if` inline como argumento. PS5.1 parsea
        # `('{0}' -f (if ...))` como el CMDLET if -> CommandNotFound. Es el mismo
        # bug que rompio el panel de bateria del reporte [8] en v2.4.0.
        [string] $sinBomTxt   = 'ninguno'
        [string] $noParseaTxt = 'ninguno'
        if ($sinBom.Count   -gt 0) { $sinBomTxt   = $sinBom -join ', ' }
        if ($noParsea.Count -gt 0) { $noParseaTxt = $noParsea -join ' ;; ' }
        Add-Check -Id 'T4' -Name 'Todos los .ps1 del ZIP: BOM presente y parseo limpio' -Status 'FAIL' `
                  -Detail ('sin BOM: {0} | no parsean: {1}' -f $sinBomTxt, $noParseaTxt)
    }

    # T5: la VERSION empaquetada coincide con el tag.
    [string] $zipVersionFile = Join-Path $extractDir 'VERSION'
    if (Test-Path -LiteralPath $zipVersionFile) {
        [string] $zipVersion = (Get-Content -LiteralPath $zipVersionFile -Raw).Trim()
        if ($zipVersion -eq $Version) {
            Add-Check -Id 'T5' -Name 'El VERSION del paquete coincide con el tag' -Status 'PASS' -Detail $zipVersion
        } else {
            Add-Check -Id 'T5' -Name 'El VERSION del paquete coincide con el tag' -Status 'FAIL' `
                      -Detail ('ZIP dice {0}, el tag es {1}' -f $zipVersion, $Version)
        }
    } else {
        Add-Check -Id 'T5' -Name 'El VERSION del paquete coincide con el tag' -Status 'FAIL' -Detail 'No hay archivo VERSION en el ZIP'
    }

    # T6: cero documentacion interna en el paquete publico.
    # El ZIP de v2.3.1 se publico con CLAUDE.md adentro; quedo para siempre en un
    # tag publicado. El .gitattributes export-ignore y el destrackeo lo arreglan,
    # pero conviene que un chequeo lo grite antes y no despues.
    [string[]] $prohibidos = @('CLAUDE.md', '_local-dev', 'HANDOFF_')
    [System.Collections.Generic.List[string]] $filtrados = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $extractDir -Recurse -ErrorAction SilentlyContinue)) {
        [string] $rel = $item.FullName.Substring($extractDir.Length + 1)
        foreach ($p in $prohibidos) {
            if ($rel -like ('*' + $p + '*')) { [void] $filtrados.Add($rel); break }
        }
    }
    if ($filtrados.Count -eq 0) {
        Add-Check -Id 'T6' -Name 'Sin documentacion interna en el paquete publico' -Status 'PASS'
    } else {
        Add-Check -Id 'T6' -Name 'Sin documentacion interna en el paquete publico' -Status 'FAIL' `
                  -Detail ($filtrados -join ', ')
    }

    # T8: el one-liner del README empaquetado apunta a ESTE tag.
    [string] $zipReadme = Join-Path $extractDir 'README.md'
    if (Test-Path -LiteralPath $zipReadme) {
        [string] $readmeTxt = Get-Content -LiteralPath $zipReadme -Raw -Encoding UTF8
        [object[]] $otrosTags = @([regex]::Matches($readmeTxt, 'ServiceKit-Public/(v[0-9]+\.[0-9]+\.[0-9]+)/') |
                                  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
                                  Where-Object { $_ -ne $tag })
        if ($otrosTags.Count -eq 0) {
            Add-Check -Id 'T8' -Name 'El one-liner del README apunta a este tag' -Status 'PASS'
        } else {
            Add-Check -Id 'T8' -Name 'El one-liner del README apunta a este tag' -Status 'FAIL' `
                      -Detail ('El README empaquetado todavia menciona: {0}' -f ($otrosTags -join ', '))
        }
    }
}

# ─── T7: el SHA-256 de Launch.ps1 publicado == el que sirve raw.github ────────
# Este es el #38. El repo tiene core.autocrlf=true: git almacena LF y checkoutea
# CRLF, asi que hashear el archivo local da OTRO valor que el blob que sirve
# GitHub. El usuario que sigue el paso de verificacion del README compara contra
# lo que baja -- si no coincide, concluye que el archivo esta adulterado.
# Publicar un hash equivocado es PEOR que no publicar ninguno: entrena a ignorar
# la verificacion.
if ($null -ne $release) {
    try {
        [string] $rawUrl = 'https://raw.githubusercontent.com/{0}/{1}/Launch.ps1' -f $Repo, $tag
        [string] $launchLocal = Join-Path $workDir 'Launch.raw.ps1'
        Invoke-WebRequest -Uri $rawUrl -OutFile $launchLocal -UseBasicParsing -ErrorAction Stop
        [string] $servido = (Get-FileHash -Path $launchLocal -Algorithm SHA256).Hash.ToUpperInvariant()

        [string] $body = ''
        if ($null -ne $release.PSObject.Properties['body'] -and $null -ne $release.body) { $body = [string]$release.body }

        [object[]] $enNotas = @([regex]::Matches($body, '[0-9A-Fa-f]{64}') | ForEach-Object { $_.Value.ToUpperInvariant() })

        if ($enNotas.Count -eq 0) {
            Add-Check -Id 'T7' -Name 'El SHA-256 de Launch.ps1 esta publicado y coincide' -Status 'FAIL' `
                      -Detail ('Las notas de la release NO publican ningun SHA-256. El README manda a comparar contra ese valor. El correcto es: {0}' -f $servido)
        } elseif ($enNotas -contains $servido) {
            Add-Check -Id 'T7' -Name 'El SHA-256 de Launch.ps1 esta publicado y coincide' -Status 'PASS' -Detail $servido
        } else {
            Add-Check -Id 'T7' -Name 'El SHA-256 de Launch.ps1 esta publicado y coincide' -Status 'FAIL' `
                      -Detail ('Las notas dicen {0}; lo que sirve GitHub es {1} (#38)' -f ($enNotas -join ' / '), $servido)
        }
    } catch {
        Add-Check -Id 'T7' -Name 'El SHA-256 de Launch.ps1 esta publicado y coincide' -Status 'FAIL' `
                  -Detail $_.Exception.Message
    }
}

# ─── Reporte ──────────────────────────────────────────────────────────────────
[int] $fails = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
[int] $warns = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
[int] $pass  = @($checks | Where-Object { $_.Status -eq 'PASS' }).Count

Write-Both ''
Write-Both '────────────────────────────────────────────────────────────────────'
Write-Both ('  PASS: {0}   FAIL: {1}   WARN: {2}' -f $pass, $fails, $warns)
Write-Both '────────────────────────────────────────────────────────────────────'
Write-Both ''
if ($fails -eq 0) {
    Write-Both '  El PAQUETE esta bien armado.' 'Green'
} else {
    Write-Both '  El paquete tiene defectos. NO publicar / corregir antes de difundir.' 'Red'
}
Write-Both ''
Write-Both '  ESTO NO ES EL GATE. Falta lo que solo se ve corriendo el toolkit:' 'Yellow'
Write-Both '    · instalacion real desde cero con el one-liner (Execution Policy)'
Write-Both '    · los caminos que MUTAN el sistema  -> tests\release-gate-validate.ps1'
Write-Both '    · el render de la consola y la pasada visual -> ojos de Mateo'
Write-Both ''

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    try {
        [System.IO.File]::WriteAllLines($OutFile, $log, [System.Text.UTF8Encoding]::new($true))
        Write-Host ('  Reporte escrito en: {0}' -f $OutFile) -ForegroundColor DarkGray
    } catch {
        Write-Host ('  [!] No se pudo escribir el reporte: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

if (-not $KeepFiles) {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ('  Archivos conservados en: {0}' -f $workDir) -ForegroundColor DarkGray
}

if ($fails -gt 0) { exit 1 }
exit 0
