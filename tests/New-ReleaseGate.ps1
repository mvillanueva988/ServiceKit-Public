#Requires -Version 5.1
<#
.SYNOPSIS
    Prepara el gate de release: corre el pre-flight del artefacto publicado y deja
    un .wsb listo para doble-clic que instala y ejercita en Windows Sandbox.

.DESCRIPTION
    Un solo comando en el host. Hace tres cosas:

      1. Corre `release-preflight.ps1` contra la release PUBLICADA (integridad del
         paquete: hashes, BOM, parseo, VERSION, docs internas, one-liner).
      2. Arma la carpeta de staging del gate en `_local-dev\gate-v<version>\`
         (fuera del repo publico, gitignored).
      3. Escribe el `.wsb` con las rutas absolutas de ESTA maquina. Los .wsb
         viejos del repo tienen rutas hardcodeadas que se pudren cuando cambia un
         worktree; este se genera cada vez.

    Despues: doble clic al .wsb. La Sandbox instala con el one-liner real, corre
    el validate, deja el reporte en `out\` y DEJA PCTk ABIERTO para la pasada
    visual, que es la parte que no se automatiza.

.PARAMETER Version
    Version a gatear (ej. 2.5.0). Si se omite, se lee del archivo VERSION.

.PARAMETER SkipPreflight
    No correr el pre-flight (util si ya lo corriste y estas re-armando el .wsb).

.PARAMETER NoLaunch
    No abrir la Sandbox ni la carpeta de resultados: solo dejar el .wsb armado.

.EXAMPLE
    .\tests\New-ReleaseGate.ps1
    .\tests\New-ReleaseGate.ps1 -Version 2.5.0
    .\tests\New-ReleaseGate.ps1 -NoLaunch
#>

[CmdletBinding()]
param(
    [string] $Version = '',
    [switch] $SkipPreflight,
    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[string] $repoRoot = Split-Path -Parent $PSScriptRoot
[string] $testsDir = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
}
[string] $tag = 'v' + $Version

Write-Host ''
Write-Host ('  Preparando el gate de {0}' -f $tag) -ForegroundColor Cyan
Write-Host ''

# ─── 1. Pre-flight del artefacto publicado ────────────────────────────────────
[int] $preflightExit = 0
if (-not $SkipPreflight) {
    Write-Host '  --- Pre-flight del artefacto publicado ---' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $testsDir 'release-preflight.ps1') -Version $Version
    $preflightExit = $LASTEXITCODE
}

# ─── 2. Staging ───────────────────────────────────────────────────────────────
[string] $gateDir = Join-Path $repoRoot ('_local-dev\gate-{0}' -f $tag)
[string] $srcDir  = Join-Path $gateDir 'src'
[string] $outDir  = Join-Path $gateDir 'out'
foreach ($d in @($gateDir, $srcDir, $outDir)) {
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
}

# Los scripts del gate viajan a la Sandbox por la carpeta mapeada de solo lectura.
# NO son el artefacto: son el TEST. El artefacto lo baja la Sandbox de GitHub con
# el one-liner real -- si lo copiaramos desde aca, el gate probaria nuestro repo
# local y no lo que le llega al usuario, que es justo lo que no queremos.
foreach ($f in @('release-gate-validate.ps1', 'release-gate-launcher.ps1')) {
    Copy-Item -LiteralPath (Join-Path $testsDir $f) -Destination $srcDir -Force
}
Set-Content -LiteralPath (Join-Path $srcDir 'TAG.txt') -Value $tag -Encoding ASCII -NoNewline

# Limpiar corridas anteriores: un DONE.txt viejo hace creer que la de hoy termino.
Get-ChildItem -LiteralPath $outDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# ─── 3. .wsb con rutas absolutas de esta maquina ──────────────────────────────
# Networking queda HABILITADO (default de Sandbox): el gate tiene que bajar el
# instalador de GitHub, que es la mitad del punto.
[string] $wsbPath = Join-Path $gateDir ('gate-{0}.wsb' -f $tag)
[string] $wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$srcDir</HostFolder>
      <SandboxFolder>C:\gatesrc</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$outDir</HostFolder>
      <SandboxFolder>C:\out</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\gatesrc\release-gate-launcher.ps1</Command>
  </LogonCommand>
</Configuration>
"@
[System.IO.File]::WriteAllText($wsbPath, $wsb, [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  GATE PREPARADO' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
if ($preflightExit -ne 0 -and -not $SkipPreflight) {
    Write-Host '  [!] El pre-flight encontro defectos en el paquete (arriba).' -ForegroundColor Red
    Write-Host '      Conviene corregirlos ANTES de gastar la corrida de Sandbox.' -ForegroundColor Red
    Write-Host ''
}
Write-Host ('  .wsb armado en:  {0}' -f $wsbPath) -ForegroundColor White
Write-Host ''
Write-Host '  La Sandbox va a:' -ForegroundColor DarkGray
Write-Host ('    1. instalar {0} con el one-liner REAL del README' -f $tag) -ForegroundColor DarkGray
Write-Host '    2. ejercitar los caminos que mutan (PRE, [L], [U], #40)' -ForegroundColor DarkGray
Write-Host '    3. dejar el reporte en out\gate-report.txt' -ForegroundColor DarkGray
Write-Host '    4. dejar PCTk ABIERTO para tu pasada visual' -ForegroundColor DarkGray
Write-Host ''
Write-Host ('  Al terminar, el reporte queda en:  {0}' -f (Join-Path $outDir 'gate-report.txt')) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  RECORDATORIO: un PASS automatizado NO declara la release lista.' -ForegroundColor Yellow
Write-Host '  El render de la consola y el criterio de "esto se ve bien" son tuyos.' -ForegroundColor Yellow
Write-Host ''

# ─── Abrir la carpeta de resultados y arrancar la Sandbox ─────────────────────
if (-not $NoLaunch) {
    # La carpeta primero: queda abierta esperando el reporte, asi no hay que ir a
    # buscarla a mano cuando la Sandbox termina.
    try { Start-Process explorer.exe -ArgumentList $outDir } catch { }

    # Windows Sandbox se registra como handler de .wsb; Start-Process lo despacha
    # por asociacion de archivo (mismo efecto que el doble clic).
    [bool] $lanzada = $false
    try {
        Start-Process -FilePath $wsbPath -ErrorAction Stop
        $lanzada = $true
    } catch {
        Write-Host ('  [!] No se pudo abrir la Sandbox automaticamente: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host '      Windows Sandbox se habilita en "Caracteristicas de Windows".' -ForegroundColor DarkGray
        Write-Host ('      Mientras tanto: doble clic en {0}' -f $wsbPath) -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($lanzada) {
        Write-Host '  Sandbox arrancando. Tarda ~1 min en levantar y otro tanto en instalar.' -ForegroundColor Cyan
        Write-Host '  El reporte va a aparecer solo en la carpeta que se abrio.' -ForegroundColor Cyan
        Write-Host ''
    }
} else {
    Write-Host ('  (-NoLaunch) Doble clic en: {0}' -f $wsbPath) -ForegroundColor DarkGray
    Write-Host ''
}
