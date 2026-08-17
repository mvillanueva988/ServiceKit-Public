# ═══════════════════════════════════════════════════════════════════════════════
#  VaultUpload.ps1 — la clave de BitLocker viaja sola a la boveda del CRM
# ═══════════════════════════════════════════════════════════════════════════════
#
#  DE DONDE SALE (fase 3b del CRM, entrega 2; cierra el backlog #41 (b)): la
#  clave de recuperacion capturada en [A][18][C] quedaba SOLO en dos lugares
#  fragiles — la pantalla (foto del operador) y output\recovery\ de la PC del
#  cliente, que el desinstalador borra. La boveda del CRM es la copia que
#  sobrevive: cifrada de punta a punta, depositada desde la PC del cliente con
#  el mismo token write-only de los bundles.
#
#  LA REGLA DE ORO: **el secreto se cifra ANTES de salir de esta PC.** El CRM
#  recibe un sobre RSA-OAEP cerrado con la clave publica de la boveda
#  (data\vault-publica.json) y NO puede abrirlo: la privada esta cifrada con la
#  passphrase de Mateo, que no viaja nunca. Si un bug mandara la clave en
#  claro, el servidor la RECHAZA por forma (un sobre RSA-2048 mide exacto 344
#  caracteres en base64).
#
#  DOS TRAMPAS MEDIDAS (2026-08-07, el plan las trae verificadas):
#  · [RSA]::Create() SIN argumento devuelve RSACryptoServiceProvider (legacy),
#    que NO soporta OAEP-SHA256. Hay que instanciar RSACng explicito.
#  · ExportSubjectPublicKeyInfo no existe en .NET Framework: el puente con el
#    navegador es JWK ({n, e} en base64url) importado via ImportParameters.
#
#  MISMA REGLA QUE CrmUpload: esto NUNCA traba el cierre de un service. La
#  boveda es una copia MAS, no un reemplazo — output\recovery\ y la pantalla
#  siguen exactamente igual. Cada error de aca es un aviso, jamas un throw.

Set-StrictMode -Version Latest

# Tope de RSA-2048 con OAEP-SHA256, medido: 190 bytes. Una clave de BitLocker
# son 55; una password de AnyDesk, veintipico. Si algun dia hace falta guardar
# algo mas largo, el camino es cifrado hibrido (AES + RSA), no truncar aca.
$script:VaultMaxSecretBytes = 190

# ─── La clave publica de la boveda ───────────────────────────────────────────

function Get-VaultPublicaPath {
    <#
    .SYNOPSIS
        Ruta de data\vault-publica.json (viaja versionada con el toolkit).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $RootOverride = ''
    )

    [string] $root = ''
    if ([string]::IsNullOrEmpty($RootOverride)) {
        $root = Split-Path -Parent $PSScriptRoot
    } else {
        $root = $RootOverride
    }

    return (Join-Path $root 'data\vault-publica.json')
}

function Get-VaultPublica {
    <#
    .SYNOPSIS
        Lee la clave publica de la boveda. Devuelve $null si no esta, esta
        ilegible o esta vacia (el archivo se shippea con los campos en blanco
        hasta que se pega la publica real de la boveda del CRM).

        NO tira nunca: sin publica no hay deposito, pero el service sigue.
    .OUTPUTS
        [PSCustomObject] con n y e (base64url), o $null.
    #>
    [CmdletBinding()]
    param(
        [string] $RootOverride = ''
    )

    [string] $path = Get-VaultPublicaPath -RootOverride $RootOverride
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        $jwk = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }

    if ($null -eq $jwk) { return $null }
    foreach ($campo in @('kty', 'n', 'e')) {
        if ($null -eq $jwk.PSObject.Properties[$campo]) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$jwk.$campo)) { return $null }
    }
    if ([string]$jwk.kty -ne 'RSA') { return $null }

    return [PSCustomObject]@{ n = [string]$jwk.n; e = [string]$jwk.e }
}

# ─── El cifrado ──────────────────────────────────────────────────────────────

function ConvertFrom-PctkBase64Url {
    <#
    .SYNOPSIS
        base64url (el alfabeto de JWK: -_ y sin relleno) -> bytes.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    [string] $b64 = $Text.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += '==' }
        3 { $b64 += '=' }
    }
    return , ([Convert]::FromBase64String($b64))
}

