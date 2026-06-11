Set-StrictMode -Version Latest

# ─── Encryption.ps1 ───────────────────────────────────────────────────────────
# Deteccion read-only de cifrado de disco (BitLocker / Device Encryption),
# captura de la clave de recuperacion, y desactivacion explicita.
#
# DISEÑO (ver _local-dev/bitlocker-gate-plan.md):
#   - Deteccion via CIM Win32_EncryptableVolume: enums NUMERICOS, locale-
#     independientes (NO string-parsing de manage-bde). Degrada limpio: si el
#     provider no existe (VM / Windows Sandbox / edicion sin soporte) -> retorna
#     Encryptable=$false, NUNCA tira.
#   - manage-bde se usa SOLO para el decrypt (exe nativo -> EAP neutralizado).
#   - La clave de recuperacion (48 digitos) es SENSIBLE: se muestra en pantalla
#     y se guarda en output\clients\ (fuera del ZIP [L]); NUNCA al audit JSONL.
#   - Requiere elevacion para leer el namespace de cifrado (PCTk corre elevado).

[string] $script:EncCimNamespace = 'root\cimv2\security\MicrosoftVolumeEncryption'
[string] $script:EncCimClass     = 'Win32_EncryptableVolume'

function ConvertTo-EncConversionLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [int] $Status = -1)
    switch ($Status) {
        0 { 'FullyDecrypted' }
        1 { 'FullyEncrypted' }
        2 { 'EncryptionInProgress' }
        3 { 'DecryptionInProgress' }
        4 { 'EncryptionPaused' }
        5 { 'DecryptionPaused' }
        default { 'Unknown' }
    }
}

function ConvertTo-EncMethodLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [int] $Method = -1)
    switch ($Method) {
        0 { 'None' }
        1 { 'AES128_DIFFUSER' }
        2 { 'AES256_DIFFUSER' }
        3 { 'AES128' }
        4 { 'AES256' }
        6 { 'XTS_AES128' }
        7 { 'XTS_AES256' }
        default { 'Unknown' }
    }
}

function Get-EncryptableVolume {
    <#
    .SYNOPSIS
        Devuelve la instancia CIM Win32_EncryptableVolume del drive pedido, o
        $null si el provider no existe / no esta soportado / no hay permisos.
        NUNCA tira (degradacion limpia para VM/Sandbox/Home sin soporte).
    #>
    [CmdletBinding()]
    param([Parameter()] [string] $DriveLetter = 'C:')

    try {
        [object[]] $vols = @(Get-CimInstance -Namespace $script:EncCimNamespace `
            -ClassName $script:EncCimClass `
            -Filter ("DriveLetter='{0}'" -f $DriveLetter) `
            -ErrorAction Stop)
        if ($vols.Count -gt 0) { return $vols[0] }
        return $null
    } catch {
        return $null
    }
}

function Get-DiskEncryptionStatus {
    <#
    .SYNOPSIS
        Estado de cifrado del drive (read-only). Defensivo: cualquier error ->
        shape con Encryptable=$false + Error poblado, sin throw.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter()] [string] $DriveLetter = 'C:')

    [PSCustomObject] $result = [PSCustomObject]@{
        DriveLetter          = $DriveLetter
        Encryptable          = $false
        ProtectionOn         = $false
        ConversionStatus     = -1
        ConversionLabel      = 'Unknown'
        EncryptionPct        = 0
        EncryptionMethod     = 'Unknown'
        IsEncrypted          = $false
        HasRecoveryProtector = $false
        Error                = $null
    }

    $vol = Get-EncryptableVolume -DriveLetter $DriveLetter
    if ($null -eq $vol) {
        $result.Error = 'Sin provider de cifrado (no encryptable / VM / sin permisos).'
        return $result
    }
    $result.Encryptable = $true

    # ── ProtectionStatus ──────────────────────────────────────────────────────
    try {
        $ps = Invoke-CimMethod -InputObject $vol -MethodName 'GetProtectionStatus' -ErrorAction Stop
        if ($null -ne $ps -and $null -ne $ps.PSObject.Properties['ProtectionStatus']) {
            $result.ProtectionOn = ([int]$ps.ProtectionStatus -eq 1)
        }
    } catch { }

    # ── ConversionStatus + % ──────────────────────────────────────────────────
    try {
        $cs = Invoke-CimMethod -InputObject $vol -MethodName 'GetConversionStatus' -ErrorAction Stop
        if ($null -ne $cs) {
            if ($null -ne $cs.PSObject.Properties['ConversionStatus']) {
                $result.ConversionStatus = [int]$cs.ConversionStatus
                $result.ConversionLabel  = ConvertTo-EncConversionLabel -Status $result.ConversionStatus
            }
            if ($null -ne $cs.PSObject.Properties['EncryptionPercentage']) {
                [int] $pct = 0
                [void][int]::TryParse([string]$cs.EncryptionPercentage, [ref]$pct)
                $result.EncryptionPct = $pct
            }
        }
    } catch { }

    # ── EncryptionMethod ──────────────────────────────────────────────────────
    try {
        $em = Invoke-CimMethod -InputObject $vol -MethodName 'GetEncryptionMethod' -ErrorAction Stop
        if ($null -ne $em -and $null -ne $em.PSObject.Properties['EncryptionMethod']) {
            $result.EncryptionMethod = ConvertTo-EncMethodLabel -Method ([int]$em.EncryptionMethod)
        }
    } catch { }

    # ── Recovery protector presente? (tipo 3 = NumericalPassword) ─────────────
    try {
        $kp = Invoke-CimMethod -InputObject $vol -MethodName 'GetKeyProtectors' `
            -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction Stop
        if ($null -ne $kp -and $null -ne $kp.PSObject.Properties['VolumeKeyProtectorID']) {
            [object[]] $ids = @($kp.VolumeKeyProtectorID)
            $result.HasRecoveryProtector = ($ids.Count -gt 0)
        }
    } catch { }

    # IsEncrypted: hay ciphertext del que preocuparse (cifrado, cifrando, o pausado)
    # O proteccion activa. Decrypting/decrypted -> no.
    [int] $conv = $result.ConversionStatus
    $result.IsEncrypted = ((@(1, 2, 4, 5) -contains $conv) -or $result.ProtectionOn)

    return $result
}

function Get-BitLockerRecoveryKey {
    <#
    .SYNOPSIS
        Lee los protectores de recovery password (tipo 3) del drive. Read-only.
        SENSIBLE: devuelve los 48 digitos en claro. NO loguear al audit.
        Devuelve [object[]] (vacio si no hay / sin permisos / no encryptable).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()] [string] $DriveLetter = 'C:')

    [object[]] $out = @()

    $vol = Get-EncryptableVolume -DriveLetter $DriveLetter
    if ($null -eq $vol) { return $out }

    [object[]] $ids = @()
    try {
        $kp = Invoke-CimMethod -InputObject $vol -MethodName 'GetKeyProtectors' `
            -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction Stop
        if ($null -ne $kp -and $null -ne $kp.PSObject.Properties['VolumeKeyProtectorID']) {
            $ids = @($kp.VolumeKeyProtectorID)
        }
    } catch { return $out }

    foreach ($id in $ids) {
        [string] $sid = [string]$id
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        try {
            $np = Invoke-CimMethod -InputObject $vol -MethodName 'GetKeyProtectorNumericalPassword' `
                -Arguments @{ VolumeKeyProtectorID = $sid } -ErrorAction Stop
            if ($null -ne $np -and $null -ne $np.PSObject.Properties['NumericalPassword']) {
                [string] $clean = $sid.Trim('{', '}')
                [string] $keyId8 = if ($clean.Length -ge 8) { $clean.Substring(0, 8).ToUpperInvariant() } else { $clean.ToUpperInvariant() }
                $out += [PSCustomObject]@{
                    KeyProtectorId   = $sid
                    KeyId8           = $keyId8
                    RecoveryPassword = [string]$np.NumericalPassword
                }
            }
        } catch { }
    }

    return $out
}

