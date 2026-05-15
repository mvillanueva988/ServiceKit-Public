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

# ─── Static check: BOM regression detector ────────────────────────────────────
# Cuando un .ps1 tiene bytes no-ASCII (em-dash, tildes en string literals) y
# está guardado sin BOM, PowerShell 5.1 en locale es-AR lo lee como CP-1252 y
# revienta el parser. Este es un bug que ya nos mordió 2 veces (Stage 0 PR0
# y Stage 1 cuando edité MachineProfile/Privacy). Lo chequeamos cada smoke run.
function Test-BomRegression {
    [string] $rRoot = (Split-Path -Parent $PSScriptRoot)
    [string[]] $patterns = @('core\*.ps1', 'modules\*.ps1', 'utils\*.ps1', 'tools\*.ps1', 'main.ps1', 'Launch.ps1', 'Release.ps1', 'Bootstrap-Tools.ps1')
    [System.Collections.Generic.List[string]] $atRisk = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $rRoot $p) -File -ErrorAction SilentlyContinue)) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            [bool] $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
            if ($hasBom) { continue }
            [bool] $hasNonAscii = $false
            foreach ($byte in $b) { if ($byte -gt 127) { $hasNonAscii = $true; break } }
            if ($hasNonAscii) {
                $atRisk.Add($f.FullName.Substring($rRoot.Length + 1))
            }
        }
    }
    if ($atRisk.Count -gt 0) {
        throw ('BOM missing en {0} archivo(s) con bytes non-ASCII: {1}. Aplicar BOM UTF-8 antes de commit.' -f $atRisk.Count, ($atRisk -join ', '))
    }
}

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

# ─── static checks ────────────────────────────────────────────────────────────
Test-SmokeFunction 'StaticCheck' 'BomRegression' { Test-BomRegression }

# ─── core ─────────────────────────────────────────────────────────────────────
Test-SmokeFunction 'MachineProfile' 'Get-MachineProfile' { Get-MachineProfile }
Test-SmokeFunction 'MachineProfile' 'IsVirtualMachine field' {
    (Get-MachineProfile).PSObject.Properties['IsVirtualMachine']
}

# ─── modules: solo funciones read-only / preview ──────────────────────────────
Test-SmokeFunction 'Apps' 'Get-InstalledWin32Apps' { Get-InstalledWin32Apps }
Test-SmokeFunction 'Apps' 'Get-InstalledUwpApps'   { Get-InstalledUwpApps }

Test-SmokeFunction 'Cleanup' 'Get-CleanupPreview' { Get-CleanupPreview }

Test-SmokeFunction 'Diagnostics' 'Get-BsodHistory' { Get-BsodHistory -Days 7 }

Test-SmokeFunction 'Network' 'Get-NetworkDiagnostics' { Get-NetworkDiagnostics }

Test-SmokeFunction 'Privacy' 'Test-ShutUp10Available' { Test-ShutUp10Available }
Test-SmokeFunction 'Privacy' 'Get-ShutUp10Path'       { Get-ShutUp10Path }

Test-SmokeFunction 'StartupManager' 'Get-StartupEntries' { Get-StartupEntries }

Test-SmokeFunction 'Telemetry' 'Test-IsVirtualMachine' { Test-IsVirtualMachine }
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout returns on time' {
    Invoke-WithTimeout -ScriptBlock { 42 } -TimeoutSeconds 5
}
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout honors timeout' {
    # debe devolver el Default sin colgar el smoke (~2s, no el sleep)
    Invoke-WithTimeout -ScriptBlock { Start-Sleep 30; 'NO' } -TimeoutSeconds 2 -Default 'TIMEOUT'
}

$script:_snapshotResult = $null
Test-SmokeFunction 'Telemetry' 'Get-SystemSnapshot' {
    $script:_snapshotResult = Get-SystemSnapshot -Phase Pre
    $script:_snapshotResult
}
Test-SmokeFunction 'Telemetry' 'Snapshot has IsVirtualMachine field' {
    if ($null -eq $script:_snapshotResult) { throw 'Snapshot no disponible (test previo fallo)' }
    $script:_snapshotResult.PSObject.Properties['IsVirtualMachine'] | Out-Null
    if ($null -eq $script:_snapshotResult.PSObject.Properties['IsVirtualMachine']) {
        throw 'Campo IsVirtualMachine ausente en snapshot'
    }
    if ($null -eq $script:_snapshotResult.PSObject.Properties['VmVendor']) {
        throw 'Campo VmVendor ausente en snapshot'
    }
    if ($null -eq $script:_snapshotResult.PSObject.Properties['QueryTimings']) {
        throw 'Campo QueryTimings ausente en snapshot'
    }
}

Test-SmokeFunction 'ToolkitSupport' 'Get-WindowsUpdateStatus' {
    Get-WindowsUpdateStatus -IsLtsc $false
}
Test-SmokeFunction 'ToolkitSupport' 'Convert-ToolkitDateDisplay' {
    Convert-ToolkitDateDisplay -Value (Get-Date)
}

# ─── Stage 2: ProfileEngine (read-only: path + import/validate) ──────────────
Test-SmokeFunction 'ProfileEngine' 'Get-AutoProfilePath'  { Get-AutoProfilePath -UseCase generic -Tier Mid }
Test-SmokeFunction 'ProfileEngine' 'Import generic_low'   { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase generic -Tier Low) }
Test-SmokeFunction 'ProfileEngine' 'Import generic_mid'   { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase generic -Tier Mid) }
Test-SmokeFunction 'ProfileEngine' 'Import generic_high'  { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase generic -Tier High) }

# ─── Stage 0 new modules (read-only paths only) ───────────────────────────────
Test-SmokeFunction 'CoreIsolation' 'Get-CoreIsolationStatus' { Get-CoreIsolationStatus }

Test-SmokeFunction 'UsbPower' 'Get-UsbSelectiveSuspendStatus' { Get-UsbSelectiveSuspendStatus }

Test-SmokeFunction 'Hags' 'Get-HagsStatus' { Get-HagsStatus }

Test-SmokeFunction 'Wsl' 'Test-WslAvailable' { Test-WslAvailable }
Test-SmokeFunction 'Wsl' 'Get-WslConfig'     { Get-WslConfig }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Default)' { New-WslConfig -Preset Default }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Gaming)'  { New-WslConfig -Preset Gaming }
Test-SmokeFunction 'Wsl' 'New-WslConfig (DevHeavy)' { New-WslConfig -Preset DevHeavy }

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
