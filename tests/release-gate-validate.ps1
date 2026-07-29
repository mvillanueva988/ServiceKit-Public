#Requires -Version 5.1
<#
.SYNOPSIS
    Gate de release, parte automatizable: ejercita los CAMINOS QUE MUTAN sobre una
    instalacion real. Pensado para correr DENTRO de Windows Sandbox limpia.

.DESCRIPTION
    Corre contra la instalacion en $RepoRoot (por default C:\PCTk, o sea lo que
    dejo el one-liner del README). Dot-sourcea los modulos instalados y llama a
    los HANDLERS REALES -- no a las funciones puras, no a fixtures.

    DOS COSAS QUE ESTE SCRIPT HACE Y EL SMOKE NO:
    1. Corre con $ErrorActionPreference = 'Stop', igual que main.ps1. El smoke
       corre con 'Continue', y esa diferencia es exactamente la que dejo pasar el
       crash de [A][16] USB en el gate Sandbox #11: el stderr de un exe nativo
       bajo EAP=Stop se vuelve NativeCommandError TERMINANTE.
    2. Corre en una maquina de 1-de-cada-cosa (1 slot de RAM, 1 disco, 1 GPU),
       que es donde vive la trampa de PS5.1 con `@()` desenrollando a escalar.
       Una PC de desarrollo con 2 modulos de RAM NO ejercita ese camino.

    LO QUE NO CUBRE, A PROPOSITO:
    · El render de la consola (banner, menu, highlight). Se verifica que las FILAS
      del banner se arman bien, no que se VEAN bien. La pasada visual es de Mateo.
    · Todo lo que necesita hardware: bateria, BitLocker real, SMART.
    · powercfg: Windows Sandbox NO corre el servicio de energia (da 0x6ba RPC).
      No es un bug del toolkit; esos chequeos salen como SKIP con la razon.

    Un PASS aca NO declara la release lista. Declara que los caminos que mutan
    no se rompen en una maquina limpia.

.PARAMETER ArtifactsDir
    Carpeta (mapeada al host) donde se dejan el reporte y los artefactos.

.PARAMETER RepoRoot
    Raiz de la instalacion de PCTk a ejercitar.
#>

[CmdletBinding()]
param(
    [string] $ArtifactsDir = 'C:\out',
    [string] $RepoRoot     = 'C:\PCTk'
)

Set-StrictMode -Version Latest

# ESPEJO DE main.ps1. No cambiar a 'Continue': la mitad del valor de este script
# es correr bajo el mismo EAP que la produccion.
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ArtifactsDir)) {
    $null = New-Item -ItemType Directory -Path $ArtifactsDir -Force
}

