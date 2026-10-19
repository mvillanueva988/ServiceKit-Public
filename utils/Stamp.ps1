# Stamp.ps1 -- #42: UN solo formato de fecha en los nombres que escribe PCTk.
#
# Convencion (decidida por Mateo el 2026-10-15): fecha y hora `yyyy-MM-dd_HHmm`
# (2026-10-19_1435). Con segundos (`yyyy-MM-dd_HHmmss`) SOLO donde el mismo
# productor puede escribir dos archivos en el mismo minuto y pisarse (snapshots
# PRE/POST seguidos, claves de recuperacion, prompts con otros parametros...).
# Cada sitio decide con -Seconds y lo justifica donde se llama.
#
# Nombres: minusculas, sin espacios/tildes/enie; `-` separa palabras dentro de un
# campo, `_` separa campos. El sello lleva `_` entre fecha y hora a proposito:
# la fecha es un campo y la hora otro.
#
# NADIE mas formatea fecha+hora para un nombre de archivo: el guard del smoke
# (StaticCheck 'Stamp') barre el AST de raiz/core/modules/utils/tools y falla ante
# cualquier `-Format`/`.ToString()`/`-f` con `HH` y sin `:` fuera de este archivo.
#
# TRAMPA: lo que corre dentro de Start-Job / runspace / GetNewClosure NO ve esta
# funcion. En esos sitios el sello se calcula AFUERA y viaja como argumento
# (Backup-Drivers -Stamp, Save-Snapshot -Stamp).

function Get-PctkStamp {
    <#
    .SYNOPSIS
        Sello de fecha/hora para nombres de archivo y carpetas: yyyy-MM-dd_HHmm
        (o yyyy-MM-dd_HHmmss con -Seconds). Cultura invariante.
    .PARAMETER Seconds
        Agrega los segundos. Solo donde dos archivos del mismo productor pueden
        caer en el mismo minuto.
    .PARAMETER Date
        Momento a formatear (default: ahora). Sirve para sellar con una hora ya
        capturada (p. ej. el inicio de un run) y para probar el formato exacto.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [switch]   $Seconds,
        [Parameter()] [datetime] $Date = (Get-Date)
    )

    [string] $fmt = if ($Seconds) { 'yyyy-MM-dd_HHmmss' } else { 'yyyy-MM-dd_HHmm' }
    return $Date.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
}
