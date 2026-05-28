# Receta Work — PC de trabajo (oficina o estudio)

**Use-case**: PC usada principalmente para tareas productivas: Office (Word/Excel/PowerPoint), Outlook, Teams, browser pesado, videollamadas, descarga de PDFs, impresión de documentos. Cubre tanto el escenario "oficina administrativa" como "estudiante". El cliente puede usar VPN. **No es PC de juego.**

> **Nota v2.0 (2026-05-27)**: esta receta consolida los antiguos `office` y `study`, que en runtime eran funcionalmente idénticos (mismos servicios, misma privacy, mismo visual). La fusión limpia la deuda interna del modelo 4×3 sin afectar el comportamiento.

## Lógica de la receta

Work prioriza tres cosas: respuesta del sistema en tareas con muchas ventanas abiertas, estabilidad de batería en laptops (la mayoría de las PCs de trabajo son notebooks), y limpieza de servicios que consumen recursos sin aporte real para trabajo productivo. Xbox no aporta a este contexto; su deshabilitación es intencional y documentada.

Los servicios Xbox consumen recursos de autenticación y sincronización en background incluso cuando el usuario no usa la cuenta Xbox — en PCs de trabajo esto es puro ruido. El nivel de privacidad Medium apaga telemetría más agresiva que Basic, incluyendo Bing en el menú de inicio y Activity History, sin tocar OneDrive o funcionalidades de Microsoft 365.

## Servicios deshabilitados

| Servicio | Nombre | Por qué |
|----------|--------|---------|
| `Fax` | Servicio de fax | Obsoleto |
| `WMPNetworkSvc` | WMP Network Sharing | Obsoleto |
| `RemoteRegistry` | Registro remoto | Vector de ataque sin uso legítimo |
| `DiagTrack` | Telemetría diagnóstica | Consume red y disco en background |
| `dmwappushservice` | WAP Push | Componente de telemetría |
| `XblAuthManager` | Xbox Live Auth | Autenticación Xbox — sin uso en PC de trabajo |
| `XblGameSave` | Xbox Live Game Save | Sincronización de guardados — sin uso en PC de trabajo |
| `XboxNetApiSvc` | Xbox Live Networking | Networking Xbox — sin uso en PC de trabajo |
| `XboxGipSvc` | Xbox Accessory Management | Control de accesorios Xbox — sin uso en PC de trabajo |

## Servicios preservados (explícito)

- **Spooler / PrintNotify**: la oficina/estudiante imprime documentos y trabajos. Son críticos para la funcionalidad de impresión.
- **RemoteAccess**: preservado para VPN corporativa. Deshabilitarlo cortaría conexiones VPN basadas en RAS (incluyendo algunas VPNs de Windows nativas y Cisco).

## Performance

Perfil visual **Balanced**. Para trabajo productivo, Balanced es el perfil correcto incluso en hardware alto — los efectos visuales Full no aportan productividad y solo consumen GPU innecesariamente en notebooks. El módulo `Performance` aplica además los ajustes laptop-aware habituales (plan de energía por chassis, svchost si RAM ≤ 8 GB, GameDVR off, shutdown timeout reducido). La diferenciación por hardware vive en el código del módulo, no en el JSON.

## Privacidad

Nivel **Medium**. Más estricto que Generic. Apaga telemetría, Bing en el menú de inicio, feedback de Microsoft y Activity History. No toca OneDrive (puede ser crítico para Microsoft 365). Aplica `data/oosu10-profiles/medium.cfg` vía OOSU10. Si `OOSU10.exe` no está en `tools\bin\`, el toolkit lo descarga automáticamente (vía `Bootstrap-Tools.ps1`, tool `shutup10`) y aplica el perfil. Si la descarga falla, la privacy step se reporta como "NO aplicada" y el perfil sigue con el resto.

## Cleanup

Limpieza de temporales: `%TEMP%`, `C:\Windows\Temp`, Prefetch.

## Cuándo usar Work

- PC de trabajo con Office/Outlook/Teams como apps principales.
- PC de estudiante con browser pesado, Zoom/Meet, descarga de PDFs.
- PC corporativa con VPN.
- Notebook donde la batería importa.
- PC que tiene Xbox instalado pero el cliente claramente no juega ni usa Game Pass.
