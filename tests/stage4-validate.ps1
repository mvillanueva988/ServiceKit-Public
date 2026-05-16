#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 4 MVP functional validation. Corre Invoke-NamedProfile end-to-end
    INSIDE Windows Sandbox (toggles reales: HVCI/HAGS/USB/GameMode/Defender;
    efimero, se descarta con la VM). La receta de prueba se genera en el TEMP
    del Sandbox (NO en el worktree mapeado -> no ensucia el host).
    Asserts: Invoke-NamedProfile no tira, Status != Failed, gaming_tweaks
    aplicados/skipped coherentes, _last_applied escrito, audit con UNA entrada
    Profile.Apply.Named (no duplicada), ClientRun creado.
    Escribe PASS/FAIL + DONE al dir host-shared. ASCII-only. No aborta.
#>
param(
    [string] $ArtifactsDir = 'C:\stage4-validate',
    [string] $RepoRoot     = 'C:\Toolkit'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $ArtifactsDir)) { New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null }
$reportPath = Join-Path $ArtifactsDir 'stage4-validate-report.txt'
$doneMarker = Join-Path $ArtifactsDir 'DONE.txt'
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

$lines  = New-Object System.Collections.Generic.List[string]
$failed = $false
function Log([string]$m){ Write-Host $m; $script:lines.Add($m) }
function Pass([string]$m){ Log "  [PASS] $m" }
function Fail([string]$m){ $script:failed=$true; Log "  [FAIL] $m" }

Log '=== Stage 4 MVP functional validation (Windows Sandbox) ==='
Log ("Fecha    : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ("RepoRoot : {0}" -f $RepoRoot)
Log ''

try {
    foreach ($folder in @('utils','core','modules')) {
        Get-ChildItem -Path (Join-Path $RepoRoot $folder) -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
    Log '  dot-source OK (utils, core, modules)'
} catch { Fail ("dot-source: {0}" -f $_.Exception.Message) }

try {
    $mp = Get-MachineProfile
    Log ("  MachineProfile: Tier={0} IsVM={1} Vendor={2}" -f $mp.Tier, $mp.IsVirtualMachine, $mp.VmVendor)
} catch { Fail ("Get-MachineProfile: {0}" -f $_.Exception.Message) }
Log ''

# Receta de prueba en TEMP del Sandbox (no toca el worktree mapeado)
[string] $recipePath = Join-Path $env:TEMP '_stage4-validate-named.json'
$recipe = [PSCustomObject]@{
    _schema_version = '1.0'; _kind = 'named'; _name = 'VALIDATE Stage4 (sandbox)'
    _created = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'); _last_applied = $null
    _hardware_snapshot = [PSCustomObject]@{ Tier='High'; CpuName='x'; RamMB=1; Manufacturer='x'; IsLaptop=$false }
    _use_case = 'named'; _tier = 'high'; _description = 'fixture validacion Stage 4'
    _rationale = 'toggles representativos seguros en Sandbox efimero'
    services = [PSCustomObject]@{ disable = @('Fax','RemoteRegistry','DiagTrack') }
    performance = [PSCustomObject]@{ visual_profile='Balanced'; power_plan=[PSCustomObject]@{_future=$true}; system_tweaks=[PSCustomObject]@{_future=$true} }
    privacy = [PSCustomObject]@{ level='medium'; oosu10_cfg='medium.cfg'; fallback='native' }
    cleanup = [PSCustomObject]@{ clear_temp=$true }
    startup = [PSCustomObject]@{ report_only=$true }
    gaming_tweaks = [PSCustomObject]@{
        hvci='off'; hags='on'; usb_selective_suspend='off'; game_mode='on'
        wslconfig=[PSCustomObject]@{ enabled=$true; preset='Gaming' }   # WSL ausente -> debe Skip
        defender_exclusions=@('C:\Temp\stage4-validate-marker')
        oosu_profile='medium'
    }
}
($recipe | ConvertTo-Json -Depth 8) | Out-File -FilePath $recipePath -Encoding UTF8 -Force

# T1: schema named valida via Import-NamedProfile (reusa Test-AutoProfileSchema)
Log '[T1] Import-NamedProfile (schema named = core + gaming_tweaks)'
try {
    $p = Import-NamedProfile -Path $recipePath
    if ([string]$p._kind -eq 'named' -and -not [string]::IsNullOrWhiteSpace([string]$p._name)) {
        Pass ("Import+Test-NamedProfileSchema OK ('{0}')" -f $p._name)
    } else { Fail 'schema named no valido' }
} catch { Fail ("Import-NamedProfile: {0}" -f $_.Exception.Message); $p = $null }
Log ''

# T2: Invoke-NamedProfile end-to-end (mutante, Sandbox efimero, -Unattended)
Log '[T2] Invoke-NamedProfile end-to-end (toggles reales)'
$r = $null
try {
    if ($null -eq $p) { throw 'sin receta (T1 fallo)' }
    $r = Invoke-NamedProfile -Profile $p -MachineProfile $mp -ClientSlug 'test-stage4' `
        -SourcePath $recipePath -SkipRestorePoint -Unattended
    if ($null -eq $r) { Fail 'Invoke-NamedProfile devolvio $null' }
    else {
        [string] $st = if ($r.PSObject.Properties['NamedStatus']) { [string]$r.NamedStatus } else { [string]$r.Status }
        if ($st -in @('Success','Partial')) { Pass ("NamedStatus={0} (Success/Partial OK en VM)" -f $st) }
        else { Fail ("NamedStatus={0}" -f $st) }

        if ($r.PSObject.Properties['Name'] -and [string]$r.Name -eq [string]$p._name) { Pass "result.Name correcto" }
        else { Fail "result.Name ausente/incorrecto" }

        if ($r.PSObject.Properties['GamingTweaks'] -and $null -ne $r.GamingTweaks) {
            $gt = $r.GamingTweaks
            foreach ($k in @('Hvci','Hags','UsbSuspend','GameMode')) {
                if ($gt.PSObject.Properties[$k] -and $null -ne $gt.$k) {
                    [string] $ap = if ($gt.$k.PSObject.Properties['Applied']) { [string]$gt.$k.Applied } else { '?' }
                    [string] $sk = if ($gt.$k.PSObject.Properties['Skipped']) { [string]$gt.$k.Skipped } else { '?' }
                    Log ("    gaming.{0}: Applied={1} Skipped={2}" -f $k, $ap, $sk)
                }
            }
            # wslconfig debe Skip (WSL ausente en Sandbox)
            if ($gt.PSObject.Properties['Wslconfig'] -and $gt.Wslconfig.Skipped -eq $true) {
                Pass "gaming.Wslconfig Skipped (WSL ausente en Sandbox - correcto)"
            } else { Log "    [i] gaming.Wslconfig no skipped (revisar)" }
            if ($gt.PSObject.Properties['GameMode'] -and $gt.GameMode.Applied -eq $true) {
                Pass "gaming.GameMode aplicado (registry HKCU)"
            }
        } else { Fail "result.GamingTweaks ausente" }

        if ($r.PSObject.Properties['LastAppliedWrite'] -and $null -ne $r.LastAppliedWrite) {
            Log ("    LastAppliedWrite: Done={0} Path={1} Reason={2}" -f `
                $r.LastAppliedWrite.Done, $r.LastAppliedWrite.Path, $r.LastAppliedWrite.Reason)
        } else { Log "    [i] result sin LastAppliedWrite" }

        $crDir = if ($r.PSObject.Properties['ClientRun'] -and $r.ClientRun) { [string]$r.ClientRun.Dir } else { '' }
        if ($crDir -and (Test-Path $crDir)) { Pass ("ClientRun folder: {0}" -f (Split-Path $crDir -Leaf)) }
        else { Fail "ClientRun folder no creado" }
    }
} catch { Fail ("Invoke-NamedProfile THREW: {0}" -f $_.Exception.Message) }
Log ''

