# Receta Multimedia — PC de entretenimiento

**Use-case**: PC usada principalmente para streaming de series, deportes y películas (Netflix, Disney+, YouTube, etc.), juego casual con Xbox/Game Pass, y reproducción de media local. El énfasis es en throughput de red, decode de hardware y estabilidad térmica.

> **Nota v2.0 (2026-05-27)**: las tres tiers (low/mid/high) se consolidaron a un solo archivo `multimedia.json`. La variante `multimedia_high` original tenía `visual_profile=Full`, que invocaba `Set-FullOptimizedVisuals` (apaga ClearType, thumbnails, drag-full-windows = "best performance"). Eso contradice el use-case multimedia (preview de pelis/streams quiere ClearType y thumbnails ON). Fixeado: `Balanced` para todos los casos. La diferenciación por hardware vive en el módulo `Performance`.

## Lógica de la receta

Multimedia difiere de Generic y Work en un punto clave: **Xbox se preserva**. En PCs de entretenimiento, los servicios Xbox no son bloat — son funcionalidad activa. Xbox Game Bar se usa para game streaming; la app de Xbox funciona como hub de media; XblAuthManager autentica la cuenta de Microsoft para acceder al contenido. Deshabilitar Xbox en una PC multimedia rompe exactamente lo que el cliente usa.

Tres factores de optimización para streaming: throughput de red estable (sin competencia de procesos background), decode de hardware no interrumpido (DXVA2/D3D11VA funcionando correctamente), y temperatura controlada para evitar throttle durante sesiones largas de video. La receta ataca todos desde el lado de servicios y performance sin tocar lo que el usuario usa activamente.

El nivel Medium de privacidad apaga telemetría y Bing (que consume ancho de banda en background) pero preserva las apps de Xbox. El `.cfg` `multimedia.cfg` es una variante del Medium genérico con la diferencia específica de preservar las apps de Xbox — si se usara `medium.cfg` estándar, podría deshabilitar funcionalidades de la cuenta Xbox.

## Servicios deshabilitados

| Servicio | Nombre | Por qué |
|----------|--------|---------|
| `Fax` | Servicio de fax | Obsoleto |
| `WMPNetworkSvc` | WMP Network Sharing | Obsoleto (no confundir con Xbox) |
| `RemoteRegistry` | Registro remoto | Vector de ataque sin uso legítimo |
| `DiagTrack` | Telemetría diagnóstica | Consume ancho de banda en background — afecta streaming |
| `dmwappushservice` | WAP Push | Componente de telemetría |

## Servicios preservados (explícito)

- **Xbox × 4** (`XblAuthManager`, `XblGameSave`, `XboxNetApiSvc`, `XboxGipSvc`): game streaming, juego casual, app Xbox como hub de media. Deshabilitarlos rompería exactamente lo que el cliente usa en una PC multimedia.
- **Spooler / PrintNotify**: neutral — no se asume impresión, pero tampoco se rompe si existe.
- **RemoteAccess**: neutral — no se asume VPN.

## Performance

Perfil visual **Balanced**. Balanced conserva ClearType + thumbnails (preview de archivos de video importa). El módulo Performance aplica además los ajustes laptop-aware habituales por hardware.

## Privacidad

Nivel **Medium** con `multimedia.cfg`. Apaga telemetría, Bing y Activity History; preserva apps y servicios de Xbox (esa preservación es específica del perfil OOSU10 curado, no se replica con tweaks nativos). Aplica `data/oosu10-profiles/multimedia.cfg` vía OOSU10. Si `OOSU10.exe` no está en `tools\bin\`, el toolkit lo descarga automáticamente y aplica el perfil. Si la descarga falla, la privacy step se reporta como "NO aplicada" y el perfil sigue con el resto — la preservación de Xbox requiere OOSU10 específicamente.

El `.cfg` `multimedia.cfg` es un entregable manual distinto de `medium.cfg`: la diferencia está en las opciones de Xbox apps que `multimedia.cfg` preserva activas.

## Cleanup

Limpieza de temporales: `%TEMP%`, `C:\Windows\Temp`, Prefetch. En PCs multimedia esto libera espacio que puede ir a caché de streaming o downloads.

## Cuándo usar Multimedia

- PC del living room o habitación usada principalmente para ver series/películas.
- PC donde el cliente usa Netflix, Disney+, YouTube, Prime Video como actividad principal.
- PC con Xbox Game Pass o game streaming activo.
- PC de entretenimiento donde Xbox/gaming casual importa más que la optimización de trabajo.

## Cuándo NO usar Multimedia

- PC de gaming intensivo optimizado (entrada #10 del backlog: perfil gaming dedicado pendiente).
- PC donde el cliente claramente no usa Xbox ni streaming — en ese caso Generic o Work son más apropiados.
