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
            [object[]] $parts = @($value.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
    # Normalizar marcas registradas: "AMD Radeon(TM) Graphics" (nombre tipico de
    # APU Ryzen 4000G+) no matcheaba 'RADEON\s+GRAPHICS' por el (TM) en el medio
    # -> se clasificaba como dGPU (bug cazado por smoke de #23b, 2026-06-11).
    $n = ($n -replace '\((TM|R|C)\)', ' ') -replace '\s{2,}', ' '
    if ($n -match 'INTEL') { return $true }
    if ($n -match 'RADEON\s+GRAPHICS') { return $true }
    if ($n -match 'RADEON\s+\d{3}M\b') { return $true }   # 680M/780M/880M (iGPU RDNA)
    if ($n -match 'VEGA\s+\d|VEGA\s+GRAPHICS') { return $true }
    if ($n -match 'IRIS|UHD|HD\s+GRAPHICS') { return $true }
    return $false
}

function Get-CpuClass {
    <#
    .SYNOPSIS
        Clasifica un CPU en U-series / H-series / Desktop-K / Desktop-X /
        LowEnd / Unknown a partir del nombre. Usado para tier resolution.

        - U-series: Intel i*-*U / i*-*UE / AMD R*-*U (laptop thin-and-light)
        - H-series: Intel i*-*H / i*-*HX / AMD R*-*H / R*-*HX / R*-*HS
        - Desktop-K: Intel i*-*K / i*-*KF / i*-*KS
        - Desktop-X: Intel i*-*X / AMD R*-*X / R*-*X3D
        - LowEnd: Celeron / Pentium / Atom / E1 / E2 / A4 / A6
        - Unknown: lo que no matchee
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string] $CpuName
    )

    if ([string]::IsNullOrWhiteSpace($CpuName)) { return 'Unknown' }
    [string] $n = $CpuName.ToUpperInvariant()

    if ($n -match '\b(CELERON|PENTIUM|ATOM)\b|\b(E1|E2|A4|A6)-\d') { return 'LowEnd' }
    # Intel mobile: ej. i7-1355U, i5-12500H, i9-13900HX
    if ($n -match 'I[3579]-\d+\s*UE?\b') { return 'U-series' }
    if ($n -match 'I[3579]-\d+\s*H[XS]?\b') { return 'H-series' }
    if ($n -match 'I[3579]-\d+\s*K[FS]?\b') { return 'Desktop-K' }
    if ($n -match 'I[3579]-\d+\s*XE?\b') { return 'Desktop-X' }
    # AMD mobile: Ryzen 7 5800H, Ryzen 5 5600U, Ryzen 9 7945HX3D
    if ($n -match 'RYZEN\s+[3579]\s+\d+\s*U\b') { return 'U-series' }
    if ($n -match 'RYZEN\s+[3579]\s+\d+\s*H[SX]?(?:3D)?\b') { return 'H-series' }
    if ($n -match 'RYZEN\s+[3579]\s+\d+\s*X(?:3D|T)?\b') { return 'Desktop-X' }
    return 'Unknown'
}

function Get-DGpuVramMb {
    <#
    .SYNOPSIS
        Estima VRAM dedicada de la GPU discreta a partir del nombre. WMI
        AdapterRAM no es confiable (>4GB se desborda en uint32 a valores
        negativos o capeados). Usamos heurística por nombre conocido,
        retorna 0 si no se puede inferir.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $false)]
        [string] $GpuName
    )

    if ([string]::IsNullOrWhiteSpace($GpuName)) { return 0 }
    [string] $n = $GpuName.ToUpperInvariant()

    # NVIDIA por modelo conocido (laptop + desktop)
    if ($n -match 'RTX\s*5090')                                          { return 32768 }
    if ($n -match 'RTX\s*5080')                                          { return 16384 }
    if ($n -match 'RTX\s*5070\s*TI')                                     { return 16384 }
    if ($n -match 'RTX\s*5070')                                          { return 12288 }
    if ($n -match 'RTX\s*4090')                                          { return 24576 }
    if ($n -match 'RTX\s*4080')                                          { return 16384 }
    if ($n -match 'RTX\s*4070\s*TI')                                     { return 12288 }
    if ($n -match 'RTX\s*4070')                                          { return 12288 }
    if ($n -match 'RTX\s*4060\s*TI')                                     { return 8192 }
    if ($n -match 'RTX\s*4060')                                          { return 8192 }
    if ($n -match 'RTX\s*4050')                                          { return 6144 }
    if ($n -match 'RTX\s*3090')                                          { return 24576 }
    if ($n -match 'RTX\s*3080\s*TI')                                     { return 12288 }
    if ($n -match 'RTX\s*3080')                                          { return 10240 }
    if ($n -match 'RTX\s*3070\s*TI')                                     { return 8192 }
    if ($n -match 'RTX\s*3070')                                          { return 8192 }
    if ($n -match 'RTX\s*3060\s*TI')                                     { return 8192 }
    if ($n -match 'RTX\s*3060')                                          { return 6144 }
    if ($n -match 'RTX\s*3050\s*TI')                                     { return 4096 }
    if ($n -match 'RTX\s*3050')                                          { return 4096 }
    if ($n -match 'RTX\s*2080|RTX\s*2070\s*SUPER|RTX\s*2070')            { return 8192 }
    if ($n -match 'RTX\s*2060\s*SUPER|RTX\s*2060')                       { return 6144 }
    if ($n -match 'GTX\s*16\d\d')                                        { return 4096 }
    # AMD Radeon dGPU
    if ($n -match 'RX\s*7900')                                           { return 16384 }
    if ($n -match 'RX\s*7800')                                           { return 16384 }
    if ($n -match 'RX\s*7700')                                           { return 12288 }
    if ($n -match 'RX\s*7600')                                           { return 8192 }
    if ($n -match 'RX\s*6900|RX\s*6800')                                 { return 16384 }
    if ($n -match 'RX\s*6700')                                           { return 12288 }
    if ($n -match 'RX\s*6600')                                           { return 8192 }
    if ($n -match 'RX\s*6500')                                           { return 4096 }
    # Intel Arc dGPU
    if ($n -match 'ARC\s*A7\d\d')                                        { return 16384 }
    if ($n -match 'ARC\s*A5\d\d|ARC\s*A3\d\d')                           { return 8192 }
    return 0
}

