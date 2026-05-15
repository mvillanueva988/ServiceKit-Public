Set-StrictMode -Version Latest

# GUIDs oficiales del subgrupo USB + setting Selective Suspend (Doc 1 §1.7)
$script:UsbSubgroupGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:UsbSuspendGuid  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$script:UsbSvcRegPath   = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'

# ─── Get-UsbSelectiveSuspendStatus ────────────────────────────────────────────
function Get-UsbSelectiveSuspendStatus {
    <#
    .SYNOPSIS
        Lee el estado de USB Selective Suspend en el power plan activo
        (AC + DC) y la flag global del registro. Read-only. Smoke-safe.

    .OUTPUTS
        PSCustomObject con:
          - AcValueIndex / DcValueIndex   : 0 = disabled, 1 = enabled, $null si oculto
          - RegistryGlobalDisabled        : 1 si HKLM\...\USB\DisableSelectiveSuspend=1
          - IsHiddenInGui                 : si el setting está oculto en Power Options
                                            (Win11 24H2 lo oculta por default)
    #>
    [CmdletBinding()]
    param()

    [Nullable[int]] $acIdx = $null
    [Nullable[int]] $dcIdx = $null
    [bool] $hidden = $true
    [Nullable[int]] $regGlobal = $null

    # Parsear `powercfg /query SCHEME_CURRENT <subgroup> <setting>` para AC y DC
    try {
        [string] $qOut = (& powercfg /query SCHEME_CURRENT $script:UsbSubgroupGuid $script:UsbSuspendGuid 2>&1) -join "`n"
        if ($qOut -match 'Indice de valor de configuracion de CA actual:\s*0x([0-9a-fA-F]+)' -or
            $qOut -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $acIdx = [int]("0x$($Matches[1])")
        }
        if ($qOut -match 'Indice de valor de configuracion de CC actual:\s*0x([0-9a-fA-F]+)' -or
            $qOut -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $dcIdx = [int]("0x$($Matches[1])")
        }
        # Si powercfg /query devuelve datos, el setting NO está oculto.
        if ($null -ne $acIdx -or $null -ne $dcIdx) {
            $hidden = $false
        }
    }
    catch { }

    # Registry global override
    try {
        $reg = Get-ItemProperty -Path $script:UsbSvcRegPath -ErrorAction SilentlyContinue
        if ($null -ne $reg -and $null -ne $reg.PSObject.Properties['DisableSelectiveSuspend']) {
            $regGlobal = [int] $reg.DisableSelectiveSuspend
        }
    }
    catch { }

    return [PSCustomObject]@{
        AcValueIndex            = $acIdx
        DcValueIndex            = $dcIdx
        RegistryGlobalDisabled  = $regGlobal
        IsHiddenInGui           = $hidden
        SubgroupGuid            = $script:UsbSubgroupGuid
        SettingGuid             = $script:UsbSuspendGuid
    }
}

# ─── Disable-UsbSelectiveSuspend ──────────────────────────────────────────────
function Disable-UsbSelectiveSuspend {
    <#
    .SYNOPSIS
        Deshabilita USB Selective Suspend en el plan activo (AC + DC) y
        adicionalmente setea la flag global de registro como reaseguro
        para drivers que ignoran el plan. Doc 1 §1.7 + paso 5.

        Win11 24H2 oculta este setting del GUI de Power Options por default.
        Primero se hace `powercfg -attributes -ATTRIB_HIDE` para mostrarlo,
        después se aplica el valor 0.
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    # 1. Mostrar la opción en GUI (no falla si ya está visible)
    & powercfg -attributes $script:UsbSubgroupGuid $script:UsbSuspendGuid -ATTRIB_HIDE 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $applied.Add('Setting USB Selective Suspend visible en Power Options')
    }

    # 2. AC = 0 (disabled)
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $script:UsbSubgroupGuid $script:UsbSuspendGuid 0 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $applied.Add('USB Selective Suspend AC=0 (disabled)')
    } else {
        $errors.Add("SETACVALUEINDEX exit $LASTEXITCODE")
    }

    # 3. DC = 0 (disabled)
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $script:UsbSubgroupGuid $script:UsbSuspendGuid 0 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $applied.Add('USB Selective Suspend DC=0 (disabled)')
    } else {
        $errors.Add("SETDCVALUEINDEX exit $LASTEXITCODE")
    }

    # 4. Re-activar el scheme actual para que tome efecto
    & powercfg -SETACTIVE SCHEME_CURRENT 2>&1 | Out-Null

    # 5. Registry global como reaseguro
    try {
        if (-not (Test-Path $script:UsbSvcRegPath)) {
            New-Item -Path $script:UsbSvcRegPath -Force | Out-Null
        }
        Set-ItemProperty -Path $script:UsbSvcRegPath -Name 'DisableSelectiveSuspend' -Value 1 -Type DWord -ErrorAction Stop
        $applied.Add('Registry global DisableSelectiveSuspend=1')
    }
    catch { $errors.Add("Registry global: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = 'USB Selective Suspend deshabilitado para dongles 2.4GHz, periferics HID y dispositivos sensibles a latencia.'
    }
}

# ─── Enable-UsbSelectiveSuspend ───────────────────────────────────────────────
function Enable-UsbSelectiveSuspend {
    <#
    .SYNOPSIS
        Restablece USB Selective Suspend a habilitado (default de Windows).
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $script:UsbSubgroupGuid $script:UsbSuspendGuid 1 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $applied.Add('USB Selective Suspend AC=1') } else { $errors.Add("AC: exit $LASTEXITCODE") }

    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $script:UsbSubgroupGuid $script:UsbSuspendGuid 1 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $applied.Add('USB Selective Suspend DC=1') } else { $errors.Add("DC: exit $LASTEXITCODE") }

    & powercfg -SETACTIVE SCHEME_CURRENT 2>&1 | Out-Null

    try {
        if (Test-Path $script:UsbSvcRegPath) {
            $existing = Get-ItemProperty -Path $script:UsbSvcRegPath -ErrorAction SilentlyContinue
            if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['DisableSelectiveSuspend']) {
                Remove-ItemProperty -Path $script:UsbSvcRegPath -Name 'DisableSelectiveSuspend' -ErrorAction Stop
                $applied.Add('Registry global DisableSelectiveSuspend removido')
            }
        }
    }
    catch { $errors.Add("Registry global cleanup: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = 'USB Selective Suspend habilitado (default de Windows).'
    }
}
