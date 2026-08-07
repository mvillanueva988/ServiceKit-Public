Set-StrictMode -Version Latest

function Invoke-ExportClientLogs {
    [CmdletBinding()]
    param(
        # Sobreescrito en tests para no tocar la instalacion real
        [Parameter()] [string]   $OutputRootOverride = '',
        [Parameter()] [string]   $DestDirOverride    = '',
        [Parameter()] [string]   $TimestampOverride  = '',
        [Parameter()] [string]   $TagOverride        = '',
        # Pieza C recolector: paths extras a incluir en el ZIP (meta.json, clients/).
        # Filtrados internamente: solo se agregan si existen y no estan ya en la lista.
        [Parameter()] [string[]] $ExtraItems         = @()
    )

    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    } else {
        $OutputRootOverride
    }

    # Paso 1: output\ ausente
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        Write-PctkWarn '  [!] No hay output\ -- nada que empaquetar.'
        Write-ActionAudit -Action 'Logs.Export' -Status 'Empty' -Summary 'output dir missing'
        return [PSCustomObject]@{ Status = 'Empty'; ZipPath = '' }
    }

    # Paso 2: detectar subdirs candidatos (research excluido por decision explicita)
    [string] $auditDir     = Join-Path $outputRoot 'audit'
    [string] $snapshotsDir = Join-Path $outputRoot 'snapshots'

    [bool] $auditOk = (Test-Path -LiteralPath $auditDir -PathType Container) -and
                      ($null -ne (Get-ChildItem -LiteralPath $auditDir -Recurse -File -ErrorAction SilentlyContinue |
                                  Select-Object -First 1))
    [bool] $snapshotsOk = (Test-Path -LiteralPath $snapshotsDir -PathType Container) -and
                          ($null -ne (Get-ChildItem -LiteralPath $snapshotsDir -Recurse -File -ErrorAction SilentlyContinue |
                                      Select-Object -First 1))

    # Filtrar ExtraItems: solo los que existen (archivo o directorio)
    # PS5.1 StrictMode: inicializar como [object[]] antes del loop
    [object[]] $extraValid = @()
    foreach ($xp in $ExtraItems) {
        if (-not [string]::IsNullOrWhiteSpace($xp) -and (Test-Path -LiteralPath $xp)) {
            $extraValid += $xp
        }
    }

    # Paso 3: ninguno poblado y sin extras
    if (-not $auditOk -and -not $snapshotsOk -and $extraValid.Count -eq 0) {
        Write-PctkWarn '  [!] output\ esta vacio -- nada que empaquetar.'
        Write-ActionAudit -Action 'Logs.Export' -Status 'Empty' -Summary 'no populated subdirs'
        return [PSCustomObject]@{ Status = 'Empty'; ZipPath = '' }
    }

    # Paso 4: tag opcional
    [string] $rawTag = if ($PSBoundParameters.ContainsKey('TagOverride')) {
        $TagOverride
    } else {
        (Read-Host '  Tag para el zip (Enter para omitir)').Trim()
    }
    [string] $tag    = $rawTag -replace '[^A-Za-z0-9_-]', ''
    if ($tag.Length -gt 32) { $tag = $tag.Substring(0, 32) }

    # Paso 5: componer nombre
    [string] $hostname = $env:COMPUTERNAME
    [string] $ts       = if ($TimestampOverride) { $TimestampOverride } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    [string] $base     = if ($tag) { '{0}-{1}_{2}' -f $hostname, $tag, $ts }
                         else      { '{0}_{1}'      -f $hostname,      $ts }

    # Paso 6: resolver destino
    [string] $desktop = if (-not [string]::IsNullOrEmpty($DestDirOverride)) {
        $DestDirOverride
    } else {
        [Environment]::GetFolderPath('Desktop')
    }

    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) {
        $desktop = $env:TEMP
        Write-PctkWarn ("  [!] Desktop no resoluble -- usando {0}" -f $desktop)
    }

    # Paso 7: manejar colision (cap a 10 intentos)
    [string] $zipPath = Join-Path $desktop "$base.zip"
    if (Test-Path -LiteralPath $zipPath) {
        [int] $suffix = 2
        while ($suffix -le 10) {
            [string] $candidate = Join-Path $desktop ('{0}_{1}.zip' -f $base, $suffix)
            if (-not (Test-Path -LiteralPath $candidate)) {
                $zipPath = $candidate
                break
            }
            $suffix++
        }
    }

    # Paso 8: construir lista de paths (PS5.1: [object[]] inicializado antes de conditionals)
    [object[]] $items = @()
    if ($auditOk)     { $items += $auditDir }
    if ($snapshotsOk) { $items += $snapshotsDir }
    # Agregar items extras (meta.json del service, clients/ si existe)
    foreach ($xp in $extraValid) { $items += $xp }

    # Comprimir con el API de .NET (System.IO.Compression), NO con el cmdlet del
    # modulo Microsoft.PowerShell.Archive: ese modulo puede fallar al cargar en
    # Windows degradados (PC de cliente) o en instancias de Sandbox ("module could
    # not be loaded"). El API de .NET viene con el framework, no necesita el modulo
    # -> bundle a prueba de balas. Replica el layout previo: cada dir entra por su
    # leaf (audit/.., snapshots/..) y cada archivo suelto en la raiz (meta.json).
    try {
        Add-Type -AssemblyName System.IO.Compression           -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        [System.IO.Compression.ZipArchive] $zip = [System.IO.Compression.ZipFile]::Open(
            $zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($item in $items) {
                if (Test-Path -LiteralPath $item -PathType Container) {
                    [string] $leaf = Split-Path -Path $item -Leaf
                    [string] $root = (Resolve-Path -LiteralPath $item).Path.TrimEnd('\')
                    foreach ($f in @(Get-ChildItem -LiteralPath $item -Recurse -File -ErrorAction SilentlyContinue)) {
                        [string] $rel   = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
                        [string] $entry = '{0}/{1}' -f $leaf, $rel
                        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                            $zip, $f.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
                    }
                } else {
                    [string] $entry = Split-Path -Path $item -Leaf
                    $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $zip, (Resolve-Path -LiteralPath $item).Path, $entry,
                        [System.IO.Compression.CompressionLevel]::Optimal)
                }
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        [string] $errMsg = $_.Exception.Message
        Write-PctkErr ('  [!] Error al comprimir: {0}' -f $errMsg)
        Write-ActionAudit -Action 'Logs.Export' -Status 'Failed' -Summary $errMsg
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = $errMsg }
    }

    # Paso 9: verificar resultado
    if (-not (Test-Path -LiteralPath $zipPath) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
        [string] $errMsg = 'Zip no fue creado o tiene tamanio cero'
        Write-PctkErr ('  [!] {0}' -f $errMsg)
        Write-ActionAudit -Action 'Logs.Export' -Status 'Failed' -Summary $errMsg
        return [PSCustomObject]@{ Status = 'Failed'; ZipPath = ''; Error = $errMsg }
    }

    # Contar archivos incluidos para el reporte
    [object[]] $auditFiles    = @()
    [object[]] $snapshotFiles = @()
    if ($auditOk)     { $auditFiles    = @(Get-ChildItem -LiteralPath $auditDir     -Recurse -File -ErrorAction SilentlyContinue) }
    if ($snapshotsOk) { $snapshotFiles = @(Get-ChildItem -LiteralPath $snapshotsDir -Recurse -File -ErrorAction SilentlyContinue) }
    [long] $totalBytes = (Get-Item -LiteralPath $zipPath).Length
    [int]  $totalFiles = $auditFiles.Count + $snapshotFiles.Count + $extraValid.Count

    # Paso 10: reporte al usuario
    [string] $sizeMb = '{0:0.##}' -f ($totalBytes / 1MB)
    [object[]] $includeLines = @()
    if ($auditOk)            { $includeLines += ('audit ({0} archivos)'     -f $auditFiles.Count) }
    if ($snapshotsOk)        { $includeLines += ('snapshots ({0} archivos)' -f $snapshotFiles.Count) }
    if ($extraValid.Count -gt 0) { $includeLines += ('+{0} extras (meta/clients)' -f $extraValid.Count) }

    Write-Host ''
    Write-PctkOk '  [OK] Logs empaquetados:'
    Write-Host ('       Archivo : {0}' -f $zipPath)
    Write-Host ('       Tamanio : {0} MB' -f $sizeMb)
    Write-Host ('       Incluye : {0}' -f ($includeLines -join ', '))
    Write-PctkWork '  Llevatelo en USB / AnyDesk / cloud.'

    # Paso 11: audit final
    Write-ActionAudit -Action 'Logs.Export' -Status 'OK' -Summary ([System.IO.Path]::GetFileName($zipPath)) -Details @{
        Hostname = $hostname
        Tag      = $tag
        Bytes    = $totalBytes
        Files    = $totalFiles
    }

    return [PSCustomObject]@{ Status = 'OK'; ZipPath = $zipPath }
}

