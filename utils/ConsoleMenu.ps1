Set-StrictMode -Version Latest

function Get-MainMenuRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    [object[]] $rows = @()
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  PERFILES';          Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '1';   Label = '  [1]  Aplicar perfil automatico         (Generic/Work/Multimedia)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '2';   Label = '  [2]  Receta nombrada                   (cliente especifico)';       Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = '';                    Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  DIAGNOSTICO';        Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '3';   Label = '  [3]  Snapshot PRE-service';             Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '4';   Label = '  [4]  Snapshot POST-service';            Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '5';   Label = '  [5]  Comparar PRE vs POST';             Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '6';   Label = '  [6]  Historial de BSOD / Crashes';      Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '7';   Label = '  [7]  Salud de discos (SMART / wear)';   Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'R';   Label = '  [R]  Generar prompt de research        (para LLM con web search)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = '';                    Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  ACCIONES MANUALES';  Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'A';   Label = '  [A]  Submenu: acciones individuales    (debloat, limpieza, rendimiento, privacidad, etc.)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = '';                    Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  HERRAMIENTAS';       Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'T';   Label = '  [T]  Herramientas externas';            Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'L';   Label = '  [L]  Empaquetar logs de esta PC  (para llevarse)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'X';   Label = '  [X]  Salir';                           Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'U';   Label = '  [U]  Desinstalar PCTk de esta PC (borra todo)'; Color = 'DarkRed' }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = '';                    Color = $null }
    return $rows
}

function Get-IndividualActionRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    [object[]] $rows = @()
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  ACCIONES INDIVIDUALES'; Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '1';   Label = '  [1]  Debloat de Servicios'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '2';   Label = '  [2]  Limpieza de Disco'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '3';   Label = '  [3]  Mantenimiento del Sistema (DISM + SFC)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '4';   Label = '  [4]  Crear Punto de Restauracion'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '5';   Label = '  [5]  Optimizar Red'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '6';   Label = '  [6]  Rendimiento (visuales + power plan + tweaks)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '7';   Label = '  [7]  Backup de Drivers'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '8';   Label = '  [8]  Apps Win32 + UWP'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '9';   Label = '  [9]  Privacidad (registry o OOSU10)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '10';  Label = '  [10] Inicio del Sistema'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '11';  Label = '  [11] Actualizaciones de Windows'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  GAMING / LATENCIA  (avanzado - reinicio salvo USB)'; Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '12';  Label = '  [12] Core Isolation / Memory Integrity (HVCI)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '13';  Label = '  [13] HAGS (GPU Scheduling por hardware)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '14';  Label = '  [14] Timer Resolution global (solo Win11)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '15';  Label = '  [15] Prioridad de proceso por .exe (IFEO)'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '16';  Label = '  [16] USB Selective Suspend'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'B';   Label = '  [B]  Volver al menu principal'; Color = 'DarkYellow' }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    return $rows
}

