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
