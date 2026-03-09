Set-StrictMode -Version Latest

function Optimize-Network {
    <#
    .SYNOPSIS
        Deshabilita características de ahorro de energía en adaptadores de red físicos activos
        y aplica optimizaciones globales de TCP/IP.
        Retorna un objeto con la lista de adaptadores procesados y el estado de éxito.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $AdapterNames
    )

    # -- 1. Resolver adaptadores objetivo --
    [System.Collections.Generic.List[string]] $optimized = [System.Collections.Generic.List[string]]::new()
    [bool] $overallSuccess = $true

    [object[]] $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)

    [object[]] $targets = if ($PSBoundParameters.ContainsKey('AdapterNames') -and $AdapterNames.Count -gt 0) {
        @($allAdapters | Where-Object { $_.Name -in $AdapterNames })
    } else {
        @($allAdapters | Where-Object {
            $_.Status -eq 'Up' -and
            $_.PhysicalMediaType -in @('802.3', 'Native 802.11')
        })
    }

    if ($targets.Count -eq 0) {
        return [PSCustomObject]@{
            AdaptersOptimized = [string[]] @()
            Success           = [bool] $false
        }
    }

    # -- 2. Deshabilitar propiedades de ahorro de energía vía Registro --
    [string]   $nicClassPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    [string[]] $powerProps   = @('EEE', '*EEE', 'EEELinkAdvertisement', 'GreenEthernet', '*GreenEthernet', 'PowerSavingMode', 'EnablePME', 'ULPMode')

    [object[]] $nicSubKeys = @(
        Get-ChildItem -Path $nicClassPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' }
    )

    foreach ($adapter in $targets) {
        # Normalizar GUID del adaptador para comparación con NetCfgInstanceId del Registro
        [string] $adapterGuid = ($adapter.InterfaceGuid -replace '[{}]', '').ToLower()

        $matchedKey = $nicSubKeys | Where-Object {
            $cfgId = (Get-ItemProperty -Path $_.PSPath -Name 'NetCfgInstanceId' -ErrorAction SilentlyContinue).NetCfgInstanceId
            $cfgId -and ($cfgId -replace '[{}]', '').ToLower() -eq $adapterGuid
        } | Select-Object -First 1

        if ($matchedKey) {
            foreach ($prop in $powerProps) {
                $regVal = Get-ItemProperty -Path $matchedKey.PSPath -Name $prop -ErrorAction SilentlyContinue
                if ($null -ne $regVal -and $null -ne $regVal.$prop) {
                    Set-ItemProperty -Path $matchedKey.PSPath -Name $prop -Value '0' -ErrorAction SilentlyContinue
                }
            }
        }

        $optimized.Add($adapter.Name)
    }

    # -- 3. Comandos globales de red --
    try {
        $null = & netsh int tcp set global autotuninglevel=normal 2>&1
        $null = & netsh int tcp set global fastopen=enabled       2>&1
        $null = & ipconfig /flushdns                              2>&1
    }
    catch {
        $overallSuccess = $false
    }

    return [PSCustomObject]@{
        AdaptersOptimized = [string[]] $optimized.ToArray()
        Success           = [bool] $overallSuccess
    }
}

function Start-NetworkProcess {
    <#
    .SYNOPSIS
        Serializa Optimize-Network y la envía al motor asíncrono mediante Invoke-AsyncToolkitJob.
        Retorna el objeto Job para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $AdapterNames
    )

    $fnBody   = ${Function:Optimize-Network}.ToString()
    $jobBlock = [scriptblock]::Create(@"
param([string[]]`$AdapterNames)
function Optimize-Network {
$fnBody
}
Optimize-Network -AdapterNames `$AdapterNames
"@)

    $argList = @(, [string[]] $(if ($AdapterNames -and $AdapterNames.Count -gt 0) { $AdapterNames } else { @() }))

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'NetworkOptimization' -ArgumentList $argList
}
