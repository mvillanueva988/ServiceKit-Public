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

# ─── ProfileEngine v2.0: 3 recetas auto (read-only: path + import/validate) ──
# v2.0 consolido los 12 archivos (4 use-cases x 3 tiers) en 3 archivos
# (generic/work/multimedia), eliminando _tier del JSON. Office+study fusionados
# a 'work'. Multimedia_high (Full visuals = bug) fixeado a Balanced.
Test-SmokeFunction 'ProfileEngine' 'Get-AutoProfilePath'  { Get-AutoProfilePath -UseCase generic }
Test-SmokeFunction 'ProfileEngine' 'Import generic'       { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase generic) }
Test-SmokeFunction 'ProfileEngine' 'Import work'          { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase work) }
Test-SmokeFunction 'ProfileEngine' 'Import multimedia'    { Import-AutoProfile -Path (Get-AutoProfilePath -UseCase multimedia) }

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
Test-SmokeFunction 'ProcessPriority' 'clase Normal aceptada (Router [N] <-> modulo)' {
    # [15] ofrece [N]ormal en el menu; el modulo DEBE tener 'Normal' en el map o
    # la accion falla. Guarda contra el medio-cableado (Router si, modulo no).
    if (-not $script:PriorityClassMap.ContainsKey('Normal')) { throw "modulo: PriorityClassMap sin 'Normal'" }
    $rh = (Get-Command Invoke-ActionProcessPriority -CommandType Function).Definition
    if ($rh -notmatch "'N'\s*\{\s*'Normal'") { throw "Router [N] no mapea a 'Normal'" }
}

