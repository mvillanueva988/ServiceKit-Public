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
    if ($null -ne $ooP -and ([string]$ooP.Value) -notin @('basic','medium','aggressive','gaming')) {
        throw "gaming_tweaks.oosu_profile invalido: '$($ooP.Value)'."
    }
    [object] $trP = $gt.PSObject.Properties['timer_resolution']
    if ($null -ne $trP -and ([string]$trP.Value) -notin $onOff) {
        throw "gaming_tweaks.timer_resolution debe ser 'on' o 'off'. Valor: '$($trP.Value)'."
    }
    [object] $nsfP = $gt.PSObject.Properties['nvidia_sysmem_fallback']
    if ($null -ne $nsfP -and ([string]$nsfP.Value) -notin @('prefer_no','default')) {
        throw "gaming_tweaks.nvidia_sysmem_fallback invalido: '$($nsfP.Value)'. Validos: prefer_no, default."
    }
    [object] $ppP = $gt.PSObject.Properties['process_priority']
    if ($null -ne $ppP -and $null -ne $ppP.Value) {
        [string[]] $validPriority = @('High', 'AboveNormal')
        foreach ($prop in @($ppP.Value.PSObject.Properties)) {
            if ([string]$prop.Value -notin $validPriority) {
                throw "gaming_tweaks.process_priority: clase invalida para '$($prop.Name)': '$($prop.Value)'. Validos: High, AboveNormal."
            }
        }
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

# ─── Get-SteamLibraryPaths (privada, read-only, no-throw) ────────────────────
function Get-SteamLibraryPaths {
    <#
    .SYNOPSIS
        Lee las rutas de librerias Steam desde el registro y libraryfolders.vdf.
        Read-only, no-throw, StrictMode-safe. Devuelve array vacio si no hay Steam.
        D-S42c: autodeteccion para sugerir defender_exclusions en el builder.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    try {
        [object] $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' `
            -Name 'SteamPath' -ErrorAction SilentlyContinue
        if ($null -eq $reg) { return @() }
        [object] $spP = $reg.PSObject.Properties['SteamPath']
        if ($null -eq $spP -or [string]::IsNullOrWhiteSpace([string]$spP.Value)) { return @() }
        [string] $steamRoot = [string]$spP.Value
        [string] $vdfPath = Join-Path (Join-Path $steamRoot 'steamapps') 'libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdfPath -ErrorAction SilentlyContinue)) { return @() }
        [string] $vdf = Get-Content -LiteralPath $vdfPath -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($vdf)) { return @() }
        [System.Collections.Generic.List[string]] $found = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($vdf, '"path"\s+"([^"]+)"')) {
            [string] $p = $m.Groups[1].Value -replace '\\\\', '\'
            if (-not [string]::IsNullOrWhiteSpace($p)) { $found.Add($p) }
        }
        return $found.ToArray()
    } catch {
        return @()
    }
}

