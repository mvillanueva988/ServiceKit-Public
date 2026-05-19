#Requires -Version 5.1
<#
.SYNOPSIS
    PCTk self-uninstall destructive regression rig. Runs INSIDE Windows Sandbox
    (ephemeral VM). Validates the REAL detached-deleter mechanism from
    modules/UninstallToolkit.ps1 (commit 8fde9ef) against throwaway fixtures.
    NEVER touches the read-only mapped source. ASCII-only. No BOM. Headless.

    Checks:
      T0  committed code loads + parses; uninstall functions present
      T1  guard (s6.2): Invoke-UninstallToolkit on a NON-PCTk root -> $false,
          deletes nothing (no main.ps1 + core\Router.ps1)
      T2  destructive end-to-end: New-PctkUninstallScript + detached launch
          (same Start-Process as the handler) wipes ONLY the install fixture +
          $env:TEMP\PCTk-* , self-deletes, writes .log, leaves out-of-footprint
          sentinels intact. Simula race del cmd.exe con un cwdHolder separado
          (CWD=fixture, 10s) que vive mas que el PID que el deleter espera (3s).

    Interactive double-confirm / preserve prompts are NOT driven here (Read-Host;
    covered by code review + T1 abort path). RESULT.txt + DONE.txt to host dir.
#>
param(
    [string] $ArtifactsDir = 'C:\uninstall-validate',
    [string] $RepoRoot     = 'C:\PCTk'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ArtifactsDir)) { New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null }
[string] $reportPath = Join-Path $ArtifactsDir 'RESULT.txt'
[string] $doneMarker = Join-Path $ArtifactsDir 'DONE.txt'
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

$lines  = New-Object System.Collections.Generic.List[string]
$failed = $false
function Log([string]$m)  { Write-Host $m; $script:lines.Add($m) }
function Pass([string]$m) { Log "  [PASS] $m" }
function Fail([string]$m) { $script:failed = $true; Log "  [FAIL] $m" }
function Warn([string]$m) { Log "  [WARN] $m" }

