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

function Read-PctkMenuChoice {
    <#
    .SYNOPSIS
        Lee una opcion del menu hibrido: flechas/Enter en consola interactiva,
        fallback a Read-Host si no hay consola real (headless, smoke, redirigido).
        Devuelve la Key (string uppercase) identica al $choice original.
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
        foreach ($row in $Rows) {
            if ($row.Kind -eq 'Spacer') { Write-Host ''; continue }
            if ($row.Kind -eq 'Header') { Write-Host $row.Label -ForegroundColor DarkCyan; continue }
            if (-not [string]::IsNullOrEmpty([string]$row.Color)) {
                Write-Host $row.Label -ForegroundColor ([string]$row.Color)
            } else {
                Write-Host $row.Label
            }
        }
        Write-Host ''
        return (Read-Host $Prompt).Trim().ToUpperInvariant()
    }

    # Modo interactivo: flechas arriba/abajo + Enter + atajos directos por char
    [int] $hiIdx = 0

    while ($true) {
        & $RenderHeader
        [int] $itemIdx = 0
        foreach ($row in $Rows) {
            if ($row.Kind -eq 'Spacer') { Write-Host ''; continue }
            if ($row.Kind -eq 'Header') { Write-Host $row.Label -ForegroundColor DarkCyan; continue }
            [bool] $hi = ($itemIdx -eq $hiIdx)
            $itemIdx++
            [string] $rowLabel = [string]$row.Label
            if ($hi) {
                Write-Host ('> ' + $rowLabel.TrimStart()) -BackgroundColor DarkGray -ForegroundColor White
            } elseif (-not [string]::IsNullOrEmpty([string]$row.Color)) {
                Write-Host ('  ' + $rowLabel.TrimStart()) -ForegroundColor ([string]$row.Color)
            } else {
                Write-Host ('  ' + $rowLabel.TrimStart())
            }
        }
        Write-Host ''
        Write-Host '  Usa flechas + Enter, o la tecla del atajo:' -ForegroundColor DarkGray

        $key = $null
        try {
            $key = [Console]::ReadKey($true)
        } catch {
            # ReadKey fallo (host sin consola real) -> fallback a Read-Host
            & $RenderHeader
            foreach ($row in $Rows) {
                if ($row.Kind -eq 'Spacer') { Write-Host ''; continue }
                if ($row.Kind -eq 'Header') { Write-Host $row.Label -ForegroundColor DarkCyan; continue }
                if (-not [string]::IsNullOrEmpty([string]$row.Color)) {
                    Write-Host $row.Label -ForegroundColor ([string]$row.Color)
                } else {
                    Write-Host $row.Label
                }
            }
            Write-Host ''
            return (Read-Host $Prompt).Trim().ToUpperInvariant()
        }

        if ($null -eq $key) { continue }

        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            $hiIdx = if ($hiIdx -le 0) { $items.Count - 1 } else { $hiIdx - 1 }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::DownArrow) {
            $hiIdx = if ($hiIdx -ge ($items.Count - 1)) { 0 } else { $hiIdx + 1 }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            return [string]$items[$hiIdx].Key
        }
        # Atajo directo: char imprimible que coincida con una Key -> devolver sin Enter
        if ($key.KeyChar -ne [char]0) {
            [string] $kc = $key.KeyChar.ToString().ToUpperInvariant()
            foreach ($item in $items) {
                if ([string]$item.Key -eq $kc) { return $kc }
            }
        }
        # Ignorar Esc, F-keys y otros chars sin match
    }
}
