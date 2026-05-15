#Requires -Version 5.1
<#
.SYNOPSIS
    Non-interactive harness for Stage 2 re-test (post-fix P0).
    Runs Invoke-AutoProfile end-to-end with -SkipRestorePoint.
    Writes all artifacts as text files to $ArtifactsDir.
    Includes explicit P1 diagnostic: re-runs Compare-Snapshot with full exception capture.
    ASCII-only (no tildes, no box-drawing chars) - BOM-safe.
#>
param(
    [string] $ArtifactsDir = 'C:\stage2-retest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[string] $repoRoot   = Split-Path -Parent $PSScriptRoot
[string] $utilsDir   = Join-Path $repoRoot 'utils'
[string] $coreDir    = Join-Path $repoRoot 'core'
[string] $modulesDir = Join-Path $repoRoot 'modules'

# Ensure artifacts dir exists
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

# Dot-source: utils -> core -> modules (same order as smoke.ps1)
foreach ($folder in @($utilsDir, $coreDir, $modulesDir)) {
    Get-ChildItem -Path $folder -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}

Write-Host "=== STAGE 2 HARNESS (re-test post-fix P0) ==="
Write-Host "Repo root    : $repoRoot"
Write-Host "ArtifactsDir : $ArtifactsDir"
Write-Host ""

# Step 1: Get machine profile
Write-Host "[1] Get-MachineProfile ..."
$mp = Get-MachineProfile
$ramGb = [math]::Round($mp.RamMB / 1024, 1)
Write-Host "    RAM: $ramGb GB  |  Tier raw: $($mp.Tier)"

# Step 2: Resolve tier label
$tier = $mp.Tier
switch ($tier) {
    'Low'  { $tierLabel = 'Low'  }
    'High' { $tierLabel = 'High' }
    default { $tierLabel = 'Mid' }
}
Write-Host "    Tier resolved: $tierLabel"
Write-Host ""

# Step 3: Resolve profile path
Write-Host "[2] Get-AutoProfilePath -UseCase generic -Tier $tierLabel ..."
$profilePath = Get-AutoProfilePath -UseCase generic -Tier $tierLabel
Write-Host "    Path: $profilePath"
Write-Host ""

# Step 4: Import profile
Write-Host "[3] Import-AutoProfile -Path $profilePath ..."
$profile = Import-AutoProfile -Path $profilePath
Write-Host "    Schema: $($profile._schema_version)  UseCase: $($profile._use_case)  Tier: $($profile._tier)"
Write-Host ""

# Step 5: Invoke full pipeline (-SkipRestorePoint: Sandbox has System Restore off;
# without this flag, a hard failure triggers Confirm-Action interactive prompt -> hangs)
Write-Host "[4] Invoke-AutoProfile -SkipRestorePoint -ClientSlug test-harness ..."
Write-Host "    (this will mutate services, registry, temp files)"
Write-Host ""

$r = Invoke-AutoProfile -Profile $profile -MachineProfile $mp -ClientSlug 'test-harness' -SkipRestorePoint

Write-Host ""
Write-Host "=== RESULT STATUS: $($r.Status) ==="
Write-Host ""
Write-Host "=== RESULT JSON (Depth 8) ==="
$r | ConvertTo-Json -Depth 8
Write-Host ""

# =============================================================================
# P1 DIAGNOSTIC: Explicit re-run of Compare-Snapshot with full exception capture
# Goal: get the exact root cause of Compare=N/A (was silenced in ProfileEngine catch)
# =============================================================================
Write-Host "=== P1 DIAGNOSTIC: Compare-Snapshot explicit re-run ==="

[string] $snapshotsDir = Join-Path $repoRoot 'output\snapshots'
[string] $prePath  = ''
[string] $postPath = ''

# Try result paths first
$preOk  = $false
$postOk = $false
try {
    if ($r.PreSnapshot -and
        $r.PreSnapshot.PSObject.Properties['FilePath'] -and
        $r.PreSnapshot.FilePath -and
        (Test-Path $r.PreSnapshot.FilePath)) {
        $prePath = $r.PreSnapshot.FilePath
        $preOk   = $true
    }
} catch { }

try {
    if ($r.PostSnapshot -and
        $r.PostSnapshot.PSObject.Properties['FilePath'] -and
        $r.PostSnapshot.FilePath -and
        (Test-Path $r.PostSnapshot.FilePath)) {
        $postPath = $r.PostSnapshot.FilePath
        $postOk   = $true
    }
} catch { }

# Fall back to newest file search if result paths not usable
if (-not $preOk -and (Test-Path $snapshotsDir)) {
    $newest = Get-ChildItem -Path $snapshotsDir -Filter '*_pre.json' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { $prePath = $newest.FullName; $preOk = $true }
}

if (-not $postOk -and (Test-Path $snapshotsDir)) {
    $newest = Get-ChildItem -Path $snapshotsDir -Filter '*_post.json' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { $postPath = $newest.FullName; $postOk = $true }
}

Write-Host "  PrePath : $(if ($preOk)  { $prePath  } else { '<not found>' })"
Write-Host "  PostPath: $(if ($postOk) { $postPath } else { '<not found>' })"

[System.Collections.Generic.List[string]] $p1Lines =
    [System.Collections.Generic.List[string]]::new()
$p1Lines.Add("P1 DIAGNOSTIC: Compare-Snapshot explicit re-run")
$p1Lines.Add("PrePath : $(if ($preOk)  { $prePath  } else { '<not found>' })")
$p1Lines.Add("PostPath: $(if ($postOk) { $postPath } else { '<not found>' })")

if ($preOk -and $postOk) {
    try {
        $cmpResult = Compare-Snapshot -PrePath $prePath -PostPath $postPath
        $msg = "COMPARE OK score=$($cmpResult.Score)/$($cmpResult.ScoreMax)"
        Write-Host "  $msg"
        $p1Lines.Add($msg)
    } catch {
        $excText   = $_.Exception.ToString()
        $stackText = $_.ScriptStackTrace
        Write-Host "  COMPARE THREW:"
        Write-Host $excText
        Write-Host "  STACK:"
        Write-Host $stackText
        $p1Lines.Add("COMPARE THREW:")
        $p1Lines.Add($excText)
        $p1Lines.Add("STACK:")
        $p1Lines.Add($stackText)
    }
} else {
    $msg = "COMPARE SKIPPED: pre_found=$($preOk) post_found=$($postOk)"
    Write-Host "  $msg"
    $p1Lines.Add($msg)
}
Write-Host "=== END P1 DIAGNOSTIC ==="
Write-Host ""

# =============================================================================
# WRITE ARTIFACTS to $ArtifactsDir
# =============================================================================
Write-Host "=== WRITING ARTIFACTS to $ArtifactsDir ==="

# 1. ProfileRunResult.json
try {
    $resultJsonPath = Join-Path $ArtifactsDir 'ProfileRunResult.json'
    $r | ConvertTo-Json -Depth 8 | Out-File -FilePath $resultJsonPath -Encoding UTF8 -Force
    Write-Host "  [OK] ProfileRunResult.json"
} catch {
    Write-Host "  [ERR] ProfileRunResult.json: $($_.Exception.Message)"
}

# 2. p1-diagnostic.txt
try {
    $p1Path = Join-Path $ArtifactsDir 'p1-diagnostic.txt'
    $p1Lines | Out-File -FilePath $p1Path -Encoding UTF8 -Force
    Write-Host "  [OK] p1-diagnostic.txt"
} catch {
    Write-Host "  [ERR] p1-diagnostic.txt: $($_.Exception.Message)"
}

# 3. run-report.txt (copy from ClientRun if available, else generate summary)
try {
    $runReportPath    = Join-Path $ArtifactsDir 'run-report.txt'
    $clientReportSrc  = ''
    try {
        if ($r.ClientRun -and
            $r.ClientRun.PSObject.Properties['ReportPath'] -and
            $r.ClientRun.ReportPath -and
            (Test-Path $r.ClientRun.ReportPath)) {
            $clientReportSrc = $r.ClientRun.ReportPath
        }
    } catch { }

    if ($clientReportSrc) {
        Copy-Item -LiteralPath $clientReportSrc -Destination $runReportPath -Force
        Write-Host "  [OK] run-report.txt (copied from ClientRun)"
    } else {
        @(
            "=== STAGE 2 RUN REPORT (generated - no ClientRun.ReportPath) ==="
            "Status         : $($r.Status)"
            "Tier           : $($r.Tier)"
            "UseCase        : $($r.UseCase)"
            "StartedAt      : $($r.StartedAt)"
            "EndedAt        : $($r.EndedAt)"
            "DurationSec    : $($r.DurationSec)"
            ""
            "Privacy.Path   : $($r.Privacy.Path)"
            "Privacy.Success: $($r.Privacy.Success)"
            "Privacy.Detail : $($r.Privacy.Detail)"
        ) | Out-File -FilePath $runReportPath -Encoding UTF8 -Force
        Write-Host "  [OK] run-report.txt (generated summary)"
    }
} catch {
    Write-Host "  [ERR] run-report.txt: $($_.Exception.Message)"
}

# 4. meta.json (copy from ClientRun if available)
try {
    $metaJsonPath   = Join-Path $ArtifactsDir 'meta.json'
    $clientMetaSrc  = ''
    try {
        if ($r.ClientRun -and
            $r.ClientRun.PSObject.Properties['MetaPath'] -and
            $r.ClientRun.MetaPath -and
            (Test-Path $r.ClientRun.MetaPath)) {
            $clientMetaSrc = $r.ClientRun.MetaPath
        }
    } catch { }

    if ($clientMetaSrc) {
        Copy-Item -LiteralPath $clientMetaSrc -Destination $metaJsonPath -Force
        Write-Host "  [OK] meta.json (copied from ClientRun)"
    } else {
        '{"error":"ClientRun.MetaPath not found in result"}' |
            Out-File -FilePath $metaJsonPath -Encoding UTF8 -Force
        Write-Host "  [WARN] meta.json (ClientRun.MetaPath not available)"
    }
} catch {
    Write-Host "  [ERR] meta.json: $($_.Exception.Message)"
}

# 5. audit-line.txt — the Profile.Apply.Generic entry from today's audit log
try {
    $auditDir      = Join-Path $repoRoot 'output\audit'
    $auditLogPath  = Join-Path $auditDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
    $auditLinePath = Join-Path $ArtifactsDir 'audit-line.txt'

    if (Test-Path $auditLogPath) {
        $lines = @(Get-Content -LiteralPath $auditLogPath -Encoding UTF8 |
                   Where-Object { $_ -match 'Profile\.Apply\.Generic' })
        if ($lines.Count -gt 0) {
            $lines | Out-File -FilePath $auditLinePath -Encoding UTF8 -Force
            Write-Host "  [OK] audit-line.txt ($($lines.Count) entry/entries)"
        } else {
            "Profile.Apply.Generic not found in: $auditLogPath" |
                Out-File -FilePath $auditLinePath -Encoding UTF8 -Force
            Write-Host "  [WARN] audit-line.txt (entry not found in audit log)"
        }
    } else {
        "Audit log not found: $auditLogPath" |
            Out-File -FilePath $auditLinePath -Encoding UTF8 -Force
        Write-Host "  [WARN] audit-line.txt (audit log not found: $auditLogPath)"
    }
} catch {
    Write-Host "  [ERR] audit-line.txt: $($_.Exception.Message)"
}

Write-Host ""

# =============================================================================
# DONE sentinel — write last so host poll only fires when all artifacts are written
# =============================================================================
try {
    $donePath = Join-Path $ArtifactsDir 'DONE.txt'
    "DONE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') status=$($r.Status)" |
        Out-File -FilePath $donePath -Encoding ASCII -Force
    Write-Host "=== DONE sentinel written: $donePath ==="
} catch {
    Write-Host "=== [ERR] DONE sentinel failed: $($_.Exception.Message) ==="
}

Write-Host "=== HARNESS COMPLETE ==="
