Set-StrictMode -Version Latest

# ─── NamedProfileEditor ───────────────────────────────────────────────────────
# Stage 4 MVP. Editor de recetas "nombradas" (gaming personalizado por cliente).
# Schema = superset de la receta auto + bloque gaming_tweaks (DD1 stage4-plan §12):
# el core lo valida Test-AutoProfileSchema (NO se modifica); este archivo agrega
# Test-NamedProfileSchema (core + gaming_tweaks) y el editor/IO.
# UI español. PS5.1/StrictMode. data/profiles/named/ gitignored (datos de cliente).

# ─── Get-NamedProfileDir ──────────────────────────────────────────────────────
function Get-NamedProfileDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # PS5.1: Join-Path solo 2 segmentos -> anidar.
    [string] $dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
    return Join-Path (Join-Path $dataDir 'profiles') 'named'
}

# ─── Test-NamedProfileSchema ──────────────────────────────────────────────────
function Test-NamedProfileSchema {
    <#
    .SYNOPSIS
        Valida una receta nombrada. Core via Test-AutoProfileSchema (reuso) +
        bloque gaming_tweaks. Retorna $true o lanza con mensaje claro.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile
    )

    # _kind
    [object] $kindP = $Profile.PSObject.Properties['_kind']
    if ($null -eq $kindP -or ([string]$kindP.Value) -ne 'named') {
        throw "_kind debe ser 'named'. Valor: '$(if ($null -ne $kindP) { $kindP.Value } else { '(ausente)' })'."
    }
    # _name
    [object] $nameP = $Profile.PSObject.Properties['_name']
    if ($null -eq $nameP -or [string]::IsNullOrWhiteSpace([string]$nameP.Value)) {
        throw '_name no puede estar vacio.'
    }

    # Core: reusa el validador auto (NO modificado). El named es superset
    # compatible (_use_case='named', _tier valido, services.disable, etc.).
    $null = Test-AutoProfileSchema -Profile $Profile

    # gaming_tweaks
    [object] $gtP = $Profile.PSObject.Properties['gaming_tweaks']
    if ($null -eq $gtP -or $null -eq $gtP.Value) { throw 'Falta bloque gaming_tweaks.' }
    [PSCustomObject] $gt = $gtP.Value

    [string[]] $onOff = @('on', 'off')
    foreach ($k in @('hvci', 'hags', 'usb_selective_suspend', 'game_mode')) {
        [object] $p = $gt.PSObject.Properties[$k]
        if ($null -ne $p -and ([string]$p.Value) -notin $onOff) {
            throw "gaming_tweaks.$k debe ser 'on' u 'off'. Valor: '$($p.Value)'."
        }
    }
    [object] $wslP = $gt.PSObject.Properties['wslconfig']
    if ($null -ne $wslP -and $null -ne $wslP.Value) {
        [PSCustomObject] $w = $wslP.Value
        [object] $enP = $w.PSObject.Properties['enabled']
        if ($null -eq $enP -or $enP.Value -isnot [bool]) {
            throw 'gaming_tweaks.wslconfig.enabled debe ser booleano.'
        }
        [object] $prP = $w.PSObject.Properties['preset']
        if ($null -ne $prP -and ([string]$prP.Value) -notin @('Default','Gaming','DevHeavy','DevDocker')) {
            throw "gaming_tweaks.wslconfig.preset invalido: '$($prP.Value)'."
        }
    }
    [object] $deP = $gt.PSObject.Properties['defender_exclusions']
    if ($null -ne $deP -and $null -ne $deP.Value -and $deP.Value -isnot [System.Array]) {
        throw 'gaming_tweaks.defender_exclusions debe ser un array.'
    }
    [object] $ooP = $gt.PSObject.Properties['oosu_profile']
    if ($null -ne $ooP -and ([string]$ooP.Value) -notin @('basic','medium','aggressive')) {
        throw "gaming_tweaks.oosu_profile invalido: '$($ooP.Value)'."
    }

    return $true
}

