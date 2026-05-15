#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Inicializar variables script-scope ANTES de cualquier exit posible — el bloque
# finally las lee, y con StrictMode el acceso a una variable nunca definida
# tira VariableIsUndefined y oculta el error original.
$script:InstanceMutex = $null

function Import-ToolkitScripts {
    <#
    .SYNOPSIS
        Dot-sourcea todos los .ps1 de core/, modules/, utils/ en orden.
        Si alguno tira al cargar, reporta cual archivo fue y re-lanza con
        contexto util para diagnostico.
    #>
    [CmdletBinding()]
    param()

    [System.Collections.Generic.List[string]] $loaded = [System.Collections.Generic.List[string]]::new()

    foreach ($folder in @('core', 'modules', 'utils')) {
        $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
        foreach ($scriptFile in (Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object -Property Name)) {
            try {
                . $scriptFile.FullName
                $loaded.Add($scriptFile.Name)
            }
            catch {
                Write-Host '' -ErrorAction SilentlyContinue
                Write-Host ('  [!] Fallo al cargar {0}\{1}' -f $folder, $scriptFile.Name) -ForegroundColor Red
                Write-Host ('      Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
                Write-Host ('      Archivos cargados antes del fallo: {0}' -f ($loaded -join ', ')) -ForegroundColor DarkGray
                throw  # re-lanzar para que el caller decida
            }
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
        throw 'Falta la funcion Get-MachineProfile en core/. Verificar que core/MachineProfile.ps1 parsea OK con: [Parser]::ParseFile("core/MachineProfile.ps1", [ref]$null, [ref]$null)'
    }
    if (-not (Get-Command -Name 'Show-MainMenu' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'Falta la funcion Show-MainMenu en core/Router.ps1.'
    }

    $machineProfile = Get-MachineProfile
    Show-MainMenu -MachineProfile $machineProfile
}
finally {
    if ($null -ne $script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        $script:InstanceMutex.Dispose()
    }
}
