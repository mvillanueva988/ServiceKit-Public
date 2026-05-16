Set-StrictMode -Version Latest

# --- Invoke-PrivacyTweaks ----------------------------------------------------
function Invoke-PrivacyTweaks {
    <#
    .SYNOPSIS
        Aplica tweaks de privacidad al registro de Windows segun el perfil.
        Basic      : telemetria, Advertising ID, Bing en Start, feedback, Activity Feed.
        Medium     : Basic + ubicacion global, experiencias personalizadas, sugerencias de inicio.
        Aggressive : Medium + OneDrive (policy), Edge startup/background, consumer features, tips.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Basic', 'Medium', 'Aggressive')]
        [string] $Profile
    )

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    function Set-RegValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        try {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
            return $true
        } catch {
            return $_.Exception.Message
        }
    }

    # --- BASIC ---------------------------------------------------------------
    $r = Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    if ($r -eq $true) { $applied.Add('Telemetria: AllowTelemetry=0') } else { $errors.Add("Telemetria: $r") }

    $r = Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    if ($r -eq $true) { $applied.Add('Advertising ID: deshabilitado') } else { $errors.Add("AdvertisingID: $r") }

    $r = Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    if ($r -eq $true) { $applied.Add('Bing en busqueda de inicio: off') } else { $errors.Add("BingSearch: $r") }

    $r = Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Windows Search' 'CortanaConsent' 0
    if ($r -eq $true) { $applied.Add('Cortana consent: off') } else { $errors.Add("Cortana: $r") }

    $r = Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    if ($r -eq $true) { $applied.Add('Feedback de Windows: deshabilitado') } else { $errors.Add("Feedback: $r") }

    $r = Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    if ($r -eq $true) { $applied.Add('Activity Feed: deshabilitado') } else { $errors.Add("ActivityFeed: $r") }

    if ($Profile -eq 'Basic') {
        return [PSCustomObject]@{ Profile = $Profile; Applied = $applied.ToArray(); Errors = $errors.ToArray() }
    }

    # --- MEDIUM --------------------------------------------------------------
    [string] $locPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
    $r = Set-RegValue $locPath 'SensorPermissionState' 0
    if ($r -eq $true) { $applied.Add('Ubicacion global (sistema): deshabilitada') } else { $errors.Add("Location: $r") }

    $r = Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    if ($r -eq $true) { $applied.Add('Experiencias personalizadas con datos de diagnostico: off') } else { $errors.Add("TailoredExp: $r") }

    [string] $cdmPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $r = Set-RegValue $cdmPath 'SystemPaneSuggestionsEnabled' 0
    if ($r -eq $true) { $applied.Add('Sugerencias en panel Inicio: off') } else { $errors.Add("StartSuggestions: $r") }

    $r = Set-RegValue $cdmPath 'SilentInstalledAppsEnabled' 0
    if ($r -eq $true) { $applied.Add('Apps silenciosas instaladas por Microsoft: off') } else { $errors.Add("SilentApps: $r") }

    $r = Set-RegValue 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0
    if ($r -eq $true) { $applied.Add('Actualizacion automatica de mapas en background: off') } else { $errors.Add("Maps: $r") }

    if ($Profile -eq 'Medium') {
        return [PSCustomObject]@{ Profile = $Profile; Applied = $applied.ToArray(); Errors = $errors.ToArray() }
    }

    # --- AGGRESSIVE ----------------------------------------------------------
    $r = Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    if ($r -eq $true) { $applied.Add('OneDrive sync: deshabilitado (policy)') } else { $errors.Add("OneDrive: $r") }

    [string] $edgePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $r = Set-RegValue $edgePath 'StartupBoostEnabled' 0
    if ($r -eq $true) { $applied.Add('Edge Startup Boost: off') } else { $errors.Add("EdgeStartup: $r") }

    $r = Set-RegValue $edgePath 'BackgroundModeEnabled' 0
    if ($r -eq $true) { $applied.Add('Edge background mode: off') } else { $errors.Add("EdgeBG: $r") }

    $r = Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    if ($r -eq $true) { $applied.Add('Consumer features (sugerencias en Start): off') } else { $errors.Add("ConsumerFeatures: $r") }

    $r = Set-RegValue $cdmPath 'SoftLandingEnabled' 0
    if ($r -eq $true) { $applied.Add('Tips y sugerencias de apps: off') } else { $errors.Add("AppTips: $r") }

    $r = Set-RegValue $cdmPath 'SubscribedContent-310093Enabled' 0
    if ($r -eq $true) { $applied.Add('Contenido suscrito (tips, trucos de Windows): off') } else { $errors.Add("SubscribedContent: $r") }

    $r = Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    if ($r -eq $true) { $applied.Add('Windows Error Reporting: deshabilitado') } else { $errors.Add("WER: $r") }

    return [PSCustomObject]@{ Profile = $Profile; Applied = $applied.ToArray(); Errors = $errors.ToArray() }
}

