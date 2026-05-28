# Receta Generic — PC sin contexto de uso claro

**Use-case**: PC que llega al servicio técnico sin información clara de para qué la usa el cliente. Puede ser de oficina, estudio, gaming casual o doméstico. La receta es neutra y conservadora — limpia lo inequívoco y no toca nada que asuma conocer el uso.

> **Nota v2.0 (2026-05-27)**: las tres tiers (low/mid/high) se consolidaron a un solo archivo `generic.json`. La diferenciación por hardware (laptop vs desktop, RAM ≤ 8 GB) vive en el módulo `Performance` al ejecutarse — el JSON no la condiciona. Si el cliente tiene hardware Low, `Set-SystemTweaks` aplica `SvcHostSplitThreshold`; si es laptop, `Set-UltimatePowerPlan` fuerza Balanced; etc.

## Lógica de la receta

La receta Generic es el piso de seguridad del toolkit: aplica solo lo que no puede romper nada, independientemente de lo que haga el cliente con la PC. No se asume si imprime (Spooler/PrintNotify intactos), si juega (Xbox intacto), si usa VPN (RemoteAccess intacto) ni si tiene OneDrive activo (nivel Basic no lo toca).

Bloat inequívoco en cualquier instalación de Windows: el servicio de fax (nunca usado en PCs modernas), WMPNetworkSvc (streaming obsoleto), RemoteRegistry (vector de ataque sin uso real en PCs domésticas/de servicio), DiagTrack y dmwappushservice (telemetría de Microsoft que consume red y disco en background). Estos cinco servicios son la base común de todas las recetas.

## Servicios deshabilitados

| Servicio | Nombre | Por qué |
|----------|--------|---------|
| `Fax` | Servicio de fax | Obsoleto — no hay PC de cliente que use fax |
| `WMPNetworkSvc` | Uso compartido de red de WMP | Streaming local obsoleto (Windows Media Player Network Sharing) |
| `RemoteRegistry` | Registro remoto | Permite editar el registry por red — vector de ataque sin caso de uso legítimo en servicio técnico |
| `DiagTrack` | Telemetría diagnóstica | Envía datos de uso y diagnóstico a Microsoft en background; consume red y disco |
| `dmwappushservice` | WAP Push (telemetría) | Componente de telemetría complementario de DiagTrack |

## Servicios preservados (explícito)

- **Spooler / PrintNotify**: Generic no asume si el cliente imprime o no.
- **RemoteAccess**: no asume VPN.
- **Xbox × 4** (`XblAuthManager`, `XblGameSave`, `XboxNetApiSvc`, `XboxGipSvc`): no asume si juega con Game Pass o usa streaming de Xbox.

## Performance

Perfil visual **Balanced**. Balanced conserva ClearType, miniaturas y sombras de ventana — efectos que el usuario nota si desaparecen. El módulo Performance aplica además, de forma automática, ajustes laptop-aware: plan de energía según tipo de chassis (laptop vs desktop), consolidación de svchost si RAM ≤ 8 GB, hibernación desactivada, GameDVR desactivado, shutdown timeout reducido.

En laptops con TDP limitado por EC, el toolkit **no** aplica Ultimate Performance (contraproducente — fuerza frecuencia sostenida máxima → más calor → throttle agresivo). Aplica Balanced, que en la mayoría de las laptops de oficina y estudio es el plan correcto.

## Privacidad

Nivel **Basic** (más suave). No toca OneDrive, no deshabilita Bing en el menú de inicio. Aplica `data/oosu10-profiles/basic.cfg` vía OOSU10. Si `OOSU10.exe` no está en `tools\bin\`, el toolkit lo descarga automáticamente (vía `Bootstrap-Tools.ps1`, tool `shutup10`) y aplica el perfil. Si la descarga falla (sin internet, etc.), la privacy step se reporta como "NO aplicada" en el reporte final y el perfil sigue con el resto de los pasos — aplicala a mano después con `[A]→[O]` cuando haya internet. El resultado es equivalente a deshabilitar las opciones de diagnóstico y retroalimentación en Configuración de Windows, sin tocar funcionalidades que el usuario puede usar activamente.

## Cleanup

Limpieza de temporales: `%TEMP%` del usuario, `C:\Windows\Temp`, Prefetch. No toca caché de browsers (posible pérdida de datos del usuario).

## Cuándo usar Generic

- PC que llega "no anda bien" sin más contexto.
- PC de familiar de cliente sin información de uso.
- Primera pasada antes de profundizar (Generic es reversible vía Restore Point automático).
- Cualquier caso donde no se sabe si el cliente imprime, usa VPN o juega con Game Pass.
