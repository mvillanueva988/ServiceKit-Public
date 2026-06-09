Set-StrictMode -Version Latest

# -- DiskMaintenance.ps1 -------------------------------------------------------
# Mantenimiento de discos: TRIM para SSD, defrag para HDD.
# Accion [A][17] del menu individual.
#
# GUARDRAIL CENTRAL: jamas defragmentar un SSD. La operacion se decide por
# MediaType normalizado (ConvertTo-DiskMediaTypeLabel de DiskHealth.ps1, que ya
# esta dot-sourced por main.ps1). Ante cualquier duda -> Skip.
#
# TRAMPA StrictMode: acumular con [object[]] $plan = @() + asignacion por
# statement, nunca `$v = if (c) { @($x) }` (desenrolla 1 elemento a escalar).
#
# NOTA Optimize-Volume: es cmdlet PS in-box (modulo Storage), NO exe nativo.
# La trampa "exe nativo + EAP=Stop = crash" de CLAUDE.md NO aplica aqui.
# Manejo de error: try/catch normal.

# -- Resolve-VolumeMaintenanceOp (PURA, testeable sin HW) ----------------------
function Resolve-VolumeMaintenanceOp {
    <#
    .SYNOPSIS
        Dado el label de MediaType, decide que operacion corresponde.
        Funcion pura: no lee el sistema, no muta nada. Testeable con fixtures.
    .OUTPUTS
        PSCustomObject { Op: 'ReTrim'|'Defrag'|'Skip'; Reason: string }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $MediaTypeLabel
    )

    switch ($MediaTypeLabel) {
        'SSD' {
            return [PSCustomObject]@{
                Op     = 'ReTrim'
                Reason = 'TRIM: correcto para SSD'
            }
        }
        'HDD' {
            return [PSCustomObject]@{
                Op     = 'Defrag'
                Reason = 'defrag: correcto para disco mecanico'
            }
        }
        default {
            return [PSCustomObject]@{
                Op     = 'Skip'
                Reason = 'tipo de disco no determinado: no se optimiza por seguridad'
            }
        }
    }
}

# -- Get-VolumeMaintenancePlan (read-only, best-effort) ------------------------
function Get-VolumeMaintenancePlan {
    <#
    .SYNOPSIS
        Enumera volumenes fijos con letra de unidad y construye el plan por disco.
        Read-only. Smoke-safe: nunca lanza; en VM/Sandbox el disco virtual da
        MediaType Unspecified -> todo Skip (comportamiento correcto).
    .OUTPUTS
        [object[]] de { DriveLetter, Label, SizeGb, MediaType, Op, Reason }
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    [System.Collections.Generic.List[PSCustomObject]] $planList = [System.Collections.Generic.List[PSCustomObject]]::new()

    [object[]] $volumes = @()
    try {
        $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
            $_.DriveType -eq 'Fixed' -and
            $null -ne $_.DriveLetter -and
            [string]$_.DriveLetter -ne ''
        })
    } catch {
        # Cualquier fallo al enumerar -> plan vacio (correcto en Sandbox)
    }

    foreach ($vol in $volumes) {
        [string] $driveLetter = [string] $vol.DriveLetter
        [string] $label       = if (-not [string]::IsNullOrWhiteSpace([string]$vol.FileSystemLabel)) { [string]$vol.FileSystemLabel } else { '' }
        [double] $sizeGb      = 0
        if ($null -ne $vol.PSObject.Properties['Size'] -and $null -ne $vol.Size) {
            $sizeGb = [math]::Round(([double]$vol.Size) / 1GB, 2)
        }

        [string] $mediaTypeRaw = 'Desconocido'
        try {
            # Obtener DiskNumber desde la particion con esa letra de unidad
            [object] $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $partition) {
                [uint32] $diskNumber = [uint32] $partition.DiskNumber
                # Obtener el disco fisico que matchea ese DiskNumber
                [object] $physDisk = Get-PhysicalDisk -ErrorAction Stop | Where-Object {
                    $null -ne $_.PSObject.Properties['DeviceId'] -and
                    [string]$_.DeviceId -eq [string]$diskNumber
                } | Select-Object -First 1
                if ($null -ne $physDisk) {
                    $mediaTypeRaw = [string] $physDisk.MediaType
                }
            }
        } catch {
            # Storage Spaces, RAID, sin acceso -> queda Desconocido -> Skip
        }

        [string] $mediaTypeLabel = ConvertTo-DiskMediaTypeLabel -Raw $mediaTypeRaw
        $op = Resolve-VolumeMaintenanceOp -MediaTypeLabel $mediaTypeLabel

        $planList.Add([PSCustomObject]@{
            DriveLetter = $driveLetter
            Label       = $label
            SizeGb      = $sizeGb
            MediaType   = $mediaTypeLabel
            Op          = $op.Op
            Reason      = $op.Reason
        })
    }

    [object[]] $plan = $planList.ToArray()
    return $plan
}

