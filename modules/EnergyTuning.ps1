Set-StrictMode -Version Latest

# #78 - Energia en laptops: PERFBOOSTMODE oculto + opcion "laptop gaming".
# La LECTURA (Get-EnergyTuningState, Get-ProcessorPowerSetting) vive en
# Telemetry.ps1 porque el job de telemetria solo dot-sourcea ese archivo.
# Esto es lo MUTANTE: por PC, con confirmacion, NUNCA default ni parte del [1].

# GUIDs propios de este archivo (no dependen de lo que defina otro .ps1).
$script:EnergySubProcessorGuid = '54533251-82be-4824-96c1-47b60b740d00'
$script:EnergyPerfBoostGuid    = 'be337238-0d82-4146-a960-4f3749d470c7'
$script:EnergyThrottleMinGuid  = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$script:EnergyBoostLaptopGaming = 4   # Eficiencia agresiva
$script:EnergyThrottleLaptopGaming = 5
$script:EnergyBoostRevertDefault = 2  # Agresiva (default de Windows)

function Get-EnergyBackupPath {
    <# Donde se guardan los valores previos. Los tests lo shadowean. #>
    [CmdletBinding()]
    param()
    [string] $root = Split-Path -Parent $PSScriptRoot
    return (Join-Path $root 'output\state\energy-laptop-gaming.json')
}

function Test-EnergyLaptopOffered {
    <#
    .SYNOPSIS
        La opcion mutante se ofrece SOLO si el perfil dice que es laptop (la
        deteccion de chassis ya existe en Get-MachineProfile). Sin dato = no se ofrece.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()] [AllowNull()] [object] $MachineProfile)
    if ($null -eq $MachineProfile) { return $false }
    if (-not $MachineProfile.PSObject.Properties['IsLaptop']) { return $false }
    if ($null -eq $MachineProfile.IsLaptop) { return $false }
    return [bool] $MachineProfile.IsLaptop
}

function Show-PerfBoostModeSetting {
    <#
    .SYNOPSIS
        Des-oculta PERFBOOSTMODE en Power Options (mismo patron que UsbPower.ps1).
        No cambia ningun valor. No se re-oculta al revertir (es solo visibilidad).
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Continue'
    & powercfg -attributes SUB_PROCESSOR PERFBOOSTMODE -ATTRIB_HIDE 2>&1 | Out-Null
    [int] $exit = $LASTEXITCODE
    [bool] $ok = ($exit -eq 0)
    [string[]] $applied = @()
    [string[]] $errs    = @()
    [string] $reason = 'Setting visible; ningun valor cambio.'
    if ($ok) { $applied = @('PERFBOOSTMODE visible en Power Options') } else { $errs = @("ATTRIB_HIDE exit $exit"); $reason = 'El setting sigue oculto; ningun valor cambio.' }
    return [PSCustomObject]@{
        Success = $ok
        Applied = $applied
        Errors  = $errs
        RestartRequired = $false
        Reason  = $reason
    }
}

function Set-ProcessorAcValue {
    # Helper interno: SETACVALUEINDEX + verificacion por relectura. Devuelve error o ''.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SettingGuid, [Parameter(Mandatory)] [int] $Value, [Parameter(Mandatory)] [string] $Name)
    $ErrorActionPreference = 'Continue'
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $script:EnergySubProcessorGuid $SettingGuid $Value 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return ('{0}: SETACVALUEINDEX exit {1}' -f $Name, $LASTEXITCODE) }
    return ''
}

