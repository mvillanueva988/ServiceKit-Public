# `data/profiles/auto/`

Recetas pre-fabricadas que vienen en el ZIP del toolkit. Se popula en Stage 2/3.

Esquema: `<use-case>_<tier>.json`

```
generic_low.json    generic_mid.json    generic_high.json
office_low.json     office_mid.json     office_high.json
study_low.json      study_mid.json      study_high.json
multimedia_low.json multimedia_mid.json multimedia_high.json
```

Stage 1 deja la carpeta vacía intencionalmente — el `ProfileEngine` se construye en Stage 2.
