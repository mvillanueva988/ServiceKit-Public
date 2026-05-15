Set-StrictMode -Version Latest

# WSL2 .wslconfig generator + reader.
# Spec: https://learn.microsoft.com/en-us/windows/wsl/wsl-config
# Reference recipes: Doc 1 sec 1.8, Doc 2 sec 2.13, Doc 4 sec 6.1
#
# Path canónico: $env:USERPROFILE\.wslconfig (per-user, NO en el WSL distro).
# Aplicar cambios: `wsl --shutdown` (la VM tarda hasta 8s en parar — "8-second rule").

$script:WslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'

# ─── Test-WslAvailable ────────────────────────────────────────────────────────
function Test-WslAvailable {
    <#
    .SYNOPSIS
        Verifica si WSL está instalado y accesible. Read-only. Smoke-safe.
    #>
    [CmdletBinding()]
    param()

    $wsl = Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool] $wsl
}

# ─── Get-WslConfig ────────────────────────────────────────────────────────────
function Get-WslConfig {
    <#
    .SYNOPSIS
        Lee y parsea el .wslconfig actual del usuario. Read-only. Smoke-safe.

    .OUTPUTS
        PSCustomObject con:
          - Exists         : si el archivo existe
          - Path           : ruta del archivo
          - Sections       : hashtable [string]→hashtable de claves crudas
          - Wsl2           : shortcut a Sections['wsl2'] (o hashtable vacía)
    #>
    [CmdletBinding()]
    param()

    [bool] $exists = Test-Path -Path $script:WslConfigPath -PathType Leaf

    [hashtable] $sections = @{}
    if ($exists) {
        [string] $currentSection = ''
        foreach ($rawLine in (Get-Content -LiteralPath $script:WslConfigPath -ErrorAction SilentlyContinue)) {
            [string] $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }

            if ($line -match '^\[([^\]]+)\]$') {
                $currentSection = $Matches[1].Trim().ToLowerInvariant()
                if (-not $sections.ContainsKey($currentSection)) {
                    $sections[$currentSection] = @{}
                }
                continue
            }

            if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$' -and -not [string]::IsNullOrEmpty($currentSection)) {
                $sections[$currentSection][$Matches[1]] = $Matches[2].Trim()
            }
        }
    }

    [hashtable] $wsl2 = if ($sections.ContainsKey('wsl2')) { $sections['wsl2'] } else { @{} }

    return [PSCustomObject]@{
        Exists   = $exists
        Path     = $script:WslConfigPath
        Sections = $sections
        Wsl2     = $wsl2
    }
}

# ─── New-WslConfig ────────────────────────────────────────────────────────────
function New-WslConfig {
    <#
    .SYNOPSIS
        Construye el contenido de un .wslconfig según el preset solicitado.
        NO escribe a disco — devuelve el string. Usar Set-WslConfig para persistir.

        Presets disponibles:
          - 'Default'   : 4GB / processors auto / autoMemoryReclaim+sparseVhd.
                          Razonable para máquinas de oficina con WSL ocasional.
          - 'Gaming'    : 4GB / processors limitado / mismo set conservador.
                          Prioriza dejar RAM libre para CS2/AAA.
          - 'DevHeavy'  : 8-10GB / mirrored networking / firewall / DNS tunneling.
                          Para Claude Code en repos grandes; rompe Docker Desktop binding.
          - 'DevDocker' : 8GB / NAT networking (no mirrored).
                          Para flujos que requieren Docker Desktop.

        Cualquier parámetro explícito override el preset.

    .EXAMPLE
        New-WslConfig -Preset Gaming
        New-WslConfig -Preset DevHeavy -MemoryGB 12  # override
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateSet('Default', 'Gaming', 'DevHeavy', 'DevDocker')]
        [string] $Preset = 'Default',

        [Parameter()]
        [Nullable[int]] $MemoryGB = $null,

        [Parameter()]
        [Nullable[int]] $Processors = $null,

        [Parameter()]
        [Nullable[int]] $SwapGB = $null,

        [Parameter()]
        [ValidateSet('mirrored', 'nat')]
        [string] $NetworkingMode = '',

        [Parameter()]
        [ValidateSet('gradual', 'dropcache', 'disabled')]
        [string] $AutoMemoryReclaim = '',

        [Parameter()]
        [Nullable[bool]] $DnsTunneling = $null,

        [Parameter()]
        [Nullable[bool]] $Firewall = $null,

        [Parameter()]
        [Nullable[bool]] $SparseVhd = $null
    )

    # Defaults por preset
    [hashtable] $cfg = switch ($Preset) {
        'Default' {
            @{ MemoryGB = 4; Processors = $null; SwapGB = 2;
               NetworkingMode = 'nat'; AutoMemoryReclaim = 'dropcache';
               DnsTunneling = $true; Firewall = $true; SparseVhd = $true }
        }
        'Gaming' {
            @{ MemoryGB = 4; Processors = 4; SwapGB = 2;
               NetworkingMode = 'nat'; AutoMemoryReclaim = 'dropcache';
               DnsTunneling = $true; Firewall = $true; SparseVhd = $true }
        }
        'DevHeavy' {
            @{ MemoryGB = 8; Processors = $null; SwapGB = 4;
               NetworkingMode = 'mirrored'; AutoMemoryReclaim = 'dropcache';
               DnsTunneling = $true; Firewall = $true; SparseVhd = $true }
        }
        'DevDocker' {
            @{ MemoryGB = 8; Processors = $null; SwapGB = 4;
               NetworkingMode = 'nat'; AutoMemoryReclaim = 'dropcache';
               DnsTunneling = $true; Firewall = $true; SparseVhd = $true }
        }
    }

    # Apply overrides
    if ($null -ne $MemoryGB)              { $cfg.MemoryGB = [int] $MemoryGB }
    if ($null -ne $Processors)            { $cfg.Processors = [int] $Processors }
    if ($null -ne $SwapGB)                { $cfg.SwapGB = [int] $SwapGB }
    if (-not [string]::IsNullOrEmpty($NetworkingMode))   { $cfg.NetworkingMode = $NetworkingMode }
    if (-not [string]::IsNullOrEmpty($AutoMemoryReclaim)){ $cfg.AutoMemoryReclaim = $AutoMemoryReclaim }
    if ($null -ne $DnsTunneling)          { $cfg.DnsTunneling = [bool] $DnsTunneling }
    if ($null -ne $Firewall)              { $cfg.Firewall = [bool] $Firewall }
    if ($null -ne $SparseVhd)             { $cfg.SparseVhd = [bool] $SparseVhd }

    # Build content
    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by PCTk — preset: ' + $Preset)
    $lines.Add('# Apply with: wsl --shutdown   (then re-launch WSL)')
    $lines.Add('[wsl2]')
    $lines.Add(('memory=' + $cfg.MemoryGB + 'GB'))
    if ($null -ne $cfg.Processors) { $lines.Add(('processors=' + $cfg.Processors)) }
    $lines.Add(('swap=' + $cfg.SwapGB + 'GB'))
    $lines.Add(('networkingMode=' + $cfg.NetworkingMode))
    $lines.Add(('autoMemoryReclaim=' + $cfg.AutoMemoryReclaim))
    $lines.Add(('dnsTunneling=' + ($cfg.DnsTunneling.ToString().ToLowerInvariant())))
    $lines.Add(('firewall=' + ($cfg.Firewall.ToString().ToLowerInvariant())))
    $lines.Add(('sparseVhd=' + ($cfg.SparseVhd.ToString().ToLowerInvariant())))

    return [string] ($lines -join "`r`n")
}

