#Requires -Version 5.1
<#
.SYNOPSIS
    Gate HW de #54 (A): corre el diagnostico REAL de Defender por el handler de [A][19] [M]
    y escribe PASS/FAIL + la salida a output\defender\hw-check_<sello>.txt.
.DESCRIPTION
    Solo lectura sobre la config del equipo. Precondiciona: Defender disponible y la sesion
    elevada o no segun -Elevated. Si la precondicion no se cumple sale con FAIL (no corre).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\defender-diag-hw.ps1            # no elevado
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\defender-diag-hw.ps1 -Elevated   # desde consola admin
#>
[CmdletBinding()]
param([switch] $Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # espejo de main.ps1

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
foreach ($folder in @('utils', 'core', 'modules')) {
    Get-ChildItem -Path (Join-Path $repoRoot $folder) -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
}

[string] $outDir = Join-Path $repoRoot 'output\defender'
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
[string] $hwPath = Join-Path $outDir ('hw-check_{0}.txt' -f (Get-PctkStamp))

[System.Collections.Generic.List[string]] $log = [System.Collections.Generic.List[string]]::new()
[System.Collections.Generic.List[string]] $fails = [System.Collections.Generic.List[string]]::new()

function Save-HwCheck {
    param([string] $Verdict)
    [string[]] $all = @(('{0}: defender-diag-hw ({1})' -f $Verdict, $(if ($Elevated) { 'elevado' } else { 'no elevado' }))) + @($fails | ForEach-Object { 'FAIL: ' + $_ }) + @('') + @($log)
    [System.IO.File]::WriteAllLines($hwPath, $all, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ('  {0}  -> {1}' -f $Verdict, $hwPath)
}

# Precondiciones
[bool] $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin -ne [bool]$Elevated) {
    [string] $have = if ($isAdmin) { 'elevada' } else { 'NO elevada' }
    [string] $want = if ($Elevated) { '-Elevated' } else { 'no elevado' }
    $fails.Add(('precondicion: la sesion esta {0} pero se pidio {1}' -f $have, $want))
    Save-HwCheck 'FAIL'; exit 1
}
$def = Get-DefenderDiagStatus
if (-not $def.Available) {
    $fails.Add(('precondicion: Defender no disponible: {0}' -f $def.Reason))
    Save-HwCheck 'FAIL'; exit 1
}

# Corrida real por el handler (Read-Host -> 'M'); Write-Host se captura con *>&1.
function Read-Host { param([object] $Prompt) return 'M' }
[string] $captured = ''
try {
    $captured = (Invoke-ActionDefenderScan -MachineProfile ([PSCustomObject]@{}) *>&1 | Out-String)
} catch {
    $fails.Add(('el handler tiro: {0}' -f $_.Exception.Message))
}
$log.Add($captured)

# Verificaciones
[object[]] $txts = @(Get-ChildItem -LiteralPath $outDir -Filter 'diagnostico_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($txts.Count -eq 0) {
    $fails.Add('no quedo diagnostico_*.txt')
} else {
    [string] $txt = [System.IO.File]::ReadAllText($txts[0].FullName)
    if ($txt -notmatch 'min de CPU en [\d.]+ h de uptime = [\d.]+ % del CPU entero') { $fails.Add('el .txt no trae la linea del paso 4') }
    if ($txt -notmatch 'Paso 1\.' -or $txt -notmatch 'Paso 2\.' -or $txt -notmatch 'Paso 3\.' -or $txt -notmatch 'Paso 4\.') { $fails.Add('faltan pasos en el .txt') }
    if (-not $Elevated -and $txt -match 'Paso [123]\..*\r?\n\s*Skipped:.*acceso denegado') { $fails.Add('un paso 1-3 pidio admin') }
    $log.Add('--- ' + $txts[0].FullName)
}
if (@(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'pctk-defdiag-*' -ErrorAction SilentlyContinue).Count -gt 0) {
    $fails.Add('quedo una carpeta pctk-defdiag-* en TEMP (solo se informa, no se borra)')
}

if ($fails.Count -gt 0) { Save-HwCheck 'FAIL'; exit 1 }
Save-HwCheck 'PASS'
exit 0
