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

    # HALLAZGO HW 2026-06-11: filtrar por HardwareInterface (NIC real), NO por
    # PhysicalMediaType. En la PC de Mateo, "Ethernet 3" (VirtualBox) y ZeroTier
    # (VPN) reportan PhysicalMediaType=802.3 y se colaban en el target; la unica
    # NIC fisica real era el Wi-Fi MediaTek (HardwareInterface=True). EEE/Green
    # Ethernet son props de Ethernet: en una NIC Wi-Fi no existen -> ChangesMade=0
    # (no-op seguro). HardwareInterface excluye virtuales/loopback.
    [object[]] $targets = if ($PSBoundParameters.ContainsKey('AdapterNames') -and $AdapterNames.Count -gt 0) {
        @($allAdapters | Where-Object { $_.Name -in $AdapterNames })
    } else {
        @($allAdapters | Where-Object {
            $_.Status -eq 'Up' -and
            $null -ne $_.PSObject.Properties['HardwareInterface'] -and
            $_.HardwareInterface -eq $true
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

# =========================================================================
# Helpers de diagnóstico de red (PUROS + StrictMode-safe, testeables con fixtures)
# =========================================================================

function ConvertTo-Mbps {
    <# Convierte un LinkSpeed string ("1 Gbps", "100 Mbps") a Mbps (int) o -1 si no parsea. #>
    [CmdletBinding()]
    param([string] $LinkSpeed)
    if ([string]::IsNullOrWhiteSpace($LinkSpeed)) { return -1 }
    if ($LinkSpeed -match '(?i)([\d.,]+)\s*([gmk]?)bps') {
        [string] $numRaw = $Matches[1] -replace ',', '.'
        [double] $num = 0
        if (-not [double]::TryParse($numRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $num)) { return -1 }
        switch -regex ($Matches[2].ToLower()) {
            'g'     { return [int] ($num * 1000) }
            'm'     { return [int] $num }
            'k'     { return [int] ($num / 1000) }
            default { return [int] ($num / 1000000) }   # bps -> Mbps
        }
    }
    return -1
}

function Test-LinkSuspect {
    <# Ethernet (802.3) negociando <=100 Mbps = probable cable/puerto degradado. #>
    [CmdletBinding()]
    param([string] $MediaType, [string] $LinkSpeed)
    if ($MediaType -ne '802.3') { return $false }
    [int] $mbps = ConvertTo-Mbps -LinkSpeed $LinkSpeed
    return ($mbps -gt 0 -and $mbps -le 100)
}

function ConvertTo-PowerPropState {
    <# Mapea el RegistryValue de una advanced property a on/off/n/d ($null = no expuesta). #>
    [CmdletBinding()]
    param($RegistryValue)
    if ($null -eq $RegistryValue) { return 'n/d' }
    [string] $v = ([string] $RegistryValue).Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return 'n/d' }
    if ($v -eq '1' -or $v -ieq 'enabled')  { return 'on' }
    if ($v -eq '0' -or $v -ieq 'disabled') { return 'off' }
    return $v
}

function Get-NetworkAdapterReport {
    <#
    .SYNOPSIS
        PURO + StrictMode-safe: filtra adapters físicos (HardwareInterface) y arma el
        shape de diagnóstico por adapter. Recibe datos ya adquiridos (sin cmdlets) para
        ser testeable con fixtures de 0/1/N adapters + virtual-excluido.
    .PARAMETER Adapters
        Array de objetos con: Name, LinkSpeed, PhysicalMediaType, HardwareInterface,
        DriverVersion, DriverDate. Lectura StrictMode-safe vía PSObject.Properties[].
    .PARAMETER AdvByName
        Hashtable name -> objeto con .Eee / .InterruptModeration / .SpeedDuplex (raw;
        cualquiera puede faltar -> 'n/d'). Todo report-only.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Adapters = @(),
        [hashtable] $AdvByName = @{}
    )

    [System.Collections.Generic.List[PSCustomObject]] $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($a in $Adapters) {
        if ($null -eq $a) { continue }
        # Solo NIC física real (excluye VBox/ZeroTier/loopback que reportan 802.3).
        if ($null -eq $a.PSObject.Properties['HardwareInterface'] -or $a.HardwareInterface -ne $true) { continue }

        [string] $name      = if ($null -ne $a.PSObject.Properties['Name'])              { [string] $a.Name } else { '' }
        [string] $linkSpeed = if ($null -ne $a.PSObject.Properties['LinkSpeed'])         { [string] $a.LinkSpeed } else { '' }
        [string] $mediaType = if ($null -ne $a.PSObject.Properties['PhysicalMediaType']) { [string] $a.PhysicalMediaType } else { '' }
        [string] $drvVer    = if ($null -ne $a.PSObject.Properties['DriverVersion'])     { [string] $a.DriverVersion } else { '' }
        [string] $drvDate   = if ($null -ne $a.PSObject.Properties['DriverDate'])        { [string] $a.DriverDate } else { '' }

        $adv = $null
        if ($AdvByName.ContainsKey($name)) { $adv = $AdvByName[$name] }
        $eeeRaw = $null; $imRaw = $null; $sdRaw = $null
        if ($null -ne $adv) {
            if ($null -ne $adv.PSObject.Properties['Eee'])                 { $eeeRaw = $adv.Eee }
            if ($null -ne $adv.PSObject.Properties['InterruptModeration']) { $imRaw  = $adv.InterruptModeration }
            if ($null -ne $adv.PSObject.Properties['SpeedDuplex'])         { $sdRaw  = $adv.SpeedDuplex }
        }

        $out.Add([PSCustomObject]@{
            Name                = $name
            LinkSpeed           = $linkSpeed
            MediaType           = $mediaType
            DriverVersion       = $drvVer
            DriverDate          = $drvDate
            Eee                 = ConvertTo-PowerPropState -RegistryValue $eeeRaw
            InterruptModeration = ConvertTo-PowerPropState -RegistryValue $imRaw
            SpeedDuplex         = if ($null -ne $sdRaw) { [string] $sdRaw } else { '' }
            LinkSuspect         = Test-LinkSuspect -MediaType $mediaType -LinkSpeed $linkSpeed
        })
    }
    return [PSCustomObject[]] $out.ToArray()
}

function Get-NetworkDiagnostics {
    <#
    .SYNOPSIS
        Recopila diagnóstico de red (read-only): TCP AutoTuning, adaptadores físicos con
        driver/EEE/Interrupt-Moderation/duplex/link-suspect, DNS IPv4, latencia y
        NetworkThrottlingIndex (mito, report-only). Conserva los campos previos
        (TcpAutoTuning, Adapters[Name/LinkSpeed/MediaType], DnsServers, PingMs).
    #>
    [CmdletBinding()]
    param()

    # -- TCP AutoTuning --
    # Get-NetTCPSetting devuelve varias filas; la primera ('Automatic') tiene
    # AutoTuningLevelLocal nulo. La fila 'Internet' es la que aplica al trafico
    # real. Filtramos por SettingName y verificamos PSObject.Properties[] para
    # ser StrictMode-safe.
    [string] $tcpTuning = 'desconocido'
    $tcpSetting = Get-NetTCPSetting -ErrorAction SilentlyContinue |
        Where-Object { $_.SettingName -eq 'Internet' } |
        Select-Object -First 1
    if ($null -eq $tcpSetting) {
        # Fallback: cualquier fila con AutoTuningLevelLocal no-vacio.
        $tcpSetting = Get-NetTCPSetting -ErrorAction SilentlyContinue |
            Where-Object {
                $null -ne $_.PSObject.Properties['AutoTuningLevelLocal'] -and
                -not [string]::IsNullOrWhiteSpace([string] $_.AutoTuningLevelLocal)
            } |
            Select-Object -First 1
    }
    if ($null -ne $tcpSetting -and
        $null -ne $tcpSetting.PSObject.Properties['AutoTuningLevelLocal']) {
        $tcpTuning = [string] $tcpSetting.AutoTuningLevelLocal
    }
    if ([string]::IsNullOrWhiteSpace($tcpTuning) -or $tcpTuning -eq 'desconocido') {
        # Ultimo fallback: parsear netsh int tcp show global con regex agnostico
        # al idioma (busca cualquier linea que termine en valor tipo Normal/Disabled).
        [string] $netshOut = ((& netsh int tcp show global 2>&1) -join "`n")
        if ($netshOut -match '(?im)^\s*(?:Receive Window Auto-Tuning Level|Nivel de.*?ajuste.*?ventana.*?)\s*:\s*(\S+)') {
            $tcpTuning = $Matches[1]
        }
    }

    # -- Adaptadores FÍSICOS (HardwareInterface) + props avanzadas (report-only) --
    # HALLAZGO HW 2026-06-11: filtrar por HardwareInterface (excluye VBox/ZeroTier
    # que reportan 802.3). Props avanzadas matcheadas por RegistryKeyword (locale-
    # stable: en es-AR el DisplayName vuelve en español).
    [object[]] $rawAdapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface }
    )
    [hashtable] $advByName = @{}
    [object[]] $adapterInputs = @()
    foreach ($na in $rawAdapters) {
        [string] $nm = [string] $na.Name

        # EEE / ahorro de energía: probar varias keywords estables; 1ra que exista.
        $eeeVal = $null
        foreach ($kw in @('*EEE', '*GreenEthernet', 'LowPowerEnable', 'EnableGreenEthernet', 'EnablePME')) {
            # Select-Object -First 1 (NO @(...)[0]): bajo StrictMode Latest indexar
            # un array vacío tira IndexOutOfRange; Select -First 1 da $null si no hay.
            $p1 = Get-NetAdapterAdvancedProperty -Name $nm -RegistryKeyword $kw -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $p1 -and $null -ne $p1.PSObject.Properties['RegistryValue']) {
                $rv = $p1.RegistryValue
                if ($rv -is [array]) { $rv = if ($rv.Count -gt 0) { $rv[0] } else { $null } }
                if ($null -ne $rv) { $eeeVal = [string] $rv; break }
            }
        }

        # Interrupt Moderation (REPORT-ONLY, nunca aplicar)
        $imVal = $null
        $imp1 = Get-NetAdapterAdvancedProperty -Name $nm -RegistryKeyword '*InterruptModeration' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $imp1 -and $null -ne $imp1.PSObject.Properties['RegistryValue']) {
            $rv = $imp1.RegistryValue
            if ($rv -is [array]) { $rv = if ($rv.Count -gt 0) { $rv[0] } else { $null } }
            if ($null -ne $rv) { $imVal = [string] $rv }
        }

        # Speed/Duplex (DisplayValue humano, si está disponible)
        $sdVal = $null
        $sdp1 = Get-NetAdapterAdvancedProperty -Name $nm -RegistryKeyword '*SpeedDuplex' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $sdp1 -and $null -ne $sdp1.PSObject.Properties['DisplayValue']) {
            $sdVal = [string] $sdp1.DisplayValue
        }

        $advByName[$nm] = [PSCustomObject]@{ Eee = $eeeVal; InterruptModeration = $imVal; SpeedDuplex = $sdVal }

        # Driver (del propio objeto NetAdapter): version + fecha.
        [string] $dv = ''
        if ($null -ne $na.PSObject.Properties['DriverVersionString'] -and $na.DriverVersionString) { $dv = [string] $na.DriverVersionString }
        elseif ($null -ne $na.PSObject.Properties['DriverVersion'] -and $na.DriverVersion)          { $dv = [string] $na.DriverVersion }
        [string] $dd = ''
        if ($null -ne $na.PSObject.Properties['DriverDate'] -and $null -ne $na.DriverDate) {
            try { $dd = ([datetime] $na.DriverDate).ToString('yyyy-MM-dd') } catch { $dd = [string] $na.DriverDate }
        }

        $adapterInputs += [PSCustomObject]@{
            Name              = $nm
            LinkSpeed         = [string] $na.LinkSpeed
            PhysicalMediaType = [string] $na.PhysicalMediaType
            HardwareInterface = $true
            DriverVersion     = $dv
            DriverDate        = $dd
        }
    }
    [object[]] $adapters = @(Get-NetworkAdapterReport -Adapters $adapterInputs -AdvByName $advByName)

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

    # -- NetworkThrottlingIndex (mito de gaming, REPORT-ONLY, nunca tocar) --
    [string] $throttlingIdx = 'default/ausente'
    $nti = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue
    if ($null -ne $nti -and $null -ne $nti.PSObject.Properties['NetworkThrottlingIndex'] -and $null -ne $nti.NetworkThrottlingIndex) {
        $ntiVal = $nti.NetworkThrottlingIndex
        # 0xffffffff (4294967295) = deshabilitado (equivale al default funcional).
        if ([string] $ntiVal -eq '4294967295') { $throttlingIdx = 'deshabilitado (0xffffffff)' }
        else { $throttlingIdx = [string] $ntiVal }
    }

    return [PSCustomObject]@{
        TcpAutoTuning          = [string]    $tcpTuning
        Adapters               = [object[]]  $adapters
        DnsServers             = [hashtable] $dnsServers
        PingMs                 = [int]       $pingMs
        NetworkThrottlingIndex = [string]    $throttlingIdx
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
