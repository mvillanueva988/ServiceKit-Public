Set-StrictMode -Version Latest

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot

function Write-ToolkitAuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Action,

        [Parameter()]
        [string] $Status = 'Info',

        [Parameter()]
        [string] $Summary = '',

        [Parameter()]
        [object] $Details = $null
    )

    try {
        [string] $auditDir = Join-Path $script:ToolkitRoot 'output\audit'
        if (-not (Test-Path $auditDir)) {
            New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
        }

        [string] $logPath = Join-Path $auditDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
        $entry = [ordered]@{
            Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
            Action    = $Action
            Status    = $Status
            Summary   = $Summary
            Details   = $Details
        }

        Add-Content -LiteralPath $logPath -Value (($entry | ConvertTo-Json -Compress -Depth 8))
    }
    catch {
        # El audit log nunca debe romper la operacion principal.
    }
}

function Convert-ToolkitDateDisplay {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return 'Desconocida' }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm')
    }

    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        try {
            [double] $oaDate = [double] $Value
            if ($oaDate -ge 2 -and $oaDate -le 2958465) {
                return ([datetime]::FromOADate($oaDate)).ToString('yyyy-MM-dd HH:mm')
            }
        }
        catch {
            # Continuar con parse de string
        }
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]) {
        try {
            [long] $numericValue = [long] $Value
            if ($numericValue -ge 116444736000000000 -and $numericValue -le 2650467743999999999) {
                return ([datetime]::FromFileTimeUtc($numericValue).ToLocalTime()).ToString('yyyy-MM-dd HH:mm')
            }

            if ($numericValue -ge 2 -and $numericValue -le 2958465) {
                return ([datetime]::FromOADate([double]$numericValue)).ToString('yyyy-MM-dd HH:mm')
            }
        }
        catch {
            # Mantener fallback por string
        }
    }

    [string] $raw = [string] $Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'Desconocida' }

    if ($raw -match '^\d{16,19}$') {
        try {
            [long] $fileTime = [long] $raw
            if ($fileTime -ge 116444736000000000 -and $fileTime -le 2650467743999999999) {
                return ([datetime]::FromFileTimeUtc($fileTime).ToLocalTime()).ToString('yyyy-MM-dd HH:mm')
            }
        }
        catch {
            return 'Desconocida'
        }
    }

    if ($raw -match '^\d+(\.\d+)?$') {
        try {
            [double] $rawNumeric = [double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($rawNumeric -ge 2 -and $rawNumeric -le 2958465) {
                return ([datetime]::FromOADate($rawNumeric)).ToString('yyyy-MM-dd HH:mm')
            }
            return 'Desconocida'
        }
        catch {
            return 'Desconocida'
        }
    }

    try {
        return ([datetime]::Parse($raw, [System.Globalization.CultureInfo]::CurrentCulture)).ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        try {
            return ([datetime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd HH:mm')
        }
        catch {
            return 'Desconocida'
        }
    }
}

function Get-WindowsUpdateStatus {
    [CmdletBinding()]
    param(
        [Parameter()]
        [bool] $IsLtsc = $false
    )

    $result = [PSCustomObject]@{
        LastInstall = 'Desconocida'
        LastCheck   = 'Desconocida'
        Source      = 'Ninguna'
    }

    [string] $uxPath            = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    [string] $legacyInstallPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install'
    [string] $legacyDetectPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect'

    try {
        if (-not $IsLtsc) {
            $regUx = Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue
            if ($regUx) {
                $pCheck = $regUx.PSObject.Properties['LastCheckedForUpdates']
                if ($pCheck -and -not [string]::IsNullOrWhiteSpace([string] $pCheck.Value)) {
                    $result.LastCheck = Convert-ToolkitDateDisplay -Value $pCheck.Value
                }

                foreach ($propName in @('LastSuccessfulInstallTime', 'LastInstallTime')) {
                    $pInstall = $regUx.PSObject.Properties[$propName]
                    if ($pInstall -and -not [string]::IsNullOrWhiteSpace([string] $pInstall.Value)) {
                        $result.LastInstall = Convert-ToolkitDateDisplay -Value $pInstall.Value
                        break
                    }
                }

                if ($result.LastInstall -ne 'Desconocida' -or $result.LastCheck -ne 'Desconocida') {
                    $result.Source = 'UX'
                }
            }
        }

        if ($result.LastInstall -eq 'Desconocida') {
            $regInstall = Get-ItemProperty -Path $legacyInstallPath -ErrorAction SilentlyContinue
            if ($regInstall -and $regInstall.PSObject.Properties['LastSuccessTime']) {
                [string] $legacyInstallDate = Convert-ToolkitDateDisplay -Value $regInstall.LastSuccessTime
                if ($legacyInstallDate -ne 'Desconocida') {
                    $result.LastInstall = $legacyInstallDate
                    $result.Source = 'Legacy'
                }
            }
        }

        if ($result.LastCheck -eq 'Desconocida') {
            $regCheck = Get-ItemProperty -Path $legacyDetectPath -ErrorAction SilentlyContinue
            if ($regCheck -and $regCheck.PSObject.Properties['LastSuccessTime']) {
                [string] $legacyCheckDate = Convert-ToolkitDateDisplay -Value $regCheck.LastSuccessTime
                if ($legacyCheckDate -ne 'Desconocida') {
                    $result.LastCheck = $legacyCheckDate
                    $result.Source = 'Legacy'
                }
            }
        }

        if ($IsLtsc -and ($result.LastInstall -eq 'Desconocida' -or $result.LastCheck -eq 'Desconocida')) {
            $regUxFallback = Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue
            if ($regUxFallback) {
                if ($result.LastCheck -eq 'Desconocida') {
                    $pCheckFallback = $regUxFallback.PSObject.Properties['LastCheckedForUpdates']
                    if ($pCheckFallback -and -not [string]::IsNullOrWhiteSpace([string] $pCheckFallback.Value)) {
                        [string] $fallbackCheck = Convert-ToolkitDateDisplay -Value $pCheckFallback.Value
                        if ($fallbackCheck -ne 'Desconocida') {
                            $result.LastCheck = $fallbackCheck
                        }
                    }
                }
                if ($result.LastInstall -eq 'Desconocida') {
                    foreach ($propName in @('LastSuccessfulInstallTime', 'LastInstallTime')) {
                        $pInstallFallback = $regUxFallback.PSObject.Properties[$propName]
                        if ($pInstallFallback -and -not [string]::IsNullOrWhiteSpace([string] $pInstallFallback.Value)) {
                            [string] $fallbackInstall = Convert-ToolkitDateDisplay -Value $pInstallFallback.Value
                            if ($fallbackInstall -ne 'Desconocida') {
                                $result.LastInstall = $fallbackInstall
                                break
                            }
                        }
                    }
                }
                if ($result.Source -eq 'Ninguna' -and ($result.LastInstall -ne 'Desconocida' -or $result.LastCheck -ne 'Desconocida')) {
                    $result.Source = 'UX'
                }
            }
        }

        # Fallback COM (WU API) para equipos donde el registro no trae timestamps confiables
        if ($result.LastInstall -eq 'Desconocida' -or $result.LastCheck -eq 'Desconocida') {
            try {
                $au = New-Object -ComObject Microsoft.Update.AutoUpdate
                if ($au -and $au.PSObject.Properties['Results']) {
                    $auResults = $au.Results

                    if ($result.LastCheck -eq 'Desconocida' -and $auResults.PSObject.Properties['LastSearchSuccessDate']) {
                        [string] $comLastCheck = Convert-ToolkitDateDisplay -Value $auResults.LastSearchSuccessDate
                        if ($comLastCheck -ne 'Desconocida') {
                            $result.LastCheck = $comLastCheck
                        }
                    }

                    if ($result.LastInstall -eq 'Desconocida' -and $auResults.PSObject.Properties['LastInstallationSuccessDate']) {
                        [string] $comLastInstall = Convert-ToolkitDateDisplay -Value $auResults.LastInstallationSuccessDate
                        if ($comLastInstall -ne 'Desconocida') {
                            $result.LastInstall = $comLastInstall
                        }
                    }

                    if ($result.Source -eq 'Ninguna' -and ($result.LastInstall -ne 'Desconocida' -or $result.LastCheck -ne 'Desconocida')) {
                        $result.Source = 'COM'
                    }
                }
            }
            catch {
                # Continuar con fallbacks adicionales
            }
        }

        # Fallback por historial de KBs para ultima instalacion
        if ($result.LastInstall -eq 'Desconocida') {
            try {
                [object[]] $kbs = @(
                    Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSObject.Properties['InstalledOn'] -and $_.InstalledOn } |
                        Sort-Object InstalledOn -Descending
                )
                if ($kbs.Count -gt 0) {
                    [string] $qfeDate = Convert-ToolkitDateDisplay -Value $kbs[0].InstalledOn
                    if ($qfeDate -ne 'Desconocida') {
                        $result.LastInstall = $qfeDate
                        if ($result.Source -eq 'Ninguna') {
                            $result.Source = 'QFE'
                        }
                    }
                }
            }
            catch {
                # Mantener valor actual
            }
        }

        # Ultimo recurso para evitar salida vacia en ultima busqueda
        if ($result.LastCheck -eq 'Desconocida' -and $result.LastInstall -ne 'Desconocida') {
            $result.LastCheck = $result.LastInstall
            if ($result.Source -eq 'Ninguna') {
                $result.Source = 'ProxyInstallDate'
            }
        }
    }
    catch {
        return $result
    }

    return $result
}