# ─── Get-InstalledGames (privada, read-only, no-throw) ───────────────────────
function Get-InstalledGames {
    <#
    .SYNOPSIS
        Enumera juegos instalados de multiples tiendas. Read-only, no-throw,
        StrictMode-safe. Devuelve [PSCustomObject[]] con campos {Name;Path;Source}.
        Fuentes: Steam (via Get-SteamLibraryPaths), Epic (manifests JSON),
        GOG/EA/Ubisoft/Battle.net (registry Uninstall), Xbox/MS Store (best-effort),
        Fallback (dirs comunes). Loggea con Write-Verbose lo que NO se cubre.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    [System.Collections.Generic.List[PSCustomObject]] $games =
        [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Steam ------------------------------------------------------------------
    try {
        [string[]] $libs = @(Get-SteamLibraryPaths)
        foreach ($lib in $libs) {
            [string] $common = Join-Path $lib 'steamapps\common'
            if (-not (Test-Path -LiteralPath $common -ErrorAction SilentlyContinue)) { continue }
            foreach ($dir in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)) {
                $games.Add([PSCustomObject]@{ Name = $dir.Name; Path = $dir.FullName; Source = 'Steam' })
            }
        }
    } catch {
        Write-Verbose "Get-InstalledGames Steam: error suprimido: $($_.Exception.Message)"
    }

    # --- Epic Games -------------------------------------------------------------
    try {
        [string] $epicManifests = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
        if (Test-Path -LiteralPath $epicManifests -ErrorAction SilentlyContinue) {
            foreach ($item in @(Get-ChildItem -LiteralPath $epicManifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
                try {
                    [PSCustomObject] $manifest = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($null -eq $manifest) { continue }
                    [object] $nameP = $manifest.PSObject.Properties['DisplayName']
                    [object] $pathP = $manifest.PSObject.Properties['InstallLocation']
                    if ($null -eq $nameP -or $null -eq $pathP) { continue }
                    [string] $gName = [string]$nameP.Value
                    [string] $gPath = [string]$pathP.Value
                    if (-not [string]::IsNullOrWhiteSpace($gName) -and -not [string]::IsNullOrWhiteSpace($gPath)) {
                        $games.Add([PSCustomObject]@{ Name = $gName; Path = $gPath; Source = 'Epic' })
                    }
                } catch { }
            }
        }
    } catch {
        Write-Verbose "Get-InstalledGames Epic: error suprimido: $($_.Exception.Message)"
    }

    # --- GOG / EA app / Ubisoft / Battle.net (registry Uninstall best-effort) --
    try {
        [string[]] $uninstallRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        [string[]] $sourcePatterns = @('GOG.com','GOG','Electronic Arts','EA App','Ubisoft','Battle.net','Blizzard')
        foreach ($root in $uninstallRoots) {
            if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) { continue }
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                try {
                    [PSCustomObject] $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                    if ($null -eq $props) { continue }
                    [object] $pubP = $props.PSObject.Properties['Publisher']
                    [string] $pub  = if ($null -ne $pubP) { [string]$pubP.Value } else { '' }
                    [bool] $isKnownLauncher = $false
                    foreach ($pat in $sourcePatterns) {
                        if ($pub -match [regex]::Escape($pat)) { $isKnownLauncher = $true; break }
                    }
                    if (-not $isKnownLauncher) { continue }
                    [object] $nameP2 = $props.PSObject.Properties['DisplayName']
                    [object] $pathP2 = $props.PSObject.Properties['InstallLocation']
                    if ($null -eq $nameP2) { continue }
                    [string] $gName2 = [string]$nameP2.Value
                    [string] $gPath2 = if ($null -ne $pathP2) { [string]$pathP2.Value } else { '' }
                    if ([string]::IsNullOrWhiteSpace($gName2)) { continue }
                    # Deduplicar por nombre
                    [bool] $dup = $false
                    foreach ($existing in $games) {
                        if ($existing.Name -eq $gName2) { $dup = $true; break }
                    }
                    if (-not $dup) {
                        # Detectar fuente por publisher
                        [string] $src = 'Otro'
                        if ($pub -match 'GOG')                  { $src = 'GOG' }
                        elseif ($pub -match 'Electronic Arts|EA') { $src = 'EA' }
                        elseif ($pub -match 'Ubisoft')           { $src = 'Ubisoft' }
                        elseif ($pub -match 'Blizzard|Battle')   { $src = 'Battle.net' }
                        $games.Add([PSCustomObject]@{ Name = $gName2; Path = $gPath2; Source = $src })
                    }
                } catch { }
            }
        }
    } catch {
        Write-Verbose "Get-InstalledGames GOG/EA/Ubisoft/BNet: error suprimido: $($_.Exception.Message)"
    }

    # --- Xbox / MS Store (best-effort; UWP, cobertura parcial) -----------------
    # Get-AppxPackage puede ser lento o incompleto en PS5.1/Win10; se intenta y si
    # falla se loggea. NO es silencio: Write-Verbose documenta la limitacion.
    try {
        [object[]] $xboxPkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_ -and $_.PublisherId -match 'Microsoft' -and
                           $_.Name -match 'Xbox|GameApp|Gaming' } )
        foreach ($pkg in $xboxPkgs) {
            [object] $locP = $pkg.PSObject.Properties['InstallLocation']
            [string] $xPath = if ($null -ne $locP) { [string]$locP.Value } else { '' }
            $games.Add([PSCustomObject]@{ Name = $pkg.Name; Path = $xPath; Source = 'Xbox' })
        }
    } catch {
        Write-Verbose "Get-InstalledGames Xbox/MS Store: no cubierto en este sistema (Get-AppxPackage fallo o no retorno juegos). $($_.Exception.Message)"
    }

    return $games.ToArray()
}