function Protect-PctkSecret {
    <#
    .SYNOPSIS
        Cierra el sobre: RSA-OAEP-SHA256 con la publica de la boveda.

        RSACng EXPLICITO, no [RSA]::Create() pelado: el default en PS5.1 es el
        proveedor legacy y tira "el modo de relleno especificado no es valido"
        recien al ejecutar. La publica entra como JWK (n y e en base64url),
        que es lo que exporta el navegador que creo la boveda.

        TIRA si el secreto no entra en un sobre RSA-2048 (190 bytes): guardar
        un secreto CORTADO seria descubrirlo el dia que hace falta, que con
        una clave de recuperacion es el peor dia posible. El que llama decide
        que hacer con el error; esta funcion no trunca jamas.
    .OUTPUTS
        [string] el sobre en base64 (344 caracteres).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Secret,
        [Parameter(Mandatory)] [PSCustomObject] $Publica
    )

    [byte[]] $bytes = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    if ($bytes.Length -eq 0) {
        throw 'No hay nada que cifrar: el secreto vino vacio.'
    }
    if ($bytes.Length -gt $script:VaultMaxSecretBytes) {
        throw ('El secreto mide {0} bytes y en un sobre RSA-2048 entran {1}. No lo corto: un secreto guardado cortado es peor que no guardarlo.' -f
            $bytes.Length, $script:VaultMaxSecretBytes)
    }

    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = ConvertFrom-PctkBase64Url -Text ([string]$Publica.n)
    $params.Exponent = ConvertFrom-PctkBase64Url -Text ([string]$Publica.e)

    $rsa = New-Object System.Security.Cryptography.RSACng
    try {
        $rsa.ImportParameters($params)
        [byte[]] $cifrado = $rsa.Encrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        return [Convert]::ToBase64String($cifrado)
    } finally {
        $rsa.Dispose()
    }
}

# ─── El envio ────────────────────────────────────────────────────────────────

function Send-VaultSecretToCrm {
    <#
    .SYNOPSIS
        Deposita UN sobre ya cerrado en PUT /api/subida/boveda. NUNCA tira.

        Mismo transporte que Send-BundleToCrm (HttpWebRequest, TLS 1.2, sin
        seguir redirecciones) y mismo veredicto: un 2xx NO alcanza, el CRM
        tiene que decir ok = true con todas las letras. El parseo de la
        respuesta y los mensajes raros se REUSAN de CrmUpload.ps1 — dos
        definiciones de "esto conto como subido" divergirian en silencio.
    .OUTPUTS
        [PSCustomObject] Ok, Duplicate, Message, StatusCode.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $Tipo,
        [Parameter(Mandatory)] [string] $SobreB64,
        [string] $Etiqueta = '',
        [string] $ComputerNameOverride = '',
        [int]    $TimeoutSeconds = 60
    )

    function New-VaultResult {
        param([bool] $Ok, [string] $Message, [bool] $Duplicate = $false, [int] $StatusCode = 0)
        return [PSCustomObject]@{ Ok = $Ok; Duplicate = $Duplicate; Message = $Message; StatusCode = $StatusCode }
    }

    [string] $computer = ''
    if ([string]::IsNullOrWhiteSpace($ComputerNameOverride)) {
        $computer = [string]$env:COMPUTERNAME
    } else {
        $computer = $ComputerNameOverride
    }

    $cuerpoObj = [PSCustomObject]@{
        tipo          = $Tipo
        computer_name = $computer
        etiqueta      = $Etiqueta
        sobre_b64     = $SobreB64
    }
    [byte[]] $bytes = [System.Text.Encoding]::UTF8.GetBytes(($cuerpoObj | ConvertTo-Json -Compress))

    [string] $endpoint = ($Url.TrimEnd('/')) + '/api/subida/boveda'

    # TLS 1.2 explicito, misma razon que Send-BundleToCrm: un Win10 sin
    # actualizar negocia TLS 1.0 y Cloudflare lo rechaza con un error mudo.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($endpoint)
        $req.Method            = 'PUT'
        $req.ContentType       = 'application/json'
        $req.ContentLength     = $bytes.Length
        $req.Timeout           = $TimeoutSeconds * 1000
        $req.ReadWriteTimeout  = $TimeoutSeconds * 1000
        $req.UserAgent         = 'PCTk'
        # NO seguir redirecciones: si la ruta quedara detras de Access, el 302
        # al login contestaria 200 con HTML y esto reportaria "depositado" sin
        # haber depositado nada (misma leccion que la subida de bundles).
        $req.AllowAutoRedirect = $false
        $req.Headers.Add('Authorization', ('Bearer {0}' -f $Token))

        $reqStream = $req.GetRequestStream()
        try {
            $reqStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $reqStream.Close()
        }

        $resp = $req.GetResponse()
        [int] $code = [int]$resp.StatusCode
        [string] $cuerpo = ''
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        try { $cuerpo = $sr.ReadToEnd() } finally { $sr.Close() }

        $veredicto = ConvertFrom-CrmRespuesta -Code $code -Cuerpo $cuerpo
        if (-not $veredicto.Confirmado) {
            return (New-VaultResult -Ok $false -StatusCode $code -Message (Get-CrmMensajeDeRespuestaRara -Code $code -Cuerpo $cuerpo))
        }

        return (New-VaultResult -Ok $true -Duplicate $veredicto.Duplicate -StatusCode $code -Message 'Depositado.')
    }
    catch [System.Net.WebException] {
        $we = $_.Exception
        if ($null -ne $we.Response) {
            [int] $code = 0
            [string] $cuerpo = ''
            try {
                $code = [int]$we.Response.StatusCode
                $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                try { $cuerpo = $sr.ReadToEnd() } finally { $sr.Close() }
            } catch { }

            return (New-VaultResult -Ok $false -StatusCode $code -Message (Get-CrmMensajeDeRespuestaRara -Code $code -Cuerpo $cuerpo))
        }

        return (New-VaultResult -Ok $false -Message (
            'No pude llegar al CRM ({0}). Puede ser que esta PC no tenga internet.' -f $we.Message))
    }
    catch {
        return (New-VaultResult -Ok $false -Message ('El deposito fallo: {0}' -f $_.Exception.Message))
    }
    finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch { }
        }
    }
}

