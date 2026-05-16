Set-StrictMode -Version Latest

# ProcessPriority -- prioridad estatica de proceso via IFEO (Image File Execution
# Options), sin ninguna herramienta externa y SIN proceso residente.
#
# AVISO EXPLICITO (D-S42a): esto es prioridad estatica via registry IFEO.
# NO es Process Lasso. Sin ProBalance dinamico. Sin servicio/tray residente.
# El efecto es que Windows asigna la clase de prioridad pedida cuando el
# proceso arranca; no hay control dinamico posterior. Cost-zero en la PC cliente.
#
# Registry: HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\
#              Image File Execution Options\<exe>\PerfOptions
#   CpuPriorityClass (DWORD):
#     3 = High (REALTIME = 5 es peligroso; High es el maximo seguro)
#     6 = AboveNormal
#
# Referencia: D-S42a, stage4.2-plan.md ss2.3.

$script:IFEOBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

[hashtable] $script:PriorityClassMap = @{
    'High'        = 3
    'AboveNormal' = 6
}
[hashtable] $script:PriorityClassRevMap = @{
    3 = 'High'
    6 = 'AboveNormal'
}

# ----- Get-ProcessPriorityIFEO -------------------------------------------------
function Get-ProcessPriorityIFEO {
    <#
    .SYNOPSIS
        Lee las entradas IFEO PerfOptions existentes en el registro.
        Read-only. Smoke-safe (nunca lanza).
        Devuelve hashtable exe -> clase ('High'|'AboveNormal'|"Raw:N").
    #>
    [CmdletBinding()]
    param()

    [hashtable] $result = @{}
    try {
        foreach ($key in @(Get-ChildItem -Path $script:IFEOBase -ErrorAction SilentlyContinue)) {
            [string] $exeName = $key.PSChildName
            try {
                $perf = Get-ItemProperty -Path (Join-Path $script:IFEOBase (Join-Path $exeName 'PerfOptions')) `
                                         -ErrorAction SilentlyContinue
                if ($null -ne $perf -and $null -ne $perf.PSObject.Properties['CpuPriorityClass']) {
                    [int] $raw = [int]$perf.CpuPriorityClass
                    [string] $cls = if ($script:PriorityClassRevMap.ContainsKey($raw)) {
                        $script:PriorityClassRevMap[$raw]
                    } else { "Raw:$raw" }
                    $result[$exeName] = $cls
                }
            } catch { }
        }
    } catch { }
    return $result
}

# ----- Set-ProcessPriorityIFEO -------------------------------------------------
function Set-ProcessPriorityIFEO {
    <#
    .SYNOPSIS
        Establece CpuPriorityClass en IFEO\<exe>\PerfOptions para uno o mas
        ejecutables. Persistente, sin proceso residente (cost-zero).
    .PARAMETER PriorityMap
        Hashtable o PSCustomObject: { "<exe.exe>" = "High"|"AboveNormal" }
    .NOTES
        AVISO: prioridad estatica IFEO, NO Process Lasso / sin ProBalance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $PriorityMap
    )

    [System.Collections.Generic.List[string]] $applied =
        [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]] $errors  =
        [System.Collections.Generic.List[string]]::new()

    # Normalizar: acepta hashtable o PSCustomObject
    [hashtable] $map = @{}
    if ($PriorityMap -is [hashtable]) {
        $PriorityMap.GetEnumerator() | ForEach-Object { $map[$_.Key] = $_.Value }
    } elseif ($null -ne $PriorityMap) {
        $PriorityMap.PSObject.Properties | ForEach-Object { $map[$_.Name] = [string]$_.Value }
    }

    foreach ($entry in $map.GetEnumerator()) {
        [string] $exe   = [string]$entry.Key
        [string] $cls   = [string]$entry.Value

        if ([string]::IsNullOrWhiteSpace($exe)) { continue }
        if (-not $script:PriorityClassMap.ContainsKey($cls)) {
            $errors.Add("Clase '$cls' invalida para '$exe'. Validos: High, AboveNormal.")
            continue
        }
        [int] $dword = $script:PriorityClassMap[$cls]

        try {
            [string] $ifeoPerfPath = Join-Path $script:IFEOBase (Join-Path $exe 'PerfOptions')
            if (-not (Test-Path $ifeoPerfPath)) {
                New-Item -Path $ifeoPerfPath -Force | Out-Null
            }
            Set-ItemProperty -Path $ifeoPerfPath `
                             -Name 'CpuPriorityClass' `
                             -Value $dword `
                             -Type DWord `
                             -ErrorAction Stop
            $applied.Add(("{0} -> {1} (CpuPriorityClass={2})" -f $exe, $cls, $dword))
        }
        catch { $errors.Add("IFEO $exe : $($_.Exception.Message)") }
    }

    return [PSCustomObject]@{
        Success         = ($errors.Count -eq 0)
        Skipped         = $false
        Applied         = $applied.ToArray()
        Errors          = $errors.ToArray()
        RestartRequired = $false
        Reason          = ('Prioridad estatica IFEO. NO Process Lasso / sin ProBalance dinamico. ' +
                           'Sin proceso residente (cost-zero).')
    }
}
