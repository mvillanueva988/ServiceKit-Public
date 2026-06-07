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
