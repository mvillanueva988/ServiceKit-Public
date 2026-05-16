Set-StrictMode -Version Latest

# ─── Get-AutoProfilePath ──────────────────────────────────────────────────────
function Get-AutoProfilePath {
    <#
    .SYNOPSIS
        Retorna la ruta absoluta al JSON de receta para un use-case y tier dados.
        No valida existencia — el caller decide si el archivo existe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $UseCase,
        [Parameter(Mandatory)] [ValidateSet('Low','Mid','High')] [string] $Tier
    )

    [string] $dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\profiles\auto'
    return Join-Path $dataDir ('{0}_{1}.json' -f $UseCase.ToLowerInvariant(), $Tier.ToLowerInvariant())
}

# ─── Test-AutoProfileSchema ───────────────────────────────────────────────────
function Test-AutoProfileSchema {
    <#
    .SYNOPSIS
        Valida la estructura minima de una receta parseada. Retorna $true o lanza.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile
    )

    # _schema_version
    [object] $sv = $Profile.PSObject.Properties['_schema_version']
    if ($null -eq $sv -or ([string]$sv.Value) -ne '1.0') {
        throw "_schema_version debe ser '1.0'. Valor encontrado: '$($sv.Value)'."
    }

    # _use_case
    [object] $uc = $Profile.PSObject.Properties['_use_case']
    if ($null -eq $uc -or [string]::IsNullOrWhiteSpace([string]$uc.Value)) {
        throw '_use_case no puede estar vacio.'
    }

    # _tier
    [object] $tierProp = $Profile.PSObject.Properties['_tier']
    if ($null -eq $tierProp -or ([string]$tierProp.Value).ToLowerInvariant() -notin @('low','mid','high')) {
        [string] $got = if ($null -ne $tierProp) { [string]$tierProp.Value } else { '(ausente)' }
        throw "_tier debe ser low, mid o high. Valor: '$got'."
    }

    # services.disable
    [object] $svcsProp = $Profile.PSObject.Properties['services']
    if ($null -eq $svcsProp) { throw 'Falta bloque services.' }
    [object] $disableProp = $svcsProp.Value.PSObject.Properties['disable']
    if ($null -eq $disableProp) { throw 'Falta services.disable.' }

    # performance.visual_profile
    [object] $perfProp = $Profile.PSObject.Properties['performance']
    if ($null -eq $perfProp) { throw 'Falta bloque performance.' }
    [object] $vpProp = $perfProp.Value.PSObject.Properties['visual_profile']
    if ($null -eq $vpProp -or ([string]$vpProp.Value) -notin @('Balanced','Full','Restore','TweaksOnly')) {
        [string] $got = if ($null -ne $vpProp) { [string]$vpProp.Value } else { '(ausente)' }
        throw "performance.visual_profile invalido: '$got'."
    }

    # privacy.level
    [object] $privProp = $Profile.PSObject.Properties['privacy']
    if ($null -eq $privProp) { throw 'Falta bloque privacy.' }
    [object] $lvlProp = $privProp.Value.PSObject.Properties['level']
    if ($null -eq $lvlProp -or [string]::IsNullOrWhiteSpace([string]$lvlProp.Value)) {
        throw 'privacy.level es requerido.'
    }

    return $true
}

# ─── Import-AutoProfile ───────────────────────────────────────────────────────
function Import-AutoProfile {
    <#
    .SYNOPSIS
        Lee y valida una receta JSON. Lanza con mensaje claro si falta/corrupta/invalida.
        NUNCA aplica nada — solo carga.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Receta no encontrada: '$Path'. Verificar que el archivo exista en data/profiles/auto/."
    }

    [PSCustomObject] $profile = $null
    try {
        $profile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "No se pudo parsear la receta '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $profile) {
        throw "La receta '$Path' resulto en un objeto nulo al parsear."
    }

    $null = Test-AutoProfileSchema -Profile $profile
    return $profile
}