function Get-TierResolved {
    <#
    .SYNOPSIS
        Tier de hardware basado en RAM + clase de CPU + VRAM dGPU.

        Low : <=8GB RAM, U-series alto o LowEnd, iGPU only
        Mid : 12-16GB RAM, U-series alto o H-series bajo, iGPU o dGPU <=4GB
        High: >=16GB RAM, H-series alto / Desktop K/X, dGPU >=6GB

        Si el hardware está en el borde, el tier se inclina hacia abajo
        (más conservador para el operador que aplica recetas).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]    $RamMB,
        [Parameter(Mandatory)] [string] $CpuClass,
        [Parameter(Mandatory)] [int]    $DGpuVramMb
    )

    [int] $score = 0

    # Eje RAM: 8GB-=0, 16GB=1, >16GB=2
    if ($RamMB -ge 16000)      { $score += 2 }
    elseif ($RamMB -ge 12000)  { $score += 1 }

    # Eje CPU
    switch ($CpuClass) {
        'LowEnd'    { }
        'U-series'  { $score += 1 }
        'H-series'  { $score += 2 }
        'Desktop-K' { $score += 2 }
        'Desktop-X' { $score += 2 }
        'Unknown'   { $score += 1 }
    }

    # Eje GPU
    if     ($DGpuVramMb -ge 12288) { $score += 2 }
    elseif ($DGpuVramMb -ge 6144)  { $score += 1 }
    elseif ($DGpuVramMb -gt 0)     { } # dGPU pero pobre (<=4GB) no suma

    # Tier final
    if ($score -ge 5) { return 'High' }
    if ($score -ge 3) { return 'Mid'  }
    return 'Low'
}

