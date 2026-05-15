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
    [System.Collections.Generic.List[PSCustomObject]] $optimized = [System.Collections.Generic.List[PSCustomObject]]::new()
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

        # StrictMode-safe: PSObject.Properties[] retorna $null cuando la prop no existe,
        # en lugar de tirar PropertyNotFoundException como hace el acceso directo.
        $matchedKey = $nicSubKeys | Where-Object {
            $itemProps = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $itemProps) { return $false }
            if ($null -eq $itemProps.PSObject.Properties['NetCfgInstanceId']) { return $false }
            [string] $cfgId = [string] $itemProps.NetCfgInstanceId
            if ([string]::IsNullOrWhiteSpace($cfgId)) { return $false }
            return (($cfgId -replace '[{}]', '').ToLower() -eq $adapterGuid)
        } | Select-Object -First 1

        if ($null -eq $matchedKey) {
            $optimized.Add([PSCustomObject]@{ Name = $adapter.Name; ChangesMade = 0 })
            continue
        }

        [int] $changesMade = 0
        foreach ($prop in $powerProps) {
            $regVal = Get-ItemProperty -Path $matchedKey.PSPath -Name $prop -ErrorAction SilentlyContinue
            if ($null -eq $regVal) { continue }
            if ($null -eq $regVal.PSObject.Properties[$prop]) { continue }

            Set-ItemProperty -Path $matchedKey.PSPath -Name $prop -Value '0' -ErrorAction SilentlyContinue

            $verify = Get-ItemProperty -Path $matchedKey.PSPath -Name $prop -ErrorAction SilentlyContinue
            if ($null -ne $verify -and
                $null -ne $verify.PSObject.Properties[$prop] -and
                "$($verify.$prop)" -eq '0') {
                $changesMade++
            }
        }

        $optimized.Add([PSCustomObject]@{ Name = $adapter.Name; ChangesMade = $changesMade })
    }

    # -- 3. Comandos globales de red --
    # autotuning=normal ya es default en Win10 22H2+ — skip si ya está aplicado.
    # fastopen=enabled no es válido para 'set global' en varios builds de Win11 24H2 —
    # detectar el fallo via $LASTEXITCODE en lugar de catch genérico que ocultaba todo.
    [System.Collections.Generic.List[string]] $netshIssues = [System.Collections.Generic.List[string]]::new()

    # autotuning: leer valor actual via cmdlet preferida (no tira si está disponible)
    [string] $currentAutotuning = ''
    $tcpSettings = Get-NetTCPSetting -ErrorAction SilentlyContinue |
        Where-Object { $_.SettingName -eq 'Internet' } |
        Select-Object -First 1
    if ($null -eq $tcpSettings) {
        $tcpSettings = Get-NetTCPSetting -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -ne $tcpSettings -and
        $null -ne $tcpSettings.PSObject.Properties['AutoTuningLevelLocal']) {
        $currentAutotuning = [string] $tcpSettings.AutoTuningLevelLocal
    }

    if ($currentAutotuning -ine 'normal') {
        $null = & netsh int tcp set global autotuninglevel=normal 2>&1
        if ($LASTEXITCODE -ne 0) {
            $netshIssues.Add("autotuninglevel=normal: exit code $LASTEXITCODE")
            $overallSuccess = $false
        }
    }

    # fastopen: en muchos builds 24H2 el comando rechaza fastopen como 'set global'.
    # Lo intentamos best-effort: si falla, no marcamos failure global (es nice-to-have).
    $fastOpenOut = & netsh int tcp set global fastopen=enabled 2>&1
    if ($LASTEXITCODE -ne 0) {
        $netshIssues.Add("fastopen=enabled no disponible en este build (no-op)")
    }

    # flushdns es seguro siempre
    $null = & ipconfig /flushdns 2>&1

    return [PSCustomObject]@{
        AdaptersOptimized = [PSCustomObject[]] $optimized.ToArray()
        Success           = [bool] $overallSuccess
        NetshIssues       = [string[]] $netshIssues.ToArray()
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

function Get-NetworkDiagnostics {
    <#
    .SYNOPSIS
        Recopila diagnóstico de red: TCP AutoTuning, adaptadores activos, DNS IPv4, latencia.
        Retorna PSCustomObject con TcpAutoTuning, Adapters, DnsServers, PingMs.
    #>
    [CmdletBinding()]
    param()

    # -- TCP AutoTuning --
    [string] $tcpTuning = 'desconocido'
    $tcpSetting = Get-NetTCPSetting -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $tcpSetting -and $null -ne $tcpSetting.AutoTuningLevelLocal) {
        $tcpTuning = $tcpSetting.AutoTuningLevelLocal.ToString()
    } else {
        # Fallback: parsear netsh int tcp show global
        [string] $netshOut = ((& netsh int tcp show global 2>&1) -join "`n")
        if ($netshOut -match 'Receive Window Auto-Tuning Level\s*:\s*(\S+)') {
            $tcpTuning = $Matches[1]
        }
    }

    # -- Adaptadores activos --
    [object[]] $adapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' } |
            ForEach-Object {
                [PSCustomObject]@{
                    Name      = [string] $_.Name
                    LinkSpeed = [string] $_.LinkSpeed
                    MediaType = [string] $_.PhysicalMediaType
                }
            }
    )

    # -- DNS IPv4 por adaptador --
    [hashtable] $dnsServers = @{}
    [object[]] $dnsEntries = @(
        Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
            Where-Object { $_.AddressFamily -eq 2 -and $_.ServerAddresses.Count -gt 0 }
    )
    foreach ($entry in $dnsEntries) {
        $dnsServers[$entry.InterfaceAlias] = [string[]] @($entry.ServerAddresses)
    }

    # -- Latencia a 8.8.8.8 --
    [int] $pingMs = -1
    [object[]] $pingResult = @(Test-Connection -ComputerName '8.8.8.8' -Count 2 -ErrorAction SilentlyContinue)
    if ($pingResult.Count -gt 0) {
        $pingMs = [int] ($pingResult | Measure-Object -Property ResponseTime -Average).Average
    }

    return [PSCustomObject]@{
        TcpAutoTuning = [string]    $tcpTuning
        Adapters      = [object[]]  $adapters
        DnsServers    = [hashtable] $dnsServers
        PingMs        = [int]       $pingMs
    }
}

function Start-NetworkDiagnosticsProcess {
    <#
    .SYNOPSIS
        Serializa Get-NetworkDiagnostics y la envía al motor asíncrono mediante Invoke-AsyncToolkitJob.
        Retorna el objeto Job para su seguimiento con Wait-ToolkitJobs.
    #>
    [CmdletBinding()]
    param()

    $fnBody   = ${Function:Get-NetworkDiagnostics}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function Get-NetworkDiagnostics {
$fnBody
}
Get-NetworkDiagnostics
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'NetworkDiagnostics'
}
