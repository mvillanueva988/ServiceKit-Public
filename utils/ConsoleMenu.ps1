Set-StrictMode -Version Latest

function Get-MainMenuSpec {
    <#
    .SYNOPSIS
        El menu principal como DATOS (#72): de esta tabla salen las filas que
        dibuja Read-PctkMenuChoice (ConvertTo-PctkMenuRows) y el despacho
        (Invoke-MainMenuDispatch). Cambiar un boton es cambiar una entrada aca.

    .DESCRIPTION
        Entradas, en el orden en que se ven:
        - Seccion   : @{ Tipo = 'Seccion'; Texto } (la sangria la pone el formateador).
        - Separador : @{ Tipo = 'Separador' }.
        - Columna   : @{ Tipo = 'Columna' } (#72 paso 4): lo que sigue va en la
                      columna derecha cuando la ventana tiene ancho >= 100. Con
                      menos ancho (o sin esta entrada) el menu va en una columna.
        - Opcion    : @{ Tipo = 'Opcion'; Tecla; Texto; Aclaracion; Color; Salida; Accion }
            Aclaracion : va entre parentesis, alineada sola a AnchoTexto. $null = sin.
            Color      : nombre 16-color de la fila ($null = el de siempre).
            Salida     : que hace el menu despues de la accion.
                         'Pausa'         -> pide [Enter] y vuelve al menu.
                         'Termina'       -> el menu devuelve 'X' (salir), sin pausa.
                         'TerminaSiTrue' -> si la accion devuelve $true el menu devuelve
                                            'U' (PCTk se cierra para que el deleter
                                            pueda borrar la instalacion); si no, pausa.
            Accion     : scriptblock LITERAL que recibe el MachineProfile. Nunca
                         .GetNewClosure(): ata el bloque a un modulo que solo ve
                         funciones globales (rompe con '& main.ps1' y con las sombras
                         de los tests, que resuelven por la pila).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    [object[]] $entradas = @(
        @{ Tipo = 'Seccion'; Texto = 'PERFILES' }
        @{ Tipo = 'Opcion'; Tecla = '1'; Texto = 'Aplicar perfil automatico'; Aclaracion = 'Generic/Work/Multimedia'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ApplyAutoProfile -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '2'; Texto = 'Receta nombrada'; Aclaracion = 'cliente especifico'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-NamedProfileMenu -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Seccion'; Texto = 'DIAGNOSTICO' }
        @{ Tipo = 'Opcion'; Tecla = '3'; Texto = 'Snapshot PRE-service'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-DiagnosticSnapshot -Phase Pre -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '4'; Texto = 'Snapshot POST-service'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-DiagnosticSnapshot -Phase Post -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '5'; Texto = 'Comparar PRE vs POST'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-DiagnosticCompare -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '6'; Texto = 'Historial de BSOD / Crashes'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-DiagnosticBsod -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '7'; Texto = 'Salud de discos (SMART / wear)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-DiagnosticDiskHealth -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '8'; Texto = 'Reporte para el cliente'; Aclaracion = 'HTML para mostrar/imprimir'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ClientReport -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = 'R'; Texto = 'Generar prompt de research'; Aclaracion = 'para LLM con web search'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ResearchPrompt -MachineProfile $MachineProfile } }
        # #90 (4): medicion de FPS en CS2 (modules\MedicionFps.ps1). Solo a pedido
        # del operador: nunca corre dentro del [1].
        @{ Tipo = 'Opcion'; Tecla = 'F'; Texto = 'Medir FPS en CS2'; Aclaracion = 'PresentMon, A/B base-variante-base'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-FpsMeasurement -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        # #72 paso 4: en dos columnas, ACCIONES MANUALES y HERRAMIENTAS van a la derecha.
        @{ Tipo = 'Columna' }
        @{ Tipo = 'Seccion'; Texto = 'ACCIONES MANUALES' }
        @{ Tipo = 'Opcion'; Tecla = 'A'; Texto = 'Submenu: acciones individuales'; Aclaracion = 'debloat, limpieza, rendimiento, privacidad, etc.'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Show-IndividualActionsSubmenu -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Seccion'; Texto = 'HERRAMIENTAS' }
        @{ Tipo = 'Opcion'; Tecla = 'T'; Texto = 'Herramientas externas'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Show-ToolsMenu -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = 'I'; Texto = 'Informe tecnico del equipo'; Aclaracion = '.txt legible para leer/mandar'; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-RawAuditReport -MachineProfile $MachineProfile } }
        # [L] = cerrar service (POST auto + meta.json + ZIP) y ofrecer desinstalar.
        # Puede terminar en desinstalacion: por eso TerminaSiTrue, igual que el [U].
        @{ Tipo = 'Opcion'; Tecla = 'L'; Texto = 'Cerrar service y llevarse el paquete'; Aclaracion = 'POST + ZIP'; Color = $null; Salida = 'TerminaSiTrue'
           Accion = { param($MachineProfile) Invoke-ServiceClose } }
        @{ Tipo = 'Opcion'; Tecla = 'X'; Texto = 'Salir'; Aclaracion = $null; Color = $null; Salida = 'Termina'
           Accion = { param($MachineProfile) Write-PctkWork '  Saliendo de PCTk v2...' } }
        @{ Tipo = 'Opcion'; Tecla = 'U'; Texto = 'Desinstalar PCTk de esta PC (borra todo)'; Aclaracion = $null; Color = 'DarkRed'; Salida = 'TerminaSiTrue'
           Accion = { param($MachineProfile) Invoke-UninstallToolkit } }
        @{ Tipo = 'Separador' }
    )
    return [PSCustomObject]@{ AnchoTexto = 34; Entradas = $entradas }
}

function Get-IndividualActionSpec {
    <#
    .SYNOPSIS
        El submenu [A] (acciones individuales) como DATOS (#72), misma forma que
        Get-MainMenuSpec: de aca salen las filas (ConvertTo-PctkMenuRows) y el
        despacho (Show-IndividualActionsSubmenu / Invoke-IndividualActionDispatch).
    .DESCRIPTION
        Sin columna de aclaracion: lo que va entre parentesis es parte del Texto.
        Salida de las acciones = 'Pausa' (pide [Enter] y vuelve al submenu);
        'Vuelve' = el submenu termina y se vuelve al menu principal, sin Accion.
        Oculta = $true: la tecla funciona pero no se dibuja (la X vuelve, como
        siempre, sin estar en la lista).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    [object[]] $entradas = @(
        @{ Tipo = 'Seccion'; Texto = 'ACCIONES INDIVIDUALES' }
        @{ Tipo = 'Opcion'; Tecla = '1'; Texto = 'Debloat de Servicios'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionDebloat -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '2'; Texto = 'Limpieza de Disco'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionCleanup -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '3'; Texto = 'Mantenimiento del Sistema (DISM + SFC)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionMaintenance -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '4'; Texto = 'Crear Punto de Restauracion'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionRestorePoint -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '5'; Texto = 'Optimizar Red'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionNetwork -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '6'; Texto = 'Rendimiento (visuales + power plan + tweaks)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionPerformance -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '7'; Texto = 'Backup de Drivers'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionDriverBackup -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '8'; Texto = 'Apps Win32 + UWP'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionApps -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '9'; Texto = 'Privacidad (registry o OOSU10)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionPrivacy -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '10'; Texto = 'Inicio del Sistema'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionStartup -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '11'; Texto = 'Actualizaciones de Windows'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionWindowsUpdate -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        # #72 paso 4: el corte que mas parejas deja las columnas (12 filas a la
        # izquierda y 14 a la derecha, sin separadores).
        @{ Tipo = 'Columna' }
        @{ Tipo = 'Seccion'; Texto = 'GAMING / LATENCIA  (avanzado - reinicio salvo USB)' }
        @{ Tipo = 'Opcion'; Tecla = '12'; Texto = 'Core Isolation / Memory Integrity (HVCI)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionCoreIsolation -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '13'; Texto = 'HAGS (GPU Scheduling por hardware)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionHags -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '14'; Texto = 'Timer Resolution global (solo Win11)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionTimerResolution -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '15'; Texto = 'Prioridad de proceso por .exe (IFEO)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionProcessPriority -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '16'; Texto = 'USB Selective Suspend'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionUsbPower -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Seccion'; Texto = 'DISCO' }
        @{ Tipo = 'Opcion'; Tecla = '17'; Texto = 'Mantenimiento de discos (TRIM SSD / defrag HDD)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionDiskMaintenance -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Seccion'; Texto = 'SEGURIDAD' }
        @{ Tipo = 'Opcion'; Tecla = '18'; Texto = 'Encriptacion de disco (BitLocker)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionEncryption -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Seccion'; Texto = 'RENDIMIENTO' }
        @{ Tipo = 'Opcion'; Tecla = '19'; Texto = 'Defender: reagendar escaneo + exclusiones (dev/WSL)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionDefenderScan -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '20'; Texto = 'Energia: PERFBOOSTMODE + laptop gaming (por PC)'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-ActionEnergyLaptop -MachineProfile $MachineProfile } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Opcion'; Tecla = 'B'; Texto = 'Volver al menu principal'; Aclaracion = $null; Color = 'DarkYellow'; Salida = 'Vuelve'; Accion = $null }
        # X tambien vuelve, sin estar dibujada: asi fue siempre (es la tecla de salir del principal).
        @{ Tipo = 'Opcion'; Tecla = 'X'; Texto = 'Volver al menu principal'; Aclaracion = $null; Color = $null; Salida = 'Vuelve'; Accion = $null; Oculta = $true }
        @{ Tipo = 'Separador' }
    )
    return [PSCustomObject]@{ AnchoTexto = 0; Entradas = $entradas }
}

function Get-NamedProfileSpec {
    <#
    .SYNOPSIS
        El submenu [2] (receta nombrada) como DATOS (#72), misma forma que
        Get-MainMenuSpec: de aca salen las filas y el despacho de
        Invoke-NamedProfileMenu.
    .DESCRIPTION
        De un solo disparo: la opcion corre y el submenu termina. La pausa la pone
        el menu principal ([2] tiene Salida = 'Pausa' alla), por eso las opciones
        dicen 'Pausa'. 'Vuelve' = termina sin correr nada.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    [object[]] $entradas = @(
        @{ Tipo = 'Seccion'; Texto = 'RECETA NOMBRADA (gaming personalizado)' }
        @{ Tipo = 'Opcion'; Tecla = '1'; Texto = 'Nueva'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-NamedProfileNew -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '2'; Texto = 'Cargar existente'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-NamedProfileLoad -MachineProfile $MachineProfile } }
        @{ Tipo = 'Opcion'; Tecla = '3'; Texto = 'Reaplicar ultima'; Aclaracion = $null; Color = $null; Salida = 'Pausa'
           Accion = { param($MachineProfile) Invoke-NamedProfileLoad -MachineProfile $MachineProfile -Reapply } }
        @{ Tipo = 'Separador' }
        @{ Tipo = 'Opcion'; Tecla = 'B'; Texto = 'Volver'; Aclaracion = $null; Color = 'DarkYellow'; Salida = 'Vuelve'; Accion = $null }
        @{ Tipo = 'Separador' }
    )
    return [PSCustomObject]@{ AnchoTexto = 0; Entradas = $entradas }
}

function Get-PctkMenuEntry {
    <#
    .SYNOPSIS
        La busqueda de entrada de los menus (#72): la entrada Opcion de una tabla
        (Get-MainMenuSpec, Get-IndividualActionSpec, Get-NamedProfileSpec) para una
        tecla, sin importar mayusculas/minusculas. Encuentra tambien las Oculta.
        $null si la tecla no esta en la tabla.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [object] $Spec,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Choice
    )
    foreach ($e in @($Spec.Entradas)) {
        if ($e.Tipo -eq 'Opcion' -and [string]::Equals([string]$e.Tecla, $Choice, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $e
        }
    }
    return $null
}

function Get-MainMenuEntry {
    <#
    .SYNOPSIS
        Get-PctkMenuEntry sobre la tabla del menu principal (o sobre -Spec).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Choice,
        [object] $Spec = $null
    )
    if ($null -eq $Spec) { $Spec = Get-MainMenuSpec }
    return (Get-PctkMenuEntry -Spec $Spec -Choice $Choice)
}

function ConvertTo-PctkMenuRows {
    <#
    .SYNOPSIS
        Arma desde una tabla de menu (Get-MainMenuSpec, Get-IndividualActionSpec,
        Get-NamedProfileSpec) las filas Kind/Key/Label/Color que consume
        Read-PctkMenuChoice.
    .DESCRIPTION
        La tecla va en un campo de ancho fijo: '[1]' lleva 2 espacios antes del
        texto y '[10]' uno, asi las teclas de 1 y 2 caracteres quedan alineadas.
        Alinea la aclaracion sola: Texto rellenado a AnchoTexto, y si el texto
        llega o pasa el ancho, 2 espacios; la aclaracion va entre parentesis. Sin
        aclaracion, la fila termina en el texto (sin relleno). Las entradas
        Oculta no se dibujan (la tecla igual la encuentra Get-PctkMenuEntry).

        #72 paso 4 (dos columnas): cada fila lleva tambien LabelCorto (la fila sin
        la aclaracion), Aclaracion (el texto solo, $null = sin) y Columna ($true en
        la primera fila despues de una entrada Tipo = 'Columna': ahi arranca la
        columna derecha). Label queda como siempre: es el de una columna y el del
        render plano.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object] $Spec)
    [int] $ancho = [int] $Spec.AnchoTexto
    [int] $anchoTecla = 4   # el campo de la tecla ('[10]'), sin el espacio que lo separa del texto
    [object[]] $rows = @()
    [bool] $corte = $false        # hubo una entrada Columna y todavia no salio la fila que la lleva
    [bool] $huboCorte = $false
    foreach ($e in @($Spec.Entradas)) {
        [object] $row = $null
        switch ([string] $e.Tipo) {
            'Seccion' {
                [string] $hl = '  ' + [string]$e.Texto
                $row = [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = $hl; Color = 'DarkCyan'; LabelCorto = $hl; Aclaracion = $null; Columna = $false }
            }
            'Separador' {
                $row = [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null; LabelCorto = ''; Aclaracion = $null; Columna = $false }
            }
            'Columna' {
                if ($huboCorte) { throw 'ConvertTo-PctkMenuRows: la tabla tiene mas de un corte de columna' }
                $corte = $true
                $huboCorte = $true
            }
            'Opcion' {
                # Indexador y no .Oculta: con StrictMode, la clave ausente (la gran
                # mayoria de las entradas) tira por propiedad; el indexador da $null.
                if (-not $e['Oculta']) {
                    [string] $texto = [string] $e.Texto
                    [string] $corto = '  ' + ('[' + [string]$e.Tecla + ']').PadRight($anchoTecla) + ' ' + $texto
                    [string] $label = $corto
                    [object] $acl = $null
                    if (-not [string]::IsNullOrEmpty([string]$e.Aclaracion)) {
                        $acl = [string] $e.Aclaracion
                        [int] $relleno = 2
                        if ($texto.Length -lt $ancho) { $relleno = $ancho - $texto.Length }
                        $label = $label + (' ' * $relleno) + '(' + [string]$e.Aclaracion + ')'
                    }
                    $row = [PSCustomObject]@{ Kind = 'Item'; Key = [string]$e.Tecla; Label = $label; Color = $e.Color; LabelCorto = $corto; Aclaracion = $acl; Columna = $false }
                }
            }
            default { throw ("ConvertTo-PctkMenuRows: tipo de entrada desconocido '{0}'" -f [string]$e.Tipo) }
        }
        if ($null -ne $row) {
            if ($corte) { $row.Columna = $true; $corte = $false }
            $rows += $row
        }
    }
    return $rows
}

function Get-MainMenuRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return (ConvertTo-PctkMenuRows -Spec (Get-MainMenuSpec))
}

function Get-IndividualActionRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return (ConvertTo-PctkMenuRows -Spec (Get-IndividualActionSpec))
}

function Get-NamedProfileRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return (ConvertTo-PctkMenuRows -Spec (Get-NamedProfileSpec))
}

function Test-PctkConsoleResized {
    <#
    .SYNOPSIS
        Cambio de geometria de la consola desde el ultimo redibujo completo.

    .DESCRIPTION
        Defensiva por dos lados, y los dos importan:

        1. Si la consola no expone geometria (host raro), devuelve $false. Nunca
           reporta "cambio" cuando no puede saberlo.
        2. Si los valores de referencia son negativos -- o sea que el redibujo
           completo NUNCA logro leer la geometria -- tambien devuelve $false.
           Sin esa guarda, comparar contra -1 daria "cambio" en cada vuelta y el
           menu entraria en un bucle de redibujo infinito sin consumir teclas:
           un cuelgue, no un bug cosmetico.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [int] $LastWidth,
        [Parameter(Mandatory)] [int] $LastHeight,
        [Parameter(Mandatory)] [int] $LastBufferWidth
    )

    if ($LastWidth -lt 0 -or $LastHeight -lt 0 -or $LastBufferWidth -lt 0) { return $false }
    try {
        return ([Console]::WindowWidth  -ne $LastWidth -or
                [Console]::WindowHeight -ne $LastHeight -or
                [Console]::BufferWidth  -ne $LastBufferWidth)
    }
    catch { return $false }
}

# #99: seams finos de medicion. Los lectores de menu leen la consola por aca (y
# no [Console] directo) para que smoke pueda correr el lector REAL simulando el
# alto de ventana y el cursor. Mismo comportamiento que antes: si no se puede
# medir, tiran, y el caller degrada ($measureOk).
function Get-PctkConsoleCursorTop {
    [OutputType([int])]
    param()
    return [int] [Console]::CursorTop
}

function Get-PctkConsoleWindowHeight {
    [OutputType([int])]
    param()
    try { return [int] [Console]::WindowHeight }
    catch { return [int] $Host.UI.RawUI.WindowSize.Height }
}

# #72 paso 4: seams del teclado y del cursor de Read-PctkMenuChoice, mismo
# criterio que los de arriba: el smoke corre el lector REAL con teclas y una
# pantalla simulada. Mismo comportamiento que las llamadas directas: si la
# consola no tiene teclado real, tiran, y el lector cae al render plano.
function Test-PctkConsoleKeyAvailable {
    [OutputType([bool])]
    param()
    return [bool] [Console]::KeyAvailable
}

function Read-PctkConsoleKey {
    [OutputType([System.ConsoleKeyInfo])]
    param()
    return [Console]::ReadKey($true)
}

function Set-PctkConsoleCursor {
    [OutputType([void])]
    param([Parameter(Mandatory)] [int] $X, [Parameter(Mandatory)] [int] $Y)
    [Console]::SetCursorPosition($X, $Y)
}

function Get-PctkMenuLayout {
    <#
    .SYNOPSIS
        Decide como entra una lista de filas de menu en el alto REAL
        disponible de la consola (bug #46: en Windows Terminal la ventana no
        se puede agrandar -- MaxWindowSize ahi es el tamanio actual de la
        ventana, asi que Set-PctkConsoleSize no tiene margen para crecer -- el
        menu tiene que entrar en lo que hay, no asumir que agrandar funciono).

    .DESCRIPTION
        Pura: recibe los altos ya medidos por el caller y devuelve el modo de
        dibujo, sin tocar la consola (asi se puede probar sin abrir una). El
        guard NO es "es Windows Terminal": es medir budget vs. filas, y eso
        cubre tambien conhost en pantalla chica o achicado por AnyDesk.

        Modos, de mejor a peor:
        - Full     : entra TODO como hoy (headers + items + separadores).
        - Compact  : entra sin los separadores en blanco (Kind=Spacer), con
                     todo el contenido real (headers + items).
        - Paged    : ni compacto entra completo -> el caller dibuja una
                     VENTANA de $Budget filas de las compactas, que se
                     desliza para mantener visible la fila resaltada.
        - TooSmall : opcion (c) del plan D7 -- ni una vista minimamente util
                     entra. El caller avisa con UNA linea y cae al render
                     plano (sin coordenadas absolutas, a prueba de scroll)
                     en vez de romper el dibujo.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [int] $TotalRows,
        [Parameter(Mandatory)] [int] $CompactRows,
        [Parameter(Mandatory)] [int] $HeaderLines,
        [Parameter(Mandatory)] [int] $WindowHeight,
        [int] $FooterLines   = 2,   # linea en blanco + linea de ayuda, debajo de las filas
        [int] $BottomReserve = 1,   # ver nota abajo: la fila que se come el newline final
        [int] $MinUsableRows = 3    # opcion (c): por debajo de esto paginar ya no ayuda
    )
    # #46 -- POR QUE $BottomReserve (hallazgo de la verificacion visual, 2026-09-09):
    # la ULTIMA linea que dibuja el caller (la de ayuda) se escribe con Write-Host, o
    # sea TERMINA CON NEWLINE. Si el dibujo ocupa hasta la ultima fila valida
    # (WindowHeight-1), ese newline manda el cursor a la fila WindowHeight, que no
    # existe, y la consola SCROLLEA una fila. En Windows Terminal duele el doble
    # porque Buffer == WindowSize: no hay scrollback que lo absorba.
    #
    # El scroll no rompe el frame recien dibujado -- rompe el SIGUIENTE: las Y de
    # cada item ($itemY) se capturan MIENTRAS se dibuja, o sea antes del scroll, asi
    # que quedan todas +1. El redibujo "surgical" de 2 filas (el que evita el
    # parpadeo) entonces pinta una fila mas abajo de donde esta el texto: pisa la
    # opcion de al lado y deja la vieja sin limpiar.
    #
    # Reservar una fila es la unica correccion que NO toca el resto del fix: el
    # dibujo termina en WindowHeight-2, el newline final cae en WindowHeight-1 (que
    # existe) y no hay scroll en NINGUN modo. La alternativa -- escribir la ultima
    # linea con -NoNewline -- deja el cursor a mitad de renglon y lo que imprima el
    # caller despues se pega ahi.
    [int] $budget = $WindowHeight - $HeaderLines - $FooterLines - $BottomReserve
    [string] $mode = 'TooSmall'
    if ($budget -ge $TotalRows) {
        $mode = 'Full'
    } elseif ($budget -ge $CompactRows) {
        $mode = 'Compact'
    } elseif ($budget -ge $MinUsableRows -and $CompactRows -gt 0) {
        $mode = 'Paged'
    }
    return [PSCustomObject]@{ Mode = $mode; Budget = $budget }
}

