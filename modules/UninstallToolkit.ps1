Set-StrictMode -Version Latest

# --- New-PctkUninstallScript ---------------------------------------------------
# Devuelve el texto del script de limpieza desprendido como [string].
# Funcion PURA: no escribe, no ejecuta, no spawnea nada.
# El handler Invoke-UninstallToolkit es quien escribe el texto a disco y lanza.
function New-PctkUninstallScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [Parameter(Mandatory)] [int]    $PctkPid
    )

    return @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'

# CWD neutral: no bloquear el directorio a borrar
Set-Location `$env:TEMP

# Log persistente (queda aunque el .ps1 se autoborre)
`$logFile  = `$PSCommandPath -replace '\.ps1`$', '.log'
`$logLines = [System.Collections.Generic.List[string]]::new()
function WriteLog { param([string]`$m) Write-Host `$m; [void] `$script:logLines.Add(`$m) }

WriteLog ('=== PCTk uninstall {0} ===' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
WriteLog ('InstallRoot : $InstallRoot')
WriteLog ('PID espera  : $PctkPid')

# Esperar a que PCTk (PID $PctkPid) termine (max 30s)
`$waited = 0
while (`$waited -lt 30) {
    if (`$null -eq (Get-Process -Id $PctkPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
    `$waited++
}
WriteLog ('PID $PctkPid finalizo tras ' + `$waited + 's')

# Borrar root con retry + verificacion (resuelve race del cmd.exe / handles AV, max ~60s)
`$attempt = 0
`$deleted  = `$false
`$lastErr  = ''
while (`$attempt -lt 80) {
    Remove-Item -LiteralPath '$InstallRoot' -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path '$InstallRoot')) { `$deleted = `$true; break }
    `$attempt++
    Start-Sleep -Milliseconds 750
}
if (-not `$deleted) {
    try {
        Remove-Item -LiteralPath '$InstallRoot' -Recurse -Force -ErrorAction Stop
        `$deleted = `$true
    } catch { `$lastErr = `$_.Exception.Message }
}
WriteLog ('Deleted     : ' + `$deleted + ' (intentos: ' + `$attempt + ')')
if (`$lastErr) { WriteLog ('UltimoError : ' + `$lastErr) }

# Borrar artefactos temporales PCTk-*
Get-ChildItem -Path `$env:TEMP -Filter 'PCTk-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
WriteLog 'Temp PCTk-* limpiados'
WriteLog ('=== fin ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

# Escribir log a disco
try {
    [System.IO.File]::WriteAllLines(`$logFile, `$logLines, [System.Text.Encoding]::UTF8)
} catch { }

# Auto-borrar este script
Start-Sleep -Seconds 1
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@
}

# --- Save-PreUninstallArtifacts -----------------------------------------------
# Preserva artifacts antes de borrar: clients\ + audit\ en carpeta plana del
# Desktop (si habia clients\), y zip de audit\ + snapshots\ via [L] siempre.
# Devuelve $null si el copy de clients\ fallo (senial de abort para el caller).
# $ZipDestOverride permite redirigir el zip a un dir arbitrario (usado en tests).
function Save-PreUninstallArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [string] $ZipDestOverride = ''
    )

    [string] $clientsDir = Join-Path $InstallRoot 'output\clients'
    [string] $auditDir   = Join-Path $InstallRoot 'output\audit'
    [string] $preserveDest  = ''
    [string] $auditCopiedTo = ''

    # Bloque A: preservar clients\ + audit\ en carpeta plana del Desktop.
    if (Test-Path $clientsDir -PathType Container) {
        [string] $defaultDest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PCTk-historial-clientes'
        Write-Host ''
        Write-PctkWork ('  Historial de clientes: {0}' -f $clientsDir)
        [string] $rawDest = (Read-Host ("  Ruta de copia (Enter = {0})" -f $defaultDest)).Trim()
        $preserveDest = if ([string]::IsNullOrWhiteSpace($rawDest)) { $defaultDest } else { $rawDest }

        try {
            if (Test-Path $preserveDest) { Remove-Item $preserveDest -Recurse -Force }
            Copy-Item -Path $clientsDir -Destination $preserveDest -Recurse -Force
            Write-PctkOk ('  [OK] Historial copiado a: {0}' -f $preserveDest)
        } catch {
            Write-PctkErr ('  [!] No se pudo copiar el historial: {0}' -f $_.Exception.Message)
            Write-PctkHint '  Abortando sin borrar nada.'
            return $null
        }
    }

    # Audit escrita ANTES del zip para que Toolkit.Uninstall quede incluida.
    [string] $auditSummary = if ([string]::IsNullOrWhiteSpace($preserveDest)) { 'sin preservar' } else { $preserveDest }
    Write-ActionAudit -Action 'Toolkit.Uninstall' -Status 'Started' -Summary $auditSummary

    # Preservar audit\ dentro del folder plano (solo si entro al bloque A).
    if (-not [string]::IsNullOrWhiteSpace($preserveDest)) {
        if (Test-Path $auditDir -PathType Container) {
            try {
                [string] $auditExportDest = Join-Path $preserveDest 'audit'
                Copy-Item -Path $auditDir -Destination $auditExportDest -Recurse -Force
                Write-PctkOk ('  [OK] Audit copiado a: {0}' -f $auditExportDest)
                $auditCopiedTo = $auditExportDest
            } catch {
                Write-PctkWarn ('  [!] No se pudo copiar el audit: {0}' -f $_.Exception.Message)
            }
        }
    }

    # Bloque B: empaquetar antes de borrar.
    # #39 (2026-07-25): esto llamaba a Invoke-ExportClientLogs (el path a-la-carte),
    # asi que el ZIP del desinstalador salia SIN bundle-meta.json -> el CRM no lo
    # podia ingestar (sin meta no renderiza el boton "Importar a cliente"). Y
    # desinstalar al terminar el service es un camino natural: dejar la PC del
    # cliente limpia. Ahora usa Invoke-CloseService, que sintetiza el meta, mete
    # clients\ + reports\ y cierra el estado -- el mismo paquete que el [L].
    # Fallback al export directo si la funcion no cargo (mismo patron que Router.ps1).
    [string] $zipPath = ''
    try {
        Write-Host ''
        [string] $outputRoot = Join-Path $InstallRoot 'output'
        [PSCustomObject] $zipResult = $null

        # ── Decision de empaquetar (unificacion [L]/[U]) ──────────────────────
        # Antes, el unico criterio era "hay archivos en audit/snapshots/clients".
        # Como el [L] cierra el service pero NO borra esos archivos, hacer [L] y
        # despues [U] -- el flujo natural: me llevo el paquete y dejo la PC
        # limpia -- dejaba DOS ZIP en el Escritorio del cliente, y el segundo
        # peor (el service ya estaba cerrado, asi que salia "bundle parcial" sin
        # POST). Ahora se decide en este orden:
        #   1. Service ABIERTO en esta PC  -> empaquetar (el [U] tambien cierra).
        #   2. Bundle ya tomado en esta PC -> NO re-empaquetar, mostrar el ZIP.
        #   3. Datos sueltos sin service   -> empaquetar.
        #   4. Nada                        -> no fabricar un ZIP vacio.
        # OJO: los helpers de ServiceState reciben la RAIZ DEL TOOLKIT
        # ($InstallRoot), no la carpeta output.
        [bool] $svcAbierto = $false
        if (Get-Command -Name 'Get-ServiceState' -CommandType Function -ErrorAction SilentlyContinue) {
            $svcState = Get-ServiceState -OutputRootOverride $InstallRoot
            if ($null -ne $svcState -and
                $null -ne $svcState.PSObject.Properties['open']     -and [bool]$svcState.open -and
                $null -ne $svcState.PSObject.Properties['hostname'] -and [string]$svcState.hostname -eq $env:COMPUTERNAME) {
                $svcAbierto = $true
            }
        }

        [bool] $yaEmpaquetado = $false
        if (-not $svcAbierto -and
            (Get-Command -Name 'Test-BundleAlreadyTaken' -CommandType Function -ErrorAction SilentlyContinue)) {
            $yaEmpaquetado = Test-BundleAlreadyTaken -OutputRootOverride $InstallRoot
        }

        # Guard historico: Invoke-CloseService sintetiza un meta.json SIEMPRE, asi
        # que sin esto una PC sin service dejaria un ZIP inutil (solo meta) en el
        # Escritorio del cliente. La intencion del [U] es no perder datos, no
        # fabricar basura.
        [bool] $hayAlgo = $false
        foreach ($sub in @('audit', 'snapshots', 'clients')) {
            [string] $d = Join-Path $outputRoot $sub
            if ((Test-Path -LiteralPath $d -PathType Container) -and
                ($null -ne (Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1))) {
                $hayAlgo = $true
                break
            }
        }

        if ($yaEmpaquetado) {
            [string] $zipPrevio = ''
            if (Get-Command -Name 'Get-LastBundleMarker' -CommandType Function -ErrorAction SilentlyContinue) {
                $marker = Get-LastBundleMarker -OutputRootOverride $InstallRoot
                if ($null -ne $marker -and $null -ne $marker.PSObject.Properties['zip_path']) {
                    $zipPrevio = [string]$marker.zip_path
                }
            }
            Write-PctkOk '  [OK] El paquete de este service ya se genero; no se duplica.'
            if (-not [string]::IsNullOrWhiteSpace($zipPrevio)) {
                Write-PctkHint ('       {0}' -f $zipPrevio)
                $zipPath = $zipPrevio
            }
            $zipResult = [PSCustomObject]@{ Status = 'Skipped'; ZipPath = $zipPrevio }
        } elseif (-not $hayAlgo) {
            Write-PctkHint '  [i] Sin datos de service para empaquetar.'
            $zipResult = [PSCustomObject]@{ Status = 'Empty'; ZipPath = '' }
        } elseif (Get-Command -Name 'Invoke-CloseService' -CommandType Function -ErrorAction SilentlyContinue) {
            Write-PctkWork '  Empaquetando el service para llevarte...'
            [hashtable] $closeParams = @{
                OutputRootOverride  = $outputRoot
                ToolkitRootOverride = $InstallRoot
            }
            if (-not [string]::IsNullOrWhiteSpace($ZipDestOverride)) {
                $closeParams['DestDirOverride'] = $ZipDestOverride
            }
            $zipResult = Invoke-CloseService @closeParams
        } else {
            Write-PctkWork '  Empaquetando el service para llevarte...'
            [hashtable] $exportParams = @{
                TagOverride        = 'preuninstall'
                OutputRootOverride = $outputRoot
            }
            if (-not [string]::IsNullOrWhiteSpace($ZipDestOverride)) {
                $exportParams['DestDirOverride'] = $ZipDestOverride
            }
            $zipResult = Invoke-ExportClientLogs @exportParams
        }
        if ($zipResult.Status -eq 'OK') {
            Write-PctkOk ('  [OK] Zip generado: {0}' -f $zipResult.ZipPath)
            $zipPath = $zipResult.ZipPath
        } elseif ($zipResult.Status -eq 'Empty') {
            Write-PctkHint '  [i] Sin audit ni snapshots para empaquetar.'
        } elseif ($zipResult.Status -ne 'Skipped') {
            Write-PctkWarn ('  [!] No se pudo empaquetar (Status={0}). Borrado continua.' -f $zipResult.Status)
        }
    } catch {
        Write-PctkWarn ('  [!] Falla al empaquetar logs: {0}. Borrado continua.' -f $_.Exception.Message)
    }

    return [PSCustomObject]@{
        ClientsCopiedTo = $preserveDest
        AuditCopiedTo   = $auditCopiedTo
        ZipPath         = $zipPath
    }
}

# --- Confirm-RecoveryKeysSaved (#40) ------------------------------------------
# output\recovery\ guarda las claves de recuperacion de BitLocker capturadas con
# [A][18][C]. El deleter borra $InstallRoot ENTERO y Save-PreUninstallArtifacts
# preserva clients\ + audit\ + el ZIP pero NUNCA recovery\: capturar una clave y
# despues desinstalar la destruia sin avisar. Si el disco pide la clave mas
# tarde, el cliente queda afuera de su propia PC.
#
# NO se copia al Escritorio del cliente a proposito: es un secreto suyo, no algo
# para dejar suelto en su maquina (misma regla que la mantiene fuera del bundle).
# La capa 2 -- subirla a la boveda del CRM -- va aparte.
#
# Devuelve $true si se puede seguir: no habia claves, o el operador confirmo.
function Confirm-RecoveryKeysSaved {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot
    )

    [string] $recoveryDir = Join-Path $InstallRoot 'output\recovery'
    if (-not (Test-Path -LiteralPath $recoveryDir -PathType Container)) { return $true }

    [object[]] $files = @()
    $files = @(Get-ChildItem -LiteralPath $recoveryDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $true }

    Write-Host ''
    Write-PctkWarn '  [!] ATENCION: esta instalacion tiene claves de recuperacion de BitLocker guardadas.'
    Write-PctkWarn '      Desinstalar las BORRA. Si el disco pide la clave despues, el cliente queda afuera.'
    Write-Host ''

    foreach ($f in $files) {
        Write-PctkHint ('  --- {0}' -f $f.FullName)
        try {
            foreach ($ln in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop)) {
                Write-Host ('  {0}' -f $ln) -ForegroundColor Yellow
            }
        } catch {
            Write-PctkErr ('  [!] No se pudo leer el archivo: {0}' -f $_.Exception.Message)
            Write-PctkWarn '      Copialo a mano antes de seguir.'
        }
        Write-Host ''
    }

    Write-PctkHint '  Pasala a tu registro antes de seguir. No se copia al Escritorio del cliente.'
    Write-Host ''
    Write-PctkWarn '  Para confirmar que ya la guardaste, escribi exactamente: GUARDADA'
    [string] $ans = (Read-Host '  >').Trim().ToUpperInvariant()
    return ($ans -eq 'GUARDADA')
}

