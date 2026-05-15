#Requires -Version 5.1

<#
.SYNOPSIS
    Chequea cuales entries con updatePolicy='pinned' tienen versiones mas
    nuevas disponibles upstream. Read-only: NO descarga ni modifica el
    manifest. Reporta qué hay para bumpear.

.DESCRIPTION
    Para cada entry pinned con 'checkUpdate' definido:
      - GitHub API:        parsea JSON y compara tag_name vs version actual
      - Cualquier otra:    descarga la pagina HTML y busca un patron de version

    Sugerencia: correr cada par de semanas o antes de un release.

.EXAMPLE
    .\tools\Check-ToolUpdates.ps1
    .\tools\Check-ToolUpdates.ps1 -Verbose
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[string] $manifestPath = Join-Path $PSScriptRoot 'manifest.json'
if (-not (Test-Path $manifestPath)) {
    Write-Error "No se encontro tools\manifest.json en $PSScriptRoot"
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

[System.Collections.Generic.List[PSCustomObject]] $results = [System.Collections.Generic.List[PSCustomObject]]::new()

function _Get-GithubLatestTag {
    param([string] $ApiUrl)
    try {
        $resp = Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'PCTk-CheckUpdates' } -TimeoutSec 15
        return [PSCustomObject]@{
            Tag      = [string] $resp.tag_name
            Assets   = @($resp.assets | ForEach-Object { $_.name })
            HtmlUrl  = [string] $resp.html_url
        }
    } catch {
        return $null
    }
}

function _Get-VersionFromHtml {
    param(
        [string] $Url,
        [string] $VersionPattern = ''
    )
    try {
        $html = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15).Content

        # 1. Patron explicito del manifest (mas confiable). Captura una version completa.
        if (-not [string]::IsNullOrWhiteSpace($VersionPattern) -and $html -match $VersionPattern) {
            if ($Matches.Count -gt 1) {
                # Si el regex tiene grupos numerados, los ensamblamos como version
                [string[]] $parts = @()
                for ([int] $i = 1; $i -lt $Matches.Count; $i++) { $parts += [string] $Matches[$i] }
                return ($parts -join '.')
            }
            return [string] $Matches[0]
        }
        # Si hay versionPattern pero no matchea, NO hacemos fallback (evita falsos positivos)
        if (-not [string]::IsNullOrWhiteSpace($VersionPattern)) {
            return ''
        }

        # 2. Sin patron — heuristica generica (puede dar falsos positivos)
        if ($html -match '(?i)(?:version|v(?:ersion)?\.?\s*)\s*(\d+(?:\.\d+){1,3})') {
            return $Matches[1]
        }
    } catch { }
    return ''
}

function _Compare-Versions {
    param([string] $Current, [string] $Upstream)
    if ([string]::IsNullOrWhiteSpace($Current) -or [string]::IsNullOrWhiteSpace($Upstream)) { return 'UNKNOWN' }
    # Strip leading 'v' si tiene
    $c = $Current.TrimStart('v','V')
    $u = $Upstream.TrimStart('v','V')
    if ($c -eq $u) { return 'CURRENT' }
    try {
        # Pad ambos a 4 niveles para que [version] no se queje
        $padFn = { param($v); $parts = $v.Split('.'); while ($parts.Count -lt 4) { $parts += '0' }; ($parts -join '.') }
        $cv = [version] (& $padFn $c)
        $uv = [version] (& $padFn $u)
        if ($uv -gt $cv) { return 'OUTDATED' }
        if ($uv -lt $cv) { return 'AHEAD' }
        return 'CURRENT'
    } catch {
        return 'UNKNOWN'
    }
}

Write-Host ''
Write-Host 'PCTk — Tool update checker' -ForegroundColor Cyan
Write-Host '============================'

foreach ($tool in $manifest.tools) {
    [string] $policy = if ($tool.PSObject.Properties['updatePolicy']) { [string] $tool.updatePolicy } else { 'latest' }
    if ($policy -ne 'pinned') { continue }
    [string] $checkUpdate = ''
    if ($null -ne $tool.PSObject.Properties['checkUpdate']) {
        $checkUpdate = [string] $tool.checkUpdate
    }
    if ([string]::IsNullOrWhiteSpace($checkUpdate)) {
        [string] $currentForNoChecker = ''
        if ($null -ne $tool.PSObject.Properties['version']) { $currentForNoChecker = [string] $tool.version }
        $results.Add([PSCustomObject]@{
            Name      = $tool.name
            Current   = $currentForNoChecker
            Upstream  = ''
            Status    = 'NO-CHECKER'
            Note      = 'sin checkUpdate definido'
        })
        continue
    }

    [string] $current = if ($null -ne $tool.PSObject.Properties['version']) { [string] $tool.version } else { '' }
    [string] $checkUrl = $checkUpdate
    [string] $upstream = ''
    [string] $note     = ''

    Write-Verbose ("Checking {0} via {1}" -f $tool.name, $checkUrl)

    if ($checkUrl -match 'api\.github\.com') {
        $gh = _Get-GithubLatestTag -ApiUrl $checkUrl
        if ($null -ne $gh) {
            $upstream = $gh.Tag
            # Para BCUninstaller, el tag es 'v6.1' pero el asset incluye '6.1.0.1'
            # Si la version actual del manifest es mas larga, usamos el asset name como upstream
            $portableAsset = @($gh.Assets | Where-Object { $_ -match '_portable\.zip$' }) | Select-Object -First 1
            if ($portableAsset -and $portableAsset -match '_(\d+(?:\.\d+){1,3})_portable\.zip$') {
                $upstream = $Matches[1]
                $note = "asset: $portableAsset"
            }
        } else {
            $note = 'GitHub API no respondio'
        }
    } else {
        [string] $versionPattern = ''
        if ($null -ne $tool.PSObject.Properties['versionPattern']) {
            $versionPattern = [string] $tool.versionPattern
        }
        $upstream = _Get-VersionFromHtml -Url $checkUrl -VersionPattern $versionPattern
        if ([string]::IsNullOrWhiteSpace($upstream)) { $note = 'no se detecto version en HTML' }
    }

    [string] $status = _Compare-Versions -Current $current -Upstream $upstream

    $results.Add([PSCustomObject]@{
        Name     = $tool.name
        Current  = $current
        Upstream = $upstream
        Status   = $status
        Note     = $note
    })
}

# Reporte
Write-Host ''
$results | Format-Table -AutoSize -Property Name, Current, Upstream, Status, Note

[int] $outdated = @($results | Where-Object { $_.Status -eq 'OUTDATED' }).Count
[int] $unknown  = @($results | Where-Object { $_.Status -eq 'UNKNOWN' -or $_.Status -eq 'NO-CHECKER' }).Count
[int] $current  = @($results | Where-Object { $_.Status -eq 'CURRENT' }).Count

Write-Host ''
if ($outdated -gt 0) {
    Write-Host ("  [!] {0} tool(s) OUTDATED — bump version + url en manifest.json y verificar SHA-256." -f $outdated) -ForegroundColor Yellow
}
if ($unknown -gt 0) {
    Write-Host ("  [?] {0} tool(s) sin verificar — chequear manualmente." -f $unknown) -ForegroundColor DarkGray
}
Write-Host ("  [OK] {0} tool(s) up-to-date." -f $current) -ForegroundColor Green

if ($outdated -gt 0) { exit 1 }
exit 0
