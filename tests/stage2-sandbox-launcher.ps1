#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (internal - runs as LogonCommand).
# Maps: C:\Toolkit = worktree (writable), C:\stage2-retest = artifacts (writable, host-shared).
# Called via .wsb LogonCommand as WDAGUtilityAccount (admin in sandbox).

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot       = 'C:\Toolkit'
$artifactsDir   = 'C:\stage2-retest'
$harnessPs1     = Join-Path $repoRoot 'tests\stage2-harness.ps1'
$transcriptPath = Join-Path $artifactsDir 'stage2-transcript.txt'
$doneMarker     = Join-Path $artifactsDir 'DONE.txt'

# Ensure artifacts dir exists (mapped from host, but be defensive)
if (-not (Test-Path $artifactsDir)) {
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
}

# Remove stale markers from previous runs
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

Write-Host "=== SANDBOX LAUNCHER: starting transcript ==="
Write-Host "Transcript   : $transcriptPath"
Write-Host "Harness      : $harnessPs1"
Write-Host "ArtifactsDir : $artifactsDir"
Write-Host ""

Start-Transcript -Path $transcriptPath -Force

try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPs1 -ArtifactsDir $artifactsDir
    $exitCode = $LASTEXITCODE
    Write-Host ""
    Write-Host "=== HARNESS EXIT CODE: $exitCode ==="
} catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
} finally {
    Stop-Transcript
}

# Fallback DONE marker in case harness crashed before writing its own
if (-not (Test-Path $doneMarker)) {
    "FALLBACK DONE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') harness-crashed" |
        Out-File -FilePath $doneMarker -Encoding ASCII
    Write-Host "Fallback done marker written: $doneMarker"
}
