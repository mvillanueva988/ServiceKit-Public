Set-StrictMode -Version Latest

# ─────────────────────────────────────────────────────────────────────────────
# Claves compartidas usadas por los tres perfiles
# ─────────────────────────────────────────────────────────────────────────────
$script:DesktopPath  = 'HKCU:\Control Panel\Desktop'
$script:MetricsPath  = 'HKCU:\Control Panel\Desktop\WindowMetrics'
$script:AdvPath      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$script:VfxPath      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
$script:ThemePath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

function Set-BalancedVisuals {
    <#
    .SYNOPSIS
        Aplica un perfil de efectos visuales balanceado: deshabilita animaciones,
        sombras y transparencias pesadas, manteniendo font smoothing, thumbnails
        y contenido de ventana al arrastrar.
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $script:VfxPath))   { New-Item -Path $script:VfxPath   -Force | Out-Null }
        if (-not (Test-Path $script:ThemePath))  { New-Item -Path $script:ThemePath -Force | Out-Null }

        # Custom (3): Windows respeta los valores individuales
        Set-ItemProperty -Path $script:VfxPath    -Name 'VisualFXSetting'     -Value 3   -Type DWord

        # ── MANTENER ──────────────────────────────────────────────────────────────
        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothing'      -Value '2'
        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothingType'  -Value 2   -Type DWord
        $applied.Add('[ON]  Smooth edges of screen fonts (ClearType)')

        Set-ItemProperty -Path $script:DesktopPath -Name 'DragFullWindows'    -Value '1'
        $applied.Add('[ON]  Show window contents while dragging')

        Set-ItemProperty -Path $script:AdvPath     -Name 'IconsOnly'          -Value 0   -Type DWord
        $applied.Add('[ON]  Show thumbnails instead of icons')

        # ── DESHABILITAR ──────────────────────────────────────────────────────────
        Set-ItemProperty -Path $script:AdvPath     -Name 'TaskbarAnimations'  -Value 0   -Type DWord
        $applied.Add('[OFF] Taskbar animations')

        Set-ItemProperty -Path $script:MetricsPath -Name 'MinAnimate'         -Value '0'
        $applied.Add('[OFF] Animate windows when minimizing/maximizing')

        Set-ItemProperty -Path $script:AdvPath     -Name 'ListviewShadow'     -Value 0   -Type DWord
        $applied.Add('[OFF] Drop shadows under desktop icons')

        Set-ItemProperty -Path $script:ThemePath   -Name 'EnableTransparency' -Value 0   -Type DWord
        $applied.Add('[OFF] Glass/Acrylic transparency')

        # UserPreferencesMask: Best Performance con FontSmoothing/DragFullWindows preservados
        [byte[]] $mask = 0x90, 0x12, 0x01, 0x80, 0x10, 0x00, 0x00, 0x00
        Set-ItemProperty -Path $script:DesktopPath -Name 'UserPreferencesMask' -Value $mask -Type Binary
        $applied.Add('[OFF] Fade/slide menus and tooltips')

        Set-ItemProperty -Path $script:DesktopPath -Name 'MenuShowDelay'      -Value '0'
        $applied.Add('[OFF] Menu show delay (0 ms)')
    }
    catch { $errors.Add($_.Exception.Message) }

    return [PSCustomObject]@{ Success = ($errors.Count -eq 0); Applied = $applied.ToArray(); Errors = $errors.ToArray() }
}

