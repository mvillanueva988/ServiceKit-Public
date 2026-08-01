# ═══════════════════════════════════════════════════════════════════════════════
#  CrmUpload.ps1 — el bundle del [L] viaja solo al CRM
# ═══════════════════════════════════════════════════════════════════════════════
#
#  DE DONDE SALE (backlog #41): el dolor real de Mateo, textual —
#  "siempre tengo que recurrir a abrir el wpp del cliente, abrir su mail...
#  necesito un lugar donde subirlos y no renegar". Hasta hoy el [L] dejaba el ZIP
#  en el Escritorio del cliente y de ahi en adelante lo movia el operador a mano.
#
#  LA REGLA QUE ORDENA TODO ESTE ARCHIVO: **esto NUNCA traba el cierre de un
#  service.** Sin internet, sin token, con el CRM caido o con la PC del cliente
#  detras de un proxy raro: el ZIP ya esta hecho y sigue en el Escritorio, no se
#  perdio nada, y el [L] termina igual. Cada error de aca es un aviso, jamas un
#  throw. El operador esta por AnyDesk con el cliente al lado; que el toolkit se
#  cuelgue por un problema de red seria peor que no tener esta funcion.
#
#  POR QUE NO VA A UN BACKGROUND JOB: es interactivo (pregunta y muestra el
#  resultado) y ademas dura lo que dura un POST de kilobytes. Mandarlo a un job
#  obligaria a serializar la clausura transitiva de funciones a mano, que es la
#  trampa que ya nos costo una release (el [A][5] D de v2.3.0, CommandNotFound al
#  EJECUTARSE, que el smoke no caza). No hay nada que ganar y si que perder.
#
#  DONDE VIVE EL TOKEN: en output\state\crm.json, en la PC del cliente. Eso es
#  inevitable —esa PC tiene que poder identificarse— y por eso el token del CRM
#  es de SOLO SUBIR: no lee, no lista, no borra, y tiene tope diario. Si se
#  filtra, lo peor que hace el que lo tenga es mandar basura hasta que se corte.
#  Muere con el desinstalador, junto con el resto de output\state\.
#
#  LO QUE ESTE MODULO NO HACE: no abre el ZIP, no decide de que cliente es, no
#  reintenta solo. Manda y cuenta que paso.

Set-StrictMode -Version Latest

# Tope del lado del cliente. El servidor tiene el suyo (25 MB) y contestaria 413,
# pero avisar antes de empujar los bytes da un mensaje mejor y no gasta la subida.
$script:CrmMaxBundleBytes = 25MB

# ─── Configuracion (donde esta el CRM y con que llave) ────────────────────────

function Get-CrmConfigPath {
    <#
    .SYNOPSIS
        Ruta de output\state\crm.json.

        OJO con $OutputRootOverride, misma convencion que Get-ServiceStatePath y
        Get-LastBundleMarkerPath: recibe la RAIZ DEL TOOLKIT y le agrega
        'output\state', NO la carpeta output ya armada. Pasarle un output root
        aca manda a buscar <output>\output\state\crm.json y no encuentra nunca
        nada -- que es exactamente el bug que tuvo el [U] con el service state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $OutputRootOverride = ''
    )

    [string] $root = ''
    if ([string]::IsNullOrEmpty($OutputRootOverride)) {
        $root = Split-Path -Parent $PSScriptRoot
    } else {
        $root = $OutputRootOverride
    }

    return (Join-Path $root 'output\state\crm.json')
}

