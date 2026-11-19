# `data/`

Data assets que viajan con el toolkit en el ZIP de release.

## Estructura

```
data/
├── profiles/
│   ├── auto/    ← recetas pre-fabricadas (versionado)
│   └── named/   ← recetas del operador (gitignored)
├── oosu10-profiles/
│   └── *.cfg    ← perfiles XML de O&O ShutUp10++ por nivel de privacidad
├── paquete-campo.json  ← tools que el service guiado premarca en [T]
└── oem-bloat/
    └── *.json   ← catálogos de bloat por fabricante (HP/Lenovo/Dell/etc.)
```

## Cuándo se popula cada carpeta

- `profiles/auto/` — Stage 2/3. 3 recetas, una por use-case (`generic`, `work`, `multimedia`); el tier no elige archivo (ver `profiles/auto/README.md`).
- `paquete-campo.json` — las tools que el paso 4 del service guiado (`[1]`) premarca en `[T]`; ids de `tools/manifest.json`.
- `profiles/named/` — el operador vía `[N] Receta nombrada` en Stage 4. Gitignored.
- `oosu10-profiles/` — Stage 2. El operador arma los `.cfg` una vez con OOSU10 GUI y los commitea.
- `oem-bloat/` — Stage 2+. Catálogos opcionales referenciados por `core/MachineProfile.ps1::OemCatalogPath`.
