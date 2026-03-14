#Requires -Version 5.1

param(
    [switch] $DryRun,
    [switch] $KeepDist
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host ("`n==> {0}" -f $Message) -ForegroundColor Cyan
}

function Remove-GeneratedItems {
    param(
        [string] $Root,
        [bool] $IsDryRun
    )

    $targets = @(
        (Join-Path $Root 'output\audit\*.jsonl'),
        (Join-Path $Root 'output\snapshots\*.json'),
        (Join-Path $Root 'output\driver_backup\*')
    )

    if (-not $KeepDist) {
        $targets += (Join-Path $Root 'dist\*.zip')
        $targets += (Join-Path $Root 'dist\*.sha256')
    }

    [int] $deleted = 0

    foreach ($pattern in $targets) {
        $items = @(Get-ChildItem -Path $pattern -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if ($IsDryRun) {
                Write-Host ("  [dry-run] remove {0}" -f $item.FullName) -ForegroundColor DarkYellow
            }
            else {
                if ($item.PSIsContainer) {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                else {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
                Write-Host ("  [ok] removed {0}" -f $item.FullName) -ForegroundColor DarkGray
            }
            $deleted++
        }
    }

    Write-Host ("  Total candidate/generated items: {0}" -f $deleted) -ForegroundColor Green
}

function Ensure-GeneratedFolders {
    param([string] $Root)

    $folders = @(
        (Join-Path $Root 'output'),
        (Join-Path $Root 'output\audit'),
        (Join-Path $Root 'output\snapshots'),
        (Join-Path $Root 'output\driver_backup'),
        (Join-Path $Root 'dist'),
        (Join-Path $Root 'tools\bin'),
        (Join-Path $Root '_local-dev')
    )

    foreach ($folder in $folders) {
        if (-not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
            Write-Host ("  [ok] created {0}" -f $folder) -ForegroundColor DarkGray
        }
    }
}

function Test-TrackedSensitivePaths {
    param([string] $Root)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host '  [warn] git no esta disponible; se omite validacion de tracking.' -ForegroundColor Yellow
        return $true
    }

    Push-Location $Root
    try {
        $tracked = @(git ls-files)
    }
    finally {
        Pop-Location
    }

    $forbiddenPrefixes = @(
        '.gsd/',
        '.github/',
        'Logs/',
        'output/',
        '_local-dev/',
        'get-stuff-done-for-github-copilot.code-workspace'
    )

    $matches = @()
    foreach ($path in $tracked) {
        $norm = ($path -replace '\\', '/')
        foreach ($prefix in $forbiddenPrefixes) {
            if ($norm.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += $path
                break
            }
        }
    }

    if ($matches.Count -gt 0) {
        Write-Host '  [error] Hay rutas internas/generadas trackeadas en git:' -ForegroundColor Red
        $matches | Sort-Object -Unique | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor Red }
        return $false
    }

    Write-Host '  [ok] No hay rutas internas/generadas trackeadas.' -ForegroundColor Green
    return $true
}

function Show-ProjectLayout {
    param([string] $Root)

    Write-Host "`n=== Layout de carpetas (referencia) ===" -ForegroundColor Cyan

    [string[]] $functional = @('core', 'modules', 'utils', 'tools', 'main.ps1', 'Launch.ps1', 'Release.ps1', 'Bootstrap-Tools.ps1', 'Run.bat', 'README.md')
    [string[]] $generated  = @('output', 'dist', 'tools/bin')
    [string[]] $localOnly  = @('_local-dev')

    Write-Host '  Toolkit funcional (se publica):' -ForegroundColor Green
    foreach ($entry in $functional) {
        Write-Host ("    - {0}" -f $entry)
    }

    Write-Host '  Generado por scripts/runtime (no se versiona):' -ForegroundColor Yellow
    foreach ($entry in $generated) {
        Write-Host ("    - {0}" -f $entry)
    }

    Write-Host '  Desarrollo interno local (no se publica):' -ForegroundColor Magenta
    foreach ($entry in $localOnly) {
        Write-Host ("    - {0}" -f $entry)
    }
}

[string] $repoRoot = $PSScriptRoot

Write-Step 'Validando estructura base de carpetas'
Ensure-GeneratedFolders -Root $repoRoot

Write-Step 'Limpiando artefactos generados (runtime y release local)'
Remove-GeneratedItems -Root $repoRoot -IsDryRun:$DryRun

Write-Step 'Validando que no haya tracking de rutas internas/generadas'
$trackingOk = Test-TrackedSensitivePaths -Root $repoRoot

Write-Step 'Mostrando layout recomendado'
Show-ProjectLayout -Root $repoRoot

if (-not $trackingOk) {
    throw 'Se detectaron rutas internas o generadas trackeadas en git. Revisar antes de publicar.'
}

Write-Host "`nPrep-ReleaseWorkspace completado." -ForegroundColor Green
if ($DryRun) {
    Write-Host 'Modo dry-run activo: no se borraron archivos.' -ForegroundColor DarkYellow
}
