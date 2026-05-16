# Recetas de Optimización — Índice

PCTk v2.0.0 organiza la optimización en **recetas**: archivos JSON que declaran exactamente qué hace el toolkit para cada use-case y tier de hardware. Este directorio documenta el contenido y la lógica de cada receta.

## Filosofía

**Optimización sin formatear.** El toolkit nunca toca el OS instalado (sin wipe, sin clean install, sin migración LTSC). Trabaja con lo que hay. El objetivo es entregar resultado tangible en 30-60 minutos sin reinstalar nada.

El consenso de investigación técnica (cuatro documentos internos de referencia sobre optimización Windows, gaming rigs y entornos de oficina) apunta a las mismas categorías de mejora: servicios innecesarios activos, plan de energía no adecuado al hardware, telemetría que consume recursos de red/disco en background, y settings de privacidad que no aportan al usuario. Las recetas implementan exactamente eso — nada más.

## Cómo leer las recetas

Cada receta tiene:

- **Use-case**: qué tipo de cliente usa esa PC (`generic`, `office`, `study`, `multimedia`).
- **Tier**: nivel de hardware detectado (`low`, `mid`, `high`).
- **Servicios a deshabilitar**: lista explícita (lo que NO está en la lista no se toca).
- **Perfil visual**: `Balanced` (conserva ClearType, thumbnails, sombras útiles) o `Full` (habilita todos los efectos — solo en hardware High con GPU dedicada que los absorbe sin costo).
- **Nivel de privacidad**: `basic` (mínimo, no toca OneDrive) o `medium` (baja telemetría, Bing, feedback y activity history).
- **OOSU10 cfg**: nombre del `.cfg` opcional. Si OOSU10.exe o el `.cfg` no están, el engine aplica el perfil nativo equivalente sin interrupción.
- **Cleanup**: limpieza de temporales (`%TEMP%`, `C:\Windows\Temp`, Prefetch).
- **Startup**: en v2.0 siempre report-only (lista los items de inicio sin deshabilitarlos automáticamente).

## Use-cases disponibles

| Use-case | Doc |
|----------|-----|
| Generic — PC sin contexto de uso claro | [generic.md](generic.md) |
| Office — trabajo administrativo | [office.md](office.md) |
| Study — estudiante | [study.md](study.md) |
| Multimedia — streaming y entretenimiento | [multimedia.md](multimedia.md) |

## Estructura de archivos

Las recetas viven en `data/profiles/auto/<use_case>_<tier>.json`. Son legibles a mano y documentadas con campos `_description` y `_rationale`. El engine (`core/ProfileEngine.ps1`) las carga, valida el schema y orquesta los módulos existentes.

## OOSU10 — privacidad extendida (opcional)

Los archivos `.cfg` de ShutUp10++ (`basic.cfg`, `medium.cfg`, `multimedia.cfg`) permiten aplicar privacidad más fina que el perfil nativo. Son deliverables manuales — no están incluidos en el ZIP de distribución. El engine detecta su presencia y los usa si están; si no, cae al nativo. Ver `data/oosu10-profiles/` una vez que Mateo los genere con OOSU10.exe.