function ConvertFrom-CrmConnectionString {
    <#
    .SYNOPSIS
        Parte el codigo de conexion "https://...|TOKEN" en sus dos mitades.

        POR QUE UN SOLO PEGADO Y NO DOS PREGUNTAS: esto se tipea en la PC de un
        cliente, muchas veces por AnyDesk, donde cada pegado del portapapeles es
        un viaje. Una linea = un Ctrl+V. El script del CRM (nuevo-token.ts) la
        imprime ya armada para copiar.

        Valida que la direccion sea https. No es purismo: el token viaja en una
        cabecera, y por http lo lee cualquiera que este en el medio -- que en la
        casa de un cliente puede ser el router del vecino.
    .OUTPUTS
        [PSCustomObject] con Ok, Url, Token y Error.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    [string] $raw = ''
    if ($null -ne $Text) { $raw = $Text.Trim() }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ Ok = $false; Url = ''; Token = ''; Error = 'No pegaste nada.' }
    }

    [string[]] $partes = $raw.Split('|')
    if ($partes.Count -ne 2) {
        return [PSCustomObject]@{
            Ok = $false; Url = ''; Token = ''
            Error = 'El codigo tiene que ser la direccion, una barra vertical y el token. Copialo entero, sin cortarlo.'
        }
    }

    [string] $url   = $partes[0].Trim().TrimEnd('/')
    [string] $token = $partes[1].Trim()

    if ($url -notmatch '^https://') {
        return [PSCustomObject]@{
            Ok = $false; Url = ''; Token = ''
            Error = 'La direccion tiene que empezar con https:// (por http el token viaja a la vista).'
        }
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [PSCustomObject]@{ Ok = $false; Url = ''; Token = ''; Error = 'Falta el token despues de la barra.' }
    }

    return [PSCustomObject]@{ Ok = $true; Url = $url; Token = $token; Error = '' }
}

function Get-CrmConfig {
    <#
    .SYNOPSIS
        Lee crm.json. Devuelve $null si no hay, si esta ilegible o si le falta
        algo -- los tres casos significan lo mismo para quien llama: hay que
        pedirle el codigo al operador.

        NO tira nunca: un JSON corrupto no puede impedir cerrar un service.
    .OUTPUTS
        [PSCustomObject] con Url y Token, o $null.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRootOverride = ''
    )

    [string] $path = Get-CrmConfigPath -OutputRootOverride $OutputRootOverride
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-PctkWarn '  [!] La configuracion del CRM de esta PC esta ilegible; te la vuelvo a pedir.'
        return $null
    }

    if ($null -eq $cfg) { return $null }
    if ($null -eq $cfg.PSObject.Properties['url'] -or $null -eq $cfg.PSObject.Properties['token']) { return $null }

    [string] $url   = [string]$cfg.url
    [string] $token = [string]$cfg.token
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($token)) { return $null }

    return [PSCustomObject]@{ Url = $url.TrimEnd('/'); Token = $token }
}

function Save-CrmConfig {
    <#
    .SYNOPSIS
        Guarda la direccion y el token en output\state\crm.json.
    .OUTPUTS
        [bool] $true si quedo escrito y se pudo releer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Token,
        [string] $OutputRootOverride = ''
    )

    [string] $path     = Get-CrmConfigPath -OutputRootOverride $OutputRootOverride
    [string] $stateDir = Split-Path -Parent $path

    try {
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop
        }

        $obj = [PSCustomObject]@{
            url        = $Url.TrimEnd('/')
            token      = $Token
            guardado_en = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        }
        ($obj | ConvertTo-Json -Depth 3) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop

        # Confirmacion por lectura de vuelta: escribir sin excepcion no garantiza
        # que haya quedado (disco lleno, permisos raros en la PC de un cliente).
        $check = Get-CrmConfig -OutputRootOverride $OutputRootOverride
        if ($null -eq $check -or $check.Token -ne $Token) { return $false }
        return $true
    } catch {
        Write-PctkWarn ('  [!] No pude guardar la configuracion del CRM: {0}' -f $_.Exception.Message)
        return $false
    }
}

# ─── La subida ────────────────────────────────────────────────────────────────

