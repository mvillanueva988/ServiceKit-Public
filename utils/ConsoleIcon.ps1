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
