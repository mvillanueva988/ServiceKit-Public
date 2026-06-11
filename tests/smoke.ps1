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
# Canary gate Sandbox: marca off-brand de 1 sola palabra (EXO, BANGHO, etc.).
# $value.Split(' ') | Where-Object {...} con 1 elemento se desenrolla a escalar
# y $parts.Count tiraba PropertyNotFoundStrict → crasheaba Get-MachineProfile en
# el arranque (main.ps1). El path default sólo se ejercita con marca NO conocida
# de 1 palabra — Get-MachineProfile sobre la PC de dev (marca multi-palabra) no
# lo toca. Test directo del helper con fixture de 1 palabra.
Test-SmokeFunction 'MachineProfile' 'Get-NormalizedManufacturer 1-word off-brand' {
    [string] $r = Get-NormalizedManufacturer -RawManufacturer 'EXO'
    if ($r -ne 'Exo') { throw ("EXO -> 'Exo' esperado; got '{0}'" -f $r) }
    # Sanity de marcas conocidas + vacío (no deben regresionar)
    if ((Get-NormalizedManufacturer -RawManufacturer 'ASUSTeK COMPUTER INC.') -ne 'Asus') { throw 'ASUSTeK -> Asus rompió' }
    if ((Get-NormalizedManufacturer -RawManufacturer '') -ne 'Unknown')                   { throw 'vacío -> Unknown rompió' }
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

Test-SmokeFunction 'StartupManager' 'Get-StartupDescription: conocido vs desconocido' {
    if ($null -eq (Get-Command 'Get-StartupDescription' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Get-StartupDescription no encontrado'
    }
    [string] $known = Get-StartupDescription -Name 'RtkAudUService'
    if ([string]::IsNullOrEmpty($known)) { throw 'RtkAudUService deberia tener descripcion' }
    # Regresion del falso positivo: 'Application Restart' NO debe matchear Brave por
    # el comando (ahora el match es solo por Name) -> debe ser "Restaurar...".
    [string] $appRestart = Get-StartupDescription -Name 'Application Restart #1'
    if ($appRestart -notmatch 'Restaurar') { throw ("Application Restart deberia ser Restaurar...; got '{0}'" -f $appRestart) }
    [string] $unknown = Get-StartupDescription -Name 'ZxQ_nada_123'
    if ($unknown -ne '') { throw ("desconocido deberia dar ''; got '{0}'" -f $unknown) }
}

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
Test-SmokeFunction 'Privacy' 'Get-DefenderScanSchedule (read-only)' { $null = Get-DefenderScanSchedule }
Test-SmokeFunction 'Privacy' 'Set-DefenderScanSchedule definida (no se ejecuta: muta Defender)' {
    if (-not (Get-Command Set-DefenderScanSchedule -ErrorAction SilentlyContinue)) { throw 'Set-DefenderScanSchedule no definida' }
}
Test-SmokeFunction 'Router' 'Invoke-ActionDefenderScan definida ([A][19])' {
    if (-not (Get-Command Invoke-ActionDefenderScan -ErrorAction SilentlyContinue)) { throw 'Invoke-ActionDefenderScan no definida' }
}

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

# ─── DiskHealth (backlog #17): recoleccion read-only + logica de umbral ───────
# Get-DiskHealth lee el sistema real (smoke-safe, timeouts). Get-DiskAlertLevel
# es funcion PURA → se testea la logica de alerta con fixtures, sin depender
# del HW. Incluye la TRAMPA del research (vacio != sano) y el BUG de enum
# cazado en HW (HealthStatus/MediaType vienen como numero, no label).
Test-SmokeFunction 'DiskHealth' 'Get-DiskHealth no throw + shape' {
    $d = Get-DiskHealth
    foreach ($f in @('IsVM','Disks','AlertCount','PredictFailAny','EnumTimedOut')) {
        if ($null -eq $d.PSObject.Properties[$f]) { throw "Campo $f ausente en Get-DiskHealth" }
    }
}
Test-SmokeFunction 'DiskHealth' 'umbral: disco sano -> OK' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 10 -TempC 35
    if ($r.Alert -ne 'OK') { throw "esperado OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'BUG enum: HealthStatus 0 (numero) -> OK no CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus '0' -WearPct 10
    if ($r.Alert -ne 'OK') { throw "enum 0 debe ser Healthy/OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'BUG enum: HealthStatus 2 (numero) -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus '2'
    if ($r.Alert -ne 'CRIT') { throw "enum 2 debe ser Unhealthy/CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'enum: HealthStatus 1 (Warning) -> WARN' {
    $r = Get-DiskAlertLevel -HealthStatus '1'
    if ($r.Alert -ne 'WARN') { throw "enum 1 debe ser Warning/WARN; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'MediaType enum: 4->SSD, 3->HDD, 0->Desconocido' {
    if ((ConvertTo-DiskMediaTypeLabel -Raw '4') -ne 'SSD') { throw '4 debe ser SSD' }
    if ((ConvertTo-DiskMediaTypeLabel -Raw '3') -ne 'HDD') { throw '3 debe ser HDD' }
    if ((ConvertTo-DiskMediaTypeLabel -Raw '0') -ne 'Desconocido') { throw '0 debe ser Desconocido' }
}
Test-SmokeFunction 'DiskHealth' 'umbral: wear critico -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 95
    if ($r.Alert -ne 'CRIT') { throw "esperado CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'umbral: wear warn -> WARN' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -WearPct 85
    if ($r.Alert -ne 'WARN') { throw "esperado WARN; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'Get-DiskWearLabel: HDD->N/A, SSD 0->sin dato real, SSD N->%' {
    if ((Get-DiskWearLabel -MediaType 'HDD' -WearPct 0)    -notmatch 'N/A')           { throw 'HDD wear deberia ser N/A' }
    if ((Get-DiskWearLabel -MediaType 'HDD' -WearPct 50)   -notmatch 'N/A')           { throw 'HDD 50 deberia ser N/A (mecanico)' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct $null) -ne 'no reportado')       { throw 'SSD null deberia ser no reportado' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct 0)    -notmatch 'sin dato real') { throw 'SSD 0 deberia marcarse sin dato real' }
    if ((Get-DiskWearLabel -MediaType 'SSD' -WearPct 42)   -ne '42%')                 { throw 'SSD 42 deberia ser 42%' }
}
Test-SmokeFunction 'DiskHealth' 'umbral: prediccion de falla -> CRIT' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -PredictFail $true
    if ($r.Alert -ne 'CRIT') { throw "esperado CRIT; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'TRAMPA: vacio + sin SMART -> UNKNOWN (no OK)' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true
    if ($r.Alert -ne 'UNKNOWN') { throw "campo vacio NO debe ser OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'Healthy + SMART faltante -> OK (Windows dice sano)' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -SmartMissing $true
    if ($r.Alert -ne 'OK') { throw "esperado OK; got $($r.Alert)" }
}
# Bug de campo (HDD lento): el timeout devolvia disco vacio sin distinguirse de
# "no hay disco". El flag TimedOut ahora se propaga; la razon UNKNOWN lo dice.
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: SmartTimedOut + sin base -> UNKNOWN con razon de timeout' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true -SmartTimedOut $true
    if ($r.Alert -ne 'UNKNOWN') { throw "timeout sin base debe ser UNKNOWN; got $($r.Alert)" }
    if (($r.Reasons -join ' ') -notmatch 'tiempo|timeout|lento') { throw "la razon debe indicar timeout; got: $($r.Reasons -join ' | ')" }
}
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: sin timeout, la razon UNKNOWN NO menciona timeout' {
    $r = Get-DiskAlertLevel -HealthStatus '' -SmartMissing $true
    if (($r.Reasons -join ' ') -match 'se agoto el tiempo') { throw "sin timeout no debe decir timeout; got: $($r.Reasons -join ' | ')" }
}
Test-SmokeFunction 'DiskHealth' 'TIMEOUT: Healthy + SmartTimedOut -> OK (timeout no degrada salud)' {
    $r = Get-DiskAlertLevel -HealthStatus 'Healthy' -SmartMissing $true -SmartTimedOut $true
    if ($r.Alert -ne 'OK') { throw "Healthy con SMART en timeout debe seguir OK; got $($r.Alert)" }
}
Test-SmokeFunction 'DiskHealth' 'shape disco: SmartTimedOut presente por disco' {
    $d = Get-DiskHealth
    foreach ($disk in @($d.Disks)) {
        if ($null -eq $disk.PSObject.Properties['SmartTimedOut']) { throw 'campo SmartTimedOut ausente en disco' }
    }
}
Test-SmokeFunction 'DiskHealth' 'cableado: menu principal [7] -> Invoke-DiagnosticDiskHealth' {
    if (-not (Get-Command Invoke-DiagnosticDiskHealth -CommandType Function -ErrorAction SilentlyContinue)) { throw 'handler Invoke-DiagnosticDiskHealth ausente' }
    $disp = (Get-Command Invoke-MainMenuDispatch -CommandType Function).Definition
    if ($disp -notmatch "'7'\s*\{\s*Invoke-DiagnosticDiskHealth") { throw 'dispatch principal no rutea [7]' }
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

# ConsoleSetup: QuickEdit off (utils read-only; NO muta la consola en smoke)
Test-SmokeFunction 'ConsoleSetup' 'Disable-PctkQuickEdit + Restore-PctkConsoleMode presentes' {
    foreach ($fn in @('Disable-PctkQuickEdit','Restore-PctkConsoleMode')) {
        if ($null -eq (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
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

# ─── #10 Gaming Profile: schema, preset, Get-InstalledGames, fold-#19 ────────

# C. gaming-template.json valida con Test-NamedProfileSchema + ConvertFrom-Json
Test-SmokeFunction 'GamingProfile' 'gaming-template.json parsea sin error' {
    [string] $tplPath = Join-Path (Get-NamedProfileDir) 'gaming-template.json'
    if (-not (Test-Path -LiteralPath $tplPath)) { throw "gaming-template.json no encontrado en $(Get-NamedProfileDir)" }
    [PSCustomObject] $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $tpl) { throw 'gaming-template.json parseo a null' }
}
Test-SmokeFunction 'GamingProfile' 'gaming-template.json valida contra Test-NamedProfileSchema' {
    [string] $tplPath = Join-Path (Get-NamedProfileDir) 'gaming-template.json'
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $null = Test-NamedProfileSchema -Profile $tpl
}

# B. oosu_profile='gaming' aceptado; 'xxx' rechazado
Test-SmokeFunction 'GamingProfile' "oosu_profile='gaming' aceptado por schema" {
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'oosu_profile' -NotePropertyValue 'gaming' -Force
    $null = Test-NamedProfileSchema -Profile $p
}
Test-SmokeFunction 'GamingProfile' "oosu_profile='xxx' rechazado por schema" {
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.gaming_tweaks | Add-Member -NotePropertyName 'oosu_profile' -NotePropertyValue 'xxx' -Force
    [bool] $threw = $false
    try { $null = Test-NamedProfileSchema -Profile $p } catch { $threw = $true }
    if (-not $threw) { throw "Test-NamedProfileSchema debio rechazar oosu_profile='xxx'" }
}

# A. New-GamingPreset: fixture 1 GPU con VRAM 8GB -> hags=off
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset fixture 1-GPU VRAM<8GB -> hags off' {
    # Fixture con 1 GPU, VRAM 6144 MB (< 8192); coleccion de 1 elemento (trampa StrictMode)
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 3060')   # RTX30: no RTX40+, VRAM=6144
    $mp = [PSCustomObject]@{
        DGpuVramMb = 6144
        GpuNames   = $gpuNames
        IsWin11    = $false
    }
    $gt = New-GamingPreset -MachineProfile $mp
    if ($null -eq $gt) { throw 'New-GamingPreset devolvio $null' }
    [object] $hagsP = $gt.PSObject.Properties['hags']
    if ($null -eq $hagsP -or [string]$hagsP.Value -ne 'off') {
        throw ("VRAM<8GB debe dar hags=off; got '{0}'" -f $(if ($hagsP) { $hagsP.Value } else { '(ausente)' }))
    }
    [object] $hvciP = $gt.PSObject.Properties['hvci']
    if ($null -eq $hvciP -or [string]$hvciP.Value -ne 'off') { throw "hvci debe ser off; got '$($hvciP.Value)'" }
    [object] $gmP = $gt.PSObject.Properties['game_mode']
    if ($null -eq $gmP -or [string]$gmP.Value -ne 'on') { throw "game_mode debe ser on" }
    # timer_resolution: Win10 (build=19041) -> NO debe incluirse
    [object] $trP = $gt.PSObject.Properties['timer_resolution']
    if ($null -ne $trP) { throw 'Win10 (build<22000): timer_resolution NO debe incluirse en el preset' }
    # oosu_profile = gaming
    [object] $ooP = $gt.PSObject.Properties['oosu_profile']
    if ($null -eq $ooP -or [string]$ooP.Value -ne 'gaming') { throw "oosu_profile debe ser 'gaming'" }
}
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset fixture RTX40 -> hags on' {
    # Fixture con 1 GPU RTX40+ (RTX 4070); coleccion de 1 elemento
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 4070')
    $mp = [PSCustomObject]@{
        DGpuVramMb = 12288
        GpuNames   = $gpuNames
        IsWin11    = $true
    }
    $gt = New-GamingPreset -MachineProfile $mp
    if ($null -eq $gt) { throw 'New-GamingPreset devolvio $null con RTX40' }
    [object] $hagsP = $gt.PSObject.Properties['hags']
    if ($null -eq $hagsP -or [string]$hagsP.Value -ne 'on') {
        throw ("RTX40+ debe dar hags=on; got '{0}'" -f $(if ($hagsP) { $hagsP.Value } else { '(ausente)' }))
    }
    # timer_resolution: Win11 (build=22621) -> debe estar
    [object] $trP = $gt.PSObject.Properties['timer_resolution']
    if ($null -eq $trP -or [string]$trP.Value -ne 'on') {
        throw ("Win11 build>=22000: timer_resolution debe ser on; got '{0}'" -f $(if ($trP) { $trP.Value } else { '(ausente)' }))
    }
}
# El resultado del preset debe validar con Test-NamedProfileSchema (en una receta named completa)
Test-SmokeFunction 'GamingProfile' 'New-GamingPreset produce gaming_tweaks que pasa schema' {
    [object[]] $gpuNames = @('NVIDIA GeForce RTX 3070')
    $mp = [PSCustomObject]@{ DGpuVramMb = 8192; GpuNames = $gpuNames; IsWin11 = $true }
    $gt = New-GamingPreset -MachineProfile $mp
    # Construir receta named minima con el gaming_tweaks del preset
    [string] $sP = Join-Path (Get-NamedProfileDir) '_sample.json'
    $p = Get-Content $sP -Raw -Encoding UTF8 | ConvertFrom-Json
    # Reemplazar gaming_tweaks con el preset (campo a campo)
    foreach ($prop in @($gt.PSObject.Properties)) {
        $p.gaming_tweaks | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
    $null = Test-NamedProfileSchema -Profile $p
}

# D. Get-InstalledGames: no-throw con/sin tiendas
Test-SmokeFunction 'GamingProfile' 'Get-InstalledGames no-throw devuelve array' {
    # Read-only: no valida deteccion real (eso es HW). Solo verifica que no lanza
    # y retorna un array (posiblemente vacio).
    [PSCustomObject[]] $games = @(Get-InstalledGames)
    if ($null -eq $games) { throw 'Get-InstalledGames retorno $null (esperado array, posiblemente vacio)' }
    # Shape: cada elemento debe tener Name, Path, Source
    foreach ($g in $games) {
        if ($null -eq $g.PSObject.Properties['Name'])   { throw 'campo Name ausente en juego' }
        if ($null -eq $g.PSObject.Properties['Path'])   { throw 'campo Path ausente en juego' }
        if ($null -eq $g.PSObject.Properties['Source']) { throw 'campo Source ausente en juego' }
    }
}

# E. Fold #19: Disable-Hvci / Enable-Hvci: check estructural (GPO check presente en codigo)
# El test de mutacion real (GPO impuesto) requiere HW con GPO; el smoke solo verifica
# que el codigo de la guardia esta presente (evita que el fix se borre en silencio).
Test-SmokeFunction 'GamingProfile' 'fold-19: Disable-Hvci tiene check GPO antes de Set-ItemProperty' {
    [string] $rRoot    = Split-Path -Parent $PSScriptRoot
    [string] $ciFile   = Join-Path $rRoot 'modules\CoreIsolation.ps1'
    if (-not (Test-Path -LiteralPath $ciFile)) { throw 'CoreIsolation.ps1 no encontrado' }
    [string] $content  = [System.IO.File]::ReadAllText($ciFile)
    # El bloque de Disable-Hvci debe contener la clave de la guardia
    [int] $fnStart = $content.IndexOf('function Disable-Hvci')
    if ($fnStart -lt 0) { throw 'Disable-Hvci no encontrada en CoreIsolation.ps1' }
    # Buscar el cuerpo de la funcion
    [int] $braceOpen = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -notmatch 'Policies.*DeviceGuard') {
        throw 'Disable-Hvci no contiene check GPO (Policies\Microsoft\Windows\DeviceGuard) -- fold-19 rota'
    }
    if ($fnBody -notmatch 'Blocked') {
        throw 'Disable-Hvci no retorna campo Blocked -- fold-19 rota'
    }
}
Test-SmokeFunction 'GamingProfile' 'fold-19: Enable-Hvci tiene check GPO antes de Set-ItemProperty' {
    [string] $rRoot    = Split-Path -Parent $PSScriptRoot
    [string] $ciFile   = Join-Path $rRoot 'modules\CoreIsolation.ps1'
    [string] $content  = [System.IO.File]::ReadAllText($ciFile)
    [int] $fnStart = $content.IndexOf('function Enable-Hvci')
    if ($fnStart -lt 0) { throw 'Enable-Hvci no encontrada en CoreIsolation.ps1' }
    [int] $braceOpen = $content.IndexOf('{', $fnStart)
    [int] $depth = 0; [int] $fnEnd = $braceOpen
    for ([int] $i = $braceOpen; $i -lt $content.Length; $i++) {
        if ($content[$i] -eq '{') { $depth++ }
        elseif ($content[$i] -eq '}') { $depth--; if ($depth -eq 0) { $fnEnd = $i; break } }
    }
    [string] $fnBody = $content.Substring($fnStart, $fnEnd - $fnStart + 1)
    if ($fnBody -notmatch 'Policies.*DeviceGuard') {
        throw 'Enable-Hvci no contiene check GPO (Policies\Microsoft\Windows\DeviceGuard) -- fold-19 rota'
    }
    if ($fnBody -notmatch 'Blocked') {
        throw 'Enable-Hvci no retorna campo Blocked -- fold-19 rota'
    }
}

# ─── ConsoleMenu: Read-PctkMenuChoice + Get-MainMenuRows (estructural) ───────
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMenuChoice presente' {
    if ($null -eq (Get-Command 'Read-PctkMenuChoice' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Read-PctkMenuChoice no encontrado'
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-MainMenuRows: 13 items en orden + 4 headers' {
    [object[]] $rows  = Get-MainMenuRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    [string[]] $expectedKeys = @('1','2','3','4','5','6','7','R','A','T','L','X','U')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 4) {
        throw ('Se esperaban 4 headers; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMenuChoice fallback no bloquea (input redirigido)' {
    [object[]] $rows = Get-MainMenuRows
    [scriptblock] $rh = { }
    function Read-Host { '1' }
    [string] $result = Read-PctkMenuChoice -Rows $rows -RenderHeader $rh -ForceFallbackForTest
    if ($result -ne '1') {
        throw ("fallback retorno '$result'; esperado '1'")
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-IndividualActionRows: 20 items en orden + 5 headers' {
    [object[]] $rows  = Get-IndividualActionRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    [string[]] $expectedKeys = @('1','2','3','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19','B')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 5) {
        throw ('Se esperaban 5 headers; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Get-NamedProfileRows: 4 items en orden + 1 header' {
    [object[]] $rows  = Get-NamedProfileRows
    [object[]] $items = @($rows | Where-Object { $_.Kind -eq 'Item' })
    [string[]] $expectedKeys = @('1','2','3','B')
    if ($items.Count -ne $expectedKeys.Count) {
        throw ('Se esperaban {0} items; encontrados {1}' -f $expectedKeys.Count, $items.Count)
    }
    for ([int] $i = 0; $i -lt $expectedKeys.Count; $i++) {
        if ([string]$items[$i].Key -ne $expectedKeys[$i]) {
            throw ('Item[{0}]: key esperada {1}; got {2}' -f $i, $expectedKeys[$i], [string]$items[$i].Key)
        }
    }
    [object[]] $headers = @($rows | Where-Object { $_.Kind -eq 'Header' })
    if ($headers.Count -ne 1) {
        throw ('Se esperaba 1 header; encontrados {0}' -f $headers.Count)
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Read-PctkMultiChoice + Test-PctkInteractiveConsole presentes' {
    foreach ($fn in @('Read-PctkMultiChoice', 'Test-PctkInteractiveConsole')) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
    }
}
Test-SmokeFunction 'ConsoleMenu' 'Test-PctkInteractiveConsole: bool + false bajo input redirigido (smoke)' {
    $r = Test-PctkInteractiveConsole
    if ($r -isnot [bool]) { throw 'no devolvio bool' }
    if ($r -ne $false) { throw "esperado false bajo input redirigido; got $r" }
}
Test-SmokeFunction 'ConsoleMenu' 'Invoke-ToolsMenuInteractive presente (handler [T])' {
    if ($null -eq (Get-Command 'Invoke-ToolsMenuInteractive' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Invoke-ToolsMenuInteractive no encontrado'
    }
}

# ─── Router: renderHeader robusto ante '& main.ps1' (regresion) ──────────────
# Canary del bug del gate 2026-06-07: el renderHeader que dibuja el banner NO debe
# usar .GetNewClosure(). Ese closure queda atado a un modulo dinamico que solo ve
# funciones GLOBALES; con '& main.ps1' (vs powershell -File) main.ps1 corre en un
# script-scope hijo y el closure no resuelve Show-MachineBanner -> CommandNotFound.
# El smoke NO lo reproduce funcionalmente (corre todo en un scope via -File), por eso
# el guard es estructural. Fix = scriptblock plano + $script:var (lookup dinamico).
Test-SmokeFunction 'Router' 'renderHeader sin GetNewClosure (sobrevive a "& main.ps1")' {
    [string] $routerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core\Router.ps1'
    [string[]] $hits = @(Get-Content -LiteralPath $routerPath | Where-Object { $_ -match '\.GetNewClosure\(' })
    if ($hits.Count -gt 0) {
        throw ('Router.ps1 usa .GetNewClosure() ({0}): rompe el render con "& main.ps1" (el closure no ve Show-MachineBanner). Usar scriptblock plano + $script:var.' -f $hits.Count)
    }
}

# ─── ConsoleTheme: VT + capa de helpers de output (estructural) ──────────────
# En smoke el output esta redirigido -> Enable-PctkVT da false y todo cae al
# render 16-color/texto. Estos tests verifican el contrato del FALLBACK: presencia,
# no-throw, devuelve bool, y que los Get-* NO emiten ANSI crudo con VT off.
Test-SmokeFunction 'ConsoleTheme' 'Enable-PctkVT presente + devuelve bool + no-throw' {
    if ($null -eq (Get-Command 'Enable-PctkVT' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Enable-PctkVT no encontrado'
    }
    $r = Enable-PctkVT
    if ($r -isnot [bool]) { throw ('Enable-PctkVT no devolvio bool; got {0}' -f $r.GetType().Name) }
    $t = Test-PctkVT
    if ($t -isnot [bool]) { throw 'Test-PctkVT no devolvio bool' }
}
Test-SmokeFunction 'ConsoleTheme' 'helpers de tema presentes' {
    [string[]] $fns = @(
        'Write-PctkLine','Write-PctkOk','Write-PctkWarn','Write-PctkErr','Write-PctkHint',
        'Write-PctkWork','Write-PctkSection','Write-PctkValue','Write-PctkActionTitle',
        'Get-PctkBadge','Write-PctkDivider','ConvertTo-PctkAnsiFg','Get-PctkKindSpec',
        'Write-PctkMachineBanner','Get-PctkGrad'
    )
    foreach ($fn in $fns) {
        if ($null -eq (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "$fn no encontrado" }
    }
}
Test-SmokeFunction 'ConsoleTheme' 'helpers de output no-throw con VT off' {
    # Sub-scriptblock con *>$null: no ensuciamos el reporte; un throw igual propaga.
    & {
        Write-PctkLine -Text 'x' -Kind 'ok'
        Write-PctkOk 'x'; Write-PctkWarn 'x'; Write-PctkErr 'x'; Write-PctkHint 'x'
        Write-PctkWork 'x'; Write-PctkSection 'x'; Write-PctkValue 'x'; Write-PctkValue ''
        Write-PctkActionTitle 'TITULO DE PRUEBA'
        Write-PctkDivider 20
    } *> $null
}
Test-SmokeFunction 'ConsoleTheme' 'Get-* no emiten ANSI crudo con VT off' {
    [char] $esc = [char]27
    [string] $b = Get-PctkBadge 'OK' 'ok'
    if ($b.IndexOf($esc) -ge 0) { throw 'Get-PctkBadge emitio ESC con VT off' }
    if ($b -ne '[OK]')          { throw ("Get-PctkBadge VT off esperado '[OK]'; got '{0}'" -f $b) }
    [string] $g = Get-PctkGrad 'abc' 255 170 40 95 108 124
    if ($g.IndexOf($esc) -ge 0) { throw 'Get-PctkGrad emitio ESC con VT off' }
    if ($g -ne 'abc')           { throw ("Get-PctkGrad VT off esperado 'abc'; got '{0}'" -f $g) }
    [string] $f = ConvertTo-PctkAnsiFg 'Green'
    if ($f -ne '')              { throw ("ConvertTo-PctkAnsiFg VT off esperado ''; got '{0}'" -f $f) }
}
Test-SmokeFunction 'ConsoleTheme' 'Get-PctkKindSpec: shape + 16-color por kind' {
    $s = Get-PctkKindSpec 'ok'
    foreach ($k in @('R','G','B','C16')) {
        if (-not $s.ContainsKey($k)) { throw "Get-PctkKindSpec sin clave $k" }
    }
    if ($s.C16 -ne 'Green') { throw ("kind 'ok' C16 esperado Green; got {0}" -f $s.C16) }
    if ((Get-PctkKindSpec 'err').C16  -ne 'Red')      { throw "kind 'err' C16 != Red" }
    if ((Get-PctkKindSpec 'hint').C16 -ne 'DarkGray') { throw "kind 'hint' C16 != DarkGray" }
    if ((Get-PctkKindSpec 'zzz').C16  -ne 'Gray')     { throw "kind desconocido C16 != Gray (default value)" }
}

# ─── DiskMaintenance: Resolve-VolumeMaintenanceOp (funcion pura) ─────────────
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: SSD->ReTrim' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'SSD'
    if ($r.Op -ne 'ReTrim') { throw "SSD: Op esperado ReTrim; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'SSD: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: HDD->Defrag' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'HDD'
    if ($r.Op -ne 'Defrag') { throw "HDD: Op esperado Defrag; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'HDD: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: SCM->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'SCM'
    if ($r.Op -ne 'Skip') { throw "SCM: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'SCM: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: Desconocido->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'Desconocido'
    if ($r.Op -ne 'Skip') { throw "Desconocido: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Desconocido: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: vacio->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel ''
    if ($r.Op -ne 'Skip') { throw "Vacio: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Vacio: Reason vacia' }
}
Test-SmokeFunction 'DiskMaintenance' 'Resolve-VolumeMaintenanceOp: valor arbitrario->Skip' {
    $ErrorActionPreference = 'Stop'
    $r = Resolve-VolumeMaintenanceOp -MediaTypeLabel 'cualquiercosa'
    if ($r.Op -ne 'Skip') { throw "Arbitrario: Op esperado Skip; got $($r.Op)" }
    if ([string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Arbitrario: Reason vacia' }
}

# ─── DiskMaintenance: Get-VolumeMaintenancePlan (read-only, live) ─────────────
# Canario de trampa StrictMode: la dev-PC tipica tiene 1-2 volumenes. Con
# @(...) forzamos array para el caso de exactamente 1 elemento.
Test-SmokeFunction 'DiskMaintenance' 'Get-VolumeMaintenancePlan: no lanza + shape correcto' {
    $ErrorActionPreference = 'Stop'
    # Forzar @(...) para proteger contra trampa StrictMode de 1 elemento
    [object[]] $plan = @(Get-VolumeMaintenancePlan)
    # En Sandbox/VM puede ser vacio (todo Skip antes del filtro, o sin volumenes fijos)
    foreach ($item in $plan) {
        [string[]] $requiredProps = @('DriveLetter','Label','SizeGb','MediaType','Op','Reason')
        foreach ($p in $requiredProps) {
            if ($null -eq $item.PSObject.Properties[$p]) {
                throw ("Volumen sin propiedad '$p'")
            }
        }
        [string] $op = [string]$item.Op
        if ($op -ne 'ReTrim' -and $op -ne 'Defrag' -and $op -ne 'Skip') {
            throw ("Op inesperada: '$op'")
        }
    }
}

# ─── DiskMaintenance: Get-WindowsDefragTaskStatus (read-only) ─────────────────
Test-SmokeFunction 'DiskMaintenance' 'Get-WindowsDefragTaskStatus: no lanza + shape o null' {
    $ErrorActionPreference = 'Stop'
    $r = Get-WindowsDefragTaskStatus
    if ($null -ne $r) {
        if ($null -eq $r.PSObject.Properties['Exists'])      { throw 'Get-WindowsDefragTaskStatus: falta propiedad Exists' }
        if ($null -eq $r.PSObject.Properties['State'])       { throw 'Get-WindowsDefragTaskStatus: falta propiedad State' }
        if ($null -eq $r.PSObject.Properties['LastRunTime']) { throw 'Get-WindowsDefragTaskStatus: falta propiedad LastRunTime' }
    }
}

# ─── DiskMaintenance: canario estructural dispatch ────────────────────────────
Test-SmokeFunction 'DiskMaintenance' 'handler [17] DiskMaintenance: dispatch rutea correctamente' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'17'\s*\{\s*Invoke-ActionDiskMaintenance") {
        throw 'dispatch no rutea [17] -> Invoke-ActionDiskMaintenance'
    }
}

# ─── DiskMaintenance: canario de NO-mutacion del smoke ───────────────────────
# El smoke NUNCA debe llamar Invoke-VolumeMaintenance ni Start-DiskMaintenanceProcess
# (solo las funciones read-only y la pura). Buscamos lineas con llamadas directas:
# la funcion aparece al inicio de la expresion (precedida por espacio o comienzo
# de linea) sin estar dentro de un -match/-notmatch (que solo la referencia como string).
Test-SmokeFunction 'DiskMaintenance' 'smoke no llama funciones mutantes de DiskMaintenance' {
    $ErrorActionPreference = 'Stop'
    [string] $smokePath = $PSCommandPath
    [string[]] $smokeLines = @(Get-Content -LiteralPath $smokePath -Encoding UTF8)
    foreach ($mutantFn in @('Invoke-VolumeMaintenance', 'Start-DiskMaintenanceProcess')) {
        # Buscar lineas donde la funcion aparece como llamada real (no como literal de string en -match/-notmatch)
        [object[]] $callLines = @($smokeLines | Where-Object {
            $_ -match "\b$([regex]::Escape($mutantFn))\b" -and
            $_.TrimStart() -notmatch '^#' -and
            $_ -notmatch '-match\s' -and
            $_ -notmatch '-notmatch\s' -and
            $_ -notmatch "'\s*$([regex]::Escape($mutantFn))" -and
            $_ -notmatch "@'\s*$([regex]::Escape($mutantFn))"
        })
        if ($callLines.Count -gt 0) {
            throw "smoke.ps1 llama a $mutantFn (funcion mutante): $($callLines[0].Trim())"
        }
    }
}

# ─── ToolsManifest: antimalware ───────────────────────────────────────────────
Test-SmokeFunction 'ToolsManifest' 'manifest: kvrt + adwcleaner con categoria antimalware' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($toolName in @('kvrt', 'adwcleaner')) {
        $tool = $m.tools | Where-Object { $_.name -eq $toolName } | Select-Object -First 1
        if ($null -eq $tool)                                          { throw "Tool '$toolName' no encontrada en manifest" }
        if ([string]$tool.category -ne 'antimalware')                 { throw "Tool '$toolName': category esperado 'antimalware'; got '$($tool.category)'" }
        if ([string]::IsNullOrWhiteSpace([string]$tool.url))          { throw "Tool '$toolName': url vacia" }
        if ([string]$tool.updatePolicy -ne 'latest')                  { throw "Tool '$toolName': updatePolicy esperado 'latest'; got '$($tool.updatePolicy)'" }
        if (-not ($tool.PSObject.Properties['approxSizeMB']) -or [int]$tool.approxSizeMB -le 0) { throw "Tool '$toolName': approxSizeMB debe ser > 0" }
    }
}
Test-SmokeFunction 'ToolsManifest' 'manifest: categoria antimalware existe' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $m.categories.PSObject.Properties['antimalware']) {
        throw "categoria 'antimalware' no encontrada en manifest.categories"
    }
}

# ─── ToolsManifest: #23d medicion fps + ddu ───────────────────────────────────
Test-SmokeFunction 'ToolsManifest' 'manifest: presentmon (diagnostico + url release x64)' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tool = $m.tools | Where-Object { $_.name -eq 'presentmon' } | Select-Object -First 1
    if ($null -eq $tool)                                    { throw "Tool 'presentmon' no encontrada en manifest" }
    if ([string]$tool.category -ne 'diagnostico')           { throw "presentmon: category esperado 'diagnostico'; got '$($tool.category)'" }
    if ([string]::IsNullOrWhiteSpace([string]$tool.url))    { throw 'presentmon: url vacia' }
    if ([string]$tool.url -notmatch 'PresentMon.*x64\.exe') { throw "presentmon: url no apunta al exe x64: $($tool.url)" }
}
Test-SmokeFunction 'ToolsManifest' 'manifest: ddu ya presente (drivers) - no re-agregar' {
    $ErrorActionPreference = 'Stop'
    [string] $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\manifest.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tool = $m.tools | Where-Object { $_.name -eq 'ddu' } | Select-Object -First 1
    if ($null -eq $tool)                      { throw "Tool 'ddu' no encontrada en manifest" }
    if ([string]$tool.category -ne 'drivers') { throw "ddu: category esperado 'drivers'; got '$($tool.category)'" }
}

# ─── Encryption: label maps (funciones puras) ─────────────────────────────────
Test-SmokeFunction 'Encryption' 'ConvertTo-Enc*Label: enums conocidos y default' {
    $ErrorActionPreference = 'Stop'
    if ((ConvertTo-EncConversionLabel -Status 1)  -ne 'FullyEncrypted') { throw 'conv 1 != FullyEncrypted' }
    if ((ConvertTo-EncConversionLabel -Status 0)  -ne 'FullyDecrypted') { throw 'conv 0 != FullyDecrypted' }
    if ((ConvertTo-EncConversionLabel -Status 99) -ne 'Unknown')        { throw 'conv 99 != Unknown' }
    if ((ConvertTo-EncMethodLabel     -Method 4)  -ne 'AES256')         { throw 'method 4 != AES256' }
    if ((ConvertTo-EncMethodLabel     -Method 7)  -ne 'XTS_AES256')     { throw 'method 7 != XTS_AES256' }
    if ((ConvertTo-EncMethodLabel     -Method 99) -ne 'Unknown')        { throw 'method 99 != Unknown' }
}

# ─── Encryption: detector read-only ───────────────────────────────────────────
# Degrada limpio en VM/Sandbox/sin-permisos: Encryptable=$false, sin throw.
Test-SmokeFunction 'Encryption' 'Get-DiskEncryptionStatus: no lanza + shape completo' {
    $ErrorActionPreference = 'Stop'
    $st = Get-DiskEncryptionStatus
    if ($null -eq $st) { throw 'Get-DiskEncryptionStatus devolvio $null' }
    foreach ($p in @('DriveLetter','Encryptable','ProtectionOn','ConversionStatus',
                     'ConversionLabel','EncryptionPct','EncryptionMethod','IsEncrypted',
                     'HasRecoveryProtector','Error')) {
        if ($null -eq $st.PSObject.Properties[$p]) { throw ("falta propiedad {0}" -f $p) }
    }
}

# Read-only y SENSIBLE: devuelve [object[]] (vacio en dev sin cifrar/sin permisos).
Test-SmokeFunction 'Encryption' 'Get-BitLockerRecoveryKey: no lanza + devuelve array' {
    $ErrorActionPreference = 'Stop'
    [object[]] $keys = @(Get-BitLockerRecoveryKey)
    if ($keys -isnot [object[]]) { throw 'no devolvio [object[]]' }
}

# ─── Encryption: Save con coleccion de EXACTAMENTE 1 (canario StrictMode) ──────
Test-SmokeFunction 'Encryption' 'Save-BitLockerRecoveryKey: 1 protector + vacio->""' {
    $ErrorActionPreference = 'Stop'
    if ((Save-BitLockerRecoveryKey -Keys @()) -ne '') { throw 'coleccion vacia debe dar ""' }
    [object[]] $one = @([PSCustomObject]@{
        KeyProtectorId   = '{12345678-AAAA-BBBB-CCCC-DDDDDDDDDDDD}'
        KeyId8           = '12345678'
        RecoveryPassword = '111111-222222-333333-444444-555555-666666-777777-888888'
    })
    [string] $tmp = Join-Path $env:TEMP ('pctk-enc-smoke-' + [System.IO.Path]::GetRandomFileName())
    try {
        [string] $path = Save-BitLockerRecoveryKey -Keys $one -OutputRootOverride $tmp -TimestampOverride '20260101-000000'
        if ([string]::IsNullOrEmpty($path)) { throw 'no devolvio path' }
        if (-not (Test-Path -LiteralPath $path)) { throw 'archivo no creado' }
        [string] $body = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($body -notmatch '12345678')            { throw 'no contiene Key ID' }
        if ($body -notmatch '111111-222222')       { throw 'no contiene la clave' }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ─── Encryption: canario estructural dispatch ─────────────────────────────────
Test-SmokeFunction 'Encryption' 'handler [18] Encryption: dispatch rutea correctamente' {
    $ErrorActionPreference = 'Stop'
    $disp = (Get-Command Invoke-IndividualActionDispatch -CommandType Function).Definition
    if ($disp -notmatch "'18'\s*\{\s*Invoke-ActionEncryption") {
        throw 'dispatch no rutea [18] -> Invoke-ActionEncryption'
    }
}

# ─── Encryption: canario de NO-mutacion del smoke ─────────────────────────────
# El smoke NUNCA debe llamar Start-BitLockerDecrypt (descifra el disco real).
Test-SmokeFunction 'Encryption' 'smoke no llama funciones mutantes de Encryption' {
    $ErrorActionPreference = 'Stop'
    [string] $smokePath = $PSCommandPath
    [string[]] $smokeLines = @(Get-Content -LiteralPath $smokePath -Encoding UTF8)
    foreach ($mutantFn in @('Start-BitLockerDecrypt')) {
        [object[]] $callLines = @($smokeLines | Where-Object {
            $_ -match "\b$([regex]::Escape($mutantFn))\b" -and
            $_.TrimStart() -notmatch '^#' -and
            $_ -notmatch '-match\s' -and
            $_ -notmatch '-notmatch\s' -and
            $_ -notmatch "'\s*$([regex]::Escape($mutantFn))" -and
            $_ -notmatch "@'\s*$([regex]::Escape($mutantFn))"
        })
        if ($callLines.Count -gt 0) {
            throw "smoke.ps1 llama a $mutantFn (funcion mutante): $($callLines[0].Trim())"
        }
    }
}

# ─── #23a: Test-IsX3dDualCcdCpu (funcion pura) ────────────────────────────────
Test-SmokeFunction 'PowerPlan' 'Test-IsX3dDualCcdCpu: dual-CCD true / single-CCD false' {
    $ErrorActionPreference = 'Stop'
    if (-not (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 9 7950X3D 16-Core Processor' -Cores 16)) { throw '7950X3D/16 debe ser true' }
    if (-not (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 9 9900X3D 12-Core Processor' -Cores 12)) { throw '9900X3D/12 debe ser true' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 7 9800X3D 8-Core Processor' -Cores 8)  { throw '9800X3D/8 debe ser false (single-CCD)' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 7 7800X3D 8-Core Processor' -Cores 8)  { throw '7800X3D/8 debe ser false (single-CCD)' }
    if (Test-IsX3dDualCcdCpu -CpuName 'AMD Ryzen 5 5600X 6-Core Processor' -Cores 6)    { throw '5600X debe ser false (no X3D)' }
    if (Test-IsX3dDualCcdCpu -CpuName '' -Cores 0)                                       { throw 'vacio debe ser false' }
}

# ─── #23b: Get-RamAdvisories (funcion pura; canario StrictMode de 1 elemento) ──
Test-SmokeFunction 'HwAdvisories' 'Get-RamAdvisories: 1 modulo -> single-channel' {
    $ErrorActionPreference = 'Stop'
    [object[]] $one = @([PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 })
    [object[]] $adv = @(Get-RamAdvisories -Modules $one)
    if ($adv.Count -ne 1)                          { throw ("1 modulo debe dar 1 aviso; got {0}" -f $adv.Count) }
    if ($adv[0] -notmatch 'single-channel')        { throw ("aviso esperado single-channel; got '{0}'" -f $adv[0]) }
}
Test-SmokeFunction 'HwAdvisories' 'Get-RamAdvisories: XMP off detectado / dual ok sin avisos' {
    $ErrorActionPreference = 'Stop'
    [object[]] $xmpOff = @(
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 2133 }
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 2133 }
    )
    [object[]] $adv = @(Get-RamAdvisories -Modules $xmpOff)
    if (@($adv | Where-Object { $_ -match 'XMP' }).Count -ne 1) { throw 'dual a 2133/3200 debe avisar XMP' }
    [object[]] $ok = @(
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 }
        [PSCustomObject]@{ CapacityGb = 8; SpeedMhz = 3200; ConfiguredMhz = 3200 }
    )
    if (@(Get-RamAdvisories -Modules $ok).Count -ne 0) { throw 'dual a rated no debe avisar' }
    if (@(Get-RamAdvisories -Modules @()).Count -ne 0) { throw 'vacio no debe avisar' }
}
Test-SmokeFunction 'HwAdvisories' 'Test-IsIntegratedGpuName: APU moderna (TM) = iGPU, dGPU sigue dGPU' {
    $ErrorActionPreference = 'Stop'
    # Regresion #23b: "(TM)" rompia el match y clasificaba la APU como dGPU
    if (-not (Test-IsIntegratedGpuName -GpuName 'AMD Radeon(TM) Graphics'))      { throw 'Radeon(TM) Graphics debe ser iGPU' }
    if (-not (Test-IsIntegratedGpuName -GpuName 'AMD Radeon(TM) 780M Graphics')) { throw 'Radeon(TM) 780M debe ser iGPU' }
    if (-not (Test-IsIntegratedGpuName -GpuName 'Radeon RX Vega 11 Graphics'))   { throw 'Vega 11 debe ser iGPU' }
    if (Test-IsIntegratedGpuName -GpuName 'AMD Radeon RX 6600')                  { throw 'RX 6600 debe ser dGPU' }
    if (Test-IsIntegratedGpuName -GpuName 'NVIDIA GeForce RTX 3060')             { throw 'RTX 3060 debe ser dGPU' }
}
Test-SmokeFunction 'HwAdvisories' 'Get-UmaAdvisory: APU UMA chico avisa / dGPU e Intel no' {
    $ErrorActionPreference = 'Stop'
    [string] $a = Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes (2GB)
    if ([string]::IsNullOrEmpty($a) -or $a -notmatch 'UMA') { throw ("APU 2GB debe avisar UMA; got '{0}'" -f $a) }
    if ((Get-UmaAdvisory -HasIGpuOnly $false -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes (2GB)) -ne '') { throw 'con dGPU no debe avisar' }
    if ((Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'Intel(R) UHD Graphics 630' -AdapterRamBytes (1GB)) -ne '') { throw 'Intel iGPU no debe avisar (UMA es de APU AMD)' }
    if ((Get-UmaAdvisory -HasIGpuOnly $true -GpuName 'AMD Radeon(TM) Graphics' -AdapterRamBytes 0) -ne '') { throw 'AdapterRAM 0 (desconocido/overflow) no debe avisar' }
}
Test-SmokeFunction 'HwAdvisories' 'Get-MachineProfile expone Advisories como [string[]]' {
    $ErrorActionPreference = 'Stop'
    $mp = Get-MachineProfile
    if ($null -eq $mp.PSObject.Properties['Advisories']) { throw 'falta propiedad Advisories' }
    [object[]] $a = @($mp.Advisories)
    foreach ($x in $a) { if ($x -isnot [string]) { throw 'Advisories debe contener solo strings' } }
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
