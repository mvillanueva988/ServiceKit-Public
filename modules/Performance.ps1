Set-StrictMode -Version Latest

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
        # Modo Visual FX: Custom (3) — requerido para que los valores individuales tengan efecto
        [string] $vePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        if (-not (Test-Path $vePath)) { New-Item -Path $vePath -Force | Out-Null }
        Set-ItemProperty -Path $vePath -Name 'VisualFXSetting' -Value 3 -Type DWord
        $applied.Add('VisualFXSetting = Custom (3)')

        # ── MANTENER ────────────────────────────────────────────────────────────────

        # Font Smoothing (ClearType): texto legible
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothing'     -Value '2'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothingType' -Value 2 -Type DWord
        $applied.Add('[ON]  Smooth edges of screen fonts (ClearType)')

        # Show window contents while dragging: evita sensacion de lag al mover ventanas
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'DragFullWindows' -Value '1'
        $applied.Add('[ON]  Show window contents while dragging')

        # Show thumbnails instead of icons: imprescindible para fotos/videos
        [string] $advPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-ItemProperty -Path $advPath -Name 'IconsOnly' -Value 0 -Type DWord
        $applied.Add('[ON]  Show thumbnails instead of icons')

        # ── DESHABILITAR ─────────────────────────────────────────────────────────────

        # Animaciones de la barra de tareas y el boton de inicio
        Set-ItemProperty -Path $advPath -Name 'TaskbarAnimations' -Value 0 -Type DWord
        $applied.Add('[OFF] Taskbar animations')

        # Animacion de minimizar/maximizar ventanas
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0'
        $applied.Add('[OFF] Animate windows when minimizing/maximizing')

        # Sombras debajo de los iconos del escritorio
        Set-ItemProperty -Path $advPath -Name 'ListviewShadow' -Value 0 -Type DWord
        $applied.Add('[OFF] Drop shadows under desktop icons')

        # Transparencia Glass/Acrylic (Fluent Design)
        [string] $themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $themePath)) { New-Item -Path $themePath -Force | Out-Null }
        Set-ItemProperty -Path $themePath -Name 'EnableTransparency' -Value 0 -Type DWord
        $applied.Add('[OFF] Glass/Acrylic transparency')

        # Fades y slides de menus via UserPreferencesMask.
        # Valor = "Best Performance" de sysdm.cpl. FontSmoothing y DragFullWindows
        # se gestionan por claves independientes y no son afectados por esta mascara.
        [byte[]] $mask = 0x90, 0x12, 0x01, 0x80, 0x10, 0x00, 0x00, 0x00
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'UserPreferencesMask' -Value $mask -Type Binary
        $applied.Add('[OFF] Fade/slide menus and tooltips')

        # Delay de apertura de menus: 0ms — instantaneo
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '0'
        $applied.Add('[OFF] Menu show delay (0 ms)')
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0)
        Applied = $applied.ToArray()
        Errors  = $errors.ToArray()
    }
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
        Empaqueta Set-BalancedVisuals y Set-UltimatePowerPlan en un job asincrono
        y retorna el objeto de trabajo para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param()

    [string] $fnVisualsBody   = ${Function:Set-BalancedVisuals}.ToString()
    [string] $fnPowerPlanBody = ${Function:Set-UltimatePowerPlan}.ToString()

    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Set-BalancedVisuals {
$fnVisualsBody
}
function Set-UltimatePowerPlan {
$fnPowerPlanBody
}
`$v  = Set-BalancedVisuals
`$pp = Set-UltimatePowerPlan
[PSCustomObject]@{
    Visuals   = `$v
    PowerPlan = `$pp
}
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'Performance'
}
