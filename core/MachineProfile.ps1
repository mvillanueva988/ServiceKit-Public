Set-StrictMode -Version Latest

function Get-NormalizedManufacturer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $RawManufacturer
    )

    if ([string]::IsNullOrWhiteSpace($RawManufacturer)) {
        return 'Unknown'
    }

    [string] $value = $RawManufacturer.Trim().ToUpperInvariant()
    $value = $value -replace 'ELECTRONICS\s+CO\.?', ''
    $value = $value -replace '\bCO\.?\b', ''
    $value = $value -replace '\bLTD\.?\b', ''
    $value = $value -replace '\bINC\.?\b', ''
    $value = $value -replace '[\.,]', ' '
    $value = ($value -replace '\s{2,}', ' ').Trim()

    switch -Regex ($value) {
        'SAMSUNG' { return 'Samsung' }
        '^HEWLETT\s*PACKARD|^HP\b' { return 'HP' }
        'LENOVO' { return 'Lenovo' }
        'DELL' { return 'Dell' }
        'ASUS|ASUSTEK' { return 'Asus' }
        default {
            $parts = $value.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($parts.Count -gt 0) {
                [string] $first = $parts[0].ToLowerInvariant()
                return [char]::ToUpperInvariant($first[0]) + $first.Substring(1)
            }
            return 'Unknown'
        }
    }
}

function Test-IsIntegratedGpuName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GpuName
    )

    [string] $n = $GpuName.ToUpperInvariant()
    if ($n -match 'INTEL') { return $true }
    if ($n -match 'RADEON\s+GRAPHICS') { return $true }
    if ($n -match 'VEGA\s+\d|VEGA\s+GRAPHICS') { return $true }
    if ($n -match 'IRIS|UHD|HD\s+GRAPHICS') { return $true }
    return $false
}

function Get-MachineProfile {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
    $osReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    [int] $ramMB = 0
    if ($cs -and $cs.TotalPhysicalMemory) {
        $ramMB = [int][math]::Round(([double]$cs.TotalPhysicalMemory / 1MB), 0)
    }

    [int] $build = 0
    if ($osReg -and $osReg.PSObject.Properties['CurrentBuild']) {
        [void][int]::TryParse([string]$osReg.CurrentBuild, [ref]$build)
    }

    [string[]] $gpuNames = @($gpus |
        ForEach-Object { [string]$_.Name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique)

    [bool] $hasDGpu = $false
    if ($gpuNames.Count -gt 0) {
        $hasDGpu = @($gpuNames | Where-Object { -not (Test-IsIntegratedGpuName -GpuName $_) }).Count -gt 0
    }

    [bool] $hasIGpuOnly = ($gpuNames.Count -gt 0 -and -not $hasDGpu)

    [bool] $isLaptop = $false
    if ($cs -and $cs.PSObject.Properties['PCSystemType']) {
        $isLaptop = ([int]$cs.PCSystemType -eq 2)
    }
    if (-not $isLaptop -and $enclosure -and $enclosure.ChassisTypes) {
        [int[]] $mobileChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
        $isLaptop = @($enclosure.ChassisTypes | Where-Object { $mobileChassis -contains [int]$_ }).Count -gt 0
    }

    [string] $manufacturer = Get-NormalizedManufacturer -RawManufacturer ([string]$cs.Manufacturer)
    [string] $manufacturerSlug = $manufacturer.ToLowerInvariant()
    [string] $toolkitRoot = Split-Path -Parent $PSScriptRoot
    [string] $oemCatalogPath = Join-Path -Path $toolkitRoot -ChildPath ('data\oem-bloat\{0}.json' -f $manufacturerSlug)

    return [PSCustomObject]@{
        IsLaptop      = $isLaptop
        RamMB         = $ramMB
        IsLowRam      = ($ramMB -le 8192)
        HasDGpu       = $hasDGpu
        HasIGpuOnly   = $hasIGpuOnly
        GpuNames      = $gpuNames
        Manufacturer  = $manufacturer
        IsWin11       = ($build -ge 22000)
        IsHome        = ($osReg -and ([string]$osReg.ProductName -match '\bHome\b'))
        Build         = $build
        OemCatalogPath= $oemCatalogPath
    }
}
