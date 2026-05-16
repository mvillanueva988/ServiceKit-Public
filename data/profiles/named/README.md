# Recetas nombradas (gaming personalizado por cliente)

Las recetas que el operador crea desde el menú `[2] Receta nombrada` se guardan
acá como `<slug>.json`. **Son datos de clientes específicos: gitignored, no se
publican** (el ZIP de release tampoco las incluye — ver `Release.ps1`).

- `_sample.json` — fixture de validación (no es un cliente real); se versiona
  para que el smoke valide el schema en cada run.
- `<cualquier-otro>.json` — recetas reales de clientes; ignoradas por git.

Schema = receta auto + bloque `gaming_tweaks` (ver `_local-dev/stage4-plan.md`
y `core/NamedProfileEditor.ps1`). Los `.json` son human-readable y editables a
mano.
