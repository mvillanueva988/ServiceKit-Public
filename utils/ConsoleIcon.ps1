Set-StrictMode -Version Latest

function Set-PctkConsoleIcon {
    [CmdletBinding()]
    param()

    try {
        [string] $root     = Split-Path -Parent $PSScriptRoot
        [string] $iconPath = Join-Path $root 'assets\pctk.ico'

        if (-not (Test-Path -LiteralPath $iconPath)) { return }

        if (-not ([System.Management.Automation.PSTypeName]'PctkWin32Icon').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PctkWin32Icon {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadImageW(IntPtr hInst, string name, uint type, int cx, int cy, uint fuLoad);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@
        }

        [IntPtr] $hwnd = [PctkWin32Icon]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }

        # LR_LOADFROMFILE=0x10 | LR_DEFAULTSIZE=0x40; IMAGE_ICON=1; cx=cy=0 -> system default sizes
        [IntPtr] $hIcon = [PctkWin32Icon]::LoadImageW([IntPtr]::Zero, $iconPath, 1, 0, 0, 0x50)
        if ($hIcon -eq [IntPtr]::Zero) { return }

        # WM_SETICON=0x0080; wParam: ICON_SMALL=0, ICON_BIG=1
        [void] [PctkWin32Icon]::SendMessageW($hwnd, 0x0080, [IntPtr]::Zero,    $hIcon)
        [void] [PctkWin32Icon]::SendMessageW($hwnd, 0x0080, [IntPtr]::new(1),  $hIcon)
    }
    catch { }
}

function Disable-PctkQuickEdit {
    <#
    .SYNOPSIS
        Desactiva QuickEdit mode del input de la consola PER-PROCESO (NO toca el
        registro). Con QuickEdit ON, un clic del operador PAUSA el script (parece
        colgado hasta apretar Enter/Esc) -> footgun clasico en sesiones AnyDesk.
        Devuelve el modo ORIGINAL (int) para poder restaurarlo al salir, o $null si
        no hay consola real (headless/redirigido). No-throw. Se revierte solo al
        cerrar el proceso -> no deja el sistema del cliente tocado.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    try {
        if (-not ([System.Management.Automation.PSTypeName]'PctkWin32Console').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PctkWin32Console {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
}
'@
        }
        [IntPtr] $h = [PctkWin32Console]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        if ($h -eq [IntPtr]::Zero) { return $null }
        [int] $mode = 0
        if (-not [PctkWin32Console]::GetConsoleMode($h, [ref] $mode)) { return $null }
        # ENABLE_QUICK_EDIT_MODE=0x40 (quitar); ENABLE_EXTENDED_FLAGS=0x80 (requerido al setear)
        [int] $newMode = ($mode -band -bnot 0x40) -bor 0x80
        [void] [PctkWin32Console]::SetConsoleMode($h, $newMode)
        return $mode
    }
    catch { return $null }
}

function Restore-PctkConsoleMode {
    <#
    .SYNOPSIS
        Restaura el modo de consola guardado por Disable-PctkQuickEdit (al salir de
        PCTk), para no dejar la consola del operador con QuickEdit apagado. No-throw.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $Mode)
    try {
        if (-not ([System.Management.Automation.PSTypeName]'PctkWin32Console').Type) { return }
        [IntPtr] $h = [PctkWin32Console]::GetStdHandle(-10)
        if ($h -eq [IntPtr]::Zero) { return }
        [void] [PctkWin32Console]::SetConsoleMode($h, $Mode)
    }
    catch { }
}
