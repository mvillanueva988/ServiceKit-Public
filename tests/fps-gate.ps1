#Requires -Version 5.1
<#
.SYNOPSIS
    Gate HW de #90 (4), kit de medicion de FPS: con CS2 abierto en el mapa de
    Workshop "CS2 FPS Benchmark", hace 3 capturas seguidas con PresentMon y
    escribe PASS/FAIL + resumen a output\medicion-fps\gate-<timestamp>.txt.

.DESCRIPTION
    Correr en una consola de ADMINISTRADOR (PresentMon lee frames por ETW), con
    CS2 abierto y dibujando (el recorrido del benchmark o parado en el mapa). Sin
    CS2 falla limpio con "abri CS2". Si PresentMon no esta en tools\bin lo baja
    con Bootstrap-Tools.ps1 (version fijada + SHA256 del manifest).
    Exit 0 = PASS, 1 = FAIL.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\fps-gate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\fps-gate.ps1 -Seconds 45 -DelaySeconds 10
#>
[CmdletBinding()]
param(
    [int] $Seconds = 30,
    [int] $DelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # espejo de main.ps1

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
foreach ($folder in @('utils', 'core', 'modules')) {
    foreach ($f in @(Get-ChildItem -Path (Join-Path $repoRoot $folder) -Filter '*.ps1' -File | Sort-Object -Property Name)) {
        . $f.FullName
    }
}

$g = Invoke-FpsGate -Seconds $Seconds -DelaySeconds $DelaySeconds
if ($g.Pass) { exit 0 }
exit 1
