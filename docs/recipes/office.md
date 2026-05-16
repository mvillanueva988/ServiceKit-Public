# Receta Office — PC de trabajo administrativo

**Use-case**: PC usada principalmente para Office (Word/Excel/PowerPoint), Outlook, Teams, y herramientas de productividad corporativas. Cliente que imprime documentos y puede usar VPN. **No es PC de juego.**

## Lógica de la receta

Office prioriza tres cosas: respuesta del sistema en tareas con muchas ventanas abiertas, estabilidad de batería en laptops (la mayoría de las PCs de oficina son notebooks), y limpieza de servicios que consumen recursos sin aporte real para trabajo administrativo. Xbox no aporta a este contexto; su deshabilitación es intencional y documentada.

La investigación de referencia sobre optimización de PCs de trabajo destaca que los servicios Xbox consumen recursos de autenticación y sincronización en background incluso cuando el usuario no usa la cuenta Xbox — en PCs de oficina esto es puro ruido. El nivel de privacidad Medium apaga telemetría más agresiva que Basic, incluyendo Bing en el menú de inicio y Activity History, sin tocar OneDrive o funcionalidades de Microsoft 365.

## Servicios deshabilitados

| Servicio | Nombre | Por qué |
|----------|--------|---------|
| `Fax` | Servicio de fax | Obsoleto |
| `WMPNetworkSvc` | WMP Network Sharing | Obsoleto |
| `RemoteRegistry` | Registro remoto | Vector de ataque sin uso legítimo |
| `DiagTrack` | Telemetría diagnóstica | Consume red y disco en background |
| `dmwappushservice` | WAP Push | Componente de telemetría |
| `XblAuthManager` | Xbox Live Auth | Autenticación Xbox — sin uso en PC de oficina |
| `XblGameSave` | Xbox Live Game Save | Sincronización de guardados — sin uso en PC de oficina |
| `XboxNetApiSvc` | Xbox Live Networking | Networking Xbox — sin uso en PC de oficina |
| `XboxGipSvc` | Xbox Accessory Management | Control de accesorios Xbox — sin uso en PC de oficina |

## Servicios preservados (explícito)

- **Spooler / PrintNotify**: la oficina imprime. Son críticos para la funcionalidad de impresión.
- **RemoteAccess**: preservado para VPN corporativa. Deshabilitarlo cortaría conexiones VPN basadas en RAS (incluyendo algunas VPNs de Windows nativas y Cisco).

## Performance

Perfil visual **Balanced** en los tres tiers. Para Office, Balanced es el perfil correcto incluso en High — los efectos visuales Full no aportan productividad y solo consumen GPU innecesariamente en notebooks. El módulo Performance aplica además los ajustes laptop-aware habituales (plan de energía por chassis, svchost si ≤ 8 GB, GameDVR off, shutdown timeout reducido).

## Privacidad

Nivel **Medium**. Más estricto que Generic. Apaga telemetría, Bing en el menú de inicio, feedback de Microsoft y Activity History. No toca OneDrive (puede ser crítico para Microsoft 365). Si OOSU10.exe + `data/oosu10-profiles/medium.cfg` están disponibles, aplica ese perfil; si no, aplica `Start-PrivacyJob -Profile Medium` (registry nativo).

El `.cfg` Medium es un entregable manual — no está incluido en el ZIP de distribución. El engine detecta su ausencia y cae al nativo sin interrupción.

## Cleanup

Limpieza de temporales: `%TEMP%`, `C:\Windows\Temp`, Prefetch.

## Diferencias por tier

Los tres JSONs de Office (`office_low`, `office_mid`, `office_high`) son funcionalmente idénticos en cuanto a servicios y privacidad — la diferencia real entre tiers la aplica el módulo Performance (power plan, svchost), no el JSON.

| Tier | Escenario típico |
|------|-----------------|
| Low | Notebook de oficina vieja (Celeron/i5 U ≤ 8 GB) — mayor impacto de la consolidación de svchost |
| Mid | HP/Dell/Lenovo con i7-U y 16 GB — el escenario más común de oficina |
| High | Workstation o desktop de oficina con hardware sobrado |

## Cuándo usar Office

- PC de trabajo con Office/Outlook/Teams como apps principales.
- PC corporativa con VPN.
- Notebook de oficina donde la batería importa.
- PC que tiene Xbox instalado pero el cliente claramente no juega.