[System.Collections.Generic.List[string]]        $log     = [System.Collections.Generic.List[string]]::new()
[System.Collections.Generic.List[PSCustomObject]] $results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Log {
    param([string] $Message, [string] $Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    [void] $log.Add($Message)
}

function Invoke-GateCheck {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    [string] $status = 'PASS'
    [string] $detail = ''
    try {
        $r = & $Body
        if ($r -is [string] -and -not [string]::IsNullOrWhiteSpace($r)) { $detail = $r }
    } catch {
        # Convencion: lanzar 'SKIP: <razon>' marca el chequeo como no aplicable
        # en este entorno en vez de como falla. Sirve para lo que la Sandbox
        # estructuralmente no puede cubrir (energia, HW), y deja la limitacion
        # ESCRITA en el reporte en vez de silenciada.
        [string] $msg = $_.Exception.Message
        if ($msg -like 'SKIP:*') {
            $status = 'SKIP'
            $detail = $msg.Substring(5).Trim()
        } else {
            $status = 'FAIL'
            $detail = $msg
        }
    }
    [void] $results.Add([PSCustomObject]@{ Id = $Id; Name = $Name; Status = $status; Detail = $detail })
    [string] $color = switch ($status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Log ('  [{0}] {1}  {2}' -f $status, $Id, $Name) $color
    if (-not [string]::IsNullOrWhiteSpace($detail)) { Log ('         {0}' -f $detail) 'DarkGray' }
}

Log ''
Log '════════════════════════════════════════════════════════════════════'
Log '  GATE DE RELEASE - caminos que mutan (Windows Sandbox)'
Log '════════════════════════════════════════════════════════════════════'
Log ('  Instalacion : {0}' -f $RepoRoot)
Log ('  EAP         : {0}  (espejo de main.ps1)' -f $ErrorActionPreference)
Log ('  Fecha       : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log ''

# ─── G1: la instalacion carga ─────────────────────────────────────────────────
# Bajo EAP=Stop y desde la copia INSTALADA (no el repo de desarrollo). Caza de una
# la clase entera "BOM / parse / Execution Policy" en su contexto real.
#
# EL DOT-SOURCE VA ACA, A NIVEL DE SCRIPT, Y NO ADENTRO DE Invoke-GateCheck.
# `Invoke-GateCheck` corre el body con `& $Body`, y el operador de llamada ejecuta
# el scriptblock en un scope HIJO: todo lo que se dot-sourcea ahi adentro muere
# cuando el scriptblock termina. Con el dot-source dentro del check, G1 pasaba
# feliz ("38 archivos cargados", sin un solo error) y de G2 en adelante NINGUNA
# funcion existia -- el reporte acusaba a la release de no definir handlers que en
# la maquina estaban perfectamente definidos. Medido en el gate de v2.5.0
# (2026-07-29): 1 PASS / 4 FAIL, todos falsos, mientras PCTk corria al lado.
#
# La leccion es la de siempre en este repo, en otra forma: el canario tiene que
# ejercitar el mismo camino que corre en produccion. `main.ps1` dot-sourcea a
# nivel de script; el gate lo hacia adentro de una funcion.
[int]    $archivosCargados = 0
[string] $errorDeCarga     = ''
try {
    foreach ($folder in @('utils', 'core', 'modules')) {
        [string] $dir = Join-Path $RepoRoot $folder
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            throw ('falta la carpeta {0} en la instalacion' -f $folder)
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File)) {
            . $f.FullName
            $archivosCargados++
        }
    }
}
catch {
    $errorDeCarga = $_.Exception.Message
}

Invoke-GateCheck -Id 'G1' -Name 'El toolkit instalado dot-sourcea completo bajo EAP=Stop' {
    if ($errorDeCarga -ne '') { throw $errorDeCarga }
    return ('{0} archivos cargados' -f $archivosCargados)
}

Invoke-GateCheck -Id 'G2' -Name 'Los handlers del service estan definidos' {
    [string[]] $req = @(
        'Get-MachineProfile', 'Show-MachineBanner', 'Invoke-CloseService',
        'Invoke-ServiceClose', 'Invoke-UninstallToolkit', 'Save-PreUninstallArtifacts',
        'Confirm-RecoveryKeysSaved', 'Set-LastBundleMarker', 'Test-BundleAlreadyTaken'
    )
    [System.Collections.Generic.List[string]] $falta = [System.Collections.Generic.List[string]]::new()
    foreach ($fn in $req) {
        if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) { [void] $falta.Add($fn) }
    }
    if ($falta.Count -gt 0) { throw ('faltan: {0}' -f ($falta -join ', ')) }
    return ('{0} funciones' -f $req.Count)
}

# ─── G3: el perfil de maquina en una PC de 1-de-cada-cosa ─────────────────────
# La Sandbox tiene 1 slot de RAM, 1 disco y 1 GPU por diseno. Es EL entorno donde
# vive la trampa de `$v = if (c) { @($x) }`, que con un solo elemento desenrolla a
# escalar y hace que .Count tire PropertyNotFoundStrict bajo StrictMode.
$script:GateProfile = $null
Invoke-GateCheck -Id 'G3' -Name 'Get-MachineProfile en maquina de 1-de-cada-cosa (StrictMode + EAP=Stop)' {
    Set-StrictMode -Version Latest
    $script:GateProfile = Get-MachineProfile
    if ($null -eq $script:GateProfile) { throw 'devolvio $null' }
    foreach ($campo in @('Manufacturer', 'Model', 'SerialNumber', 'RamMB', 'Tier')) {
        if (-not $script:GateProfile.PSObject.Properties[$campo]) { throw ('falta el campo {0}' -f $campo) }
    }
    return ('{0} / {1} / Tier {2}' -f $script:GateProfile.Manufacturer, $script:GateProfile.Model, $script:GateProfile.Tier)
}

# ─── G4: el banner se ARMA bien (que se VEA bien lo mira Mateo) ───────────────
Invoke-GateCheck -Id 'G4' -Name 'El banner arma las filas OEM y S/N (#28)' {
    Set-StrictMode -Version Latest
    if ($null -eq $script:GateProfile) { throw 'SKIP: G3 no dejo un perfil para usar' }
    $script:GateBannerRows = $null
    function Write-PctkMachineBanner { param([object[]]$Rows, [string]$Tier, [string]$VmLine = '')
        $script:GateBannerRows = $Rows }
    Show-MachineBanner -MachineProfile $script:GateProfile
    if ($null -eq $script:GateBannerRows) { throw 'el banner no armo ninguna fila' }
    [object[]] $rows = @($script:GateBannerRows)
    foreach ($lbl in @('OEM', 'S/N')) {
        if (-not @($rows | Where-Object { $_.Label -eq $lbl })) { throw ('falta la fila {0}' -f $lbl) }
    }
    return ('{0} filas' -f $rows.Count)
}

