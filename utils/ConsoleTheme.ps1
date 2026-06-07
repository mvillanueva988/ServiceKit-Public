Set-StrictMode -Version Latest

# ─── ConsoleTheme.ps1 ─────────────────────────────────────────────────────────
# Tema de consola PCTk (amber principal + slate/teal secundario). Usa ANSI/VT
# truecolor cuando se puede habilitar; si no (Windows viejo / output redirigido)
# degrada solo al estilo clasico de 16-color. Cost-zero, estatico (sin animacion).
# AnyDesk: el conhost del cliente renderiza local y AnyDesk lo espeja -> deberia
# verse bien; el fallback cubre el caso que no.

$script:PctkVT  = $false
$script:PctkEsc = [char]27

function Enable-PctkVT {
    <#
    .SYNOPSIS
        Habilita ENABLE_VIRTUAL_TERMINAL_PROCESSING en STD_OUTPUT (ANSI truecolor).
        Devuelve $true si quedo habilitado. No-throw. Guarda el estado en $script:PctkVT.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        if ([Console]::IsOutputRedirected) { $script:PctkVT = $false; return $false }
        if (-not ([System.Management.Automation.PSTypeName]'PctkVtConsole').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PctkVtConsole {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);
}
'@
        }
        [IntPtr] $h = [PctkVtConsole]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        if ($h -eq [IntPtr]::Zero) { $script:PctkVT = $false; return $false }
        [int] $m = 0
        if (-not [PctkVtConsole]::GetConsoleMode($h, [ref] $m)) { $script:PctkVT = $false; return $false }
        [void] [PctkVtConsole]::SetConsoleMode($h, ($m -bor 0x0004))   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        [int] $m2 = 0
        [void] [PctkVtConsole]::GetConsoleMode($h, [ref] $m2)
        $script:PctkVT = (($m2 -band 0x0004) -ne 0)
        return $script:PctkVT
    } catch { $script:PctkVT = $false; return $false }
}

function Test-PctkVT { [OutputType([bool])] param(); return [bool] $script:PctkVT }

# Helpers ANSI: devuelven '' si VT off (asi el mismo render degrada solo).
function Pf([int]$r,[int]$g,[int]$b) { if ($script:PctkVT) { "$($script:PctkEsc)[38;2;$r;$g;${b}m" } else { '' } }
function Pb([int]$r,[int]$g,[int]$b) { if ($script:PctkVT) { "$($script:PctkEsc)[48;2;$r;$g;${b}m" } else { '' } }
function Pe    { if ($script:PctkVT) { "$($script:PctkEsc)[0m" } else { '' } }
function Pbold { if ($script:PctkVT) { "$($script:PctkEsc)[1m" } else { '' } }

function Get-PctkGrad([string]$t,[int]$r1,[int]$g1,[int]$b1,[int]$r2,[int]$g2,[int]$b2) {
    if (-not $script:PctkVT) { return $t }
    [string] $o = ''; [int] $n = $t.Length
    for ([int] $i = 0; $i -lt $n; $i++) {
        [double] $f = if ($n -le 1) { 0 } else { $i / ($n - 1) }
        $o += (Pf ([int]($r1 + ($r2 - $r1) * $f)) ([int]($g1 + ($g2 - $g1) * $f)) ([int]($b1 + ($b2 - $b1) * $f))) + $t[$i]
    }
    return $o + (Pe)
}

$script:PctkBanner = @(
    '██████   ██████ ████████ ██  ██',
    '██   ██ ██         ██    ██ ██ ',
    '██████  ██         ██    ████  ',
    '██      ██         ██    ██ ██ ',
    '██       ██████    ██    ██  ██')

