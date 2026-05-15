#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-ToolkitScripts {
    [CmdletBinding()]
    param()

    foreach ($folder in @('core', 'modules', 'utils')) {
        $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
        foreach ($scriptFile in (Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object -Property Name)) {
            . $scriptFile.FullName
        }
    }
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    if (-not (Test-IsAdministrator)) {
        Write-Host '  [!] PCTk requiere PowerShell ejecutado como Administrador.' -ForegroundColor Red
        exit 1
    }

    $script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Local\PCTk')
    if (-not $script:InstanceMutex.WaitOne(0)) {
        Write-Host '  [!] Ya existe una instancia activa de PCTk.' -ForegroundColor Yellow
        exit 1
    }

    Import-ToolkitScripts

    if (-not (Get-Command -Name 'Get-MachineProfile' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Falta la funcion Get-MachineProfile en core/.'
    }
    if (-not (Get-Command -Name 'Show-MainMenu' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Falta la funcion Show-MainMenu en core/Router.ps1.'
    }

    $machineProfile = Get-MachineProfile
    Show-MainMenu -MachineProfile $machineProfile
}
finally {
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        $script:InstanceMutex.Dispose()
    }
}
