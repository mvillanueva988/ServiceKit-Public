Set-StrictMode -Version Latest

# NvidiaTweaks -- NVIDIA Sysmem Fallback Policy via nvidiaProfileInspector.
# Gate duro: sin GPU NVIDIA dedicada O sin inspector en tools\bin -> skip limpio.
# NO proceso residente (cost-zero).
# Validacion funcional PENDIENTE de PC NVIDIA real (D-S42b stage4.2-plan.md).
#
# Apply path invoca nvidiaProfileInspector.exe con un perfil NIP temporal.
# Setting ID 0x00A06871 (Sysmem Fallback Policy): VERIFICAR en PC NVIDIA real.
# El gate garantiza que el apply path no corre sin inspector instalado + GPU NVIDIA.

[string] $script:NvInspBin = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\bin') 'nvidiaProfileInspector'

# ─── Test-NvidiaInspectorAvailable ───────────────────────────────────────────
function Test-NvidiaInspectorAvailable {
    <#
    .SYNOPSIS
        Devuelve $true si nvidiaProfileInspector.exe esta en tools\bin.
        No descarga ni ejecuta. Smoke-safe.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [string] $exePath = Join-Path $script:NvInspBin 'nvidiaProfileInspector.exe'
    return (Test-Path -LiteralPath $exePath)
}

# ─── Get-NvidiaSysmemStatus ──────────────────────────────────────────────────
function Get-NvidiaSysmemStatus {
    <#
    .SYNOPSIS
        Lee estado de GPU NVIDIA via deteccion existente (Get-MachineProfile).
        Read-only. Smoke-safe: nunca lanza.
    .OUTPUTS
        PSCustomObject:
          IsNvidiaDedicated : $true si hay GPU NVIDIA dedicada (RTX/GTX/GeForce)
          Enabled           : $null (estado exacto requiere nvidiaProfileInspector)
          Reason            : descripcion del estado detectado
    #>
    [CmdletBinding()]
    param()

    [bool]   $isNvidiaDedicated = $false
    [object] $enabled           = $null
    [string] $reason            = ''

    try {
        [PSCustomObject] $mp = Get-MachineProfile
        [string[]] $gpuNames = @()
        if ($null -ne $mp -and
            $null -ne $mp.PSObject.Properties['GpuNames'] -and
            $null -ne $mp.GpuNames) {
            $gpuNames = @($mp.GpuNames)
        }
        $isNvidiaDedicated = @(
            $gpuNames | Where-Object { $_ -match 'NVIDIA|GeForce|RTX|GTX' }
        ).Count -gt 0

        if ($isNvidiaDedicated) {
            $reason = 'GPU NVIDIA dedicada detectada. Estado exacto de SysmemFallback requiere nvidiaProfileInspector.'
        } else {
            $reason = 'No se detecto GPU NVIDIA dedicada. El toggle NvidiaSysmemFallback no aplica.'
        }
    } catch {
        $reason = "Error al leer perfil de maquina: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        IsNvidiaDedicated = $isNvidiaDedicated
        Enabled           = $enabled
        Reason            = $reason
    }
}

# ─── Set-NvidiaSysmemFallback ─────────────────────────────────────────────────
function Set-NvidiaSysmemFallback {
    <#
    .SYNOPSIS
        Aplica Sysmem Fallback Policy via nvidiaProfileInspector.
        Gate duro: sin GPU NVIDIA dedicada O sin inspector -> skip limpio.
        Cost-zero: sin proceso residente.
    .PARAMETER State
        'prefer_no' -> Sysmem Fallback Policy = no preferido (0x00000001)
        'default'   -> Sysmem Fallback Policy = defecto (0x00000000)
    .NOTES
        VALIDACION PENDIENTE de PC NVIDIA real (D-S42b).
        Setting ID 0x00A06871 debe verificarse con nvidiaProfileInspector en PC real.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('prefer_no','default')]
        [string] $State
    )

    # Gate 1: GPU NVIDIA dedicada
    [PSCustomObject] $status = Get-NvidiaSysmemStatus
    if (-not $status.IsNvidiaDedicated) {
        return [PSCustomObject]@{
            Success         = $true
            Skipped         = $true
            Applied         = @()
            Errors          = @()
            RestartRequired = $false
            Reason          = 'No se detecto GPU NVIDIA dedicada. Skip limpio.'
        }
    }

    # Gate 2: inspector disponible en tools\bin
    if (-not (Test-NvidiaInspectorAvailable)) {
        return [PSCustomObject]@{
            Success         = $true
            Skipped         = $true
            Applied         = @()
            Errors          = @()
            RestartRequired = $false
            Reason          = 'nvidiaProfileInspector no disponible en tools\bin. Ejecutar Bootstrap-Tools primero. Skip limpio.'
        }
    }

    [System.Collections.Generic.List[string]] $applied =
        [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  =
        [System.Collections.Generic.List[string]]::new()

    # Sysmem Fallback Policy values (ID 0x00A06871 -- verificar en PC real):
    #   prefer_no -> 0x00000001  (preferir no usar memoria de sistema)
    #   default   -> 0x00000000  (comportamiento por defecto del driver)
    [string] $nipPath = ''
    try {
        [string] $inspPath = Join-Path $script:NvInspBin 'nvidiaProfileInspector.exe'
        [string] $nipVal   = if ($State -eq 'prefer_no') { '0x00000001' } else { '0x00000000' }
        [string] $nipXml   = ('<?xml version="1.0" encoding="utf-16"?>' +
            '<NvidiaInspectorProfile version="2.0.0.1">' +
            '<Profile name="Base Profile" ProfileType="1">' +
            '<Setting name="Sysmem Fallback Policy" id="0x00A06871" value="{0}" />' +
            '</Profile></NvidiaInspectorProfile>') -f $nipVal

        $nipPath = [System.IO.Path]::ChangeExtension(
            [System.IO.Path]::GetTempFileName(), '.nip')
        [System.IO.File]::WriteAllText(
            $nipPath, $nipXml, [System.Text.Encoding]::Unicode)

        [object] $proc = Start-Process `
            -FilePath     $inspPath `
            -ArgumentList $nipPath  `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        [int] $exitCode = [int]$proc.ExitCode

        if ($exitCode -ne 0) {
            $errors.Add(("nvidiaProfileInspector exited with code {0}" -f $exitCode))
        } else {
            $applied.Add(("NvidiaSysmemFallback={0} (id=0x00A06871, val={1})" -f $State, $nipVal))
        }
    } catch {
        $errors.Add("Set-NvidiaSysmemFallback: $($_.Exception.Message)")
    } finally {
        if ($nipPath.Length -gt 0 -and (Test-Path -LiteralPath $nipPath)) {
            Remove-Item -LiteralPath $nipPath -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Skipped         = $false
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = if ($errors.Count -eq 0) {
            ("NvidiaSysmemFallback={0} aplicado via nvidiaProfileInspector." +
             " Sin reinicio requerido. Efecto en proxima sesion de juego.") -f $State
        } else { 'Error al aplicar NvidiaSysmemFallback.' }
    }
}
