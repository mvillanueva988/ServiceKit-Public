# Receta Study — PC de estudiante

**Use-case**: PC usada principalmente para estudio: browser con muchas pestañas abiertas, Zoom/Google Meet para clases virtuales, descarga de PDFs, impresión de trabajos. **No es PC de juego.**

## Lógica de la receta

Study comparte la misma lógica que Office en cuanto a servicios: Xbox deshabilitado (no es PC de juego), Spooler/PrintNotify preservados (el estudiante imprime trabajos académicos), privacidad Medium. El énfasis distinto es el perfil de uso: el problema más común en PCs de estudiantes no es un crash sino **lentitud progresiva** — el sistema arranca rápido pero se va poniendo lento a medida que el semestre avanza (muchos programas en startup, browser con 40 pestañas, Zoom activo en background, disco casi lleno de PDFs).

La investigación de referencia identifica el startup bloat y los servicios de sincronización en background como los principales culpables de la lentitud progresiva. Study ataca exactamente eso: servicios de telemetría que consumen CPU/red, Xbox que consume recursos de auth en background, y cleanup de temporales que liberan espacio. El startup report (sin auto-disable en v2.0) le permite a Mateo mostrarle al cliente qué programas están arrancando y decidir juntos cuáles deshabilitar.

## Servicios deshabilitados

| Servicio | Nombre | Por qué |
|----------|--------|---------|
| `Fax` | Servicio de fax | Obsoleto |
| `WMPNetworkSvc` | WMP Network Sharing | Obsoleto |
| `RemoteRegistry` | Registro remoto | Vector de ataque sin uso legítimo |
| `DiagTrack` | Telemetría diagnóstica | Consume red y disco en background |
| `dmwappushservice` | WAP Push | Componente de telemetría |
| `XblAuthManager` | Xbox Live Auth | Sin uso en PC de estudio |
| `XblGameSave` | Xbox Live Game Save | Sin uso en PC de estudio |
| `XboxNetApiSvc` | Xbox Live Networking | Sin uso en PC de estudio |
| `XboxGipSvc` | Xbox Accessory Management | Sin uso en PC de estudio |

## Servicios preservados (explícito)

- **Spooler / PrintNotify**: el estudiante imprime trabajos. Son críticos.
- **RemoteAccess**: neutral (no se asume VPN de institución, pero no se rompe si existe).

## Performance

Perfil visual **Balanced** en los tres tiers. Para Study, Balanced es correcto: los efectos visuales no mejoran la productividad académica y en hardware Low (la mayoría de las notebooks de estudiante) consumen recursos que valen para el browser y Zoom. El módulo Performance aplica los ajustes laptop-aware (plan de energía por chassis, svchost si ≤ 8 GB, GameDVR off, shutdown timeout reducido).

## Privacidad

Nivel **Medium**. Igual que Office. Apaga telemetría, Bing, feedback y Activity History sin tocar OneDrive (el estudiante puede tener trabajos en OneDrive). Si `medium.cfg` está disponible, se usa; si no, el nativo.

## Cleanup

Limpieza de temporales: `%TEMP%`, `C:\Windows\Temp`, Prefetch. En PCs de estudiantes con disco casi lleno, esta limpieza es especialmente relevante (browsers y apps de estudio generan caché temporales voluminosos).

## Diferencias por tier

| Tier | Escenario típico |
|------|-----------------|
| Low | Notebook de estudiante económica (Celeron/i5 ≤ 8 GB) — el más común; mayor impacto de la limpieza y consolidación de svchost |
| Mid | Notebook media gama con i7-U/R7-U y 16 GB |
| High | Notebook gamer que el estudiante también usa para estudiar; la receta Study es más conservadora que Generic en High porque Xbox se deshabilita |

Los tres JSONs son funcionalmente idénticos en servicios y privacidad.

## Cuándo usar Study

- PC de estudiante secundario o universitario.
- PC que arranca rápido pero "se pone lenta" con el tiempo (startup bloat + telemetría).
- PC con browser como app principal + videollamadas.
- PC que tiene instalado todo lo del colegio/universidad pero no se usa para gaming.
