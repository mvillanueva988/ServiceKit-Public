#Requires -Version 5.1
<#
.SYNOPSIS
    Regenera los golden de los menus (#72): la foto en texto y su capa de color
    del menu principal (120x30 y 120x44), del submenu [A] (120x30 y 120x44), del
    submenu [2] (120x30) y del submenu [F] (120x30).

.DESCRIPTION
    El smoke NUNCA escribe los golden: los compara. Este script es la unica via
    para reescribirlos, y se corre solo cuando el cambio de la foto es deliberado
    (un layout nuevo, un boton nuevo). Va en el mismo commit que el cambio de
    codigo, asi el diff del golden muestra lo que cambio en pantalla.

    New-SmokeMenuFixture, Get-SmokeMenuTarget y Get-SmokeMenuPhoto salen de
    tests\smoke.ps1 por AST: una sola definicion de la foto, la misma que compara
    el smoke.

    Formato: UTF-8 sin BOM, una linea por fila de consola, separador LF (el smoke
    parte por \r?\n: con autocrlf=true el checkout puede traer CRLF).

.PARAMETER Menu
    Que menus regenerar (por defecto, todos). Regenerar solo el que cambio a
    proposito deja los demas como estan.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\golden\regenerar-menus.ps1 -Menu Acciones
#>
[CmdletBinding()]
param(
    [ValidateSet('Principal', 'Acciones', 'Receta', 'Fps')]
    [string[]] $Menu = @('Principal', 'Acciones', 'Receta', 'Fps')
)

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
foreach ($name in @('New-SmokeMenuFixture', 'Get-SmokeMenuTarget', 'Get-SmokeMenuPhoto')) {
    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    if ($null -eq $fn) { throw ('no encontre {0} en tests\smoke.ps1' -f $name) }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# Los tamanios de cada menu: los mismos que compara el smoke.
$sizes = @{
    Principal = @(@(120, 30), @(120, 44))
    Acciones  = @(@(120, 30), @(120, 44))
    Receta    = @(, @(120, 30))
    Fps       = @(, @(120, 30))
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($m in $Menu) {
    [string] $golden = (Get-SmokeMenuTarget -Menu $m).Golden
    foreach ($size in @($sizes[$m])) {
        [int] $w = $size[0]
        [int] $h = $size[1]
        $photo = Get-SmokeMenuPhoto -Width $w -Height $h -Menu $m
        [string] $base = Join-Path $goldenDir ('{0}-{1}x{2}' -f $golden, $w, $h)
        [System.IO.File]::WriteAllText($base + '.txt',     ((@($photo.Lines) -join "`n") + "`n"), $utf8NoBom)
        [System.IO.File]::WriteAllText($base + '.sgr.txt', ((@($photo.Sgr)   -join "`n") + "`n"), $utf8NoBom)
        Write-Output ('{0} {1}x{2}: {3} lineas -> {4}.txt / .sgr.txt' -f $m, $w, $h, @($photo.Lines).Count, $base)
    }
}
