Set-StrictMode -Version Latest

# ─── Test-ShutUp10Available ───────────────────────────────────────────────────
function Test-ShutUp10Available {
    [CmdletBinding()]
    param()
    return (Test-Path (Join-Path $PSScriptRoot '..\tools\bin\OOSU10.exe'))
}

# ─── Open-ShutUp10 ────────────────────────────────────────────────────────────
function Open-ShutUp10 {
    [CmdletBinding()]
    param()

    [string] $exePath = Join-Path $PSScriptRoot '..\tools\bin\OOSU10.exe'

    if (-not (Test-Path $exePath)) {
        return [PSCustomObject]@{ Success = $false; Error = 'OOSU10.exe no encontrado. Descargalo desde [T] Herramientas.' }
    }

    try {
        Start-Process -FilePath $exePath
        return [PSCustomObject]@{ Success = $true }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