# ─── New-RunMeta ──────────────────────────────────────────────────────────────
function New-RunMeta {
    <#
    .SYNOPSIS
        Sintetiza el objeto meta.json del service al momento del cierre (D1).
        Solo usa datos que siempre estan disponibles: AnyDesk ID (read-only),
        hostname, fecha, y opcionalmente el score del Compare-Snapshot.

        POR QUE no reutiliza el meta de [1]: el flujo recolector permite usar
        [3]/[4] manuales sin pasar por [1]. El meta se genera igual en ambos
        casos para que el bundle SIEMPRE tenga contexto del equipo.

        En el futuro, [1] puede refactorizarse para llamar esta funcion en vez
        de duplicar la logica; pero ese cambio no entra en este contrato
        (blast-radius del refactor de Invoke-AutoProfile es alto).
    .OUTPUTS
        [ordered] hashtable con los campos del meta (listo para ConvertTo-Json).
    #>
    [CmdletBinding()]
    param(
        # Slug del cliente (por defecto usa hostname)
        [string] $ClientSlug        = '',
        # Override de fecha para tests reproducibles
        [string] $DateOverride       = '',
        # Paths de AnyDesk conf (override para tests)
        [string[]] $AnyDeskConfPaths = @()
    )

    [string] $slug = if ([string]::IsNullOrWhiteSpace($ClientSlug)) {
        'cliente-' + $env:COMPUTERNAME.ToLowerInvariant()
    } else { $ClientSlug }

    [string] $dateStr = if ([string]::IsNullOrEmpty($DateOverride)) {
        (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } else { $DateOverride }

    # AnyDesk ID (read-only; $null si AnyDesk no instalado o conf no encontrado).
    # Guard: la captura NUNCA debe abortar la escritura del meta.
    [string] $anydeskId = $null
    try {
        if ($AnyDeskConfPaths.Count -gt 0) {
            $anydeskId = Get-AnyDeskId -ConfPaths $AnyDeskConfPaths
        } else {
            $anydeskId = Get-AnyDeskId
        }
    } catch { $anydeskId = $null }

    # Score del ultimo Compare-Snapshot (si hay PRE y POST disponibles).
    # Si no hay PRE/POST, devuelve 'N/A' sin tirar.
    [string] $compareScore = 'N/A'
    try {
        if (Get-Command -Name 'Compare-Snapshot' -CommandType Function -ErrorAction SilentlyContinue) {
            $cmp = Compare-Snapshot
            if ($null -ne $cmp -and $null -ne $cmp.PSObject.Properties['Score']) {
                $compareScore = ('{0}/{1}' -f [string]$cmp.Score, [string]$cmp.ScoreMax)
            }
        }
    } catch { $compareScore = 'N/A' }

    return [ordered]@{
        client             = $slug
        date               = $dateStr
        computer_name      = $env:COMPUTERNAME
        anydesk_id         = $anydeskId
        schema_version     = '1.0'
        compare_score      = $compareScore
        status             = 'closed'
        amount_charged_ars = $null
        notes              = ''
    }
}

# ─── Invoke-CloseService ──────────────────────────────────────────────────────
function Invoke-CloseService {
    <#
    .SYNOPSIS
        Pieza C del recolector: cierra el service y arma el bundle completo.

        Flujo:
        1. Si hay service abierto con PRE -> toma POST automatico (igual que [4]).
        2. Sintetiza meta.json del service (D1: Get-AnyDeskId + Compare-Snapshot).
        3. Arma el ZIP incluyendo meta.json + audit + snapshots + clients/ si existe.
        4. Cierra el state (borra current-run.json, D3).
        5. Si [L] se aprieta sin service/sin PRE -> empaqueta lo que haya + aviso
           "bundle parcial" (D4, no bloquear).

        POR QUE separado de Invoke-ExportClientLogs: ExportClientLogs es el
        modo a-la-carte (herramienta directa, pide tag, sin service state). Este
        handler es el flujo de service completo. Reutiliza ExportClientLogs
        para la compresion (codigo compartido).
    #>
    [CmdletBinding()]
    param(
        # Overrides para tests (no tocar instalacion real)
        [Parameter()] [string]   $OutputRootOverride = '',
        [Parameter()] [string]   $DestDirOverride    = '',
        [Parameter()] [string]   $TimestampOverride  = '',
        # Override de paths AnyDesk (para test sin AnyDesk instalado)
        [Parameter()] [string[]] $AnyDeskConfPaths   = @(),
        # Raiz del TOOLKIT para los helpers de ServiceState. Ver nota de $stateRoot.
        [Parameter()] [string]   $ToolkitRootOverride = ''
    )

    Write-PctkWork '  Cerrando service...'
    Write-ActionAudit -Action 'Service.Close' -Status 'Started'

    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    } else {
        $OutputRootOverride
    }

    # OJO, dos convenciones distintas con el mismo nombre de parametro:
    #   - Aca $OutputRootOverride ES la carpeta output.
    #   - En ServiceState.ps1 $OutputRootOverride es la RAIZ DEL TOOLKIT (le
    #     agrega 'output\state').
    # Pasarle nuestro output root a Get-ServiceState lo manda a buscar
    # <output>\output\state\current-run.json -> nunca encuentra nada. En el [L]
    # no se notaba (ambos vacios = raiz real), pero el [U] SI pasa un override
    # (<install>\output): por eso Save-PreUninstallArtifacts nunca veia el service
    # abierto y se salteaba el POST en silencio.
    # $ToolkitRootOverride vacio = comportamiento historico (hereda el otro).
    [string] $stateRoot = if (-not [string]::IsNullOrEmpty($ToolkitRootOverride)) {
        $ToolkitRootOverride
    } else {
        $OutputRootOverride
    }

    # ── Paso 1: leer el state del service ────────────────────────────────────
    # Determina si hay PRE para el POST automatico y si el bundle es completo o parcial.
    [bool] $hasService = $false
    [bool] $hasPre     = $false
    $svcState = $null

    if (Get-Command -Name 'Get-ServiceState' -CommandType Function -ErrorAction SilentlyContinue) {
        $svcState = Get-ServiceState -OutputRootOverride $stateRoot
        if ($null -ne $svcState -and $null -ne $svcState.PSObject.Properties['open'] -and [bool]$svcState.open) {
            $hasService = $true
            if ($null -ne $svcState.PSObject.Properties['pre_taken_at'] -and
                -not [string]::IsNullOrEmpty([string]$svcState.pre_taken_at) -and
                [string]$svcState.pre_taken_at -ne 'null') {
                $hasPre = $true
            }
        }
    }

    # ── Paso 2: POST automatico si hay service con PRE ────────────────────────
    # Usa el mismo patron que [4] (Start-TelemetryJob + Invoke-JobWithProgress).
    # El POST automático solo tiene sentido si hay PRE para comparar despues.
    if ($hasService -and $hasPre) {
        Write-PctkWork '  Capturando snapshot POST automatico...'
        if (Get-Command -Name 'Start-TelemetryJob' -CommandType Function -ErrorAction SilentlyContinue) {
            try {
                $postJob = Start-TelemetryJob -Phase Post
                $postResults = Invoke-JobWithProgress -Jobs @($postJob) -Activity 'Snapshot POST (cierre)' -TimeoutSeconds 120
                if ($null -ne $postResults -and $postResults.Count -gt 0 -and $null -ne $postResults[0]) {
                    $pr = $postResults[0]
                    Write-PctkOk ('  [OK] POST: {0}' -f $pr.FileName)
                } else {
                    Write-PctkWarn '  [!] POST no se pudo capturar; continuando sin POST.'
                }
            } catch {
                Write-PctkWarn ('  [!] POST automatico fallo: {0}. Continuando.' -f $_.Exception.Message)
            }
        }
    } elseif (-not $hasService -or -not $hasPre) {
        # D4: bundle parcial, no bloquear
        Write-PctkWarn '  [!] Bundle parcial: no hay service abierto con PRE en esta PC.'
    }

    # ── Paso 3: sintetizar meta.json para el bundle ───────────────────────────
    # Siempre se genera (D1): aunque no haya corrido [1], el bundle tiene contexto.
    [string] $metaTmpPath = $null
    try {
        [string] $stateDir = Join-Path $outputRoot 'state'
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop
        }
        $metaTmpPath = Join-Path $stateDir 'bundle-meta.json'

        # Slug del cliente (nombre del estado del service o fallback al hostname)
        [string] $slug = 'cliente-' + $env:COMPUTERNAME.ToLowerInvariant()

        # Construir el objeto meta con New-RunMeta
        $metaParams = @{ ClientSlug = $slug }
        if ($TimestampOverride) { $metaParams['DateOverride'] = $TimestampOverride }
        if ($AnyDeskConfPaths.Count -gt 0) { $metaParams['AnyDeskConfPaths'] = $AnyDeskConfPaths }

        $metaObj = New-RunMeta @metaParams

        ($metaObj | ConvertTo-Json -Depth 4) | Out-File -FilePath $metaTmpPath -Encoding UTF8 -ErrorAction Stop

        # Validar que el JSON quedó bien formado
        $null = Get-Content -LiteralPath $metaTmpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-PctkOk '  [OK] meta.json sintetizado.'
    } catch {
        Write-PctkWarn ('  [!] No se pudo generar meta.json: {0}' -f $_.Exception.Message)
        $metaTmpPath = $null
    }

    # ── Paso 3b: guardar la comparacion COMPLETA, no solo su puntaje ─────────
    # Compare-Snapshot arma la lista de mejoras en criollo ("Espacio liberado:
    # 12,4 GB", "Programas de inicio removidos: 3") mas el puntaje sobre 6 areas.
    # Hasta aca se corria, se tomaba SOLO el numero para el meta y la lista se
    # tiraba -- asi que del otro lado, en el CRM, no habia con que armar el cajon
    # "lo que mejoro" y habria habido que RECALCULARLO en TypeScript.
    #
    # Eso serian DOS definiciones de "que mejoro", en dos lenguajes, divergiendo
    # en silencio. La comparacion se decide en UN solo lugar -- aca, que es donde
    # ya estaba -- y viaja escrita.
    #
    # Si no hay PRE y POST no se escribe nada: un diagnostico sin cierre no tiene
    # comparacion, y un archivo vacio se leeria como "no mejoro nada", que es
    # distinto de "no habia con que comparar".
    [string] $comparePath = $null
    try {
        if (Get-Command -Name 'Compare-Snapshot' -CommandType Function -ErrorAction SilentlyContinue) {
            [object] $cmpObj = Compare-Snapshot
            if ($null -ne $cmpObj) {
                [string] $stateDir2 = Join-Path $outputRoot 'state'
                if (-not (Test-Path -LiteralPath $stateDir2 -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $stateDir2 -Force -ErrorAction Stop
                }
                $comparePath = Join-Path $stateDir2 'compare.json'
                # Depth 5: VolumeDiff es una lista de objetos y es lo mas anidado.
                ($cmpObj | ConvertTo-Json -Depth 5) | Out-File -FilePath $comparePath -Encoding UTF8 -ErrorAction Stop
                $null = Get-Content -LiteralPath $comparePath -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-PctkOk '  [OK] Comparacion antes/despues guardada.'
            }
        }
    } catch {
        # Nunca traba el cierre: sin esto el bundle sale igual, sin el detalle.
        #
        # Y NO se avisa cuando la razon es que no hay snapshots: un diagnostico
        # sin cierre no tiene antes/despues, eso es lo NORMAL y no un problema.
        # Gritarlo en pantalla seria ruido justo cuando el operador esta con el
        # cliente delante, y ruido repetido es como se aprende a ignorar los
        # avisos que si importan.
        if ($_.Exception.Message -notmatch '(?i)snapshot') {
            Write-PctkWarn ('  [!] No se pudo guardar la comparacion: {0}' -f $_.Exception.Message)
        }
        $comparePath = $null
    }

    # ── Paso 4: incluir clients/ si existe (run-dir de [1] si se uso) ────────
    [string] $clientsDir = Join-Path $outputRoot 'clients'
    [string] $clientsDirOk = ''
    if ((Test-Path -LiteralPath $clientsDir -PathType Container) -and
        ($null -ne (Get-ChildItem -LiteralPath $clientsDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1))) {
        $clientsDirOk = $clientsDir
    }

    # ── Paso 4b: incluir reports/ si existe (#29) ────────────────────────────
    # El reporte HTML del cliente ([8] / cierre de [1]) vive en output\reports\ y
    # hasta v2.4.0 NO viajaba en el bundle: el detalle quedaba en la PC del cliente
    # y habia que ir a buscarlo aparte (caso Olivo 2026-07-14, los BSOD).
    # GUARDRAIL (feedback_secrets_not_in_bundles): se agrega reports\, NO recovery\.
    # La clave de BitLocker se escribe en output\recovery\, que sigue fuera del ZIP
    # a proposito -- no ampliar la lista sin auditar que no arrastre secretos.
    [string] $reportsDir = Join-Path $outputRoot 'reports'
    [string] $reportsDirOk = ''
    if ((Test-Path -LiteralPath $reportsDir -PathType Container) -and
        ($null -ne (Get-ChildItem -LiteralPath $reportsDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1))) {
        $reportsDirOk = $reportsDir
    }

    # ── Paso 4c: incluir audits/ (informe tecnico del [I]) ───────────────────
    # OJO con el nombre: 'audits' (informe legible del tecnico, RawAudit) NO es
    # 'audit' (el JSONL del audit trail). Un caracter de diferencia entre dos cosas
    # que no tienen nada que ver -- ver code-map.md seccion 7.
    [string] $auditsDir = Join-Path $outputRoot 'audits'
    [string] $auditsDirOk = ''
    if ((Test-Path -LiteralPath $auditsDir -PathType Container) -and
        ($null -ne (Get-ChildItem -LiteralPath $auditsDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1))) {
        $auditsDirOk = $auditsDir
    }

    # ── Paso 5: armar lista de extras para ExportClientLogs ──────────────────
    # PS5.1 StrictMode: [object[]] inicializado antes de conditionals
    [object[]] $extras = @()
    if (-not [string]::IsNullOrEmpty($metaTmpPath) -and (Test-Path -LiteralPath $metaTmpPath)) {
        $extras += $metaTmpPath
    }
    if (-not [string]::IsNullOrEmpty($comparePath) -and (Test-Path -LiteralPath $comparePath)) {
        $extras += $comparePath
    }
    if (-not [string]::IsNullOrEmpty($clientsDirOk)) {
        $extras += $clientsDirOk
    }
    if (-not [string]::IsNullOrEmpty($reportsDirOk)) {
        $extras += $reportsDirOk
    }
    if (-not [string]::IsNullOrEmpty($auditsDirOk)) {
        $extras += $auditsDirOk
    }

    # ── Paso 6: comprimir (reusar ExportClientLogs con tag fijo = cierre) ────
    $exportParams = @{
        OutputRootOverride = $OutputRootOverride
        DestDirOverride    = $DestDirOverride
        TagOverride        = 'cierre'      # fijo: no pedir tag al usuario en el cierre
        ExtraItems         = $extras
    }
    if ($TimestampOverride) { $exportParams['TimestampOverride'] = $TimestampOverride }

    $result = Invoke-ExportClientLogs @exportParams

    # ── Paso 7: cerrar el service state (D3: borrar current-run.json) ────────
    # SOLO si el bundle se armo OK. Si fallo/vacio, NO cerramos el service: el
    # operador puede reintentar el [L] sin perder el estado (evita "service cerrado
    # sin ZIP", que dejaria sin forma de re-empaquetar).
    if ($null -ne $result -and $null -ne $result.PSObject.Properties['Status'] -and $result.Status -eq 'OK' -and
        (Get-Command -Name 'Close-ServiceState' -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            Close-ServiceState -OutputRootOverride $stateRoot
        } catch {
            Write-PctkWarn ('  [!] No se pudo cerrar el state: {0}' -f $_.Exception.Message)
        }

        # Marcador del bundle: es lo que le permite al [U] saber que el paquete
        # de ESTA PC ya se genero y no dejar un segundo ZIP en el Escritorio del
        # cliente. Se sella DESPUES de cerrar el state y solo con Status OK.
        if (Get-Command -Name 'Set-LastBundleMarker' -CommandType Function -ErrorAction SilentlyContinue) {
            try {
                $null = Set-LastBundleMarker -ZipPath ([string]$result.ZipPath) -OutputRootOverride $stateRoot
            } catch {
                # El marcador es una optimizacion de UX; si falla, el [U] re-empaqueta.
            }
        }
    } elseif ($null -ne $result -and $result.Status -ne 'OK') {
        Write-PctkWarn ('  [!] El bundle no se creo (estado {0}); el service queda ABIERTO para reintentar [L].' -f $result.Status)
    }

    # ── Paso 8: limpiar meta temporal (ya esta en el ZIP) ────────────────────
    if (-not [string]::IsNullOrEmpty($metaTmpPath) -and (Test-Path -LiteralPath $metaTmpPath)) {
        Remove-Item -LiteralPath $metaTmpPath -Force -ErrorAction SilentlyContinue
    }

    Write-ActionAudit -Action 'Service.Close' -Status $result.Status -Summary $result.ZipPath

    return $result
}
