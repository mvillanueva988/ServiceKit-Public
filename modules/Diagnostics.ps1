Set-StrictMode -Version Latest

# ─────────────────────────────────────────────────────────────────────────────
#  BSOD / CRASH HISTORY
# ─────────────────────────────────────────────────────────────────────────────

function Get-BsodHistory {
    <#
    .SYNOPSIS
        Lee el Event Log del sistema para detectar crashes, reinicios inesperados
        y BSODs en los últimos N días. Lista además los minidumps presentes.
        No requiere privilegios especiales para la lectura del Event Log.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int] $Days = 90
    )

    [DateTime] $since = (Get-Date).AddDays(-$Days)

    # ── Eventos de crash / reinicio inesperado ────────────────────────────────
    # 41   Kernel-Power     : reinicio sin apagado limpio (crash, corte de luz)
    # 1001 BugCheck         : BSOD confirmado (Stop Code presente)
    # 6008 EventLog         : apagado inesperado detectado al volver a arrancar

    [System.Collections.Generic.List[PSCustomObject]] $events = `
        [System.Collections.Generic.List[PSCustomObject]]::new()

    # PS5.1 StrictMode: inicializar ANTES del try. El catch la escribe y el objeto
    # de retorno la lee siempre; sin esto, el camino feliz tira VariableIsUndefined.
    [string] $readError = ''

    try {
        $raw = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = @(41, 1001, 6008)
            StartTime = $since
        } -ErrorAction SilentlyContinue

        foreach ($ev in $raw) {
            [string] $type = switch ($ev.Id) {
                41   { 'Reinicio inesperado (Kernel-Power)' }
                1001 { 'BSOD / BugCheck' }
                6008 { 'Apagado abrupto detectado' }
            }

            # Para EventID 1001 extraer el Stop Code — primero via Properties (locale-independent),
            # luego regex sobre Message como fallback
            [string] $detail = ''
            if ($ev.Id -eq 1001) {
                try {
                    foreach ($p in $ev.Properties) {
                        # OJO: no reusar $raw aca -- es la variable que alimenta el
                        # foreach de afuera. Se renombro a $propVal (2026-07-25).
                        $propVal = $p.Value
                        if ($propVal -is [long] -or $propVal -is [int] -or $propVal -is [uint32] -or $propVal -is [uint64]) {
                            [long] $val = [long] $propVal
                            if ($val -gt 0 -and $val -le 0xFFFFFFFFFFFF) {
                                $detail = '0x{0:X8}' -f $val
                                break
                            }
                        }
                    }
                } catch { }
                if ([string]::IsNullOrEmpty($detail) -and $ev.Message -match '0x[0-9A-Fa-f]{8,16}') {
                    $detail = $Matches[0]
                }
            }

            $events.Add([PSCustomObject]@{
                Fecha   = $ev.TimeCreated
                EventId = $ev.Id
                Tipo    = $type
                Detalle = $detail
            })
        }
    }
    catch {
        # Hasta 2026-07-25 este catch estaba vacio: un fallo REAL de lectura del
        # Event Log era indistinguible de "no hubo crashes" -> el handler reportaba
        # Success con 0 eventos y el operador se iba tranquilo. Ahora se propaga el
        # motivo para que la UI pueda decir "no se pudo leer" en vez de "todo bien".
        $readError = $_.Exception.Message
    }

    # Ordenar cronológico descendente
    [PSCustomObject[]] $sortedEvents = @($events | Sort-Object -Property Fecha -Descending)

    # ── Minidumps ─────────────────────────────────────────────────────────────
    [string] $dumpPath = "$env:SystemRoot\Minidump"
    [PSCustomObject[]] $minidumps = @()

    if (Test-Path -Path $dumpPath -PathType Container) {
        $minidumps = @(
            Get-ChildItem -Path $dumpPath -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property LastWriteTime -Descending |
                Select-Object -Property Name, LastWriteTime,
                    @{ Name = 'SizeMB'; Expression = { [math]::Round($_.Length / 1MB, 2) } }
        )
    }

    # Conteos DISCRIMINADOS (2026-07-25). Antes solo existia TotalCrashes = la suma
    # de los 3 event IDs, y esa suma es la que se mostraba y la que iba al audit.
    # Mezclar 1001 (BSOD real, falla de kernel) con 41/6008 (apagon sucio, corte de
    # luz) lleva a diagnosticos equivocados: el caso Olivo 2026-07-14 se leyo como
    # "11 BSOD" cuando eran 1 BSOD + 5 apagones. Son problemas DISTINTOS: uno apunta
    # a driver/RAM, el otro a la instalacion electrica o a la fuente.
    [int] $bsodCount  = @($sortedEvents | Where-Object { $_.EventId -eq 1001 }).Count
    [int] $powerCount = @($sortedEvents | Where-Object { $_.EventId -eq 41 -or $_.EventId -eq 6008 }).Count

    return [PSCustomObject]@{
        DaysScanned  = $Days
        Since        = $since
        TotalCrashes = $sortedEvents.Count   # total de EVENTOS (no de BSOD) - ver BsodCount
        BsodCount    = $bsodCount            # solo 1001: pantallazo azul real
        PowerCount   = $powerCount           # 41 + 6008: apagon sucio / corte
        Events       = $sortedEvents
        Minidumps    = $minidumps
        ReadFailed   = (-not [string]::IsNullOrEmpty($readError))
        ReadError    = $readError
    }
}

function Show-BsodHistory {
    <#
    .SYNOPSIS
        Visualiza el resultado de Get-BsodHistory en consola con colores.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Data
    )

    Write-Host ''
    Write-PctkSection ("  Crashes / reinicios inesperados en los ultimos {0} dias:" -f $Data.DaysScanned)

    # Si la lectura del Event Log fallo, decirlo. "0 eventos" y "no pude leer" NO son
    # lo mismo y hasta 2026-07-25 se veian igual (el operador se iba tranquilo).
    if ($Data.PSObject.Properties['ReadFailed'] -and [bool] $Data.ReadFailed) {
        Write-PctkErr  '  [!] No se pudo leer el Event Log -- este resultado NO es confiable.'
        Write-PctkHint ('      {0}' -f $Data.ReadError)
        Write-Host ''
    }

    if ($Data.TotalCrashes -eq 0) {
        Write-PctkOk '  Sin eventos criticos registrados.'
    } else {
        # Conteos SEPARADOS: un BSOD real (1001) apunta a driver/RAM; un apagon sucio
        # (41/6008) apunta a la electrica o la fuente. Sumarlos lleva a diagnosticar
        # mal -- caso Olivo: "11 BSOD" que eran 1 BSOD + 5 apagones.
        [int] $bsodN  = if ($Data.PSObject.Properties['BsodCount'])  { [int] $Data.BsodCount }  else { 0 }
        [int] $powerN = if ($Data.PSObject.Properties['PowerCount']) { [int] $Data.PowerCount } else { 0 }

        Write-PctkLine ("  BSOD reales (pantallazo azul) : {0}" -f $bsodN) $(
            if ($bsodN -ge 3) { 'err' } elseif ($bsodN -ge 1) { 'warn' } else { 'ok' }
        )
        Write-PctkLine ("  Apagones sucios / cortes      : {0}" -f $powerN) $(
            if ($powerN -ge 5) { 'warn' } else { 'hint' }
        )
        Write-PctkHint ("  (total de eventos: {0})" -f $Data.TotalCrashes)
        Write-Host ''
        Write-PctkSection ('  {0,-21} {1,-7} {2,-35} {3}' -f 'Fecha', 'ID', 'Tipo', 'Detalle')
        Write-PctkSection ('  {0}' -f ('-' * 80))

        foreach ($ev in $Data.Events) {
            [string] $rowKind = switch ($ev.EventId) {
                1001 { 'err'  }
                41   { 'warn' }
                6008 { 'warn' }
            }
            Write-PctkLine ('  {0,-21} {1,-7} {2,-35} {3}' -f `
                $ev.Fecha.ToString('dd/MM/yyyy HH:mm:ss'), `
                $ev.EventId, `
                $ev.Tipo, `
                $ev.Detalle) $rowKind
        }
    }

    Write-Host ''
    Write-PctkSection ('  Minidumps en {0}:' -f "$env:SystemRoot\Minidump")

    if ($Data.Minidumps.Count -eq 0) {
        Write-PctkHint '  Sin minidumps.'
    } else {
        Write-PctkSection ('  {0,-30} {1,-22} {2}' -f 'Archivo', 'Fecha', 'Tamanio')
        foreach ($d in $Data.Minidumps) {
            Write-Host ('  {0,-30} {1,-22} {2} MB' -f `
                $d.Name, `
                $d.LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss'), `
                $d.SizeMB)
        }
    }

    # ── Guia de diagnostico ───────────────────────────────────────────────────
    if ($Data.TotalCrashes -gt 0) {
        Write-Host ''
        Write-PctkSection '  Diagnostico sugerido:'
        Write-PctkSection ('  {0}' -f ('-' * 60))

        # Recopilar todos los Stop Codes presentes
        [string[]] $stopCodes = @(
            $Data.Events |
                Where-Object { $_.EventId -eq 1001 -and $_.Detalle -match '0x[0-9A-Fa-f]+' } |
                ForEach-Object { ($_.Detalle | Select-String -Pattern '0x[0-9A-Fa-f]+' -AllMatches).Matches.Value } |
                Sort-Object -Unique
        )

        # Tabla de lookup: Stop Code → causa + acciones
        $guidance = @(
            [PSCustomObject]@{
                Codes   = @('0x0000001A', '0x0000003B', '0x00000050', '0xC0000005')
                Causa   = 'RAM defectuosa o incompatible'
                Accion  = 'Correr MemTest86 (booteable). Si falla, retirar un modulo a la vez para aislar el defectuoso.'
            }
            [PSCustomObject]@{
                Codes   = @('0x0000009F', '0x000000FE', '0x0000004E')
                Causa   = 'Driver de energia o USB defectuoso'
                Accion  = 'Verificar fecha de los crashes vs actualizaciones recientes. Revertir drivers de chipset/USB.'
            }
            [PSCustomObject]@{
                Codes   = @('0x0000007E', '0x1000007E', '0x0000008E')
                Causa   = 'Driver de tercero bugueado'
                Accion  = 'Revisar minidump con WinDbg o subir a https://www.osronline.com para identificar el modulo culpable.'
            }
            [PSCustomObject]@{
                Codes   = @('0x00000124', '0x00000101', '0x00000117')
                Causa   = 'Hardware inestable (CPU/GPU/chipset)'
                Accion  = 'Verificar temperaturas con HWMonitor. Si hay OC, revertirlo. Puede indicar falla de PSU.'
            }
            [PSCustomObject]@{
                Codes   = @('0x0000007A', '0x00000024', '0x0000002E')
                Causa   = 'Disco con errores'
                Accion  = 'Correr chkdsk /r /f en la unidad de sistema. Verificar SMART con CrystalDiskInfo.'
            }
        )

        [bool] $matchFound = $false
        foreach ($entry in $guidance) {
            [bool] $hit = $false
            foreach ($code in $stopCodes) {
                if ($entry.Codes -contains $code.ToUpper()) { $hit = $true; break }
            }
            if ($hit) {
                $matchFound = $true
                Write-PctkWarn ("  [!] {0}" -f $entry.Causa)
                Write-PctkHint ("      {0}" -f $entry.Accion)
                Write-Host ''
            }
        }

        # Heurísticas por patrón de eventos cuando no hay Stop Code identificable
        [int] $kernelPowerCount = @($Data.Events | Where-Object { $_.EventId -eq 41 }).Count
        [int] $bsodCount        = @($Data.Events | Where-Object { $_.EventId -eq 1001 }).Count

        if (-not $matchFound -and $bsodCount -gt 0) {
            Write-PctkWarn '  [!] Stop Code no identificado automaticamente.'
            Write-PctkHint '      Subir el .dmp mas reciente a https://www.osronline.com'
            Write-PctkHint '      o analizarlo con: windbg -z "C:\Windows\Minidump\<archivo>.dmp"'
            Write-Host ''
        }

        if ($kernelPowerCount -ge 3 -and $bsodCount -eq 0) {
            Write-PctkWarn '  [!] Multiples Kernel-Power 41 sin BSOD asociado.'
            Write-PctkHint '      Causas comunes: PSU deteriorada, cortes de luz, overheating.'
            Write-PctkHint '      Verificar temperaturas en carga y revisar fuente de alimentacion.'
            Write-Host ''
        }

        if ($kernelPowerCount -eq 0 -and @($Data.Events | Where-Object { $_.EventId -eq 6008 }).Count -ge 3) {
            Write-PctkWarn '  [i] Multiples apagados abruptos (6008) sin crash de kernel.'
            Write-PctkHint '      Probablemente cortes de luz o apagados forzados. No indica falla de hardware.'
            Write-Host ''
        }
    }
}