Log '=== PCTk self-uninstall destructive rig (Windows Sandbox) ==='
Log ("Date     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ("RepoRoot : {0}" -f $RepoRoot)
Log ("Artifacts: {0}" -f $ArtifactsDir)
Log ''

# =============================================================================
# T0: committed code loads + parses; uninstall functions present
# =============================================================================
Log '[T0] Committed code load + parse + functions present'

[string] $modPath = Join-Path $RepoRoot 'modules\UninstallToolkit.ps1'
if (-not (Test-Path $modPath)) {
    Fail ("modules\UninstallToolkit.ps1 not found at {0}" -f $modPath)
} else {
    $perr = $null; $ptok = $null
    [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$ptok, [ref]$perr) | Out-Null
    if ($perr -and $perr.Count -gt 0) { Fail ("UninstallToolkit.ps1 parse errors: {0}" -f $perr.Count) }
    else { Pass 'UninstallToolkit.ps1 parses clean' }
}

try {
    foreach ($folder in @('core', 'modules', 'utils')) {
        $fp = Join-Path $RepoRoot $folder
        if (Test-Path $fp) {
            Get-ChildItem -Path $fp -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
        }
    }
    Pass 'dot-source OK (core, modules, utils)'
} catch { Fail ("dot-source: {0}" -f $_.Exception.Message) }

foreach ($fn in @('Invoke-UninstallToolkit','New-PctkUninstallScript','Show-MainMenu',
                  'Confirm-Action','Write-ActionAudit')) {
    if (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue) {
        Pass ("function present: {0}" -f $fn)
    } else {
        Fail ("function MISSING after dot-source: {0}" -f $fn)
    }
}
Log ''

# =============================================================================
# T1: guard refuses a NON-PCTk root (s6.2) -> $false, deletes nothing
#   Build C:\GuardTest\modules\ with a copy of UninstallToolkit.ps1 + a stub
#   that provides Confirm-Action/Write-ActionAudit. NO C:\GuardTest\main.ps1
#   -> guard must fail BEFORE any prompt or Remove-Item.
# =============================================================================
Log '[T1] Guard refuses non-PCTk root (no main.ps1 + core\Router.ps1)'

[string] $guardRoot = 'C:\GuardTest'
try {
    if (Test-Path $guardRoot) { Remove-Item $guardRoot -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $guardRoot 'modules') -Force | Out-Null
    Copy-Item -Path $modPath -Destination (Join-Path $guardRoot 'modules\UninstallToolkit.ps1') -Force
    # stub deps so the module's calls resolve if ever reached (must NOT be reached)
    [string] $stub = @'
function Confirm-Action { param([string]$Title,[string[]]$Lines=@(),[bool]$DefaultYes=$true) return $true }
function Write-ActionAudit { param([string]$Action,[string]$Status='Started',[string]$Summary='',[object]$Details=$null) }
'@
    Set-Content -LiteralPath (Join-Path $guardRoot 'modules\_stub.ps1') -Value $stub -Encoding ASCII
    New-Item -ItemType File -Path (Join-Path $guardRoot 'GUARD_SENTINEL.txt') -Force | Out-Null

    # Fresh runspace so the guarded module's $PSScriptRoot = C:\GuardTest\modules
    $psi = [PowerShell]::Create()
    $null = $psi.AddScript({
        param($gr)
        . (Join-Path $gr 'modules\_stub.ps1')
        . (Join-Path $gr 'modules\UninstallToolkit.ps1')
        Invoke-UninstallToolkit
    }).AddArgument($guardRoot)
    $out = $psi.Invoke()
    $psi.Dispose()

    [bool] $ret = $false
    if ($out -and $out.Count -gt 0) { $ret = [bool]$out[$out.Count - 1] }

    if ($ret -eq $false) { Pass 'Invoke-UninstallToolkit returned $false on non-PCTk root' }
    else { Fail 'Invoke-UninstallToolkit returned $true on non-PCTk root (GUARD BROKEN)' }

    if (Test-Path (Join-Path $guardRoot 'GUARD_SENTINEL.txt')) {
        Pass 'guard root NOT deleted (no destructive action on invalid root)'
    } else {
        Fail 'guard root content deleted (GUARD allowed Remove-Item on non-PCTk dir)'
    }
} catch {
    Fail ("T1 threw: {0}" -f $_.Exception.Message)
} finally {
    if (Test-Path $guardRoot) { Remove-Item $guardRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
Log ''

# =============================================================================
# T2: destructive end-to-end (the real risk)
#   - synthetic PCTk install fixture (passes the guard: main.ps1 + core\Router.ps1)
#   - TEMP decoys PCTk-*  + out-of-footprint survivors
#   - real New-PctkUninstallScript + same detached Start-Process as the handler
#   - assert: fixture GONE, PCTk-* GONE, deleter self-deleted, survivors INTACT
# =============================================================================
Log '[T2] Destructive end-to-end: detached deleter wipes ONLY the footprint'

[string] $fixRoot   = 'C:\PCTk-fixture'
[string] $keepDir   = 'C:\KEEPME'
[string] $keepTemp  = Join-Path $env:TEMP 'KEEP-notpctk.txt'
[string] $tmpZip    = Join-Path $env:TEMP 'PCTk-update.zip'
[string] $tmpStage  = Join-Path $env:TEMP 'PCTk-staging'

try {
    foreach ($d in @($fixRoot, $keepDir, $tmpStage)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    foreach ($f in @($keepTemp, $tmpZip)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }

    # synthetic install (guard expects main.ps1 + core\Router.ps1)
    New-Item -ItemType Directory -Path (Join-Path $fixRoot 'core') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixRoot 'modules') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixRoot 'output\clients\acme_20260517') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixRoot 'main.ps1') -Value '# fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $fixRoot 'core\Router.ps1') -Value '# fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $fixRoot 'MARKER.txt') -Value 'delete-me' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $fixRoot 'output\clients\acme_20260517\run-report.txt') -Value 'client' -Encoding ASCII

    # TEMP decoys (must be wiped by the PCTk-* glob)
    Set-Content -LiteralPath $tmpZip -Value 'zip' -Encoding ASCII
    New-Item -ItemType Directory -Path $tmpStage -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tmpStage 'f.txt') -Value 'stage' -Encoding ASCII

    # out-of-footprint survivors (must remain)
    New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $keepDir 'sentinel.txt') -Value 'KEEP' -Encoding ASCII
    Set-Content -LiteralPath $keepTemp -Value 'KEEP' -Encoding ASCII

    # CWD holder: simula el cmd.exe de Run.bat que retiene CWD=fixture
    # despues de que powershell.exe (dummyPid) ya termino. Dura 10s.
    $cwdHolder = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 10') `
        -WorkingDirectory $fixRoot -WindowStyle Hidden -PassThru

    # dummy "PCTk process" the deleter will wait on (exits faster que cwdHolder)
    $dummy = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 3') `
        -WindowStyle Hidden -PassThru
    [int] $dummyPid = $dummy.Id
    Log ("    dummy PCTk PID = {0}  cwdHolder PID = {1}" -f $dummyPid, $cwdHolder.Id)

    # REAL committed generator
    [string] $deleterText = New-PctkUninstallScript -InstallRoot $fixRoot -PctkPid $dummyPid
    [string] $deleterPath = Join-Path $env:TEMP ('pctk-uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ps1')
    [System.IO.File]::WriteAllText($deleterPath, $deleterText, [System.Text.Encoding]::UTF8)
    Pass ("deleter written: {0}" -f (Split-Path $deleterPath -Leaf))

    # same detached launch as Invoke-UninstallToolkit
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-NonInteractive','-File',$deleterPath
    ) -WindowStyle Hidden -ErrorAction Stop
    Pass 'deleter launched detached (-WindowStyle Hidden)'

    # poll up to 90s for the fixture to disappear
    [int] $waited = 0
    while ($waited -lt 90 -and (Test-Path $fixRoot)) { Start-Sleep -Seconds 2; $waited += 2 }
    Log ("    waited {0}s for deletion" -f $waited)

    if (-not (Test-Path $fixRoot)) { Pass 'install fixture C:\PCTk-fixture DELETED' }
    else { Fail 'install fixture still present after 90s (deleter did not wipe root)' }

    if (-not (Test-Path $tmpZip) -and -not (Test-Path $tmpStage)) {
        Pass '$env:TEMP\PCTk-* decoys DELETED'
    } else {
        Fail ('$env:TEMP\PCTk-* leftovers: zip={0} stage={1}' -f (Test-Path $tmpZip), (Test-Path $tmpStage))
    }

    Start-Sleep -Seconds 3
    if (-not (Test-Path $deleterPath)) { Pass 'deleter script self-deleted' }
    else { Fail 'deleter script NOT self-deleted' }

    [string] $logPath = $deleterPath -replace '\.ps1$', '.log'
    if (Test-Path $logPath) {
        [string] $logContent = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
        if ($logContent -match 'Deleted\s+:\s+True') {
            Pass 'log de desinstalacion presente y reporta Deleted: True'
        } else {
            Fail ('log presente pero sin Deleted: True; contenido: ' + $logContent)
        }
    } else {
        Fail 'log de desinstalacion NO creado por el deleter'
    }

    # out-of-footprint MUST survive
    if ((Test-Path (Join-Path $keepDir 'sentinel.txt'))) {
        Pass 'C:\KEEPME survived (nothing deleted outside footprint)'
    } else {
        Fail 'C:\KEEPME deleted (DESTRUCTIVE OVERREACH - outside footprint)'
    }
    if ((Test-Path $keepTemp)) {
        Pass '$env:TEMP\KEEP-notpctk.txt survived (PCTk-* glob did not over-match)'
    } else {
        Fail '$env:TEMP\KEEP-notpctk.txt deleted (glob over-matched non-PCTk temp)'
    }
} catch {
    Fail ("T2 threw: {0}" -f $_.Exception.Message)
} finally {
    if ($cwdHolder -and -not $cwdHolder.HasExited) { $cwdHolder.Kill() }
    foreach ($d in @($fixRoot, $keepDir, $tmpStage)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($f in @($keepTemp, $tmpZip)) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem -Path $env:TEMP -Filter 'pctk-uninstall-*.ps1' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $env:TEMP -Filter 'pctk-uninstall-*.log' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Log ''

# =============================================================================
# Verdict
# =============================================================================
Log '=== VERDICT ==='
if ($failed) {
    Log 'RESULT: FAIL (see [FAIL] entries above)'
} else {
    Log 'RESULT: PASS (deleter wipes only the PCTk footprint; guard refuses non-PCTk)'
}
Log ''
Log 'Notes:'
Log '  - Interactive gates (double-confirm + BORRAR + preserve path) are Read-Host;'
Log '    NOT driven headless. Covered by Opus code review + T1 (guard abort path).'
Log '  - T2 exercises the exact destructive path of Invoke-UninstallToolkit:'
Log '    the committed New-PctkUninstallScript output + the same detached'
Log '    Start-Process invocation. Host worktree mapped READ-ONLY, never the target.'
Log '  - T2 simula la race del cmd.exe via cwdHolder separado (CWD=fixture, 10s)'
Log '    que sigue vivo cuando el PID-espera (3s) ya termino; el retry-loop del'
Log '    deleter debe aguantar hasta que cwdHolder suelte el handle.'
Log '  - Re-gate Sandbox OBLIGATORIO para validar el escenario Run.bat real.'

$lines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
"done $(Get-Date -Format o) failed=$failed" | Out-File -FilePath $doneMarker -Encoding ASCII -Force
Write-Host ''
Write-Host ("=== Report: {0} ===" -f $reportPath)
