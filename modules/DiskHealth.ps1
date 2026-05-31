Set-StrictMode -Version Latest

# ─── DiskHealth.ps1 ───────────────────────────────────────────────────────────
# Diagnóstico read-only de salud de disco (SMART / wear / predicción de falla).
# Cost-zero: solo lee, no muta, sin proceso residente. Backlog #11→#17.
#
# PCTk ya recolecta Wear/Temp/Health en el snapshot (Telemetry.ps1), pero ahí
# es data plana sin umbral ni alerta. Este módulo: (1) agrega la señal canónica
# de predicción de falla (MSStorageDriver_FailurePredictStatus), (2) evalúa
# umbrales y emite ALERTA accionable, (3) se expone como diagnóstico standalone
# en el menú principal [7].
#
# TRAMPA (research 2026-05-30): un campo vacío NUNCA es "disco sano" — es "no
# reportado por este firmware". Algunos NVMe (Samsung/WD firmware propio)
# devuelven nulos en Wear/Temp. La evaluación lo refleja: Health del disco es
# la señal base; SMART faltante es info, no un OK falso.
#
# Umbrales PROVISIONALES (a validar en HW real — el research multi-LLM no dio
# números exactos; estos son sensatos de industria):
$script:DH_WearWarnPct = 80   # SSD: % de vida consumida estimada
$script:DH_WearCritPct = 90
$script:DH_TempWarnC    = 60   # disco; temp es la señal menos confiable
$script:DH_TempCritC    = 70