function Get-BundleUploadId {
    <#
    .SYNOPSIS
        El identificador que viaja en X-PCTk-Bundle-Id, derivado del nombre del ZIP.

        POR QUE DERIVADO Y NO AL AZAR: es lo que hace que reintentar sea gratis.
        El nombre del ZIP ya es unico por PC y por momento (lleva hostname y
        timestamp), asi que el MISMO paquete manda SIEMPRE el mismo id y el CRM
        contesta "ya lo tenia" en vez de guardar una segunda copia. Con un id al
        azar, decir que no y subirlo despues dejaria dos bundles iguales.

        Se limpia a lo que el CRM acepta como id (letras, numeros, punto, guion y
        guion bajo): lo que no entra en eso, el servidor lo descarta, y entonces
        dos ZIP distintos podrian terminar con el mismo id.
    .OUTPUTS
        [string] el id, o '' si el nombre no dejo nada usable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ZipPath
    )

    [string] $base = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    if ([string]::IsNullOrWhiteSpace($base)) { return '' }

    [string] $limpio = ($base -replace '[^A-Za-z0-9._-]', '-')
    $limpio = ($limpio -replace '\.{2,}', '-')
    $limpio = $limpio.Trim('-', '.')
    if ($limpio.Length -gt 80) { $limpio = $limpio.Substring(0, 80) }

    return $limpio
}

function ConvertFrom-CrmRespuesta {
    <#
    .SYNOPSIS
        Decide si lo que contesto el servidor cuenta como "el paquete llego".

        VIVE APARTE PARA PODER PROBARLA. Adentro de Send-BundleToCrm haria falta
        un servidor de mentira para ejercitar el caso que importa; aca es una
        funcion pura y el smoke le pasa las respuestas raras directo.

        LA REGLA: hace falta un 2xx **y** que el CRM lo diga con todas las letras
        (ok = true). Cualquier otra cosa que conteste 200 -- una pantalla de
        login, un portal cautivo de wifi, un proxy corporativo -- es "algo
        contesto", no "el paquete se guardo".
    .OUTPUTS
        [PSCustomObject] Confirmado, Duplicate, Key.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [int] $Code,
        [AllowEmptyString()] [string] $Cuerpo
    )

    [PSCustomObject] $r = [PSCustomObject]@{ Confirmado = $false; Duplicate = $false; Key = '' }
    if ($Code -lt 200 -or $Code -ge 300) { return $r }

    try {
        $j = $Cuerpo | ConvertFrom-Json
        if ($null -eq $j) { return $r }
        if ($null -eq $j.PSObject.Properties['ok']) { return $r }
        if (-not [bool]$j.ok) { return $r }

        $r.Confirmado = $true
        if ($null -ne $j.PSObject.Properties['duplicado']) { $r.Duplicate = [bool]$j.duplicado }
        if ($null -ne $j.PSObject.Properties['clave'])     { $r.Key       = [string]$j.clave }
    } catch {
        # No es el JSON del CRM. Confirmado queda en $false a proposito.
    }

    return $r
}

function Get-CrmMensajeDeRespuestaRara {
    <#
    .SYNOPSIS
        Traduce "el servidor contesto algo que no esperabamos" a una frase que le
        sirva a alguien que esta por AnyDesk con el cliente al lado.

        El caso que tiene nombre propio es el redirect al login: es el mas
        probable si alguien toca la configuracion del CRM, y el mas confuso,
        porque el error PARECE del toolkit cuando en realidad es del servidor.
        Decirlo con todas las letras ahorra una hora de buscar del lado que no es.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $Code,
        [AllowEmptyString()] [string] $Cuerpo
    )

    [string] $texto = ''
    if ($null -ne $Cuerpo) { $texto = $Cuerpo }

    # Lo que el CRM escribe cuando rechaza algo a proposito, ya en criollo.
    try {
        $j = $texto | ConvertFrom-Json
        if ($null -ne $j -and $null -ne $j.PSObject.Properties['error']) {
            [string] $msg = [string]$j.error
            if (-not [string]::IsNullOrWhiteSpace($msg)) { return $msg }
        }
    } catch { }

    if ($Code -ge 300 -and $Code -lt 400) {
        return 'El CRM mando a una pantalla de login en vez de aceptar el paquete: la ruta de subida quedo detras de Cloudflare Access. Es configuracion del servidor, no un problema de esta PC.'
    }
    if ($texto -match '(?i)<html') {
        return 'En vez de una respuesta del CRM llego una pagina web (una pantalla de login, un portal de wifi o un proxy en el medio). El paquete NO se subio.'
    }
    if ($Code -eq 0) {
        return 'El CRM contesto algo que no entiendo. El paquete NO se subio.'
    }
    return ('El CRM no acepto el paquete (codigo {0}).' -f $Code)
}

