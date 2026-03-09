#Requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-ToolkitLoader {
    [CmdletBinding()]
    param()

    $modulesPath = Join-Path $PSScriptRoot 'modules'

    if (-not (Test-Path -Path $modulesPath -PathType Container)) {
        return
    }

    $scripts = Get-ChildItem -Path $modulesPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue

    foreach ($script in $scripts) {
        . $script.FullName
    }
}

Invoke-ToolkitLoader
