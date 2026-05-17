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

# ─── Internal helper: safe PSObject property accessor ─────────────────────────
# Devuelve $p.Value si la propiedad existe en $Obj; $Default si no (o si $Obj es $null).
function _Rp_Prop {
    param([object] $Obj, [string] $Name, [object] $Default = 'N/A')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
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
    [bool] $isHome = $false
    if ($MachineProfile.PSObject.Properties['IsHome'] -and $null -ne $MachineProfile.IsHome) {
        $isHome = [bool] $MachineProfile.IsHome
    }
    [bool] $scrub = (-not $IncludeIdentifiers) -and (-not $isHome)
    [string] $computerLabel = if ($scrub) { '[scrubbed]' } else {
        [string] (_Rp_Prop $Snapshot 'ComputerName' '[unknown]')
    }

    # Resolver template
    $tplData = $script:PromptTemplates[$Template]
    [string] $questionFinal = if (-not [string]::IsNullOrWhiteSpace($Question)) { $Question } else { $tplData.Question }

    # Build markdown
    [System.Collections.Generic.List[string]] $L = [System.Collections.Generic.List[string]]::new()
    $L.Add('# Contexto del equipo')
    $L.Add('')
    $L.Add('## Hardware')

    # CPU — guardar el sub-objeto antes de acceder propiedades anidadas
    $cpuObjProp = $Snapshot.PSObject.Properties['CPU']
    $cpuObj = if ($null -ne $cpuObjProp) { $cpuObjProp.Value } else { $null }
    [string] $cpuName    = [string] (_Rp_Prop $cpuObj 'Name'    'N/A')
    [string] $cpuCores   = [string] (_Rp_Prop $cpuObj 'Cores'   '?')
    [string] $cpuThreads = [string] (_Rp_Prop $cpuObj 'Threads' '?')
    [string] $cpuClass   = if ($MachineProfile.PSObject.Properties['CpuClass']) { [string] $MachineProfile.CpuClass } else { 'N/A' }
    $L.Add(('- **CPU**: {0}' -f $cpuName))
    $L.Add(('  - Class: {0}, Cores/Threads: {1}/{2}' -f $cpuClass, $cpuCores, $cpuThreads))

    # RAM
    [string] $ramTotal = if ($Snapshot.PSObject.Properties['RamTotalGb'] -and $null -ne $Snapshot.RamTotalGb) {
        ('{0:N1}' -f [double] $Snapshot.RamTotalGb)
    } else { 'N/A' }
    $slotsProp = $Snapshot.PSObject.Properties['RamSlots']
    $slotsArr  = if ($null -ne $slotsProp -and $null -ne $slotsProp.Value) { @($slotsProp.Value) } else { $null }
    [string] $slotsCount = if ($null -ne $slotsArr) { [string] $slotsArr.Count } else { '?' }
    [string] $speedMhz   = '?'
    if ($null -ne $slotsArr -and $slotsArr.Count -gt 0) {
        $sp = $slotsArr[0].PSObject.Properties['SpeedMhz']
        if ($null -ne $sp) { $speedMhz = [string] $sp.Value }
    }
    $L.Add(('- **RAM**: {0} GB en {1} slots @ {2} MHz' -f $ramTotal, $slotsCount, $speedMhz))

    # GPU
    $gpusProp = $Snapshot.PSObject.Properties['GPU']
    if ($null -ne $gpusProp -and $null -ne $gpusProp.Value -and @($gpusProp.Value).Count -gt 0) {
        foreach ($g in @($gpusProp.Value)) {
            [string] $gType   = [string] (_Rp_Prop $g 'Type'          '')
            [string] $gName   = [string] (_Rp_Prop $g 'Name'          'N/A')
            [string] $gDriver = [string] (_Rp_Prop $g 'DriverVersion' '?')
            [string] $vramTag = ''
            if ($gType -eq 'Dedicated' -and
                $MachineProfile.PSObject.Properties['DGpuVramMb'] -and
                $null -ne $MachineProfile.DGpuVramMb -and
                $MachineProfile.DGpuVramMb -gt 0) {
                $vramTag = (' — {0} GB VRAM estimada' -f [math]::Round($MachineProfile.DGpuVramMb / 1024, 1))
            }
            $L.Add(('- **GPU**: {0} [{1}{2}] driver {3}' -f $gName, $gType, $vramTag, $gDriver))
        }
    }

    # Disks
    $disksProp = $Snapshot.PSObject.Properties['Disks']
    if ($null -ne $disksProp -and $null -ne $disksProp.Value -and @($disksProp.Value).Count -gt 0) {
        foreach ($d in @($disksProp.Value)) {
            [string] $dName   = [string] (_Rp_Prop $d 'Name'      'N/A')
            [double] $dSize   = if ($d.PSObject.Properties['SizeGb'] -and $null -ne $d.SizeGb) { [double] $d.SizeGb } else { 0 }
            [string] $dMedia  = [string] (_Rp_Prop $d 'MediaType' '?')
            [string] $dHealth = if ($d.PSObject.Properties['HealthStatus'] -and $null -ne $d.HealthStatus) { [string] $d.HealthStatus } else { '?' }
            $L.Add(('- **Disco**: {0} {1:N1} GB [{2}] health={3}' -f $dName, $dSize, $dMedia, $dHealth))
        }
    }

    # OEM / Tier / Form factor
    [string] $manufacturer = if ($MachineProfile.PSObject.Properties['Manufacturer'] -and
                                  -not [string]::IsNullOrWhiteSpace([string] $MachineProfile.Manufacturer)) {
        [string] $MachineProfile.Manufacturer
    } else { 'Unknown' }
    [string] $tier     = if ($MachineProfile.PSObject.Properties['Tier'])     { [string] $MachineProfile.Tier }     else { 'N/A' }
    [bool]   $isLaptop = if ($MachineProfile.PSObject.Properties['IsLaptop'] -and $null -ne $MachineProfile.IsLaptop) { [bool] $MachineProfile.IsLaptop } else { $false }
    $L.Add(('- **OEM**: {0}' -f $manufacturer))
    $L.Add(('- **Tier resuelto**: {0}' -f $tier))
    $L.Add(('- **Form factor**: {0}' -f $(if ($isLaptop) { 'Laptop' } else { 'Desktop' })))
    $L.Add('')

    $L.Add('## Sistema operativo')
    [bool] $isWin11 = if ($MachineProfile.PSObject.Properties['IsWin11'] -and $null -ne $MachineProfile.IsWin11) { [bool] $MachineProfile.IsWin11 } else { $false }
    [string] $osName = if ($isWin11) { 'Windows 11' } else { 'Windows 10' }
    if ($isHome) { $osName = "$osName Home" } else { $osName = "$osName Pro/Enterprise" }
    [string] $build = if ($MachineProfile.PSObject.Properties['Build'] -and $null -ne $MachineProfile.Build) { [string] $MachineProfile.Build } else { 'N/A' }
    $L.Add(('- {0} build {1}' -f $osName, $build))

    # DeviceGuard — la prop puede no existir; el null-check de la prop misma ya tira bajo StrictMode
    $dgProp = $Snapshot.PSObject.Properties['DeviceGuard']
    if ($null -ne $dgProp -and $null -ne $dgProp.Value) {
        $dg = $dgProp.Value
        $L.Add(('- VBS running: {0}  |  HVCI running: {1}' -f ([string] (_Rp_Prop $dg 'VbsRunning' '?')), ([string] (_Rp_Prop $dg 'HvciRunning' '?'))))
    }

    # PowerPlan — mismo patrón
    $ppProp = $Snapshot.PSObject.Properties['PowerPlan']
    if ($null -ne $ppProp -and $null -ne $ppProp.Value) {
        $pp = $ppProp.Value
        $anProp = $pp.PSObject.Properties['ActiveName']
        if ($null -ne $anProp -and -not [string]::IsNullOrWhiteSpace([string] $anProp.Value)) {
            $L.Add(('- Power plan activo: {0}' -f [string] $anProp.Value))
        }
    }
    $L.Add('')

    $L.Add('## Estado actual relevante')

    # Services
    $svcProp = $Snapshot.PSObject.Properties['Services']
    if ($null -ne $svcProp -and $null -ne $svcProp.Value) {
        $svc = $svcProp.Value
        [string] $runCount = if ($svc.PSObject.Properties['RunningCount'] -and $null -ne $svc.RunningCount) { [string] $svc.RunningCount } else { 'N/A' }
        $L.Add(('- Servicios en ejecución: {0}' -f $runCount))
        $bloatProp = $svc.PSObject.Properties['BloatRunning']
        if ($null -ne $bloatProp -and $null -ne $bloatProp.Value -and @($bloatProp.Value).Count -gt 0) {
            $L.Add(('- Servicios bloat corriendo: {0}' -f (@($bloatProp.Value) -join ', ')))
        }
    } else {
        $L.Add('- Servicios en ejecución: N/A')
    }

    [string] $startupStr = if ($Snapshot.PSObject.Properties['StartupCount'] -and $null -ne $Snapshot.StartupCount) { [string] $Snapshot.StartupCount } else { 'N/A' }
    [string] $uptimeStr  = if ($Snapshot.PSObject.Properties['UptimeHours']  -and $null -ne $Snapshot.UptimeHours)  { ('{0:N1}' -f [double] $Snapshot.UptimeHours) } else { 'N/A' }
    $L.Add(('- Entradas de inicio: {0}' -f $startupStr))
    $L.Add(('- Uptime: {0} horas' -f $uptimeStr))

    # CpuTempC — acceso directo tira bajo StrictMode si la prop no existe
    $tempProp = $Snapshot.PSObject.Properties['CpuTempC']
    if ($null -ne $tempProp -and $null -ne $tempProp.Value) { $L.Add(('- Temperatura CPU: {0} C' -f $tempProp.Value)) }

    # Antivirus
    $avProp = $Snapshot.PSObject.Properties['Antivirus']
    if ($null -ne $avProp -and $null -ne $avProp.Value) {
        foreach ($av in @($avProp.Value)) {
            [bool]   $avNative  = if ($av.PSObject.Properties['IsNative'] -and $null -ne $av.IsNative) { [bool] $av.IsNative } else { $false }
            [string] $tag       = if ($avNative) { 'native' } else { '3rd-party' }
            [string] $avModeVal = [string] (_Rp_Prop $av 'AMRunningMode' '')
            [string] $avMode    = if (-not [string]::IsNullOrEmpty($avModeVal)) { (' [' + $avModeVal + ']') } else { '' }
            [string] $avName    = [string] (_Rp_Prop $av 'Name'     'N/A')
            [string] $avActive  = [string] (_Rp_Prop $av 'IsActive' '?')
            $L.Add(('- AV: {0} [{1}]  active={2}{3}' -f $avName, $tag, $avActive, $avMode))
        }
    }

    # BSOD history NO se incluye automáticamente (es un dataset separado del snapshot).
    # El LLM puede pedir contexto adicional si la pregunta lo requiere.
    $L.Add('')

    # Steam / CS2
    $steamProp = $Snapshot.PSObject.Properties['Steam']
    if ($null -ne $steamProp -and $null -ne $steamProp.Value) {
        $steam       = $steamProp.Value
        $stInstProp  = $steam.PSObject.Properties['Installed']
        $cs2InstProp = $steam.PSObject.Properties['Cs2Installed']
        if ($null -ne $stInstProp  -and [bool] $stInstProp.Value -and
            $null -ne $cs2InstProp -and [bool] $cs2InstProp.Value) {
            $L.Add('## Steam / CS2')
            $L.Add(('- CS2 instalado en: {0}' -f [string] (_Rp_Prop $steam 'Cs2Path' 'N/A')))
            $cs2LocProp = $steam.PSObject.Properties['Cs2LaunchOptions']
            if ($null -ne $cs2LocProp -and -not [string]::IsNullOrWhiteSpace([string] $cs2LocProp.Value)) {
                $L.Add(('- Launch options: `{0}`' -f [string] $cs2LocProp.Value))
            }
            $autoExecProp = $steam.PSObject.Properties['AutoexecLines']
            if ($null -ne $autoExecProp -and $null -ne $autoExecProp.Value -and @($autoExecProp.Value).Count -gt 0) {
                $L.Add('- autoexec.cfg:')
                $L.Add('  ```')
                foreach ($a in @($autoExecProp.Value)) { $L.Add(('  ' + $a)) }
                $L.Add('  ```')
            }
            $L.Add('')
        }
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