# --- Start-PrivacyJob --------------------------------------------------------
function Start-PrivacyJob {
    <#
    .SYNOPSIS
        Empaqueta Invoke-PrivacyTweaks en un job asincrono y retorna el Job.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Basic', 'Medium', 'Aggressive')]
        [string] $Profile
    )

    [string]      $fnBody   = ${Function:Invoke-PrivacyTweaks}.ToString()
    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Invoke-PrivacyTweaks {
$fnBody
}
Invoke-PrivacyTweaks -Profile `$args[0]
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName "Privacy_$Profile" -ArgumentList @($Profile)
}

function Get-ShutUp10Path {
    [CmdletBinding()]
    param()

    [string] $bundledPath = Join-Path $PSScriptRoot '..\tools\bin\OOSU10.exe'
    if (Test-Path $bundledPath) {
        return $bundledPath
    }

    $cmd = Get-Command -Name 'OOSU10.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return [string] $cmd.Source
    }

    return ''
}

# --- Test-ShutUp10Available --------------------------------------------------
function Test-ShutUp10Available {
    [CmdletBinding()]
    param()
    return (-not [string]::IsNullOrWhiteSpace((Get-ShutUp10Path)))
}

# --- Open-ShutUp10 -----------------------------------------------------------
function Open-ShutUp10 {
    [CmdletBinding()]
    param()

    [string] $exePath = Get-ShutUp10Path

    if ([string]::IsNullOrWhiteSpace($exePath) -or -not (Test-Path $exePath)) {
        return [PSCustomObject]@{ Success = $false; Error = 'OOSU10.exe no encontrado. Descargalo desde [T] Herramientas.' }
    }

    try {
        Start-Process -FilePath $exePath
        return [PSCustomObject]@{ Success = $true; Path = $exePath }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message; Path = $exePath }
    }
}

# --- Add-WslDefenderExclusions -----------------------------------------------
function Add-WslDefenderExclusions {
    <#
    .SYNOPSIS
        Agrega exclusiones de Defender para WSL2 + Docker Desktop + VS Code.
        Doc 1 sec 1.11 documenta que el scan sincronico de Defender sobre
        archivos del LXSS (donde vive el rootfs de Ubuntu/Docker) es la
        causa #1 de slowness en flujos de desarrollo con WSL2: cada open
        de archivo dispara una inspeccion AV que bloquea el syscall.

        Excluye:
          - Paths del LXSS: cualquier CanonicalGroupLimited.Ubuntu* en LocalAppData
          - Path de Docker Desktop: LocalAppData\Docker
          - Procesos: vmmemWSL.exe, wsl.exe, wslservice.exe, Code.exe
          - Opcional: Steam si se pasa -IncludeSteam

        Tamper Protection se mantiene ON. Add-MpPreference no requiere
        apagarla mientras el caller sea admin local.

        Si Defender no esta disponible (ej. AV de terceros), no hace nada
        y reporta Skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $IncludeSteam,

        [Parameter()]
        [string] $SteamPath = 'C:\Program Files (x86)\Steam'
    )

    # ¿Defender disponible? Si Get-MpPreference falla, asumimos AV de terceros activo.
    try {
        $null = Get-MpPreference -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            Success = $true
            Skipped = $true
            Reason  = 'Get-MpPreference no disponible (probablemente AV de terceros activo). No se aplican exclusiones de Defender.'
            Applied = @()
            Errors  = @()
        }
    }

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    # Resolver paths LXSS (puede haber varios distros — Ubuntu, Ubuntu-22.04, kali, debian, etc.)
    [string[]] $lxssPaths = @()
    [string] $localPkgs = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $localPkgs) {
        $lxssPaths = @(
            Get-ChildItem -Path $localPkgs -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'CanonicalGroupLimited\.|TheDebianProject\.|KaliLinux\.|whitewaterfoundry\.|46932SUSE\.|Fedora' } |
                Select-Object -ExpandProperty FullName
        )
    }
    [string] $dockerPath = Join-Path $env:LOCALAPPDATA 'Docker'

    foreach ($p in $lxssPaths) {
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            $applied.Add("Path: $p")
        }
        catch { $errors.Add("Path $p : $($_.Exception.Message)") }
    }

    if (Test-Path $dockerPath) {
        try {
            Add-MpPreference -ExclusionPath $dockerPath -ErrorAction Stop
            $applied.Add("Path: $dockerPath")
        }
        catch { $errors.Add("Path $dockerPath : $($_.Exception.Message)") }
    }

    [string[]] $procs = @('vmmemWSL.exe', 'wsl.exe', 'wslservice.exe', 'Code.exe')
    foreach ($proc in $procs) {
        try {
            Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
            $applied.Add("Process: $proc")
        }
        catch { $errors.Add("Process $proc : $($_.Exception.Message)") }
    }

    if ($IncludeSteam -and (Test-Path $SteamPath)) {
        try {
            Add-MpPreference -ExclusionPath $SteamPath -ErrorAction Stop
            $applied.Add("Path: $SteamPath")
            foreach ($sp in @('steam.exe', 'steamwebhelper.exe', 'cs2.exe')) {
                try {
                    Add-MpPreference -ExclusionProcess $sp -ErrorAction Stop
                    $applied.Add("Process: $sp")
                }
                catch { $errors.Add("Process $sp : $($_.Exception.Message)") }
            }
        }
        catch { $errors.Add("Path $SteamPath : $($_.Exception.Message)") }
    }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Skipped         = $false
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = 'Exclusiones de Defender aplicadas. Tamper Protection sigue ON.'
    }
}

# --- Invoke-OOSU10Profile ----------------------------------------------------
function Invoke-OOSU10Profile {
    <#
    .SYNOPSIS
        Aplica un archivo .cfg de O&O ShutUp10++ de forma silenciosa.
        Si OOSU10.exe o el .cfg no estan disponibles, retorna Skipped=$true
        sin fallar (el engine ya tiene fallback nativo decidido antes de llamar aca).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [int] $TimeoutSeconds = 120
    )

    [string] $exe = Get-ShutUp10Path

    if ([string]::IsNullOrWhiteSpace($exe)) {
        return [PSCustomObject]@{
            Success        = $true
            Skipped        = $true
            Reason         = 'OOSU10.exe no instalado'
            ExePath        = ''
            CfgPath        = $Path
            ExitCode       = $null
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Success        = $true
            Skipped        = $true
            Reason         = 'cfg no encontrado'
            ExePath        = $exe
            CfgPath        = $Path
            ExitCode       = $null
        }
    }

    try {
        $proc = Start-Process -FilePath $exe -ArgumentList @($Path, '/quiet') `
            -PassThru -WindowStyle Hidden -ErrorAction Stop

        [bool] $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            try { $proc.Kill() } catch { }
            return [PSCustomObject]@{
                Success        = $false
                Skipped        = $false
                Reason         = "Timeout ($TimeoutSeconds s)"
                ExePath        = $exe
                CfgPath        = $Path
                ExitCode       = $null
            }
        }

        [int] $exit = $proc.ExitCode
        return [PSCustomObject]@{
            Success        = ($exit -eq 0)
            Skipped        = $false
            Reason         = if ($exit -eq 0) { '' } else { "ExitCode $exit" }
            ExePath        = $exe
            CfgPath        = $Path
            ExitCode       = $exit
        }
    }
    catch {
        return [PSCustomObject]@{
            Success        = $false
            Skipped        = $false
            Reason         = $_.Exception.Message
            ExePath        = $exe
            CfgPath        = $Path
            ExitCode       = $null
        }
    }
}

