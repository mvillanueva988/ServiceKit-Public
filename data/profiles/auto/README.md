# `data/profiles/auto/`

Recetas pre-fabricadas que vienen en el ZIP del toolkit. Las consume el engine en `core/ProfileEngine.ps1` (use-case elegido por Mateo desde el menú [1]).

## Esquema (v2.0, 2026-05-27)

`<use-case>.json` (sin tier en el nombre):

```
generic.json
work.json
multimedia.json
```

3 archivos = 3 use-cases distinguibles. El tier de hardware (Low/Mid/High) detectado por `Get-MachineProfile` NO afecta qué archivo se carga; la diferenciación por hardware la aplica el módulo `Performance` al ejecutarse (laptop vs desktop por chassis, `SvcHostSplitThreshold` si RAM ≤ 8 GB, hibernación off, GameDVR off, shutdown timeout, etc.).

## Cambio desde v1.0 (mayo 2026)

En v1.0 había 12 archivos (`<use_case>_<tier>.json` con 4 use-cases × 3 tiers). El audit 2026-05-27 (`_local-dev/recipes-audit.md`) demostró que:

- 11 de 12 tenían contenido funcional idéntico (todos `visual_profile=Balanced`, mismos services por use-case, misma cfg). El único distinto era `multimedia_high` con `visual_profile=Full`, contraintuitivo al use-case (apagaba ClearType + thumbnails en una PC de streaming) — fixeado a Balanced.
- `office_*` y `study_*` (6 archivos) eran runtime-idénticos. Fusionados a `work.json`.
- El tier sólo se usaba para validación de schema y display en preview, no condicionaba ningún tweak en el JSON (los bloques `power_plan` y `system_tweaks` estaban como `_future: true` y nunca se implementaron).

Resultado: 12 → 3 archivos. Schema bumpeado a `_schema_version: "2.0"`. `_tier` removido. Whitelist `_use_case`: `generic|work|multimedia|named`.

## Recetas nombradas

Las recetas "nombradas" (rama Stage 4 / gaming personalizado) viven en `data/profiles/named/` y usan `_use_case: "named"`. Comparten el mismo schema v2.0.

## Efecto sobre `output/clients/*/meta.json`

El `meta.json` que escribe `Invoke-AutoProfile` hereda `schema_version` del recipe aplicado. Post v2.0, los `meta.json` nuevos llevan `schema_version: "2.0"`. Las 11 keys del meta.json (`client`, `date`, `computer_name`, `anydesk_id`, `tier`, `use_case`, `schema_version`, `compare_score`, `status`, `amount_charged_ars`, `notes`) **NO cambian** — solo el label. Los `meta.json` históricos con `schema_version: "1.0"` y `use_case: office`/`study` siguen siendo legibles (son audit del pasado, inmutables).