function Write-PctkMachineBanner {
    <#
    .SYNOPSIS
        Banner + panel de info de la PC con el tema (banner block ambar + caja
        doble). Si VT off -> estilo clasico (== box + lista). No-throw el render.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Rows,   # cada uno: @{ Label; Value }
        [Parameter(Mandatory)] [string]   $Tier,
        [string] $VmLine = ''
    )

    if (-not $script:PctkVT) {
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host '                   PCTk v2' -ForegroundColor Cyan
        Write-Host '        Mateo Villanueva ~ mvillanueva988' -ForegroundColor DarkGray
        Write-Host '================================================' -ForegroundColor DarkCyan
        foreach ($r in $Rows) { Write-Host ('  {0,-4} : {1}' -f $r.Label, $r.Value) }
        Write-Host ('  TIER : {0}' -f $Tier) -ForegroundColor Yellow
        if (-not [string]::IsNullOrEmpty($VmLine)) { Write-Host ('  VM   : {0}' -f $VmLine) -ForegroundColor Yellow }
        Write-Host '================================================' -ForegroundColor DarkCyan
        Write-Host ''
        return
    }

    foreach ($ln in $script:PctkBanner) { Write-Host ('  ' + (Get-PctkGrad $ln 255 185 45 255 105 0)) }
    Write-Host ('  ' + (Pbold) + (Pf 255 200 90) + 'PC Toolkit' + (Pe) + (Pf 95 108 124) + '  v2  -  acelerador del operador' + (Pe))
    Write-Host ('  ' + (Pf 80 215 185) + 'Mateo Villanueva ' + (Pf 95 108 124) + '~ mvillanueva988' + (Pe))
    Write-Host ''

    [string] $title = 'PCTk v2'
    [string] $badge = " $Tier "
    [int] $innerW = 50
    foreach ($r in $Rows) { [int] $l = ('{0,-4} {1}' -f $r.Label, $r.Value).Length; if ($l -gt $innerW) { $innerW = $l } }
    if (-not [string]::IsNullOrEmpty($VmLine)) { [int] $l = ('{0,-4} {1}' -f 'VM', $VmLine).Length; if ($l -gt $innerW) { $innerW = $l } }
    [int] $tl = $title.Length + $badge.Length + 1; if ($tl -gt $innerW) { $innerW = $tl }

    [string] $bx = Pf 80 92 108
    Write-Host ('  ' + $bx + '╔' + ('═' * ($innerW + 2)) + '╗' + (Pe))
    [int] $tpad = $innerW - $title.Length - $badge.Length; if ($tpad -lt 1) { $tpad = 1 }
    Write-Host ('  ' + $bx + '║ ' + (Pe) + (Pbold) + (Pf 235 238 242) + $title + (Pe) + (' ' * $tpad) + (Pb 150 95 0) + (Pf 25 20 0) + $badge + (Pe) + ' ' + $bx + '║' + (Pe))
    Write-Host ('  ' + $bx + '╠' + ('═' * ($innerW + 2)) + '╣' + (Pe))
    foreach ($r in $Rows) {
        [string] $plain = ('{0,-4} {1}' -f $r.Label, $r.Value)
        [int] $pad = $innerW - $plain.Length; if ($pad -lt 0) { $pad = 0 }
        Write-Host ('  ' + $bx + '║ ' + (Pe) + (Pf 95 150 150) + ('{0,-4} ' -f $r.Label) + (Pe) + (Pf 140 152 166) + $r.Value + (Pe) + (' ' * $pad) + ' ' + $bx + '║' + (Pe))
    }
    if (-not [string]::IsNullOrEmpty($VmLine)) {
        [string] $plain = ('{0,-4} {1}' -f 'VM', $VmLine)
        [int] $pad = $innerW - $plain.Length; if ($pad -lt 0) { $pad = 0 }
        Write-Host ('  ' + $bx + '║ ' + (Pe) + (Pf 230 190 80) + ('{0,-4} ' -f 'VM') + $VmLine + (Pe) + (' ' * $pad) + ' ' + $bx + '║' + (Pe))
    }
    Write-Host ('  ' + $bx + '╚' + ('═' * ($innerW + 2)) + '╝' + (Pe))
    Write-Host ''
}

# ─── Capa de salida tematizada (helpers de modulo) ───────────────────────────
# Cada helper degrada solo: VT on -> ANSI truecolor del tema; VT off -> Write-Host
# con el 16-color mas cercano (mismo look clasico de hoy). NUNCA emite ANSI crudo
# con VT off. Los handlers del Router / modulos adoptan estos en vez de cablear
# -ForegroundColor a mano, para que el tema sea una sola fuente de verdad.

function Get-PctkKindSpec {
    # Devuelve @{ R; G; B; C16 } para una intencion semantica de output.
    [OutputType([hashtable])]
    param([string] $Kind)
    switch (([string]$Kind).ToLowerInvariant()) {
        'work'    { return @{ R = 110; G = 225; B = 200; C16 = 'Cyan'     } }  # trabajando / en curso
        'ok'      { return @{ R = 90;  G = 210; B = 120; C16 = 'Green'    } }  # exito
        'warn'    { return @{ R = 255; G = 170; B = 40;  C16 = 'Yellow'   } }  # aviso blando
        'err'     { return @{ R = 210; G = 95;  B = 95;  C16 = 'Red'      } }  # error
        'hint'    { return @{ R = 95;  G = 108; B = 124; C16 = 'DarkGray' } }  # detalle / cancel / skip
        'section' { return @{ R = 80;  G = 215; B = 185; C16 = 'DarkCyan' } }  # sub-encabezado de reporte
        'white'   { return @{ R = 235; G = 238; B = 242; C16 = 'White'    } }  # enfasis
        default   { return @{ R = 140; G = 152; B = 166; C16 = 'Gray'     } }  # value / texto normal
    }
}

