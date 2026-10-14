Set-StrictMode -Version Latest

# ─── #90 (1): detectores de GPU y pantalla para Get-MachineProfile ───────────
#
# Lo que mas FPS le roba a un cliente gamer y PCTk no veia: monitor por debajo
# de su refresh, pantalla enchufada a la placa madre, ReBAR apagado / firmware
# legacy, PCIe degradado, RAM en un solo canal y driver generico.
# Fuente: _local-dev/research/90-gpu-cs2/informe.md § 1 y § A1-A6.
#
# REGLAS DE ESTE ARCHIVO
# - SOLO LECTURA. Detecta y reporta; no corrige nada (ni registro, ni BIOS, ni
#   drivers, ni modo de pantalla: un modo que el cable no soporta deja negra la
#   pantalla en una sesion AnyDesk).
# - Sin admin, y sin llamar a nada de modules\: Get-MachineProfile corre en
#   main al arrancar y puede terminar dentro de un job (limite #24).
# - Costo cero en la PC del cliente: nada de Get-PnpDeviceProperty (importar
#   el modulo PnpDevice costo 1518 ms medidos; el mismo dato por CIM ClientOnly
#   46 ms). Ver Get-GpuDisplayChecks.
# - Nunca rompe el perfil: cada fuente y cada detector en su try/catch; si la
#   fuente no esta (VM, Sandbox, driver sin instalar) el resultado es
#   'no determinado' con el motivo.
#
# Cada detector es una funcion PURA (recibe datos ya leidos, testeable con
# fixtures) y devuelve UN resultado:
#   Id, Nombre, Estado, Detalle, Aviso
# Estado: 'aviso' | 'ok' | 'dato' | 'no aplica' | 'no determinado'.
# Solo 'aviso' trae texto en Aviso, y ese texto es el que llega al banner [HW].

function New-GpuCheckResult {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Nombre,
        [Parameter(Mandatory)] [ValidateSet('aviso', 'ok', 'dato', 'no aplica', 'no determinado')] [string] $Estado,
        [Parameter()] [AllowEmptyString()] [string] $Detalle = '',
        [Parameter()] [AllowEmptyString()] [string] $Aviso = ''
    )
    if ($Estado -ne 'aviso') { $Aviso = '' }
    return [PSCustomObject]@{ Id = $Id; Nombre = $Nombre; Estado = $Estado; Detalle = $Detalle; Aviso = $Aviso }
}

function Get-PctkChassisKind {
    <#
    .SYNOPSIS
        'desktop' | 'notebook' | 'otro'. Funcion pura.
    .DESCRIPTION
        Las reglas de A2 y A4 avisan SOLO en un desktop clasico: en notebook (y
        en AIO / mini PC, que suelen ser hibridos de diseno) el mismo patron es
        normal. 'otro' = no se avisa. Sin dato NO se asume desktop.
        ChassisTypes desktop: 3 Desktop, 4 Low Profile, 5 Pizza Box, 6 Mini
        Tower, 7 Tower, 15 Space-saving, 16 Lunch Box, 24 Sealed-case.
        Clones con chassis 1/2 (Other/Unknown): manda PCSystemType 1/3.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [AllowEmptyCollection()] [int[]] $ChassisTypes = @(),
        [Parameter()] [int] $PCSystemType = 0,
        [Parameter()] [bool] $IsLaptop = $false
    )

    if ($IsLaptop) { return 'notebook' }
    [int[]] $desktopSet = @(3, 4, 5, 6, 7, 15, 16, 24)
    [int[]] $mobileSet  = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    [int[]] $types = @($ChassisTypes)
    if (@($types | Where-Object { $mobileSet -contains $_ }).Count -gt 0) { return 'notebook' }
    if (@($types | Where-Object { $desktopSet -contains $_ }).Count -gt 0) { return 'desktop' }
    [bool] $soloAmbiguo = (@($types | Where-Object { $_ -notin @(1, 2) }).Count -eq 0)
    if ($soloAmbiguo -and $types.Count -gt 0 -and $PCSystemType -in @(1, 3)) { return 'desktop' }
    return 'otro'
}

