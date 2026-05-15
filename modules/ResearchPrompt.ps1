Set-StrictMode -Version Latest

# Captura la ruta del módulo durante el dot-sourcing para resolver paths.
[string] $script:ResearchPromptModulePath = $PSCommandPath

# ─── Templates de prompts disponibles ─────────────────────────────────────────
$script:PromptTemplates = @{
    'Optimization' = @{
        Label = 'Optimization research'
        Description = 'Investigá tweaks específicos para este hardware + use-case.'
        Question = @'
Investigá optimizaciones específicas para esta máquina. Priorizá:
1. Drivers críticos y versiones recomendadas (con foros oficiales como referencia)
2. Tweaks específicos del modelo documentados en foros del fabricante
3. Herramientas vendor-specific aplicables (nvidiaProfileInspector / Intel ARC Control / AMD Adrenalin)
4. Problemas conocidos reportados con esta configuración exacta
5. Gaps de configuración que el toolkit puede no estar cubriendo
'@
    }
    'Troubleshooting' = @{
        Label = 'Troubleshooting síntoma específico'
        Description = 'Esta PC tiene un síntoma raro; el LLM busca causas conocidas.'
        Question = @'
Esta PC presenta un síntoma específico que necesito diagnosticar. Investigá:
1. Causas conocidas para esta configuración hardware + OS exacta
2. Threads en Intel Community / AMD Community / Lenovo Forums / HP Support / Reddit del modelo específico
3. Event Viewer IDs típicos que correlacionan con este síntoma
4. Workarounds documentados con evidencia
5. Si hay algún driver o BIOS update que históricamente lo resuelve

[Descripción del síntoma completar aquí antes de mandar al LLM]
'@
    }
    'DriverAudit' = @{
        Label = 'Driver audit'
        Description = 'Qué versiones de driver son consensus-estable hoy para este hardware en este OS.'
        Question = @'
Auditá los drivers actuales de esta máquina. Para cada uno (GPU, chipset, audio, red, USB, storage):
1. ¿Es la versión actual considerada estable por foros oficiales?
2. ¿Hay una versión más nueva con bugs conocidos a evitar?
3. ¿Hay una versión más vieja que sea "punto de retorno seguro" si la actual falla?
4. ¿El fabricante publica drivers customizados (Lenovo/HP/Dell vs Intel/AMD/NVIDIA stock)?
5. Recomendá driver target con justificación.
'@
    }
    'MigrationReadiness' = @{
        Label = 'Migration readiness (Win10 -> Win11 / 23H2 -> 24H2)'
        Description = 'Si vale la pena migrar el OS en este hardware. Riesgos conocidos.'
        Question = @'
Evaluá si vale la pena migrar este hardware a una versión más nueva de Windows. Investigá:
1. Drivers actuales: ¿siguen soportados en la versión target?
2. Performance: ¿hay regresiones conocidas para esta CPU/GPU en la versión target?
3. Features que dependen de hardware (HVCI, VBS, HAGS, DirectStorage, etc.) — ¿están disponibles en este hardware?
4. Bugs reportados con la combinación hardware + OS target
5. Recomendación: migrar, no migrar, o esperar a próximo release con justificación.
'@
    }
    'Custom' = @{
        Label = 'Pregunta libre'
        Description = 'Vos completás la pregunta antes de copiar el prompt.'
        Question = @'
[Reemplazá este placeholder con tu pregunta antes de mandar el prompt al LLM]
'@
    }
}

function Get-ResearchPromptTemplates {
    <#
    .SYNOPSIS
        Lista las plantillas disponibles. Read-only. Smoke-safe.
    #>
    [CmdletBinding()]
    param()
    return @($script:PromptTemplates.Keys | ForEach-Object {
        [PSCustomObject]@{
            Key         = $_
            Label       = $script:PromptTemplates[$_].Label
            Description = $script:PromptTemplates[$_].Description
        }
    })
}