function Start-BsodHistoryJob {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int] $Days = 90
    )

    [string]  $fnBody   = ${Function:Get-BsodHistory}.ToString()
    [int]     $daysVal  = $Days

    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Get-BsodHistory {
$fnBody
}
Get-BsodHistory -Days $daysVal
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'BsodHistory'
}

# ─────────────────────────────────────────────────────────────────────────────
#  DRIVER BACKUP
# ─────────────────────────────────────────────────────────────────────────────

function Backup-Drivers {
    <#
    .SYNOPSIS
        Exporta drivers de terceros (no-Microsoft) más drivers de red críticos
        a output\driver_backup\<timestamp>\.
        Usa Export-WindowsDriver filtrado por proveedor / clase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $OutputRoot
    )

    [string] $timestamp  = (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    [string] $destFolder = Join-Path $OutputRoot $timestamp

    try {
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    }
    catch {
        return [PSCustomObject]@{
            Success     = $false
            Destination = $destFolder
            Exported    = 0
            Message     = "No se pudo crear la carpeta de destino: $($_.Exception.Message)"
        }
    }

    # Obtener todos los drivers OEM del sistema
    [object[]] $allDrivers = @(
        Get-WindowsDriver -Online -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Driver -like 'oem*.inf' }
    )

    # Filtro: terceros (ProviderName no es Microsoft) + clase Net (red, siempre crítica)
    [object[]] $targets = @(
        $allDrivers | Where-Object {
            $_.ProviderName -notmatch '(?i)^microsoft' -or
            $_.ClassName    -eq 'Net'
        }
    )

    if ($targets.Count -eq 0) {
        return [PSCustomObject]@{
            Success     = $true
            Destination = $destFolder
            Exported    = 0
            Message     = 'No se encontraron drivers de terceros para exportar.'
        }
    }

    # Exportar al destino. Export-WindowsDriver exporta los .inf + binarios asociados.
    [int]    $exported = 0
    [string] $lastError = ''

    foreach ($drv in $targets) {
        try {
            Export-WindowsDriver -Online -Destination $destFolder `
                -ErrorAction Stop | Out-Null
            # Export-WindowsDriver exporta TODOS de una vez; salimos del loop después del primero exitoso
            $exported = $targets.Count
            break
        }
        catch {
            $lastError = $_.Exception.Message
            break
        }
    }

    # Si la exportación masiva falló, intentar driver a driver via pnputil
    if ($exported -eq 0) {
        # pnputil es nativo: bajo $ErrorActionPreference='Stop' (main.ps1) su stderr
        # se vuelve NativeCommandError terminante y el redirect NO salva (2>&1 / 2>$null
        # tiran igual). EAP local Continue lo neutraliza y deja correr el chequeo de
        # $LASTEXITCODE; auto-revierte al return. Misma trampa que powercfg en UsbPower.ps1.
        $ErrorActionPreference = 'Continue'

        foreach ($drv in $targets) {
            try {
                $driverDest = Join-Path $destFolder ($drv.Driver -replace '\.inf$', '')
                New-Item -Path $driverDest -ItemType Directory -Force | Out-Null
                & pnputil /export-driver $drv.Driver $driverDest 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $exported++ }
            }
            catch { <# continuar con el siguiente #> }
        }
    }

    return [PSCustomObject]@{
        Success     = ($exported -gt 0)
        Destination = $destFolder
        Exported    = $exported
        Total       = $targets.Count
        Message     = if ($exported -gt 0) { 'Backup completado.' } else { $lastError }
    }
}

function Start-DriverBackupJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $OutputRoot
    )

    [string] $fnBody     = ${Function:Backup-Drivers}.ToString()
    [string] $outputVal  = $OutputRoot

    [scriptblock] $jobBlock = [scriptblock]::Create(@"
function Backup-Drivers {
$fnBody
}
Backup-Drivers -OutputRoot '$outputVal'
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DriverBackup'
}
