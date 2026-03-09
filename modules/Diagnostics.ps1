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

            # Para EventID 1001 extraer el Stop Code del mensaje si está presente
            [string] $detail = ''
            if ($ev.Id -eq 1001) {
                $msg = $ev.Message
                if ($msg -match '(?i)bugcheck.*?0x[0-9a-f]+') {
                    $detail = $Matches[0] -replace '[\r\n]+', ' '
                } elseif ($msg -match '0x[0-9A-Fa-f]{8}') {
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
    catch { <# Sin eventos en el rango — lista vacía #> }

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

    return [PSCustomObject]@{
        DaysScanned  = $Days
        Since        = $since
        TotalCrashes = $sortedEvents.Count
        Events       = $sortedEvents
        Minidumps    = $minidumps
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
    Write-Host ("  Crashes / reinicios inesperados en los ultimos {0} dias:" -f $Data.DaysScanned) -ForegroundColor DarkCyan

    if ($Data.TotalCrashes -eq 0) {
        Write-Host '  Sin eventos criticos registrados.' -ForegroundColor Green
    } else {
        Write-Host ("  Total eventos : {0}" -f $Data.TotalCrashes) -ForegroundColor $(
            if ($Data.TotalCrashes -ge 5) { 'Red' } elseif ($Data.TotalCrashes -ge 2) { 'Yellow' } else { 'Green' }
        )
        Write-Host ''
        Write-Host ('  {0,-21} {1,-7} {2,-35} {3}' -f 'Fecha', 'ID', 'Tipo', 'Detalle') -ForegroundColor DarkCyan
        Write-Host ('  {0}' -f ('-' * 80)) -ForegroundColor DarkCyan

        foreach ($ev in $Data.Events) {
            [string] $rowColor = switch ($ev.EventId) {
                1001 { 'Red'    }
                41   { 'Yellow' }
                6008 { 'DarkYellow' }
            }
            Write-Host ('  {0,-21} {1,-7} {2,-35} {3}' -f `
                $ev.Fecha.ToString('dd/MM/yyyy HH:mm:ss'), `
                $ev.EventId, `
                $ev.Tipo, `
                $ev.Detalle) -ForegroundColor $rowColor
        }
    }

    Write-Host ''
    Write-Host ('  Minidumps en {0}:' -f "$env:SystemRoot\Minidump") -ForegroundColor DarkCyan

    if ($Data.Minidumps.Count -eq 0) {
        Write-Host '  Sin minidumps.' -ForegroundColor DarkGray
    } else {
        Write-Host ('  {0,-30} {1,-22} {2}' -f 'Archivo', 'Fecha', 'Tamanio') -ForegroundColor DarkCyan
        foreach ($d in $Data.Minidumps) {
            Write-Host ('  {0,-30} {1,-22} {2} MB' -f `
                $d.Name, `
                $d.LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss'), `
                $d.SizeMB)
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
