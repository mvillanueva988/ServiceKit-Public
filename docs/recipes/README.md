# Recetas de Optimización — Índice

PCTk organiza la optimización en **recetas**: archivos JSON que declaran exactamente qué hace el toolkit para cada use-case. Este directorio documenta el contenido y la lógica de cada receta.

> **v2.0 (2026-05-27)**: las recetas auto se consolidaron de 12 archivos (4 use-cases × 3 tiers) a 3 (uno por use-case). El `_tier` ya no vive en el JSON — la diferenciación por hardware vive en los módulos `Performance` y `Debloat` al ejecutarse (laptop vs desktop por chassis, `SvcHostSplitThreshold` si RAM ≤ 8 GB, etc.). Office y Study (que eran idénticos en runtime) se fusionaron a `work`.

## Filosofía

**Optimización sin formatear.** El toolkit nunca toca el OS instalado (sin wipe, sin clean install, sin migración LTSC). Trabaja con lo que hay. El objetivo es entregar resultado tangible en 30-60 minutos sin reinstalar nada.

PCTk orquesta tools terceras maduras (OOSU10 para privacy con `.cfg` curados, futuras herramientas de cleanup/debloat) + snapshots + audit + reportes. No es autor de tweaks hardcoded.

## Cómo leer las recetas

Cada receta tiene:

- **Use-case**: qué tipo de cliente usa esa PC (`generic`, `work`, `multimedia`).
- **Servicios a deshabilitar**: lista explícita (lo que NO está en la lista no se toca).
- **Perfil visual**: `Balanced` (conserva ClearType, thumbnails, sombras útiles).
- **Nivel de privacidad**: `basic` (mínimo, no toca OneDrive) o `medium` (baja telemetría, Bing, feedback y activity history).
- **OOSU10 cfg**: nombre del `.cfg` aplicado vía OOSU10. Si OOSU10.exe no está, el toolkit lo descarga automáticamente; si la descarga falla, la step se reporta como "NO aplicada" y el perfil sigue.
- **Cleanup**: limpieza de temporales (`%TEMP%`, `C:\Windows\Temp`, Prefetch).
- **Startup**: en v2.0 siempre report-only (lista los items de inicio sin deshabilitarlos automáticamente).

## Use-cases disponibles

| Use-case | Doc | OOSU cfg | Xbox |
|----------|-----|----------|------|
| Generic — PC sin contexto de uso claro | [generic.md](generic.md) | basic.cfg | preservado |
| Work — trabajo (oficina o estudio) | [work.md](work.md) | medium.cfg | deshabilitado |
| Multimedia — streaming y entretenimiento | [multimedia.md](multimedia.md) | multimedia.cfg | preservado |

Pendiente (backlog #10): **Gaming** — perfil dedicado con `gaming.cfg` que preserve Microsoft Store + Xbox + Windows Update.

## Estructura de archivos

Las recetas viven en `data/profiles/auto/<use_case>.json` (sin tier en el nombre desde v2.0). Son legibles a mano y documentadas con campos `_description` y `_rationale`. El engine (`core/ProfileEngine.ps1`) las carga, valida el schema (v2.0) y orquesta los módulos existentes.

## OOSU10 — privacidad extendida

Los archivos `.cfg` de ShutUp10++ (`basic.cfg`, `medium.cfg`, `multimedia.cfg`, `aggressive.cfg`) viven en `data/oosu10-profiles/`. El engine los aplica vía OOSU10.exe; si OOSU10 no está instalado, el toolkit lo descarga vía `Bootstrap-Tools.ps1 -ToolName shutup10`. Si la descarga falla, el perfil sigue con el resto y reporta la privacy step como "NO aplicada".
