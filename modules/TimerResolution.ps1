Set-StrictMode -Version Latest

# TimerResolution -- registry-only, Win11 build >= 22000, cost-zero.
# HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel
#   GlobalTimerResolutionRequests = 1  -> habilita que apps pidan 0.5ms sin
#   que el sistema vuelva al defecto (~15.6ms) cuando la app que lo pide cierra.
#   Efecto: menor latencia de scheduler/input en juegos.
#   SOLO registry: SIN proceso residente. Requiere reinicio para efecto pleno.
#
# Gate de version: solo Win11 (build >= 22000). En Win10 el comportamiento de
# GlobalTimerResolutionRequests es diferente o inexistente; skip limpio.
#
# Referencia: D-S42d orden 1 (piloto del patron), stage4.2-plan.md ss2.1.

$script:TimerRegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
$script:TimerValName  = 'GlobalTimerResolutionRequests'

# ----- Get-TimerResolutionStatus -----------------------------------------------
function Get-TimerResolutionStatus {
    <#
    .SYNOPSIS
        Lee el estado del registro GlobalTimerResolutionRequests.
        Read-only. Smoke-safe (nunca lanza).
    .OUTPUTS
        PSCustomObject:
          Enabled        : $true si el valor = 1, $false si = 0 o ausente
          RawValue       : valor crudo ($null si ausente)
          RegistryPath   : ruta del hive consultado
          WinBuild       : build de Windows detectado (0 si no se pudo leer)
          GateWin11      : $true si build >= 22000
    #>
    [CmdletBinding()]
    param()

    [int]    $build  = 0
    [bool]   $gateOk = $false
    try {
        $osReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                                  -ErrorAction SilentlyContinue
        if ($null -ne $osReg -and $null -ne $osReg.PSObject.Properties['CurrentBuildNumber']) {
            $build  = [int]$osReg.CurrentBuildNumber
            $gateOk = ($build -ge 22000)
        }
    } catch { }

    [object] $raw = $null
    try {
        $reg = Get-ItemProperty -Path $script:TimerRegPath -ErrorAction SilentlyContinue
        if ($null -ne $reg -and $null -ne $reg.PSObject.Properties[$script:TimerValName]) {
            $raw = [int]$reg.$script:TimerValName
        }
    } catch { }

    return [PSCustomObject]@{
        Enabled      = ($null -ne $raw -and [int]$raw -eq 1)
        RawValue     = $raw
        RegistryPath = $script:TimerRegPath
        WinBuild     = $build
        GateWin11    = $gateOk
    }
}

# ----- Set-TimerResolutionRegistry ---------------------------------------------
function Set-TimerResolutionRegistry {
    <#
    .SYNOPSIS
        Activa o desactiva GlobalTimerResolutionRequests via registry.
        Gate duro: solo Win11 (build >= 22000). Reboot requerido.
        Cost-zero: SIN proceso residente.
    .PARAMETER State
        'on'  -> GlobalTimerResolutionRequests = 1
        'off' -> GlobalTimerResolutionRequests = 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('on','off')]
        [string] $State
    )

    [System.Collections.Generic.List[string]] $applied =
        [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  =
        [System.Collections.Generic.List[string]]::new()

    # Gate Win11
    [PSCustomObject] $status = Get-TimerResolutionStatus
    if (-not $status.GateWin11) {
        return [PSCustomObject]@{
            Success         = $true
            Skipped         = $true
            Applied         = @()
            Errors          = @()
            RestartRequired = $false
            Reason          = ("Timer Resolution registry gate: build {0} < 22000 (Win10 o anterior). " +
                               "GlobalTimerResolutionRequests no tiene efecto documentado. Skip limpio.") -f $status.WinBuild
        }
    }

    [int] $value = if ($State -eq 'on') { 1 } else { 0 }
    try {
        if (-not (Test-Path $script:TimerRegPath)) {
            New-Item -Path $script:TimerRegPath -Force | Out-Null
        }
        Set-ItemProperty -Path $script:TimerRegPath `
                         -Name $script:TimerValName `
                         -Value $value `
                         -Type DWord `
                         -ErrorAction Stop
        $applied.Add(("GlobalTimerResolutionRequests={0} ({1})" -f $value, $State))
    }
    catch { $errors.Add("TimerResolution registry: $($_.Exception.Message)") }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Skipped         = $false
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $true
        Reason          = if ($errors.Count -eq 0) {
            ("GlobalTimerResolutionRequests={0}. Reinicio requerido para efecto pleno. " +
             "Sin proceso residente (cost-zero).") -f $value
        } else { 'Error al escribir registro de TimerResolution.' }
    }
}
