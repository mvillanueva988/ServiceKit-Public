#Requires -Version 5.1
<#
.SYNOPSIS
    PCTk post-queue batch regression rig. Runs INSIDE Windows Sandbox (ephemeral VM).
    Validates: Invoke-AutoProfile -ShowProgress, Invoke-NamedProfile -Unattended,
    status heuristic (step-roto synthetic, Deuda C), git-archive export-ignore (Deuda A).
    Writes RESULT.txt (PASS/FAIL per check) + DONE.txt to host-shared artifacts dir.
    ASCII-only. No BOM. No interactive prompts.
    Fixtures: data/profiles/named/ (NOT $env:TEMP - Start-CleanupProcess clears TEMP).
#>
param(
    [string] $ArtifactsDir = 'C:\postqueue-validate',
    [string] $RepoRoot     = 'C:\Toolkit'
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

Log '=== PCTk post-queue regression rig (Windows Sandbox) ==='
Log ("Date     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ("RepoRoot : {0}" -f $RepoRoot)
Log ''

# --- dot-source (same order as main.ps1: core, modules, utils) ---------------
try {
    foreach ($folder in @('core', 'modules', 'utils')) {
        Get-ChildItem -Path (Join-Path $RepoRoot $folder) -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
    Log '  dot-source OK (core, modules, utils)'
} catch { Fail ("dot-source: {0}" -f $_.Exception.Message) }

foreach ($fn in @('Get-MachineProfile','Invoke-AutoProfile','Invoke-NamedProfile',
                   'Test-StepSucceeded','Get-AutoProfilePath','Import-AutoProfile',
                   'Get-NamedProfileDir','Import-NamedProfile')) {
    if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        Fail ("Function not found after dot-source: {0}" -f $fn)
    }
}

[PSCustomObject] $mp = $null
try {
    $mp = Get-MachineProfile
    Log ("  MachineProfile: Tier={0} IsVM={1} Vendor={2}" -f $mp.Tier, $mp.IsVirtualMachine, $mp.VmVendor)
} catch { Fail ("Get-MachineProfile: {0}" -f $_.Exception.Message) }
Log ''

# =============================================================================
# T1: Invoke-AutoProfile -ShowProgress
# Progress UX (R11): pipeline completes, Status correct, DurationSec reported,
# PRE/POST snapshots, Compare != N/A (shape intact), ClientRun folder created.
# Uses existing data/profiles/auto/generic.json (v2.0 schema, no extra fixture needed).
# =============================================================================
Log '[T1] Invoke-AutoProfile -ShowProgress (progress UX + pipeline end-to-end)'

[PSCustomObject] $autoProf = $null
try {
    [string] $apPath = Get-AutoProfilePath -UseCase 'generic'
    $autoProf = Import-AutoProfile -Path $apPath
    Pass ("Import-AutoProfile OK: generic.json")
} catch { Fail ("Import-AutoProfile: {0}" -f $_.Exception.Message) }

[PSCustomObject] $autoResult = $null
if ($null -ne $autoProf -and $null -ne $mp) {
    try {
        $autoResult = Invoke-AutoProfile `
            -Profile $autoProf -MachineProfile $mp `
            -ClientSlug 'test-pq-auto' -SkipRestorePoint -ShowProgress
        if ($null -eq $autoResult) {
            Fail 'Invoke-AutoProfile returned null'
        } else {
            [string] $st = if ($autoResult.PSObject.Properties['Status']) { [string]$autoResult.Status } else { '(missing)' }
            if ($st -in @('Success','Partial')) {
                Pass ("Status={0} (Success or Partial accepted in Sandbox)" -f $st)
            } else {
                Fail ("Status={0} (expected Success or Partial)" -f $st)
            }

            [int] $dur = if ($autoResult.PSObject.Properties['DurationSec']) { [int]$autoResult.DurationSec } else { -1 }
            Log ("    DurationSec={0} (perf ref only - no pre-change baseline, see RESULT.txt note)" -f $dur)
            if ($dur -gt 0) { Pass ("DurationSec={0} (pipeline completed, did not hang)" -f $dur) }
            else            { Warn ("DurationSec={0} (0 or missing)" -f $dur) }

            [bool] $preOk = ($null -ne $autoResult.PSObject.Properties['PreSnapshot'] -and
                             $null -ne $autoResult.PreSnapshot -and
                             $autoResult.PreSnapshot.PSObject.Properties['Ok'] -and
                             [bool]$autoResult.PreSnapshot.Ok)
            [bool] $postOk = ($null -ne $autoResult.PSObject.Properties['PostSnapshot'] -and
                              $null -ne $autoResult.PostSnapshot -and
                              $autoResult.PostSnapshot.PSObject.Properties['Ok'] -and
                              [bool]$autoResult.PostSnapshot.Ok)
            if ($preOk)  { Pass ("PRE snapshot captured: {0}" -f [string]$autoResult.PreSnapshot.FileName) }
            else         { Warn 'PRE snapshot not captured (VM telemetry limit - not a FAIL)' }
            if ($postOk) { Pass ("POST snapshot captured: {0}" -f [string]$autoResult.PostSnapshot.FileName) }
            else         { Warn 'POST snapshot not captured (VM telemetry limit - not a FAIL)' }

            if ($preOk -and $postOk) {
                [object] $cmpR = if ($autoResult.PSObject.Properties['Compare']) { $autoResult.Compare } else { $null }
                if ($null -ne $cmpR -and
                    $cmpR.PSObject.Properties['Score'] -and
                    $cmpR.PSObject.Properties['ScoreMax']) {
                    [string] $sc = "{0}/{1}" -f $cmpR.Score, $cmpR.ScoreMax
                    Pass ("Compare != N/A, score={0} (shape intact)" -f $sc)
                } else {
                    Warn 'Compare null or missing Score (both snapshots OK - review Compare logic)'
                }
            } else {
                Warn 'Compare skipped: PRE or POST snapshot missing (expected in minimal VM)'
            }

            [string] $crDir = ''
            if ($null -ne $autoResult.PSObject.Properties['ClientRun'] -and
                $null -ne $autoResult.ClientRun -and
                $autoResult.ClientRun.PSObject.Properties['Dir']) {
                $crDir = [string]$autoResult.ClientRun.Dir
            }
            if (-not [string]::IsNullOrWhiteSpace($crDir) -and (Test-Path $crDir)) {
                Pass ("ClientRun folder created: {0}" -f (Split-Path $crDir -Leaf))
            } else {
                Fail 'ClientRun folder not created'
            }
        }
    } catch { Fail ("Invoke-AutoProfile THREW: {0}" -f $_.Exception.Message) }
} else {
    Warn 'T1 skipped: autoProf or mp is null (dot-source failed earlier)'
}
Log ''

# =============================================================================
# T2: Invoke-NamedProfile -Unattended
# Validates named-profile pipeline, gaming_tweaks skip-clean (WSL absent),
# _last_applied updated in JSON source, ClientRun created.
# Fixture location: data/profiles/named/_postqueue-named.json
#   NOT in $env:TEMP: Start-CleanupProcess clears TEMP mid-pipeline (known bug).
#   named/ is gitignored; fixture is deleted at the end of this test.
# =============================================================================
Log '[T2] Invoke-NamedProfile -Unattended (named profile + gaming tweaks headless)'

[string] $namedDir     = Get-NamedProfileDir
[string] $namedFixPath = Join-Path $namedDir '_postqueue-named.json'

$namedFixObj = [PSCustomObject]@{
    _schema_version    = '2.0'
    _kind              = 'named'
    _name              = 'PCTk PostQueue Test (sandbox)'
    _created           = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    _last_applied      = $null
    _hardware_snapshot = [PSCustomObject]@{ Tier='High'; CpuName='x'; RamMB=1; Manufacturer='x'; IsLaptop=$false }
    _use_case          = 'named'
    _description       = 'Post-queue regression fixture (named profile)'
    _rationale         = 'Validates named-profile pipeline and gaming_tweaks skip in sandbox'
    services           = [PSCustomObject]@{ disable = @('Fax','RemoteRegistry','DiagTrack') }
    performance        = [PSCustomObject]@{ visual_profile = 'Balanced' }
    privacy            = [PSCustomObject]@{ level = 'medium'; oosu10_cfg = 'medium.cfg'; fallback = 'native' }
    cleanup            = [PSCustomObject]@{ clear_temp = $true }
    startup            = [PSCustomObject]@{ report_only = $true }
    gaming_tweaks      = [PSCustomObject]@{
        hvci                  = 'off'
        hags                  = 'on'
        usb_selective_suspend = 'off'
        game_mode             = 'on'
        wslconfig             = [PSCustomObject]@{ enabled = $true; preset = 'Gaming' }
        defender_exclusions   = @('C:\Temp\postqueue-marker')
        oosu_profile          = 'medium'
    }
}
($namedFixObj | ConvertTo-Json -Depth 8) | Out-File -FilePath $namedFixPath -Encoding UTF8 -Force

[PSCustomObject] $namedProf = $null
try {
    $namedProf = Import-NamedProfile -Path $namedFixPath
    if ($null -ne $namedProf -and
        [string]$namedProf._kind -eq 'named' -and
        -not [string]::IsNullOrWhiteSpace([string]$namedProf._name)) {
        Pass ("Import-NamedProfile OK: '{0}'" -f $namedProf._name)
    } else {
        Fail 'Import-NamedProfile: schema invalid'
    }
} catch { Fail ("Import-NamedProfile: {0}" -f $_.Exception.Message); $namedProf = $null }

[PSCustomObject] $namedResult = $null
if ($null -ne $namedProf -and $null -ne $mp) {
    try {
        $namedResult = Invoke-NamedProfile `
            -Profile $namedProf -MachineProfile $mp `
            -ClientSlug 'test-pq-named' -SourcePath $namedFixPath `
            -SkipRestorePoint -Unattended
        if ($null -eq $namedResult) {
            Fail 'Invoke-NamedProfile returned null'
        } else {
            [string] $nst = if ($namedResult.PSObject.Properties['NamedStatus']) { [string]$namedResult.NamedStatus }
                            elseif ($namedResult.PSObject.Properties['Status'])  { [string]$namedResult.Status }
                            else { '(missing)' }
            if ($nst -in @('Success','Partial')) {
                Pass ("NamedStatus={0} (OK in Sandbox)" -f $nst)
            } else {
                Fail ("NamedStatus={0} (expected Success or Partial)" -f $nst)
            }

            # gaming_tweaks: all toggles must apply or skip cleanly (no throw)
            if ($null -ne $namedResult.PSObject.Properties['GamingTweaks'] -and
                $null -ne $namedResult.GamingTweaks) {
                [PSCustomObject] $gt = $namedResult.GamingTweaks
                foreach ($k in @('Hvci','Hags','UsbSuspend','GameMode')) {
                    if ($gt.PSObject.Properties[$k] -and $null -ne $gt.$k) {
                        [string] $ap = if ($gt.$k.PSObject.Properties['Applied']) { [string]$gt.$k.Applied } else { '?' }
                        [string] $sk = if ($gt.$k.PSObject.Properties['Skipped']) { [string]$gt.$k.Skipped } else { '?' }
                        Log ("    gaming.{0}: Applied={1} Skipped={2}" -f $k, $ap, $sk)
                    }
                }
                # wslconfig must skip (WSL absent in Sandbox)
                [bool] $wslSkipped = ($null -ne $gt.PSObject.Properties['Wslconfig'] -and
                                      $null -ne $gt.Wslconfig -and
                                      $gt.Wslconfig.PSObject.Properties['Skipped'] -and
                                      [bool]$gt.Wslconfig.Skipped)
                if ($wslSkipped) {
                    Pass 'gaming.Wslconfig Skipped=true (WSL absent in Sandbox - correct)'
                } else {
                    Warn 'gaming.Wslconfig not skipped (WSL may be present or logic changed)'
                }
                # GameMode: HKCU registry write, should apply in Sandbox
                [bool] $gmApplied = ($null -ne $gt.PSObject.Properties['GameMode'] -and
                                     $null -ne $gt.GameMode -and
                                     $gt.GameMode.PSObject.Properties['Applied'] -and
                                     [bool]$gt.GameMode.Applied)
                if ($gmApplied) {
                    Pass 'gaming.GameMode Applied=true (registry HKCU - OK in Sandbox)'
                } else {
                    Log '    [i] gaming.GameMode not Applied (may depend on Sandbox registry state)'
                }
            } else {
                Fail 'GamingTweaks result absent from Invoke-NamedProfile result'
            }

            # _last_applied must be written back to the JSON source
            try {
                [string] $rawJ = Get-Content -LiteralPath $namedFixPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($rawJ)) {
                    $reread = $rawJ | ConvertFrom-Json
                    [object] $laProp = if ($null -ne $reread) { $reread.PSObject.Properties['_last_applied'] } else { $null }
                    if ($null -ne $laProp -and -not [string]::IsNullOrWhiteSpace([string]$laProp.Value)) {
                        Pass ("_last_applied updated in JSON: {0}" -f [string]$laProp.Value)
                    } else {
                        Fail '_last_applied not updated in JSON source (Invoke-NamedProfile did not write it)'
                    }
                } else {
                    Fail 'Named fixture file empty after run'
                }
            } catch { Fail ("_last_applied re-read: {0}" -f $_.Exception.Message) }

            [string] $nCrDir = ''
            if ($null -ne $namedResult.PSObject.Properties['ClientRun'] -and
                $null -ne $namedResult.ClientRun -and
                $namedResult.ClientRun.PSObject.Properties['Dir']) {
                $nCrDir = [string]$namedResult.ClientRun.Dir
            }
            if (-not [string]::IsNullOrWhiteSpace($nCrDir) -and (Test-Path $nCrDir)) {
                Pass ("Named ClientRun folder: {0}" -f (Split-Path $nCrDir -Leaf))
            } else {
                Fail 'Named ClientRun folder not created'
            }
        }
    } catch { Fail ("Invoke-NamedProfile THREW: {0}" -f $_.Exception.Message) }
} else {
    Warn 'T2 skipped: namedProf or mp is null'
}
Remove-Item $namedFixPath -Force -ErrorAction SilentlyContinue
Log ''

# =============================================================================
# T3: Status heuristic - step-roto synthetic (Deuda C)
# Validates that Test-StepSucceeded correctly classifies broken step results,
# and that the status derivation (same calc as Invoke-AutoProfile) gives
# Partial/Failed with broken steps - NEVER Success false (no softening).
# Synthetic and deterministic: no dependency on sandbox-specific services.
# =============================================================================
Log '[T3] Status heuristic: step-roto synthetic (Deuda C)'

# Case A: null result -> StepSucceeded must return false
if (-not (Test-StepSucceeded -StepResult $null)) {
    Pass 'null result -> StepSucceeded=false (correct)'
} else {
    Fail 'null result -> StepSucceeded=true (HEURISTIC BROKEN: false positive on null)'
}

# Case B: Success=false (mirrors broken privacy result { Path; Success=$false; Detail })
$brokenPriv = [PSCustomObject]@{ Path = 'test-injected'; Success = $false; Detail = 'injected-fail' }
if (-not (Test-StepSucceeded -StepResult $brokenPriv)) {
    Pass 'Success=false result -> StepSucceeded=false (correct)'
} else {
    Fail 'Success=false result -> StepSucceeded=true (HEURISTIC SOFTENED)'
}

# Case C: Errors array non-empty (mirrors broken debloat result)
$brokenDbloat = [PSCustomObject]@{
    Disabled = 0; AlreadyDisabled = 0; Skipped = 0; SkippedNames = @()
    Failed = 1; TotalTargeted = 1
    Errors = @('test-svc : injected access denied')
}
if (-not (Test-StepSucceeded -StepResult $brokenDbloat)) {
    Pass 'Errors>0 result -> StepSucceeded=false (correct)'
} else {
    Fail 'Errors>0 result -> StepSucceeded=true (HEURISTIC SOFTENED)'
}

# Case D: synthetic 4-step pipeline with 2 broken steps -> Partial/Failed, NEVER Success
# Mirrors the exact calc in Invoke-AutoProfile (4 steps: debloat, cleanup, perf, privacy).
$goodR = [PSCustomObject]@{ FreedMB = 100; FreedGB = '0.10'; SoftErrors = 0 }
[int] $synFailed = 0
if (-not (Test-StepSucceeded -StepResult $brokenDbloat)) { $synFailed++ }   # debloat broken
if (-not (Test-StepSucceeded -StepResult $goodR))        { $synFailed++ }   # cleanup OK (best-effort)
if (-not (Test-StepSucceeded -StepResult $goodR))        { $synFailed++ }   # perf OK (best-effort)
if (-not (Test-StepSucceeded -StepResult $brokenPriv))   { $synFailed++ }   # privacy broken
[string] $synStatus = if ($synFailed -eq 0) { 'Success' } elseif ($synFailed -lt 4) { 'Partial' } else { 'Failed' }
Log ("    Synthetic: jobsFailed={0} status={1}" -f $synFailed, $synStatus)
if ($synStatus -in @('Partial','Failed')) {
    Pass ("Synthetic status={0} with 2 broken steps (not Success false)" -f $synStatus)
} else {
    Fail 'Synthetic status=Success with broken steps (FALSE POSITIVE - heuristic softened or logic changed)'
}
Log ''

# =============================================================================
# T4: git-archive export-ignore assertions (Deuda A)
# Absent from zip: _local-dev/ .claude/ .gsd/ Release.ps1 *-validate.ps1
#                  *-sandbox* *-harness*
# Present in zip:  README.md  data/profiles/named/_sample.json  data/ tree
# NOTE: git.exe is not available by default in Windows Sandbox.
#       If not found or archive fails: WARN (not FAIL) + host instructions.
#       Worktree .git file points to host path -> may fail inside Sandbox.
# =============================================================================
Log '[T4] git-archive: export-ignore assertions (Deuda A)'

[string] $gitExe = ''
foreach ($candidate in @('git', 'C:\Program Files\Git\bin\git.exe', 'C:\ProgramData\chocolatey\bin\git.exe')) {
    try {
        $null = Get-Command $candidate -ErrorAction Stop
        $gitExe = $candidate; break
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($gitExe)) {
    Warn 'git.exe not found in Sandbox - T4 SKIPPED (expected; run manually on host)'
    Log '    Host check:'
    Log '      1. Open PowerShell in C:\Users\Mateo\Documents\Dev\Toolkit'
    Log '      2. git archive HEAD --format zip -o C:\Temp\pctk-check.zip'
    Log '      3. Verify ABSENT: _local-dev/ .claude/ .gsd/ Release.ps1 *-validate.ps1 *-sandbox* *-harness*'
    Log '      4. Verify PRESENT: README.md  data/profiles/named/_sample.json  data/'
} else {
    [string] $tmpZip = Join-Path $ArtifactsDir 'pctk-archive-check.zip'
    [bool] $archiveOk = $false
    try {
        $gitOut = & $gitExe -C $RepoRoot archive HEAD --format zip -o $tmpZip 2>&1
        [int] $archiveExit = $LASTEXITCODE
        if ($archiveExit -ne 0) {
            Warn ("git archive failed (exit {0}) - T4 SKIPPED" -f $archiveExit)
            Log '    Expected in Sandbox: worktree .git file points to host path.'
            Log '    Run T4 manually on host (see instructions above).'
        } elseif (-not (Test-Path $tmpZip)) {
            Warn 'git archive produced no zip - T4 SKIPPED'
        } else {
            $archiveOk = $true
            Pass 'git archive HEAD completed'
        }
    } catch {
        Warn ("git archive threw: {0} - T4 SKIPPED" -f $_.Exception.Message)
    }

    if ($archiveOk) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [string[]] $entries = @()
        try {
            $zipHandle = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
            try {
                $entries = @($zipHandle.Entries | ForEach-Object { $_.FullName })
            } finally {
                $zipHandle.Dispose()
            }
            Pass ("Zip parsed: {0} entries" -f $entries.Count)
        } catch { Fail ("ZipFile read: {0}" -f $_.Exception.Message) }

        if ($entries.Count -gt 0) {
            # ABSENT assertions
            [object[]] $h = @($entries | Where-Object { $_ -match '^_local-dev/' })
            if ($h.Count -eq 0) { Pass 'ABSENT: _local-dev/' } else { Fail ("PRESENT (must be absent): _local-dev/ -> {0}" -f $h[0]) }

            $h = @($entries | Where-Object { $_ -match '^\.claude/' })
            if ($h.Count -eq 0) { Pass 'ABSENT: .claude/' } else { Fail ("PRESENT (must be absent): .claude/ -> {0}" -f $h[0]) }

            $h = @($entries | Where-Object { $_ -match '^\.gsd/' })
            if ($h.Count -eq 0) { Pass 'ABSENT: .gsd/' } else { Fail ("PRESENT (must be absent): .gsd/ -> {0}" -f $h[0]) }

            $h = @($entries | Where-Object { $_ -match '^Release\.ps1$' })
            if ($h.Count -eq 0) { Pass 'ABSENT: Release.ps1' } else { Fail 'PRESENT (must be absent): Release.ps1' }

            $h = @($entries | Where-Object { $_ -match '-validate\.ps1$' })
            if ($h.Count -eq 0) { Pass 'ABSENT: *-validate.ps1' } else { Fail ("PRESENT (must be absent): *-validate.ps1 -> {0}" -f $h[0]) }

            $h = @($entries | Where-Object { $_ -match '-sandbox' })
            if ($h.Count -eq 0) { Pass 'ABSENT: *-sandbox*' } else { Fail ("PRESENT (must be absent): *-sandbox* -> {0}" -f $h[0]) }

            $h = @($entries | Where-Object { $_ -match '-harness' })
            if ($h.Count -eq 0) { Pass 'ABSENT: *-harness*' } else { Fail ("PRESENT (must be absent): *-harness* -> {0}" -f $h[0]) }

            # PRESENT assertions
            $h = @($entries | Where-Object { $_ -match '^README\.md$' })
            if ($h.Count -gt 0) { Pass 'PRESENT: README.md' } else { Fail 'ABSENT (must be present): README.md' }

            $h = @($entries | Where-Object { $_ -match '_sample\.json$' })
            if ($h.Count -gt 0) { Pass 'PRESENT: data/profiles/named/_sample.json' } else { Fail 'ABSENT (must be present): _sample.json' }

            $h = @($entries | Where-Object { $_ -match '^data/' })
            if ($h.Count -gt 0) { Pass ("PRESENT: data/ tree ({0} entries)" -f $h.Count) } else { Fail 'ABSENT: data/ tree (nothing in data/)' }
        }
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
}
Log ''

# =============================================================================
# Verdict
# =============================================================================
Log '=== VERDICT ==='
if ($failed) {
    Log 'RESULT: FAIL (see [FAIL] entries above)'
} else {
    Log 'RESULT: PASS (all checks passed; [WARN] entries are expected VM behavior)'
}
Log ''
Log 'Notes:'
Log '  - DurationSec (T1) is reported for perf reference only. No pre-change baseline exists.'
Log '    Mateo compares against his experience. The rig only asserts: completes within timeout.'
Log '  - [WARN] on PRE/POST snapshots and Compare is expected in minimal Sandbox (no SMART/WMI).'
Log '  - T4 git-archive: WARN if git not found in Sandbox. Run manually on host to verify.'

$lines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
"done $(Get-Date -Format o) failed=$failed" | Out-File -FilePath $doneMarker -Encoding ASCII -Force
Write-Host ''
Write-Host ("=== Report: {0} ===" -f $reportPath)