# ─── A1: monitor por debajo de su refresh maximo ─────────────────────────────
function Test-GpuCheckRefresh {
    <#
    .SYNOPSIS
        Monitors: [Instance, MaxHz] (maximo de WmiMonitorListedSupportedSourceModes).
        AdapterRefreshHz: CurrentRefreshRate de cada adaptador (0 = sin pantalla).
    .DESCRIPTION
        Win32_VideoController da UN refresh por adaptador, no por monitor. Con
        1 monitor la comparacion es exacta; con 2 o mas no se puede atribuir y
        se reporta como dato (sin aviso: mejor callar que avisar mal).
        Trampa conocida [CONJETURA]: modos solo en la extension DisplayID/CTA
        pueden no listarse; eso da falso NEGATIVO, nunca falso positivo.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyCollection()] [object[]] $Monitors = @(),
        [Parameter()] [AllowEmptyCollection()] [int[]] $AdapterRefreshHz = @()
    )

    [string] $id = 'A1'; [string] $nom = 'Refresh del monitor'
    [object[]] $mons = @($Monitors | Where-Object { $null -ne $_ -and [double]$_.MaxHz -gt 1 })
    if ($mons.Count -eq 0) {
        return New-GpuCheckResult $id $nom 'no determinado' 'Windows no lista los modos del monitor (VM, Sandbox o monitor sin EDID)'
    }
    [int[]] $cur = @($AdapterRefreshHz | Where-Object { $_ -gt 1 })
    if ($cur.Count -eq 0) {
        return New-GpuCheckResult $id $nom 'no determinado' 'ningun adaptador reporta el refresh actual'
    }
    [int] $actual = [int](($cur | Measure-Object -Maximum).Maximum)

    if ($mons.Count -gt 1) {
        [string] $maxs = (@($mons | ForEach-Object { '{0:0} Hz' -f [math]::Floor([double]$_.MaxHz) }) -join ' / ')
        return New-GpuCheckResult $id $nom 'dato' ('{0} monitores (maximos {1}); Windows da {2} Hz por adaptador y no se puede atribuir a cada uno: revisar en Configuracion > Pantalla' -f $mons.Count, $maxs, $actual)
    }

    [int] $max = [int][math]::Floor([double]$mons[0].MaxHz + 0.5)
    if (($max - $actual) -gt 5) {
        return New-GpuCheckResult $id $nom 'aviso' ('actual {0} Hz, maximo {1} Hz' -f $actual, $max) `
            ('Monitor a {0} Hz pudiendo {1} Hz: subirlo en Configuracion > Pantalla > Pantalla avanzada. Si no aparece, revisar el cable (HDMI viejo limita) o usar DisplayPort.' -f $actual, $max)
    }
    return New-GpuCheckResult $id $nom 'ok' ('{0} Hz de {1} Hz' -f $actual, $max)
}

# ─── A2: desktop con dGPU y el monitor en la placa madre ──────────────────────
function Test-GpuCheckDisplayOutput {
    <#
    .SYNOPSIS
        Adapters: [Name, IsIntegrated, RefreshHz]. El adaptador que tiene la
        pantalla es el que reporta CurrentRefreshRate.
    .DESCRIPTION
        En notebook el patron "iGPU con refresh, dGPU vacia" es el modo hibrido
        (Optimus), normal: se reporta como dato. En desktop es el error clasico
        del cliente: el cable en la salida de la placa madre.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyString()] [string] $ChassisKind = 'otro',
        [Parameter()] [AllowEmptyCollection()] [object[]] $Adapters = @()
    )

    [string] $id = 'A2'; [string] $nom = 'Salida de video'
    [object[]] $all  = @($Adapters | Where-Object { $null -ne $_ })
    [object[]] $dgpu = @($all | Where-Object { -not [bool]$_.IsIntegrated })
    [object[]] $igpu = @($all | Where-Object { [bool]$_.IsIntegrated })
    if ($dgpu.Count -eq 0) { return New-GpuCheckResult $id $nom 'no aplica' 'sin GPU dedicada' }

    [object[]] $dConPantalla = @($dgpu | Where-Object { [int]$_.RefreshHz -gt 1 })
    [object[]] $iConPantalla = @($igpu | Where-Object { [int]$_.RefreshHz -gt 1 })
    if ($dConPantalla.Count -gt 0) {
        return New-GpuCheckResult $id $nom 'ok' ('pantalla en la GPU dedicada ({0})' -f [string]$dConPantalla[0].Name)
    }
    if ($iConPantalla.Count -eq 0) {
        return New-GpuCheckResult $id $nom 'no determinado' 'ningun adaptador reporta pantalla activa'
    }
    if ($ChassisKind -ne 'desktop') {
        return New-GpuCheckResult $id $nom 'dato' ('modo hibrido: la pantalla sale por {0} y {1} renderiza detras (normal en notebook; el modo dGPU directo/MUX se elige en la app del fabricante)' -f [string]$iConPantalla[0].Name, [string]$dgpu[0].Name)
    }
    return New-GpuCheckResult $id $nom 'aviso' ('pantalla en {0}, {1} sin pantalla' -f [string]$iConPantalla[0].Name, [string]$dgpu[0].Name) `
        ('Monitor enchufado a la placa madre: la {0} no tiene pantalla y el juego corre en la integrada o paga una copia. Pasar el cable a la salida de la placa de video.' -f [string]$dgpu[0].Name)
}

