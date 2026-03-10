Set-StrictMode -Version Latest

# ─── Get-StartupEntries ───────────────────────────────────────────────────────
function Get-StartupEntries {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    [System.Collections.Generic.List[PSCustomObject]] $entries =
        [System.Collections.Generic.List[PSCustomObject]]::new()

    # Registry groups: Run / Run32 (togglable) + RunOnce (list-only)
    [PSCustomObject[]] $regGroups = @(
        [PSCustomObject]@{
            RunPath      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            ApprovedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            Label        = 'HKLM\Run'
            CanToggle    = $true
        }
        [PSCustomObject]@{
            RunPath      = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            ApprovedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
            Label        = 'HKLM\Run32'
            CanToggle    = $true
        }
        [PSCustomObject]@{
            RunPath      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            ApprovedPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            Label        = 'HKCU\Run'
            CanToggle    = $true
        }
        [PSCustomObject]@{
            RunPath      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
            ApprovedPath = $null
            Label        = 'HKLM\RunOnce'
            CanToggle    = $false
        }
        [PSCustomObject]@{
            RunPath      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
            ApprovedPath = $null
            Label        = 'HKCU\RunOnce'
            CanToggle    = $false
        }
    )

    foreach ($group in $regGroups) {
        if (-not (Test-Path $group.RunPath)) { continue }

        [Microsoft.Win32.RegistryKey] $key = Get-Item -Path $group.RunPath -ErrorAction SilentlyContinue
        if ($null -eq $key) { continue }

        foreach ($valueName in $key.GetValueNames()) {
            if ([string]::IsNullOrEmpty($valueName)) { continue }

            [string] $cmd     = [string] $key.GetValue($valueName, '')
            [bool]   $enabled = $true

            # Check StartupApproved: first byte 0x03 means disabled
            if ($group.CanToggle -and
                $null -ne $group.ApprovedPath -and
                (Test-Path $group.ApprovedPath)) {

                [Microsoft.Win32.RegistryKey] $appKey =
                    Get-Item -Path $group.ApprovedPath -ErrorAction SilentlyContinue

                if ($null -ne $appKey) {
                    $raw = $appKey.GetValue($valueName, $null)
                    if ($null -ne $raw -and $raw -is [byte[]] -and $raw.Length -gt 0) {
                        if ($raw[0] -eq 0x03) { $enabled = $false }
                    }
                }
            }

            $entries.Add([PSCustomObject]@{
                Name         = $valueName
                Command      = $cmd
                Location     = $group.Label
                Enabled      = $enabled
                CanToggle    = $group.CanToggle
                Type         = 'Registry'
                RunPath      = $group.RunPath
                ApprovedPath = $group.ApprovedPath
                FilePath     = $null
            })
        }
    }

    # Startup folders
    [string[]] $startupFolders = @(
        [System.Environment]::GetFolderPath('Startup')
        [System.Environment]::GetFolderPath('CommonStartup')
    )
    [string[]] $folderLabels = @('Folder-User', 'Folder-AllUsers')

    for ([int] $fi = 0; $fi -lt $startupFolders.Length; $fi++) {
        [string] $folder = $startupFolders[$fi]
        [string] $label  = $folderLabels[$fi]

        if (-not (Test-Path $folder)) { continue }

        Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | ForEach-Object {
            [string] $fPath   = $_.FullName
            [bool]   $enabled = ($_.Extension -ne '.disabled')

            $entries.Add([PSCustomObject]@{
                Name         = $_.BaseName
                Command      = $fPath
                Location     = $label
                Enabled      = $enabled
                CanToggle    = $true
                Type         = 'Folder'
                RunPath      = $null
                ApprovedPath = $null
                FilePath     = $fPath
            })
        }
    }

    return [PSCustomObject[]] $entries.ToArray()
}

# ─── Set-StartupEntry ─────────────────────────────────────────────────────────
function Set-StartupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Entry,
        [Parameter(Mandatory)] [bool]           $Enabled
    )

    if (-not $Entry.CanToggle) {
        return [PSCustomObject]@{ Success = $false; Error = 'Las entradas RunOnce no se pueden modificar.' }
    }

    if ($Entry.Enabled -eq $Enabled) {
        return [PSCustomObject]@{ Success = $true; AlreadySet = $true }
    }

    try {
        if ($Entry.Type -eq 'Registry') {
            if ([string]::IsNullOrEmpty($Entry.ApprovedPath)) {
                return [PSCustomObject]@{ Success = $false; Error = 'Sin ApprovedPath para esta entrada.' }
            }

            if (-not (Test-Path $Entry.ApprovedPath)) {
                $null = New-Item -Path $Entry.ApprovedPath -Force
            }

            # 12-byte binary: byte 0 = 0x02 (enabled) / 0x03 (disabled), resto ceros
            [byte[]] $value = [byte[]]::new(12)
            $value[0] = if ($Enabled) { [byte] 0x02 } else { [byte] 0x03 }

            Set-ItemProperty -Path $Entry.ApprovedPath -Name $Entry.Name -Value $value -Type Binary

            return [PSCustomObject]@{ Success = $true }
        }
        elseif ($Entry.Type -eq 'Folder') {
            [string] $currentPath = $Entry.FilePath

            if ($Enabled) {
                # Quitar .disabled
                [string] $newName = [System.IO.Path]::GetFileName(($currentPath -replace '\.disabled$', ''))
                Rename-Item -Path $currentPath -NewName $newName -Force
            }
            else {
                # Agregar .disabled
                [string] $newName = [System.IO.Path]::GetFileName($currentPath) + '.disabled'
                Rename-Item -Path $currentPath -NewName $newName -Force
            }

            return [PSCustomObject]@{ Success = $true }
        }
        else {
            return [PSCustomObject]@{ Success = $false; Error = "Tipo desconocido: $($Entry.Type)" }
        }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

# ─── Open-Autoruns ────────────────────────────────────────────────────────────
function Open-Autoruns {
    [CmdletBinding()]
    param()

    [string] $exePath = Join-Path $PSScriptRoot '..\tools\bin\Autoruns.exe'

    if (-not (Test-Path $exePath)) {
        return [PSCustomObject]@{ Success = $false; Error = 'Autoruns.exe no encontrado. Descargalo desde [T] Herramientas.' }
    }

    try {
        Start-Process -FilePath $exePath
        return [PSCustomObject]@{ Success = $true }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