# --- Invoke-UninstallToolkit --------------------------------------------------
# Handler del menu [U]. Devuelve $true si el deleter fue spawneado (el caller
# debe salir inmediatamente). Devuelve $false si fue cancelado o fallo (continuar
# en el menu sin borrar nada).
function Invoke-UninstallToolkit {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Override para tests: sin esto el handler resuelve la instalacion REAL y
        # no habria forma de ejercitarlo sin borrar el toolkit de la maquina.
        [string] $InstallRootOverride = ''
    )

    # Resolver root: mismo idiom que Show-ToolsMenu / Invoke-ActionDriverBackup.
    # Este modulo vive en <root>\modules\, asi que $PSScriptRoot = <root>\modules
    # y Split-Path -Parent da <root>.
    [string] $installRoot = if (-not [string]::IsNullOrWhiteSpace($InstallRootOverride)) {
        $InstallRootOverride
    } else {
        Split-Path -Parent $PSScriptRoot
    }

    # Guard obligatorio (ss 6.2): verificar que el root parece una instalacion PCTk
    # antes de generar cualquier Remove-Item -Recurse -Force.
    if (-not (Test-Path (Join-Path $installRoot 'main.ps1') -PathType Leaf) -or
        -not (Test-Path (Join-Path $installRoot 'core\Router.ps1') -PathType Leaf)) {
        Write-PctkErr '  [!] No se pudo validar la instalacion de PCTk.'
        Write-PctkHint ("      Ruta resuelta: {0}" -f $installRoot)
        Write-PctkHint '  Abortando sin borrar nada.'
        return $false
    }

    # Gate #40: las claves de BitLocker se muestran y se confirman ANTES de
    # cualquier otra confirmacion -- el operador tiene que poder copiarlas sin
    # haberse comprometido todavia a borrar.
    if (-not (Confirm-RecoveryKeysSaved -InstallRoot $installRoot)) {
        Write-PctkHint '  Desinstalacion cancelada (clave de recuperacion sin confirmar).'
        return $false
    }

    # Primera confirmacion (ss 6.3): DefaultYes:$false = Enter aborta.
    if (-not (Confirm-Action -Title 'DESINSTALAR PCTk de esta PC?' -Lines @(
        ('Instalacion : {0}' -f $installRoot),
        ('Temporales  : {0}\PCTk-*' -f $env:TEMP),
        'El historial de clientes (output\clients\) se puede copiar antes.',
        'ESTA ACCION ES IRREVERSIBLE.'
    ) -DefaultYes:$false)) {
        Write-PctkHint '  Desinstalacion cancelada.'
        return $false
    }

    # Segunda confirmacion (ss 6.3): tipear BORRAR exacto.
    Write-Host ''
    Write-PctkWarn '  Para confirmar, escribe exactamente: BORRAR'
    [string] $gate2 = (Read-Host '  >').Trim().ToUpperInvariant()
    if ($gate2 -ne 'BORRAR') {
        Write-PctkHint '  Desinstalacion cancelada.'
        return $false
    }

    # Generar el script desprendido (funcion pura, sin side-effects).
    [string] $ts          = (Get-Date -Format 'yyyyMMdd-HHmmss')
    [string] $deleterPath = Join-Path $env:TEMP ('pctk-uninstall-' + $ts + '.ps1')
    [string] $deleterText = New-PctkUninstallScript -InstallRoot $installRoot -PctkPid $PID

    # Escribir el script a disco.
    try {
        [System.IO.File]::WriteAllText($deleterPath, $deleterText, [System.Text.Encoding]::UTF8)
    } catch {
        Write-PctkErr ('  [!] No se pudo crear el script de desinstalacion: {0}' -f $_.Exception.Message)
        Write-PctkHint '  Abortando sin borrar nada.'
        return $false
    }

    # Preservar artifacts (clients + audit en carpeta + zip snapshots).
    # Devuelve $null si el copy de clients\ fallo (abort).
    [PSCustomObject] $saveResult = Save-PreUninstallArtifacts -InstallRoot $installRoot
    if ($null -eq $saveResult) {
        if (Test-Path $deleterPath) { Remove-Item $deleterPath -Force -ErrorAction SilentlyContinue }
        return $false
    }

    # Lanzar detached: Hidden, fuera del proceso PCTk, sin bloquear.
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-NonInteractive', '-File', $deleterPath
        ) -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-PctkErr ('  [!] No se pudo lanzar el desinstalador: {0}' -f $_.Exception.Message)
        if (Test-Path $deleterPath) { Remove-Item $deleterPath -Force -ErrorAction SilentlyContinue }
        return $false
    }

    [string] $logHint = $deleterPath -replace '\.ps1$', '.log'
    Write-Host ''
    Write-PctkWarn '  PCTk cerrara ahora. El borrado se realizara en segundo plano.'
    Write-PctkHint ('  Resultado en: {0}' -f $logHint)
    return $true
}