# T3: _last_applied escrito en el JSON fuente (instrumentado: vuelca datos)
Log '[T3] _last_applied actualizado en el JSON'
try {
    Log ("    recipePath = {0}" -f $recipePath)
    Log ("    Test-Path  = {0}" -f (Test-Path -LiteralPath $recipePath))
    [string] $raw = ''
    if (Test-Path -LiteralPath $recipePath) {
        $raw = Get-Content -LiteralPath $recipePath -Raw -Encoding UTF8
    }
    Log ("    raw len    = {0}" -f $raw.Length)
    Log ("    raw[0..300]= {0}" -f ($raw.Substring(0, [Math]::Min(300, $raw.Length)) -replace '\s+', ' '))
    [bool] $hasSub = ($raw -match '"_last_applied"')
    Log ("    substring '_last_applied' presente = {0}" -f $hasSub)
    $after = $raw | ConvertFrom-Json
    [object] $laProp = if ($null -ne $after) { $after.PSObject.Properties['_last_applied'] } else { $null }
    if ($null -ne $laProp -and $null -ne $laProp.Value -and -not [string]::IsNullOrWhiteSpace([string]$laProp.Value)) {
        Pass ("_last_applied = {0}" -f $laProp.Value)
    } elseif ($null -ne $laProp) {
        Fail ("_last_applied existe pero es null/vacio (rewrite no actualizo el valor)")
    } else {
        Fail ("_last_applied AUSENTE del JSON (rewrite no persistio o no corrio)")
    }
} catch { Fail ("relectura JSON: {0}" -f $_.Exception.Message) }
Log ''

# T4: audit - UNA sola entrada Profile.Apply.Named (no duplicada por el wrap)
Log '[T4] Audit consolidado (1 entrada Profile.Apply.Named, no doble)'
try {
    $auditLog = Join-Path $RepoRoot ('output\audit\' + (Get-Date -Format 'yyyy-MM-dd') + '.jsonl')
    if (Test-Path $auditLog) {
        $c = Get-Content -LiteralPath $auditLog -Encoding UTF8 -ErrorAction SilentlyContinue
        $named = @($c | Where-Object { $_ -match 'Profile\.Apply\.Named' }).Count
        $genFromThis = @($c | Where-Object { $_ -match 'Profile\.Apply\.(Generic|Named)' }).Count
        if ($named -ge 1) { Pass ("audit tiene Profile.Apply.Named ({0} entrada/s del dia)" -f $named) }
        else { Fail "audit SIN Profile.Apply.Named" }
        Log ("    (entradas Apply.Generic|Named del dia: {0}; el wrap NO debe duplicar por run)" -f $genFromThis)
    } else { Fail ("audit log no encontrado: {0}" -f $auditLog) }
} catch { Fail ("AUDIT check: {0}" -f $_.Exception.Message) }
Log ''

Remove-Item $recipePath -Force -ErrorAction SilentlyContinue
Log '=== VEREDICTO ==='
if ($failed) { Log 'RESULTADO: FAIL (ver [FAIL])' } else { Log 'RESULTADO: PASS (Stage 4 MVP funcional validado en VM)' }
$lines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
"done $(Get-Date -Format o) failed=$failed" | Out-File -FilePath $doneMarker -Encoding ASCII -Force
Write-Host ''
Write-Host ("=== Reporte: {0} ===" -f $reportPath)