# ─── Get-AutoProfilePreviewLines ──────────────────────────────────────────────
function Get-AutoProfilePreviewLines {
    <#
    .SYNOPSIS
        Retorna lineas legibles para Confirm-Action mostrando que aplicara la receta.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()

    [string] $recipeTier   = ([string]$Profile._tier).ToUpperInvariant()
    [string] $detectedTier = 'N/A'
    [object] $tierProp = $MachineProfile.PSObject.Properties['Tier']
    if ($null -ne $tierProp) { $detectedTier = [string]$tierProp.Value }

    if ($recipeTier -ne $detectedTier.ToUpperInvariant()) {
        $lines.Add("[AVISO] Tier detectado: $detectedTier | Tier de receta: $recipeTier")
    } else {
        $lines.Add("Tier: $detectedTier")
    }

    [string[]] $svcs = @($Profile.services.disable)
    $lines.Add("Servicios a deshabilitar: $($svcs.Count) ($($svcs -join ', '))")
    $lines.Add("Visual: $($Profile.performance.visual_profile)")

    [string] $privLevel = [string]$Profile.privacy.level
    [string] $oosuCfg   = ''
    [object] $oosuProp  = $Profile.privacy.PSObject.Properties['oosu10_cfg']
    if ($null -ne $oosuProp) { $oosuCfg = [string]$oosuProp.Value }

    [bool] $useOosu = $false
    if (-not [string]::IsNullOrWhiteSpace($oosuCfg)) {
        [string] $cfgPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\oosu10-profiles') $oosuCfg
        $useOosu = (Test-ShutUp10Available) -and (Test-Path $cfgPath)
    }
    [string] $privRoute = if ($useOosu) { "OOSU10 ($oosuCfg)" } else { "nativo ($privLevel)" }
    $lines.Add("Privacy: $privRoute")

    [bool] $cleanupEnabled = $false
    [object] $cleanupProp = $Profile.PSObject.Properties['cleanup']
    if ($null -ne $cleanupProp) {
        [object] $ctProp = $cleanupProp.Value.PSObject.Properties['clear_temp']
        if ($null -ne $ctProp -and $ctProp.Value -eq $true) { $cleanupEnabled = $true }
    }
    $lines.Add("Limpieza de temporales: $(if ($cleanupEnabled) { 'si' } else { 'no' })")
    $lines.Add("Startup: solo reporte (no se desactiva nada automaticamente)")
    $lines.Add("Restore Point: automatico (Enter en el proximo paso para confirmar)")

    return $lines.ToArray()
}

# ─── Invoke-ProfilePerformanceStep ───────────────────────────────────────────
function Invoke-ProfilePerformanceStep {
    <#
    .SYNOPSIS
        Seam D1: hoy = Start-PerformanceProcess -VisualProfile. Retorna un Job.
        Cuando exista un entrypoint granular, esta funcion es el unico punto a cambiar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    $null = $MachineProfile
    [string] $vp = [string]$Profile.performance.visual_profile
    return Start-PerformanceProcess -VisualProfile $vp
}

# ─── Invoke-ProfilePrivacyStep ────────────────────────────────────────────────
function Invoke-ProfilePrivacyStep {
    <#
    .SYNOPSIS
        Aplica el paso de privacy segun la receta. Si OOSU10 + .cfg disponibles,
        usa Invoke-OOSU10Profile (sincronico). Si no, cae a Start-PrivacyJob nativo.
        Retorna objeto uniforme { Path; Success; Detail }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile
    )

    [string] $level   = [string]$Profile.privacy.level
    [string] $oosuCfg = ''
    [object] $oosuProp = $Profile.privacy.PSObject.Properties['oosu10_cfg']
    if ($null -ne $oosuProp) { $oosuCfg = [string]$oosuProp.Value }

    # Decidir rama OOSU10 o nativo
    [bool]   $useOosu = $false
    [string] $cfgPath = ''
    if (-not [string]::IsNullOrWhiteSpace($oosuCfg)) {
        $cfgPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\oosu10-profiles') $oosuCfg
        $useOosu = (Test-ShutUp10Available) -and (Test-Path $cfgPath)
    }

    if ($useOosu) {
        Write-Host ('  Privacy via OOSU10 ({0})...' -f $oosuCfg) -ForegroundColor Cyan
        $r = Invoke-OOSU10Profile -Path $cfgPath
        return [PSCustomObject]@{ Path = 'oosu10'; Success = $r.Success; Detail = $r }
    }

    # Nativo: mapear level -> perfil de Invoke-PrivacyTweaks
    [string] $psLevel = switch ($level.ToLowerInvariant()) {
        'medium'     { 'Medium'     }
        'aggressive' { 'Aggressive' }
        default      { 'Basic'      }
    }
    Write-Host ('  Privacy via nativo: perfil {0}...' -f $psLevel) -ForegroundColor Cyan
    $privJob     = Start-PrivacyJob -Profile $psLevel
    $privResults = Wait-ToolkitJobs -Jobs @($privJob) -TimeoutSeconds 120
    $privRaw     = if ($privResults.Count -gt 0) { $privResults[0] } else { $null }

    [bool] $ok = $false
    if ($null -ne $privRaw) {
        [object] $errProp = $privRaw.PSObject.Properties['Errors']
        $ok = ($null -eq $errProp) -or (@($errProp.Value).Count -eq 0)
    }
    return [PSCustomObject]@{ Path = 'native'; Success = $ok; Detail = $privRaw }
}