# ─── El ofrecimiento que ve el operador ──────────────────────────────────────

function Invoke-VaultDepositOffer {
    <#
    .SYNOPSIS
        Despues de capturar la(s) clave(s) en [A][18][C], ofrece depositarlas
        en la boveda del CRM. NUNCA tira; si algo falla, la clave sigue en la
        pantalla y en output\recovery\, que es lo que ya habia.

        En consola no interactiva se saltea sin preguntar (un Read-Host en un
        gate automatizado cuelga el proceso esperando a nadie).
    .OUTPUTS
        [PSCustomObject] Intentado, Ok, Motivo, Depositados — para los tests y
        el audit, no para decidir nada del cierre.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Keys,
        [string] $OutputRootOverride = ''
    )

    [PSCustomObject] $salida = [PSCustomObject]@{ Intentado = $false; Ok = $false; Motivo = ''; Depositados = 0 }

    try {
        if ($null -eq $Keys -or @($Keys).Count -eq 0) {
            $salida.Motivo = 'sin-claves'
            return $salida
        }

        if (Get-Command -Name 'Test-PctkInteractiveConsole' -CommandType Function -ErrorAction SilentlyContinue) {
            if (-not (Test-PctkInteractiveConsole)) {
                $salida.Motivo = 'no-interactiva'
                return $salida
            }
        }

        $publica = Get-VaultPublica
        if ($null -eq $publica) {
            # Sin publica no hay boveda que ofrecer. No es un error de esta PC:
            # es un toolkit al que todavia no se le cargo data\vault-publica.json.
            $salida.Motivo = 'sin-publica'
            return $salida
        }

        Write-Host ''
        [string] $ans = (Read-Host '  Depositar la clave en la boveda del CRM? [S/n]').Trim().ToUpperInvariant()
        if ($ans -eq 'N') {
            $salida.Motivo = 'el-operador-dijo-que-no'
            Write-PctkHint '  Listo. La clave queda en pantalla y en output\recovery\ de esta PC.'
            return $salida
        }

        $cfg = Get-CrmConfig -OutputRootOverride $OutputRootOverride
        if ($null -eq $cfg) {
            # El MISMO codigo de conexion que usa la subida de bundles: parsear
            # y guardar viven en CrmUpload.ps1, aca solo esta la pregunta.
            Write-Host ''
            Write-PctkHint '  Esta PC todavia no tiene la conexion al CRM. Pega el codigo (una sola vez).'
            Write-PctkHint '  Sale del CRM con: node scripts/nuevo-token.ts "nombre de esta PC"'
            [string] $codigo = Read-Host '  Codigo de conexion (Enter para saltear)'

            if ([string]::IsNullOrWhiteSpace($codigo)) {
                $salida.Motivo = 'sin-configurar'
                Write-PctkHint '  Sin problema: la clave queda en pantalla y en output\recovery\.'
                return $salida
            }

            $parsed = ConvertFrom-CrmConnectionString -Text $codigo
            if (-not $parsed.Ok) {
                $salida.Motivo = 'codigo-invalido'
                Write-PctkWarn ('  [!] {0}' -f $parsed.Error)
                Write-PctkHint '  La clave queda en pantalla y en output\recovery\.'
                return $salida
            }

            if (-not (Save-CrmConfig -Url $parsed.Url -Token $parsed.Token -OutputRootOverride $OutputRootOverride)) {
                $salida.Motivo = 'no-se-pudo-guardar'
                Write-PctkWarn '  [!] No pude guardar la conexion; la clave queda en pantalla y en output\recovery\.'
                return $salida
            }

            Write-PctkOk '  [OK] Conexion guardada. Queda en esta PC hasta que desinstales PCTk.'
            $cfg = [PSCustomObject]@{ Url = $parsed.Url; Token = $parsed.Token }
        }

        $salida.Intentado = $true
        [int] $depositadas = 0
        [int] $fallidas = 0

        foreach ($k in @($Keys)) {
            [string] $keyId = ''
            if ($null -ne $k.PSObject.Properties['KeyId8']) { $keyId = [string]$k.KeyId8 }

            [string] $sobre = ''
            try {
                $sobre = Protect-PctkSecret -Secret ([string]$k.RecoveryPassword) -Publica $publica
            } catch {
                $fallidas++
                Write-PctkWarn ('  [!] No pude cerrar el sobre de {0}: {1}' -f $keyId, $_.Exception.Message)
                continue
            }

            Write-PctkWork ('  Depositando la clave {0} en la boveda...' -f $keyId)
            $r = Send-VaultSecretToCrm -Url $cfg.Url -Token $cfg.Token -Tipo 'bitlocker_recovery' `
                -SobreB64 $sobre -Etiqueta ('BitLocker {0}' -f $keyId)

            if ($r.Ok) {
                $depositadas++
                if ($r.Duplicate) {
                    Write-PctkOk '  [OK] Ya estaba depositada (no se duplico).'
                } else {
                    Write-PctkOk '  [OK] Depositada. Se abre desde la ficha del cliente, con la passphrase.'
                }
            } else {
                $fallidas++
                Write-PctkWarn ('  [!] {0}' -f $r.Message)
            }
        }

        $salida.Depositados = $depositadas
        $salida.Ok = ($depositadas -gt 0 -and $fallidas -eq 0)

        if ($fallidas -gt 0) {
            $salida.Motivo = 'fallo'
            Write-PctkHint '  La clave sigue en pantalla y en output\recovery\ de esta PC: no se perdio nada.'
        }

        # Al audit va CUANTAS y CUALES por Key ID -- jamas la clave. El Key ID
        # es el identificador publico que muestra account.microsoft.com.
        [string] $ids = (@($Keys) | ForEach-Object {
            if ($null -ne $_.PSObject.Properties['KeyId8']) { [string]$_.KeyId8 } }) -join ', '
        if ($salida.Ok) {
            Write-ActionAudit -Action 'Vault.Deposit' -Status 'Success' -Summary ('{0} sobre(s): {1}' -f $depositadas, $ids)
        } else {
            Write-ActionAudit -Action 'Vault.Deposit' -Status 'Failed' -Summary ('{0} ok, {1} fallida(s): {2}' -f $depositadas, $fallidas, $ids)
        }
    }
    catch {
        # Ultima red. Pase lo que pase aca, el service sigue.
        $salida.Motivo = 'excepcion'
        try { Write-PctkWarn ('  [!] El deposito en la boveda fallo: {0}' -f $_.Exception.Message) } catch { }
    }

    return $salida
}
