# `data/oosu10-profiles/`

Perfiles XML de O&O ShutUp10++ que el operador arma una vez y commitea acá. La rama auto y la rama nombrada los aplican via `OOSU10.exe /quiet /ofile=<path>`.

Stage 2 propone tres niveles:

- `basic.cfg`       — telemetría, advertising ID, Bing, feedback, activity feed.
- `medium.cfg`      — basic + ubicación global, experiencias personalizadas, sugerencias de inicio.
- `aggressive.cfg`  — medium + OneDrive policy, Edge startup/background, consumer features, WER.

Se generan abriendo OOSU10 en una VM limpia, marcando los toggles deseados, y exportando con `File → Export configuration`.
