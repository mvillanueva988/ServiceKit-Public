# `data/oosu10-profiles/`

Perfiles XML de O&O ShutUp10++ que el operador arma una vez y commitea acá. La rama auto y la rama nombrada los aplican via `OOSU10.exe <path> /quiet` (sintaxis real de OOSU10++; el `.cfg` va como primer argumento). Si el `.cfg` no existe, el toolkit cae al perfil de privacidad nativo (sin error).

Archivos que consumen las recetas (nombre EXACTO, minúscula, en esta carpeta):

- `basic.cfg`      — telemetría, advertising ID, Bing, feedback, activity feed. Usado por: `generic.json`.
- `medium.cfg`     — basic + ubicación global, experiencias personalizadas, sugerencias de inicio. Usado por: `work.json` (fusión v2.0 de los antiguos `office_*` + `study_*`).
- `multimedia.cfg` — perfil orientado a streaming/multimedia, preserva Xbox apps. Usado por: `multimedia.json`. **Requerido** para que la receta multimedia preserve Xbox correctamente.
- `aggressive.cfg` — medium + OneDrive policy, Edge startup/background, consumer features, WER. Usado solo por la rama nombrada nivel `aggressive` (`data/profiles/named/_sample.json`); opcional si no se usa ese nivel.

Se generan abriendo OOSU10 en una VM limpia, marcando los toggles deseados, y exportando con `File → Export configuration`.
