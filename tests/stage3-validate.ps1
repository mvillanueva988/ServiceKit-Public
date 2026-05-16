#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 3 functional validation. Runs Invoke-AutoProfile end-to-end for
    Office / Study / Multimedia (-SkipRestorePoint) INSIDE Windows Sandbox.
    Asserts: each use-case runs without throw, Status != Failed, ClientRun
    folder created, and the audit log gets ONE entry per use-case with the
    correct action (Profile.Apply.Office/Study/Multimedia) -> validates the
    Opus fix 3b00fa6 end-to-end in a real mutating run.
    Writes PASS/FAIL report + DONE marker to host-shared artifacts dir.
    ASCII-only (BOM-safe). Never aborts: each use-case isolated.
#>
param(
    [string] $ArtifactsDir = 'C:\stage3-validate',
    [string] $RepoRoot     = 'C:\Toolkit'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ArtifactsDir)) { New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null }
$reportPath = Join-Path $ArtifactsDir 'stage3-validate-report.txt'
$doneMarker = Join-Path $ArtifactsDir 'DONE.txt'
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

$lines  = New-Object System.Collections.Generic.List[string]
$failed = $false
function Log([string]$m){ Write-Host $m; $script:lines.Add($m) }
function Pass([string]$m){ Log "  [PASS] $m" }
function Fail([string]$m){ $script:failed=$true; Log "  [FAIL] $m" }

Log '=== Stage 3 functional validation (Windows Sandbox) ==='
Log ("Fecha    : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ("RepoRoot : {0}" -f $RepoRoot)
Log ''

# dot-source utils -> core -> modules (mismo orden que smoke/stage2-harness)
try {
    foreach ($folder in @('utils','core','modules')) {
        Get-ChildItem -Path (Join-Path $RepoRoot $folder) -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
    Log '  dot-source OK (utils, core, modules)'
} catch { Fail ("dot-source: {0}" -f $_.Exception.Message) }

try {
    $mp = Get-MachineProfile
    $tier = switch ($mp.Tier) { 'Low'{'Low'} 'High'{'High'} default {'Mid'} }
    Log ("  MachineProfile: Tier={0}  IsVM={1}  Vendor={2}" -f $mp.Tier, $mp.IsVirtualMachine, $mp.VmVendor)
} catch { Fail ("Get-MachineProfile: {0}" -f $_.Exception.Message); $tier = 'Mid' }
Log ''

[string[]] $useCases = @('office','study','multimedia')
$statusByUc = @{}

foreach ($uc in $useCases) {
    Log ("[{0}] use-case '{1}'" -f ($useCases.IndexOf($uc)+1), $uc)
    try {
        $path = Get-AutoProfilePath -UseCase $uc -Tier $tier
        if (-not (Test-Path $path)) { Fail ("receta no existe: {0}" -f $path); continue }
        $prof = Import-AutoProfile -Path $path
        if ([string]$prof._use_case -ne $uc) { Fail ("_use_case='{0}' != '{1}'" -f $prof._use_case, $uc); continue }
        Pass ("Import-AutoProfile OK ({0}_{1}.json, schema {2})" -f $uc, $tier.ToLower(), $prof._schema_version)

        $r = Invoke-AutoProfile -Profile $prof -MachineProfile $mp -ClientSlug ("test-$uc") -SkipRestorePoint
        $statusByUc[$uc] = $r.Status

        if ($r.Status -in @('Success','Partial')) { Pass ("Invoke-AutoProfile Status={0}" -f $r.Status) }
        else { Fail ("Invoke-AutoProfile Status={0} (esperado Success/Partial)" -f $r.Status) }

        if ([string]$r.UseCase -eq $uc) { Pass ("result.UseCase='{0}'" -f $r.UseCase) }
        else { Fail ("result.UseCase='{0}' != '{1}'" -f $r.UseCase, $uc) }

        $crDir = if ($r.ClientRun -and $r.ClientRun.PSObject.Properties['Dir']) { [string]$r.ClientRun.Dir } else { '' }
        if ($crDir -and (Test-Path $crDir)) { Pass ("ClientRun folder: {0}" -f (Split-Path $crDir -Leaf)) }
        else { Fail "ClientRun folder no creado" }

        Log ("    Debloat={0} Cleanup={1} Privacy={2} Compare={3}" -f `
            ($(if($r.Debloat){'ok'}else{'null'})), ($(if($r.Cleanup){'ok'}else{'null'})), `
            $r.Privacy.Path, $(if($r.Compare){"$($r.Compare.Score)/$($r.Compare.ScoreMax)"}else{'N/A'}))
    } catch {
        Fail ("use-case '{0}' THREW: {1}" -f $uc, $_.Exception.Message)
    }
    Log ''
}

# Validacion clave del fix 3b00fa6: el audit log debe tener UNA entrada por
# use-case con la action correcta (no 'Profile.Apply.Generic').
Log '[AUDIT] Validacion del fix 3b00fa6 (audit action por use-case)'
try {
    $auditLog = Join-Path $RepoRoot ('output\audit\' + (Get-Date -Format 'yyyy-MM-dd') + '.jsonl')
    if (Test-Path $auditLog) {
        $content = Get-Content -LiteralPath $auditLog -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($uc in $useCases) {
            $expected = 'Profile.Apply.' + $uc.Substring(0,1).ToUpperInvariant() + $uc.Substring(1)
            $hit = @($content | Where-Object { $_ -match [regex]::Escape($expected) }).Count
            if ($hit -ge 1) { Pass ("audit log tiene '{0}' ({1} entrada/s)" -f $expected, $hit) }
            else { Fail ("audit log SIN '{0}' (fix 3b00fa6 no efectivo)" -f $expected) }
        }
        $genericHits = @($content | Where-Object { $_ -match 'Profile\.Apply\.Generic' }).Count
        Log ("    (entradas Profile.Apply.Generic en el log de hoy: {0} - esperado 0 en esta corrida)" -f $genericHits)
    } else { Fail ("audit log no encontrado: {0}" -f $auditLog) }
} catch { Fail ("AUDIT check: {0}" -f $_.Exception.Message) }
Log ''

Log '=== VEREDICTO ==='
Log ("Status por use-case: office={0} study={1} multimedia={2}" -f $statusByUc['office'], $statusByUc['study'], $statusByUc['multimedia'])
if ($failed) { Log 'RESULTADO: FAIL (ver lineas [FAIL])' } else { Log 'RESULTADO: PASS (Stage 3 funcional validado en VM)' }

$lines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
"done $(Get-Date -Format o) failed=$failed" | Out-File -FilePath $doneMarker -Encoding ASCII -Force
Write-Host ''
Write-Host ("=== Reporte: {0} ===" -f $reportPath)
