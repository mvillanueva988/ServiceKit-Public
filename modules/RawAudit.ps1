Set-StrictMode -Version Latest

# Captura la ruta del módulo para resolver paths relativos en jobs y para
# saber donde escribir el .txt de salida.
[string] $script:RawAuditModulePath = $PSCommandPath

# ─── New-RawAuditReport ───────────────────────────────────────────────────────
function New-RawAuditReport {
    <#
    .SYNOPSIS
        Toma un snapshot del sistema (via Get-SystemSnapshot) y lo emite como
        un archivo .txt human-readable similar al script audit.ps1 que Mateo
        usa hoy a mano. El .txt sirve para tres flujos:

          1. Auditoria visual rapida del estado de una PC.
          2. Insumo manual para pegar a un LLM con web search (research prompt).
          3. Anexo al ticket de servicio cuando se documenta el trabajo hecho.

        El reporte se escribe en output/audits/audit_<computer>_<timestamp>.txt
        y se devuelve el path al caller. Si se pasa -OpenAfter, ademas se
        abre con notepad para revision inmediata.

    .PARAMETER Snapshot
        Output de Get-SystemSnapshot. Si se omite, se genera uno nuevo
        in-line (toma ~30-60 segundos).

    .PARAMETER OpenAfter
        Si esta presente, abre el .txt con notepad despues de escribir.

    .OUTPUTS
        PSCustomObject con Success / FilePath / FileSize.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCustomObject] $Snapshot = $null,

        [Parameter()]
        [switch] $OpenAfter
    )

    if ($null -eq $Snapshot) {
        $Snapshot = Get-SystemSnapshot -Phase Pre
    }

    [string] $toolkitRoot = Split-Path (Split-Path $script:RawAuditModulePath -Parent) -Parent
    [string] $outputDir   = Join-Path $toolkitRoot 'output\audits'
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }

    [string] $stamp     = (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    [string] $cleanName = ($Snapshot.ComputerName -replace '[^A-Za-z0-9_-]', '_')
    [string] $fileName  = ('audit_{0}_{1}.txt' -f $cleanName, $stamp)
    [string] $filePath  = Join-Path $outputDir $fileName

    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()

    function _Section {
        param([string] $Title)
        $lines.Add('')
        $lines.Add('========================================')
        $lines.Add('  ' + $Title)
        $lines.Add('========================================')
    }

    function _Kv {
        param([string] $Label, [object] $Value)
        if ($null -eq $Value -or "$Value" -eq '') { return }
        $lines.Add(('{0,-22}: {1}' -f $Label, $Value))
    }

    # ── Header ────────────────────────────────────────────────────────────────
    $lines.Add('PCTk Raw Audit Report')
    $lines.Add('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Computer:  ' + $Snapshot.ComputerName)
    $lines.Add('User:      ' + $env:USERNAME)
    $lines.Add('Phase:     ' + $Snapshot.Phase)
    $lines.Add('Uptime:    ' + $Snapshot.UptimeHours + ' hours')

    # ── CPU ───────────────────────────────────────────────────────────────────
    _Section 'CPU'
    _Kv 'Name'    $Snapshot.CPU.Name
    _Kv 'Cores'   $Snapshot.CPU.Cores
    _Kv 'Threads' $Snapshot.CPU.Threads

    # ── RAM ───────────────────────────────────────────────────────────────────
    _Section 'RAM'
    _Kv 'Total GB' $Snapshot.RamTotalGb
    _Kv 'Slots populated' ($Snapshot.RamSlots.Count)
    foreach ($slot in $Snapshot.RamSlots) {
        $lines.Add(('  - {0}  {1} GB @ {2} MHz  ({3})' -f $slot.Slot, $slot.CapacityGb, $slot.SpeedMhz, $slot.Manufacturer))
    }

    # ── GPU ───────────────────────────────────────────────────────────────────
    _Section 'GPU'
    foreach ($g in $Snapshot.GPU) {
        $lines.Add(('  - {0}  [{1}]  driver {2}' -f $g.Name, $g.Type, $g.DriverVersion))
    }

    # ── Storage ──────────────────────────────────────────────────────────────
    _Section 'STORAGE'
    foreach ($d in $Snapshot.Disks) {
        [string] $health = if ($null -ne $d.HealthStatus) { $d.HealthStatus } else { '?' }
        [string] $temp   = if ($null -ne $d.TempC -and $d.TempC -gt 0) { $d.TempC.ToString() + 'C' } else { '-' }
        [string] $wear   = if ($null -ne $d.WearPct) { $d.WearPct.ToString() + '%' } else { '-' }
        $lines.Add(('  - {0}  {1} GB  [{2}]  health={3}  temp={4}  wear={5}' -f $d.Name, $d.SizeGb, $d.MediaType, $health, $temp, $wear))
    }
    $lines.Add('')
    foreach ($v in $Snapshot.Volumes) {
        $lines.Add(('  {0}:  {1} GB free of {2} GB  ({3}% used)  [{4}]' -f $v.Letter, $v.FreeGb, $v.SizeGb, $v.UsedPct, $v.Label))
    }

    # ── Power plan + page file ────────────────────────────────────────────────
    _Section 'POWER & PAGEFILE'
    if ($null -ne $Snapshot.PowerPlan) {
        _Kv 'Active plan' ($Snapshot.PowerPlan.ActiveName)
        _Kv 'Plan GUID'   ($Snapshot.PowerPlan.ActiveGuid)
    }
    if ($null -ne $Snapshot.PageFile) {
        _Kv 'PageFile current MB' $Snapshot.PageFile.CurrentUsageMb
        _Kv 'PageFile peak MB'    $Snapshot.PageFile.PeakUsageMb
    }

    # ── Security: VBS / HVCI / Defender ──────────────────────────────────────
    _Section 'SECURITY (VBS / HVCI / AV)'
    if ($null -ne $Snapshot.DeviceGuard) {
        _Kv 'VBS configured'        $Snapshot.DeviceGuard.VbsConfigured
        _Kv 'VBS running'           $Snapshot.DeviceGuard.VbsRunning
        _Kv 'HVCI running'          $Snapshot.DeviceGuard.HvciRunning
        _Kv 'Credential Guard'      $Snapshot.DeviceGuard.CredentialGuardRunning
    }
    foreach ($av in $Snapshot.Antivirus) {
        [string] $tag = if ($av.IsNative) { '[native]' } else { '[3rd-party]' }
        [string] $mode = if (-not [string]::IsNullOrEmpty($av.AMRunningMode)) { '  mode=' + $av.AMRunningMode } else { '' }
        $lines.Add(('  - {0,-30} {1}  enabled={2} active={3}{4}' -f $av.Name, $tag, $av.Enabled, $av.IsActive, $mode))
    }
    _Kv 'Multiple active AV problem' $Snapshot.MultipleAvProblem

    # ── Services + Startup ────────────────────────────────────────────────────
    _Section 'SERVICES & STARTUP'
    _Kv 'Running services' $Snapshot.Services.RunningCount
    if ($Snapshot.Services.BloatRunning.Count -gt 0) {
        $lines.Add('  Bloat running: ' + ($Snapshot.Services.BloatRunning -join ', '))
    }
    _Kv 'Startup entries (registry+folders)' $Snapshot.StartupCount

    # ── Thermal ───────────────────────────────────────────────────────────────
    _Section 'THERMAL'
    _Kv 'CPU temperature C' $Snapshot.CpuTempC
    foreach ($z in $Snapshot.ThermalZones) {
        $lines.Add(('  - {0}  {1} C' -f $z.Zone, $z.TempC))
    }

    # ── Battery (laptops) ─────────────────────────────────────────────────────
    if ($null -ne $Snapshot.Battery) {
        _Section 'BATTERY'
        _Kv 'Charge %' $Snapshot.Battery.ChargePercent
        _Kv 'Health %' $Snapshot.Battery.HealthPercent
        _Kv 'Status'   $Snapshot.Battery.Status
    }

    # ── Network: adapters + DNS ──────────────────────────────────────────────
    _Section 'NETWORK'
    foreach ($key in $Snapshot.DnsServers.Keys) {
        $lines.Add(('  {0,-20} DNS: {1}' -f $key, ($Snapshot.DnsServers[$key] -join ', ')))
    }

    # ── USB / HID ─────────────────────────────────────────────────────────────
    _Section 'USB DEVICES'
    foreach ($u in $Snapshot.UsbDevices) {
        $lines.Add('  - ' + $u.FriendlyName)
    }
    _Section 'HID DEVICES'
    foreach ($h in $Snapshot.HidDevices) {
        $lines.Add(('  - {0}  ({1})' -f $h.FriendlyName, $h.Manufacturer))
    }

    # ── Top processes ─────────────────────────────────────────────────────────
    _Section 'TOP 5 PROCESSES BY WORKING SET'
    foreach ($p in $Snapshot.TopProcesses) {
        $lines.Add(('  - {0,-30} {1} MB' -f $p.Name, $p.WorkingSetMb))
    }

    # ── Installed programs (filtered) ─────────────────────────────────────────
    _Section 'INSTALLED PROGRAMS (FILTERED)'
    foreach ($prog in $Snapshot.InstalledPrograms) {
        [string] $ver = if ([string]::IsNullOrEmpty($prog.Version)) { '' } else { '  ' + $prog.Version }
        $lines.Add(('  - {0}{1}' -f $prog.Name, $ver))
    }

    # ── Steam / CS2 ──────────────────────────────────────────────────────────
    if ($null -ne $Snapshot.Steam -and $Snapshot.Steam.Installed) {
        _Section 'STEAM / CS2'
        _Kv 'Steam path'      $Snapshot.Steam.Path
        _Kv 'CS2 installed'   $Snapshot.Steam.Cs2Installed
        if ($Snapshot.Steam.Cs2Installed) {
            _Kv 'CS2 path'         $Snapshot.Steam.Cs2Path
            _Kv 'CS2 launch opts'  $Snapshot.Steam.Cs2LaunchOptions
            if ($Snapshot.Steam.AutoexecLines.Count -gt 0) {
                $lines.Add('')
                $lines.Add('  autoexec.cfg content:')
                foreach ($l in $Snapshot.Steam.AutoexecLines) {
                    $lines.Add('    ' + $l)
                }
            }
        }
    }

    # ── Footer ────────────────────────────────────────────────────────────────
    $lines.Add('')
    $lines.Add('--- end of report ---')

    # Write to disk (UTF-8 with BOM for notepad compatibility con caracteres acentuados)
    [string] $content = [string] ($lines -join "`r`n")
    [System.IO.File]::WriteAllText($filePath, $content, [System.Text.UTF8Encoding]::new($true))

    [long] $size = (Get-Item -LiteralPath $filePath).Length

    if ($OpenAfter) {
        try { Start-Process notepad.exe $filePath } catch { }
    }

    return [PSCustomObject]@{
        Success  = $true
        FilePath = $filePath
        FileName = $fileName
        FileSize = $size
    }
}