function Send-BundleToCrm {
    <#
    .SYNOPSIS
        Sube el ZIP. Devuelve un objeto contando que paso; NUNCA tira.

        POR QUE HttpWebRequest Y NO Invoke-WebRequest: cuando el servidor
        contesta un error, PS 5.1 tira una excepcion cuyo cuerpo de respuesta ya
        viene consumido, asi que el mensaje que el CRM se tomo el trabajo de
        escribir en criollo se pierde y queda un "403 Forbidden" pelado. Con
        HttpWebRequest el cuerpo se lee entero y el operador ve lo que pasa de
        verdad. Ademas evita la barra de progreso de Invoke-WebRequest, que en
        5.1 hace la transferencia mucho mas lenta (ya mordido en Launch.ps1).
    .OUTPUTS
        [PSCustomObject] Ok, Duplicate, Key, Message, StatusCode.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Token,
        [string] $ComputerNameOverride = '',
        [int]    $TimeoutSeconds = 120
    )

    function New-CrmResult {
        param([bool] $Ok, [string] $Message, [bool] $Duplicate = $false, [string] $Key = '', [int] $StatusCode = 0)
        return [PSCustomObject]@{
            Ok = $Ok; Duplicate = $Duplicate; Key = $Key; Message = $Message; StatusCode = $StatusCode
        }
    }

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        return (New-CrmResult -Ok $false -Message 'El paquete no esta donde deberia; no hay nada que subir.')
    }

    [byte[]] $bytes = @()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ZipPath)
    } catch {
        return (New-CrmResult -Ok $false -Message ('No pude leer el paquete: {0}' -f $_.Exception.Message))
    }

    if ($bytes.Length -eq 0) {
        return (New-CrmResult -Ok $false -Message 'El paquete quedo vacio; no lo subo.')
    }
    if ($bytes.Length -gt $script:CrmMaxBundleBytes) {
        return (New-CrmResult -Ok $false -Message (
            'El paquete pesa {0:N1} MB y el tope de subida es {1:N0} MB. Queda en esta PC: pasalo por otro medio.' -f
                ($bytes.Length / 1MB), ($script:CrmMaxBundleBytes / 1MB)))
    }

    [string] $computer = ''
    if ([string]::IsNullOrWhiteSpace($ComputerNameOverride)) {
        $computer = [string]$env:COMPUTERNAME
    } else {
        $computer = $ComputerNameOverride
    }

    [string] $bundleId = Get-BundleUploadId -ZipPath $ZipPath
    [string] $endpoint = ($Url.TrimEnd('/')) + '/api/subida/bundles'

    # TLS 1.2 explicito, igual que Launch.ps1: Windows 10 sin actualizar negocia
    # TLS 1.0 por defecto y Cloudflare no lo acepta -- la conexion se cae con un
    # error de "conexion cerrada" que no dice nada de TLS y manda a buscar el
    # problema a cualquier lado menos al correcto.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        # Si esto falla estamos en un runtime muy raro; que lo diga el pedido.
    }

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($endpoint)
        $req.Method            = 'PUT'
        $req.ContentType       = 'application/zip'
        $req.ContentLength     = $bytes.Length
        $req.Timeout           = $TimeoutSeconds * 1000
        $req.ReadWriteTimeout  = $TimeoutSeconds * 1000
        $req.UserAgent         = 'PCTk'
        # NO seguir redirecciones. Por defecto .NET las sigue solo, y eso acá es
        # peligroso: si la ruta de subida quedara detras de Cloudflare Access, el
        # 302 al login se seguiria hasta la pantalla de Cloudflare, que contesta
        # 200 con HTML -- y esto reportaria "subido" sin haber subido nada.
        # Cazado el 2026-08-01 probando contra el CRM real.
        $req.AllowAutoRedirect = $false
        $req.Headers.Add('Authorization', ('Bearer {0}' -f $Token))
        $req.Headers.Add('X-PCTk-Computer', $computer)
        if (-not [string]::IsNullOrWhiteSpace($bundleId)) {
            $req.Headers.Add('X-PCTk-Bundle-Id', $bundleId)
        }

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

        # UN 2xx NO ALCANZA PARA DECIR QUE SE SUBIO.
        #
        # Para dar la subida por buena hace falta que el CRM lo diga con todas
        # las letras: un JSON con ok = true. Cualquier otra cosa -- una pantalla
        # de login, la respuesta de un portal cautivo de wifi, el HTML de un
        # proxy corporativo -- es "algo contesto", no "el paquete llego".
        #
        # Antes esto tomaba cualquier 2xx como exito y el detalle se parseaba
        # "si se podia". Con eso, el HTML de la pantalla de Cloudflare habria
        # salido por pantalla como [OK] El paquete ya esta en el CRM. Decirle a
        # un operador que algo se guardo cuando no se guardo es peor que fallar:
        # se entera cuando va a buscar el bundle y no esta.
        $veredicto = ConvertFrom-CrmRespuesta -Code $code -Cuerpo $cuerpo
        if (-not $veredicto.Confirmado) {
            return (New-CrmResult -Ok $false -StatusCode $code -Message (Get-CrmMensajeDeRespuestaRara -Code $code -Cuerpo $cuerpo))
        }

        return (New-CrmResult -Ok $true -Duplicate $veredicto.Duplicate -Key $veredicto.Key -StatusCode $code -Message 'Subido.')
    }
    catch [System.Net.WebException] {
        $we = $_.Exception
        # Con respuesta = el servidor contesto y hay un mensaje que vale la pena.
        # Sin respuesta = no se llego (sin internet, DNS, proxy, cortafuegos).
        if ($null -ne $we.Response) {
            [int] $code = 0
            [string] $cuerpo = ''
            try {
                $code = [int]$we.Response.StatusCode
                $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                try { $cuerpo = $sr.ReadToEnd() } finally { $sr.Close() }
            } catch { }

            return (New-CrmResult -Ok $false -StatusCode $code -Message (Get-CrmMensajeDeRespuestaRara -Code $code -Cuerpo $cuerpo))
        }

        return (New-CrmResult -Ok $false -Message (
            'No pude llegar al CRM ({0}). Puede ser que esta PC no tenga internet.' -f $we.Message))
    }
    catch {
        return (New-CrmResult -Ok $false -Message ('La subida fallo: {0}' -f $_.Exception.Message))
    }
    finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch { }
        }
    }
}

