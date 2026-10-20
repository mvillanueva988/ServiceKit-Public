#Requires -Version 5.1
<#
.SYNOPSIS
    Gate HW de #54 (A)+(B)+(C), UN comando. Corre en la notebook de Mateo (Defender real), elevado.
.DESCRIPTION
    Parte A: tests\defender-diag-hw.ps1 -Elevated (el gate pendiente del diagnostico).
    Parte B+C: carpeta propia en el PERFIL (no en TEMP: TEMP no se ofrece), un job que escribe y lee
    ~1500 archivos chicos ahi mientras se graba, y el HANDLER real de [A][19] [G] con Read-Host
    shadowed (G, 30, Enter, el numero de la fila de esa carpeta, S). Guarda la salida -Raw real de
    Get-MpPerformanceReport en JSON. Siempre limpia: saca la exclusion, para el job, borra su carpeta.
    Escribe PASS/FAIL por parte a output\defender\hw-gate_<sello>.txt y una copia fija
    output\defender\hw-gate-ultimo.txt. Exit 0 solo si las dos partes pasan.
    Si no esta elevado se relanza con un UAC (-Verb RunAs); -NoElevate no se relanza (corrida en seco:
    da FAIL de precondicion escrito a archivo, sin tocar Defender).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Mateo\Documents\Dev\Toolkit\tests\defender-hw-gate.ps1
#>
[CmdletBinding()]
param([switch] $NoElevate)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # espejo de main.ps1

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
foreach ($folder in @('utils', 'core', 'modules')) {
    Get-ChildItem -Path (Join-Path $repoRoot $folder) -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
}

[string] $outDir = Join-Path $repoRoot 'output\defender'
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
[string] $stamp = Get-PctkStamp -Seconds
[string] $gatePath = Join-Path $outDir ('hw-gate_{0}.txt' -f $stamp)
[string] $lastPath = Join-Path $outDir 'hw-gate-ultimo.txt'

# Identidad del artefacto gateado: el commit del repo que se esta probando.
[string] $head = 'desconocido'
try {
    $ErrorActionPreference = 'Continue'
    [string] $h = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $h -ne '') { $head = $h }
} catch { $head = 'desconocido' }
$ErrorActionPreference = 'Stop'

[string] $partA = 'NO CORRIO'
[string] $partB = 'NO CORRIO'
[System.Collections.Generic.List[string]] $log = [System.Collections.Generic.List[string]]::new()
[System.Collections.Generic.List[string]] $fails = [System.Collections.Generic.List[string]]::new()

function Save-Gate {
    param([string] $Verdict)
    [string[]] $all = @(
        ('{0}: defender-hw-gate' -f $Verdict),
        ('commit: {0}' -f $head),
        ('parte A (defender-diag-hw -Elevated): {0}' -f $partA),
        ('parte B+C (handler [A][19] [G]): {0}' -f $partB)
    ) + @($fails | ForEach-Object { 'FAIL: ' + $_ }) + @('') + @($log)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($gatePath, $all, $enc)
    [System.IO.File]::WriteAllLines($lastPath, $all, $enc)
    Write-Host ('  {0}  -> {1}' -f $Verdict, $gatePath)
}

# --- Elevacion --------------------------------------------------------------------
[bool] $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    Write-Host '  No elevado: relanzando con UAC...'
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-NoElevate')
    if (Test-Path -LiteralPath $lastPath) { Get-Content -LiteralPath $lastPath | Select-Object -First 6 | ForEach-Object { Write-Host ('  ' + $_) } }
    exit $p.ExitCode
}

# --- Precondiciones -----------------------------------------------------------------
if (-not $isAdmin) { $fails.Add('precondicion: la sesion NO esta elevada (el gate graba y excluye: pide admin)') }
$def = Get-DefenderDiagStatus
if (-not $def.Available) { $fails.Add(('precondicion: Defender no disponible: {0}' -f $def.Reason)) }
foreach ($c in @('New-MpPerformanceRecording', 'Get-MpPerformanceReport')) {
    if (-not (Get-Command -Name $c -ErrorAction SilentlyContinue)) { $fails.Add(('precondicion: falta el cmdlet {0}' -f $c)) }
}
if ($fails.Count -gt 0) {
    $partA = 'FAIL (precondicion)'; $partB = 'FAIL (precondicion)'
    Save-Gate 'FAIL'; exit 1
}

