Set-StrictMode -Version Latest

function Get-ToolkitHelp {
    <#
    .SYNOPSIS
        Imprime en consola el contenido de ayuda asociado a un topic del toolkit.
        Los topics disponibles se listan en el parametro Topic (tab-completion via ValidateSet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Network')]
        [string] $Topic
    )

    switch ($Topic) {
        'Network' {
            Write-Host '================================================' -ForegroundColor DarkCyan
            Write-Host '       QUE HACE CADA OPTIMIZACION DE RED?      ' -ForegroundColor Cyan
            Write-Host '================================================' -ForegroundColor DarkCyan
            Write-Host ''
            Write-Host '  [ADAPTADOR] EEE - Energy Efficient Ethernet' -ForegroundColor Yellow
            Write-Host '  El adaptador reduce su velocidad cuando detecta poco trafico para'
            Write-Host '  ahorrar energia. Esto genera micro-cortes, spikes de latencia y'
            Write-Host '  re-negociaciones de enlace visibles en gaming o videollamadas.'
            Write-Host '  Impacto: ALTO. Siempre deshabilitarlo.'
            Write-Host ''
            Write-Host '  [ADAPTADOR] Green Ethernet' -ForegroundColor Yellow
            Write-Host '  Similar a EEE pero implementado por el fabricante (ej: Realtek, Intel).'
            Write-Host '  Ajusta la potencia de transmision segun la longitud del cable detectada.'
            Write-Host '  Puede causar desconexiones intermitentes o degradar el enlace a 100Mbps.'
            Write-Host '  Impacto: MEDIO-ALTO. Recomendado deshabilitarlo.'
            Write-Host ''
            Write-Host '  [ADAPTADOR] Power Saving Mode / ULP' -ForegroundColor Yellow
            Write-Host '  Apaga parcialmente la placa cuando el sistema esta inactivo.'
            Write-Host '  Puede impedir que la PC sea alcanzable por Wake-on-LAN o provocar'
            Write-Host '  perdida de IP en redes con DHCP agresivo.'
            Write-Host '  Impacto: MEDIO. Deshabilitarlo en PCs de escritorio o gaming.'
            Write-Host ''
            Write-Host '  [GLOBAL] TCP Auto-Tuning = Normal' -ForegroundColor Yellow
            Write-Host '  Windows ajusta dinamicamente el buffer de recepcion TCP segun el'
            Write-Host '  ancho de banda disponible. "Normal" es el valor optimo para conexiones'
            Write-Host '  de fibra (300Mbps+). "Disabled" lo fija en 64KB, limitando la velocidad'
            Write-Host '  en enlaces de alta capacidad con latencia moderada.'
            Write-Host '  Impacto: ALTO en planes de alta velocidad.'
            Write-Host ''
            Write-Host '  [GLOBAL] TCP Fast Open' -ForegroundColor Yellow
            Write-Host '  Permite enviar datos en el primer paquete del handshake TCP (SYN).'
            Write-Host '  Reduce entre 1 y 2 RTTs en conexiones repetidas al mismo servidor.'
            Write-Host '  Util navegando, en APIs REST o en juegos con servidores dedicados fijos.'
            Write-Host '  Impacto: BAJO-MEDIO en latencia percibida.'
            Write-Host ''
            Write-Host '  [GLOBAL] DNS Flush (ipconfig /flushdns)' -ForegroundColor Yellow
            Write-Host '  El sistema cachea respuestas DNS para no consultar el servidor cada vez.'
            Write-Host '  Si un sitio cambio de IP o hay una entrada danada, aparece como "sin'
            Write-Host '  internet" aunque la conexion este bien. Flush borra esa cache.'
            Write-Host '  No es permanente: solo limpia el estado actual del resolver local.'
            Write-Host '  Impacto: UTIL ante errores de resolucion de nombres.'
            Write-Host ''
            Write-Host '================================================' -ForegroundColor DarkCyan
        }
    }
}