# ─── A3: firmware legacy (CSM) ────────────────────────────────────────────────
function Test-GpuCheckFirmware {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyString()] [string] $FirmwareType = '',
        [Parameter()] [bool] $HasDGpu = $false
    )

    [string] $id = 'A3-fw'; [string] $nom = 'Firmware (UEFI/Legacy)'
    switch -Regex ($FirmwareType) {
        '^(?i)UEFI$' { return New-GpuCheckResult $id $nom 'ok' 'UEFI' }
        '^(?i)Legacy$' {
            if (-not $HasDGpu) { return New-GpuCheckResult $id $nom 'dato' 'BIOS Legacy/CSM (sin GPU dedicada: ReBAR no aplica)' }
            return New-GpuCheckResult $id $nom 'aviso' 'BIOS Legacy/CSM' `
                'Firmware en modo Legacy/CSM: ReBAR/SAM es imposible asi. Antes de apagar CSM hay que pasar el disco a GPT con mbr2gpt; si no, la PC no bootea.'
        }
        default { return New-GpuCheckResult $id $nom 'no determinado' 'Windows no informa el tipo de firmware' }
    }
}

# ─── A3: ReBAR / SAM ──────────────────────────────────────────────────────────
function Test-GpuCheckRebar {
    <#
    .DESCRIPTION
        Solo NVIDIA tiene via sin admin: BAR1 Total de nvidia-smi. 256 MiB (o
        menos) con mas VRAM que eso = apagado; BAR1 ~= VRAM = activo [la regla
        del 256 es CONJETURA de foro; el "activo" esta VERIFICADO-LOCAL].
        Ojo: dice que el BAR esta dimensionado, no que el perfil del juego lo
        use (NVIDIA lo habilita por whitelist). En NVIDIA el impacto es chico;
        en Intel Arc es alto, pero para AMD/Intel no hay via confirmada desde PS.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [bool] $HasDGpu = $false,
        [Parameter()] [bool] $HasNvidia = $false,
        [Parameter()] [bool] $SmiAvailable = $false,
        [Parameter()] [AllowEmptyCollection()] [object[]] $NvidiaRows = @()
    )

    [string] $id = 'A3-rebar'; [string] $nom = 'ReBAR / SAM'
    if (-not $HasDGpu) { return New-GpuCheckResult $id $nom 'no aplica' 'sin GPU dedicada' }
    if (-not $HasNvidia) { return New-GpuCheckResult $id $nom 'no determinado' 'sin via de lectura sin admin para AMD/Intel (verificar en Adrenalin / Arc Control o GPU-Z)' }
    if (-not $SmiAvailable) { return New-GpuCheckResult $id $nom 'no determinado' 'nvidia-smi no esta o no respondio (driver NVIDIA sin instalar o roto)' }

    [object[]] $rows = @($NvidiaRows | Where-Object { $null -ne $_ -and [int]$_.Bar1Mib -gt 0 -and [int]$_.FbMib -gt 0 })
    if ($rows.Count -eq 0) { return New-GpuCheckResult $id $nom 'no determinado' 'nvidia-smi no informo BAR1' }

    foreach ($r in $rows) {
        if ([int]$r.Bar1Mib -le 256 -and [int]$r.FbMib -gt 256) {
            return New-GpuCheckResult $id $nom 'aviso' ('{0}: BAR1 {1} MiB de {2} MiB de VRAM' -f [string]$r.Name, [int]$r.Bar1Mib, [int]$r.FbMib) `
                ('ReBAR apagado en {0} (BAR1 {1} MiB de {2} MiB): se activa en BIOS con Above 4G Decoding + Re-Size BAR y CSM apagado. En NVIDIA suma poco (0-2%) y no en todos los juegos.' -f [string]$r.Name, [int]$r.Bar1Mib, [int]$r.FbMib)
        }
    }
    [object] $f = $rows[0]
    if ([int]$f.Bar1Mib -ge [int]([int]$f.FbMib * 0.9)) {
        return New-GpuCheckResult $id $nom 'ok' ('activo: BAR1 {0} MiB = VRAM {1} MiB' -f [int]$f.Bar1Mib, [int]$f.FbMib)
    }
    return New-GpuCheckResult $id $nom 'dato' ('BAR1 {0} MiB de {1} MiB de VRAM' -f [int]$f.Bar1Mib, [int]$f.FbMib)
}