# ─── New-ResearchPrompt ───────────────────────────────────────────────────────
function New-ResearchPrompt {
    <#
    .SYNOPSIS
        Genera un prompt estructurado en Markdown a partir de un snapshot
        del sistema. El prompt se diseña para alimentar a un LLM con web
        search (Claude Deep Research, Perplexity, ChatGPT browsing) que
        investiga foros oficiales sobre esta configuración específica.

    .DESCRIPTION
        Doble persistencia: clipboard (Set-Clipboard) + archivo en
        output/research/<timestamp>.md. Default scrubbing de identificadores
        (ComputerName, dominio) salvo que se pase -IncludeIdentifiers.

    .PARAMETER Template
        Optimization | Troubleshooting | DriverAudit | MigrationReadiness | Custom

    .PARAMETER UseCase
        Free text optional (ej. "CS2 competitivo + dev con WSL2"). Incluido
        en el prompt como contexto del cliente.

    .PARAMETER Question
        Free text optional. Si se pasa, reemplaza la pregunta de la plantilla.

    .PARAMETER Snapshot
        Output de Get-SystemSnapshot. Si se omite, se invoca uno nuevo.

    .PARAMETER MachineProfile
        Output de Get-MachineProfile. Si se omite, se invoca uno nuevo.

    .PARAMETER IncludeIdentifiers
        Si se pasa, NO scrubéa ComputerName/dominio. Por default los scrubéa
        cuando el OS no es Home (asumimos máquinas Pro/Enterprise pertenecen
        a clientes que podrían ser sensibles a sharing).

    .OUTPUTS
        PSCustomObject con Success, FilePath, FileSize, ClipboardSet.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Optimization', 'Troubleshooting', 'DriverAudit', 'MigrationReadiness', 'Custom')]
        [string] $Template = 'Optimization',

        [Parameter()]
        [string] $UseCase = '',

        [Parameter()]
        [string] $Question = '',

        [Parameter()]
        [PSCustomObject] $Snapshot = $null,

        [Parameter()]
        [PSCustomObject] $MachineProfile = $null,

        [Parameter()]
        [switch] $IncludeIdentifiers
    )

    if ($null -eq $MachineProfile) { $MachineProfile = Get-MachineProfile }
    if ($null -eq $Snapshot)       { $Snapshot       = Get-SystemSnapshot -Phase Pre }

    # Privacy: scrub por default en OS no-Home; bypass via -IncludeIdentifiers.
    [bool] $scrub = (-not $IncludeIdentifiers) -and (-not $MachineProfile.IsHome)
    [string] $computerLabel = if ($scrub) { '[scrubbed]' } else { $Snapshot.ComputerName }

    # Resolver template
    $tplData = $script:PromptTemplates[$Template]
    [string] $questionFinal = if (-not [string]::IsNullOrWhiteSpace($Question)) { $Question } else { $tplData.Question }

    # Build markdown
    [System.Collections.Generic.List[string]] $L = [System.Collections.Generic.List[string]]::new()
    $L.Add('# Contexto del equipo')
    $L.Add('')
    $L.Add('## Hardware')
    $L.Add(('- **CPU**: {0}' -f $Snapshot.CPU.Name))
    $L.Add(('  - Class: {0}, Cores/Threads: {1}/{2}' -f $MachineProfile.CpuClass, $Snapshot.CPU.Cores, $Snapshot.CPU.Threads))
    $L.Add(('- **RAM**: {0:N1} GB en {1} slots @ {2} MHz' -f $Snapshot.RamTotalGb, $Snapshot.RamSlots.Count, ($Snapshot.RamSlots[0].SpeedMhz)))
    foreach ($g in $Snapshot.GPU) {
        [string] $vramTag = ''
        if ($g.Type -eq 'Dedicated' -and $MachineProfile.DGpuVramMb -gt 0) {
            $vramTag = (' — {0} GB VRAM estimada' -f [math]::Round($MachineProfile.DGpuVramMb / 1024, 1))
        }
        $L.Add(('- **GPU**: {0} [{1}{2}] driver {3}' -f $g.Name, $g.Type, $vramTag, $g.DriverVersion))
    }
    foreach ($d in $Snapshot.Disks) {
        [string] $health = if ($null -ne $d.HealthStatus) { $d.HealthStatus } else { '?' }
        $L.Add(('- **Disco**: {0} {1:N1} GB [{2}] health={3}' -f $d.Name, $d.SizeGb, $d.MediaType, $health))
    }
    $L.Add(('- **OEM**: {0}' -f $MachineProfile.Manufacturer))
    $L.Add(('- **Tier resuelto**: {0}' -f $MachineProfile.Tier))
    $L.Add(('- **Form factor**: {0}' -f $(if ($MachineProfile.IsLaptop) { 'Laptop' } else { 'Desktop' })))
    $L.Add('')

    $L.Add('## Sistema operativo')
    [string] $osName = if ($MachineProfile.IsWin11) { 'Windows 11' } else { 'Windows 10' }
    if ($MachineProfile.IsHome) { $osName = "$osName Home" } else { $osName = "$osName Pro/Enterprise" }
    $L.Add(('- {0} build {1}' -f $osName, $MachineProfile.Build))
    if ($null -ne $Snapshot.DeviceGuard) {
        $L.Add(('- VBS running: {0}  |  HVCI running: {1}' -f $Snapshot.DeviceGuard.VbsRunning, $Snapshot.DeviceGuard.HvciRunning))
    }
    if ($null -ne $Snapshot.PowerPlan -and -not [string]::IsNullOrWhiteSpace($Snapshot.PowerPlan.ActiveName)) {
        $L.Add(('- Power plan activo: {0}' -f $Snapshot.PowerPlan.ActiveName))
    }
    $L.Add('')

    $L.Add('## Estado actual relevante')
    $L.Add(('- Servicios en ejecución: {0}' -f $Snapshot.Services.RunningCount))
    if ($Snapshot.Services.BloatRunning.Count -gt 0) {
        $L.Add(('- Servicios bloat corriendo: {0}' -f ($Snapshot.Services.BloatRunning -join ', ')))
    }
    $L.Add(('- Entradas de inicio: {0}' -f $Snapshot.StartupCount))
    $L.Add(('- Uptime: {0:N1} horas' -f $Snapshot.UptimeHours))
    if ($null -ne $Snapshot.CpuTempC) { $L.Add(('- Temperatura CPU: {0} C' -f $Snapshot.CpuTempC)) }

    foreach ($av in $Snapshot.Antivirus) {
        [string] $tag = if ($av.IsNative) { 'native' } else { '3rd-party' }
        [string] $mode = if (-not [string]::IsNullOrEmpty($av.AMRunningMode)) { (' [' + $av.AMRunningMode + ']') } else { '' }
        $L.Add(('- AV: {0} [{1}]  active={2}{3}' -f $av.Name, $tag, $av.IsActive, $mode))
    }

    # BSOD history NO se incluye automáticamente (es un dataset separado del snapshot).
    # El LLM puede pedir contexto adicional si la pregunta lo requiere.
    $L.Add('')

    if ($null -ne $Snapshot.Steam -and $Snapshot.Steam.Installed -and $Snapshot.Steam.Cs2Installed) {
        $L.Add('## Steam / CS2')
        $L.Add(('- CS2 instalado en: {0}' -f $Snapshot.Steam.Cs2Path))
        if (-not [string]::IsNullOrWhiteSpace($Snapshot.Steam.Cs2LaunchOptions)) {
            $L.Add(('- Launch options: `{0}`' -f $Snapshot.Steam.Cs2LaunchOptions))
        }
        if ($Snapshot.Steam.AutoexecLines.Count -gt 0) {
            $L.Add('- autoexec.cfg:')
            $L.Add('  ```')
            foreach ($a in $Snapshot.Steam.AutoexecLines) { $L.Add(('  ' + $a)) }
            $L.Add('  ```')
        }
        $L.Add('')
    }

    if (-not [string]::IsNullOrWhiteSpace($UseCase)) {
        $L.Add('## Use-case del cliente')
        $L.Add($UseCase)
        $L.Add('')
    }

    $L.Add('---')
    $L.Add('')
    $L.Add('# Pregunta')
    $L.Add('')
    $L.Add($questionFinal)
    $L.Add('')
    $L.Add('# Formato de respuesta esperado')
    $L.Add('')
    $L.Add('- Recomendaciones accionables con: qué tocar, dónde, valor objetivo, riesgo.')
    $L.Add('- Citá foros (URL) cuando uses evidencia externa.')
    $L.Add('- Distinguí consenso vs especulación de comunidad.')
    $L.Add('- Si hay tweaks que requieren herramientas que no menciono en el contexto, listalos como "candidatas para sumar al toolkit".')
    $L.Add('')
    $L.Add('---')
    $L.Add(('_Generated by PCTk v2 ResearchPrompt at {0} for host {1}_' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $computerLabel))

    [string] $promptText = [string] ($L -join "`r`n")

    # Persistencia: archivo + clipboard
    [string] $toolkitRoot = Split-Path (Split-Path $script:ResearchPromptModulePath -Parent) -Parent
    [string] $outDir = Join-Path $toolkitRoot 'output\research'
    if (-not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }

    [string] $stamp = (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    [string] $fileName = ('prompt_{0}_{1}.md' -f $Template.ToLowerInvariant(), $stamp)
    [string] $filePath = Join-Path $outDir $fileName

    # UTF-8 con BOM para que Notepad / VS Code rendereen tildes y em-dashes correctamente
    [System.IO.File]::WriteAllText($filePath, $promptText, [System.Text.UTF8Encoding]::new($true))

    [bool] $clipboardSet = $false
    try {
        Set-Clipboard -Value $promptText -ErrorAction Stop
        $clipboardSet = $true
    } catch { }

    return [PSCustomObject]@{
        Success      = $true
        FilePath     = $filePath
        FileName     = $fileName
        FileSize     = (Get-Item -LiteralPath $filePath).Length
        ClipboardSet = $clipboardSet
        Scrubbed     = $scrub
        Template     = $Template
    }
}
