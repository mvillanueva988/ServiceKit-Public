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

# §6.4 — read-only: preview shapes, NUNCA llamar Invoke-*Uninstall en smoke
Test-SmokeFunction 'Apps' 'Get-Win32UninstallPreview MSI' {
    $fake = [PSCustomObject]@{
        Name                 = 'Fake App'
        UninstallString      = 'MsiExec.exe /X{12345678-1234-1234-1234-1234567890AB}'
        QuietUninstallString = ''
    }
    $p = Get-Win32UninstallPreview -App $fake
    if ($p.Method -ne 'MSI')             { throw ('Method MSI esperado; got {0}' -f $p.Method) }
    if ($p.CommandLine -notmatch '/X\{') { throw ('CommandLine debe tener /X{; got {0}' -f $p.CommandLine) }
}
Test-SmokeFunction 'Apps' 'Get-UwpUninstallPreview shape' {
    $fake = [PSCustomObject]@{ PackageFullName = 'Foo_1.0_x64__abc' }
    $p = Get-UwpUninstallPreview -App $fake
    if ($p.Success -ne $true)                           { throw ('Success=$true esperado; got {0}' -f $p.Success) }
    if ($p.CommandLine -notmatch 'Remove-AppxPackage')  { throw ('CommandLine debe tener Remove-AppxPackage; got {0}' -f $p.CommandLine) }
}

Test-SmokeFunction 'Cleanup' 'Get-CleanupPreview' { Get-CleanupPreview }

Test-SmokeFunction 'Diagnostics' 'Get-BsodHistory' { Get-BsodHistory -Days 7 }

Test-SmokeFunction 'Network' 'Get-NetworkDiagnostics' { Get-NetworkDiagnostics }

Test-SmokeFunction 'Privacy' 'Test-ShutUp10Available' { Test-ShutUp10Available }
Test-SmokeFunction 'Privacy' 'Get-ShutUp10Path'       { Get-ShutUp10Path }

Test-SmokeFunction 'StartupManager' 'Get-StartupEntries' { Get-StartupEntries }

# §6.3: Set-StartupEntry early-return paths — entradas SINTETICAS, cero mutacion
Test-SmokeFunction 'StartupManager' 'Set-StartupEntry rechaza RunOnce' {
    $e = [PSCustomObject]@{ Name='x'; Enabled=$true; CanToggle=$false; Type='Registry'; ApprovedPath=$null; FilePath=$null }
    $r = Set-StartupEntry -Entry $e -Enabled $false
    if ($r.Success -ne $false) { throw ('Success debe ser $false para RunOnce; got {0}' -f $r.Success) }
}
Test-SmokeFunction 'StartupManager' 'Set-StartupEntry no-op si ya en estado' {
    $e = [PSCustomObject]@{ Name='x'; Enabled=$true; CanToggle=$true; Type='Registry'; ApprovedPath=$null; FilePath=$null }
    $r = Set-StartupEntry -Entry $e -Enabled $true
    if ($r.Success -ne $true)    { throw ('Success debe ser $true para no-op; got {0}' -f $r.Success) }
    if ($r.AlreadySet -ne $true) { throw ('AlreadySet debe ser $true para no-op; got {0}' -f $r.AlreadySet) }
}

