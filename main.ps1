#Requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-ToolkitLoader {
    [CmdletBinding()]
    param()

    foreach ($folder in @('core', 'modules')) {
        $folderPath = Join-Path $PSScriptRoot $folder
        $scripts = Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        foreach ($script in $scripts) {
            . $script.FullName
        }
    }
}

Invoke-ToolkitLoader
