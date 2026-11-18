#Requires -Version 5.1
<#
.SYNOPSIS
    Regenera los golden del menu principal (#72): la foto en texto y su capa de
    color a 120x30 y a 120x44.

.DESCRIPTION
    El smoke NUNCA escribe los golden: los compara. Este script es la unica via
    para reescribirlos, y se corre solo cuando el cambio de la foto es deliberado
    (un layout nuevo, un boton nuevo). Va en el mismo commit que el cambio de
    codigo, asi el diff del golden muestra lo que cambio en pantalla.

    New-SmokeMenuFixture y Get-SmokeMenuPhoto salen de tests\smoke.ps1 por AST:
    una sola definicion de la foto, la misma que compara el smoke.

    Formato: UTF-8 sin BOM, una linea por fila de consola, separador LF (el smoke
    parte por \r?\n: con autocrlf=true el checkout puede traer CRLF).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\golden\regenerar-menu-principal.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[string] $goldenDir = $PSScriptRoot
[string] $testsDir  = Split-Path -Parent $goldenDir
[string] $repoRoot  = Split-Path -Parent $testsDir

foreach ($folder in @('utils', 'core', 'modules')) {
    Get-ChildItem -Path (Join-Path $repoRoot $folder) -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $testsDir 'smoke.ps1'), [ref] $tokens, [ref] $parseErrors)
if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) { throw ('tests\smoke.ps1 no parsea: {0}' -f @($parseErrors)[0].Message) }
foreach ($name in @('New-SmokeMenuFixture', 'Get-SmokeMenuPhoto')) {
    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    if ($null -eq $fn) { throw ('no encontre {0} en tests\smoke.ps1' -f $name) }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($size in @(@(120, 30), @(120, 44))) {
    [int] $w = $size[0]
    [int] $h = $size[1]
    $photo = Get-SmokeMenuPhoto -Width $w -Height $h
    [string] $base = Join-Path $goldenDir ('menu-principal-{0}x{1}' -f $w, $h)
    [System.IO.File]::WriteAllText($base + '.txt',     ((@($photo.Lines) -join "`n") + "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($base + '.sgr.txt', ((@($photo.Sgr)   -join "`n") + "`n"), $utf8NoBom)
    Write-Output ('{0}x{1}: {2} lineas -> {3}.txt / .sgr.txt' -f $w, $h, @($photo.Lines).Count, $base)
}