# ─── Import-NamedProfile ──────────────────────────────────────────────────────
function Import-NamedProfile {
    <#
    .SYNOPSIS
        Lee + valida una receta nombrada. Lanza claro si falta/corrupta/invalida.
        NUNCA aplica nada.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Receta nombrada no encontrada: '$Path'."
    }
    [PSCustomObject] $profile = $null
    try {
        $profile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "No se pudo parsear la receta nombrada '$Path': $($_.Exception.Message)"
    }
    if ($null -eq $profile) { throw "La receta '$Path' resulto en objeto nulo al parsear." }
    $null = Test-NamedProfileSchema -Profile $profile
    return $profile
}

# ─── Get-NamedProfileList ─────────────────────────────────────────────────────
function Get-NamedProfileList {
    <#
    .SYNOPSIS
        Lista las recetas nombradas en data/profiles/named/ (incluye _sample).
        Read-only, smoke-safe: nunca lanza; dir ausente/vacio -> @().
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    [string] $dir = Get-NamedProfileDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    [System.Collections.Generic.List[PSCustomObject]] $list =
        [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        [string] $name = $f.BaseName
        [object] $lastApplied = $null
        try {
            [PSCustomObject] $p = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $p) {
                [object] $nP = $p.PSObject.Properties['_name']
                if ($null -ne $nP -and -not [string]::IsNullOrWhiteSpace([string]$nP.Value)) { $name = [string]$nP.Value }
                [object] $laP = $p.PSObject.Properties['_last_applied']
                if ($null -ne $laP) { $lastApplied = $laP.Value }
            }
        } catch { }
        $list.Add([PSCustomObject]@{
            Name        = $name
            Slug        = $f.BaseName
            Path        = $f.FullName
            LastApplied = $lastApplied
            IsSample    = ($f.BaseName -eq '_sample')
        })
    }
    return $list.ToArray()
}

