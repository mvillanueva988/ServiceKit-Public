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

    # Tareas programadas con trigger de arranque o logon
    try {
        [object[]] $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        foreach ($task in $allTasks) {
            [bool] $hasTrigger = $false
            if ($null -ne $task.Triggers) {
                foreach ($trig in $task.Triggers) {
                    if ($null -ne $trig -and
                        $trig.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')) {
                        $hasTrigger = $true
                        break
                    }
                }
            }
            if (-not $hasTrigger) { continue }

            [bool]   $taskEnabled = ($task.State -ne 'Disabled')
            [string] $taskCmd     = ''
            try {
                [object[]] $acts = @($task.Actions)
                if ($acts.Count -gt 0) { $taskCmd = [string] $acts[0].Execute }
            } catch { }

            $entries.Add([PSCustomObject]@{
                Name         = [string] $task.TaskName
                Command      = $taskCmd
                Location     = 'Task'
                Enabled      = $taskEnabled
                CanToggle    = $true
                Type         = 'Task'
                RunPath      = $null
                ApprovedPath = $null
                FilePath     = $null
                TaskPath     = [string] $task.TaskPath
                TaskName     = [string] $task.TaskName
            })
        }
    } catch { }

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
        elseif ($Entry.Type -eq 'Task') {
            if ($Enabled) {
                $null = Enable-ScheduledTask  -TaskPath $Entry.TaskPath -TaskName $Entry.TaskName -ErrorAction Stop
            }
            else {
                $null = Disable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.TaskName -ErrorAction Stop
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

# ─── Get-StartupDescription ───────────────────────────────────────────────────
# DRAFT a validar por Mateo (criterio de campo). Mapa curado nombre+comando ->
# descripcion corta + hint (dejar / opcional / seguro apagar). Match por subcadena
# (case-insensitive), primer match gana -> ordenar de especifico a generico.
# Devuelve '' si no hay match conocido (honesto: no inventar para lo ambiguo).
function Get-StartupDescription {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Name
    )

    # Match SOLO sobre el Name: el Command (ruta/cmdline) mete falsos positivos
    # (ej. el RunOnce "Application Restart" cuyo comando referencia a Brave, o paths
    # que contienen "office"/"logi"). El Name es el identificador real de la entrada.
    [string] $hay = ([string]$Name).ToLowerInvariant()

    [object[]] $rules = @(
        # --- Audio ---
        @{ K = 'rtkaud';              D = 'Audio Realtek (dejar)' }
        @{ K = 'nahimic';             D = 'Nahimic audio (opcional)' }
        @{ K = 'fxsound';             D = 'FxSound mejora audio (opcional)' }
        @{ K = 'edb90prosound';       D = 'FxSound mejora audio (opcional)' }
        @{ K = 'amdnoisesuppression'; D = 'AMD supresion de ruido de mic (opcional)' }
        @{ K = 'equalizerapo';        D = 'Equalizer APO updater (seguro apagar)' }
        @{ K = 'amdscosupport';       D = 'AMD audio Bluetooth (dejar)' }
        # --- GPU / OEM / perifericos ---
        @{ K = 'nvidia broadcast';    D = 'NVIDIA Broadcast mic/cam IA (opcional, consume)' }
        @{ K = 'nvcontainer';         D = 'NVIDIA driver/panel (dejar)' }
        @{ K = 'armoury';             D = 'ASUS Armoury Crate (opcional)' }
        @{ K = 'lenovolegion';        D = 'Lenovo Legion Toolkit (opcional)' }
        @{ K = 'startcn';             D = 'MSI Center / Dragon Center (opcional)' }
        @{ K = 'lightshot';           D = 'Lightshot capturas de pantalla (opcional)' }
        @{ K = 'fwcustom';            D = 'Lightshot capturas de pantalla (opcional)' }
        @{ K = 'logitech';            D = 'Logitech G HUB / Options (opcional)' }
        @{ K = 'lghub';               D = 'Logitech G HUB (opcional)' }
        @{ K = 'logioptions';         D = 'Logitech Options (opcional)' }
        @{ K = 'razer';               D = 'Razer Synapse (opcional)' }
        @{ K = 'icue';                D = 'Corsair iCUE (opcional)' }
        @{ K = 'afterburner';         D = 'MSI Afterburner OC/monitor (opcional)' }
        @{ K = 'supportassist';       D = 'Dell SupportAssist (opcional)' }
        @{ K = 'vantage';             D = 'Lenovo Vantage (opcional)' }
        # --- Remoto / soporte ---
        @{ K = 'anydesk';             D = 'AnyDesk acceso remoto (dejar)' }
        @{ K = 'teamviewer';          D = 'TeamViewer acceso remoto (dejar)' }
        # --- Tuning de CPU (terceros) ---
        @{ K = 'process lasso';       D = 'Process Lasso gestion de CPU (opcional)' }
        @{ K = 'parkcontrol';         D = 'ParkControl parking de nucleos (opcional)' }
        # --- Apps comunes ---
        @{ K = 'discord';             D = 'Discord chat/voz (opcional)' }
        @{ K = 'whatsapp';            D = 'WhatsApp (opcional)' }
        @{ K = 'telegram';            D = 'Telegram (opcional)' }
        @{ K = 'steam';               D = 'Steam (opcional)' }
        @{ K = 'epicgames';           D = 'Epic Games Launcher (opcional)' }
        @{ K = 'spotify';             D = 'Spotify (opcional)' }
        @{ K = 'onedrive';            D = 'OneDrive sincronizacion (opcional)' }
        @{ K = 'googledrive';         D = 'Google Drive sincronizacion (opcional)' }
        @{ K = 'dropbox';             D = 'Dropbox sincronizacion (opcional)' }
        @{ K = 'megasync';            D = 'MEGAsync sincronizacion (opcional)' }
        @{ K = 'notion';              D = 'Notion notas (opcional)' }
        @{ K = 'teams';               D = 'Microsoft Teams (opcional)' }
        # --- Actualizadores (normalmente seguro apagar) ---
        @{ K = 'bravesoftware';       D = 'Actualizador Brave (seguro apagar)' }
        @{ K = 'googleupdat';         D = 'Actualizador Google/Chrome (seguro apagar)' }
        @{ K = 'edgeupdate';          D = 'Actualizador Edge (seguro apagar)' }
        @{ K = 'edgeautolaunch';      D = 'Edge se reabre solo al inicio (seguro apagar)' }
        @{ K = 'javaupdate';          D = 'Java updater (seguro apagar)' }
        @{ K = 'itunes';              D = 'iTunes helper (seguro apagar)' }
        @{ K = 'bonjour';             D = 'Apple Bonjour (seguro apagar)' }
        @{ K = 'adobe';               D = 'Adobe updater (seguro apagar)' }
        # --- Microsoft / Office / Windows (normalmente dejar) ---
        @{ K = 'office';              D = 'Microsoft Office mantenimiento/updates (dejar)' }
        @{ K = 'rms rights policy';   D = 'Office RMS plantillas de permisos (dejar)' }
        @{ K = 'securityhealth';      D = 'Windows Security (dejar)' }
        @{ K = 'application restart'; D = 'Restaurar apps tras reinicio' }
        @{ K = 'verifiedpublisher';  D = 'Windows verificacion de certificados (dejar)' }
        @{ K = 'pre-staged app';     D = 'Windows limpieza de apps (dejar)' }
        @{ K = 'ucpd';               D = 'Windows proteccion de navegador default (dejar)' }
        @{ K = 'keypregen';          D = 'Windows criptografia (dejar)' }
        @{ K = 'clipesu';            D = 'Windows portapapeles (dejar)' }
    )

    foreach ($r in $rules) {
        if ($hay -like ('*' + [string]$r.K + '*')) { return [string]$r.D }
    }
    return ''
}