# ─── A4: enlace PCIe degradado ────────────────────────────────────────────────
function Test-GpuCheckPcieLink {
    <#
    .SYNOPSIS
        Links: [Name, CurWidth, MaxWidth, CurGen, MaxGen] de las DEVPKEY de la
        dGPU. SmiRows: [Name, PState, GenCur, GenMax] de nvidia-smi.
    .DESCRIPTION
        Trampas medidas en la notebook de Mateo (§ 1 del informe):
        - MaxLinkWidth es lo que soporta la PLACA DE VIDEO, no la plataforma:
          x8 de x16 es de diseno en notebook. En notebook: dato, nunca aviso.
        - La generacion baja sola en reposo (ASPM). Solo cuenta la de
          nvidia-smi leida en P0, contra pcie.link.gen.max (que ya es
          min(GPU, placa)). La generacion de las DEVPKEY no se usa para avisar.
        Desktop: aviso si el ancho actual es <= x4 y la GPU soporta mas (una
        RX 6500 XT es x4 de fabrica).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyString()] [string] $ChassisKind = 'otro',
        [Parameter()] [AllowEmptyCollection()] [object[]] $Links = @(),
        [Parameter()] [AllowEmptyCollection()] [object[]] $SmiRows = @()
    )

    [string] $id = 'A4'; [string] $nom = 'Enlace PCIe de la GPU'
    [object[]] $ls = @($Links | Where-Object { $null -ne $_ -and [int]$_.CurWidth -gt 0 })
    [object[]] $ss = @($SmiRows | Where-Object { $null -ne $_ -and [int]$_.GenCur -gt 0 -and [int]$_.GenMax -gt 0 })
    if ($ls.Count -eq 0 -and $ss.Count -eq 0) {
        return New-GpuCheckResult $id $nom 'no determinado' 'el dispositivo no expone el enlace PCIe (VM, GPU sin driver o placa sin el dato)'
    }

    [System.Collections.Generic.List[string]] $det = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $ls) {
        $det.Add(('{0}: x{1} de x{2}, Gen{3} (max GPU Gen{4})' -f [string]$l.Name, [int]$l.CurWidth, [int]$l.MaxWidth, [int]$l.CurGen, [int]$l.MaxGen))
    }
    foreach ($s in $ss) {
        $det.Add(('nvidia-smi {0}: Gen{1} de Gen{2} en {3}' -f [string]$s.Name, [int]$s.GenCur, [int]$s.GenMax, [string]$s.PState))
    }
    [string] $detalle = ($det -join '; ')

    if ($ChassisKind -ne 'desktop') {
        return New-GpuCheckResult $id $nom 'dato' ($detalle + ' (fuera de un desktop el ancho es de diseno)')
    }
    foreach ($l in $ls) {
        if ([int]$l.CurWidth -le 4 -and [int]$l.MaxWidth -gt [int]$l.CurWidth) {
            return New-GpuCheckResult $id $nom 'aviso' $detalle `
                ('PCIe degradado: {0} en x{1} (soporta x{2}). Revisar que este en el slot de arriba (x16 del CPU), sin riser, y los contactos.' -f [string]$l.Name, [int]$l.CurWidth, [int]$l.MaxWidth)
        }
    }
    foreach ($s in $ss) {
        if ([string]$s.PState -eq 'P0' -and [int]$s.GenCur -lt [int]$s.GenMax) {
            return New-GpuCheckResult $id $nom 'aviso' $detalle `
                ('PCIe a Gen{0} con GPU y placa de Gen{1} ({2}, leido en P0): revisar slot/riser y que PCIe no este forzado bajo en BIOS. Confirmar bajo carga con GPU-Z.' -f [int]$s.GenCur, [int]$s.GenMax, [string]$s.Name)
        }
    }
    return New-GpuCheckResult $id $nom 'ok' $detalle
}

# ─── A5: dos modulos de RAM en el mismo canal ────────────────────────────────
function Get-RamChannelLetter {
    <#
        Solo acepta el canal dicho EXPLICITO ("P0 CHANNEL A", "ChannelA-DIMM0",
        "CHANNEL_B"). "DIMM_A1" / "BANK 0" no dicen el canal de forma confiable
        (depende del BIOS): ahi se devuelve '' y el detector calla.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [AllowEmptyString()] [string] $Text = '')
    if ($Text -match '(?i)CHANNEL\s*[-_]?\s*([A-H])(?![A-Za-z])') { return ([string]$Matches[1]).ToUpperInvariant() }
    return ''
}