function Get-NamedProfileRows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    [object[]] $rows = @()
    $rows += [PSCustomObject]@{ Kind = 'Header'; Key = $null; Label = '  RECETA NOMBRADA (gaming personalizado)'; Color = 'DarkCyan' }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '1';   Label = '  [1]  Nueva'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '2';   Label = '  [2]  Cargar existente'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = '3';   Label = '  [3]  Reaplicar ultima'; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    $rows += [PSCustomObject]@{ Kind = 'Item';   Key = 'B';   Label = '  [B]  Volver'; Color = 'DarkYellow' }
    $rows += [PSCustomObject]@{ Kind = 'Spacer'; Key = $null; Label = ''; Color = $null }
    return $rows
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

    # helper local: escribe una fila (con o sin highlight). Mismo largo de texto
    # en highlight ('> ') y normal ('  ') -> reescribir una fila sobre otra no deja
    # restos, sin necesidad de padding.
    function Write-RowLine {
        param($Row, [bool] $Hi)
        if ($Row.Kind -eq 'Spacer') { Write-Host ''; return }
        [bool] $vt = Test-PctkVT
        if ($Row.Kind -eq 'Header') {
            if ($vt) {
                [string] $nm = ([string]$Row.Label).Trim()
                Write-Host ('  ' + (Pf 255 170 40) + '── ' + $nm + ' ' + ('─' * [Math]::Max(3, 50 - $nm.Length)) + (Pe))
            } else {
                Write-Host $Row.Label -ForegroundColor DarkCyan
            }
            return
        }
        [string] $label = ([string]$Row.Label).TrimStart()
        if ($Hi) {
            if ($vt) { Write-Host ((Pb 150 95 0) + (Pf 245 240 230) + '> ' + $label + (Pe)) }
            else     { Write-Host ('> ' + $label) -BackgroundColor DarkGray -ForegroundColor White }
        } elseif (-not [string]::IsNullOrEmpty([string]$Row.Color)) {
            if ($vt) {
                [string] $fg = ConvertTo-PctkAnsiFg ([string]$Row.Color)
                if ([string]::IsNullOrEmpty($fg)) { $fg = Pf 140 152 166 }
                Write-Host ($fg + '  ' + $label + (Pe))
            } else {
                Write-Host ('  ' + $label) -ForegroundColor ([string]$Row.Color)
            }
        } elseif ($vt) {
            Write-Host ((Pf 140 152 166) + '  ' + $label + (Pe))
        } else {
            Write-Host ('  ' + $label)
        }
    }

    # Gate: todas deben pasar para usar modo crudo; si falla alguna -> fallback
    [bool] $interactive = $false
    if (-not $ForceFallbackForTest) {
        try {
            $interactive = (
                [Environment]::UserInteractive -eq $true -and
                [Console]::IsInputRedirected -eq $false -and
                [Console]::IsOutputRedirected -eq $false
            )
        } catch { $interactive = $false }
    }

    if (-not $interactive -or $items.Count -eq 0) {
        # Fallback: render sin highlight + Read-Host (comportamiento original)
        & $RenderHeader
        foreach ($row in $Rows) { Write-RowLine -Row $row -Hi $false }
        Write-Host ''
        return (Read-Host $Prompt).Trim().ToUpperInvariant()
    }

    # --- Modo interactivo: redibujo surgical (sin Clear-Host por flecha) ---
    [int]   $hiIdx   = 0
    [int[]] $itemY   = [int[]]::new($items.Count)   # Y de consola de cada Item
    [int]   $bottomY = 0
    [bool]   $full   = $true                        # true -> redibujo completo este frame
    [string] $buffer = ''                           # acumulador de atajo multi-caracter (ej. 10-16)

    while ($true) {
        if ($full) {
            & $RenderHeader
            [int] $ii = 0
            foreach ($row in $Rows) {
                if ($row.Kind -eq 'Item') {
                    $itemY[$ii] = [Console]::CursorTop
                    Write-RowLine -Row $row -Hi ($ii -eq $hiIdx)
                    $ii++
                } else {
                    Write-RowLine -Row $row -Hi $false
                }
            }
            Write-Host ''
            [string] $hintLine = '  Usa flechas arriba/abajo + Enter, o la tecla del atajo:'
            if (Test-PctkVT) { Write-Host ((Pf 95 108 124) + $hintLine + (Pe)) }
            else             { Write-Host $hintLine -ForegroundColor DarkGray }
            $bottomY = [Console]::CursorTop
            $full = $false
        }

        $key = $null
        try {
            $key = [Console]::ReadKey($true)
        } catch {
            # ReadKey fallo (host sin consola real) -> fallback a Read-Host
            & $RenderHeader
            foreach ($row in $Rows) { Write-RowLine -Row $row -Hi $false }
            Write-Host ''
            return (Read-Host $Prompt).Trim().ToUpperInvariant()
        }
        if ($null -eq $key) { continue }

        if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
            $buffer = ''
            [int] $old = $hiIdx
            if ($key.Key -eq [ConsoleKey]::UpArrow) {
                $hiIdx = if ($hiIdx -le 0) { $items.Count - 1 } else { $hiIdx - 1 }
            } else {
                $hiIdx = if ($hiIdx -ge ($items.Count - 1)) { 0 } else { $hiIdx + 1 }
            }
            if ($old -ne $hiIdx) {
                try {
                    # solo las 2 filas que cambian -> cero flash
                    [Console]::SetCursorPosition(0, $itemY[$old])
                    Write-RowLine -Row $items[$old]   -Hi $false
                    [Console]::SetCursorPosition(0, $itemY[$hiIdx])
                    Write-RowLine -Row $items[$hiIdx] -Hi $true
                    [Console]::SetCursorPosition(0, $bottomY)
                } catch {
                    $full = $true   # consola rara -> redibujo completo el proximo frame
                }
            }
            continue
        }
        # Enter o flecha derecha = elegir la opcion resaltada
        if ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::RightArrow) {
            return [string]$items[$hiIdx].Key
        }
        # Atajo por tecla. Soporta keys de varios caracteres (ej. 10-16): un
        # digito ambiguo ('1') NO elige solo (es prefijo de 10-16); acumula y
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
                        try {
                            [Console]::SetCursorPosition(0, $itemY[$old]);   Write-RowLine -Row $items[$old]   -Hi $false
                            [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-RowLine -Row $items[$hiIdx] -Hi $true
                            [Console]::SetCursorPosition(0, $bottomY)
                        } catch { $full = $true }
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

    while ($true) {
        if ($full) {
            & $RenderHeader
            for ([int] $i = 0; $i -lt $count; $i++) {
                $itemY[$i] = [Console]::CursorTop
                Write-MultiRow -IsChecked $Checked[$i] -Item $Items[$i] -Hi ($i -eq $hiIdx)
            }
            Write-Host ''
            $legendY = [Console]::CursorTop
            if (Test-PctkVT) { Write-Host ((Pf 95 108 124) + $LegendLine + (Pe)) }
            else             { Write-Host $LegendLine -ForegroundColor DarkGray }
            $full = $false
        }

        $key = $null
        try { $key = [Console]::ReadKey($true) }
        catch { return [PSCustomObject]@{ Action = 'fallback'; Checked = $Checked; HiIdx = $hiIdx } }
        if ($null -eq $key) { continue }

        if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
            $buffer = ''
            [int] $old = $hiIdx
            if ($key.Key -eq [ConsoleKey]::UpArrow) { $hiIdx = if ($hiIdx -le 0) { $count - 1 } else { $hiIdx - 1 } }
            else { $hiIdx = if ($hiIdx -ge ($count - 1)) { 0 } else { $hiIdx + 1 } }
            if ($old -ne $hiIdx) {
                try {
                    [Console]::SetCursorPosition(0, $itemY[$old]);   Write-MultiRow -IsChecked $Checked[$old]   -Item $Items[$old]   -Hi $false
                    [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                    [Console]::SetCursorPosition(0, $legendY)
                } catch { $full = $true }
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
                    try {
                        if ($old -ne $hiIdx) { [Console]::SetCursorPosition(0, $itemY[$old]); Write-MultiRow -IsChecked $Checked[$old] -Item $Items[$old] -Hi $false }
                        [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                        [Console]::SetCursorPosition(0, $legendY)
                    } catch { $full = $true }
                    $handled = $true; break
                }
                if ($hasLonger) {
                    [int] $idx = $candNum - 1
                    if ($idx -ge 0 -and $idx -lt $count) {
                        [int] $old = $hiIdx; $hiIdx = $idx
                        try {
                            if ($old -ne $hiIdx) { [Console]::SetCursorPosition(0, $itemY[$old]); Write-MultiRow -IsChecked $Checked[$old] -Item $Items[$old] -Hi $false }
                            [Console]::SetCursorPosition(0, $itemY[$hiIdx]); Write-MultiRow -IsChecked $Checked[$hiIdx] -Item $Items[$hiIdx] -Hi $true
                            [Console]::SetCursorPosition(0, $legendY)
                        } catch { $full = $true }
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
