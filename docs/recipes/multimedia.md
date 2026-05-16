# Receta Multimedia — PC de entretenimiento

**Use-case**: PC usada principalmente para streaming de series, deportes y películas (Netflix, Disney+, YouTube, etc.), juego casual con Xbox, y reproducción de media local. El énfasis es en throughput de red, decode de hardware y estabilidad térmica.

## Lógica de la receta

Multimedia difiere del resto en un punto clave: **Xbox se preserva**. En PCs de entretenimiento, los servicios Xbox no son bloat — son funcionalidad activa. Xbox Game Bar se usa para game streaming; la app de Xbox funciona como hub de media; XblAuthManager autentica la cuenta de Microsoft para acceder al contenido. Deshabilitar Xbox en una PC multimedia rompe exactamente lo que el cliente usa.

La investigación de referencia sobre optimización para streaming destaca tres factores: throughput de red estable (sin competencia de procesos background), decode de hardware no interrumpido (DXVA2/D3D11VA funcionando correctamente), y temperatura controlada para evitar throttle durante sesiones largas de video. La receta ataca todos desde el lado de servicios y performance sin tocar lo que el usuario usa activamente.

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

| Tier | Perfil visual | Por qué |
|------|--------------|---------|
| Low | Balanced | Hardware insuficiente para Full sin impacto en decode |
| Mid | Balanced | Balanced es correcto para streaming estable en hardware medio |
| High | **Full** | Con GPU dedicada de 6+ GB VRAM los efectos visuales no compiten con decode de video; vale el eye-candy en una PC de entretenimiento de gama alta |

Full solo en High: es la única receta en la que el perfil visual varía por tier. El módulo Performance aplica además los ajustes laptop-aware habituales.

## Privacidad

Nivel **Medium** con `multimedia.cfg`. Apaga telemetría, Bing y Activity History; preserva apps y servicios de Xbox. Si OOSU10.exe + `multimedia.cfg` están disponibles, aplica ese perfil; si no, aplica `Start-PrivacyJob -Profile Medium` (fallback nativo — equivalente a Medium estándar, que es razonablemente seguro para preservar Xbox si se aplica a nivel de registry sin el perfil OOSU10 específico).

El `.cfg` `multimedia.cfg` es un entregable manual distinto de `medium.cfg`: la diferencia está en las opciones de Xbox apps que `multimedia.cfg` preserva activas.

## Cleanup

Limpieza de temporales: `%TEMP%`, `C:\Windows\Temp`, Prefetch. En PCs multimedia esto libera espacio que puede ir a caché de streaming o downloads.

## Cuándo usar Multimedia

- PC del living room o habitación usada principalmente para ver series/películas.
- PC donde el cliente usa Netflix, Disney+, YouTube, Prime Video como actividad principal.
- PC con Xbox Game Pass o game streaming activo.
- PC de entretenimiento donde Xbox/gaming casual importa más que la optimización de trabajo.

## Cuándo NO usar Multimedia

- PC de gaming intensivo optimizado (Stage 4 — perfiles nombrados, diferido).
- PC donde el cliente claramente no usa Xbox ni streaming — en ese caso Generic o Study son más apropiados.