function Test-GpuCheckRamChannels {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyCollection()] [object[]] $Modules = @()
    )

    [string] $id = 'A5'; [string] $nom = 'Canales de RAM'
    [object[]] $mods = @($Modules | Where-Object { $null -ne $_ })
    if ($mods.Count -eq 0) { return New-GpuCheckResult $id $nom 'no determinado' 'Windows no lista los modulos de RAM' }
    if ($mods.Count -eq 1) { return New-GpuCheckResult $id $nom 'dato' '1 modulo: single-channel (el aviso ya sale por RAM)' }

    [System.Collections.Generic.List[string]] $canales = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $mods) {
        [string] $bank = if ($null -ne $m.PSObject.Properties['BankLabel'])     { [string]$m.BankLabel }     else { '' }
        [string] $loc  = if ($null -ne $m.PSObject.Properties['DeviceLocator']) { [string]$m.DeviceLocator } else { '' }
        [string] $ch = Get-RamChannelLetter -Text $bank
        if ([string]::IsNullOrEmpty($ch)) { $ch = Get-RamChannelLetter -Text $loc }
        if ([string]::IsNullOrEmpty($ch)) {
            return New-GpuCheckResult $id $nom 'no determinado' ('el BIOS no dice el canal en las etiquetas ("{0}" / "{1}")' -f $bank, $loc)
        }
        $canales.Add($ch)
    }
    [string[]] $distintos = @($canales | Sort-Object -Unique)
    if ($distintos.Count -eq 1) {
        return New-GpuCheckResult $id $nom 'aviso' ('{0} modulos, todos en el canal {1}' -f $mods.Count, $distintos[0]) `
            ('RAM en single-channel: los {0} modulos estan en el canal {1}. Mover uno al slot del otro canal (ver manual de la placa, suele ser A2+B2): +20-40% en iGPU.' -f $mods.Count, $distintos[0])
    }
    return New-GpuCheckResult $id $nom 'ok' ('dual-channel (canales {0})' -f ($distintos -join ', '))
}

# ─── A6: driver generico o dGPU sin driver ────────────────────────────────────
function Test-GpuCheckDriver {
    <#
    .SYNOPSIS
        Adapters: [Name, PnpId, Provider, ErrorCode] de Win32_VideoController
        (+ DEVPKEY_Device_DriverProvider). Undriven: dispositivos PCI de video
        con error (tipico: la dGPU de una notebook recien formateada aparece
        como "3D Video Controller", codigo 28, y NO esta en Win32_VideoController).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [AllowEmptyCollection()] [object[]] $Adapters = @(),
        [Parameter()] [AllowEmptyCollection()] [object[]] $Undriven = @(),
        [Parameter()] [bool] $IsVirtual = $false
    )

    [string] $id = 'A6'; [string] $nom = 'Driver de video'
    [object[]] $ads = @($Adapters | Where-Object { $null -ne $_ })
    [object[]] $und = @($Undriven | Where-Object { $null -ne $_ })
    if ($ads.Count -eq 0 -and $und.Count -eq 0) { return New-GpuCheckResult $id $nom 'no determinado' 'Windows no lista adaptadores de video' }

    [System.Collections.Generic.List[string]] $hall = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $ads) {
        [string] $n    = [string]$a.Name
        [string] $pnp  = if ($null -ne $a.PSObject.Properties['PnpId'])     { [string]$a.PnpId }     else { '' }
        [string] $prov = if ($null -ne $a.PSObject.Properties['Provider'])  { [string]$a.Provider }  else { '' }
        [int]    $err  = if ($null -ne $a.PSObject.Properties['ErrorCode'] -and $null -ne $a.ErrorCode) { [int]$a.ErrorCode } else { 0 }
        if ($n -match '(?i)Basic (Display|Render)|pantalla b.sico') {
            $hall.Add(('{0}: driver generico de Windows' -f $n))
        }
        elseif ($prov -eq 'Microsoft' -and $pnp -match '(?i)VEN_(10DE|1002|8086)') {
            $hall.Add(('{0}: driver generico de Microsoft, no el del fabricante' -f $n))
        }
        if ($err -ne 0) { $hall.Add(('{0}: error de dispositivo (codigo {1})' -f $n, $err)) }
    }
    foreach ($u in $und) {
        [int] $uerr = if ($null -ne $u.PSObject.Properties['ErrorCode'] -and $null -ne $u.ErrorCode) { [int]$u.ErrorCode } else { 0 }
        $hall.Add(('{0}: GPU sin driver (codigo {1})' -f [string]$u.Name, $uerr))
    }

    if ($hall.Count -eq 0) {
        [string] $provs = (@($ads | ForEach-Object { '{0} ({1})' -f [string]$_.Name, $(if ($null -ne $_.PSObject.Properties['Provider'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Provider)) { [string]$_.Provider } else { '?' }) }) -join '; ')
        return New-GpuCheckResult $id $nom 'ok' $provs
    }
    [string] $detalle = ($hall -join '; ')
    if ($IsVirtual) { return New-GpuCheckResult $id $nom 'dato' ('maquina virtual, driver generico esperado: ' + $detalle) }
    return New-GpuCheckResult $id $nom 'aviso' $detalle `
        ('Driver de video generico o faltante ({0}). Instalar el driver del fabricante (DDU + driver oficial).' -f $detalle)
}

# ─── Fuentes: nvidia-smi y firmware (sombreables en tests) ────────────────────
function Invoke-PctkNvidiaSmi {
    <#
    .SYNOPSIS
        Corre nvidia-smi con timeout duro y devuelve [Ok, Lines, Error]. Nunca tira.
    .DESCRIPTION
        Por Process y no por `&`: con `&` bajo EAP=Stop el stderr de un exe
        nativo es terminante (regla de powershell.md), y un nvidia-smi colgado
        (GPU en mal estado) colgaria el arranque de PCTk. Timeout 3 s.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)

    [string[]] $candidatos = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    [string] $exe = ''
    foreach ($c in $candidatos) { if (Test-Path -LiteralPath $c -PathType Leaf) { $exe = $c; break } }
    if ([string]::IsNullOrEmpty($exe)) { return [PSCustomObject]@{ Ok = $false; Lines = [string[]]@(); Error = 'nvidia-smi no esta instalado' } }

    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($Arguments -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(3000)) {
            try { $p.Kill() } catch { }
            return [PSCustomObject]@{ Ok = $false; Lines = [string[]]@(); Error = 'nvidia-smi no respondio en 3 s' }
        }
        [string] $out = [string]$outTask.Result
        [string[]] $lines = @($out -split "`r?`n" | Where-Object { $_ -ne '' })
        if ($p.ExitCode -ne 0) { return [PSCustomObject]@{ Ok = $false; Lines = $lines; Error = ('nvidia-smi salio con codigo {0}' -f $p.ExitCode) } }
        return [PSCustomObject]@{ Ok = $true; Lines = $lines; Error = '' }
    }
    catch { return [PSCustomObject]@{ Ok = $false; Lines = [string[]]@(); Error = ('nvidia-smi: {0}' -f $_.Exception.Message) } }
    finally { if ($null -ne $p) { $p.Dispose() } }
}