# ─── Stage 5: handlers menu [A] de modulos huerfanos (backlog #11) ────────────
# Cada handler es interactivo (Read-Host). Por handler:
#  (1) ROUTING: el dispatch rutea su numero [12]-[16] al handler correcto.
#  (2) ABORT-SEGURO: shadowea Read-Host con '' (aborta en el 1er prompt SIN
#      mutar) y corre el handler -> ejercita el display (Get-*Status) + cancela.
# Cada test fija $ErrorActionPreference='Stop' para ESPEJAR main.ps1 (el smoke
# global usa 'Continue'; ese mismatch dejo pasar el bug del gate #11: powercfg
# nativo bajo EAP=Stop tira NativeCommandError terminante). No-throw caza esa
# familia + crashes StrictMode en el path de lectura.
# La mutacion real (registry/powercfg) la valida el gate Sandbox, no el smoke.
Test-SmokeFunction 'Router' 'handler [12] CoreIsolation routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'12'\s*\{\s*Invoke-ActionCoreIsolation") { throw 'dispatch no rutea [12] -> Invoke-ActionCoreIsolation' }
    function Read-Host { '' }
    Invoke-ActionCoreIsolation -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [13] HAGS routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'13'\s*\{\s*Invoke-ActionHags") { throw 'dispatch no rutea [13] -> Invoke-ActionHags' }
    function Read-Host { '' }
    Invoke-ActionHags -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [14] TimerResolution routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'14'\s*\{\s*Invoke-ActionTimerResolution") { throw 'dispatch no rutea [14] -> Invoke-ActionTimerResolution' }
    function Read-Host { '' }
    Invoke-ActionTimerResolution -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [15] ProcessPriority routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'15'\s*\{\s*Invoke-ActionProcessPriority") { throw 'dispatch no rutea [15] -> Invoke-ActionProcessPriority' }
    function Read-Host { '' }
    Invoke-ActionProcessPriority -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'Router' 'handler [16] UsbPower routing + abort-seguro' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'16'\s*\{\s*Invoke-ActionUsbPower") { throw 'dispatch no rutea [16] -> Invoke-ActionUsbPower' }
    function Read-Host { '' }
    Invoke-ActionUsbPower -MachineProfile (Get-MachineProfile) | Out-Null
}
# Guard estructural del fix del gate #11: las 3 funciones de UsbPower que llaman
# powercfg (nativo) deben neutralizar EAP localmente, o crashean bajo main.ps1
# (EAP=Stop). El smoke no puede reproducir la mutacion sin mutar; este guard
# evita que el fix se borre en silencio.
Test-SmokeFunction 'UsbPower' 'powercfg EAP-guarded (regresion gate #11)' {
    foreach ($fn in @('Get-UsbSelectiveSuspendStatus','Disable-UsbSelectiveSuspend','Enable-UsbSelectiveSuspend')) {
        $def = (Get-Command $fn -CommandType Function).Definition
        if ($def -notmatch "ErrorActionPreference\s*=\s*'Continue'") {
            throw ("$fn no neutraliza EAP=Stop; powercfg crashearia bajo main.ps1 (ver gate #11)")
        }
    }
}

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
Test-SmokeFunction 'NvidiaTweaks' 'New-NvidiaSysmemNip formato real' {
    [string] $pn = New-NvidiaSysmemNip -State prefer_no
    [string] $df = New-NvidiaSysmemNip -State default
    foreach ($xml in @($pn, $df)) {
        if ($xml -notmatch '<ArrayOfProfile>')                                              { throw 'Falta <ArrayOfProfile>' }
        if ($xml -notmatch '<SettingID>283962569</SettingID>')                              { throw 'Falta SettingID 283962569' }
        if ($xml -notmatch '<SettingNameInfo>CUDA Sysmem Fallback Policy</SettingNameInfo>'){ throw 'Falta SettingNameInfo CUDA Sysmem Fallback Policy' }
        if ($xml -notmatch '<ValueType>Dword</ValueType>')                                  { throw 'Falta ValueType Dword' }
        if ($xml -match 'NvidiaInspectorProfile')                                           { throw 'Contiene schema incorrecto NvidiaInspectorProfile' }
        if ($xml -match '0x00A06871')                                                       { throw 'Contiene ID incorrecto 0x00A06871' }
    }
    if ($pn -notmatch '<SettingValue>1</SettingValue>') { throw 'prefer_no debe tener SettingValue=1' }
    if ($df -notmatch '<SettingValue>0</SettingValue>') { throw 'default debe tener SettingValue=0' }
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
    # 5. CWD neutral (no bloquear el dir a borrar)
    if ($s -notmatch 'Set-Location') { throw 'Script no contiene Set-Location (CWD neutral)' }
    # 6. Retry loop con verificacion (resuelve race cmd.exe)
    if ($s -notmatch '\$attempt') { throw 'Script no contiene retry loop ($attempt)' }
    if ($s -notmatch 'Start-Sleep -Milliseconds') { throw 'Script no contiene Start-Sleep -Milliseconds (retry delay)' }
    # 7. Log persistente
    if ($s -notmatch '\.log') { throw 'Script no contiene referencia al archivo .log' }
    if ($s -notmatch 'WriteAllLines|WriteLog') { throw 'Script no contiene escritura de log persistente' }
}

# ─── Handlers interactivos del Router: abort-seguro (gap que dejo pasar Bug2) ──
# Bugs 2/3 shippearon porque NINGUN test ejercitaba los handlers interactivos.
# Cada test shadowea Read-Host con un valor que ABORTA en el 1er prompt SIN
# mutar (tokens verificados contra el codigo: '' => break/return temprano).
# Solo handlers con abort-seguro PROBADO; ApplyAutoProfile/NamedProfileMenu se
# excluyen a proposito (flujos multi-prompt que llegan a aplicar -> peligroso
# en smoke que corre en la PC real). Asercion = no-throw (caza crash StrictMode
# en el path interactivo, la familia de Bug2).
Test-SmokeFunction 'RouterInteractive' 'Invoke-ActionStartup abort-seguro no crashea' {
    function Read-Host { '' }   # l.~1122: '' => break, sin Set-StartupEntry
    Invoke-ActionStartup -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'RouterInteractive' 'Invoke-ActionApps abort-seguro no crashea' {
    function Read-Host { '' }   # '' => return tras listar (jobs read-only), sin uninstall
    Invoke-ActionApps -MachineProfile (Get-MachineProfile) | Out-Null
}
Test-SmokeFunction 'RouterInteractive' 'Invoke-ResearchPrompt cancel no crashea' {
    function Read-Host { '' }   # l.324: '' => return ANTES de New-ResearchPrompt
    Invoke-ResearchPrompt -MachineProfile (Get-MachineProfile) | Out-Null
}

# ─── ResearchPrompt: snapshot sparse (regresion proactiva Bug3) ───────────────
# Con el bug original: StrictMode tira "property cannot be found" en el primer
# acceso crudo (ej. $Snapshot.RamSlots[0]). Con el fix: no lanza y Success=$true.
Test-SmokeFunction 'ResearchPrompt' 'New-ResearchPrompt sobrevive snapshot sparse' {
    $snap = [PSCustomObject]@{ CPU = [PSCustomObject]@{ Name = 'x' } }
    $mp   = [PSCustomObject]@{ }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r)    { throw 'New-ResearchPrompt retorno $null' }
    if (-not $r.Success) { throw ('Success=$false; esperado $true') }
}
# Regresion v2.0.2: colecciones de 1 elemento (1 modulo RAM = VM/Sandbox/laptop).
# El hardening v2.0.1 usaba `$x = if(c){@(...)}else{}` -> con 1 elem la
# expresion-if desenrolla el @() a escalar -> .Count PropertyNotFoundStrict.
# La fixture sparse de arriba NO tenia RamSlots, por eso no lo cazaba.
Test-SmokeFunction 'ResearchPrompt' 'New-ResearchPrompt colecciones de 1 elemento' {
    $snap = [PSCustomObject]@{
        CPU      = [PSCustomObject]@{ Name = 'x'; Cores = 4; Threads = 8 }
        RamSlots = @([PSCustomObject]@{ SpeedMhz = 3200 })
        GPU      = @([PSCustomObject]@{ Name = 'g'; Type = 'Dedicated'; DriverVersion = '1' })
        Disks    = @([PSCustomObject]@{ Name = 'd'; SizeGb = 500; MediaType = 'SSD'; HealthStatus = 'OK' })
    }
    $mp = [PSCustomObject]@{ }
    $r = New-ResearchPrompt -Template Optimization -Snapshot $snap -MachineProfile $mp
    if ($null -eq $r)    { throw 'New-ResearchPrompt retorno $null con colecciones de 1 elemento' }
    if (-not $r.Success) { throw 'Success=$false con colecciones de 1 elemento' }
}

# ─── ConsoleIcon: utils read-only (no llama Set-PctkConsoleIcon en smoke) ─────
Test-SmokeFunction 'ConsoleIcon' 'Set-PctkConsoleIcon presente + asset valido' {
    $cmd = Get-Command 'Set-PctkConsoleIcon' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw 'Set-PctkConsoleIcon no encontrado' }
    [string] $rRoot   = Split-Path -Parent $PSScriptRoot
    [string] $icoPath = Join-Path $rRoot 'assets\pctk.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) { throw "assets\pctk.ico no encontrado en $icoPath" }
    [byte[]] $b = [System.IO.File]::ReadAllBytes($icoPath)
    if ($b[0] -ne 0x00 -or $b[1] -ne 0x00 -or $b[2] -ne 0x01 -or $b[3] -ne 0x00) {
        throw ('Header ICO invalido: {0:X2} {1:X2} {2:X2} {3:X2}' -f $b[0],$b[1],$b[2],$b[3])
    }
}

# ─── ExportClientLogs (5 casos: empty, only-audit, both, tag-sanitize, collide) ─

Test-SmokeFunction 'ExportClientLogs' 'export-empty: output ausente -> Empty + sin zip' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $tmpDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'Empty') { throw ('Status esperado Empty; got {0}' -f $r.Status) }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw 'No debe haber zip cuando output\ esta ausente' }
    } finally {
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-only-audit: 1 subdir (PS5.1 array) -> zip con solo audit' {
    [string] $tmpOut      = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest     = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir    = Join-Path $tmpOut 'audit'
    [string] $auditFile   = Join-Path $auditDir '2026-05-20.jsonl'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $auditFile -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'Zip no fue creado' }
        if ((Get-Item -LiteralPath $r.ZipPath).Length -eq 0) { throw 'Zip tiene tamanio cero' }
        # Verificar que el zip contiene audit\ pero NO snapshots\
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [object[]] $entries = @()
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) }
        finally { $za.Dispose() }
        [bool] $hasAudit = $false
        [bool] $hasSnaps = $false
        foreach ($e in $entries) {
            if ($e -match '^audit')     { $hasAudit = $true }
            if ($e -match '^snapshots') { $hasSnaps = $true }
        }
        if (-not $hasAudit) { throw 'Zip no contiene audit\' }
        if ($hasSnaps)      { throw 'Zip contiene snapshots\ inesperado (trampa PS5.1 arrays)' }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-both: audit + snapshots -> zip con ambos' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    [string] $snapsDir  = Join-Path $tmpOut 'snapshots'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir 'pre.json')         -Value '{"Phase":"pre"}'  -Encoding UTF8
    try {
        function Read-Host { '' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        if (-not (Test-Path -LiteralPath $r.ZipPath)) { throw 'Zip no fue creado' }
        if ((Get-Item -LiteralPath $r.ZipPath).Length -eq 0) { throw 'Zip tiene tamanio cero' }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-tag-sanitize: chars invalidos -> solo validos en nombre' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { 'cliente/01 *<>' }
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch 'cliente01') { throw ('ZipName debe contener cliente01 (tag sanitizado); got {0}' -f $zipName) }
        if ($zipName -match '[/\\* <>]')    { throw ('ZipName contiene chars invalidos: {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-existing-collide: base.zip existe -> base_2.zip' {
    [string] $tmpOut    = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest   = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir  = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-20.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { '' }
        [string] $fixedTs  = '20260520-223015'
        [string] $baseZip  = Join-Path $tmpDest ('{0}_{1}.zip' -f $env:COMPUTERNAME, $fixedTs)
        New-Item -Path $baseZip -ItemType File -Force | Out-Null
        $r = Invoke-ExportClientLogs -OutputRootOverride $tmpOut -DestDirOverride $tmpDest -TimestampOverride $fixedTs
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $expected = Join-Path $tmpDest ('{0}_{1}_2.zip' -f $env:COMPUTERNAME, $fixedTs)
        if ($r.ZipPath -ne $expected) { throw ('ZipPath esperado {0}; got {1}' -f $expected, $r.ZipPath) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── ExportClientLogs: -TagOverride (2 casos) ────────────────────────────────

Test-SmokeFunction 'ExportClientLogs' 'export-tag-override-skip-prompt: con -TagOverride, NO llama Read-Host' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        # Si Read-Host se invoca, el test explota: eso es lo que queremos verificar.
        function Read-Host { throw 'Read-Host NO debe invocarse cuando se pasa -TagOverride' }
        $r = Invoke-ExportClientLogs -TagOverride 'preuninstall' -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch '-preuninstall_') { throw ('ZipName debe contener -preuninstall_; got {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'ExportClientLogs' 'export-tag-override-sanitized: -TagOverride sanitiza igual que Read-Host' {
    [string] $tmpOut  = Join-Path $env:TEMP ('pctk-smoke-out-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpDest = Join-Path $env:TEMP ('pctk-smoke-dest-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir = Join-Path $tmpOut 'audit'
    New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpDest  -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl') -Value '{"Action":"test"}' -Encoding UTF8
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse cuando se pasa -TagOverride' }
        $r = Invoke-ExportClientLogs -TagOverride 'cliente/01 *<>' -OutputRootOverride $tmpOut -DestDirOverride $tmpDest
        if ($r.Status -ne 'OK') { throw ('Status esperado OK; got {0}' -f $r.Status) }
        [string] $zipName = [System.IO.Path]::GetFileNameWithoutExtension($r.ZipPath)
        if ($zipName -notmatch 'cliente01') { throw ('ZipName debe contener cliente01 (tag sanitizado); got {0}' -f $zipName) }
        if ($zipName -match '[/\\* <>]')    { throw ('ZipName contiene chars invalidos: {0}' -f $zipName) }
    } finally {
        Remove-Item -LiteralPath $tmpOut  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─── OOSU rework: Invoke-ProfilePrivacyStep (6 casos) ───────────────────────
# Tests read-only: usan fixtures en memoria + shadowing de funciones.
# Ningun test ejecuta OOSU10.exe real ni muta el sistema.

Test-SmokeFunction 'OosuRework' 'oosu-rework-no-cfg: skip silencioso' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    $privacy = [PSCustomObject]@{}
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Path    -ne 'skipped') { throw ('Path esperado skipped; got {0}' -f $r.Path) }
    if ($r.Success -ne $true)     { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'Skipped') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply Skipped no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-cfg-missing: cfg no encontrado' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'nonexistent_smoke_test.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $false) { throw ('Success esperado $false; got {0}' -f $r.Success) }
    if ($r.Detail['Reason'] -ne 'cfg_not_found') {
        throw ('Reason esperado cfg_not_found; got {0}' -f $r.Detail['Reason'])
    }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'Failed') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply Failed no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-oosu-available: aplica cfg, audit OK' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $true }
    function Invoke-OOSU10Profile {
        param([string]$Path, [int]$TimeoutSeconds = 120)
        return [PSCustomObject]@{ Success = $true; Skipped = $false; Reason = '' }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Path    -ne 'oosu10') { throw ('Path esperado oosu10; got {0}' -f $r.Path) }
    if ($r.Success -ne $true)    { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Apply' -and $a.Status -eq 'OK') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Apply OK no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-download-needed: descarga OK, luego aplica' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $false }
    function Invoke-OOSUDownload {
        return [PSCustomObject]@{ Success = $true; Error = ''; ExePath = 'C:\fake\OOSU10.exe' }
    }
    function Invoke-OOSU10Profile {
        param([string]$Path, [int]$TimeoutSeconds = 120)
        return [PSCustomObject]@{ Success = $true; Skipped = $false; Reason = '' }
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $true) { throw ('Success esperado $true; got {0}' -f $r.Success) }
    [bool] $dlOk = $false; [bool] $applyOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Download' -and $a.Status -eq 'OK')    { $dlOk    = $true }
        if ($a.Action -eq 'Privacy.OOSU.Apply'    -and $a.Status -eq 'OK')    { $applyOk = $true }
    }
    if (-not $dlOk)    { throw 'Audit Privacy.OOSU.Download OK no registrado' }
    if (-not $applyOk) { throw 'Audit Privacy.OOSU.Apply OK no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-download-fails: falla de descarga, sin fallback nativo' {
    [object[]] $script:_oosuAudit = @()
    function Write-ActionAudit {
        param($Action, $Status = 'Started', $Summary = '', $Details = $null)
        $script:_oosuAudit += [PSCustomObject]@{ Action = $Action; Status = $Status }
    }
    function Test-ShutUp10Available { $false }
    function Invoke-OOSUDownload {
        return [PSCustomObject]@{ Success = $false; Error = 'no internet'; ExePath = '' }
    }
    [bool] $script:_nativeInvoked = $false
    function Start-PrivacyJob {
        param([string]$Profile)
        $script:_nativeInvoked = $true
        throw 'Start-PrivacyJob NO debe invocarse tras falla de descarga'
    }
    $privacy = [PSCustomObject]@{ oosu10_cfg = 'basic.cfg' }
    $prof    = [PSCustomObject]@{ privacy = $privacy }
    $r = Invoke-ProfilePrivacyStep -Profile $prof
    if ($r.Success -ne $false) { throw ('Success esperado $false; got {0}' -f $r.Success) }
    if ($r.Detail['Reason'] -ne 'download_failed') {
        throw ('Reason esperado download_failed; got {0}' -f $r.Detail['Reason'])
    }
    if ($script:_nativeInvoked) { throw 'Start-PrivacyJob fue invocado (fallback nativo NO debe ocurrir)' }
    [bool] $auditOk = $false
    foreach ($a in $script:_oosuAudit) {
        if ($a.Action -eq 'Privacy.OOSU.Download' -and $a.Status -eq 'Failed') { $auditOk = $true }
    }
    if (-not $auditOk) { throw 'Audit Privacy.OOSU.Download Failed no registrado' }
}

Test-SmokeFunction 'OosuRework' 'oosu-rework-no-native-fallback: grep estructural' {
    [string] $rRoot  = Split-Path -Parent $PSScriptRoot
    [string] $peFile = Join-Path $rRoot 'core\ProfileEngine.ps1'
    if (-not (Test-Path -LiteralPath $peFile)) { throw 'ProfileEngine.ps1 no encontrado' }
    [string] $content = [System.IO.File]::ReadAllText($peFile)
    $fnStart = $content.IndexOf('function Invoke-ProfilePrivacyStep')
    if ($fnStart -lt 0) { throw 'Invoke-ProfilePrivacyStep no encontrada en ProfileEngine.ps1' }
    # Buscar el cuerpo de la funcion: desde el { hasta el } de cierre al mismo nivel
    $braceOpen  = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -match 'Start-PrivacyJob') {
        throw 'Start-PrivacyJob encontrado en Invoke-ProfilePrivacyStep (regresion: fallback nativo presente)'
    }
}

# ─── UninstallPreserve: Save-PreUninstallArtifacts (6 casos) ─────────────────
# Testea la funcion extraida directamente, sin lanzar el deleter real.
# Shadowing: Read-Host (dest de clients), Write-ActionAudit (no-op en smoke).

Test-SmokeFunction 'UninstallPreserve' 'preserve-clients-and-snapshots: ambos presentes -> folder + zip' {
    [string] $tmpRoot     = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest  = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpCliDest  = Join-Path $env:TEMP ('pctk-smoke-cli-'  + [System.Guid]::NewGuid().ToString('N'))
    # Fixtures
    [string] $clientsDir  = Join-Path $tmpRoot 'output\clients\ClientA'
    [string] $auditDir    = Join-Path $tmpRoot 'output\audit'
    [string] $snapsDir    = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $clientsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $auditDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clientsDir 'run.log')           -Value 'log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl')    -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir  '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { $script:_rhCalled = $true; $tmpCliDest }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $script:_rhCalled = $false
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)                    { throw 'Save-PreUninstallArtifacts devolvio $null' }
        if (-not $script:_rhCalled)          { throw 'Read-Host no fue llamado (esperado para clients prompt)' }
        # clients copiados al dest que Read-Host retorno
        if (-not (Test-Path (Join-Path $tmpCliDest 'ClientA'))) {
            throw ('clients\ClientA no encontrado en {0}' -f $tmpCliDest)
        }
        # audit copiado dentro del folder
        if (-not (Test-Path (Join-Path $tmpCliDest 'audit'))) {
            throw ('audit\ no encontrado en {0}' -f $tmpCliDest)
        }
        # zip generado con audit + snapshots
        if ([string]::IsNullOrWhiteSpace($r.ZipPath) -or -not (Test-Path -LiteralPath $r.ZipPath)) {
            throw ('ZipPath esperado existente; got "{0}"' -f $r.ZipPath)
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [object[]] $entries = @()
        $za = [System.IO.Compression.ZipFile]::OpenRead($r.ZipPath)
        try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) }
        finally { $za.Dispose() }
        [bool] $hasAudit = $false; [bool] $hasSnaps = $false
        foreach ($e in $entries) {
            if ($e -match '^audit')     { $hasAudit = $true }
            if ($e -match '^snapshots') { $hasSnaps = $true }
        }
        if (-not $hasAudit) { throw 'Zip no contiene audit\' }
        if (-not $hasSnaps) { throw 'Zip no contiene snapshots\' }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpCliDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-snapshots-only: sin clients -> SOLO zip, sin folder' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $auditDir   = Join-Path $tmpRoot 'output\audit'
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $auditDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $auditDir '2026-05-23.jsonl')   -Value '{"Action":"test"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        # Read-Host NO debe invocarse (no hay clients\)
        function Read-Host { throw 'Read-Host NO debe invocarse sin clients\' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)          { throw 'Save-PreUninstallArtifacts devolvio $null' }
        # NO debe haber carpeta de historial en Desktop
        [string] $historial = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PCTk-historial-clientes'
        if (Test-Path $historial)  { throw 'PCTk-historial-clientes fue creado en Desktop inesperadamente' }
        # Zip SI debe existir
        if ([string]::IsNullOrWhiteSpace($r.ZipPath) -or -not (Test-Path -LiteralPath $r.ZipPath)) {
            throw ('ZipPath esperado existente; got "{0}"' -f $r.ZipPath)
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-empty-output: sin audit ni snapshots -> nada' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    # Dirs vacios (sin archivos adentro)
    New-Item -Path (Join-Path $tmpRoot 'output\audit')     -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tmpRoot 'output\snapshots') -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar)' }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('No debia crearse zip con output vacio; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-no-output: sin output\ -> nada' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    # NO crear nada en tmpRoot (ni siquiera output\)
    New-Item -Path $tmpRoot    -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar sin output\)' }
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('No debia crearse zip sin output\; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-zip-fails-doesnt-abort-uninstall' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json') -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { throw 'Read-Host NO debe invocarse' }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        function Compress-Archive { throw 'Error simulado de compresion' }
        # No debe lanzar al caller aunque Compress-Archive falle
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r)                      { throw 'Save-PreUninstallArtifacts devolvio $null (no debia abortar por zip fallido)' }
        if (-not [string]::IsNullOrWhiteSpace($r.ZipPath) -and (Test-Path -LiteralPath $r.ZipPath)) {
            throw 'No debia generarse zip cuando Compress-Archive falla'
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-SmokeFunction 'UninstallPreserve' 'preserve-clients-survives-zip-fail: si zip falla, folder igual queda' {
    [string] $tmpRoot    = Join-Path $env:TEMP ('pctk-smoke-root-' + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpZipDest = Join-Path $env:TEMP ('pctk-smoke-zip-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $tmpCliDest = Join-Path $env:TEMP ('pctk-smoke-cli-'  + [System.Guid]::NewGuid().ToString('N'))
    [string] $clientsDir = Join-Path $tmpRoot 'output\clients\ClientA'
    [string] $snapsDir   = Join-Path $tmpRoot 'output\snapshots'
    New-Item -Path $clientsDir -ItemType Directory -Force | Out-Null
    New-Item -Path $snapsDir   -ItemType Directory -Force | Out-Null
    New-Item -Path $tmpZipDest -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clientsDir 'run.log')          -Value 'log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $snapsDir '20260523-pre.json')  -Value '{"Phase":"pre"}' -Encoding UTF8
    try {
        function Read-Host { $tmpCliDest }
        function Write-ActionAudit { param($Action, $Status, $Summary, $Details) }
        function Compress-Archive { throw 'Error simulado de compresion' }
        $r = Save-PreUninstallArtifacts -InstallRoot $tmpRoot -ZipDestOverride $tmpZipDest
        if ($null -eq $r) { throw 'Save-PreUninstallArtifacts devolvio $null' }
        # clients debe haber quedado copiado (el copy ocurre ANTES del zip)
        if (-not (Test-Path (Join-Path $tmpCliDest 'ClientA'))) {
            throw ('clients\ClientA no encontrado en {0} (el copy de clients debe sobrevivir al zip fallido)' -f $tmpCliDest)
        }
        # zip NO debe existir
        [object[]] $zips = @(Get-ChildItem -LiteralPath $tmpZipDest -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -gt 0) { throw ('Zip no debia generarse cuando Compress-Archive falla; encontrados {0}' -f $zips.Count) }
    } finally {
        Remove-Item -LiteralPath $tmpRoot    -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpZipDest -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpCliDest -Recurse -Force -ErrorAction SilentlyContinue
    }
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