Test-SmokeFunction 'Telemetry' 'Test-IsVirtualMachine' { Test-IsVirtualMachine }
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout returns on time' {
    $r = Invoke-WithTimeout -ScriptBlock { 42 } -TimeoutSeconds 5
    if (-not $r.Ok) { throw ('Debe ser Ok=$true; Ok={0}' -f $r.Ok) }
    if ($r.TimedOut) { throw 'No debe ser TimedOut' }
    if ($r.Value[0] -ne 42) { throw ('Value[0] debe ser 42; got {0}' -f $r.Value[0]) }
}
Test-SmokeFunction 'Telemetry' 'Invoke-WithTimeout honors timeout' {
    # debe devolver envelope con TimedOut=$true sin colgar el smoke (~2s, no el sleep)
    $r = Invoke-WithTimeout -ScriptBlock { Start-Sleep 30; 'NO' } -TimeoutSeconds 2 -Default 'TIMEOUT'
    if (-not $r.TimedOut) { throw ('Debe ser TimedOut=$true; TimedOut={0}' -f $r.TimedOut) }
    if ($r.Ok) { throw 'No debe ser Ok=$true en timeout' }
    if ($r.Value[0] -ne 'TIMEOUT') { throw ('Value[0] debe ser TIMEOUT; got {0}' -f $r.Value[0]) }
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

# ─── Stage 3: Office / Study / Multimedia recipes (read-only: import/validate) ─
Test-SmokeFunction 'ProfileEngine' 'Import office_low'      { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase office -Tier Low) }
Test-SmokeFunction 'ProfileEngine' 'Import office_mid'      { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase office -Tier Mid) }
Test-SmokeFunction 'ProfileEngine' 'Import office_high'     { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase office -Tier High) }
Test-SmokeFunction 'ProfileEngine' 'Import study_low'       { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase study -Tier Low) }
Test-SmokeFunction 'ProfileEngine' 'Import study_mid'       { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase study -Tier Mid) }
Test-SmokeFunction 'ProfileEngine' 'Import study_high'      { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase study -Tier High) }
Test-SmokeFunction 'ProfileEngine' 'Import multimedia_low'  { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase multimedia -Tier Low) }
Test-SmokeFunction 'ProfileEngine' 'Import multimedia_mid'  { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase multimedia -Tier Mid) }
Test-SmokeFunction 'ProfileEngine' 'Import multimedia_high' { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase multimedia -Tier High) }

# ─── Stage 0 new modules (read-only paths only) ───────────────────────────────
Test-SmokeFunction 'CoreIsolation' 'Get-CoreIsolationStatus' { Get-CoreIsolationStatus }

Test-SmokeFunction 'UsbPower' 'Get-UsbSelectiveSuspendStatus' { Get-UsbSelectiveSuspendStatus }

Test-SmokeFunction 'Hags' 'Get-HagsStatus' { Get-HagsStatus }

Test-SmokeFunction 'Wsl' 'Test-WslAvailable' { Test-WslAvailable }
Test-SmokeFunction 'Wsl' 'Get-WslConfig'     { Get-WslConfig }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Default)' { New-WslConfig -Preset Default }
Test-SmokeFunction 'Wsl' 'New-WslConfig (Gaming)'  { New-WslConfig -Preset Gaming }
Test-SmokeFunction 'Wsl' 'New-WslConfig (DevHeavy)' { New-WslConfig -Preset DevHeavy }

# Stage 4 — read-only (no mutan): editor/IO de recetas nombradas + helpers toggle
Test-SmokeFunction 'NamedProfileEditor' 'Get-NamedProfileDir'  { Get-NamedProfileDir }
Test-SmokeFunction 'NamedProfileEditor' 'Get-NamedProfileList' { Get-NamedProfileList }
Test-SmokeFunction 'NamedProfileEditor' 'Import/validate _sample' { Import-NamedProfile -Path (Join-Path (Get-NamedProfileDir) '_sample.json') }
# Regresion Bug2 (v2.0.1): Add-Tweak escribia $script:gt -> crash StrictMode al
# 1er toggle; ademas 410/438 leian $gt local -> receta vacia. Read-only: el
# builder solo construye/retorna un objeto (Get-*Status son deteccion).
# Shadow de Read-Host (funcion local) -> headless: 'f' hace toggles 'off'.
Test-SmokeFunction 'NamedProfileEditor' 'New-NamedProfileInteractive escribe gaming_tweaks' {
    function Read-Host { 'f' }
    $p = New-NamedProfileInteractive -MachineProfile (Get-MachineProfile)
    if ($null -eq $p) { throw 'New-NamedProfileInteractive devolvio $null' }
    $gtp = $p.PSObject.Properties['gaming_tweaks']
    if ($null -eq $gtp) { throw 'falta gaming_tweaks en la receta' }
    $hv = $gtp.Value.PSObject.Properties['hvci']
    if ($null -eq $hv -or [string]$hv.Value -ne 'off') {
        throw ("gaming_tweaks.hvci esperado 'off'; got {0}" -f $(if ($hv) { $hv.Value } else { '(ausente)' }))
    }
}
Test-SmokeFunction 'Performance' 'Get-GameModeStatus' { Get-GameModeStatus }
Test-SmokeFunction 'Privacy' 'Get-CustomDefenderExclusions' { Get-CustomDefenderExclusions }

