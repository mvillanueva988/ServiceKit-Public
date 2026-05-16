#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (internal - LogonCommand).
# Maps: C:\Toolkit = worktree (writable), C:\stage3-validate = artifacts
# (writable, host-shared). Runs as WDAGUtilityAccount (admin in sandbox).

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot       = 'C:\Toolkit'
$artifactsDir   = 'C:\stage3-validate'
$validatePs1    = Join-Path $repoRoot 'tests\stage3-validate.ps1'
$transcriptPath = Join-Path $artifactsDir 'stage3-transcript.txt'

if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }

Write-Host "=== STAGE 3 SANDBOX LAUNCHER ==="
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
