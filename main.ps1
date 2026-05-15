#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Inicializar variables script-scope ANTES de cualquier exit posible — el bloque
# finally las lee, y con StrictMode el acceso a una variable nunca definida
# tira VariableIsUndefined y oculta el error original.
$script:InstanceMutex = $null

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

    # --- Dot-source de todos los .ps1 INLINE en script scope ---------------------
    # NO mover esto a una funcion. PowerShell dot-sourcing dentro de una funcion
    # define las funciones cargadas en el scope de esa funcion (que muere al
    # retornar), no en el script scope. Las funciones tienen que quedar
    # accesibles para el resto del try block (Show-MainMenu, Get-MachineProfile,
    # los handlers del Router, etc.), por lo tanto el dot-source vive aca al
    # nivel del script.
    [System.Collections.Generic.List[string]] $loaded = [System.Collections.Generic.List[string]]::new()
    foreach ($folder in @('core', 'modules', 'utils')) {
        $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
        foreach ($scriptFile in (Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object -Property Name)) {
            try {
                . $scriptFile.FullName
                $loaded.Add($scriptFile.Name)
            }
            catch {
                Write-Host ('  [!] Fallo al cargar {0}\{1}' -f $folder, $scriptFile.Name) -ForegroundColor Red
                Write-Host ('      Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
                Write-Host ('      Archivos cargados antes del fallo: {0}' -f ($loaded -join ', ')) -ForegroundColor DarkGray
                throw
            }
        }
    }

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
