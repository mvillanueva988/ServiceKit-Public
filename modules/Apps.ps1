Set-StrictMode -Version Latest

# ─── Get-InstalledWin32Apps ───────────────────────────────────────────────────
function Get-InstalledWin32Apps {
    <#
    .SYNOPSIS
        Lee los tres hives del registro donde Windows registra apps instaladas.
        Equivalente a lo que muestra Panel de Control > Desinstalar un programa.
        Retorna array ordenado por nombre, deduplicado, sin componentes del sistema.
    #>
    [CmdletBinding()]
    param(
        [string] $Filter = ''
    )

    [string[]] $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($path in $regPaths) {
        foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
            # Excluir: sin nombre, componentes del sistema, sub-entradas de padre visible
            if ([string]::IsNullOrWhiteSpace($item.DisplayName))          { continue }
            if ($item.SystemComponent -eq 1)                               { continue }
            if (-not [string]::IsNullOrWhiteSpace($item.ParentKeyName))   { continue }
            if (-not $seen.Add($item.DisplayName.Trim()))                  { continue }  # dedup

            $list.Add([PSCustomObject]@{
                Name                 = [string] $item.DisplayName.Trim()
                Version              = [string] $item.DisplayVersion
                Publisher            = [string] $item.Publisher
                UninstallString      = [string] $item.UninstallString
                QuietUninstallString = [string] $item.QuietUninstallString
                SizeMB               = if ($item.EstimatedSize -gt 0) {
                                           [math]::Round($item.EstimatedSize / 1024.0, 0)
                                       } else { $null }
            })
        }
    }

    [PSCustomObject[]] $sorted = @($list | Sort-Object Name)

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        try {
            $sorted = @($sorted | Where-Object { $_.Name -match $Filter -or $_.Publisher -match $Filter })
        }
        catch {
            # Regex inválido — caer a comparación literal
            $sorted = @($sorted | Where-Object { $_.Name -like "*$Filter*" -or $_.Publisher -like "*$Filter*" })
        }
    }

    return $sorted
}

# ─── Get-InstalledUwpApps ─────────────────────────────────────────────────────
function Get-InstalledUwpApps {
    <#
    .SYNOPSIS
        Lista paquetes AppX del usuario actual. Excluye resource packages, bundles
        y paquetes marcados NonRemovable. Incluye apps de Microsoft (Xbox, Cortana,
        etc.) para que el usuario pueda elegir qué eliminar.
        Los flags IsMicrosoft permiten colorear en la UI.
    #>
    [CmdletBinding()]
    param(
        [string] $Filter = ''
    )

    [PSCustomObject[]] $apps = @(
        Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.IsResourcePackage -and
                -not $_.IsBundle -and
                $_.NonRemovable -ne $true
            } |
            ForEach-Object {
                # Construir nombre legible: quitar prefijo "Publisher." y separar CamelCase
                [string] $display = $_.Name -replace '^[A-Za-z0-9]+\.', ''
                $display = [regex]::Replace($display, '([a-z])([A-Z])', '$1 $2')
                if ([string]::IsNullOrWhiteSpace($display)) { $display = $_.Name }

                [PSCustomObject]@{
                    Name            = [string] $_.Name
                    DisplayName     = $display
                    PackageFullName = [string] $_.PackageFullName
                    Publisher       = [string] $_.Publisher
                    Version         = [string] $_.Version
                    IsMicrosoft     = ($_.Publisher -match 'CN=Microsoft Corporation' -or
                                       $_.Publisher -match 'CN=Microsoft Windows')
                }
            } |
            Sort-Object IsMicrosoft, DisplayName   # terceros primero
    )

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        try {
            $apps = @($apps | Where-Object { $_.DisplayName -match $Filter -or $_.Name -match $Filter })
        }
        catch {
            $apps = @($apps | Where-Object { $_.DisplayName -like "*$Filter*" -or $_.Name -like "*$Filter*" })
        }
    }

    return $apps
}

# ─── Invoke-Win32Uninstall ────────────────────────────────────────────────────
function Invoke-Win32Uninstall {
    <#
    .SYNOPSIS
        Desinstala una app Win32 usando el método más silencioso disponible.
        Prioridad: QuietUninstallString > MSI /qn > UninstallString (abre UI).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $App
    )

    # ── Prioridad 1: QuietUninstallString ────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($App.QuietUninstallString)) {
        return _Invoke-UninstallCommand -CmdStr $App.QuietUninstallString -Method 'Quiet' -AppName $App.Name
    }

    # ── Prioridad 2: MSI — extraer GUID y lanzar /X silencioso ───────────────
    if ($App.UninstallString -match 'MsiExec\.exe\s+/[IXx]\{([^}]+)\}') {
        [string] $guid = $Matches[1]
        try {
            $proc = Start-Process -FilePath 'msiexec.exe' `
                                  -ArgumentList "/X{$guid} /qn /norestart" `
                                  -Wait -PassThru -NoNewWindow
            return [PSCustomObject]@{
                Success  = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1605)
                Method   = 'MSI'
                App      = $App.Name
                ExitCode = $proc.ExitCode
            }
        }
        catch {
            return [PSCustomObject]@{ Success = $false; Method = 'MSI'; App = $App.Name; Error = $_.Exception.Message }
        }
    }

    # ── Prioridad 3: UninstallString directo (puede abrir UI) ────────────────
    if (-not [string]::IsNullOrWhiteSpace($App.UninstallString)) {
        return _Invoke-UninstallCommand -CmdStr $App.UninstallString -Method 'Interactive' -AppName $App.Name
    }

    return [PSCustomObject]@{ Success = $false; Method = 'None'; App = $App.Name; Error = 'Sin UninstallString en el registro' }
}

# Helper privado — parsea "exe args" y ejecuta
function _Invoke-UninstallCommand {
    [CmdletBinding()]
    param(
        [string] $CmdStr,
        [string] $Method,
        [string] $AppName
    )

    [string] $exe     = ''
    [string] $cmdArgs = ''

    if ($CmdStr -match '^"([^"]+)"\s*(.*)$') {
        $exe     = $Matches[1]
        $cmdArgs = $Matches[2].Trim()
    }
    elseif ($CmdStr -match '^(\S+)\s*(.*)$') {
        $exe     = $Matches[1]
        $cmdArgs = $Matches[2].Trim()
    }
    else {
        return [PSCustomObject]@{ Success = $false; Method = $Method; App = $AppName; Error = "No se pudo parsear: $CmdStr" }
    }

    try {
        $startParams = @{ FilePath = $exe; Wait = $true; PassThru = $true }
        if ($cmdArgs)                { $startParams['ArgumentList'] = $cmdArgs }
        if ($Method -eq 'Quiet')     { $startParams['NoNewWindow']  = $true }

        $proc = Start-Process @startParams
        return [PSCustomObject]@{
            Success  = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1605)
            Method   = $Method
            App      = $AppName
            ExitCode = $proc.ExitCode
        }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Method = $Method; App = $AppName; Error = $_.Exception.Message }
    }
}