function Get-PctkMenuViewport {
    <#
    .SYNOPSIS
        Nuevo ViewTop (primer indice visible) de un menu en modo Paged, para
        que $TargetPos (indice de la fila resaltada dentro de la lista SIN
        separadores) quede dentro de la ventana visible. Pura: sin consola,
        para poder probarla sin abrir una.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [int] $TargetPos,
        [Parameter(Mandatory)] [int] $CurrentViewTop,
        [Parameter(Mandatory)] [int] $Budget,
        [Parameter(Mandatory)] [int] $TotalCompactRows
    )
    [int] $viewTop = $CurrentViewTop
    if ($TargetPos -lt $viewTop) {
        $viewTop = $TargetPos
    } elseif ($TargetPos -ge ($viewTop + $Budget)) {
        $viewTop = $TargetPos - $Budget + 1
    }
    [int] $maxTop = [Math]::Max(0, $TotalCompactRows - $Budget)
    if ($viewTop -gt $maxTop) { $viewTop = $maxTop }
    if ($viewTop -lt 0)       { $viewTop = 0 }
    return $viewTop
}

function Show-PctkMenuTooSmallNotice {
    <#
    .SYNOPSIS
        Aviso de la opcion (c) del plan D7 cuando ni la vista paginada entra:
        avisa Y ESPERA al operador antes de devolver el control.

    .DESCRIPTION
        La pausa es el punto de la funcion, no un adorno. El multi-select no
        tiene un "render plano" propio: en TooSmall devuelve Action=fallback y
        el caller (Invoke-ToolsMenuInteractive) hace `return`, con lo cual el
        menu de arriba redibuja con Clear-Host y BORRA el aviso antes de que se
        alcance a leer. Sin esperar, el operador ve un flash y un [T] que
        aparenta no hacer nada -- el mismo sintoma que el bug #46 original,
        justo en el camino que existe para explicarlo.

        Esta afuera del loop de ReadKey a proposito: asi el comportamiento
        (avisa + espera) se prueba de verdad en smoke sombreando Write-PctkWarn
        y Read-Host, en vez de con un test estatico que mire el texto del
        archivo. El Read-Host va en try/catch porque en una consola sin input
        real (headless) tira, y el aviso no puede ser mas grave que lo que
        avisa.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)] [string] $Message)
    Write-PctkWarn $Message
    try { Read-Host '  [Enter] para volver' | Out-Null } catch { }
}