# --- Parte A -------------------------------------------------------------------------
try {
    $ErrorActionPreference = 'Continue'   # exe nativo: stderr no debe ser terminante
    [string] $aOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'defender-diag-hw.ps1') -Elevated 2>&1 | Out-String)
    [int] $aCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $log.Add('--- parte A: salida'); $log.Add($aOut)
    [object[]] $aFile = @(Get-ChildItem -LiteralPath $outDir -Filter 'hw-check_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($aFile.Count -gt 0) { $log.Add('--- archivo de A: ' + $aFile[0].FullName) }
    if ($aCode -eq 0) { $partA = 'PASS' } else { $partA = ('FAIL (exit {0})' -f $aCode); $fails.Add('parte A: defender-diag-hw salio con exit ' + $aCode) }
} catch {
    $ErrorActionPreference = 'Stop'
    $partA = 'FAIL (tiro)'; $fails.Add('parte A tiro: ' + $_.Exception.Message)
}

# --- Parte B+C -----------------------------------------------------------------------
[string] $gateDir = Join-Path $env:USERPROFILE ('pctk-defgate-{0}' -f $stamp)
$script:GateDir = $gateDir
$script:GateOut = $outDir
$script:GateStamp = $stamp
$script:RawReport = $null
$script:RealReport = Get-Command -Name 'Get-MpPerformanceReport' -CommandType Cmdlet -ErrorAction Stop
$job = $null
[datetime] $t0 = Get-Date
[bool] $excluded = $false
try {
    $null = New-Item -ItemType Directory -Path $gateDir -ErrorAction Stop
    # El job escribe y lee ~1500 archivos chicos ahi en bucle mientras se graba.
    $job = Start-Job -ArgumentList $gateDir -ScriptBlock {
        param($dir)
        $end = (Get-Date).AddSeconds(75)
        $body = 'pctk defender gate ' + ('lorem ipsum dolor sit amet ' * 8)
        while ((Get-Date) -lt $end) {
            for ($i = 1; $i -le 1500; $i++) { [System.IO.File]::WriteAllText((Join-Path $dir ('g{0:D5}.txt' -f $i)), ($body + $i)) }
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) { $null = [System.IO.File]::ReadAllText($f) }
        }
    }
    Start-Sleep -Seconds 3

    # Shadows del gate: Read-Host por prompt, y el reporte real se guarda tal cual.
    function Read-Host {
        param([object] $Prompt)
        [string] $pr = [string]$Prompt
        if ($pr -match 'Opcion') { return 'G' }
        if ($pr -match 'Segundos') { return '30' }
        if ($pr -match 'empezar') { return '' }
        if ($pr -match 'Numeros a excluir') {
            [object[]] $f = @(Get-ChildItem -LiteralPath $script:GateOut -Filter 'rutas_*.txt' -File | Sort-Object LastWriteTime -Descending)
            if ($f.Count -eq 0) { return '' }
            foreach ($l in [System.IO.File]::ReadAllLines($f[0].FullName)) {
                if ($l -match '^\[(\d+)\]\s' -and $l.IndexOf('pctk-defgate-' + $script:GateStamp, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $l -notmatch 'NO se ofrece') { return $Matches[1] }
            }
            return ''
        }
        if ($pr -match 'Confirmar') { return 'S' }
        return ''
    }
    function Get-MpPerformanceReport {
        $r = & $script:RealReport @args
        $script:RawReport = $r
        return $r
    }

    [string] $screen = (Invoke-ActionDefenderScan -MachineProfile ([PSCustomObject]@{}) *>&1 | Out-String)
    $log.Add('--- parte B+C: pantalla del handler'); $log.Add($screen)

    if ($null -ne $script:RawReport) {
        [string] $rawPath = Join-Path $outDir ('hw-gate-raw_{0}.json' -f $stamp)
        [System.IO.File]::WriteAllText($rawPath, ($script:RawReport | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        $log.Add('--- salida -Raw real guardada en ' + $rawPath)
    } else { $fails.Add('B+C: Get-MpPerformanceReport no fue llamado (no hubo grabacion)') }

    # Verificaciones.
    [object[]] $rutas = @(Get-ChildItem -LiteralPath $outDir -Filter 'rutas_*.txt' -File | Sort-Object LastWriteTime -Descending)
    if ($rutas.Count -eq 0) {
        $fails.Add('B+C: no quedo rutas_*.txt')
    } else {
        [string[]] $rl = [System.IO.File]::ReadAllLines($rutas[0].FullName)
        [string[]] $mine = @($rl | Where-Object { $_.IndexOf('pctk-defgate-' + $stamp, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($mine.Count -eq 0) { $fails.Add('B+C: la carpeta del gate no aparece como fila en rutas_*.txt') }
        elseif ($mine[0] -match 'NO se ofrece') { $fails.Add('B+C: la fila de la carpeta del gate figura como NO ofrecible') }
        $log.Add('--- rutas_*.txt: filas no ofrecibles (informativo)')
        foreach ($l in @($rl | Where-Object { $_ -match 'NO se ofrece' })) { $log.Add('  ' + $l) }
    }
    $pref = Get-MpPreference
    [string[]] $exNow = @($pref.ExclusionPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $excluded = @($exNow | Where-Object { $_.TrimEnd('\') -ieq $gateDir }).Count -gt 0
    if (-not $excluded) { $fails.Add('B+C: la exclusion NO aparece en Get-MpPreference') }
    [string] $auditFile = Join-Path $repoRoot ('output\audit\{0}.jsonl' -f (Get-Date).ToString('yyyy-MM-dd'))
    [bool] $auditOk = $false
    if (Test-Path -LiteralPath $auditFile) {
        [string] $esc = $gateDir.Replace('\', '\\')
        foreach ($l in [System.IO.File]::ReadAllLines($auditFile)) {
            if ($l.Contains('Defender.Exclusions.Measured') -and $l.Contains($esc)) { $auditOk = $true }
        }
    }
    if (-not $auditOk) { $fails.Add('B+C: el audit Defender.Exclusions.Measured no nombra la carpeta del gate') }
    [object[]] $left = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'pctk-defrec-*' -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $t0 })
    if ($left.Count -gt 0) { $fails.Add('B+C: quedo una carpeta pctk-defrec-* de esta corrida en TEMP') }
} catch {
    $fails.Add('parte B+C tiro: ' + $_.Exception.Message)
    $log.Add('--- excepcion: ' + $_.Exception.ToString())
} finally {
    # Siempre: sacar la exclusion, parar el job, borrar SOLO la carpeta propia (ruta guardada).
    try { Remove-MpPreference -ExclusionPath $gateDir -ErrorAction Stop } catch { $log.Add('(Remove-MpPreference: ' + $_.Exception.Message + ')') }
    try {
        [string[]] $after = @((Get-MpPreference).ExclusionPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (@($after | Where-Object { $_.TrimEnd('\') -ieq $gateDir }).Count -gt 0) { $fails.Add('B+C: la exclusion del gate NO se pudo sacar (sacala a mano: Remove-MpPreference -ExclusionPath ''' + $gateDir + ''')') }
    } catch { $fails.Add('B+C: no se pudo verificar la limpieza de la exclusion: ' + $_.Exception.Message) }
    if ($null -ne $job) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $gateDir) { Remove-Item -LiteralPath $gateDir -Recurse -Force -ErrorAction SilentlyContinue }
}
$partB = if (@($fails | Where-Object { $_ -like 'B+C*' -or $_ -like 'parte B+C*' }).Count -eq 0) { 'PASS' } else { 'FAIL' }

if ($partA -eq 'PASS' -and $partB -eq 'PASS') { Save-Gate 'PASS'; exit 0 }
Save-Gate 'FAIL'
exit 1