# ─── ITEM C: Test-StepSucceeded (D-SD2 adapters, structural-debt-plan.md) ────
# Entradas read-only: solo ejercitan el helper con fixtures en memoria, sin mutar.
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded null -> false' {
    $r = Test-StepSucceeded -StepResult $null
    if ($r -ne $false) { throw ('null debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Success=$true -> true' {
    $obj = [PSCustomObject]@{ Success = $true }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Success=$true debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Success=$false -> false' {
    $obj = [PSCustomObject]@{ Success = $false }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Success=$false debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Errors no vacio -> false' {
    $obj = [PSCustomObject]@{ Errors = @('algo fallo') }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Errors no-vacio debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Errors vacio -> true' {
    $obj = [PSCustomObject]@{ Errors = @() }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Errors vacio debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Failed>0 -> false' {
    $obj = [PSCustomObject]@{ Failed = 3 }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Failed=3 debe dar false; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Failed=0 -> true' {
    $obj = [PSCustomObject]@{ Failed = 0 }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('Failed=0 debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded objeto plano no-null -> true' {
    $obj = [PSCustomObject]@{ SomeField = 'valor' }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $true) { throw ('objeto plano no-null debe dar true; got {0}' -f $r) }
}
Test-SmokeFunction 'JobManager' 'Test-StepSucceeded Error no vacio -> false' {
    $obj = [PSCustomObject]@{ Error = 'mensaje de error' }
    $r = Test-StepSucceeded -StepResult $obj
    if ($r -ne $false) { throw ('Error no-vacio debe dar false; got {0}' -f $r) }
}

# ─── ToolsSelector: listado/estado read-only (D-TS1) ─────────────────────────
# Verifica que Get-ToolStatus parsea manifest.json y devuelve bool por herramienta
# sin descargar nada (read-only).
Test-SmokeFunction 'ToolsSelector' 'Get-ToolStatus parsea manifest sin descargar' {
    [string] $rRoot  = Split-Path -Parent $PSScriptRoot
    [string] $mPath  = Join-Path $rRoot 'tools\manifest.json'
    [string] $binDir = Join-Path $rRoot 'tools\bin'
    if (-not (Test-Path $mPath)) { throw 'tools\manifest.json no encontrado' }
    $m = Get-Content $mPath -Raw | ConvertFrom-Json
    [object[]] $tl = @($m.tools)
    if ($tl.Count -eq 0) { throw 'Manifest sin herramientas' }
    foreach ($t in $tl) {
        $r = Get-ToolStatus -Tool $t -BinDir $binDir
        if ($r -isnot [bool]) { throw ('Get-ToolStatus devolvio no-bool para {0}' -f $t.name) }
    }
    $tl.Count
}

# ─── Stage 4.2-A: TimerResolution + ProcessPriority (read-only) ──────────────
Test-SmokeFunction 'TimerResolution' 'Get-TimerResolutionStatus no throw' { Get-TimerResolutionStatus }
Test-SmokeFunction 'TimerResolution' 'Get-TimerResolutionStatus shape' {
    $s = Get-TimerResolutionStatus
    foreach ($f in @('Enabled','RawValue','RegistryPath','WinBuild','GateWin11')) {
        if ($null -eq $s.PSObject.Properties[$f]) { throw "Campo $f ausente en Get-TimerResolutionStatus" }
    }
}
Test-SmokeFunction 'ProcessPriority' 'Get-ProcessPriorityIFEO no throw' { Get-ProcessPriorityIFEO }

Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta timer_resolution=on' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'timer_resolution' -NotePropertyValue 'on' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta process_priority valido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $pp = [PSCustomObject]@{}
    $pp | Add-Member -NotePropertyName 'game.exe' -NotePropertyValue 'High' -Force
    $p.gaming_tweaks | Add-Member -NotePropertyName 'process_priority' -NotePropertyValue $pp -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta sin timer_resolution ni process_priority' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza timer_resolution invalido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'timer_resolution' -NotePropertyValue 'maybe' -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar timer_resolution=maybe' }
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza process_priority clase invalida' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $pp = [PSCustomObject]@{}
    $pp | Add-Member -NotePropertyName 'game.exe' -NotePropertyValue 'Realtime' -Force
    $p.gaming_tweaks | Add-Member -NotePropertyName 'process_priority' -NotePropertyValue $pp -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar process_priority clase=Realtime' }
}

# ─── Stage 4.2-C: Steam-autodetect read-only ────────────────────────────────
Test-SmokeFunction 'NamedProfileEditor' 'Get-SteamLibraryPaths no-throw devuelve array' {
    [string[]] $r = @(Get-SteamLibraryPaths)
    if ($null -eq $r) { throw 'Get-SteamLibraryPaths retorno $null (esperado array, posiblemente vacio)' }
}

# ─── Progress UX: Wait-ToolkitJobs sin -ShowProgress (R3 opt-IN) ─────────────
# Verifica que Wait-ToolkitJobs SIN -ShowProgress sobre un job trivial devuelve
# array y no throw. No valida la UX visual (eso es Sandbox/Opus).
Test-SmokeFunction 'JobManager' 'Wait-ToolkitJobs no-ShowProgress devuelve array' {
    $j = Start-Job -ScriptBlock { 'ok' }
    $arr = Wait-ToolkitJobs -Jobs @($j) -TimeoutSeconds 10
    if ($null -eq $arr) { throw 'Wait-ToolkitJobs retorno $null (esperado array)' }
    if ($arr.Count -lt 1) { throw ('Array vacio; esperado Count>=1; Count={0}' -f $arr.Count) }
}

# ─── Progress UX extension: Invoke-JobWithProgress (wrapper acciones sueltas) ─
# Verifica que el wrapper devuelve array y no throw sobre un job trivial.
# No valida la UX visual (la barra se suprime en host no interactivo por
# $script:PctkProgressOk; eso es comportamiento correcto en rig).
Test-SmokeFunction 'JobManager' 'Invoke-JobWithProgress devuelve array sin throw' {
    $j = Start-Job -ScriptBlock { 'ok' }
    $arr = Invoke-JobWithProgress -Jobs @($j) -Activity 'Smoke test' -TimeoutSeconds 10
    if ($null -eq $arr) { throw 'Invoke-JobWithProgress retorno $null (esperado array)' }
    if ($arr.Count -lt 1) { throw ('Array vacio; esperado Count>=1; Count={0}' -f $arr.Count) }
}

# ─── Stage 4.2-B: NvidiaTweaks (read-only, no aplica nada) ──────────────────
Test-SmokeFunction 'NvidiaTweaks' 'Get-NvidiaSysmemStatus no throw' {
    Get-NvidiaSysmemStatus
}
Test-SmokeFunction 'NvidiaTweaks' 'Get-NvidiaSysmemStatus shape' {
    $s = Get-NvidiaSysmemStatus
    foreach ($f in @('IsNvidiaDedicated','Enabled','Reason')) {
        if ($null -eq $s.PSObject.Properties[$f]) {
            throw "Campo $f ausente en Get-NvidiaSysmemStatus"
        }
    }
}
Test-SmokeFunction 'NvidiaTweaks' 'Test-NvidiaInspectorAvailable no throw' {
    Test-NvidiaInspectorAvailable
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta nvidia_sysmem_fallback=prefer_no' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'nvidia_sysmem_fallback' -NotePropertyValue 'prefer_no' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema acepta sin nvidia_sysmem_fallback' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'NamedProfileEditor' 'Schema rechaza nvidia_sysmem_fallback invalido' {
    $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'nvidia_sysmem_fallback' -NotePropertyValue 'maybe' -Force
    $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw 'Test-NamedProfileSchema debio rechazar nvidia_sysmem_fallback=maybe' }
}

# ─── Uninstall: New-PctkUninstallScript (read-only, no ejecuta nada) ─────────
Test-SmokeFunction 'Uninstall' 'New-PctkUninstallScript genera contenido esperado' {
    [string] $fakeRoot = 'C:\FakePCTk'
    [int]    $fakePid  = 99999
    [string] $s = New-PctkUninstallScript -InstallRoot $fakeRoot -PctkPid $fakePid
    # 1. Contiene Remove-Item y el root pasado
    if ($s -notmatch 'Remove-Item') { throw 'Script no contiene Remove-Item' }
    if ($s -notmatch [regex]::Escape($fakeRoot)) { throw "Script no contiene el install root '$fakeRoot'" }
    # 2. Limpieza de artefactos temporales PCTk-*
    if ($s -notmatch 'PCTk-\*') { throw "Script no contiene glob PCTk-*" }
    # 3. Espera al PID
    if ($s -notmatch [string]$fakePid) { throw "Script no contiene el PID $fakePid" }
    # 4. Auto-borrado del propio script
    if ($s -notmatch 'PSCommandPath') { throw 'Script no contiene auto-borrado del propio script (PSCommandPath)' }
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