function Read-PctkMenuChoice {
    <#
    .SYNOPSIS
        Lee una opcion del menu hibrido: flechas/Enter en consola interactiva,
        fallback a Read-Host si no hay consola real (headless, smoke, redirigido).
        Devuelve la Key (string uppercase) identica al $choice original.
    .NOTES
        Modo interactivo v2: redibujo SURGICAL. El menu se dibuja completo UNA vez
        al entrar; cada flecha solo reescribe las 2 filas que cambian (la que pierde
        el highlight y la que lo gana) con [Console]::SetCursorPosition, SIN Clear-Host
        -> cero parpadeo (el flash de la v1 venia del Clear-Host por flecha). Si
        SetCursorPosition falla (consola rara), cae a un redibujo completo ese frame.

        #46: cada redibujo completo mide el alto REAL de ventana (Get-PctkMenuLayout)
        y elige Full/Compact/Paged/TooSmall en vez de asumir que Set-PctkConsoleSize
        agrando la ventana. En Paged, la ventana visible (viewTop) se desliza para
        mantener la fila resaltada a la vista; moverse DENTRO de la ventana sigue
        siendo el mismo redibujo surgical de 2 filas, moverse afuera fuerza un
        redibujo completo (la ventana visible cambio, las Y guardadas ya no valen).

        #72 paso 4: si las filas traen un corte de columna (Columna = $true, ver
        ConvertTo-PctkMenuRows) y la ventana tiene ancho >= 100, el menu va en DOS
        columnas: la izquierda en x = 0, la derecha en x = 60, nada pasa de 118
        columnas (una celda que no entra se corta). El alto (Full/Compact/Paged/
        TooSmall y el banner compacto de #99) se decide con la columna mas alta.
        Las filas van sin la aclaracion: la de la opcion resaltada va en una linea
        propia arriba de la de ayuda y se reescribe al mover. Flechas arriba/abajo
        recorren la lista entera en el orden de la tabla; izquierda/derecha saltan
        a la columna de enfrente (a la opcion de la fila mas cercana); en dos
        columnas la flecha derecha NO elige, Enter si.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object[]] $Rows,
        [Parameter(Mandatory)] [scriptblock] $RenderHeader,
        [string] $Prompt = '  Selecciona una opcion',
        [switch] $ForceFallbackForTest
    )

    [object[]] $items = @($Rows | Where-Object { $_.Kind -eq 'Item' })

    # #72 paso 4: geometria de las dos columnas.
    [int] $twoColMinWidth = 100   # ancho de ventana desde el que se usan dos columnas
    [int] $colRightX      = 60    # x de la columna derecha: celda de 56 + 4 de separacion
    [int] $maxLineWidth   = 118   # ninguna linea pasa de aca

    # helper local: el texto VISIBLE de una fila (sin color), el mismo que escribe
    # Write-RowLine. $Max > 0 = tope de ancho (dos columnas): un rotulo de seccion
    # acorta su raya, una opcion se corta con '...'. $Short = la fila sin aclaracion.
    function Get-RowCellText {
        param($Row, [bool] $Hi, [int] $Max = 0, [bool] $Short = $false)
        if ($Row.Kind -eq 'Spacer') { return '' }
        if ($Row.Kind -eq 'Header') {
            if (Test-PctkVT) {
                [string] $nm = ([string]$Row.Label).Trim()
                [int] $dashes = [Math]::Max(3, 50 - $nm.Length)
                if ($Max -gt 0 -and (6 + $nm.Length + $dashes) -gt $Max) {
                    $dashes = $Max - 6 - $nm.Length
                    if ($dashes -lt 1) { $nm = Limit-PctkText $nm ($Max - 7); $dashes = 1 }
                }
                return ('  ── ' + $nm + ' ' + ('─' * $dashes))
            }
            return (Limit-PctkText ([string]$Row.Label) $Max)
        }
        [string] $src = [string]$Row.Label
        if ($Short) { $src = [string]$Row.LabelCorto }
        [string] $mark = '  '
        if ($Hi) { $mark = '> ' }
        return (Limit-PctkText ($mark + $src.TrimStart()) $Max)
    }

    # helper local: escribe una fila (con o sin highlight). Mismo largo de texto
    # en highlight ('> ') y normal ('  ') -> reescribir una fila sobre otra no deja
    # restos, sin necesidad de padding.
    function Write-RowLine {
        param($Row, [bool] $Hi, [int] $Max = 0, [switch] $Short, [switch] $NoNewline)
        if ($Row.Kind -eq 'Spacer') { Write-Host '' -NoNewline:$NoNewline; return }
        [bool] $vt = Test-PctkVT
        [string] $t = Get-RowCellText -Row $Row -Hi $Hi -Max $Max -Short ([bool]$Short)
        if ($Row.Kind -eq 'Header') {
            if ($vt) { Write-Host ('  ' + (Pf 255 170 40) + $t.Substring(2) + (Pe)) -NoNewline:$NoNewline }
            else     { Write-Host $t -ForegroundColor DarkCyan -NoNewline:$NoNewline }
            return
        }
        if ($Hi) {
            if ($vt) { Write-Host ((Pb 150 95 0) + (Pf 245 240 230) + $t + (Pe)) -NoNewline:$NoNewline }
            else     { Write-Host $t -BackgroundColor DarkGray -ForegroundColor White -NoNewline:$NoNewline }
        } elseif (-not [string]::IsNullOrEmpty([string]$Row.Color)) {
            if ($vt) {
                [string] $fg = ConvertTo-PctkAnsiFg ([string]$Row.Color)
                if ([string]::IsNullOrEmpty($fg)) { $fg = Pf 140 152 166 }
                Write-Host ($fg + $t + (Pe)) -NoNewline:$NoNewline
            } else {
                Write-Host $t -ForegroundColor ([string]$Row.Color) -NoNewline:$NoNewline
            }
        } elseif ($vt) {
            Write-Host ((Pf 140 152 166) + $t + (Pe)) -NoNewline:$NoNewline
        } else {
            Write-Host $t -NoNewline:$NoNewline
        }
    }

    # helper local (#72 paso 4): la linea de aclaracion de la opcion $Idx. -Pad la
    # rellena al ancho de la mas larga: reescrita encima de otra no deja restos.
    function Write-AclLine {
        param([int] $Idx, [switch] $Pad, [switch] $NoNewline)
        [string] $t = ''
        if (-not [string]::IsNullOrEmpty([string]$items[$Idx].Aclaracion)) { $t = '  (' + [string]$items[$Idx].Aclaracion + ')' }
        $t = Limit-PctkText $t $lineMax
        if ($Pad) { $t = $t.PadRight($aclWidth) }
        if (Test-PctkVT) { Write-Host ((Pf 140 152 166) + $t + (Pe)) -NoNewline:$NoNewline }
        else             { Write-Host $t -ForegroundColor DarkGray -NoNewline:$NoNewline }
    }

    # helper local: redibujo SURGICAL al mover el resaltado de $Old a $New: solo
    # las celdas que cambian (y en dos columnas la linea de aclaracion), en su
    # (x, y). Si la consola no deja mover el cursor tira, y el caller hace un
    # redibujo completo el proximo frame.
    function Update-Highlight {
        param([int] $Old, [int] $New)
        if ($twoCol) {
            Set-PctkConsoleCursor -X $itemX[$Old] -Y $itemY[$Old]; Write-RowLine -Row $items[$Old] -Hi $false -Max $itemMax[$Old] -Short -NoNewline
            Set-PctkConsoleCursor -X $itemX[$New] -Y $itemY[$New]; Write-RowLine -Row $items[$New] -Hi $true  -Max $itemMax[$New] -Short -NoNewline
            Set-PctkConsoleCursor -X 0 -Y $aclY; Write-AclLine -Idx $New -Pad -NoNewline
        } else {
            Set-PctkConsoleCursor -X 0 -Y $itemY[$Old]; Write-RowLine -Row $items[$Old] -Hi $false
            Set-PctkConsoleCursor -X 0 -Y $itemY[$New]; Write-RowLine -Row $items[$New] -Hi $true
        }
        Set-PctkConsoleCursor -X 0 -Y $bottomY
    }

    # helper local (#72 paso 4): dos listas de filas -> lineas de pantalla con su
    # celda izquierda (L) y derecha (R); $null = celda vacia.
    function ConvertTo-MenuGrid {
        param([object[]] $L, [object[]] $R)
        [int] $n = [Math]::Max($L.Count, $R.Count)
        [object[]] $g = @()
        for ([int] $i = 0; $i -lt $n; $i++) {
            [object] $cl = $null; [object] $cr = $null
            if ($i -lt $L.Count) { $cl = $L[$i] }
            if ($i -lt $R.Count) { $cr = $R[$i] }
            $g += [PSCustomObject]@{ L = $cl; R = $cr }
        }
        return ,$g
    }

    # helper local: render plano sin highlight + Read-Host. Sin coordenadas
    # absolutas -> nunca se desalinea aunque el contenido scrollee, por eso es
    # el fallback comun de "no hay consola interactiva real" (headless/smoke),
    # "ReadKey fallo a mitad de sesion" (consola rara) y "TooSmall" (#46,
    # opcion c: ni la vista paginada entra -- avisar y no romper el dibujo).
    function Invoke-FlatFallback {
        foreach ($row in $Rows) { Write-RowLine -Row $row -Hi $false }
        Write-Host ''
        return (Read-Host $Prompt).Trim().ToUpperInvariant()
    }

    # Gate: todas deben pasar para usar modo crudo; si falla alguna -> fallback
    # (#99: el gate es Test-PctkInteractiveConsole, la misma condicion que antes
    # estaba inline, para que smoke pueda correr el modo interactivo)
    [bool] $interactive = $false
    if (-not $ForceFallbackForTest) {
        $interactive = [bool] (Test-PctkInteractiveConsole)
    }

    if (-not $interactive -or $items.Count -eq 0) {
        # Fallback: render sin highlight + Read-Host (comportamiento original)
        & $RenderHeader
        return (Invoke-FlatFallback)
    }

    # --- Modo interactivo: redibujo surgical (sin Clear-Host por flecha) ---
    [int]   $hiIdx   = 0
    [int[]] $itemY   = [int[]]::new($items.Count)   # Y de consola de cada Item
    [int]   $bottomY = 0
    [bool]   $full   = $true                        # true -> redibujo completo este frame
    [string] $buffer = ''                           # acumulador de atajo multi-caracter (ej. 10-18)
    [int]    $lastW  = -1                            # tamanio de ventana/buffer en el ultimo redibujo
    [int]    $lastH  = -1                            #   completo -> detectar resize (ej. maximizar) y
    [int]    $lastBW = -1                            #   re-dibujar (las Y cacheadas quedan obsoletas)

    # #46: filas sin separadores (modo Compact/Paged) + mapa fila->indice de
    # item, precalculado UNA vez (la estructura de $Rows no cambia durante el
    # loop). $itemIndexOf usa el objeto fila como clave -- son las MISMAS
    # instancias en $Rows/$compactRows (Where-Object no clona), asi que la
    # identidad de referencia es estable.
    [object[]] $compactRows = @($Rows | Where-Object { $_.Kind -ne 'Spacer' })
    [hashtable] $itemIndexOf = @{}
    for ([int] $k = 0; $k -lt $items.Count; $k++) { $itemIndexOf[$items[$k]] = $k }
    [int[]] $oneColRowPos = [int[]]::new($items.Count)   # indice del item DENTRO de $compactRows
    [int] $cIdx = 0
    foreach ($cRow in $compactRows) {
        if ($cRow.Kind -eq 'Item') { $oneColRowPos[$itemIndexOf[$cRow]] = $cIdx }
        $cIdx++
    }

    # #72 paso 4: las dos columnas, precalculadas UNA vez. La derecha arranca en
    # la fila con Columna = $true. Lineas de pantalla sin separadores ($gridCompact),
    # y por item: columna (0/1) y linea en la grilla.
    [object[]] $leftRows = @()
    [object[]] $rightRows = @()
    foreach ($r in $Rows) {
        if ($rightRows.Count -gt 0 -or ($null -ne $r.PSObject.Properties['Columna'] -and [bool] $r.Columna)) { $rightRows += $r }
        else { $leftRows += $r }
    }
    [bool] $hasBreak = $leftRows.Count -gt 0 -and $rightRows.Count -gt 0
    [object[]] $gridCompact = ConvertTo-MenuGrid -L @($leftRows | Where-Object { $_.Kind -ne 'Spacer' }) -R @($rightRows | Where-Object { $_.Kind -ne 'Spacer' })
    [int[]] $itemCol     = [int[]]::new($items.Count)
    [int[]] $lineCompact = [int[]]::new($items.Count)
    foreach ($r in $rightRows) { if ($r.Kind -eq 'Item') { $itemCol[$itemIndexOf[$r]] = 1 } }
    for ([int] $g = 0; $g -lt $gridCompact.Count; $g++) {
        foreach ($cell in @($gridCompact[$g].L, $gridCompact[$g].R)) { if ($null -ne $cell -and $cell.Kind -eq 'Item') { $lineCompact[$itemIndexOf[$cell]] = $g } }
    }
    [bool]  $twoCol   = $false                          # el ultimo redibujo completo fue en dos columnas
    [int[]] $itemX    = [int[]]::new($items.Count)       # X de consola de cada Item (dos columnas)
    [int[]] $itemMax  = [int[]]::new($items.Count)       # tope de ancho de la celda de cada Item
    [int]   $aclY     = 0                                # Y de la linea de aclaracion
    [int]   $aclWidth = 0                                # ancho de la aclaracion mas larga
    [int]   $lineMax  = $maxLineWidth

    [int[]] $itemRowPos   = $oneColRowPos   # posicion de cada item en la lista paginable del modo actual
    [int]   $compactCount = $compactRows.Count
    [string] $layoutMode = 'Full'
    [int]    $viewTop    = 0   # solo relevante en modo Paged: primer indice visible de $compactRows
    [int]    $viewEnd    = $compactRows.Count - 1

    try {
        while ($true) {
            if ($full) {
                # #99: cada redibujo completo re-decide desde el banner completo.
                $script:PctkBannerCompact = $false
                & $RenderHeader

                # #72 paso 4: dos columnas si la tabla tiene corte y la ventana el ancho.
                # El alto se decide con la columna mas alta (las lineas de la grilla), y
                # el pie suma la linea de aclaracion.
                [int] $winW = 0
                try { $winW = [int] (Get-PctkConsoleWindowWidth) } catch { $winW = 0 }
                $twoCol = $hasBreak -and $winW -ge $twoColMinWidth
                [int] $layTotal   = $Rows.Count
                [int] $layCompact = $compactRows.Count
                [int] $layFooter  = 2
                $itemRowPos   = $oneColRowPos
                $compactCount = $compactRows.Count
                if ($twoCol) {
                    # En dos columnas no van los separadores: caen a alturas distintas
                    # en cada columna y desalinean las filas (y el rotulo de cada
                    # seccion ya la separa). Full y Compact dibujan lo mismo.
                    $layTotal     = $gridCompact.Count
                    $layCompact   = $gridCompact.Count
                    $layFooter    = 3
                    $itemRowPos   = $lineCompact
                    $compactCount = $gridCompact.Count
                }

                # #46: medir el alto REAL antes de decidir como dibujar. Si algo
                # no se puede medir, degradar directo al render plano (mismo
                # espiritu que TooSmall: ante la duda, el seguro es el que no usa
                # coordenadas absolutas).
                [bool] $measureOk   = $true
                [int]  $headerLines = 0
                try { $headerLines = Get-PctkConsoleCursorTop } catch { $measureOk = $false }
                [int] $winH = 0
                if ($measureOk) {
                    try { $winH = Get-PctkConsoleWindowHeight } catch { $measureOk = $false }
                }

                if (-not $measureOk -or $winH -le 0) {
                    $layoutMode = 'TooSmall'
                } else {
                    $layoutInfo = Get-PctkMenuLayout -TotalRows $layTotal -CompactRows $layCompact -HeaderLines $headerLines -WindowHeight $winH -FooterLines $layFooter
                    $layoutMode = [string] $layoutInfo.Mode
                    # #99: si no entra ni compacto, antes de paginar probar con el
                    # banner compacto (sin logo ni titulo/autor). Se RE-MIDE el
                    # header: manda la medicion, no el -8 calculado. Si sigue sin
                    # entrar, queda compacto igual (mas filas visibles).
                    if (($layoutMode -eq 'Paged' -or $layoutMode -eq 'TooSmall') -and -not $script:PctkBannerCompact) {
                        $script:PctkBannerCompact = $true
                        & $RenderHeader
                        try { $headerLines = Get-PctkConsoleCursorTop } catch { $measureOk = $false }
                        if ($measureOk) {
                            $layoutInfo = Get-PctkMenuLayout -TotalRows $layTotal -CompactRows $layCompact -HeaderLines $headerLines -WindowHeight $winH -FooterLines $layFooter
                            $layoutMode = [string] $layoutInfo.Mode
                        } else {
                            $layoutMode = 'TooSmall'
                        }
                    }
                }

                if ($layoutMode -eq 'TooSmall') {
                    Write-PctkWarn '  [!] La consola es muy chica para el menu -- agranda la ventana para ver las opciones.'
                    return (Invoke-FlatFallback)
                }

                if ($layoutMode -eq 'Paged') {
                    $viewTop = Get-PctkMenuViewport -TargetPos $itemRowPos[$hiIdx] -CurrentViewTop $viewTop -Budget $layoutInfo.Budget -TotalCompactRows $compactCount
                    $viewEnd = [Math]::Min($compactCount, $viewTop + $layoutInfo.Budget) - 1
                } else {
                    $viewTop = 0
                    $viewEnd = $compactCount - 1
                }

                if (-not $twoCol) {
                    [object[]] $rowsToDraw = $Rows
                    if ($layoutMode -eq 'Compact') { $rowsToDraw = $compactRows }
                    if ($layoutMode -eq 'Paged')   { $rowsToDraw = $compactRows[$viewTop..$viewEnd] }

                    foreach ($row in $rowsToDraw) {
                        if ($row.Kind -eq 'Item') {
                            [int] $ii = $itemIndexOf[$row]
                            $itemY[$ii] = Get-PctkConsoleCursorTop
                            Write-RowLine -Row $row -Hi ($ii -eq $hiIdx)
                        } else {
                            Write-RowLine -Row $row -Hi $false
                        }
                    }
                    Write-Host ''
                } else {
                    # #72 paso 4: una linea de pantalla = celda izquierda + relleno
                    # hasta x = 60 + celda derecha. Las celdas van sin aclaracion.
                    [object[]] $grid = $gridCompact
                    if ($layoutMode -eq 'Paged') { $grid = $gridCompact[$viewTop..$viewEnd] }
                    $lineMax = [Math]::Min($maxLineWidth, $winW - 1)
                    [int] $leftMax  = $colRightX - 4
                    [int] $rightMax = $lineMax - $colRightX
                    foreach ($gl in $grid) {
                        [int] $used = 0
                        if ($null -ne $gl.L) {
                            [bool] $lhi = $false
                            if ($gl.L.Kind -eq 'Item') {
                                [int] $li = $itemIndexOf[$gl.L]
                                $itemY[$li] = Get-PctkConsoleCursorTop; $itemX[$li] = 0; $itemMax[$li] = $leftMax
                                $lhi = ($li -eq $hiIdx)
                            }
                            Write-RowLine -Row $gl.L -Hi $lhi -Max $leftMax -Short -NoNewline
                            $used = (Get-RowCellText -Row $gl.L -Hi $lhi -Max $leftMax -Short $true).Length
                        }
                        if ($null -ne $gl.R -and $gl.R.Kind -ne 'Spacer') {
                            if ($colRightX -gt $used) { Write-Host (' ' * ($colRightX - $used)) -NoNewline }
                            [bool] $rhi = $false
                            if ($gl.R.Kind -eq 'Item') {
                                [int] $ri = $itemIndexOf[$gl.R]
                                $itemY[$ri] = Get-PctkConsoleCursorTop; $itemX[$ri] = $colRightX; $itemMax[$ri] = $rightMax
                                $rhi = ($ri -eq $hiIdx)
                            }
                            Write-RowLine -Row $gl.R -Hi $rhi -Max $rightMax -Short -NoNewline
                        }
                        Write-Host ''
                    }
                    Write-Host ''
                    $aclWidth = 0
                    foreach ($it in $items) {
                        if (-not [string]::IsNullOrEmpty([string]$it.Aclaracion)) {
                            $aclWidth = [Math]::Max($aclWidth, (Limit-PctkText ('  (' + [string]$it.Aclaracion + ')') $lineMax).Length)
                        }
                    }
                    $aclY = Get-PctkConsoleCursorTop
                    Write-AclLine -Idx $hiIdx
                }
                [string] $hintLine = '  Usa flechas arriba/abajo + Enter, o la tecla del atajo:'
                if ($twoCol) { $hintLine = '  Flechas + Enter, o el atajo del margen.' }
                if ($layoutMode -eq 'Paged') {
                    $hintLine = ('  Flechas + Enter, o el atajo del margen.  (mostrando {0}-{1} de {2})' -f ($viewTop + 1), ($viewEnd + 1), $compactCount)
                }
                if (Test-PctkVT) { Write-Host ((Pf 95 108 124) + $hintLine + (Pe)) }
                else             { Write-Host $hintLine -ForegroundColor DarkGray }
                $bottomY = Get-PctkConsoleCursorTop
                try { $lastW = [Console]::WindowWidth; $lastH = [Console]::WindowHeight; $lastBW = [Console]::BufferWidth } catch { }
                $full = $false
            }

            # --- Espera de tecla CON deteccion de resize (#43) -----------------------
            # Antes esto era un [Console]::ReadKey($true) bloqueante y el chequeo de
            # resize corria DESPUES, o sea recien cuando llegaba una tecla. Resultado:
            # el operador maximizaba y la pantalla quedaba con el highlight estirado a
            # todo el ancho nuevo y con restos del dibujo viejo en los bordes, hasta
            # que apretaba algo. Sintoma textual de Mateo en el gate de v2.5.0: "se
            # buguea un poquito, si entro a un menu y salgo se arregla" -- eso era la
            # guarda disparandose tarde, no un problema de dibujo.
            #
            # Ahora se sondea, asi el redibujo llega solo. 80 ms es imperceptible al
            # tipear (nadie nota 80 ms entre tecla y highlight) y no mueve la CPU: la
            # regla del repo es que nada de UX puede agregar carga en la PC del cliente.
            $key = $null
            [bool] $resized = $false
            try {
                # #72 paso 4: por los seams (Test-PctkConsoleKeyAvailable sondea
                # [Console]::KeyAvailable, Read-PctkConsoleKey hace el ReadKey).
                while (-not (Test-PctkConsoleKeyAvailable)) {
                    if (Test-PctkConsoleResized -LastWidth $lastW -LastHeight $lastH -LastBufferWidth $lastBW) {
                        $resized = $true
                        break
                    }
                    Start-Sleep -Milliseconds 80
                }
                if (-not $resized) { $key = Read-PctkConsoleKey }
            } catch {
                # KeyAvailable/ReadKey fallaron (host sin consola real) -> fallback a
                # Read-Host, igual que antes.
                & $RenderHeader
                return (Invoke-FlatFallback)
            }

            # Resize mientras se esperaba: las Y cacheadas en $itemY quedaron obsoletas,
            # asi que redibujo completo en vez de pintar el highlight en coordenadas
            # viejas. No se consumio ninguna tecla.
            if ($resized) { $full = $true; continue }
            if ($null -eq $key) { continue }

            # Y el resize que entra JUNTO con la tecla (o entre el poll y el ReadKey):
            # mismo tratamiento. Este es el camino que ya existia y se conserva.
            if (Test-PctkConsoleResized -LastWidth $lastW -LastHeight $lastH -LastBufferWidth $lastBW) {
                $full = $true
                continue
            }

            if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
                $buffer = ''
                [int] $old = $hiIdx
                if ($key.Key -eq [ConsoleKey]::UpArrow) {
                    $hiIdx = if ($hiIdx -le 0) { $items.Count - 1 } else { $hiIdx - 1 }
                } else {
                    $hiIdx = if ($hiIdx -ge ($items.Count - 1)) { 0 } else { $hiIdx + 1 }
                }
                if ($old -ne $hiIdx) {
                    # #46: en modo Paged, si el nuevo resaltado cae afuera de la
                    # ventana visible actual hay que deslizarla -> las Y de TODAS
                    # las filas visibles cambian, asi que toca redibujo completo
                    # (no alcanza con las 2 filas de siempre).
                    [bool] $needsScroll = ($layoutMode -eq 'Paged') -and
                        ($itemRowPos[$hiIdx] -lt $viewTop -or $itemRowPos[$hiIdx] -gt $viewEnd)
                    if ($needsScroll) {
                        $full = $true
                    } else {
                        # solo las celdas que cambian -> cero flash
                        try { Update-Highlight -Old $old -New $hiIdx }
                        catch { $full = $true }   # consola rara -> redibujo completo el proximo frame
                    }
                }
                continue
            }
            # #72 paso 4: en dos columnas, izquierda/derecha saltan a la columna de
            # enfrente, a la opcion de la linea mas cercana (empate: la de arriba).
            if ($twoCol -and ($key.Key -eq [ConsoleKey]::LeftArrow -or $key.Key -eq [ConsoleKey]::RightArrow)) {
                $buffer = ''
                [int] $targetCol = 1 - $itemCol[$hiIdx]
                [int] $best = -1
                [int] $bestDist = [int]::MaxValue
                for ([int] $j = 0; $j -lt $items.Count; $j++) {
                    if ($itemCol[$j] -ne $targetCol) { continue }
                    [int] $dist = [Math]::Abs($lineCompact[$j] - $lineCompact[$hiIdx])
                    if ($dist -lt $bestDist) { $best = $j; $bestDist = $dist }
                }
                if ($best -ge 0 -and $best -ne $hiIdx) {
                    [int] $old = $hiIdx
                    $hiIdx = $best
                    [bool] $needsScroll = ($layoutMode -eq 'Paged') -and
                        ($itemRowPos[$hiIdx] -lt $viewTop -or $itemRowPos[$hiIdx] -gt $viewEnd)
                    if ($needsScroll) {
                        $full = $true
                    } else {
                        try { Update-Highlight -Old $old -New $hiIdx }
                        catch { $full = $true }
                    }
                }
                continue
            }
            # Enter o flecha derecha = elegir la opcion resaltada. En dos columnas la
            # flecha derecha no llega aca: la consume el salto de columna de arriba.
            if ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::RightArrow) {
                return [string]$items[$hiIdx].Key
            }
            # Atajo por tecla. Soporta keys de varios caracteres (ej. 10-17): un
            # digito ambiguo ('1') NO elige solo (es prefijo de 10-17); acumula y
            # mueve el highlight, y se completa con el 2do digito ('12') o se
            # confirma con Enter. Los no ambiguos (2-9, B) eligen al toque.
            if ($key.KeyChar -ne [char]0) {
                [string] $ch = $key.KeyChar.ToString().ToUpperInvariant()
                [string[]] $cands = @()
                if ($buffer -ne '') { $cands += ($buffer + $ch) }
                $cands += $ch

                [bool] $accepted = $false
                foreach ($cand in $cands) {
                    [object] $exact     = $items | Where-Object { [string]$_.Key -eq $cand } | Select-Object -First 1
                    [bool]   $hasLonger = @($items | Where-Object { [string]$_.Key -ne $cand -and ([string]$_.Key).StartsWith($cand) }).Count -gt 0
                    if ($null -ne $exact -and -not $hasLonger) {
                        return [string]$exact.Key                  # match unico y completo -> elegir
                    }
                    if ($hasLonger -or $null -ne $exact) {
                        $buffer = $cand                            # prefijo (o ambiguo) -> acumular y esperar
                        [int] $mi = -1
                        for ($j = 0; $j -lt $items.Count; $j++) { if ([string]$items[$j].Key -eq $cand) { $mi = $j; break } }
                        if ($mi -lt 0) { for ($j = 0; $j -lt $items.Count; $j++) { if (([string]$items[$j].Key).StartsWith($cand)) { $mi = $j; break } } }
                        if ($mi -ge 0 -and $mi -ne $hiIdx) {
                            [int] $old = $hiIdx; $hiIdx = $mi
                            # #46: mismo trato que las flechas -- si el atajo salto
                            # a un item fuera de la ventana Paged visible, redibujo
                            # completo en vez de pintar en Y que ya no corresponden.
                            [bool] $needsScroll = ($layoutMode -eq 'Paged') -and
                                ($itemRowPos[$hiIdx] -lt $viewTop -or $itemRowPos[$hiIdx] -gt $viewEnd)
                            if ($needsScroll) {
                                $full = $true
                            } else {
                                try { Update-Highlight -Old $old -New $hiIdx } catch { $full = $true }
                            }
                        }
                        $accepted = $true
                        break
                    }
                }
                if (-not $accepted) { $buffer = '' }
            }
            # Otras teclas (Esc, F-keys, flecha izquierda): ignorar
        }
    }
    finally {
        # #99: el compacto vive mientras ESTE menu esta activo. La pantalla del
        # handler y el proximo menu arrancan con el banner completo.
        $script:PctkBannerCompact = $false
    }
}

