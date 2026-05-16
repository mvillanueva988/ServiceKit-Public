#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (LogonCommand). No BOM.
# Invokes postqueue-validate.ps1 and guarantees DONE.txt even if validate throws.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot     = 'C:\Toolkit'
$artifactsDir = 'C:\postqueue-validate'
$validatePs1  = Join-Path $repoRoot 'tests\postqueue-validate.ps1'
$transcript   = Join-Path $artifactsDir 'postqueue-transcript.txt'
$doneMarker   = Join-Path $artifactsDir 'DONE.txt'

if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }

Write-Host '=== POSTQUEUE SANDBOX LAUNCHER ==='
Start-Transcript -Path $transcript -Force
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validatePs1 `
        -ArtifactsDir $artifactsDir -RepoRoot $repoRoot
    Write-Host ''
    Write-Host "=== VALIDATE EXIT: $LASTEXITCODE ==="
} catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
} finally {
    # Guarantee DONE.txt even if validate threw or never wrote it
    if (-not (Test-Path $doneMarker)) {
        "done $(Get-Date -Format o) failed=true (launcher-catch - validate did not complete)" |
            Out-File -FilePath $doneMarker -Encoding ASCII -Force
    }
    Stop-Transcript
}