# --- Add-CustomDefenderExclusion ---------------------------------------------
function Add-CustomDefenderExclusion {
    <#
    .SYNOPSIS
        Agrega uno o mas paths arbitrarios como exclusiones de Defender.
        Defensivo e idempotente: Add-MpPreference no falla si el path ya existe.
        D3 (stage4-plan §12): MVP = lista de paths libres (Steam auto-detect = Stage 4.2).

        Si Defender no esta disponible (AV de terceros), no hace nada y reporta Skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Path
    )

    try {
        $null = Get-MpPreference -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            Success = $true
            Skipped = $true
            Reason  = 'Get-MpPreference no disponible (probablemente AV de terceros activo). No se aplican exclusiones de Defender.'
            Applied = @()
            Errors  = @()
        }
    }

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            $applied.Add("Path: $p")
        }
        catch {
            $errors.Add("Path $p : $($_.Exception.Message)")
        }
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0)
        Skipped = $false
        Applied = $applied.ToArray()
        Errors  = $errors.ToArray()
        Reason  = 'Exclusiones de Defender aplicadas. Tamper Protection sigue ON.'
    }
}

# --- Get-CustomDefenderExclusions --------------------------------------------
function Get-CustomDefenderExclusions {
    <#
    .SYNOPSIS
        Lee los paths de exclusion de Defender actualmente configurados.
        Read-only. Smoke-safe.
    #>
    [CmdletBinding()]
    param()

    try {
        $pref = Get-MpPreference -ErrorAction Stop
        [string[]] $paths = @()
        if ($null -ne $pref -and $null -ne $pref.PSObject.Properties['ExclusionPath']) {
            $paths = @($pref.ExclusionPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        return [PSCustomObject]@{
            Available = $true
            Paths     = $paths
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Paths     = @()
            Reason    = $_.Exception.Message
        }
    }
}

# --- Remove-WslDefenderExclusions --------------------------------------------
function Remove-WslDefenderExclusions {
    <#
    .SYNOPSIS
        Revierte las exclusiones aplicadas por Add-WslDefenderExclusions.
        Es best-effort: si una exclusion no existe, Remove-MpPreference
        no tira error.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $IncludeSteam,

        [Parameter()]
        [string] $SteamPath = 'C:\Program Files (x86)\Steam'
    )

    try { $null = Get-MpPreference -ErrorAction Stop } catch {
        return [PSCustomObject]@{
            Success = $true
            Skipped = $true
            Reason  = 'Defender no disponible. Nada que remover.'
            Applied = @()
            Errors  = @()
        }
    }

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    [string[]] $lxssPaths = @()
    [string] $localPkgs = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $localPkgs) {
        $lxssPaths = @(
            Get-ChildItem -Path $localPkgs -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'CanonicalGroupLimited\.|TheDebianProject\.|KaliLinux\.|whitewaterfoundry\.|46932SUSE\.|Fedora' } |
                Select-Object -ExpandProperty FullName
        )
    }
    [string] $dockerPath = Join-Path $env:LOCALAPPDATA 'Docker'

    foreach ($p in @($lxssPaths + @($dockerPath))) {
        try { Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue; $applied.Add("Path removido: $p") } catch { }
    }
    foreach ($proc in @('vmmemWSL.exe', 'wsl.exe', 'wslservice.exe', 'Code.exe')) {
        try { Remove-MpPreference -ExclusionProcess $proc -ErrorAction SilentlyContinue; $applied.Add("Process removido: $proc") } catch { }
    }
    if ($IncludeSteam) {
        try { Remove-MpPreference -ExclusionPath $SteamPath -ErrorAction SilentlyContinue; $applied.Add("Path removido: $SteamPath") } catch { }
        foreach ($sp in @('steam.exe', 'steamwebhelper.exe', 'cs2.exe')) {
            try { Remove-MpPreference -ExclusionProcess $sp -ErrorAction SilentlyContinue; $applied.Add("Process removido: $sp") } catch { }
        }
    }

    return [PSCustomObject]@{
        Success         = $true
        Skipped         = $false
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = 'Exclusiones de Defender removidas (best-effort).'
    }
}