# ─── El ofrecimiento que ve el operador ───────────────────────────────────────

function Invoke-CrmUploadOffer {
    <#
    .SYNOPSIS
        Despues de armar el bundle, ofrece subirlo. Es lo que llama el [L].

        NO DEVUELVE NADA QUE IMPORTE Y NUNCA TIRA. Quien la llama esta cerrando
        un service; pase lo que pase aca, el ZIP esta hecho y el cierre sigue.

        En consola no interactiva (headless, un gate automatizado) se saltea sin
        preguntar: un Read-Host ahi colgaria el proceso esperando a nadie.
    .OUTPUTS
        [PSCustomObject] con lo que paso -- para los tests y el audit, no para
        decidir nada del cierre.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [string] $OutputRootOverride = ''
    )

    [PSCustomObject] $salida = [PSCustomObject]@{ Intentado = $false; Ok = $false; Motivo = '' }

    try {
        if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            $salida.Motivo = 'sin-zip'
            return $salida
        }

        if (Get-Command -Name 'Test-PctkInteractiveConsole' -CommandType Function -ErrorAction SilentlyContinue) {
            if (-not (Test-PctkInteractiveConsole)) {
                $salida.Motivo = 'no-interactiva'
                return $salida
            }
        }

        Write-Host ''
        [string] $ans = (Read-Host '  Subir el paquete al CRM? [S/n]').Trim().ToUpperInvariant()
        if ($ans -eq 'N') {
            $salida.Motivo = 'el-operador-dijo-que-no'
            Write-PctkHint '  Listo. El paquete queda en el Escritorio de esta PC.'
            return $salida
        }

        $cfg = Get-CrmConfig -OutputRootOverride $OutputRootOverride
        if ($null -eq $cfg) {
            Write-Host ''
            Write-PctkHint '  Esta PC todavia no tiene la conexion al CRM. Pega el codigo (una sola vez).'
            Write-PctkHint '  Sale del CRM con: node scripts/nuevo-token.ts "nombre de esta PC"'
            [string] $codigo = Read-Host '  Codigo de conexion (Enter para saltear)'

            if ([string]::IsNullOrWhiteSpace($codigo)) {
                $salida.Motivo = 'sin-configurar'
                Write-PctkHint '  Sin problema: el paquete queda en el Escritorio de esta PC.'
                return $salida
            }

            $parsed = ConvertFrom-CrmConnectionString -Text $codigo
            if (-not $parsed.Ok) {
                $salida.Motivo = 'codigo-invalido'
                Write-PctkWarn ('  [!] {0}' -f $parsed.Error)
                Write-PctkHint '  El paquete queda en el Escritorio de esta PC.'
                return $salida
            }

            if (-not (Save-CrmConfig -Url $parsed.Url -Token $parsed.Token -OutputRootOverride $OutputRootOverride)) {
                $salida.Motivo = 'no-se-pudo-guardar'
                Write-PctkWarn '  [!] No pude guardar la conexion; el paquete queda en el Escritorio.'
                return $salida
            }

            Write-PctkOk '  [OK] Conexion guardada. Queda en esta PC hasta que desinstales PCTk.'
            $cfg = [PSCustomObject]@{ Url = $parsed.Url; Token = $parsed.Token }
        }

        $salida.Intentado = $true
        Write-PctkWork '  Subiendo el paquete al CRM...'
        $r = Send-BundleToCrm -ZipPath $ZipPath -Url $cfg.Url -Token $cfg.Token

        if ($r.Ok) {
            $salida.Ok = $true
            if ($r.Duplicate) {
                Write-PctkOk '  [OK] Ya estaba subido (no se duplico).'
            } else {
                Write-PctkOk '  [OK] El paquete ya esta en el CRM.'
            }
            Write-ActionAudit -Action 'Crm.Upload' -Status 'Success' -Summary ([string]$r.Key)
        } else {
            $salida.Motivo = 'fallo'
            Write-PctkWarn ('  [!] {0}' -f $r.Message)
            Write-PctkHint '  El paquete quedo en el Escritorio de esta PC: no se perdio nada.'
            Write-ActionAudit -Action 'Crm.Upload' -Status 'Failed' -Summary ([string]$r.Message)
        }
    }
    catch {
        # Ultima red. Si algo imprevisto se rompio, el cierre del service sigue.
        $salida.Motivo = 'excepcion'
        try { Write-PctkWarn ('  [!] La subida al CRM fallo: {0}' -f $_.Exception.Message) } catch { }
    }

    return $salida
}