function Set-FullOptimizedVisuals {
    <#
    .SYNOPSIS
        Perfil "Maximo Rendimiento": todos los efectos deshabilitados.
        Equivalente a sysdm.cpl > "Adjust for best performance".
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $script:VfxPath))  { New-Item -Path $script:VfxPath  -Force | Out-Null }
        if (-not (Test-Path $script:ThemePath)) { New-Item -Path $script:ThemePath -Force | Out-Null }

        # Best Performance (2): Windows deshabilita todo automaticamente
        Set-ItemProperty -Path $script:VfxPath    -Name 'VisualFXSetting'     -Value 2   -Type DWord

        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothing'      -Value '0'
        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothingType'  -Value 0   -Type DWord
        $applied.Add('[OFF] Smooth edges of screen fonts')

        Set-ItemProperty -Path $script:DesktopPath -Name 'DragFullWindows'    -Value '0'
        $applied.Add('[OFF] Show window contents while dragging')

        Set-ItemProperty -Path $script:AdvPath     -Name 'IconsOnly'          -Value 1   -Type DWord
        $applied.Add('[OFF] Show thumbnails (muestra iconos simples)')

        Set-ItemProperty -Path $script:AdvPath     -Name 'TaskbarAnimations'  -Value 0   -Type DWord
        $applied.Add('[OFF] Taskbar animations')

        Set-ItemProperty -Path $script:MetricsPath -Name 'MinAnimate'         -Value '0'
        $applied.Add('[OFF] Animate windows when minimizing/maximizing')

        Set-ItemProperty -Path $script:AdvPath     -Name 'ListviewShadow'     -Value 0   -Type DWord
        $applied.Add('[OFF] Drop shadows under desktop icons')

        Set-ItemProperty -Path $script:ThemePath   -Name 'EnableTransparency' -Value 0   -Type DWord
        $applied.Add('[OFF] Glass/Acrylic transparency')

        # Mascara "Best Performance" completa
        [byte[]] $mask = 0x90, 0x02, 0x01, 0x80, 0x10, 0x00, 0x00, 0x00
        Set-ItemProperty -Path $script:DesktopPath -Name 'UserPreferencesMask' -Value $mask -Type Binary
        $applied.Add('[OFF] Todas las animaciones y fades')

        Set-ItemProperty -Path $script:DesktopPath -Name 'MenuShowDelay'      -Value '0'
        $applied.Add('[OFF] Menu show delay (0 ms)')
    }
    catch { $errors.Add($_.Exception.Message) }

    return [PSCustomObject]@{ Success = ($errors.Count -eq 0); Applied = $applied.ToArray(); Errors = $errors.ToArray() }
}

function Restore-DefaultVisuals {
    <#
    .SYNOPSIS
        Restaura todos los efectos visuales a los valores por defecto de Windows.
        Equivalente a sysdm.cpl > "Adjust for best appearance".
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-Path $script:VfxPath))  { New-Item -Path $script:VfxPath  -Force | Out-Null }
        if (-not (Test-Path $script:ThemePath)) { New-Item -Path $script:ThemePath -Force | Out-Null }

        # Best Appearance (1): Windows activa todo
        Set-ItemProperty -Path $script:VfxPath    -Name 'VisualFXSetting'     -Value 1   -Type DWord

        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothing'      -Value '2'
        Set-ItemProperty -Path $script:DesktopPath -Name 'FontSmoothingType'  -Value 2   -Type DWord
        $applied.Add('[ON]  Smooth edges of screen fonts (ClearType)')

        Set-ItemProperty -Path $script:DesktopPath -Name 'DragFullWindows'    -Value '1'
        $applied.Add('[ON]  Show window contents while dragging')

        Set-ItemProperty -Path $script:AdvPath     -Name 'IconsOnly'          -Value 0   -Type DWord
        $applied.Add('[ON]  Show thumbnails instead of icons')

        Set-ItemProperty -Path $script:AdvPath     -Name 'TaskbarAnimations'  -Value 1   -Type DWord
        $applied.Add('[ON]  Taskbar animations')

        Set-ItemProperty -Path $script:MetricsPath -Name 'MinAnimate'         -Value '1'
        $applied.Add('[ON]  Animate windows when minimizing/maximizing')

        Set-ItemProperty -Path $script:AdvPath     -Name 'ListviewShadow'     -Value 1   -Type DWord
        $applied.Add('[ON]  Drop shadows under desktop icons')

        Set-ItemProperty -Path $script:ThemePath   -Name 'EnableTransparency' -Value 1   -Type DWord
        $applied.Add('[ON]  Glass/Acrylic transparency')

        # Mascara "Best Appearance" con todas las animaciones activas
        [byte[]] $mask = 0x9E, 0x1E, 0x07, 0x80, 0x12, 0x00, 0x00, 0x00
        Set-ItemProperty -Path $script:DesktopPath -Name 'UserPreferencesMask' -Value $mask -Type Binary
        $applied.Add('[ON]  Todas las animaciones y fades')

        Set-ItemProperty -Path $script:DesktopPath -Name 'MenuShowDelay'      -Value '400'
        $applied.Add('[ON]  Menu show delay (400 ms, valor Windows)')
    }
    catch { $errors.Add($_.Exception.Message) }

    return [PSCustomObject]@{ Success = ($errors.Count -eq 0); Applied = $applied.ToArray(); Errors = $errors.ToArray() }
}

