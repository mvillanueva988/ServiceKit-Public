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

    [string[]] $regPaths = if ([Environment]::Is64BitOperatingSystem) {
        @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    } else {
        # En x86 puro WOW6432Node no existe como clave separada — evitar duplicados
        @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    }

    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($path in $regPaths) {
        foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
            # Acceso seguro a propiedades opcionales del registro (StrictMode-safe)
            $pDN  = $item.PSObject.Properties['DisplayName']
            $pSC  = $item.PSObject.Properties['SystemComponent']
            $pPKN = $item.PSObject.Properties['ParentKeyName']

            # Excluir: sin nombre, componentes del sistema, sub-entradas de padre visible
            if ($null -eq $pDN  -or [string]::IsNullOrWhiteSpace($pDN.Value))             { continue }
            if ($null -ne $pSC  -and $pSC.Value -eq 1)                                    { continue }
            if ($null -ne $pPKN -and -not [string]::IsNullOrWhiteSpace($pPKN.Value))      { continue }
            if (-not $seen.Add(([string] $pDN.Value).Trim()))                              { continue }  # dedup

            $pDV  = $item.PSObject.Properties['DisplayVersion']
            $pPub = $item.PSObject.Properties['Publisher']
            $pUS  = $item.PSObject.Properties['UninstallString']
            $pQUS = $item.PSObject.Properties['QuietUninstallString']
            $pES  = $item.PSObject.Properties['EstimatedSize']

            $list.Add([PSCustomObject]@{
                Name                 = [string] (([string] $pDN.Value).Trim())
                Version              = if ($null -ne $pDV)  { [string] $pDV.Value  } else { '' }
                Publisher            = if ($null -ne $pPub) { [string] $pPub.Value } else { '' }
                UninstallString      = if ($null -ne $pUS)  { [string] $pUS.Value  } else { '' }
                QuietUninstallString = if ($null -ne $pQUS) { [string] $pQUS.Value } else { '' }
                SizeMB               = if ($null -ne $pES -and $pES.Value -gt 0) {
                                           [math]::Round($pES.Value / 1024.0, 0)
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

# ─── Start-Win32AppsJob ───────────────────────────────────────────────────────
function Start-Win32AppsJob {
    <#
    .SYNOPSIS
        Carga la lista completa de apps Win32 instaladas de forma asíncrona.
    #>
    [CmdletBinding()]
    param()

    [string] $fnBody = ${Function:Get-InstalledWin32Apps}.ToString()
    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Get-InstalledWin32Apps {
$fnBody
}
Get-InstalledWin32Apps
"@)
    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'Win32AppsLoad'
}

# ─── Start-UwpAppsJob ────────────────────────────────────────────────────────
function Start-UwpAppsJob {
    <#
    .SYNOPSIS
        Carga la lista completa de apps UWP instaladas de forma asíncrona.
    #>
    [CmdletBinding()]
    param()

    [string] $fnBody = ${Function:Get-InstalledUwpApps}.ToString()
    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Get-InstalledUwpApps {
$fnBody
}
Get-InstalledUwpApps
"@)
    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'UwpAppsLoad'
}
