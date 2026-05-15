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
        [Parameter()] [string] $ClientSlug = ''
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
            [bool] $continuar = Confirm-Action `
                -Title 'Continuar sin Restore Point?' `
                -Lines @(
                    'No se pudo crear un punto de restauracion del sistema.',
                    'Si continuas y algo sale mal, no habra ancla de reversion automatica.',
                    'Recomendado: cancelar y verificar que System Restore este habilitado.'
                ) `
                -DefaultYes:$false

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

    Write-ActionAudit `
        -Action  'Profile.Apply.Generic' `
        -Status  $overallStatus `
        -Summary "tier=$tier services=$disabledStr cleanup=$cleanupGb privacy=$($privResult.Path) compare=$compareScore" `
        -Details $fullResult

    return $fullResult
}