# ─── New-GamingPreset ─────────────────────────────────────────────────────────
function Test-IsRtx40Plus {
    <# True si MachineProfile.GpuNames trae una NVIDIA RTX serie 40/50 (Ada/Blackwell).
       Esas placas tienen DLSS3/4 Frame Generation, que REQUIERE HAGS on -> guardrail.
       (research 2026-06-05; ver _local-dev/research/2026-06-05-hags/). StrictMode-safe. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [PSCustomObject] $MachineProfile)
    [object] $p = $MachineProfile.PSObject.Properties['GpuNames']
    if ($null -eq $p -or $null -eq $p.Value) { return $false }
    foreach ($gn in @($p.Value)) {
        if ([string]$gn -match 'RTX\s*[45]\d{3}') { return $true }
    }
    return $false
}

function New-GamingPreset {
    <#
    .SYNOPSIS
        Pre-llena gaming_tweaks con defaults HW-smart segun MachineProfile.
        Los defaults son CONJETURAS del research (2026-05-30); validar en HW.
        SIEMPRE devuelve un objeto editable (no aplica nada). StrictMode-safe.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile
    )

    [PSCustomObject] $gt = [PSCustomObject]@{}

    # hvci = off (gaming; VBS/WSL2 se preservan)
    $gt | Add-Member -NotePropertyName 'hvci' -NotePropertyValue 'off' -Force

    # game_mode = on
    $gt | Add-Member -NotePropertyName 'game_mode' -NotePropertyValue 'on' -Force

    # usb_selective_suspend = off (perifericos 2.4GHz/HID/latencia)
    $gt | Add-Member -NotePropertyName 'usb_selective_suspend' -NotePropertyValue 'off' -Force

    # timer_resolution = on SOLO si Win11. Get-MachineProfile emite IsWin11 (bool,
    # = build>=22000); NO existe WinBuild. Defensivo con PSObject.Properties.
    [object] $win11P = $MachineProfile.PSObject.Properties['IsWin11']
    [bool] $isWin11 = if ($null -ne $win11P -and $null -ne $win11P.Value) {
        try { [bool]$win11P.Value } catch { $false }
    } else { $false }
    if ($isWin11) {
        $gt | Add-Member -NotePropertyName 'timer_resolution' -NotePropertyValue 'on' -Force
    }

    # hags: GUARDRAIL de Frame Generation, NO perf (research 2026-06-05).
    # RTX 40/50 -> ON SIEMPRE: DLSS3/4 Frame Generation REQUIERE HAGS; apagarlo lo rompe
    # en silencio. Resto (RTX20/30, GTX, AMD, iGPU) -> OFF como default blando: no hay FG
    # que perder, libera algo de VRAM, mejor para streaming/NVENC; en FPS es indiferente y
    # el frame pacing es por-juego (editable -> probar ambos si stuttea). Ya NO se usa
    # umbral de VRAM (los numeros de overhead fueron refutados en el research).
    if (Test-IsRtx40Plus -MachineProfile $MachineProfile) {
        $gt | Add-Member -NotePropertyName 'hags' -NotePropertyValue 'on' -Force
    } else {
        $gt | Add-Member -NotePropertyName 'hags' -NotePropertyValue 'off' -Force
    }

    # oosu_profile = gaming
    $gt | Add-Member -NotePropertyName 'oosu_profile' -NotePropertyValue 'gaming' -Force

    # defender_exclusions = [] (vacio; el operador los agrega via scan/toggle)
    $gt | Add-Member -NotePropertyName 'defender_exclusions' -NotePropertyValue @() -Force

    return $gt
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
        [Parameter(Mandatory)] [PSCustomObject] $MachineProfile,
        # Si se pasa, pre-llena gaming_tweaks con defaults HW-smart (modo gaming preset).
        # El operador puede sobreescribir cada valor con Enter=no tocar o eligiendo otro.
        [Parameter()] [switch] $UseGamingPreset
    )

    function Read-OnOffSkip([string] $Label, [string] $CurrentState, [string] $PresetDefault = '') {
        Write-Host ''
        [string] $hint = if ([string]::IsNullOrWhiteSpace($PresetDefault)) {
            "  {0}  (actual: {1})" -f $Label, $CurrentState
        } else {
            "  {0}  (actual: {1}  |  preset: {2})" -f $Label, $CurrentState, $PresetDefault
        }
        Write-Host $hint -ForegroundColor Cyan
        [string] $promptTxt = if ([string]::IsNullOrWhiteSpace($PresetDefault)) {
            '    [o]n / [f]off / Enter=no tocar'
        } else {
            "    [o]n / [f]off / Enter=usar preset ($PresetDefault)"
        }
        [string] $a = (Read-Host $promptTxt).Trim().ToLowerInvariant()
        switch ($a) {
            'o'   { 'on' }  'on'  { 'on' }
            'f'   { 'off' } 'off' { 'off' }
            default { if (-not [string]::IsNullOrWhiteSpace($PresetDefault)) { $PresetDefault } else { $null } }
        }
    }

    Write-Host ''
    Write-Host '  ── Nueva receta nombrada (gaming) ──' -ForegroundColor DarkCyan
    [string] $name = (Read-Host '  Nombre de la receta (ej. PC Carlos CS2)').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Receta ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

    [PSCustomObject] $gt = [PSCustomObject]@{}
    function Add-Tweak([string]$Key, $Value) {
        # $gt es local de New-NamedProfileInteractive; Add-Tweak lo resuelve por
        # scope dinamico y muta el MISMO objeto que se lee/retorna abajo.
        # NO usar $script:gt: crashea con StrictMode (nunca seteado) y ademas
        # arrastraria estado entre llamadas.
        if ($null -ne $Value) { $gt | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    }

    # Estados actuales (defensivo: si el Get-*Status no esta o falla, 'N/A')
    function Safe-State([scriptblock]$Get, [string]$Prop) {
        try { $r = & $Get; if ($null -ne $r -and $r.PSObject.Properties[$Prop]) { [string]$r.$Prop } else { 'N/A' } } catch { 'N/A' }
    }

    # Defaults HW-smart del preset (si se activo; sino string vacio = sin sugerencia)
    [PSCustomObject] $presetGt = $null
    if ($UseGamingPreset) {
        Write-Host '  [Preset gaming] Calculando defaults HW-smart...' -ForegroundColor DarkGray
        $presetGt = New-GamingPreset -MachineProfile $MachineProfile
    }
    function Get-PresetDefault([string]$Key) {
        if ($null -eq $presetGt) { return '' }
        [object] $p = $presetGt.PSObject.Properties[$Key]
        if ($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { return [string]$p.Value }
        return ''
    }

    Add-Tweak 'hvci'                  (Read-OnOffSkip 'HVCI / Memory Integrity (off recomendado gaming; VBS se preserva)' (Safe-State { Get-CoreIsolationStatus } 'HvciEnabled') (Get-PresetDefault 'hvci'))
    [string] $hagsChoice = Read-OnOffSkip 'HAGS (Hardware-Accelerated GPU Scheduling)' (Safe-State { Get-HagsStatus } 'Enabled') (Get-PresetDefault 'hags')
    if ($hagsChoice -eq 'off' -and (Test-IsRtx40Plus -MachineProfile $MachineProfile)) {
        Write-Host '    [!] OJO: GPU RTX 40/50 -> con HAGS off, DLSS Frame Generation NO funciona (se desactiva solo).' -ForegroundColor Yellow
    }
    Add-Tweak 'hags' $hagsChoice
    Add-Tweak 'usb_selective_suspend' (Read-OnOffSkip 'USB Selective Suspend (off recomendado p/ periféricos gaming)'      (Safe-State { Get-UsbSelectiveSuspendStatus } 'Enabled') (Get-PresetDefault 'usb_selective_suspend'))
    Add-Tweak 'game_mode'             (Read-OnOffSkip 'Game Mode'                                                          (Safe-State { Get-GameModeStatus } 'EffectiveState')     (Get-PresetDefault 'game_mode'))

    # .wslconfig
    Write-Host ''
    [string] $w = (Read-Host '  .wslconfig: aplicar preset? [Default/Gaming/DevHeavy/DevDocker] o Enter=no tocar').Trim()
    if ($w -in @('Default','Gaming','DevHeavy','DevDocker')) {
        Add-Tweak 'wslconfig' ([PSCustomObject]@{ enabled = $true; preset = $w })
    }

    # Juegos instalados -- scan multi-tienda + toggle por juego (D: Get-InstalledGames)
    # Los elegidos van a defender_exclusions (Path) + process_priority (exe -> High).
    Write-Host ''
    Write-Host '  Escaneando juegos instalados (Steam/Epic/GOG/EA/Ubisoft/Xbox)...' -ForegroundColor DarkGray
    [PSCustomObject[]] $allGames = @(Get-InstalledGames)
    [System.Collections.Generic.List[string]] $dePaths = [System.Collections.Generic.List[string]]::new()
    [PSCustomObject] $ppObj = [PSCustomObject]@{}
    [bool] $ppHasEntries = $false
    if ($allGames.Count -gt 0) {
        Write-Host ("  {0} juego(s) detectado(s):" -f $allGames.Count) -ForegroundColor DarkYellow
        # Paginar: mostrar hasta 30 por pantalla para no truncar en silencio
        [int] $pageSize = 30
        [int] $totalPages = [int][Math]::Ceiling($allGames.Count / $pageSize)
        [int] $page = 0
        while ($page -lt $totalPages) {
            [int] $start = $page * $pageSize
            [int] $end   = [Math]::Min($start + $pageSize, $allGames.Count) - 1
            for ([int] $gi = $start; $gi -le $end; $gi++) {
                [string] $src = $allGames[$gi].Source
                [string] $gname = $allGames[$gi].Name
                Write-Host ("    [{0}] [{1}] {2}" -f ($gi + 1), $src, $gname) -ForegroundColor DarkYellow
            }
            if ($totalPages -gt 1) {
                Write-Host ("  (Pagina {0}/{1}; Total: {2})" -f ($page + 1), $totalPages, $allGames.Count) -ForegroundColor DarkGray
            }
            [string] $numIn = (Read-Host '  Numeros a optimizar (Defender + IFEO High; ej. 1 3) o Enter=ninguno').Trim()
            foreach ($tok in @($numIn -split '\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                [int] $idx = 0
                if ([int]::TryParse($tok, [ref] $idx) -and $idx -ge 1 -and $idx -le $allGames.Count) {
                    [PSCustomObject] $chosen = $allGames[$idx - 1]
                    # defender_exclusions: agregar el Path si no esta vacio
                    [object] $cpP = $chosen.PSObject.Properties['Path']
                    if ($null -ne $cpP -and -not [string]::IsNullOrWhiteSpace([string]$cpP.Value)) {
                        $dePaths.Add([string]$cpP.Value)
                    }
                    # process_priority: buscar .exe en el directorio del juego (heuristico)
                    [object] $gpP = $chosen.PSObject.Properties['Path']
                    if ($null -ne $gpP -and -not [string]::IsNullOrWhiteSpace([string]$gpP.Value)) {
                        [string] $gameDir = [string]$gpP.Value
                        [object[]] $exes = @()
                        if (Test-Path -LiteralPath $gameDir -ErrorAction SilentlyContinue) {
                            # Sin -Recurse: solo el nivel raiz del directorio del juego
                            $exes = @(Get-ChildItem -LiteralPath $gameDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                                      Where-Object { $_.Length -gt 1MB })
                        }
                        if ($exes.Count -gt 0) {
                            Write-Host ("    Ejecutables detectados en {0}:" -f $chosen.Name) -ForegroundColor DarkGray
                            for ([int] $ei = 0; $ei -lt $exes.Count; $ei++) {
                                Write-Host ("      [{0}] {1}" -f ($ei + 1), $exes[$ei].Name) -ForegroundColor DarkGray
                            }
                            [string] $exeIn = (Read-Host '      Numeros IFEO High (ej. 1 2) o Enter=ninguno').Trim()
                            foreach ($etok in @($exeIn -split '\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                                [int] $eidx = 0
                                if ([int]::TryParse($etok, [ref] $eidx) -and $eidx -ge 1 -and $eidx -le $exes.Count) {
                                    [string] $exeName = $exes[$eidx - 1].Name
                                    $ppObj | Add-Member -NotePropertyName $exeName -NotePropertyValue 'High' -Force
                                    $ppHasEntries = $true
                                }
                            }
                        }
                    }
                }
            }
            $page++
        }
    } else {
        Write-Host '  No se detectaron juegos instalados (o ninguna tienda compatible presente).' -ForegroundColor DarkGray
        Write-Verbose 'Get-InstalledGames: sin juegos detectados; Xbox/MS Store puede no estar cubierto en este sistema.'
    }
    [string] $deExtra = (Read-Host '  Paths adicionales de exclusion Defender (sep. ;) o Enter=ninguno').Trim()
    if (-not [string]::IsNullOrWhiteSpace($deExtra)) {
        foreach ($ep in @($deExtra -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $dePaths.Add($ep)
        }
    }
    if ($dePaths.Count -gt 0) { Add-Tweak 'defender_exclusions' $dePaths.ToArray() }

    # OOSU profile
    Write-Host ''
    [string] $ooPreset = Get-PresetDefault 'oosu_profile'
    [string] $ooPrompt = if (-not [string]::IsNullOrWhiteSpace($ooPreset)) {
        "  OOSU profile [basic/medium/aggressive/gaming] o Enter=usar preset ($ooPreset)"
    } else {
        '  OOSU profile [basic/medium/aggressive/gaming] o Enter=no tocar'
    }
    [string] $oo = (Read-Host $ooPrompt).Trim().ToLowerInvariant()
    if ($oo -in @('basic','medium','aggressive','gaming')) {
        Add-Tweak 'oosu_profile' $oo
    } elseif (-not [string]::IsNullOrWhiteSpace($ooPreset)) {
        Add-Tweak 'oosu_profile' $ooPreset
    }

    # timer_resolution (registry-only Win11, cost-zero, requiere reinicio)
    Write-Host ''
    [string] $trPreset = Get-PresetDefault 'timer_resolution'
    [string] $trPrompt = if (-not [string]::IsNullOrWhiteSpace($trPreset)) {
        "  Timer Resolution [on/off] o Enter=usar preset ($trPreset)"
    } else {
        '  Timer Resolution [on/off] o Enter=no tocar'
    }
    [string] $tr = (Read-Host $trPrompt).Trim().ToLowerInvariant()
    if ($tr -in @('on', 'off')) {
        Add-Tweak 'timer_resolution' $tr
    } elseif (-not [string]::IsNullOrWhiteSpace($trPreset)) {
        Add-Tweak 'timer_resolution' $trPreset
    }

    # IFEO adicional manual (agrega entradas al $ppObj ya construido por el scan de juegos)
    Write-Host ''
    [string] $ppRaw = (Read-Host '  IFEO adicional manual (ej. game.exe=High;otro.exe=AboveNormal) o Enter=ninguno').Trim()
    if (-not [string]::IsNullOrWhiteSpace($ppRaw)) {
        foreach ($ppPair in @($ppRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            [string[]] $ppKv = $ppPair -split '=', 2
            if ($ppKv.Count -eq 2) {
                [string] $ppExe = $ppKv[0].Trim()
                [string] $ppCls = $ppKv[1].Trim()
                if (-not [string]::IsNullOrWhiteSpace($ppExe) -and $ppCls -in @('High', 'AboveNormal')) {
                    $ppObj | Add-Member -NotePropertyName $ppExe -NotePropertyValue $ppCls -Force
                    $ppHasEntries = $true
                }
            }
        }
    }
    # Guardar process_priority (del scan de juegos + manual combinado)
    if ($ppHasEntries) { Add-Tweak 'process_priority' $ppObj }

    # nvidia_sysmem_fallback (gateado por GPU NVIDIA dedicada + inspector en tools\bin)
    Write-Host ''
    [string] $nsf = (Read-Host '  NVIDIA Sysmem Fallback [prefer_no/default] o Enter=no tocar').Trim().ToLowerInvariant()
    if ($nsf -in @('prefer_no', 'default')) { Add-Tweak 'nvidia_sysmem_fallback' $nsf }

    # Core auto-shaped (gaming-ready, neutro y seguro; el operador lo edita a mano si quiere)
    # v2.0: _tier ya no esta en el JSON (se queda solo en _hardware_snapshot para info).
    [string] $oosuLevel = if ($gt.PSObject.Properties['oosu_profile']) { [string]$gt.oosu_profile } else { 'medium' }

    [PSCustomObject] $hwSnap = [PSCustomObject]@{
        Tier         = if ($MachineProfile.PSObject.Properties['Tier']) { [string]$MachineProfile.Tier } else { '' }
        CpuName      = if ($MachineProfile.PSObject.Properties['CpuName']) { [string]$MachineProfile.CpuName } else { '' }
        RamMB        = if ($MachineProfile.PSObject.Properties['RamMB']) { [int]$MachineProfile.RamMB } else { 0 }
        Manufacturer = if ($MachineProfile.PSObject.Properties['Manufacturer']) { [string]$MachineProfile.Manufacturer } else { '' }
        IsLaptop     = if ($MachineProfile.PSObject.Properties['IsLaptop']) { [bool]$MachineProfile.IsLaptop } else { $false }
    }

    return [PSCustomObject]@{
        _schema_version   = '2.0'
        _kind             = 'named'
        _name             = $name
        _created          = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        _last_applied     = $null
        _hardware_snapshot = $hwSnap

        _use_case   = 'named'
        _description = "Receta nombrada: $name"
        _rationale  = 'Gaming personalizado. Core neutro+seguro (editable a mano); el valor esta en gaming_tweaks.'
        services    = [PSCustomObject]@{ disable = @('Fax','WMPNetworkSvc','RemoteRegistry','DiagTrack','dmwappushservice') }
        performance = [PSCustomObject]@{ visual_profile = 'Balanced' }
        privacy     = [PSCustomObject]@{ level = $oosuLevel; oosu10_cfg = ($oosuLevel + '.cfg'); fallback = 'native' }
        cleanup     = [PSCustomObject]@{ clear_temp = $true }
        startup     = [PSCustomObject]@{ report_only = $true }

        gaming_tweaks = $gt
    }
}