# ─── Normalizadores de enum (BUG cazado en HW 2026-05-30) ─────────────────────
# Get-PhysicalDisk devuelve HealthStatus y MediaType como enums UInt16. Al
# castear [string] dan el NUMERO crudo ('0' en vez de 'Healthy', '4' en vez de
# 'SSD'), no el label amigable. Comparar contra 'Healthy' marcaba CRIT a discos
# sanos. El smoke con fixtures de string nunca lo cazó — solo el HW real.
# Mapeo oficial: HealthStatus 0=Healthy 1=Warning 2/3=Unhealthy 5=Unknown.
function ConvertTo-DiskHealthLabel {
    [CmdletBinding()]
    param([object] $Raw)
    if ($null -eq $Raw) { return '' }
    [string] $s = ([string] $Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    switch -Regex ($s) {
        '^(0|Healthy)$'     { return 'Healthy' }
        '^(1|Warning)$'     { return 'Warning' }
        '^(2|3|Unhealthy)$' { return 'Unhealthy' }
        '^(5|Unknown)$'     { return 'Unknown' }
        default             { return $s }   # valor inesperado → crudo, no asumir
    }
}
# Mapeo oficial MediaType: 0=Unspecified 3=HDD 4=SSD 5=SCM.
function ConvertTo-DiskMediaTypeLabel {
    [CmdletBinding()]
    param([object] $Raw)
    if ($null -eq $Raw) { return 'Desconocido' }
    [string] $s = ([string] $Raw).Trim()
    switch -Regex ($s) {
        '^(3|HDD)$'          { return 'HDD' }
        '^(4|SSD)$'          { return 'SSD' }
        '^(5|SCM)$'          { return 'SCM' }
        '^(0|Unspecified|)$' { return 'Desconocido' }
        default              { return $s }
    }
}

# ─── Get-DiskAlertLevel (lógica pura de umbral — testeable sin HW) ────────────
function Get-DiskAlertLevel {
    <#
    .SYNOPSIS
        Evalúa los datos de un disco contra los umbrales y devuelve nivel +
        razones. Función PURA (no lee el sistema) → testeable con fixtures.
        Health del disco es la señal base; SMART faltante NO es un OK falso.
        Acepta HealthStatus como label ('Healthy') o enum crudo ('0').

    .OUTPUTS
        PSCustomObject con Alert (OK/WARN/CRIT/UNKNOWN) y Reasons[].
    #>
    [CmdletBinding()]
    param(
        [string] $HealthStatus,
        [object] $WearPct      = $null,
        [object] $TempC        = $null,
        [object] $ReadErrors   = $null,
        [object] $WriteErrors  = $null,
        [bool]   $PredictFail  = $false,
        [bool]   $SmartMissing = $false
    )

    [System.Collections.Generic.List[string]] $reasons = [System.Collections.Generic.List[string]]::new()
    [string] $alert = 'OK'

    # Normalizar enum numérico ('0'→'Healthy', etc.) antes de comparar.
    [string] $label = ConvertTo-DiskHealthLabel -Raw $HealthStatus
    if     ($label -eq 'Unhealthy') { $alert = 'CRIT'; $reasons.Add('HealthStatus=Unhealthy (Windows reporta el disco como no sano)') }
    elseif ($label -eq 'Warning')   { $alert = 'WARN'; $reasons.Add('HealthStatus=Warning (Windows marca advertencia en el disco)') }
    # 'Healthy' / 'Unknown' / '' → sin señal de alerta desde aquí.

    if ($PredictFail) {
        $alert = 'CRIT'; $reasons.Add('Predicción de falla SMART activa (hacer backup YA)')
    }
    if ($null -ne $WearPct) {
        if ([int] $WearPct -ge $script:DH_WearCritPct) { $alert = 'CRIT'; $reasons.Add("Wear $($WearPct)% (>= $($script:DH_WearCritPct)% critico)") }
        elseif ([int] $WearPct -ge $script:DH_WearWarnPct) { if ($alert -ne 'CRIT') { $alert = 'WARN' }; $reasons.Add("Wear $($WearPct)% (>= $($script:DH_WearWarnPct)% advertencia)") }
    }
    if ($null -ne $ReadErrors  -and [int64] $ReadErrors  -gt 0) { if ($alert -ne 'CRIT') { $alert = 'WARN' }; $reasons.Add("ReadErrors=$ReadErrors") }
    if ($null -ne $WriteErrors -and [int64] $WriteErrors -gt 0) { if ($alert -ne 'CRIT') { $alert = 'WARN' }; $reasons.Add("WriteErrors=$WriteErrors") }
    if ($null -ne $TempC) {
        if ([int] $TempC -ge $script:DH_TempCritC) { $alert = 'CRIT'; $reasons.Add("Temp $($TempC)C (>= $($script:DH_TempCritC)C critico)") }
        elseif ([int] $TempC -ge $script:DH_TempWarnC) { if ($alert -ne 'CRIT') { $alert = 'WARN' }; $reasons.Add("Temp $($TempC)C (>= $($script:DH_TempWarnC)C advertencia)") }
    }

    # Sin señal base usable ('' o 'Unknown') NI SMART → no se puede evaluar
    # (NUNCA asumir "sano" cuando no hay datos).
    [bool] $noBaseHealth = ($label -eq '' -or $label -eq 'Unknown')
    if ($alert -eq 'OK' -and $noBaseHealth -and $SmartMissing) {
        $alert = 'UNKNOWN'; $reasons.Add('Sin datos de salud disponibles (no se puede evaluar)')
    }

    return [PSCustomObject]@{ Alert = $alert; Reasons = $reasons.ToArray() }
}

# ─── Get-DiskHealth ───────────────────────────────────────────────────────────
function Get-DiskHealth {
    <#
    .SYNOPSIS
        Lee salud de cada disco físico y evalúa alertas. Read-only, smoke-safe
        (nunca lanza; usa timeouts para no colgar en disco virtual/lento).

    .OUTPUTS
        PSCustomObject con:
          - IsVM            : SMART se saltea en VM (cuelga en disco virtual)
          - Disks           : array por disco (labels normalizados) + Alert
                              (OK/WARN/CRIT/UNKNOWN) + AlertReasons[]
          - PredictFailAny  : $true si alguna instancia SMART predijo falla
          - AlertCount      : cuántos discos con WARN o CRIT
    #>
    [CmdletBinding()]
    param()

    [bool] $isVM = $false
    try { if (Get-Command Test-IsVirtualMachine -ErrorAction SilentlyContinue) { $vm = Test-IsVirtualMachine; if ($null -ne $vm -and $null -ne $vm.PSObject.Properties['IsVirtual']) { $isVM = [bool] $vm.IsVirtual } } } catch { }

    [bool] $hasTimeout = [bool] (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)

    # ── Predicción de falla SMART (señal canónica, best-effort) ───────────────
    # MSStorageDriver_FailurePredictStatus.PredictFailure = $true ⇒ backup ya.
    # Puede tirar "Not supported" según driver/firmware → try/catch. v1 lo trata
    # como flag global (el mapeo InstanceName→disco es frágil; mejora futura).
    [bool] $predictFailAny = $false
    [System.Collections.Generic.List[string]] $predictFailInstances = [System.Collections.Generic.List[string]]::new()
    if (-not $isVM) {
        try {
            $fp = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop
            foreach ($inst in @($fp)) {
                if ($null -ne $inst.PSObject.Properties['PredictFailure'] -and [bool] $inst.PredictFailure) {
                    $predictFailAny = $true
                    if ($null -ne $inst.PSObject.Properties['InstanceName']) { $predictFailInstances.Add([string] $inst.InstanceName) }
                }
            }
        }
        catch { }  # "Not supported" / sin permisos → simplemente no hay señal
    }

    # ── Discos físicos ────────────────────────────────────────────────────────
    [object[]] $physDisks = @()
    if ($hasTimeout) {
        $physDisks = @((Invoke-WithTimeout -TimeoutSeconds 10 -Default @() -ScriptBlock {
            @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        }).Value)
    } else {
        try { $physDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue) } catch { $physDisks = @() }
    }

    [System.Collections.Generic.List[PSCustomObject]] $diskList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($physDisk in $physDisks) {
        [string] $health    = ConvertTo-DiskHealthLabel    -Raw $physDisk.HealthStatus
        [string] $mediaType = ConvertTo-DiskMediaTypeLabel -Raw $physDisk.MediaType
        [object] $tempC    = $null
        [object] $wearPct  = $null
        [object] $readErr  = $null
        [object] $writeErr = $null

        if (-not $isVM) {
            [object] $rel = $null
            if ($hasTimeout) {
                $rel = (Invoke-WithTimeout -TimeoutSeconds 8 -Default $null -ScriptBlock {
                    param($d) $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                } -ArgumentList @($physDisk)).Value | Select-Object -First 1
            } else {
                try { $rel = $physDisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $rel = $null }
            }
            if ($rel) {
                if ($null -ne $rel.PSObject.Properties['Temperature']      -and [int] $rel.Temperature -gt 0) { $tempC   = [int] $rel.Temperature }
                if ($null -ne $rel.PSObject.Properties['Wear']             -and $null -ne $rel.Wear)          { $wearPct = [int] $rel.Wear }
                if ($null -ne $rel.PSObject.Properties['ReadErrorsTotal'])  { $readErr  = $rel.ReadErrorsTotal }
                if ($null -ne $rel.PSObject.Properties['WriteErrorsTotal']) { $writeErr = $rel.WriteErrorsTotal }
            }
        }

        # ── Evaluación de umbrales (delega en la función pura testeable) ──────
        [bool] $smartMissing = ($isVM -or ($null -eq $wearPct -and $null -eq $tempC -and $null -eq $readErr -and $null -eq $writeErr))
        $eval = Get-DiskAlertLevel -HealthStatus $health -WearPct $wearPct -TempC $tempC `
            -ReadErrors $readErr -WriteErrors $writeErr -PredictFail $predictFailAny -SmartMissing $smartMissing

        $diskList.Add([PSCustomObject]@{
            Name         = [string] $physDisk.FriendlyName
            MediaType    = $mediaType
            SizeGb       = [double] [math]::Round(([double] $physDisk.Size) / 1GB, 2)
            HealthStatus = $health
            WearPct      = $wearPct
            TempC        = $tempC
            ReadErrors   = $readErr
            WriteErrors  = $writeErr
            SmartMissing = $smartMissing
            Alert        = $eval.Alert
            AlertReasons = $eval.Reasons
        })
    }

    [object[]] $disks = $diskList.ToArray()
    [int] $alertCount = @($disks | Where-Object { $_.Alert -eq 'WARN' -or $_.Alert -eq 'CRIT' }).Count

    return [PSCustomObject]@{
        IsVM                 = $isVM
        Disks                = $disks
        PredictFailAny       = $predictFailAny
        PredictFailInstances = $predictFailInstances.ToArray()
        AlertCount           = $alertCount
    }
}

# ─── Show-DiskHealth ──────────────────────────────────────────────────────────
function Show-DiskHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $Data)

    Write-Host ''
    Write-Host '  SALUD DE DISCOS (SMART / wear)' -ForegroundColor DarkCyan
    Write-Host '  ==============================' -ForegroundColor DarkCyan

    if ($Data.IsVM) {
        Write-Host '  [i] Máquina virtual detectada: SMART no disponible en disco virtual.' -ForegroundColor DarkYellow
    }
    if (@($Data.Disks).Count -eq 0) {
        Write-Host '  [!] No se detectaron discos físicos.' -ForegroundColor Yellow
        return
    }

    foreach ($d in $Data.Disks) {
        [string] $color = switch ($d.Alert) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } 'UNKNOWN' { 'DarkGray' } default { 'Green' } }
        [string] $wear = if ($null -ne $d.WearPct) { "$($d.WearPct)%" } else { 'no reportado' }
        [string] $temp = if ($null -ne $d.TempC)   { "$($d.TempC)C" }   else { 'no reportado' }
        [string] $hlth = if (-not [string]::IsNullOrWhiteSpace($d.HealthStatus)) { $d.HealthStatus } else { 'no reportado' }

        Write-Host ''
        Write-Host ('  [{0}] {1}  ({2} GB, {3})' -f $d.Alert, $d.Name, $d.SizeGb, $d.MediaType) -ForegroundColor $color
        Write-Host ('        Health: {0}   Wear: {1}   Temp: {2}' -f $hlth, $wear, $temp) -ForegroundColor DarkGray
        if (@($d.AlertReasons).Count -gt 0 -and $d.Alert -ne 'OK') {
            foreach ($r in $d.AlertReasons) { Write-Host ('        -> {0}' -f $r) -ForegroundColor $color }
        }
    }

    Write-Host ''
    if ($Data.AlertCount -gt 0) {
        Write-Host ('  {0} disco(s) con alerta. Revisar arriba; considerar backup / reemplazo.' -f $Data.AlertCount) -ForegroundColor Yellow
    } else {
        Write-Host '  Sin alertas de salud en los discos detectados.' -ForegroundColor Green
    }
    Write-Host '  (Umbrales provisionales; SMART puede no estar disponible según firmware.)' -ForegroundColor DarkGray
}
