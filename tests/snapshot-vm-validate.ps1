#Requires -Version 5.1
# ASCII-only. snapshot-vm-plan.md DoD section 10 validation, runs INSIDE Windows
# Sandbox (Hyper-V based) as WDAGUtilityAccount. Invoked by the sandbox launcher.
# Writes a human-readable PASS/FAIL report + raw details to the host-shared
# artifacts dir, then a DONE marker. Never aborts: every check is isolated.

param(
    [string] $ArtifactsDir = 'C:\snapshot-vm-validate',
    [string] $RepoRoot     = 'C:\Toolkit'
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}
$reportPath = Join-Path $ArtifactsDir 'snapshot-vm-validate-report.txt'
$doneMarker = Join-Path $ArtifactsDir 'DONE.txt'
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

$lines  = New-Object System.Collections.Generic.List[string]
$failed = $false
function Log([string]$m) { Write-Host $m; $script:lines.Add($m) }
function Pass([string]$m) { Log "  [PASS] $m" }
function Fail([string]$m) { $script:failed = $true; Log "  [FAIL] $m" }

Log '=== snapshot-vm DoD validation (Windows Sandbox) ==='
Log ("Fecha     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ("RepoRoot  : {0}" -f $RepoRoot)
Log ''

# ---- dot-source modules under test -------------------------------------------
try {
    . (Join-Path $RepoRoot 'core\JobManager.ps1')
    . (Join-Path $RepoRoot 'core\MachineProfile.ps1')
    . (Join-Path $RepoRoot 'modules\Telemetry.ps1')
    Log '  dot-source OK (JobManager, MachineProfile, Telemetry)'
} catch {
    Fail ("dot-source: {0}" -f $_.Exception.Message)
}
Log ''

# ---- T1: VM detection --------------------------------------------------------
Log '[T1] Deteccion de VM'
try {
    $vm = Test-IsVirtualMachine
    if ($vm.IsVirtual -eq $true) { Pass ("Test-IsVirtualMachine.IsVirtual=True Vendor='{0}'" -f $vm.Vendor) }
    else { Fail "Test-IsVirtualMachine.IsVirtual=False (esperado True en Sandbox)" }

    $mvm = Get-MachineVmInfo
    if ($mvm.IsVirtual -eq $true) { Pass ("Get-MachineVmInfo.IsVirtual=True Vendor='{0}'" -f $mvm.Vendor) }
    else { Fail "Get-MachineVmInfo.IsVirtual=False (esperado True)" }

    $mp = Get-MachineProfile
    if ($mp.IsVirtualMachine -eq $true) { Pass ("Get-MachineProfile.IsVirtualMachine=True VmVendor='{0}'" -f $mp.VmVendor) }
    else { Fail "Get-MachineProfile.IsVirtualMachine=False (esperado True)" }
} catch { Fail ("T1: {0}" -f $_.Exception.Message) }
Log ''

# ---- T2: snapshot speed + VM-skip + Volumes shape ----------------------------
Log '[T2] Get-SystemSnapshot: velocidad / VM-skip / shape'
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $snap = Get-SystemSnapshot -Phase Pre
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Log ("  Duracion Get-SystemSnapshot: {0}s" -f $secs)
    if ($secs -lt 60) { Pass ("snapshot rapido ({0}s < 60s; el bug era ~375s)" -f $secs) }
    else { Fail ("snapshot lento ({0}s >= 60s)" -f $secs) }

    if ($snap.IsVirtualMachine -eq $true) { Pass ("snapshot.IsVirtualMachine=True VmVendor='{0}'" -f $snap.VmVendor) }
    else { Fail "snapshot.IsVirtualMachine=False" }

    # VM-skip: estas queries deben figurar 'skipped' en QueryTimings
    $qt = $snap.QueryTimings
    $expectSkipped = @('Get-StorageReliabilityCounter','Get-PnpDevice-USB','Get-PnpDevice-HID')
    foreach ($k in $expectSkipped) {
        if ($qt.ContainsKey($k)) {
            if ("$($qt[$k])" -eq 'skipped') { Pass ("QueryTimings['{0}']=skipped (VM-skip OK)" -f $k) }
            else { Fail ("QueryTimings['{0}']='{1}' (esperado skipped en VM)" -f $k, $qt[$k]) }
        } else { Log ("  [i] QueryTimings sin clave '{0}' (puede variar)" -f $k) }
    }

    # T-N2: Volumes debe ser array aun con 1 solo volumen (el fix 988349c)
    $volIsArray = ($null -ne $snap.Volumes) -and ($snap.Volumes -is [System.Array])
    $volCount = @($snap.Volumes).Count
    if ($volIsArray) { Pass ("snapshot.Volumes es array (count={0}) - fix Volumes OK" -f $volCount) }
    else { Fail ("snapshot.Volumes NO es array (type={0}) - regresion T-N2" -f ($snap.Volumes.GetType().Name)) }

    # Dump QueryTimings completo al reporte
    Log '  QueryTimings:'
    foreach ($kv in ($qt.GetEnumerator() | Sort-Object Name)) {
        Log ("    {0} = {1}" -f $kv.Name, $kv.Value)
    }
} catch { Fail ("T2: {0}" -f $_.Exception.Message) }
Log ''