# ─── G5: snapshot PRE real (primer camino que MUTA) ───────────────────────────
Invoke-GateCheck -Id 'G5' -Name 'Snapshot PRE real: escribe a disco y abre el service' {
    Set-StrictMode -Version Latest
    if ($null -eq $script:GateProfile) { throw 'SKIP: sin perfil de maquina' }
    Invoke-DiagnosticSnapshot -Phase Pre -MachineProfile $script:GateProfile | Out-Null

    [string] $snapDir = Join-Path $RepoRoot 'output\snapshots'
    [object[]] $pre = @()
    if (Test-Path -LiteralPath $snapDir -PathType Container) {
        $pre = @(Get-ChildItem -LiteralPath $snapDir -Filter '*_pre.json' -File -ErrorAction SilentlyContinue)
    }
    if ($pre.Count -lt 1) { throw 'no se escribio ningun *_pre.json' }

    # El JSON tiene que parsear: un snapshot corrupto rompe todo lo de abajo.
    $null = Get-Content -LiteralPath $pre[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json

    $svc = Get-ServiceState
    if ($null -eq $svc) { throw 'el PRE no abrio el service state' }
    return ('{0} ({1:N0} bytes)' -f $pre[0].Name, $pre[0].Length)
}

# ─── G6: [L] cerrar service (el camino mutante principal) ─────────────────────
$script:GateZipL = ''
Invoke-GateCheck -Id 'G6' -Name '[L] Cerrar service: un ZIP con meta y SIN la clave de BitLocker' {
    Set-StrictMode -Version Latest
    [string] $desktop = [Environment]::GetFolderPath('Desktop')
    [object[]] $antes = @(Get-ChildItem -LiteralPath $desktop -Filter '*.zip' -File -ErrorAction SilentlyContinue)

    # Sembrar una clave de recuperacion ANTES del [L]: el bundle NUNCA debe
    # llevarla (feedback_secrets_not_in_bundles). Es la red anti-fuga.
    [string] $recDir = Join-Path $RepoRoot 'output\recovery'
    $null = New-Item -ItemType Directory -Path $recDir -Force
    Set-Content -LiteralPath (Join-Path $recDir 'bitlocker-recovery-GATE.txt') `
                -Value 'Clave : 111111-222222-333333-CANARIO' -Encoding UTF8

    $r = Invoke-CloseService
    if ($null -eq $r) { throw 'Invoke-CloseService devolvio $null' }
    if ([string]$r.Status -ne 'OK') { throw ('Status={0}' -f $r.Status) }

    [object[]] $despues = @(Get-ChildItem -LiteralPath $desktop -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if (($despues.Count - $antes.Count) -ne 1) {
        throw ('el [L] dejo {0} ZIP nuevos, esperado 1' -f ($despues.Count - $antes.Count))
    }
    $script:GateZipL = [string]$r.ZipPath

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($script:GateZipL)
    try {
        [string[]] $entries = @($zip.Entries | ForEach-Object { $_.FullName })
    } finally { $zip.Dispose() }

    if (-not @($entries | Where-Object { $_ -match '(?i)meta' })) {
        throw 'el bundle NO lleva bundle-meta.json: el CRM no lo puede ingestar'
    }
    if (@($entries | Where-Object { $_ -match '(?i)recovery|CANARIO' })) {
        throw 'FUGA DE SECRETO: la clave de BitLocker entro al bundle'
    }
    # Copiar el bundle al host para poder mirarlo despues del gate.
    Copy-Item -LiteralPath $script:GateZipL -Destination $ArtifactsDir -Force -ErrorAction SilentlyContinue
    return ('{0} entradas, meta OK, sin recovery' -f $entries.Count)
}

# ─── G7: [L] y despues [U] = UN solo paquete (la unificacion de v2.5.0) ───────
Invoke-GateCheck -Id 'G7' -Name '[U] despues del [L]: NO deja un segundo ZIP' {
    Set-StrictMode -Version Latest
    if ([string]::IsNullOrWhiteSpace($script:GateZipL)) { throw 'SKIP: G6 no dejo un ZIP de referencia' }

    if (-not (Test-BundleAlreadyTaken)) { throw 'el [L] no dejo el marcador del bundle' }

    [string] $desktop = [Environment]::GetFolderPath('Desktop')
    [object[]] $antes = @(Get-ChildItem -LiteralPath $desktop -Filter '*.zip' -File -ErrorAction SilentlyContinue)

    $ru = Save-PreUninstallArtifacts -InstallRoot $RepoRoot
    if ($null -eq $ru) { throw 'Save-PreUninstallArtifacts devolvio $null' }

    [object[]] $despues = @(Get-ChildItem -LiteralPath $desktop -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if ($despues.Count -ne $antes.Count) {
        throw ('el [U] genero {0} ZIP extra: volvio el bug de los dos paquetes en el Escritorio' -f ($despues.Count - $antes.Count))
    }
    if ([string]$ru.ZipPath -ne $script:GateZipL) {
        throw ('el [U] deberia reportar el ZIP del [L]; reporto "{0}"' -f $ru.ZipPath)
    }
    return 'un solo paquete'
}

# ─── G8: #40 el [U] no borra la clave de recuperacion sin confirmar ───────────
Invoke-GateCheck -Id 'G8' -Name '#40: con claves de BitLocker guardadas, el [U] frena' {
    Set-StrictMode -Version Latest
    [string] $recFile = Join-Path $RepoRoot 'output\recovery\bitlocker-recovery-GATE.txt'
    if (-not (Test-Path -LiteralPath $recFile)) {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $recFile) -Force
        Set-Content -LiteralPath $recFile -Value 'Clave : 111111-222222-333333-CANARIO' -Encoding UTF8
    }

    # El operador NO confirma. Las dos redes de abajo cazan el paso indebido
    # ANTES de que se borre nada real.
    function Read-Host { param([string]$Prompt) return 'no-confirmo' }
    function Confirm-Action { param([string]$Title, [string[]]$Lines, [bool]$DefaultYes = $true)
        throw 'el [U] paso el gate de claves SIN confirmacion' }
    function Start-Process { throw 'el [U] lanzo el deleter con claves sin confirmar' }

    [bool] $r = Invoke-UninstallToolkit -InstallRootOverride $RepoRoot
    if ($r) { throw 'el [U] devolvio $true: habria borrado la instalacion con la clave adentro' }
    if (-not (Test-Path -LiteralPath $recFile)) { throw 'la clave se borro' }
    return 'freno y la clave sigue viva'
}

# ─── G9: limitaciones estructurales del entorno, declaradas ───────────────────
# No se "saltean" en silencio: quedan escritas en el reporte para que se sepa que
# el gate NO las cubrio y hay que verlas en hardware real.
Invoke-GateCheck -Id 'G9' -Name 'Plan de energia (powercfg)' {
    throw 'SKIP: Windows Sandbox no corre el servicio de energia (powercfg da 0x6ba RPC). Validar en HW real.'
}
Invoke-GateCheck -Id 'G10' -Name 'Bateria, BitLocker real y SMART' {
    throw 'SKIP: la Sandbox no tiene bateria, ni volumen cifrado, ni disco fisico con SMART. Validar en HW real.'
}

# ─── Reporte ──────────────────────────────────────────────────────────────────
[int] $fails = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
[int] $pass  = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
[int] $skips = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count

Log ''
Log '────────────────────────────────────────────────────────────────────'
Log ('  PASS: {0}   FAIL: {1}   SKIP: {2}' -f $pass, $fails, $skips)
Log '────────────────────────────────────────────────────────────────────'
Log ''
if ($fails -gt 0) {
    Log '  HAY FALLAS. La release NO esta lista.' 'Red'
    foreach ($f in @($results | Where-Object { $_.Status -eq 'FAIL' })) {
        Log ('    [{0}] {1}: {2}' -f $f.Id, $f.Name, $f.Detail) 'Red'
    }
} else {
    Log '  Los caminos que mutan andan en una maquina limpia.' 'Green'
}
Log ''
Log '  FALTA LA PASADA VISUAL (no automatizable):' 'Yellow'
Log '    · que el menu ENTRE en la ventana y el banner no salga cortado'
Log '    · que la barra de seleccion no se desalinee al maximizar'
Log '    · caminar a mano los menus que toco esta release'
Log ''

[string] $reportPath = Join-Path $ArtifactsDir 'gate-report.txt'
try {
    [System.IO.File]::WriteAllLines($reportPath, $log, [System.Text.UTF8Encoding]::new($true))
} catch { }

# DONE.txt: el launcher lo usa para saber que el validate llego al final. Sin
# esto, "fallo" y "nunca corrio" se ven igual desde el host.
[string] $doneMarker = Join-Path $ArtifactsDir 'DONE.txt'
try {
    ('done {0} fails={1} pass={2} skips={3}' -f (Get-Date -Format o), $fails, $pass, $skips) |
        Out-File -FilePath $doneMarker -Encoding ASCII -Force
} catch { }

if ($fails -gt 0) { exit 1 }
exit 0
