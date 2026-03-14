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

    [string] $raw = [string] $Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'Desconocida' }

    try {
        return ([datetime]::Parse($raw)).ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        return $raw
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
                $result.LastInstall = Convert-ToolkitDateDisplay -Value $regInstall.LastSuccessTime
                $result.Source = 'Legacy'
            }
        }

        if ($result.LastCheck -eq 'Desconocida') {
            $regCheck = Get-ItemProperty -Path $legacyDetectPath -ErrorAction SilentlyContinue
            if ($regCheck -and $regCheck.PSObject.Properties['LastSuccessTime']) {
                $result.LastCheck = Convert-ToolkitDateDisplay -Value $regCheck.LastSuccessTime
                $result.Source = 'Legacy'
            }
        }

        if ($IsLtsc -and ($result.LastInstall -eq 'Desconocida' -or $result.LastCheck -eq 'Desconocida')) {
            $regUxFallback = Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue
            if ($regUxFallback) {
                if ($result.LastCheck -eq 'Desconocida') {
                    $pCheckFallback = $regUxFallback.PSObject.Properties['LastCheckedForUpdates']
                    if ($pCheckFallback -and -not [string]::IsNullOrWhiteSpace([string] $pCheckFallback.Value)) {
                        $result.LastCheck = Convert-ToolkitDateDisplay -Value $pCheckFallback.Value
                    }
                }
                if ($result.LastInstall -eq 'Desconocida') {
                    foreach ($propName in @('LastSuccessfulInstallTime', 'LastInstallTime')) {
                        $pInstallFallback = $regUxFallback.PSObject.Properties[$propName]
                        if ($pInstallFallback -and -not [string]::IsNullOrWhiteSpace([string] $pInstallFallback.Value)) {
                            $result.LastInstall = Convert-ToolkitDateDisplay -Value $pInstallFallback.Value
                            break
                        }
                    }
                }
                if ($result.Source -eq 'Ninguna' -and ($result.LastInstall -ne 'Desconocida' -or $result.LastCheck -ne 'Desconocida')) {
                    $result.Source = 'UX'
                }
            }
        }
    }
    catch {
        return $result
    }

    return $result
}