function Get-PctkFirmwareType {
    <#
        'UEFI' | 'Legacy' | ''. Lee la variable de entorno firmware_type, que
        Windows 8+ pone en todo proceso al bootear (la misma fuente que
        kernel32!GetFirmwareType, sin Add-Type: costo cero; Add-Type midio
        205 ms). El informe descarta PEFirmwareType del registro: no existe en
        la notebook de Mateo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [string] $v = [string][Environment]::GetEnvironmentVariable('firmware_type')
    if ($v -match '^(?i)UEFI$') { return 'UEFI' }
    if ($v -match '^(?i)Legacy$') { return 'Legacy' }
    return ''
}

function ConvertFrom-NvidiaSmiQuery {
    <#
        Filas de: --query-gpu=pci.bus_id,name,memory.total,pstate,
        pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,
        pcie.link.width.max --format=csv,noheader,nounits
        gen.max ya es min(GPU, placa) (doc de --help-query-gpu). Se usan
        gen.current/gen.max y no gpucurrent/hostmax porque existen en drivers
        viejos: un campo desconocido hace fallar la query entera.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()] [AllowEmptyCollection()] [string[]] $Lines = @())

    [object[]] $rows = @()
    foreach ($ln in @($Lines)) {
        [string[]] $f = @(([string]$ln).Split(',') | ForEach-Object { $_.Trim() })
        if ($f.Count -lt 8 -or $f[0] -notmatch '^[0-9A-Fa-f]{4,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f]$') { continue }
        [int] $fb = 0; [int] $gc = 0; [int] $gm = 0; [int] $wc = 0; [int] $wm = 0
        [void][int]::TryParse($f[2], [ref]$fb)
        [void][int]::TryParse($f[4], [ref]$gc)
        [void][int]::TryParse($f[5], [ref]$gm)
        [void][int]::TryParse($f[6], [ref]$wc)
        [void][int]::TryParse($f[7], [ref]$wm)
        $rows += [PSCustomObject]@{ BusId = $f[0]; Name = $f[1]; FbMib = $fb; PState = $f[3]; GenCur = $gc; GenMax = $gm; WidthCur = $wc; WidthMax = $wm }
    }
    return $rows
}

function ConvertFrom-NvidiaSmiMemory {
    <# Filas [BusId, FbMib, Bar1Mib] de `nvidia-smi -q -d MEMORY`. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()] [AllowEmptyCollection()] [string[]] $Lines = @())

    [object[]] $rows = @()
    $cur = $null
    [string] $sec = ''
    foreach ($ln in @($Lines)) {
        [string] $l = [string]$ln
        if ($l -match '^GPU\s+([0-9A-Fa-f]{4,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f])\s*$') {
            $cur = [PSCustomObject]@{ BusId = $Matches[1]; FbMib = 0; Bar1Mib = 0 }
            $rows += $cur
            $sec = ''
            continue
        }
        if ($null -eq $cur) { continue }
        if ($l -match '^\s*FB Memory Usage\s*$')   { $sec = 'FB';   continue }
        if ($l -match '^\s*BAR1 Memory Usage\s*$') { $sec = 'BAR1'; continue }
        if ($l -notmatch ':') { $sec = ''; continue }
        if ($sec -ne '' -and $l -match '^\s*Total\s*:\s*(\d+)\s*MiB') {
            if ($sec -eq 'FB') { $cur.FbMib = [int]$Matches[1] } else { $cur.Bar1Mib = [int]$Matches[1] }
            $sec = ''
        }
    }
    return $rows
}