# ─── Save-NamedProfile ────────────────────────────────────────────────────────
function Save-NamedProfile {
    <#
    .SYNOPSIS
        Persiste una receta nombrada como JSON UTF-8 (con BOM) en named/<slug>.json.
        Sanitiza el slug a [a-z0-9-]. Retorna la ruta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [string] $Slug
    )

    [string] $clean = $Slug.ToLowerInvariant()
    $clean = $clean -replace '\s+', '-'
    $clean = $clean -replace '[^a-z0-9-]', ''
    $clean = ($clean -replace '-{2,}', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'receta-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    if ($clean -eq '_sample') { $clean = 'receta-' + $clean }   # no pisar el fixture

    [string] $dir = Get-NamedProfileDir
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [string] $path = Join-Path $dir ($clean + '.json')

    # UTF-8 CON BOM (editor-friendly; el engine lee con -Encoding UTF8).
    [string] $json = $Profile | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

# ─── Get-NamedProfilePreviewLines ─────────────────────────────────────────────
function Get-NamedProfilePreviewLines {
    <#
    .SYNOPSIS
        Lineas legibles para Confirm-Action + warnings hardware-aware (§2.6):
        no bloquean, solo informan que un toggle puede no aplicar.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Profile,
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [System.Collections.Generic.List[string]] $lines =
        [System.Collections.Generic.List[string]]::new()
    $lines.Add("Receta: $([string]$Profile._name)")
    $lines.Add("Tier receta: $([string]$Profile._tier)  |  Tier detectado: $(if ($MachineProfile.PSObject.Properties['Tier']) { [string]$MachineProfile.Tier } else { 'N/A' })")

    # Hardware cambio vs snapshot guardado
    [object] $hsP = $Profile.PSObject.Properties['_hardware_snapshot']
    if ($null -ne $hsP -and $null -ne $hsP.Value) {
        [PSCustomObject] $hs = $hsP.Value
        foreach ($k in @('CpuName','RamMB','Manufacturer')) {
            [object] $a = $hs.PSObject.Properties[$k]
            [object] $b = $MachineProfile.PSObject.Properties[$k]
            if ($null -ne $a -and $null -ne $b -and ([string]$a.Value) -ne ([string]$b.Value)) {
                $lines.Add("[AVISO] Hardware cambio desde que se guardo: $k '$($a.Value)' -> '$($b.Value)'")
            }
        }
    }

    [string[]] $svcs = @($Profile.services.disable)
    $lines.Add("Core: $($svcs.Count) servicios, visual $($Profile.performance.visual_profile), privacy $($Profile.privacy.level)")

    [PSCustomObject] $gt = $Profile.gaming_tweaks
    foreach ($k in @('hvci','hags','usb_selective_suspend','game_mode')) {
        [object] $p = $gt.PSObject.Properties[$k]
        if ($null -ne $p) { $lines.Add("gaming.$k = $($p.Value)") }
    }
    [object] $wP = $gt.PSObject.Properties['wslconfig']
    if ($null -ne $wP -and $null -ne $wP.Value -and $wP.Value.enabled -eq $true) {
        $lines.Add("gaming.wslconfig = ON (preset $([string]$wP.Value.preset))")
        if (-not (Test-WslAvailable)) { $lines.Add('[AVISO] WSL no instalado; el toggle .wslconfig se omitira.') }
    }
    [object] $deP2 = $gt.PSObject.Properties['defender_exclusions']
    if ($null -ne $deP2 -and @($deP2.Value).Count -gt 0) {
        $lines.Add("gaming.defender_exclusions = $(@($deP2.Value).Count) path(s)")
    }
    [object] $ooP2 = $gt.PSObject.Properties['oosu_profile']
    if ($null -ne $ooP2) { $lines.Add("gaming.oosu_profile = $($ooP2.Value)") }

    # Warnings hardware-aware
    [object] $hvP = $gt.PSObject.Properties['hvci']
    if ($null -ne $hvP -and ([string]$hvP.Value) -eq 'off') {
        $lines.Add('[i] HVCI off: VBS se preserva (WSL2/Hyper-V no se rompen).')
    }
    [object] $hgP = $gt.PSObject.Properties['hags']
    if ($null -ne $hgP -and $MachineProfile.PSObject.Properties['HasIGpuOnly'] -and $MachineProfile.HasIGpuOnly) {
        $lines.Add('[AVISO] HAGS: GPU integrada; puede no soportar HAGS (WDDM 2.7+).')
    }
    $lines.Add('Restore Point: automatico (salvo skip en el proximo paso).')
    return $lines.ToArray()
}

# ─── New-NamedProfileInteractive ──────────────────────────────────────────────
function New-NamedProfileInteractive {
    <#
    .SYNOPSIS
        Editor interactivo de toggles. Construye y RETORNA una receta nombrada
        (no la guarda ni aplica). Default de cada toggle = 'no tocar' (D2): Enter
        sin elegir = el toggle NO se incluye en gaming_tweaks.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    function Read-OnOffSkip([string] $Label, [string] $CurrentState) {
        Write-Host ''
        Write-Host ("  {0}  (estado actual: {1})" -f $Label, $CurrentState) -ForegroundColor Cyan
        [string] $a = (Read-Host '    [o]n / [f]off / Enter=no tocar').Trim().ToLowerInvariant()
        switch ($a) {
            'o'   { 'on' }  'on'  { 'on' }
            'f'   { 'off' } 'off' { 'off' }
            default { $null }
        }
    }

    Write-Host ''
    Write-Host '  ── Nueva receta nombrada (gaming) ──' -ForegroundColor DarkCyan
    [string] $name = (Read-Host '  Nombre de la receta (ej. PC Carlos CS2)').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Receta ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

    [PSCustomObject] $gt = [PSCustomObject]@{}
    function Add-Tweak([string]$Key, $Value) {
        if ($null -ne $Value) { $script:gt | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    }

    # Estados actuales (defensivo: si el Get-*Status no esta o falla, 'N/A')
    function Safe-State([scriptblock]$Get, [string]$Prop) {
        try { $r = & $Get; if ($null -ne $r -and $r.PSObject.Properties[$Prop]) { [string]$r.$Prop } else { 'N/A' } } catch { 'N/A' }
    }

    Add-Tweak 'hvci'                  (Read-OnOffSkip 'HVCI / Memory Integrity (off recomendado gaming; VBS se preserva)' (Safe-State { Get-CoreIsolationStatus } 'HvciEnabled'))
    Add-Tweak 'hags'                  (Read-OnOffSkip 'HAGS (Hardware-Accelerated GPU Scheduling)'                         (Safe-State { Get-HagsStatus } 'Enabled'))
    Add-Tweak 'usb_selective_suspend' (Read-OnOffSkip 'USB Selective Suspend (off recomendado p/ periféricos gaming)'      (Safe-State { Get-UsbSelectiveSuspendStatus } 'Enabled'))
    Add-Tweak 'game_mode'             (Read-OnOffSkip 'Game Mode'                                                          (Safe-State { Get-GameModeStatus } 'EffectiveState'))

    # .wslconfig
    Write-Host ''
    [string] $w = (Read-Host '  .wslconfig: aplicar preset? [Default/Gaming/DevHeavy/DevDocker] o Enter=no tocar').Trim()
    if ($w -in @('Default','Gaming','DevHeavy','DevDocker')) {
        Add-Tweak 'wslconfig' ([PSCustomObject]@{ enabled = $true; preset = $w })
    }

    # Defender exclusions
    Write-Host ''
    [string] $de = (Read-Host '  Defender exclusions (paths separados por ; o Enter=ninguno)').Trim()
    if (-not [string]::IsNullOrWhiteSpace($de)) {
        [string[]] $paths = @($de -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($paths.Count -gt 0) { Add-Tweak 'defender_exclusions' $paths }
    }

    # OOSU profile
    Write-Host ''
    [string] $oo = (Read-Host '  OOSU profile [basic/medium/aggressive] o Enter=no tocar').Trim().ToLowerInvariant()
    if ($oo -in @('basic','medium','aggressive')) { Add-Tweak 'oosu_profile' $oo }

    # Core auto-shaped (gaming-ready, neutro y seguro; el operador lo edita a mano si quiere)
    [string] $tier = if ($MachineProfile.PSObject.Properties['Tier']) { ([string]$MachineProfile.Tier).ToLowerInvariant() } else { 'high' }
    [string] $oosuLevel = if ($gt.PSObject.Properties['oosu_profile']) { [string]$gt.oosu_profile } else { 'medium' }

    [PSCustomObject] $hwSnap = [PSCustomObject]@{
        Tier         = if ($MachineProfile.PSObject.Properties['Tier']) { [string]$MachineProfile.Tier } else { '' }
        CpuName      = if ($MachineProfile.PSObject.Properties['CpuName']) { [string]$MachineProfile.CpuName } else { '' }
        RamMB        = if ($MachineProfile.PSObject.Properties['RamMB']) { [int]$MachineProfile.RamMB } else { 0 }
        Manufacturer = if ($MachineProfile.PSObject.Properties['Manufacturer']) { [string]$MachineProfile.Manufacturer } else { '' }
        IsLaptop     = if ($MachineProfile.PSObject.Properties['IsLaptop']) { [bool]$MachineProfile.IsLaptop } else { $false }
    }

    return [PSCustomObject]@{
        _schema_version   = '1.0'
        _kind             = 'named'
        _name             = $name
        _created          = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        _last_applied     = $null
        _hardware_snapshot = $hwSnap

        _use_case   = 'named'
        _tier       = $tier
        _description = "Receta nombrada: $name"
        _rationale  = 'Gaming personalizado. Core neutro+seguro (editable a mano); el valor esta en gaming_tweaks.'
        services    = [PSCustomObject]@{ disable = @('Fax','WMPNetworkSvc','RemoteRegistry','DiagTrack','dmwappushservice') }
        performance = [PSCustomObject]@{ visual_profile = 'Balanced'; power_plan = [PSCustomObject]@{ _future = $true }; system_tweaks = [PSCustomObject]@{ _future = $true } }
        privacy     = [PSCustomObject]@{ level = $oosuLevel; oosu10_cfg = ($oosuLevel + '.cfg'); fallback = 'native' }
        cleanup     = [PSCustomObject]@{ clear_temp = $true }
        startup     = [PSCustomObject]@{ report_only = $true }

        gaming_tweaks = $gt
    }
}
