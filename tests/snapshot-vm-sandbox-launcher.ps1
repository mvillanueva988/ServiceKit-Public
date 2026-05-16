#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (internal - LogonCommand).
# Maps: C:\Toolkit = worktree (writable), C:\snapshot-vm-validate = artifacts
# (writable, host-shared). Runs as WDAGUtilityAccount (admin in sandbox).

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot       = 'C:\Toolkit'
$artifactsDir   = 'C:\snapshot-vm-validate'
$validatePs1    = Join-Path $repoRoot 'tests\snapshot-vm-validate.ps1'
$transcriptPath = Join-Path $artifactsDir 'snapshot-vm-transcript.txt'

if (-not (Test-Path $artifactsDir)) {
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
}

Write-Host "=== SNAPSHOT-VM SANDBOX LAUNCHER ==="
Write-Host "Transcript : $transcriptPath"
Write-Host "Validate   : $validatePs1"
Write-Host ""

Start-Transcript -Path $transcriptPath -Force
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validatePs1 -ArtifactsDir $artifactsDir -RepoRoot $repoRoot
    Write-Host ""
    Write-Host "=== VALIDATE EXIT: $LASTEXITCODE ==="
} catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
} finally {
    Stop-Transcript
}