# ─── Invoke-AutoProfile ───────────────────────────────────────────────────────
function Invoke-AutoProfile {
    <#
    .SYNOPSIS
        Orquesta el pipeline completo: RP -> PRE -> batch(Debloat+Cleanup+Perf)
        -> Privacy -> POST -> Compare -> ClientFolder -> Startup -> Audit -> result.
        NO imprime el menu ni pide el Confirm inicial — eso es responsabilidad del Router.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile,
        [Parameter()] [switch] $SkipRestorePoint,
        [Parameter()] [string] $ClientSlug = '',
        # Headless/batch (reaplicar receta nombrada — Stage 4): si la creacion de
        # Restore Point falla DURO, NO prompts; continua sin RP (logueado). Default
        # (sin el switch) mantiene el Confirm-Action interactivo. Es el unico
        # prompt interno de Invoke-AutoProfile; el resto vive en el handler Router.
        [Parameter()] [switch] $Unattended,
        # Stage 4: cuando Invoke-NamedProfile envuelve esta funcion, suprime la
        # entrada de audit interna para escribir UNA sola consolidada (con
        # gaming_tweaks). Sin el switch = audita normal (invariante intacto).
        [Parameter()] [switch] $NoAudit
    )

    [datetime] $startedAt = Get-Date
    [string]   $useCase   = [string]$Profile._use_case
    [string]   $tier      = [string]$Profile._tier
    [string] $tierNorm = switch ($tier.ToLowerInvariant()) {
        'low'  { 'Low'  }
        'high' { 'High' }
        default { 'Mid' }
    }
    [string]   $profPath  = Get-AutoProfilePath -UseCase $useCase -Tier $tierNorm
    [string]   $schemaVer = [string]$Profile._schema_version

    # Valores iniciales del result (se sobreescriben a medida que el pipeline avanza)
    [PSCustomObject] $rpResult   = [PSCustomObject]@{ Done = $false; Skipped = $false; CooldownActive = $false; Message = '' }
    [PSCustomObject] $preSnap    = [PSCustomObject]@{ Ok = $false; FileName = ''; FilePath = '' }
    [PSCustomObject] $postSnap   = [PSCustomObject]@{ Ok = $false; FileName = ''; FilePath = '' }
    [object]         $debloatR   = $null
    [object]         $cleanupR   = $null
    [object]         $perfR      = $null
    [PSCustomObject] $privResult = [PSCustomObject]@{ Path = 'none'; Success = $false; Detail = '' }
    [object]         $compareR   = $null
    [PSCustomObject] $startupR   = [PSCustomObject]@{ Count = 0; ReportedOnly = $true }
    [PSCustomObject] $clientRun  = [PSCustomObject]@{ Slug = $ClientSlug; Dir = ''; ReportPath = ''; MetaPath = ''; WriteError = '' }
    [string]         $overallStatus = 'Failed'

    # ── 1. Restore Point ──────────────────────────────────────────────────────
    if ($SkipRestorePoint) {
        $rpResult = [PSCustomObject]@{ Done = $false; Skipped = $true; CooldownActive = $false; Message = 'Omitido por operador (-SkipRestorePoint)' }
        Write-Host '  [i] Restore Point omitido.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Creando Restore Point...' -ForegroundColor Cyan
        $rpJob     = Start-RestorePointProcess
        $rpArr     = Wait-ToolkitJobs -Jobs @($rpJob) -TimeoutSeconds 120
        $rpRaw     = if ($rpArr.Count -gt 0) { $rpArr[0] } else { $null }

        if ($null -ne $rpRaw -and $rpRaw.PSObject.Properties['Success'] -and $rpRaw.Success) {
            $rpResult = [PSCustomObject]@{ Done = $true; Skipped = $false; CooldownActive = $false; Message = [string]$rpRaw.Message }
            Write-Host '  [OK] Restore Point creado.' -ForegroundColor Green
        }
        elseif ($null -ne $rpRaw -and $rpRaw.PSObject.Properties['CooldownActive'] -and $rpRaw.CooldownActive) {
            $rpResult = [PSCustomObject]@{
                Done          = $false
                Skipped       = $false
                CooldownActive = $true
                LatestRp      = $rpRaw.LatestRp
                Message       = [string]$rpRaw.Reason
            }
            Write-Host ('  [i] RP cooldown activo — hay un RP reciente como ancla. {0}' -f $rpRaw.Reason) -ForegroundColor Yellow
        }
        else {
            # Falla dura: System Restore deshabilitado o error
            [string] $failMsg = if ($null -ne $rpRaw -and $rpRaw.PSObject.Properties['Message']) { [string]$rpRaw.Message } else { 'No se pudo crear el Restore Point.' }
            Write-Host ("  [!] Restore Point fallo: $failMsg") -ForegroundColor Red
            [bool] $continuar = if ($Unattended) {
                Write-Host '  [i] -Unattended: continuando sin Restore Point (sin prompt).' -ForegroundColor DarkYellow
                $true
            } else {
                Confirm-Action `
                    -Title 'Continuar sin Restore Point?' `
                    -Lines @(
                        'No se pudo crear un punto de restauracion del sistema.',
                        'Si continuas y algo sale mal, no habra ancla de reversion automatica.',
                        'Recomendado: cancelar y verificar que System Restore este habilitado.'
                    ) `
                    -DefaultYes:$false
            }

            if (-not $continuar) {
                $rpResult = [PSCustomObject]@{ Done = $false; Skipped = $false; CooldownActive = $false; Message = "Abortado por operador. RP error: $failMsg" }
                [datetime] $endedAt0 = Get-Date
                return [PSCustomObject]@{
                    UseCase = $useCase; Tier = $tier; ProfilePath = $profPath; SchemaVersion = $schemaVer
                    RestorePoint = $rpResult; PreSnapshot = $preSnap; Debloat = $null; Cleanup = $null
                    Performance = $null; Privacy = $privResult; PostSnapshot = $postSnap; Compare = $null
                    Startup = $startupR; Status = 'Failed'; StartedAt = $startedAt; EndedAt = $endedAt0
                    DurationSec = [math]::Round(($endedAt0 - $startedAt).TotalSeconds)
                    ClientRun = $clientRun
                }
            }
            $rpResult = [PSCustomObject]@{ Done = $false; Skipped = $false; CooldownActive = $false; Message = "Continuado sin RP. RP error: $failMsg" }
        }
    }

    # ── 2. Snapshot PRE ───────────────────────────────────────────────────────
    Write-Host '  Capturando snapshot PRE...' -ForegroundColor Cyan
    $preJob  = Start-TelemetryJob -Phase Pre
    $preArr  = Wait-ToolkitJobs -Jobs @($preJob) -TimeoutSeconds 90
    $preRaw  = if ($preArr.Count -gt 0) { $preArr[0] } else { $null }
    if ($null -ne $preRaw -and $preRaw.PSObject.Properties['FileName'] -and -not [string]::IsNullOrWhiteSpace([string]$preRaw.FileName)) {
        $preSnap = [PSCustomObject]@{ Ok = $true; FileName = [string]$preRaw.FileName; FilePath = [string]$preRaw.FilePath }
        Write-Host ('  [OK] Snapshot PRE: {0}' -f $preRaw.FileName) -ForegroundColor Green
    } else {
        Write-Host '  [!] Snapshot PRE no disponible (timeout o error). Continuando sin el.' -ForegroundColor Yellow
    }

    # ── 3. Batch de mutacion (Debloat + Cleanup + Performance en paralelo) ────
    Write-Host '  Aplicando perfil: Debloat / Limpieza / Performance (en paralelo)...' -ForegroundColor Cyan
    [string[]] $svcList = @($Profile.services.disable)
    $jobDebloat  = Start-DebloatProcess -ServicesList $svcList
    $jobCleanup  = Start-CleanupProcess
    $jobPerf     = Invoke-ProfilePerformanceStep -Profile $Profile -MachineProfile $MachineProfile

    $batchArr = Wait-ToolkitJobs -Jobs @($jobDebloat, $jobCleanup, $jobPerf) -TimeoutSeconds 600
    $debloatR = if ($batchArr.Count -gt 0) { $batchArr[0] } else { $null }
    $cleanupR = if ($batchArr.Count -gt 1) { $batchArr[1] } else { $null }
    $perfR    = if ($batchArr.Count -gt 2) { $batchArr[2] } else { $null }

    # ── 3b. Privacy (sincronico, despues del batch) ───────────────────────────
    try {
        $privResult = Invoke-ProfilePrivacyStep -Profile $Profile
    } catch {
        $privResult = [PSCustomObject]@{ Path = 'error'; Success = $false; Detail = $_.Exception.Message }
        Write-Host ('  [!] Privacy fallo: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }

    # ── Determinar status (lo necesitamos antes del ClientFolder) ─────────────
    [int] $jobsFailed = 0
    if ($null -eq $debloatR) { $jobsFailed++ }
    if ($null -eq $cleanupR) { $jobsFailed++ }
    if ($null -eq $perfR)    { $jobsFailed++ }
    if (-not $privResult.Success) { $jobsFailed++ }

    $overallStatus = if ($jobsFailed -eq 0) { 'Success' } elseif ($jobsFailed -lt 4) { 'Partial' } else { 'Failed' }

    # ── 4. Snapshot POST ──────────────────────────────────────────────────────
    Write-Host '  Capturando snapshot POST...' -ForegroundColor Cyan
    $postJob = Start-TelemetryJob -Phase Post
    $postArr = Wait-ToolkitJobs -Jobs @($postJob) -TimeoutSeconds 90
    $postRaw = if ($postArr.Count -gt 0) { $postArr[0] } else { $null }
    if ($null -ne $postRaw -and $postRaw.PSObject.Properties['FileName'] -and -not [string]::IsNullOrWhiteSpace([string]$postRaw.FileName)) {
        $postSnap = [PSCustomObject]@{ Ok = $true; FileName = [string]$postRaw.FileName; FilePath = [string]$postRaw.FilePath }
        Write-Host ('  [OK] Snapshot POST: {0}' -f $postRaw.FileName) -ForegroundColor Green
    } else {
        Write-Host '  [!] Snapshot POST no disponible.' -ForegroundColor Yellow
    }

    # ── 5. Compare + Show ─────────────────────────────────────────────────────
    if ($preSnap.Ok -and $postSnap.Ok) {
        try {
            $compareR = Compare-Snapshot -PrePath $preSnap.FilePath -PostPath $postSnap.FilePath
            Show-SnapshotComparison -Diff $compareR
        } catch {
            Write-Host ('  [!] Comparacion no disponible: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        Write-Host '  [i] Compare omitido (snapshot PRE o POST no disponible).' -ForegroundColor DarkGray
    }

    # ── 5b. Carpeta de run por cliente ────────────────────────────────────────
    [string] $compareScore = if ($null -ne $compareR) {
        "$($compareR.Score)/$($compareR.ScoreMax)"
    } else { 'N/A' }

    try {
        [string] $ts       = $startedAt.ToString('yyyy-MM-dd_HHmmss')
        [string] $runSlug  = if ([string]::IsNullOrWhiteSpace($ClientSlug)) {
            'cliente-' + $env:COMPUTERNAME.ToLowerInvariant()
        } else { $ClientSlug }

        [string] $clientsBase = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\clients'
        [string] $runDir      = Join-Path $clientsBase ('{0}_{1}' -f $runSlug, $ts)
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        # meta.json
        [string] $metaPath = Join-Path $runDir 'meta.json'
        $metaObj = [ordered]@{
            client             = $runSlug
            date               = $startedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
            computer_name      = $env:COMPUTERNAME
            anydesk_id         = $null
            tier               = $tier
            use_case           = $useCase
            schema_version     = $schemaVer
            compare_score      = $compareScore
            status             = $overallStatus
            amount_charged_ars = $null
            notes              = ''
        }
        ($metaObj | ConvertTo-Json -Depth 4) | Out-File -FilePath $metaPath -Encoding UTF8

        # run-report.txt
        [string] $reportPath = Join-Path $runDir 'run-report.txt'
        [string] $debloatLine = if ($null -ne $debloatR -and $debloatR.PSObject.Properties['Disabled']) {
            "$($debloatR.Disabled)/$($debloatR.TotalTargeted) servicios deshabilitados"
        } else { 'no disponible' }
        [string] $cleanupLine = if ($null -ne $cleanupR -and $cleanupR.PSObject.Properties['FreedGB']) {
            "$($cleanupR.FreedGB) GB liberados"
        } else { 'no disponible' }
        [string] $perfLine = if ($null -ne $perfR) { 'OK' } else { 'no disponible' }
        [string] $privLine = "$($privResult.Path) - $(if ($privResult.Success) { 'OK' } else { 'error' })"
        [string] $approxDur = [math]::Round((([datetime]::Now) - $startedAt).TotalSeconds).ToString()

        @(
            '=== PCTk v2 - Run Report ==='
            "Cliente    : $runSlug"
            "Fecha      : $($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))"
            "PC         : $env:COMPUTERNAME"
            "Tier       : $tier"
            "Use Case   : $useCase"
            ''
            '=== Resultados ==='
            "Debloat    : $debloatLine"
            "Cleanup    : $cleanupLine"
            "Performance: $perfLine"
            "Privacy    : $privLine"
            "Compare    : $compareScore"
            ''
            "Status     : $overallStatus"
            "Duracion   : $approxDur segundos (aprox.)"
        ) -join "`r`n" | Out-File -FilePath $reportPath -Encoding UTF8

        # Copiar snapshots al folder del cliente
        if ($preSnap.Ok -and (Test-Path -LiteralPath $preSnap.FilePath)) {
            Copy-Item -LiteralPath $preSnap.FilePath -Destination (Join-Path $runDir 'pre.json') -ErrorAction SilentlyContinue
        }
        if ($postSnap.Ok -and (Test-Path -LiteralPath $postSnap.FilePath)) {
            Copy-Item -LiteralPath $postSnap.FilePath -Destination (Join-Path $runDir 'post.json') -ErrorAction SilentlyContinue
        }

        $clientRun = [PSCustomObject]@{
            Slug       = $runSlug
            Dir        = $runDir
            ReportPath = $reportPath
            MetaPath   = $metaPath
            WriteError = ''
        }
        Write-Host ('  [OK] Carpeta de run: {0}' -f $runDir) -ForegroundColor Green
    } catch {
        $clientRun = [PSCustomObject]@{
            Slug       = $ClientSlug
            Dir        = ''
            ReportPath = ''
            MetaPath   = ''
            WriteError = $_.Exception.Message
        }
        Write-Host ('  [!] No se pudo escribir la carpeta de run: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    # ── 6. Startup Report (D3 — solo reporte, sin toggle) ────────────────────
    Write-Host '  Entradas de inicio detectadas (solo reporte):' -ForegroundColor DarkCyan
    try {
        [object[]] $startupEntries = @(Get-StartupEntries)
        $startupR = [PSCustomObject]@{ Count = $startupEntries.Count; ReportedOnly = $true }
        Write-Host ('  [i] Programas de inicio: {0} entradas.' -f $startupEntries.Count) -ForegroundColor DarkGray
    } catch {
        $startupR = [PSCustomObject]@{ Count = -1; ReportedOnly = $true; Error = $_.Exception.Message }
        Write-Host ('  [!] No se pudo leer startup: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    # ── 7. Audit (una sola entrada con el resultado completo) ─────────────────
    [datetime] $endedAt    = Get-Date
    [int]      $durationSec = [math]::Round(($endedAt - $startedAt).TotalSeconds)

    [string] $disabledStr = if ($null -ne $debloatR -and $debloatR.PSObject.Properties['Disabled']) {
        "$($debloatR.Disabled)/$($debloatR.TotalTargeted)"
    } else { '?/?' }
    [string] $cleanupGb = if ($null -ne $cleanupR -and $cleanupR.PSObject.Properties['FreedGB']) {
        "$($cleanupR.FreedGB) GB"
    } else { '?' }

    [PSCustomObject] $fullResult = [PSCustomObject]@{
        UseCase      = $useCase
        Tier         = $tier
        ProfilePath  = $profPath
        SchemaVersion = $schemaVer
        RestorePoint = $rpResult
        PreSnapshot  = $preSnap
        Debloat      = $debloatR
        Cleanup      = $cleanupR
        Performance  = $perfR
        Privacy      = $privResult
        PostSnapshot = $postSnap
        Compare      = $compareR
        Startup      = $startupR
        Status       = $overallStatus
        StartedAt    = $startedAt
        EndedAt      = $endedAt
        DurationSec  = $durationSec
        ClientRun    = $clientRun
    }

    # Audit action derivado del use-case (Stage 3): un run de Office/Study/
    # Multimedia debe loguearse como tal, NO como Generic. Sigue siendo UNA
    # sola entrada (invariante Stage 2 ticket 6). $useCase validado no-vacio
    # por Test-AutoProfileSchema antes de llegar aca.
    if (-not $NoAudit) {
        [string] $auditAction = 'Profile.Apply.' + $useCase.Substring(0,1).ToUpperInvariant() + $useCase.Substring(1)
        Write-ActionAudit `
            -Action  $auditAction `
            -Status  $overallStatus `
            -Summary "tier=$tier services=$disabledStr cleanup=$cleanupGb privacy=$($privResult.Path) compare=$compareScore" `
            -Details $fullResult
    }

    return $fullResult
}

# ─── Invoke-ProfileGamingTweaksStep ───────────────────────────────────────────
function Invoke-ProfileGamingTweaksStep {
    <#
    .SYNOPSIS
        Aplica el bloque gaming_tweaks de una receta nombrada delegando a los
        modulos existentes (Stage 0) + helpers Stage 4. SOLO aplica los toggles
        PRESENTES (ausente = no tocar, D2). Defensivo: un toggle que falla NO
        aborta el resto. HVCI/HAGS marcan RebootNeeded.
        oosu_profile NO se aplica aca: lo cubre el core (privacy.level del
        recipe via Invoke-ProfilePrivacyStep) — evitar doble aplicacion.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile,
        [Parameter()] [switch] $Unattended
    )
    $null = $MachineProfile; $null = $Unattended

    [PSCustomObject] $res = [PSCustomObject]@{
        Hvci = $null; Hags = $null; UsbSuspend = $null; GameMode = $null
        Wslconfig = $null; DefenderExcl = $null; OosuProfile = $null
        RebootNeeded = $false; Success = $true
    }
    [object] $gtP = $Profile.PSObject.Properties['gaming_tweaks']
    if ($null -eq $gtP -or $null -eq $gtP.Value) { return $res }
    [PSCustomObject] $gt = $gtP.Value

    function Invoke-Toggle([string]$Key, [scriptblock]$Action) {
        [object] $p = $gt.PSObject.Properties[$Key]
        if ($null -eq $p -or $null -eq $p.Value) {
            return [PSCustomObject]@{ Applied = $false; Skipped = $true; Detail = 'no tocar (ausente)' }
        }
        try {
            [object] $d = & $Action ([string]$p.Value)
            [bool] $ok = $true
            if ($null -ne $d -and $d.PSObject.Properties['Success']) { $ok = [bool]$d.Success }
            return [PSCustomObject]@{ Applied = $ok; Skipped = $false; Value = [string]$p.Value; Detail = $d }
        } catch {
            return [PSCustomObject]@{ Applied = $false; Skipped = $false; Value = [string]$p.Value; Detail = $_.Exception.Message }
        }
    }
    # Nota: Invoke-Toggle es pura (NO muta $res — $script:res no existe en
    # scope de funcion bajo StrictMode, tiraba). El parent agrega Success abajo.

    $res.Hvci = Invoke-Toggle 'hvci' {
        param($v); if ($v -eq 'off') { Disable-Hvci } else { Enable-Hvci } }
    if ($null -ne $res.Hvci -and -not $res.Hvci.Skipped) { $res.RebootNeeded = $true }

    $res.Hags = Invoke-Toggle 'hags' {
        param($v); if ($v -eq 'off') { Disable-Hags } else { Enable-Hags } }
    if ($null -ne $res.Hags -and -not $res.Hags.Skipped) { $res.RebootNeeded = $true }

    $res.UsbSuspend = Invoke-Toggle 'usb_selective_suspend' {
        param($v); if ($v -eq 'off') { Disable-UsbSelectiveSuspend } else { Enable-UsbSelectiveSuspend } }

    $res.GameMode = Invoke-Toggle 'game_mode' {
        param($v); Set-GameMode -State $v }

    # Agregacion de Success: un toggle ejecutado (no skipped) que no aplico
    # marca el step como no-exitoso (-> Status Partial en Invoke-NamedProfile).
    foreach ($t in @($res.Hvci, $res.Hags, $res.UsbSuspend, $res.GameMode)) {
        if ($null -ne $t -and -not $t.Skipped -and -not $t.Applied) { $res.Success = $false }
    }

    # wslconfig: objeto { enabled; preset }. Solo si enabled y WSL disponible.
    [object] $wP = $gt.PSObject.Properties['wslconfig']
    if ($null -eq $wP -or $null -eq $wP.Value -or $wP.Value.enabled -ne $true) {
        $res.Wslconfig = [PSCustomObject]@{ Applied = $false; Skipped = $true; Detail = 'no tocar (ausente/disabled)' }
    } elseif (-not (Test-WslAvailable)) {
        $res.Wslconfig = [PSCustomObject]@{ Applied = $false; Skipped = $true; Detail = 'WSL no instalado' }
    } else {
        try {
            [string] $preset = if ($wP.Value.PSObject.Properties['preset']) { [string]$wP.Value.preset } else { 'Default' }
            [string] $content = New-WslConfig -Preset $preset
            $null = Set-WslConfig -Content $content
            $null = Invoke-WslShutdown
            $res.Wslconfig = [PSCustomObject]@{ Applied = $true; Skipped = $false; Detail = "preset $preset" }
        } catch {
            $res.Success = $false
            $res.Wslconfig = [PSCustomObject]@{ Applied = $false; Skipped = $false; Detail = $_.Exception.Message }
        }
    }

    [object] $deP = $gt.PSObject.Properties['defender_exclusions']
    if ($null -eq $deP -or $null -eq $deP.Value -or @($deP.Value).Count -eq 0) {
        $res.DefenderExcl = [PSCustomObject]@{ Applied = $false; Skipped = $true; Detail = 'sin paths' }
    } else {
        try {
            [object] $d = Add-CustomDefenderExclusion -Path @($deP.Value)
            [bool] $ok = ($null -eq $d) -or (-not $d.PSObject.Properties['Success']) -or [bool]$d.Success
            if (-not $ok) { $res.Success = $false }
            $res.DefenderExcl = [PSCustomObject]@{ Applied = $ok; Skipped = $false; Detail = $d }
        } catch {
            $res.Success = $false
            $res.DefenderExcl = [PSCustomObject]@{ Applied = $false; Skipped = $false; Detail = $_.Exception.Message }
        }
    }

    [object] $ooP = $gt.PSObject.Properties['oosu_profile']
    $res.OosuProfile = [PSCustomObject]@{
        Applied = $false; Skipped = $true
        Detail  = if ($null -ne $ooP) { "via core privacy (level=$($ooP.Value))" } else { 'ausente' }
    }

    return $res
}

# ─── Invoke-NamedProfile ──────────────────────────────────────────────────────
function Invoke-NamedProfile {
    <#
    .SYNOPSIS
        Orquesta una receta nombrada: chequea hardware vs _hardware_snapshot,
        reusa Invoke-AutoProfile (-NoAudit) para el core, aplica gaming_tweaks,
        actualiza _last_applied y escribe UNA sola entrada de audit consolidada
        (Profile.Apply.Named). Retorna el result del core + extras named.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile,
        [Parameter()] [switch] $SkipRestorePoint,
        [Parameter()] [switch] $Unattended,
        [Parameter()] [string] $ClientSlug = '',
        [Parameter()] [string] $SourcePath = ''
    )

    # Hardware changed vs snapshot guardado (warn, no bloquea)
    [bool] $hwChanged = $false
    [object] $hsP = $Profile.PSObject.Properties['_hardware_snapshot']
    if ($null -ne $hsP -and $null -ne $hsP.Value) {
        foreach ($k in @('CpuName','RamMB','Manufacturer','Tier')) {
            [object] $a = $hsP.Value.PSObject.Properties[$k]
            [object] $b = $MachineProfile.PSObject.Properties[$k]
            if ($null -ne $a -and $null -ne $b -and ([string]$a.Value) -ne ([string]$b.Value)) {
                $hwChanged = $true
                Write-Host ("  [AVISO] Hardware cambio ({0}): '{1}' -> '{2}'" -f $k, $a.Value, $b.Value) -ForegroundColor Yellow
            }
        }
    }

    # Core (reusa el motor validado; -NoAudit para 1 sola entrada consolidada)
    [PSCustomObject] $core = Invoke-AutoProfile -Profile $Profile -MachineProfile $MachineProfile `
        -SkipRestorePoint:$SkipRestorePoint -Unattended:$Unattended -ClientSlug $ClientSlug -NoAudit

    # gaming_tweaks
    Write-Host '  Aplicando gaming_tweaks...' -ForegroundColor Cyan
    [PSCustomObject] $gaming = Invoke-ProfileGamingTweaksStep -Profile $Profile -MachineProfile $MachineProfile -Unattended:$Unattended

    # _last_applied + reescribir el JSON fuente (si existe)
    [string] $appliedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and (Test-Path -LiteralPath $SourcePath)) {
        try {
            if ($Profile.PSObject.Properties['_last_applied']) { $Profile._last_applied = $appliedAt }
            else { $Profile | Add-Member -NotePropertyName '_last_applied' -NotePropertyValue $appliedAt -Force }
            [string] $json = $Profile | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($SourcePath, $json, (New-Object System.Text.UTF8Encoding($true)))
        } catch {
            Write-Host ("  [!] No se pudo actualizar _last_applied: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # Status consolidado
    [string] $coreStatus = if ($core -and $core.PSObject.Properties['Status']) { [string]$core.Status } else { 'Failed' }
    [string] $named = if ($coreStatus -eq 'Failed') { 'Failed' }
        elseif (-not $gaming.Success) { 'Partial' }
        else { $coreStatus }

    # Result consolidado (core + extras named)
    [PSCustomObject] $result = $core
    Add-Member -InputObject $result -NotePropertyName 'Name'            -NotePropertyValue ([string]$Profile._name) -Force
    Add-Member -InputObject $result -NotePropertyName 'GamingTweaks'    -NotePropertyValue $gaming               -Force
    Add-Member -InputObject $result -NotePropertyName 'HardwareChanged' -NotePropertyValue $hwChanged            -Force
    Add-Member -InputObject $result -NotePropertyName 'RebootNeeded'    -NotePropertyValue ([bool]$gaming.RebootNeeded) -Force
    Add-Member -InputObject $result -NotePropertyName 'NamedStatus'     -NotePropertyValue $named                -Force

    # UNA sola entrada de audit consolidada (invariante: 1 entrada por run)
    Write-ActionAudit `
        -Action  'Profile.Apply.Named' `
        -Status  $named `
        -Summary "name=$([string]$Profile._name) core=$coreStatus gaming=$(if ($gaming.Success){'ok'}else{'partial'}) reboot=$($gaming.RebootNeeded)" `
        -Details $result

    if ($gaming.RebootNeeded) {
        Write-Host '  [i] HVCI/HAGS aplicados: requieren REINICIO para efecto pleno.' -ForegroundColor Yellow
    }
    return $result
}
