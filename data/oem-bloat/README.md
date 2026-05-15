# `data/oem-bloat/`

Catálogos JSON de bloat por fabricante. El path lo construye
`core/MachineProfile.ps1` a partir del manufacturer detectado, ej:

```
data/oem-bloat/hp.json
data/oem-bloat/lenovo.json
data/oem-bloat/dell.json
data/oem-bloat/asus.json
data/oem-bloat/samsung.json
```

Cuando una receta auto de Stage 2/3 invoca `Disable-BloatServices`, además de la lista canónica de servicios deshabilitados puede consultar este catálogo para extender la lista con OEM-specific (ej. `HP Wolf Security`, `Lenovo Vantage Service`, etc.).

Schema propuesto:

```json
{
  "_manufacturer": "HP",
  "services_to_disable": ["HPSurfScanSvc", "..."],
  "uwp_to_remove":       ["HP.JumpStart", "..."],
  "win32_to_uninstall":  ["HP Support Assistant"]
}
```

Stage 2+ popula estos archivos a medida que se identifican bloat catalogs reales.