function Enable-LaptopGamingEnergy {
    <#
    .SYNOPSIS
        PERFBOOSTMODE=4 + PROCTHROTTLEMIN=5 en AC sobre el esquema activo.
        Antes guarda los valores actuales (si ya hay respaldo, NO lo pisa: el
        respaldo es el estado ORIGINAL, no el de una aplicacion previa).
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Continue'

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    $curBoost = Get-ProcessorPowerSetting -SettingGuid $script:EnergyPerfBoostGuid
    $curThr   = Get-ProcessorPowerSetting -SettingGuid $script:EnergyThrottleMinGuid
    if ($null -eq $curBoost.Ac -or $null -eq $curThr.Ac) {
        $errors.Add('No se pudieron leer los valores actuales (powercfg /qh); no se aplica nada.')
        return [PSCustomObject]@{ Success = $false; Applied = @(); Errors = $errors.ToArray(); RestartRequired = $false; Reason = 'Sin respaldo no se muta.' }
    }

    [string] $bak = Get-EnergyBackupPath
    try {
        if (Test-Path -LiteralPath $bak) {
            $applied.Add('Respaldo previo conservado (estado original)')
        } else {
            [string] $dir = Split-Path -Parent $bak
            if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            [PSCustomObject]@{
                Timestamp         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
                PerfBoostModeAc   = [int] $curBoost.Ac
                ProcThrottleMinAc = [int] $curThr.Ac
            } | ConvertTo-Json | Out-File -LiteralPath $bak -Encoding UTF8
            $applied.Add(('Respaldo guardado: PERFBOOSTMODE AC={0}, PROCTHROTTLEMIN AC={1}' -f $curBoost.Ac, $curThr.Ac))
        }
    } catch {
        $errors.Add("No se pudo guardar el respaldo: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Applied = $applied.ToArray(); Errors = $errors.ToArray(); RestartRequired = $false; Reason = 'Sin respaldo no se muta.' }
    }

    [string] $e1 = Set-ProcessorAcValue -SettingGuid $script:EnergyPerfBoostGuid -Value $script:EnergyBoostLaptopGaming -Name 'PERFBOOSTMODE'
    if ($e1) { $errors.Add($e1) } else { $applied.Add(('PERFBOOSTMODE AC={0}' -f $script:EnergyBoostLaptopGaming)) }
    [string] $e2 = Set-ProcessorAcValue -SettingGuid $script:EnergyThrottleMinGuid -Value $script:EnergyThrottleLaptopGaming -Name 'PROCTHROTTLEMIN'
    if ($e2) { $errors.Add($e2) } else { $applied.Add(('PROCTHROTTLEMIN AC={0}' -f $script:EnergyThrottleLaptopGaming)) }

    & powercfg -SETACTIVE SCHEME_CURRENT 2>&1 | Out-Null

    # Verificacion por relectura (no confiar en el exit code solo).
    $vB = Get-ProcessorPowerSetting -SettingGuid $script:EnergyPerfBoostGuid
    $vT = Get-ProcessorPowerSetting -SettingGuid $script:EnergyThrottleMinGuid
    if ($vB.Ac -ne $script:EnergyBoostLaptopGaming -or $vT.Ac -ne $script:EnergyThrottleLaptopGaming) {
        $errors.Add(('Verificacion: AC leido boost={0} thr={1}' -f $vB.Ac, $vT.Ac))
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0); Applied = $applied.ToArray(); Errors = $errors.ToArray()
        RestartRequired = $false
        Reason = 'Solo AC del esquema activo. Validar temperaturas/ruido en la PC.'
    }
}

function Restore-LaptopGamingEnergy {
    <#
    .SYNOPSIS
        Revierte: restaura el respaldo; sin respaldo, PERFBOOSTMODE=2 y deja
        PROCTHROTTLEMIN como esta (y lo avisa en Reason).
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Continue'

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()
    [string] $reason = ''

    [string] $bak = Get-EnergyBackupPath
    [Nullable[int]] $boost = $null
    [Nullable[int]] $thr   = $null
    try {
        if (Test-Path -LiteralPath $bak) {
            $b = Get-Content -LiteralPath $bak -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($b.PSObject.Properties['PerfBoostModeAc'])   { $boost = [int] $b.PerfBoostModeAc }
            if ($b.PSObject.Properties['ProcThrottleMinAc']) { $thr   = [int] $b.ProcThrottleMinAc }
        }
    } catch { $errors.Add("Respaldo ilegible: $($_.Exception.Message)") }

    [bool] $hadBackup = ($null -ne $boost -and $null -ne $thr)
    if (-not $hadBackup) {
        $boost = $script:EnergyBoostRevertDefault
        $thr   = $null
        $reason = ('Sin respaldo guardado: PERFBOOSTMODE vuelve a {0} (default) y PROCTHROTTLEMIN queda como esta.' -f $script:EnergyBoostRevertDefault)
    } else {
        $reason = 'Valores restaurados desde el respaldo.'
    }

    [string] $e1 = Set-ProcessorAcValue -SettingGuid $script:EnergyPerfBoostGuid -Value ([int]$boost) -Name 'PERFBOOSTMODE'
    if ($e1) { $errors.Add($e1) } else { $applied.Add(('PERFBOOSTMODE AC={0}' -f $boost)) }
    if ($null -ne $thr) {
        [string] $e2 = Set-ProcessorAcValue -SettingGuid $script:EnergyThrottleMinGuid -Value ([int]$thr) -Name 'PROCTHROTTLEMIN'
        if ($e2) { $errors.Add($e2) } else { $applied.Add(('PROCTHROTTLEMIN AC={0}' -f $thr)) }
    }
    & powercfg -SETACTIVE SCHEME_CURRENT 2>&1 | Out-Null

    $vB = Get-ProcessorPowerSetting -SettingGuid $script:EnergyPerfBoostGuid
    if ($vB.Ac -ne [int]$boost) { $errors.Add(('Verificacion: PERFBOOSTMODE AC leido={0}' -f $vB.Ac)) }

    if ($errors.Count -eq 0 -and $hadBackup) {
        try { Remove-Item -LiteralPath $bak -Force -ErrorAction Stop } catch { $errors.Add("No se pudo borrar el respaldo: $($_.Exception.Message)") }
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0); Applied = $applied.ToArray(); Errors = $errors.ToArray()
        RestartRequired = $false; Reason = $reason
    }
}
