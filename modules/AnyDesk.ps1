Set-StrictMode -Version Latest

function ConvertFrom-AnyDeskConf {
    <#
    .SYNOPSIS
        PURO (sin I/O): extrae el AnyDesk ID de las líneas de un system.conf.
        Devuelve el ID numérico (string) o $null si no aparece. Testeable con fixtures.
    .DESCRIPTION
        AnyDesk guarda el ID en system.conf bajo la clave 'ad.anynet.id=<numero>'.
        Match locale-agnóstico y tolerante a espacios. Solo acepta ID numérico
        (los ID de AnyDesk son enteros de 9-10 dígitos).
    #>
    [CmdletBinding()]
    param([string[]] $Lines = @())

    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        if ($line -match '^\s*ad\.anynet\.id\s*=\s*(\d+)\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Get-AnyDeskIdFromConf {
    <#
    .SYNOPSIS
        Lee un archivo system.conf y devuelve el AnyDesk ID o $null. Read-only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConfPath)

    if (-not (Test-Path -LiteralPath $ConfPath -PathType Leaf)) { return $null }
    [string[]] $lines = @(Get-Content -LiteralPath $ConfPath -ErrorAction SilentlyContinue)
    return (ConvertFrom-AnyDeskConf -Lines $lines)
}

function Get-AnyDeskId {
    <#
    .SYNOPSIS
        Devuelve el AnyDesk ID de esta PC (read-only) o $null si AnyDesk no está
        instalado / todavía sin registrar.
    .DESCRIPTION
        Lee el ID del system.conf de AnyDesk (clave 'ad.anynet.id='). Prueba las
        ubicaciones conocidas: instalación con servicio (ProgramData) y portable/
        per-user (APPDATA). NO invoca el binario AnyDesk: evita depender del path de
        instalación, no dispara el banner de "uso comercial" en el origen, y no
        requiere que el servicio esté corriendo. Puro file-read, StrictMode-safe,
        sin exe nativo (no hay riesgo de NativeCommandError bajo EAP=Stop).
    .PARAMETER ConfPaths
        Override de rutas a probar (para tests). Default = ubicaciones reales.
    .OUTPUTS
        [string] el ID numérico, o $null.
    #>
    [CmdletBinding()]
    param([string[]] $ConfPaths)

    [string[]] $paths = @()
    if ($PSBoundParameters.ContainsKey('ConfPaths') -and $null -ne $ConfPaths -and $ConfPaths.Count -gt 0) {
        $paths = @($ConfPaths)
    } else {
        # ProgramData = instalación con servicio (lo normal en PC de cliente).
        # APPDATA = AnyDesk portable / per-user.
        [string] $progData = [string] $env:ProgramData
        [string] $appData  = [string] $env:APPDATA
        if (-not [string]::IsNullOrWhiteSpace($progData)) { $paths += (Join-Path $progData 'AnyDesk\system.conf') }
        if (-not [string]::IsNullOrWhiteSpace($appData))  { $paths += (Join-Path $appData  'AnyDesk\system.conf') }
    }

    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        [string] $id = Get-AnyDeskIdFromConf -ConfPath $p
        if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
    }
    return $null
}
