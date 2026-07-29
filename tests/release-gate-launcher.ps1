#Requires -Version 5.1
# ASCII-only launcher para el auto-run de Windows Sandbox (LogonCommand). Sin BOM.
#
# Instala PCTk con el ONE-LINER REAL del README (el mismo texto que copia un
# usuario), espera a que la instalacion aparezca, y despues corre el validate.
#
# POR QUE se lanza desprendido: Launch.ps1 no tiene modo "instalar sin abrir" --
# al terminar de instalar abre el menu interactivo. Si lo esperaramos, el
# LogonCommand quedaria colgado para siempre. Lanzarlo desprendido tiene un bonus:
# cuando el validate termina, PCTk queda ABIERTO en la Sandbox, que es justo lo
# que hace falta para la pasada visual a mano.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$artifactsDir = 'C:\out'
$srcDir       = 'C:\gatesrc'
$repoRoot     = 'C:\PCTk'
$transcript   = Join-Path $artifactsDir 'launcher-transcript.txt'
$doneMarker   = Join-Path $artifactsDir 'DONE.txt'
$validatePs1  = Join-Path $srcDir 'release-gate-validate.ps1'

if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }

Write-Host '=== GATE DE RELEASE: LAUNCHER ==='
Start-Transcript -Path $transcript -Force

try {
    # El tag sale de un archivo que deja el generador del host. Asi el one-liner
    # apunta SIEMPRE al tag que se esta gateando y no a uno hardcodeado que se pudre.
    $tagFile = Join-Path $srcDir 'TAG.txt'
    if (-not (Test-Path $tagFile)) { throw "falta TAG.txt en $srcDir" }
    $tag = (Get-Content $tagFile -Raw).Trim()
    Write-Host "Tag a gatear: $tag"

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # --- ONE-LINER REAL DEL README ------------------------------------------
    # Textual, no una version "equivalente": la mitad del valor del gate es que
    # este camino exacto funcione en una maquina nueva (Execution Policy
    # Restricted, sin PowerShell configurado, sin nada).
    $f = "$env:TEMP\PCTk-Launch.ps1"
    $url = "https://raw.githubusercontent.com/mvillanueva988/ServiceKit-Public/$tag/Launch.ps1"
    Write-Host "Bajando $url"

    # REINTENTAR: la Sandbox NO tiene red cuando arranca este script. El
    # LogonCommand se dispara apenas loguea el usuario, antes de que el adaptador
    # consiga IP, asi que la primera descarga sale contra un stack sin red y tira
    # "Unable to connect to the remote server". Medido 2026-07-29: el gate murio
    # ahi y desde el host el fallo era INVISIBLE -- la Sandbox quedaba abierta y
    # vacia, como si estuviera trabajando.
    #
    # Se reintenta la descarga REAL en vez de pinguear algo primero: es la misma
    # operacion que hay que lograr, no un proxy de ella, y de paso cubre el caso
    # de que la red aparezca a medias (DNS antes que ruta, por ejemplo).
    $intentos = 0
    $bajado   = $false
    while (-not $bajado -and $intentos -lt 45) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $f -UseBasicParsing -TimeoutSec 20
            $bajado = $true
        }
        catch {
            $intentos++
            if ($intentos -eq 1) { Write-Host '  sin red todavia; reintentando cada 2s...' }
            Start-Sleep -Seconds 2
        }
    }
    if (-not $bajado) {
        throw "no se pudo bajar $url despues de $intentos intentos (~$($intentos * 2)s sin red)"
    }
    if ($intentos -gt 0) { Write-Host "  red lista tras ~$($intentos * 2)s" }

    Write-Host 'Ejecutando el instalador (desprendido)...'
    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f)

    # Esperar a que la instalacion este completa. No alcanza con que exista
    # main.ps1: la descarga+extraccion escribe muchos archivos y hay que dejarla
    # asentar antes de dot-sourcear.
    Write-Host 'Esperando la instalacion...'
    $waited = 0
    $ready  = $false
    while ($waited -lt 300) {
        if ((Test-Path (Join-Path $repoRoot 'main.ps1')) -and
            (Test-Path (Join-Path $repoRoot 'core\Router.ps1')) -and
            (Test-Path (Join-Path $repoRoot 'modules\ServiceState.ps1'))) {
            Start-Sleep -Seconds 8   # asentar
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if (-not $ready) { throw "la instalacion no aparecio en $repoRoot despues de ${waited}s" }
    Write-Host "Instalacion lista tras ${waited}s"

    # Foto de la instalacion recien hecha: sirve para probar DESPUES que se
    # instalo desde cero (sin tools\bin ni output\ de una corrida previa).
    Get-ChildItem $repoRoot | Select-Object Name, Mode, LastWriteTime |
        Format-Table -AutoSize | Out-File (Join-Path $artifactsDir 'install-tree.txt') -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validatePs1 `
        -ArtifactsDir $artifactsDir -RepoRoot $repoRoot
    Write-Host ''
    Write-Host "=== VALIDATE EXIT: $LASTEXITCODE ==="
}
catch {
    Write-Host "=== LAUNCHER ERROR: $($_.Exception.Message) ==="
}
finally {
    if (-not (Test-Path $doneMarker)) {
        "done $(Get-Date -Format o) failed=true (launcher-catch: el validate no llego a terminar)" |
            Out-File -FilePath $doneMarker -Encoding ASCII -Force
    }
    Stop-Transcript
    Write-Host ''
    Write-Host '======================================================='
    Write-Host '  AUTOMATIZADO LISTO. Mira C:\out\gate-report.txt'
    Write-Host ''
    Write-Host '  FALTA LA PASADA VISUAL: PCTk quedo abierto.'
    Write-Host '  Fijate que el menu entre en la ventana, que el banner'
    Write-Host '  no salga cortado y camina los menus que cambiaron.'
    Write-Host '======================================================='
}
