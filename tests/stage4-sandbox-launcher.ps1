#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (internal - LogonCommand).
# Maps: C:\Toolkit = worktree (writable), C:\stage4-validate = artifacts.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot     = 'C:\Toolkit'
$artifactsDir = 'C:\stage4-validate'
$validatePs1  = Join-Path $repoRoot 'tests\stage4-validate.ps1'
$transcript   = Join-Path $artifactsDir 'stage4-transcript.txt'

if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }

Write-Host "=== STAGE 4 SANDBOX LAUNCHER ==="
Start-Transcript -Path $transcript -Force
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validatePs1 -ArtifactsDir $artifactsDir -RepoRoot $repoRoot
    Write-Host ""
    Write-Host "=== VALIDATE EXIT: $LASTEXITCODE ==="
} catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
} finally {
    Stop-Transcript
}