function Get-MachineVmInfo {
    <#
    .SYNOPSIS
        Detección thin de VM para MachineProfile. Duplicación intencional de
        Test-IsVirtualMachine en Telemetry.ps1 (T-N1 / DD4): el job de telemetría
        solo dot-sourcea Telemetry.ps1; NO llamar al helper de Telemetry desde acá.
        Misma lista de firmas §3a del plan snapshot-vm-plan.md.
    .NOTES
        Acepta los CIM ya consultados para no re-query. Defensivo: error → IsVirtual=$false.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [object] $ComputerSystem = $null,
        [Parameter()] [object] $Bios           = $null
    )

    try {
        # Self-query si no se pasan (§3a: paridad con Test-IsVirtualMachine de
        # Telemetry). El caller real Get-MachineProfile siempre los pasa; este
        # fallback evita el footgun de un standalone no-arg devolviendo False.
        if ($null -eq $ComputerSystem) {
            $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem `
                -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
        }
        if ($null -eq $Bios) {
            $Bios = Get-CimInstance -ClassName Win32_BIOS `
                -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
        }

        [string] $csManufacturer = if ($ComputerSystem) { [string]$ComputerSystem.Manufacturer } else { '' }
        [string] $csModel        = if ($ComputerSystem) { [string]$ComputerSystem.Model }        else { '' }
        [string] $biosManuf      = if ($Bios)           { [string]$Bios.Manufacturer }           else { '' }
        [string] $biosVersion    = if ($Bios)           { [string]$Bios.Version }                else { '' }

        # Hyper-V / Windows Sandbox
        if ($csModel -match '(?i)Virtual Machine' -and $csManufacturer -match '(?i)Microsoft') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Hyper-V' }
        }
        if ($csModel -match '(?i)Virtual Machine') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Hyper-V' }
        }
        # VMware
        if ($csManufacturer -match '(?i)VMware' -or $csModel -match '(?i)VMware' -or
            $biosManuf -match '(?i)VMware') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'VMware' }
        }
        # VirtualBox
        if ($csManufacturer -match '(?i)innotek' -or $csModel -match '(?i)VirtualBox' -or
            $biosManuf -match '(?i)VBOX' -or $biosVersion -match '(?i)VBOX') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'VirtualBox' }
        }
        # KVM/QEMU
        if ($csManufacturer -match '(?i)QEMU' -or
            $csModel -match '(?i)Standard PC \(Q35|(?i)KVM' -or
            $biosManuf -match '(?i)SeaBIOS') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'KVM/QEMU' }
        }
        # Xen
        if ($csManufacturer -match '(?i)Xen' -or $csModel -match '(?i)Xen') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Xen' }
        }
        # Parallels
        if ($csManufacturer -match '(?i)Parallels' -or $csModel -match '(?i)Parallels') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Parallels' }
        }
        # Fallback genérico
        if ($csModel -match '(?i)\bvirtual\b') {
            return [PSCustomObject]@{ IsVirtual = $true; Vendor = 'Virtual' }
        }
        return [PSCustomObject]@{ IsVirtual = $false; Vendor = '' }
    } catch {
        return [PSCustomObject]@{ IsVirtual = $false; Vendor = '' }
    }
}

function Get-RamAdvisories {
    <#
    .SYNOPSIS
        Avisos [REPORTAR] de RAM para el operador (#23b, research gaming
        2026-06-11). PCTk NO toca BIOS: detecta y reporta (rol extractor/guia).
        - 1 solo modulo = single-channel garantizado (palanca #1 de gama baja:
          +20-40% en iGPU al sumar el segundo modulo). Upsell directo.
        - ConfiguredClockSpeed < Speed (rated) = XMP/DOCP/EXPO sin activar.
        Funcion pura: recibe los modulos ya consultados (testeable con fixtures;
        OJO trampa StrictMode de 1 elemento -> [object[]] tipado).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()] [AllowEmptyCollection()] [object[]] $Modules = @()
    )

    [object[]] $advisories = @()
    [object[]] $mods = @($Modules | Where-Object { $null -ne $_ })
    if ($mods.Count -eq 0) { return $advisories }

    if ($mods.Count -eq 1) {
        $advisories += ('RAM single-channel (1 modulo de {0} GB): un segundo modulo da +20-40% en iGPU/gama baja. Upsell directo.' -f $mods[0].CapacityGb)
    }

    # XMP/EXPO off: corre por debajo del perfil rated. Solo si ambos datos > 0.
    [int] $maxRated = 0
    [int] $maxConf  = 0
    foreach ($m in $mods) {
        if ($null -ne $m.PSObject.Properties['SpeedMhz']      -and [int]$m.SpeedMhz      -gt $maxRated) { $maxRated = [int]$m.SpeedMhz }
        if ($null -ne $m.PSObject.Properties['ConfiguredMhz'] -and [int]$m.ConfiguredMhz -gt $maxConf)  { $maxConf  = [int]$m.ConfiguredMhz }
    }
    if ($maxRated -gt 0 -and $maxConf -gt 0 -and $maxConf -lt $maxRated) {
        $advisories += ('RAM corriendo a {0} MT/s con perfil de {1}: activar XMP/DOCP/EXPO en BIOS.' -f $maxConf, $maxRated)
    }

    return $advisories
}

function Get-UmaAdvisory {
    <#
    .SYNOPSIS
        Aviso [REPORTAR] de UMA Frame Buffer chico en APU AMD (#23b). Si la
        unica GPU es una iGPU AMD (Radeon/Vega) y el carve-out reportado es
        < ~3.5 GB, avisar "subir UMA en BIOS" (research: diferencia gigante en
        APUs; el caso Ana quedo en 2G). PCTk no toca BIOS: solo reporta.
        AdapterRAM es uint32 (>=4GB desborda) -> solo confiamos en el rango
        128MB..3.5GB; fuera de eso, sin aviso (honesto, no adivinar).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [bool] $HasIGpuOnly = $false,
        [Parameter()] [AllowEmptyString()] [string] $GpuName = '',
        [Parameter()] [long] $AdapterRamBytes = 0
    )

    if (-not $HasIGpuOnly) { return '' }
    if ([string]::IsNullOrWhiteSpace($GpuName)) { return '' }
    [string] $n = $GpuName.ToUpperInvariant()
    [bool] $isAmdIGpu = ($n -match 'RADEON|VEGA') -and (Test-IsIntegratedGpuName -GpuName $GpuName)
    if (-not $isAmdIGpu) { return '' }

    [long] $minB = 128MB
    [long] $maxB = [long](3.5 * 1GB)
    if ($AdapterRamBytes -lt $minB -or $AdapterRamBytes -gt $maxB) { return '' }

    [double] $gb = [math]::Round($AdapterRamBytes / 1GB, 1)
    return ('APU AMD con UMA Frame Buffer ~{0} GB: subirlo en BIOS (4 GB si la RAM da) mejora mucho los juegos.' -f $gb)
}