# -- Get-WindowsDefragTaskStatus (read-only, best-effort) ----------------------
function Get-WindowsDefragTaskStatus {
    <#
    .SYNOPSIS
        Lee el estado de la tarea programada de desfragmentacion de Windows.
        Retorna null si no se puede leer (try/catch, sin ruido).
    .OUTPUTS
        PSCustomObject { Exists, State, LastRunTime } o $null
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        [object] $taskInfo = $null
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName 'ScheduledDefrag' -TaskPath '\Microsoft\Windows\Defrag\' -ErrorAction Stop
        } catch { }

        [string] $state       = [string] $task.State
        [object] $lastRunTime = if ($null -ne $taskInfo) { $taskInfo.LastRunTime } else { $null }

        return [PSCustomObject]@{
            Exists      = $true
            State       = $state
            LastRunTime = $lastRunTime
        }
    } catch {
        return $null
    }
}

# -- Invoke-VolumeMaintenance (MUTANTE - disenada para correr en el job) -------
function Invoke-VolumeMaintenance {
    <#
    .SYNOPSIS
        Ejecuta Optimize-Volume por cada item del plan (solo ReTrim|Defrag).
        No recalcula: ejecuta exactamente lo confirmado. Un fallo por volumen
        no corta el resto. Retorna array de resultados por volumen.
    .PARAMETER Plan
        Array de objetos con al menos: DriveLetter, Op (ReTrim|Defrag).
    .OUTPUTS
        [object[]] de { DriveLetter, Op, Success, Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Plan
    )

    [System.Collections.Generic.List[PSCustomObject]] $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($item in $Plan) {
        [string] $dl = [string] $item.DriveLetter
        [string] $op = [string] $item.Op

        [bool]   $ok  = $false
        [string] $err = ''

        try {
            if ($op -eq 'ReTrim') {
                Optimize-Volume -DriveLetter $dl -ReTrim -ErrorAction Stop
                $ok = $true
            } elseif ($op -eq 'Defrag') {
                Optimize-Volume -DriveLetter $dl -Defrag -ErrorAction Stop
                $ok = $true
            } else {
                $err = "Op inesperada: $op"
            }
        } catch {
            $err = $_.Exception.Message
        }

        $results.Add([PSCustomObject]@{
            DriveLetter = $dl
            Op          = $op
            Success     = $ok
            Error       = $err
        })
    }

    [object[]] $output = $results.ToArray()
    return $output
}

# -- Start-DiskMaintenanceProcess (empaqueta Invoke-VolumeMaintenance en job) --
function Start-DiskMaintenanceProcess {
    <#
    .SYNOPSIS
        Empaqueta Invoke-VolumeMaintenance en un job asincrono via
        Invoke-AsyncToolkitJob con -ArgumentList, igual que Start-MaintenanceProcess.
        El plan se pasa serializado; los PSCustomObject cruzan deserializados con
        propiedades planas (alcanza para DriveLetter/Op).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Plan
    )

    $fnBody   = ${Function:Invoke-VolumeMaintenance}.ToString()
    $jobBlock = [scriptblock]::Create(@"
function Invoke-VolumeMaintenance {
$fnBody
}
Invoke-VolumeMaintenance -Plan `$args[0]
"@)

    return Invoke-AsyncToolkitJob -ScriptBlock $jobBlock -JobName 'DiskMaintenance' -ArgumentList @(,$Plan)
}
