#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test mínimo para los módulos del toolkit. Verifica que las funciones
    expuestas se pueden invocar sin tirar excepción en una máquina típica.
    Read-only: solo invoca funciones de detección / preview, NUNCA las que mutan
    el sistema (Disable-BloatServices, Optimize-Network, etc.).

.DESCRIPTION
    Para correr antes de cualquier release o después de cambios en módulos.
    Output: tabla con OK/FAIL por función + exit code 0 si todos pasan, 1 si alguno falla.

.EXAMPLE
    .\tests\smoke.ps1                # corre todos
    .\tests\smoke.ps1 -Module Network # solo un módulo
#>

[CmdletBinding()]
param(
    [string] $Module = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
[string] $modulesDir = Join-Path $repoRoot 'modules'
[string] $coreDir    = Join-Path $repoRoot 'core'
[string] $utilsDir   = Join-Path $repoRoot 'utils'

# Dot-source en orden de dependencia: utils → core → modules
foreach ($folder in @($utilsDir, $coreDir, $modulesDir)) {
    Get-ChildItem -Path $folder -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}

[System.Collections.Generic.List[PSCustomObject]] $results =
    [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-SmokeFunction {
    param(
        [string] $ModuleName,
        [string] $FunctionName,
        [scriptblock] $Invocation
    )

    if (-not [string]::IsNullOrWhiteSpace($script:Module) -and $ModuleName -ne $script:Module) {
        return
    }

    [string] $status = 'OK'
    [string] $errMsg = ''
    [int] $durationMs = 0

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & $Invocation
        $sw.Stop()
        $durationMs = [int] $sw.ElapsedMilliseconds
    }
    catch {
        $status = 'FAIL'
        $errMsg = $_.Exception.Message
        if ($null -ne $sw) { $sw.Stop() }
    }

    $script:results.Add([PSCustomObject]@{
        Module     = $ModuleName
        Function   = $FunctionName
        Status     = $status
        DurationMs = $durationMs
        Error      = $errMsg
    })
}

# ─── core ─────────────────────────────────────────────────────────────────────
Test-SmokeFunction 'MachineProfile' 'Get-MachineProfile' { Get-MachineProfile }

# ─── modules: solo funciones read-only / preview ──────────────────────────────
Test-SmokeFunction 'Apps' 'Get-InstalledWin32Apps' { Get-InstalledWin32Apps }
Test-SmokeFunction 'Apps' 'Get-InstalledUwpApps'   { Get-InstalledUwpApps }

Test-SmokeFunction 'Cleanup' 'Get-CleanupPreview' { Get-CleanupPreview }

Test-SmokeFunction 'Diagnostics' 'Get-BsodHistory' { Get-BsodHistory -Days 7 }

Test-SmokeFunction 'Network' 'Get-NetworkDiagnostics' { Get-NetworkDiagnostics }

Test-SmokeFunction 'Privacy' 'Test-ShutUp10Available' { Test-ShutUp10Available }
Test-SmokeFunction 'Privacy' 'Get-ShutUp10Path'       { Get-ShutUp10Path }

Test-SmokeFunction 'StartupManager' 'Get-StartupEntries' { Get-StartupEntries }

Test-SmokeFunction 'Telemetry' 'Get-SystemSnapshot' { Get-SystemSnapshot -Phase Pre }

Test-SmokeFunction 'ToolkitSupport' 'Get-WindowsUpdateStatus' {
    Get-WindowsUpdateStatus -IsLtsc $false
}
Test-SmokeFunction 'ToolkitSupport' 'Convert-ToolkitDateDisplay' {
    Convert-ToolkitDateDisplay -Value (Get-Date)
}

# ─── Reporte ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '────────────────────────────────────────────────────────────────────'
Write-Host '  SMOKE TEST RESULTS'
Write-Host '────────────────────────────────────────────────────────────────────'

$results | Format-Table -AutoSize -Property Module, Function, Status, DurationMs

[int] $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
[int] $okCount   = @($results | Where-Object { $_.Status -eq 'OK' }).Count

Write-Host ''
Write-Host ('  OK: {0}  FAIL: {1}' -f $okCount, $failCount) -ForegroundColor $(
    if ($failCount -gt 0) { 'Red' } else { 'Green' }
)

if ($failCount -gt 0) {
    Write-Host ''
    Write-Host '  Errores:' -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host ('    [{0}::{1}] {2}' -f $_.Module, $_.Function, $_.Error) -ForegroundColor Red
    }
    exit 1
}

exit 0