# ─── Orquestador: lee las fuentes una vez y corre los 6 detectores ───────────
function Get-GpuDisplayChecks {
    <#
    .SYNOPSIS
        Corre A1-A6 y devuelve [object[]] de resultados. Nunca tira.
    .DESCRIPTION
        Recibe lo que Get-MachineProfile YA consulto (Win32_VideoController,
        Win32_PhysicalMemory, chassis): no se repite ninguna query. Agrega:
          - root\wmi WmiMonitorListedSupportedSourceModes (148 ms medidos)
          - DEVPKEY de PCIe + proveedor del driver por CIM ClientOnly (46 ms)
          - nvidia-smi, solo si hay NVIDIA (2 llamadas, ~50 + ~170 ms)
          - Win32_PnPEntity con error, SOLO si no hay dGPU listada (292 ms):
            es como se ve una dGPU sin driver.
        *Error = '' si la fuente respondio; si no, el motivo (-> 'no determinado').
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()] [AllowEmptyCollection()] [object[]] $VideoControllers = @(),
        [Parameter()] [AllowEmptyString()] [string] $VideoError = '',
        [Parameter()] [AllowEmptyCollection()] [object[]] $RamModules = @(),
        [Parameter()] [AllowEmptyString()] [string] $RamError = '',
        [Parameter()] [string] $ChassisKind = 'otro',
        [Parameter()] [bool] $IsVirtual = $false
    )

    [object[]] $results = @()

    # ── Adaptadores normalizados ──
    [object[]] $ads = @()
    foreach ($v in @($VideoControllers | Where-Object { $null -ne $_ })) {
        [string] $n = if ($null -ne $v.PSObject.Properties['Name']) { [string]$v.Name } else { '' }
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        [string] $pnp = if ($null -ne $v.PSObject.Properties['PNPDeviceID'] -and $null -ne $v.PNPDeviceID) { [string]$v.PNPDeviceID } else { '' }
        [int] $hz = 0
        if ($null -ne $v.PSObject.Properties['CurrentRefreshRate'] -and $null -ne $v.CurrentRefreshRate) { $hz = [int]$v.CurrentRefreshRate }
        [int] $err = 0
        if ($null -ne $v.PSObject.Properties['ConfigManagerErrorCode'] -and $null -ne $v.ConfigManagerErrorCode) { $err = [int]$v.ConfigManagerErrorCode }
        [bool] $basic = ($n -match '(?i)Basic (Display|Render)|pantalla b.sico')
        $ads += [PSCustomObject]@{
            Name = $n.Trim(); PnpId = $pnp; RefreshHz = $hz; ErrorCode = $err; IsBasic = $basic
            IsIntegrated = (Test-IsIntegratedGpuName -GpuName $n)
            IsNvidia = ($pnp -match '(?i)VEN_10DE' -or $n -match '(?i)NVIDIA')
            Provider = ''; CurWidth = 0; MaxWidth = 0; CurGen = 0; MaxGen = 0
        }
    }
    # Un adaptador basico no es una dGPU (en una VM o sin driver, Test-IsIntegratedGpuName da $false).
    [object[]] $dgpus = @($ads | Where-Object { -not $_.IsIntegrated -and -not $_.IsBasic })
    [bool] $hasDGpu = $dgpus.Count -gt 0
    [bool] $hasNvidia = @($dgpus | Where-Object { $_.IsNvidia }).Count -gt 0

    # ── DEVPKEY por CIM ClientOnly (PCIe + proveedor del driver) ──
    [string] $pnpError = ''
    [string[]] $keys = @('DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkWidth',
                         'DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkSpeed',
                         'DEVPKEY_Device_DriverProvider')
    foreach ($a in $ads) {
        if ([string]::IsNullOrEmpty($a.PnpId)) { continue }
        try {
            $ent = New-CimInstance -ClassName Win32_PnPEntity -Property @{ DeviceID = $a.PnpId } -Key DeviceID -ClientOnly -ErrorAction Stop
            $res = Invoke-CimMethod -InputObject $ent -MethodName GetDeviceProperties -Arguments @{ devicePropertyKeys = $keys } -OperationTimeoutSec 2 -ErrorAction Stop
            foreach ($dp in @($res.deviceProperties | Where-Object { $null -ne $_ })) {
                if ($null -eq $dp.PSObject.Properties['Data'] -or $null -eq $dp.Data) { continue }
                switch ([string]$dp.KeyName) {
                    'DEVPKEY_PciDevice_CurrentLinkWidth' { $a.CurWidth = [int]$dp.Data }
                    'DEVPKEY_PciDevice_MaxLinkWidth'     { $a.MaxWidth = [int]$dp.Data }
                    'DEVPKEY_PciDevice_CurrentLinkSpeed' { $a.CurGen   = [int]$dp.Data }
                    'DEVPKEY_PciDevice_MaxLinkSpeed'     { $a.MaxGen   = [int]$dp.Data }
                    'DEVPKEY_Device_DriverProvider'      { $a.Provider = [string]$dp.Data }
                }
            }
        }
        catch { $pnpError = ('propiedades del dispositivo: {0}' -f $_.Exception.Message) }
    }

    # ── nvidia-smi (solo con NVIDIA) ──
    [bool] $smiOk = $false
    [string] $smiError = ''
    [object[]] $smiQuery = @()
    [object[]] $smiMem = @()
    if ($hasNvidia) {
        try {
            $q = Invoke-PctkNvidiaSmi -Arguments @('--query-gpu=pci.bus_id,name,memory.total,pstate,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max', '--format=csv,noheader,nounits')
            if ([bool]$q.Ok) { $smiQuery = @(ConvertFrom-NvidiaSmiQuery -Lines @($q.Lines)) } else { $smiError = [string]$q.Error }
            $m = Invoke-PctkNvidiaSmi -Arguments @('-q', '-d', 'MEMORY')
            if ([bool]$m.Ok) { $smiMem = @(ConvertFrom-NvidiaSmiMemory -Lines @($m.Lines)); $smiOk = $true }
            elseif ([string]::IsNullOrEmpty($smiError)) { $smiError = [string]$m.Error }
        }
        catch { $smiError = ('nvidia-smi: {0}' -f $_.Exception.Message) }
    }
    [object[]] $nvRows = @()
    foreach ($mm in $smiMem) {
        [string] $nm = 'GPU NVIDIA'
        foreach ($qq in $smiQuery) { if ([string]$qq.BusId -eq [string]$mm.BusId) { $nm = [string]$qq.Name } }
        $nvRows += [PSCustomObject]@{ Name = $nm; FbMib = [int]$mm.FbMib; Bar1Mib = [int]$mm.Bar1Mib }
    }

    # ── A1 ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        [object[]] $mons = @()
        foreach ($inst in @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorListedSupportedSourceModes' -OperationTimeoutSec 2 -ErrorAction SilentlyContinue)) {
            if ($null -eq $inst -or $null -eq $inst.PSObject.Properties['MonitorSourceModes']) { continue }
            [double] $max = 0
            foreach ($md in @($inst.MonitorSourceModes)) {
                if ($null -eq $md) { continue }
                [double] $den = [double]$md.VerticalRefreshRateDenominator
                if ($den -le 0) { continue }
                [double] $hz = [double]$md.VerticalRefreshRateNumerator / $den
                if ($hz -gt $max) { $max = $hz }
            }
            [string] $iname = if ($null -ne $inst.PSObject.Properties['InstanceName']) { [string]$inst.InstanceName } else { '' }
            $mons += [PSCustomObject]@{ Instance = $iname; MaxHz = $max }
        }
        [int[]] $hzs = @($ads | ForEach-Object { [int]$_.RefreshHz })
        $results += Test-GpuCheckRefresh -Monitors $mons -AdapterRefreshHz $hzs
    }
    catch { $results += New-GpuCheckResult 'A1' 'Refresh del monitor' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A2 ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        [object[]] $a2 = @($ads | Where-Object { -not $_.IsBasic })
        $results += Test-GpuCheckDisplayOutput -ChassisKind $ChassisKind -Adapters $a2
    }
    catch { $results += New-GpuCheckResult 'A2' 'Salida de video' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A3 firmware ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        [string] $fw = Get-PctkFirmwareType
        $results += Test-GpuCheckFirmware -FirmwareType $fw -HasDGpu $hasDGpu
    }
    catch { $results += New-GpuCheckResult 'A3-fw' 'Firmware (UEFI/Legacy)' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A3 ReBAR ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        $r3 = Test-GpuCheckRebar -HasDGpu $hasDGpu -HasNvidia $hasNvidia -SmiAvailable $smiOk -NvidiaRows $nvRows
        if ([string]$r3.Estado -eq 'no determinado' -and -not [string]::IsNullOrEmpty($smiError)) { $r3.Detalle = ('{0} ({1})' -f $r3.Detalle, $smiError) }
        $results += $r3
    }
    catch { $results += New-GpuCheckResult 'A3-rebar' 'ReBAR / SAM' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A4 ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        if (-not $hasDGpu) {
            $results += New-GpuCheckResult 'A4' 'Enlace PCIe de la GPU' 'no aplica' 'sin GPU dedicada'
        }
        else {
            [object[]] $links = @($dgpus | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; CurWidth = $_.CurWidth; MaxWidth = $_.MaxWidth; CurGen = $_.CurGen; MaxGen = $_.MaxGen } })
            [object[]] $sr = @($smiQuery | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; PState = $_.PState; GenCur = $_.GenCur; GenMax = $_.GenMax } })
            $r4 = Test-GpuCheckPcieLink -ChassisKind $ChassisKind -Links $links -SmiRows $sr
            if ([string]$r4.Estado -eq 'no determinado' -and -not [string]::IsNullOrEmpty($pnpError)) { $r4.Detalle = ('{0} ({1})' -f $r4.Detalle, $pnpError) }
            $results += $r4
        }
    }
    catch { $results += New-GpuCheckResult 'A4' 'Enlace PCIe de la GPU' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A5 ──
    try {
        if (-not [string]::IsNullOrEmpty($RamError)) { throw $RamError }
        $results += Test-GpuCheckRamChannels -Modules @($RamModules)
    }
    catch { $results += New-GpuCheckResult 'A5' 'Canales de RAM' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    # ── A6 ──
    try {
        if (-not [string]::IsNullOrEmpty($VideoError)) { throw $VideoError }
        [object[]] $undriven = @()
        if (-not $hasDGpu) {
            foreach ($pe in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -OperationTimeoutSec 2 -ErrorAction SilentlyContinue)) {
                if ($null -eq $pe) { continue }
                [string] $did = if ($null -ne $pe.PSObject.Properties['DeviceID'] -and $null -ne $pe.DeviceID) { [string]$pe.DeviceID } else { '' }
                if ($did -notmatch '(?i)^PCI\\VEN_(10DE|1002|8086)') { continue }
                [string] $cids = if ($null -ne $pe.PSObject.Properties['CompatibleID'] -and $null -ne $pe.CompatibleID) { (@($pe.CompatibleID) -join ' ') } else { '' }
                [string] $pname = if ($null -ne $pe.PSObject.Properties['Name'] -and $null -ne $pe.Name) { [string]$pe.Name } else { 'dispositivo PCI' }
                if ($cids -notmatch '(?i)CC_03' -and $pname -notmatch '(?i)video|vga|3d|display') { continue }
                [int] $pec = if ($null -ne $pe.PSObject.Properties['ConfigManagerErrorCode'] -and $null -ne $pe.ConfigManagerErrorCode) { [int]$pe.ConfigManagerErrorCode } else { 0 }
                $undriven += [PSCustomObject]@{ Name = $pname; PnpId = $did; ErrorCode = $pec }
            }
        }
        [object[]] $a6 = @($ads | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; PnpId = $_.PnpId; Provider = $_.Provider; ErrorCode = $_.ErrorCode } })
        $results += Test-GpuCheckDriver -Adapters $a6 -Undriven $undriven -IsVirtual $IsVirtual
    }
    catch { $results += New-GpuCheckResult 'A6' 'Driver de video' 'no determinado' ('no se pudo leer: {0}' -f $_.Exception.Message) }

    return $results
}