function Test-PctkInteractiveConsole {
    <#
    .SYNOPSIS
        True si hay consola real con teclado (no headless, no redirigido, no smoke).
        Gate compartido para decidir modo crudo vs fallback tipeado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        return ([Environment]::UserInteractive -eq $true -and
                [Console]::IsInputRedirected -eq $false -and
                [Console]::IsOutputRedirected -eq $false)
    } catch { return $false }
}

function Read-PctkMultiChoice {
    <#
    .SYNOPSIS
        Multi-seleccion interactiva con checkboxes. Flechas mueven el highlight,
        Espacio marca/desmarca, Enter confirma (Action=submit), B/Esc cancela
        (Action=cancel); cada tecla de ActionKeys devuelve esa accion (el caller
        la maneja y vuelve a llamar preservando Checked). Redibujo surgical, sin
        Clear-Host. Asume consola interactiva: el caller chequea
        Test-PctkInteractiveConsole y maneja el fallback tipeado.
        Devuelve [PSCustomObject] @{ Action; Checked }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]    $Items,        # cada uno: { Label; Color }
        [Parameter(Mandatory)] [scriptblock] $RenderHeader,
        [Parameter(Mandatory)] [bool[]]      $Checked,      # estado inicial (largo == Items)
        [int]      $InitialHighlight = 0,                   # fila resaltada inicial (preservar pos entre acciones)
        [string]   $LegendLine = '  Espacio marca | Enter confirma | B vuelve',
        [string[]] $ActionKeys = @()
    )

    function Write-MultiRow {
        param([bool] $IsChecked, [object] $Item, [bool] $Hi)
        [bool]   $vt    = Test-PctkVT
        [string] $box   = if ($IsChecked) { '[x] ' } else { '[ ] ' }
        [string] $label = ([string]$Item.Label).TrimStart()
        if ($Hi) {
            # fila resaltada: fondo ambar (a1) con VT; clasico gris sin VT. Mismo
            # ancho visible que la fila normal -> overwrite surgical sin restos.
            if ($vt) { Write-Host ((Pb 150 95 0) + (Pf 245 240 230) + '> ' + $box + $label + (Pe)) }
            else     { Write-Host ('> ' + $box + $label) -BackgroundColor DarkGray -ForegroundColor White }
            return
        }
        if ($vt) {
            # checkbox marcado = verde ok, vacio = dim; texto = .Color mapeado al tema (o slate).
            [string] $boxCol = if ($IsChecked) { Pf 90 210 120 } else { Pf 95 108 124 }
            [string] $txtCol = ConvertTo-PctkAnsiFg ([string]$Item.Color)
            if ([string]::IsNullOrEmpty($txtCol)) { $txtCol = Pf 140 152 166 }
            Write-Host ('  ' + $boxCol + $box + (Pe) + $txtCol + $label + (Pe))
        } elseif (-not [string]::IsNullOrEmpty([string]$Item.Color)) {
            Write-Host ('  ' + $box + $label) -ForegroundColor ([string]$Item.Color)
        } else {
            Write-Host ('  ' + $box + $label)
        }
    }

    [int]   $count   = $Items.Count
    [int]   $hiIdx   = if ($InitialHighlight -ge 0 -and $InitialHighlight -lt $count) { $InitialHighlight } else { 0 }
    [int[]] $itemY   = [int[]]::new([Math]::Max($count, 1))
    [int]    $legendY = 0
    [bool]   $full    = $true
    [string] $buffer  = ''    # acumulador para marcar por numero multi-digito (10-19)
    [int]    $lastW = -1; [int] $lastH = -1; [int] $lastBW = -1   # detectar resize -> redibujo

    # #46: sin headers/spacers aca (todas las filas son items) -> "Compact" no
    # aporta nada distinto de "Full" y nunca se elige; solo importan Full vs.
    # Paged vs. TooSmall. viewTop/viewEnd delimitan la ventana visible cuando
    # es Paged (indices directos sobre $Items, no hace falta mapeo de filas).
    [string] $layoutMode = 'Full'
    [int]    $viewTop    = 0
    [int]    $viewEnd    = $count - 1

    try {
        while ($true) {
            if ($full) {
                # #99: mismo trato que Read-PctkMenuChoice (banner compacto antes de paginar).
                $script:PctkBannerCompact = $false
                & $RenderHeader

                [bool] $measureOk   = $true
                [int]  $headerLines = 0
                try { $headerLines = Get-PctkConsoleCursorTop } catch { $measureOk = $false }
                [int] $winH = 0
                if ($measureOk) {
                    try { $winH = Get-PctkConsoleWindowHeight } catch { $measureOk = $false }
                }

                if (-not $measureOk -or $winH -le 0) {
                    $layoutMode = 'TooSmall'
                } else {
                    $layoutInfo = Get-PctkMenuLayout -TotalRows $count -CompactRows $count -HeaderLines $headerLines -WindowHeight $winH
                    $layoutMode = [string] $layoutInfo.Mode
                    if (($layoutMode -eq 'Paged' -or $layoutMode -eq 'TooSmall') -and -not $script:PctkBannerCompact) {
                        $script:PctkBannerCompact = $true
                        & $RenderHeader
                        try { $headerLines = Get-PctkConsoleCursorTop } catch { $measureOk = $false }
                        if ($measureOk) {
                            $layoutInfo = Get-PctkMenuLayout -TotalRows $count -CompactRows $count -HeaderLines $headerLines -WindowHeight $winH
                            $layoutMode = [string] $layoutInfo.Mode
                        } else {
                            $layoutMode = 'TooSmall'
                        }
                    }
                }

                if ($layoutMode -eq 'TooSmall') {
                    # #46 opcion (c): avisar con UNA linea y volver -- no hay un
                    # "render plano" propio para el multi-select (el caller ya
                    # trata Action=fallback como "salir con gracia", ver
                    # Invoke-ToolsMenuInteractive), asi que se reusa esa salida
                    # PERO con el aviso puesto, en vez de irse en silencio.
                    #
                    # La pausa NO es opcional: al volver, el menu de arriba redibuja
                    # con Clear-Host y borra el aviso. Ver Show-PctkMenuTooSmallNotice.
                    Show-PctkMenuTooSmallNotice '  [!] La consola es muy chica para esta lista -- agranda la ventana para ver las opciones.'
                    return [PSCustomObject]@{ Action = 'fallback'; Checked = $Checked; HiIdx = $hiIdx }
                }

                if ($layoutMode -eq 'Paged') {
                    $viewTop = Get-PctkMenuViewport -TargetPos $hiIdx -CurrentViewTop $viewTop -Budget $layoutInfo.Budget -TotalCompactRows $count
                    $viewEnd = [Math]::Min($count, $viewTop + $layoutInfo.Budget) - 1
                } else {
                    $viewTop = 0
                    $viewEnd = $count - 1
                }

                for ([int] $i = $viewTop; $i -le $viewEnd; $i++) {
                    $itemY[$i] = [Console]::CursorTop
                    Write-MultiRow -IsChecked $Checked[$i] -Item $Items[$i] -Hi ($i -eq $hiIdx)
                }
                Write-Host ''
                $legendY = [Console]::CursorTop
                [string] $legend = $LegendLine
                if ($layoutMode -eq 'Paged') {
                    $legend = ('{0}  (mostrando {1}-{2} de {3})' -f $LegendLine, ($viewTop + 1), ($viewEnd + 1), $count)
                }
                if (Test-PctkVT) { Write-Host ((Pf 95 108 124) + $legend + (Pe)) }
                else             { Write-Host $legend -ForegroundColor DarkGray }
                try { $lastW = [Console]::WindowWidth; $lastH = [Console]::WindowHeight; $lastBW = [Console]::BufferWidth } catch { }
                $full = $false
            }

            # Misma espera sondeada que Read-PctkMenuChoice (#43): con el ReadKey
            # bloqueante, la guarda de resize de abajo no se evaluaba hasta que llegara
            # una tecla, asi que maximizar dejaba el menu mal dibujado hasta que el
            # operador apretaba algo. Este menu tenia el bug identico -- arreglar solo
            # el principal habria dejado la mitad, y el [T] es el que mas se mira con
            # la ventana agrandada (23 herramientas en lista).
            $key = $null
            [bool] $resized = $false
            try {
                while (-not [Console]::KeyAvailable) {
                    if (Test-PctkConsoleResized -LastWidth $lastW -LastHeight $lastH -LastBufferWidth $lastBW) {
                        $resized = $true
                        break
                    }
                    Start-Sleep -Milliseconds 80
                }
                if (-not $resized) { $key = [Console]::ReadKey($true) }
            }
            catch { return [PSCustomObject]@{ Action = 'fallback'; Checked = $Checked; HiIdx = $hiIdx } }

            if ($resized) { $full = $true; continue }
            if ($null -eq $key) { continue }

            # Resize que entra junto con la tecla -> Y cacheadas obsoletas -> redibujo.
            if (Test-PctkConsoleResized -LastWidth $lastW -LastHeight $lastH -LastBufferWidth $lastBW) {
                $full = $true
                continue
            }

            if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
                $buffer = ''
                [int] $old = $hiIdx
                if ($key.Key -eq [ConsoleKey]::UpArrow) { $hiIdx = if ($hiIdx -le 0) { $count - 1 } else { $hiIdx - 1 } }
                else { $hiIdx = if ($hiIdx -ge ($count - 1)) { 0 } else { $hiIdx + 1 } }
                if ($old -ne $hiIdx) {
                    # #46: mismo trato que en Read-PctkMenuChoice -- si el nuevo
                    # resaltado cae afuera de la ventana Paged visible, redibujo
                    # completo (la ventana se desliza, todas las Y cambian).
                    [bool] $needsScroll = ($layoutMode -eq 'Paged') -and ($hiIdx -lt $viewTop -or $hiIdx -gt $viewEnd)
                    if ($needsScroll) {
                        $full = $true
                    } else {
                        try {
                            [Console]::SetCursorPosition(0, $itemY[$old]);   Write-MultiRow -IsChecked $Checked[$old]   -Item $Items[$old]   -Hi $false
                            [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                            [Console]::SetCursorPosition(0, $legendY)
                        } catch { $full = $true }
                    }
                }
                continue
            }
            if ($key.Key -eq [ConsoleKey]::RightArrow) {
                return [PSCustomObject]@{ Action = 'open'; Checked = $Checked; HiIdx = $hiIdx }
            }
            if ($key.Key -eq [ConsoleKey]::Spacebar) {
                $buffer = ''
                $Checked[$hiIdx] = -not $Checked[$hiIdx]
                try {
                    [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                    [Console]::SetCursorPosition(0, $legendY)
                } catch { $full = $true }
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                return [PSCustomObject]@{ Action = 'submit'; Checked = $Checked; HiIdx = $hiIdx }
            }
            if ($key.Key -eq [ConsoleKey]::Escape) {
                return [PSCustomObject]@{ Action = 'cancel'; Checked = $Checked; HiIdx = $hiIdx }
            }
            # Numero: marca/desmarca por posicion (1..N). Multi-digito (10-19): un
            # prefijo ambiguo ('1') mueve el highlight y espera; el numero completo
            # togglea. El no ambiguo (2-9, o el 2do digito '12') togglea al toque.
            if ([char]::IsDigit($key.KeyChar)) {
                [string] $ch = [string] $key.KeyChar
                [string[]] $cands = @()
                if ($buffer -ne '') { $cands += ($buffer + $ch) }
                $cands += $ch
                [bool] $handled = $false
                foreach ($cand in $cands) {
                    [int]  $candNum   = 0
                    [bool] $exact     = [int]::TryParse($cand, [ref] $candNum) -and $candNum -ge 1 -and $candNum -le $count
                    [bool] $hasLonger = ($candNum -ge 1 -and ($candNum * 10) -le $count)
                    if ($exact -and -not $hasLonger) {
                        [int] $idx = $candNum - 1
                        [int] $old = $hiIdx; $hiIdx = $idx
                        $Checked[$idx] = -not $Checked[$idx]
                        $buffer = ''
                        # #46: el estado (Checked) ya cambio arriba pase lo que
                        # pase con el dibujo -- si el salto se va de la ventana
                        # Paged visible, redibujo completo en vez de pintar Y viejas.
                        if (($layoutMode -eq 'Paged') -and ($hiIdx -lt $viewTop -or $hiIdx -gt $viewEnd)) {
                            $full = $true
                        } else {
                            try {
                                if ($old -ne $hiIdx) { [Console]::SetCursorPosition(0, $itemY[$old]); Write-MultiRow -IsChecked $Checked[$old] -Item $Items[$old] -Hi $false }
                                [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                                [Console]::SetCursorPosition(0, $legendY)
                            } catch { $full = $true }
                        }
                        $handled = $true; break
                    }
                    if ($hasLonger) {
                        [int] $idx = $candNum - 1
                        if ($idx -ge 0 -and $idx -lt $count) {
                            [int] $old = $hiIdx; $hiIdx = $idx
                            if (($layoutMode -eq 'Paged') -and ($hiIdx -lt $viewTop -or $hiIdx -gt $viewEnd)) {
                                $full = $true
                            } else {
                                try {
                                    if ($old -ne $hiIdx) { [Console]::SetCursorPosition(0, $itemY[$old]); Write-MultiRow -IsChecked $Checked[$old] -Item $Items[$old] -Hi $false }
                                    [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                                    [Console]::SetCursorPosition(0, $legendY)
                                } catch { $full = $true }
                            }
                        }
                        $buffer = $cand
                        $handled = $true; break
                    }
                }
                if (-not $handled) { $buffer = '' }
                continue
            }
            if ($key.KeyChar -ne [char]0) {
                [string] $kc = $key.KeyChar.ToString().ToUpperInvariant()
                if ($kc -eq 'B') { return [PSCustomObject]@{ Action = 'cancel'; Checked = $Checked; HiIdx = $hiIdx } }
                foreach ($ak in $ActionKeys) {
                    if ($kc -eq ([string]$ak).ToUpperInvariant()) {
                        return [PSCustomObject]@{ Action = $kc; Checked = $Checked; HiIdx = $hiIdx }
                    }
                }
            }
            # otras teclas: ignorar
        }
    }
    finally {
        $script:PctkBannerCompact = $false   # #99: ver Read-PctkMenuChoice
    }
}