function Save-BitLockerRecoveryKey {
    <#
    .SYNOPSIS
        Guarda las claves capturadas en output\clients\<HOST>_<ts>\ (FUERA del
        ZIP [L], que solo zipea audit\ + snapshots\). Respaldo secundario; el
        primario es mostrarla en pantalla. Devuelve el path o '' si no hay claves.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Keys,
        [Parameter()] [string] $OutputRootOverride = '',
        [Parameter()] [string] $TimestampOverride  = ''
    )

    if ($null -eq $Keys -or @($Keys).Count -eq 0) { return '' }

    [string] $outputRoot = if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    } else { $OutputRootOverride }

    [string] $host_ = $env:COMPUTERNAME
    [string] $ts    = if ($TimestampOverride) { $TimestampOverride } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    [string] $dir   = Join-Path $outputRoot ('clients\{0}_{1}' -f $host_, $ts)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    [string] $file = Join-Path $dir ('bitlocker-recovery-{0}.txt' -f $host_)

    [System.Collections.Generic.List[string]] $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('CLAVE(S) DE RECUPERACION BITLOCKER - SENSIBLE')
    $lines.Add(('Equipo : {0}' -f $host_))
    $lines.Add(('Fecha  : {0}' -f $ts))
    $lines.Add('')
    $lines.Add('Guardala/fotografiala ANTES de reiniciar. NO la dejes en el ZIP del cliente.')
    $lines.Add('Se matchea por Key ID en account.microsoft.com/devices/recoverykey.')
    $lines.Add('')
    foreach ($k in $Keys) {
        $lines.Add(('Key ID  : {0}' -f $k.KeyId8))
        $lines.Add(('Clave   : {0}' -f $k.RecoveryPassword))
        $lines.Add('')
    }

    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
    return $file
}

function Start-BitLockerDecrypt {
    <#
    .SYNOPSIS
        Desactiva BitLocker (descifra el drive) via manage-bde -off. MUTANTE.
        manage-bde es exe nativo -> EAP neutralizado localmente (EAP=Stop crashea
        el toolkit con el stderr de un exe nativo; ver CLAUDE.md). Fire-and-forget:
        el descifrado sigue en segundo plano.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter()] [string] $DriveLetter = 'C:')

    $ErrorActionPreference = 'Continue'   # local: auto-revierte al return
    & manage-bde -off $DriveLetter 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return [PSCustomObject]@{ Started = $true;  ExitCode = 0;            Message = 'Descifrado iniciado en segundo plano.' }
    }
    return [PSCustomObject]@{ Started = $false; ExitCode = $LASTEXITCODE; Message = ("manage-bde -off devolvio {0}" -f $LASTEXITCODE) }
}
