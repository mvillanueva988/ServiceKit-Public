# --- Get-HvciAntiCheatNotice --------------------------------------------------
# Unica fuente del aviso anti-cheat al apagar HVCI (#27a / #87). La usan el
# [A][12] [D] (Invoke-ActionCoreIsolation) y el preview de recetas nombradas
# (Get-NamedProfilePreviewLines), asi las dos copias no se desincronizan. Cada
# llamador le pone su prefijo/indentacion y lo que es propio de su camino (como
# se revierte). ASCII puro: se pinta en consola CP850.
function Get-HvciAntiCheatNotice {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]] @(
        'Juegos con anti-cheat a nivel kernel (Valorant/Vanguard, FACEIT, EasyAntiCheat, BattlEye):',
        'algunos exigen Memory Integrity / VBS activos y pueden dejar de abrir si se apaga.',
        'Preguntale al cliente a que juega antes de seguir.'
    )
}