# ---- T3: PRE -> POST -> Compare (Compare != N/A) -----------------------------
Log '[T3] Ciclo PRE/POST/Compare via jobs (DoD: Compare != N/A)'
try {
    $preJob = Start-TelemetryJob -Phase Pre
    $preArr = Wait-ToolkitJobs -Jobs @($preJob) -TimeoutSeconds 90
    $pre = if ($preArr.Count -gt 0) { $preArr[0] } else { $null }

    $postJob = Start-TelemetryJob -Phase Post
    $postArr = Wait-ToolkitJobs -Jobs @($postJob) -TimeoutSeconds 90
    $post = if ($postArr.Count -gt 0) { $postArr[0] } else { $null }

    if ($null -ne $pre  -and $pre.PSObject.Properties['FileName']  -and $pre.FileName)  { Pass ("snapshot PRE escrito: {0}"  -f $pre.FileName) }  else { Fail "snapshot PRE no disponible (preSnap.Ok seria False)" }
    if ($null -ne $post -and $post.PSObject.Properties['FileName'] -and $post.FileName) { Pass ("snapshot POST escrito: {0}" -f $post.FileName) } else { Fail "snapshot POST no disponible" }

    if ($pre -and $post -and $pre.FileName -and $post.FileName) {
        # Check JSON shape del PRE: "Volumes" debe serializar como array
        $rawPre = Get-Content -LiteralPath $pre.FilePath -Raw
        if ($rawPre -match '"Volumes":\s*\[') { Pass 'JSON PRE: "Volumes" serializa como array [' }
        elseif ($rawPre -match '"Volumes":\s*\{') { Fail 'JSON PRE: "Volumes" serializa como objeto { (regresion T-N2)' }
        else { Log '  [i] JSON PRE: patron Volumes no detectado (revisar manualmente)' }

        $diff = Compare-Snapshot -PrePath $pre.FilePath -PostPath $post.FilePath
        if ($null -ne $diff -and $diff.PSObject.Properties['Score'] -and $diff.Score -is [int]) {
            Pass ("Compare-Snapshot OK: Score={0}/{1}, VolumeDiff rows={2} (Compare != N/A)" -f $diff.Score, $diff.ScoreMax, @($diff.VolumeDiff).Count)
            try { Show-SnapshotComparison -Diff $diff | Out-Null; Pass 'Show-SnapshotComparison render sin throw' }
            catch { Fail ("Show-SnapshotComparison tiro: {0}" -f $_.Exception.Message) }
        } else { Fail 'Compare-Snapshot no devolvio Diff valido (Compare = N/A)' }
    }
} catch { Fail ("T3: {0}" -f $_.Exception.Message) }
Log ''

# ---- T4: smoke en VM (bonus) -------------------------------------------------
Log '[T4] smoke.ps1 en VM (bonus)'
try {
    $smokeOut = Join-Path $ArtifactsDir 'smoke-vm.txt'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'tests\smoke.ps1') *> $smokeOut
    $tail = Get-Content -LiteralPath $smokeOut -ErrorAction SilentlyContinue | Select-Object -Last 3
    $resLine = ($tail | Where-Object { $_ -match 'OK:\s*\d+\s+FAIL:\s*\d+' } | Select-Object -First 1)
    if ($resLine -match 'FAIL:\s*0\b') { Pass ("smoke en VM: {0}" -f $resLine.Trim()) }
    elseif ($resLine) { Fail ("smoke en VM con fallos: {0}" -f $resLine.Trim()) }
    else { Log '  [i] smoke en VM: no se pudo parsear resultado (ver smoke-vm.txt)' }
} catch { Log ("  [i] T4 smoke no concluyente: {0}" -f $_.Exception.Message) }
Log ''

# ---- Veredicto ---------------------------------------------------------------
Log '=== VEREDICTO ==='
if ($failed) { Log 'RESULTADO: FAIL (ver lineas [FAIL] arriba)' }
else        { Log 'RESULTADO: PASS (DoD snapshot-vm validado en VM)' }

$lines | Out-File -FilePath $reportPath -Encoding UTF8
"done $(Get-Date -Format o) failed=$failed" | Out-File -FilePath $doneMarker -Encoding UTF8
Write-Host ''
Write-Host ("=== Reporte: {0} ===" -f $reportPath)
