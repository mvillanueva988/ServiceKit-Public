Set-StrictMode -Version Latest

# ─── Get-CoreIsolationStatus ──────────────────────────────────────────────────
function Get-CoreIsolationStatus {
    <#
    .SYNOPSIS
        Lee el estado de Virtualization-Based Security (VBS) y Hypervisor-
        Protected Code Integrity (HVCI / Memory Integrity), tanto la
        configuración en registry como el estado en tiempo de ejecución que
        reporta Win32_DeviceGuard.

        Read-only. Smoke-safe.

    .OUTPUTS
        PSCustomObject con:
          - VbsConfigured / VbsRunning      : si VBS está habilitado/corriendo
          - HvciConfigured / HvciRunning    : idem para HVCI
          - HypervisorPresent               : Hyper-V virtualization activo
          - WslHyperVRequirement            : si VBS/Hyper-V son necesarios
                                              para WSL2 en esta máquina
          - SecurityServicesConfigured/Running: arrays raw del WMI
    #>
    [CmdletBinding()]
    param()

    [bool] $vbsConfigured  = $false
    [bool] $vbsRunning     = $false
    [bool] $hvciConfigured = $false
    [bool] $hvciRunning    = $false
    [bool] $hypervisorPresent = $false
    [int[]] $svcConfigured = @()
    [int[]] $svcRunning    = @()

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                              -ClassName Win32_DeviceGuard `
                              -ErrorAction Stop
        if ($null -ne $dg) {
            # VirtualizationBasedSecurityStatus: 0=Off, 1=Configured(no running), 2=Running
            if ($null -ne $dg.PSObject.Properties['VirtualizationBasedSecurityStatus']) {
                [int] $vbsStatus = [int] $dg.VirtualizationBasedSecurityStatus
                $vbsConfigured = ($vbsStatus -ge 1)
                $vbsRunning    = ($vbsStatus -eq 2)
            }
            if ($null -ne $dg.PSObject.Properties['SecurityServicesConfigured']) {
                $svcConfigured = @($dg.SecurityServicesConfigured | ForEach-Object { [int] $_ })
            }
            if ($null -ne $dg.PSObject.Properties['SecurityServicesRunning']) {
                $svcRunning = @($dg.SecurityServicesRunning | ForEach-Object { [int] $_ })
            }
            # SecurityService ID 2 = HVCI (Memory Integrity)
            $hvciConfigured = ($svcConfigured -contains 2)
            $hvciRunning    = ($svcRunning -contains 2)
        }
    }
    catch { }

    # Hypervisor presence: useful to know if WSL2/Hyper-V is even installable.
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($null -ne $cs -and $null -ne $cs.PSObject.Properties['HypervisorPresent']) {
            $hypervisorPresent = [bool] $cs.HypervisorPresent
        }
    }
    catch { }

    # Registry values (lo que está PEDIDO, no necesariamente lo que está running)
    [string] $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    [string] $dgPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    [object] $hvciEnabledReg = $null
    [object] $vbsEnabledReg  = $null
    try {
        $hvciReg = Get-ItemProperty -Path $hvciPath -ErrorAction SilentlyContinue
        if ($null -ne $hvciReg -and $null -ne $hvciReg.PSObject.Properties['Enabled']) {
            $hvciEnabledReg = [int] $hvciReg.Enabled
        }
        $dgReg = Get-ItemProperty -Path $dgPath -ErrorAction SilentlyContinue
        if ($null -ne $dgReg -and $null -ne $dgReg.PSObject.Properties['EnableVirtualizationBasedSecurity']) {
            $vbsEnabledReg = [int] $dgReg.EnableVirtualizationBasedSecurity
        }
    }
    catch { }

    return [PSCustomObject]@{
        VbsConfigured                = $vbsConfigured
        VbsRunning                   = $vbsRunning
        HvciConfigured               = $hvciConfigured
        HvciRunning                  = $hvciRunning
        HypervisorPresent            = $hypervisorPresent
        HvciRegistryEnabled          = $hvciEnabledReg  # $null si la key no existe
        VbsRegistryEnabled           = $vbsEnabledReg
        SecurityServicesConfigured   = $svcConfigured
        SecurityServicesRunning      = $svcRunning
    }
}

# ─── Disable-Hvci ─────────────────────────────────────────────────────────────
function Disable-Hvci {
    <#
    .SYNOPSIS
        Deshabilita HVCI (Memory Integrity / Hypervisor-Protected Code
        Integrity) PRESERVANDO VBS y Hyper-V. WSL2 sigue funcionando porque
        depende del hipervisor (que controla bcdedit hypervisorlaunchtype),
        no de HVCI. Tom's Hardware mide 5-10% mejora promedio en gaming al
        apagar HVCI (Doc 1 §1.6, Doc 2 §2.10, Doc 4 §4.1).

        Cambio toma efecto al próximo reboot.

        Si querés deshabilitar VBS completo (no recomendado con WSL2),
        pasá -DisableVbsToo. Eso SÍ rompe WSL2 si está en uso.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $DisableVbsToo
    )

    [string] $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    [string] $dgPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $hvciPath)) {
            New-Item -Path $hvciPath -Force | Out-Null
        }
        Set-ItemProperty -Path $hvciPath -Name 'Enabled' -Value 0 -Type DWord -ErrorAction Stop
        $applied.Add('HVCI Enabled=0 (HypervisorEnforcedCodeIntegrity)')
    }
    catch { $errors.Add("HVCI registry: $($_.Exception.Message)") }

    if ($DisableVbsToo) {
        try {
            if (-not (Test-Path $dgPath)) {
                New-Item -Path $dgPath -Force | Out-Null
            }
            Set-ItemProperty -Path $dgPath -Name 'EnableVirtualizationBasedSecurity' -Value 0 -Type DWord -ErrorAction Stop
            $applied.Add('VBS EnableVirtualizationBasedSecurity=0')
        }
        catch { $errors.Add("VBS registry: $($_.Exception.Message)") }
    }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $true
        Reason          = if ($DisableVbsToo) {
            'HVCI + VBS deshabilitados. WSL2 puede romperse si dependía de VBS.'
        } else {
            'HVCI deshabilitado, VBS preservado. WSL2/Hyper-V siguen funcionando.'
        }
    }
}

# ─── Enable-Hvci ──────────────────────────────────────────────────────────────
function Enable-Hvci {
    <#
    .SYNOPSIS
        Restablece HVCI / Memory Integrity. Cambio toma efecto al reboot.
    #>
    [CmdletBinding()]
    param()

    [string] $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    [string] $dgPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $hvciPath)) { New-Item -Path $hvciPath -Force | Out-Null }
        Set-ItemProperty -Path $hvciPath -Name 'Enabled' -Value 1 -Type DWord -ErrorAction Stop
        $applied.Add('HVCI Enabled=1')
    } catch { $errors.Add("HVCI registry: $($_.Exception.Message)") }

    try {
        if (-not (Test-Path $dgPath)) { New-Item -Path $dgPath -Force | Out-Null }
        Set-ItemProperty -Path $dgPath -Name 'EnableVirtualizationBasedSecurity' -Value 1 -Type DWord -ErrorAction Stop
        $applied.Add('VBS EnableVirtualizationBasedSecurity=1')
    } catch { $errors.Add("VBS registry: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $true
        Reason          = 'HVCI + VBS habilitados. Memory Integrity activo tras el próximo reboot.'
    }
}
