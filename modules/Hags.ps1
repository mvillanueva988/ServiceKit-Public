Set-StrictMode -Version Latest

# HAGS — Hardware-Accelerated GPU Scheduling.
# Registry: HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode
#   1 = Off (disabled)
#   2 = On  (enabled)
# Toma efecto al reboot.
#
# Trade-off documentado (Doc 2 §2.8, Doc 4 §3.2):
#   - HAGS reserva ~700 MB a 1 GB de VRAM para sus buffers de scheduling.
#   - En GPUs ajustadas (≤4-6 GB VRAM, ej. RTX 3050 Ti laptop), perder 25%
#     del buffer dispara antes el Sysmem Fallback al RAM del sistema.
#   - DLSS Frame Generation 3 (RTX 40+) requiere HAGS encendido.
#   - En GPUs <8GB sin FG: recomendación es HAGS Off.
#   - En GPUs ≥12GB o que usan FG: HAGS On.

$script:HagsRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$script:HagsValName = 'HwSchMode'

# ─── Get-HagsStatus ───────────────────────────────────────────────────────────
function Get-HagsStatus {
    <#
    .SYNOPSIS
        Lee el estado actual de Hardware-Accelerated GPU Scheduling.
        Read-only. Smoke-safe.

    .OUTPUTS
        PSCustomObject con:
          - Mode           : 'Off' | 'On' | 'Default' | 'Unknown'
          - RawValue       : valor crudo de HwSchMode ($null si no existe)
          - RestartPending : si el valor en registry no coincide con el
                             estado en runtime (cambio aplicado sin reboot)
    #>
    [CmdletBinding()]
    param()

    [Nullable[int]] $raw = $null
    try {
        $reg = Get-ItemProperty -Path $script:HagsRegPath -ErrorAction SilentlyContinue
        if ($null -ne $reg -and $null -ne $reg.PSObject.Properties[$script:HagsValName]) {
            $raw = [int] $reg.$($script:HagsValName)
        }
    }
    catch { }

    [string] $mode = switch ($raw) {
        $null { 'Default' }
        1     { 'Off' }
        2     { 'On' }
        default { 'Unknown' }
    }

    return [PSCustomObject]@{
        Mode           = $mode
        RawValue       = $raw
        RegistryPath   = $script:HagsRegPath
        RestartPending = $false  # Sin API confiable para detectar pending — placeholder
    }
}

# ─── Disable-Hags ─────────────────────────────────────────────────────────────
function Disable-Hags {
    <#
    .SYNOPSIS
        Deshabilita HAGS (HwSchMode = 1). Reboot requerido.
        Recomendado para GPUs <8 GB VRAM que no usan DLSS Frame Generation.
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $script:HagsRegPath)) {
            New-Item -Path $script:HagsRegPath -Force | Out-Null
        }
        Set-ItemProperty -Path $script:HagsRegPath -Name $script:HagsValName -Value 1 -Type DWord -ErrorAction Stop
        $applied.Add('HwSchMode=1 (HAGS Off)')
    }
    catch { $errors.Add("HAGS registry: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $true
        Reason          = 'HAGS deshabilitado. Libera ~1GB de VRAM en GPUs ajustadas. No afecta DLSS Frame Generation si la GPU es Ampere o anterior.'
    }
}

# ─── Enable-Hags ──────────────────────────────────────────────────────────────
function Enable-Hags {
    <#
    .SYNOPSIS
        Habilita HAGS (HwSchMode = 2). Reboot requerido.
        Recomendado para GPUs ≥12 GB VRAM o que usan DLSS Frame Generation (RTX 40+).
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $script:HagsRegPath)) {
            New-Item -Path $script:HagsRegPath -Force | Out-Null
        }
        Set-ItemProperty -Path $script:HagsRegPath -Name $script:HagsValName -Value 2 -Type DWord -ErrorAction Stop
        $applied.Add('HwSchMode=2 (HAGS On)')
    }
    catch { $errors.Add("HAGS registry: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $true
        Reason          = 'HAGS habilitado. Requerido para DLSS Frame Generation (RTX 40+); puede causar micro-stutter en GPUs <8GB.'
    }
}
