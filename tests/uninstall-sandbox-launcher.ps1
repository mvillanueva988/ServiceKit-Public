#Requires -Version 5.1
# ASCII-only launcher for Windows Sandbox auto-run (LogonCommand). No BOM.
# Copies the READ-ONLY mapped source to a sandbox-local install, then invokes
# uninstall-validate.ps1. Guarantees DONE.txt even if validate throws.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$srcRoot      = 'C:\ToolkitSrc'
$repoRoot     = 'C:\PCTk'
$artifactsDir = 'C:\uninstall-validate'
$validatePs1  = Join-Path $repoRoot 'tests\uninstall-validate.ps1'
$transcript   = Join-Path $artifactsDir 'uninstall-transcript.txt'
$doneMarker   = Join-Path $artifactsDir 'DONE.txt'

if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }

Write-Host '=== UNINSTALL SANDBOX LAUNCHER ==='
Start-Transcript -Path $transcript -Force
try {
    # Sandbox-local copy: the read-only mapped source is never the deletion
    # target and is never mutated. robocopy mirrors the tree (excludes .git junk).
    Write-Host "Copying $srcRoot -> $repoRoot ..."
    if (Test-Path $repoRoot) { Remove-Item $repoRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    & robocopy.exe $srcRoot $repoRoot /MIR /NFL /NDL /NJH /NJS /NP /XD '.git' '.claude' | Out-Null
    Write-Host "Copy done (robocopy exit $LASTEXITCODE)"

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validatePs1 `
        -ArtifactsDir $artifactsDir -RepoRoot $repoRoot
    Write-Host ''
    Write-Host "=== VALIDATE EXIT: $LASTEXITCODE ==="
} catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
} finally {
    if (-not (Test-Path $doneMarker)) {
        "done $(Get-Date -Format o) failed=true (launcher-catch - validate did not complete)" |
            Out-File -FilePath $doneMarker -Encoding ASCII -Force
    }
    Stop-Transcript
}
