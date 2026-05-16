# Receta Generic — PC sin contexto de uso claro

**Use-case**: PC que llega al servicio técnico sin información clara de para qué la usa el cliente. Puede ser de oficina, estudio, gaming casual o doméstico. La receta es neutra y conservadora — limpia lo inequívoco y no toca nada que asuma conocer el uso.

## Lógica de la receta

La receta Generic es el piso de seguridad del toolkit: aplica solo lo que no puede romper nada, independientemente de lo que haga el cliente con la PC. No se asume si imprime (Spooler/PrintNotify intactos), si juega (Xbox intacto), si usa VPN (RemoteAccess intacto) ni si tiene OneDrive activo (nivel Basic no lo toca).

La investigación de referencia identifica como bloat inequívoco en cualquier instalación de Windows: el servicio de fax (nunca usado en PCs modernas), WMPNetworkSvc (streaming obsoleto), RemoteRegistry (vector de ataque sin uso real en PCs domésticas/de servicio), DiagTrack y dmwappushservice (telemetría de Microsoft que consume red y disco en background). Estos cinco servicios son la base común de todas las recetas.

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

Perfil visual **Balanced** en los tres tiers. Balanced conserva ClearType, miniaturas y sombras de ventana — efectos que el usuario nota si desaparecen. El módulo Performance aplica además, de forma automática, ajustes laptop-aware: plan de energía según tipo de chassis (laptop vs desktop), consolidación de svchost si RAM ≤ 8 GB, hibernación desactivada, GameDVR desactivado, shutdown timeout reducido.

En laptops con TDP limitado por EC, el toolkit **no** aplica Ultimate Performance (contraproducente — fuerza frecuencia sostenida máxima → más calor → throttle agresivo). Aplica Balanced, que en la mayoría de las laptops de oficina y estudio es el plan correcto.

## Privacidad

Nivel **Basic** (más suave). No toca OneDrive, no deshabilita Bing en el menú de inicio. Si OOSU10.exe + `data/oosu10-profiles/basic.cfg` están disponibles, aplica ese perfil. Si no, aplica `Start-PrivacyJob -Profile Basic` (registry HKCU/HKLM nativo). El resultado es equivalente a deshabilitar las opciones de diagnóstico y retroalimentación en Configuración de Windows, sin tocar funcionalidades que el usuario puede usar activamente.

## Cleanup

Limpieza de temporales: `%TEMP%` del usuario, `C:\Windows\Temp`, Prefetch. No toca caché de browsers (posible pérdida de datos del usuario).

## Diferencias por tier

| Tier | Diferencia funcional |
|------|---------------------|
| Low | `Start-PerformanceProcess` consolida svchost (RAM ≤ 8 GB) — ya incluido en el módulo |
| Mid | Igual que Low pero sin consolidación de svchost si RAM > 8 GB |
| High | Igual que Mid; en hardware High con GPU dedicada el perfil Balanced es incluso más conservador de lo necesario, pero Generic no asume gaming |

La diferencia real entre tiers la decide el módulo Performance, no el JSON de la receta. Los tres JSONs (`generic_low`, `generic_mid`, `generic_high`) son funcionalmente idénticos — el tier está documentado en el JSON para trazabilidad en el log de ejecución.

## Cuándo usar Generic

- PC que llega "no anda bien" sin más contexto.
- PC de familiar de cliente sin información de uso.
- Primera pasada antes de profundizar (Generic es reversible vía Restore Point automático).
- Cualquier caso donde no se sabe si el cliente imprime, usa VPN o juega con Game Pass.