function Get-MachineProfile {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
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

    # CPU class y dGPU VRAM para clasificación de tier
    [string] $cpuName  = if ($null -ne $cs -and $cs.PSObject.Properties['Manufacturer']) {
        $cpuRaw = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cpuRaw -and $null -ne $cpuRaw.Name) { [string] $cpuRaw.Name } else { '' }
    } else { '' }
    [string] $cpuClass = Get-CpuClass -CpuName $cpuName

    [int] $dGpuVramMb = 0
    foreach ($gname in $gpuNames) {
        if (Test-IsIntegratedGpuName -GpuName $gname) { continue }
        [int] $candidate = Get-DGpuVramMb -GpuName $gname
        if ($candidate -gt $dGpuVramMb) { $dGpuVramMb = $candidate }
    }

    [string] $tier = Get-TierResolved -RamMB $ramMB -CpuClass $cpuClass -DGpuVramMb $dGpuVramMb

    # VM detection thin (T-N1 / DD4): usando $cs y $bios ya consultados.
    # La lógica es una copia de §3a de snapshot-vm-plan.md — duplicación intencional
    # (no puede llamar a Test-IsVirtualMachine de Telemetry.ps1 por el límite de job).
    $vmInfo = Get-MachineVmInfo -ComputerSystem $cs -Bios $bios

    # ── Avisos de HW al operador (#23b: detectar y REPORTAR, no tocar) ────────
    # Una sola vez acá (el banner se redibuja por loop de menú: no puede pagar
    # CIM por redibujo). Defensivo: cualquier fallo -> sin avisos, nunca tira.
    [object[]] $advisories = @()
    try {
        [object[]] $ramModules = @(
            Get-CimInstance -ClassName Win32_PhysicalMemory -OperationTimeoutSec 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.Capacity -gt 0 } |
                ForEach-Object {
                    [int] $confMhz = 0
                    if ($null -ne $_.PSObject.Properties['ConfiguredClockSpeed'] -and $null -ne $_.ConfiguredClockSpeed) {
                        $confMhz = [int]$_.ConfiguredClockSpeed
                    }
                    [PSCustomObject]@{
                        CapacityGb    = [double] [math]::Round($_.Capacity / 1GB, 2)
                        SpeedMhz      = [int] $_.Speed
                        ConfiguredMhz = $confMhz
                    }
                }
        )
        $advisories += @(Get-RamAdvisories -Modules $ramModules)
    } catch { }
    try {
        if ($hasIGpuOnly) {
            foreach ($g in $gpus) {
                [string] $gn = [string]$g.Name
                if ([string]::IsNullOrWhiteSpace($gn)) { continue }
                [long] $aRam = 0
                if ($null -ne $g.PSObject.Properties['AdapterRAM'] -and $null -ne $g.AdapterRAM) { $aRam = [long]$g.AdapterRAM }
                [string] $uma = Get-UmaAdvisory -HasIGpuOnly $hasIGpuOnly -GpuName $gn -AdapterRamBytes $aRam
                if (-not [string]::IsNullOrEmpty($uma)) { $advisories += $uma; break }
            }
        }
    } catch { }

    return [PSCustomObject]@{
        IsLaptop         = $isLaptop
        RamMB            = $ramMB
        IsLowRam         = ($ramMB -le 8192)
        HasDGpu          = $hasDGpu
        HasIGpuOnly      = $hasIGpuOnly
        GpuNames         = $gpuNames
        DGpuVramMb       = $dGpuVramMb
        CpuName          = $cpuName
        CpuClass         = $cpuClass
        Tier             = $tier
        Manufacturer     = $manufacturer
        IsWin11          = ($build -ge 22000)
        IsHome           = ($osReg -and ([string]$osReg.ProductName -match '\bHome\b'))
        Build            = $build
        OemCatalogPath   = $oemCatalogPath
        # ── Campos nuevos snapshot-vm-plan §5 ─────────────────────────────────
        IsVirtualMachine = [bool]   $vmInfo.IsVirtual
        VmVendor         = [string] $vmInfo.Vendor
        # ── #23b: avisos de HW al operador (single-channel / XMP off / UMA) ───
        Advisories       = [string[]] @($advisories | ForEach-Object { [string]$_ })
    }
}