# ─── Set-WslConfig ────────────────────────────────────────────────────────────
function Set-WslConfig {
    <#
    .SYNOPSIS
        Escribe contenido al .wslconfig del usuario. Hace backup del archivo
        previo (si existe) a .wslconfig.bak antes de sobrescribir.

        El cambio NO toma efecto hasta `wsl --shutdown` (8-second rule).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter()]
        [switch] $NoBackup
    )

    [System.Collections.Generic.List[string]] $applied = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  = [System.Collections.Generic.List[string]]::new()
    [string] $backupPath = $script:WslConfigPath + '.bak'

    try {
        if (-not $NoBackup -and (Test-Path $script:WslConfigPath)) {
            Copy-Item -LiteralPath $script:WslConfigPath -Destination $backupPath -Force -ErrorAction Stop
            $applied.Add('Backup creado en .wslconfig.bak')
        }

        # UTF-8 sin BOM para .wslconfig (WSL kernel lo parsea como ASCII/UTF-8 plano)
        [System.IO.File]::WriteAllText($script:WslConfigPath, $Content, [System.Text.UTF8Encoding]::new($false))
        $applied.Add('.wslconfig escrito en ' + $script:WslConfigPath)
    }
    catch { $errors.Add($_.Exception.Message) }

    return [PSCustomObject]@{
        Success       = ($errors.Count -eq 0)
        Applied       = $applied.ToArray()
        Errors        = $errors.ToArray()
        Path          = $script:WslConfigPath
        BackupPath    = if (-not $NoBackup) { $backupPath } else { $null }
        NextStep      = 'Ejecutar `wsl --shutdown` desde PowerShell para que el cambio tome efecto.'
    }
}

# ─── Invoke-WslShutdown ───────────────────────────────────────────────────────
function Invoke-WslShutdown {
    <#
    .SYNOPSIS
        Detiene la VM de WSL2 limpiamente (`wsl --shutdown`). La próxima
        invocación de wsl re-lee el .wslconfig actual.

        Espera 10s adicionales — la VM tarda hasta 8s en parar realmente
        ("8-second rule" documentado por Microsoft).
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-WslAvailable)) {
        return [PSCustomObject]@{
            Success = $false
            Reason  = 'wsl.exe no encontrado en PATH. WSL2 no parece estar instalado.'
        }
    }

    & wsl.exe --shutdown 2>&1 | Out-Null
    [bool] $ok = ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 10

    return [PSCustomObject]@{
        Success = $ok
        Reason  = if ($ok) {
            'WSL2 detenido. El proximo `wsl` va a leer el .wslconfig actualizado.'
        } else {
            "wsl --shutdown exit code $LASTEXITCODE"
        }
    }
}