function Write-PctkLine {
    <#
    .SYNOPSIS
        Primitiva de salida tematizada. VT on -> ANSI truecolor; VT off -> 16-color.
        Kind: work/ok/warn/err/hint/section/white/value (default value). No-throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [string] $Kind = 'value',
        [switch] $NoNewline
    )
    [hashtable] $s = Get-PctkKindSpec $Kind
    if ($script:PctkVT) {
        Write-Host ((Pf $s.R $s.G $s.B) + $Text + (Pe)) -NoNewline:$NoNewline
    } else {
        Write-Host $Text -ForegroundColor ([string]$s.C16) -NoNewline:$NoNewline
    }
}

function Write-PctkOk      { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'ok' }
function Write-PctkWarn    { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'warn' }
function Write-PctkErr     { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'err' }
function Write-PctkHint    { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'hint' }
function Write-PctkWork    { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'work' }
function Write-PctkSection { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'section' }
function Write-PctkValue   { param([AllowEmptyString()][string] $Text) Write-PctkLine -Text $Text -Kind 'value' }

function ConvertTo-PctkAnsiFg {
    <#
    .SYNOPSIS
        Mapea un nombre 16-color (campo .Color heredado de las filas) a un Pf del
        tema. Devuelve '' si VT off, vacio, o nombre desconocido -> el caller cae a
        -ForegroundColor con el nombre original (sin regresion).
    #>
    [OutputType([string])]
    param([string] $Name)
    if (-not $script:PctkVT) { return '' }
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    switch ($Name.ToLowerInvariant()) {
        'green'      { return (Pf 90 210 120) }
        'darkgreen'  { return (Pf 70 165 95) }
        'yellow'     { return (Pf 255 190 70) }
        'darkyellow' { return (Pf 255 170 40) }
        'red'        { return (Pf 210 95 95) }
        'darkred'    { return (Pf 200 80 80) }
        'cyan'       { return (Pf 110 225 200) }
        'darkcyan'   { return (Pf 80 215 185) }
        'gray'       { return (Pf 140 152 166) }
        'darkgray'   { return (Pf 95 108 124) }
        'white'      { return (Pf 235 238 242) }
        default      { return '' }
    }
}

function Write-PctkActionTitle {
    <#
    .SYNOPSIS
        Encabezado de accion (b2): barra ambar '── TITULO ───' con VT; clasico
        DarkCyan + linea '====' sin VT. Imprime una linea en blanco antes y despues.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)
    [string] $t = ([string]$Text).Trim()
    Write-Host ''
    if ($script:PctkVT) {
        [int] $pad = [Math]::Max(3, 50 - $t.Length)
        Write-Host ('  ' + (Pf 255 170 40) + '── ' + $t + ' ' + ('─' * $pad) + (Pe))
    } else {
        Write-Host ('  ' + $t) -ForegroundColor DarkCyan
        Write-Host ('  ' + ('=' * $t.Length)) -ForegroundColor DarkCyan
    }
    Write-Host ''
}

function Get-PctkBadge {
    <#
    .SYNOPSIS
        Pastilla inline (c1) como token string para componer dentro de una fila.
        VT on -> fondo + fg con padding; VT off -> '[Texto]' plano (componible en
        una linea -ForegroundColor sin romper). Kind: ok/warn/danger/info/neutral.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [string] $Kind = 'neutral'
    )
    if (-not $script:PctkVT) { return ('[' + $Text + ']') }
    switch (([string]$Kind).ToLowerInvariant()) {
        'ok'     { return ((Pb 40 120 60)  + (Pf 230 255 238) + ' ' + $Text + ' ' + (Pe)) }
        'warn'   { return ((Pb 150 95 0)   + (Pf 255 240 210) + ' ' + $Text + ' ' + (Pe)) }
        'danger' { return ((Pb 120 40 40)  + (Pf 255 225 225) + ' ' + $Text + ' ' + (Pe)) }
        'info'   { return ((Pb 30 90 80)   + (Pf 200 255 245) + ' ' + $Text + ' ' + (Pe)) }
        default  { return ((Pb 60 68 80)   + (Pf 220 225 232) + ' ' + $Text + ' ' + (Pe)) }
    }
}

function Write-PctkDivider {
    <#
    .SYNOPSIS
        Divisor (e3): linea con gradiente ambar->dim con VT; '─' DarkGray sin VT.
    #>
    [CmdletBinding()]
    param([int] $Width = 60)
    if ($Width -lt 1) { $Width = 1 }
    if ($script:PctkVT) {
        Write-Host ('  ' + (Get-PctkGrad ('━' * $Width) 255 170 40 95 108 124))
    } else {
        Write-Host ('  ' + ('─' * $Width)) -ForegroundColor DarkGray
    }
}