function Set-UltimatePowerPlan {
    <#
    .SYNOPSIS
        Activa el plan Ultimate Performance. Si no existe en esta edicion de Windows,
        lo duplica desde su GUID conocido. Cae a High Performance como fallback.
    #>
    [CmdletBinding()]
    param()

    [string] $ultimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    [string] $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

    try {
        [string] $listOutput  = (& powercfg /list 2>&1) -join "`n"
        [bool]   $hasUltimate = $listOutput -match $ultimateGuid

        if (-not $hasUltimate) {
            # Intentar importar el esquema oculto (requiere Windows 10 1803+ / Win 11)
            & powercfg /duplicatescheme $ultimateGuid 2>&1 | Out-Null
            $hasUltimate = ($LASTEXITCODE -eq 0)
        }

        if ($hasUltimate) {
            & powercfg /setactive $ultimateGuid 2>&1 | Out-Null
            return [PSCustomObject]@{
                Success  = $true
                PlanName = 'Ultimate Performance'
                PlanGuid = $ultimateGuid
            }
        }

        # Fallback: High Performance (siempre disponible)
        & powercfg /setactive $highPerfGuid 2>&1 | Out-Null
        return [PSCustomObject]@{
            Success  = ($LASTEXITCODE -eq 0)
            PlanName = 'High Performance (Ultimate no disponible en esta edicion de Windows)'
            PlanGuid = $highPerfGuid
        }
    }
    catch {
        return [PSCustomObject]@{
            Success  = $false
            PlanName = "Error: $($_.Exception.Message)"
            PlanGuid = ''
        }
    }
}

function Start-PerformanceProcess {
    <#
    .SYNOPSIS
        Empaqueta el perfil visual elegido + Set-UltimatePowerPlan en un job asincrono.
        VisualProfile: 'Balanced' | 'Full' | 'Restore'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Balanced', 'Full', 'Restore')]
        [string] $VisualProfile
    )

    [string] $fnBalanced  = ${Function:Set-BalancedVisuals}.ToString()
    [string] $fnFull      = ${Function:Set-FullOptimizedVisuals}.ToString()
    [string] $fnRestore   = ${Function:Restore-DefaultVisuals}.ToString()
    [string] $fnPowerPlan = ${Function:Set-UltimatePowerPlan}.ToString()

    [scriptblock] $jobBlock = [scriptblock]::Create(@"
`$script:DesktopPath = 'HKCU:\Control Panel\Desktop'
`$script:MetricsPath = 'HKCU:\Control Panel\Desktop\WindowMetrics'
`$script:AdvPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
`$script:VfxPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
`$script:ThemePath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
function Set-BalancedVisuals      { $fnBalanced  }
function Set-FullOptimizedVisuals { $fnFull      }
function Restore-DefaultVisuals   { $fnRestore   }
function Set-UltimatePowerPlan    { $fnPowerPlan }
`$v = switch ('$VisualProfile') {
    'Balanced' { Set-BalancedVisuals      }
    'Full'     { Set-FullOptimizedVisuals }
    'Restore'  { Restore-DefaultVisuals   }
}
`$pp = Set-UltimatePowerPlan
[PSCustomObject]@{ Visuals = `$v; PowerPlan = `$pp }
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName "Performance_$VisualProfile"
}
