# Changelog

Registro de cambios de PCTk. Formato: Keep a Changelog + SemVer.

## [2.8.0] - 2026-08-17

Release: **la clave de BitLocker deja de depender de una sola PC**. La clave de recuperación que el `[A][18][C]` captura quedaba en dos lugares frágiles: la pantalla (la foto del operador) y `output\recovery\` de la PC del cliente, que el desinstalador borra. Ahora se puede depositar, cifrada de punta a punta, en la bóveda del CRM.

**Nota de versión**: v2.7.0 quedó como tag sin release publicada (el paso de publicación no llegó a correr y nadie la instaló; la última instalable fue v2.6.0). Esta release acumula también lo de v2.7.0 — quien venga de v2.6.0 encuentra las dos secciones acá abajo.

Va como *minor* porque agrega funcionalidad, igual que el resto del changelog.

### Added

- **#41 (b) - la clave de BitLocker viaja a la bóveda del CRM (`modules/VaultUpload.ps1`, `core/ActionHandlers.ps1`, `data/vault-publica.json`)**: después de capturar la clave en `[A][18][C]`, el toolkit ofrece *"¿Depositar la clave en la bóveda del CRM? [S/n]"*.

  **La clave se cifra ANTES de salir de la PC** (RSA-OAEP-SHA256 con la clave pública de la bóveda, que viaja versionada con el toolkit y no es secreta: sólo cierra sobres). El CRM recibe un sobre cerrado que no puede abrir — la privada está cifrada con una passphrase que no viaja nunca — y lo rechaza por forma si algún bug mandara la clave en claro. Mismo token write-only y misma cuota diaria que la subida de bundles: con ese token no se puede leer nada.

  **La bóveda es una copia MÁS, no un reemplazo**: la pantalla y `output\recovery\` siguen exactamente igual, y si el depósito falla (sin internet, sin conexión configurada) el service cierra igual.

- **El paquete se lleva la comparación completa, no sólo su puntaje (`modules/ExportClientLogs.ps1`)**: `compare.json` entra al bundle del `[L]`, así el CRM lee lo que mejoró en vez de recalcularlo — dos definiciones de "qué mejoró" divergiendo en silencio era el riesgo.

### Fixed

- **#48 - el paquete pendiente dice DE CUÁNDO es (`core/Router.ps1`, `modules/ServiceState.ps1`)**: el `[L]` ofrecía subir el paquete sin subir mostrando sólo el nombre del archivo, con la fecha embebida en un formato que hay que decodificar leyendo — así se subió un paquete de hacía una semana creyendo que era el de hoy. Ahora la pregunta dice *"Es del 01/08 (hace 7 días)."* y avisa que aceptar termina ahí (no se arma un paquete nuevo). Sin fecha legible no dice nada, en vez de inventar una edad.

## [2.7.0] - 2026-08-07

Release: **el equipo se identifica y la batería se mide**. Dos datos que el toolkit mostraba en blanco o a medias, y que en los dos casos se cobran: la salud de la batería decide un cambio de $85.000, y el modelo exacto es con lo que se entra al soporte del fabricante a sacar el despiece.

Va como *minor* y no como parche porque agrega funcionalidad, igual que el resto del changelog.

### Added

- **#28 - el equipo se identifica por su nombre, no por un código (`core/MachineProfile.ps1`, `core/Router.ps1`, `modules/Telemetry.ps1`, `modules/ResearchPrompt.ps1`)**: el banner pasa de decir `Lenovo 82K2` a decir `Lenovo IdeaPad Gaming 3 15ACH6 (82K2)`.

  En Lenovo y HP el modelo del SMBIOS viene enmascarado y no alcanza para identificar el equipo: Lenovo devuelve `82K2` y HP devuelve `HP Laptop 15-fd0xxx`, donde la `xxx` es literal. Ahora se leen también `SystemSKUNumber` y `SystemFamily`, que salen de la **misma consulta que ya se hacía**: cero consultas nuevas y cero milisegundos al escaneo.

  **El código queda entre paréntesis a propósito**, porque ES lo que se tipea en el soporte del fabricante para sacar part-numbers. El nombre comercial es para saber qué equipo se tiene delante; el código, para buscar repuestos.

  El research prompt `[R]` lleva las dos cosas: con "Lenovo 82K2" un LLM busca a ciegas, con el nombre comercial encuentra el manual y el despiece. **El número de serie sigue afuera** y hay dos canarios que fallan si vuelve a aparecer: el modelo lo comparten millones de equipos, el serial identifica el del cliente.

- **Ciclos de carga de la batería en el informe técnico `[I]`**: vienen en la misma lectura que la salud, así que no cuestan nada. Van al informe técnico y **no** al reporte del cliente.

### Fixed

- **#37 - la salud de la batería sale de donde de verdad vive (`modules/Telemetry.ps1`)**: la fila "Salud" del reporte no salía **nunca** en la mayoría de las notebooks.

  No era un bug de render: faltaba el dato de origen. `Win32_Battery` devuelve las capacidades **vacías** en casi cualquier notebook, y de ahí se calculaba la salud. Es una limitación conocida de esa clase de WMI, no algo que el toolkit estuviera haciendo mal.

  Ahora se encadenan tres fuentes y se usa la primera que da un dato creíble: el namespace `root\wmi` (de donde lee `powercfg`), `powercfg /batteryreport` en su salida XML, y por último `Win32_Battery` por si algún equipo sí la completa. Medido en una notebook real: las dos primeras dieron el mismo número, 35.380 sobre 45.000 mWh.

  **Se mantiene el degradado honesto**: si no hay dato, la fila se omite. Nunca un número inventado ni un 100% por defecto. El porcentaje se acota a 100 porque una batería que carga más que su diseño está sana al 100%, y un "103%" en el reporte del cliente se lee como error del toolkit.

- **El escaneo podía romperse en equipos con dos baterías (`modules/Telemetry.ps1`)**: en una notebook con batería interna más externa, la consulta devuelve una lista y la conversión a número fallaba sobre la lista entera. Bug latente que nunca se vio en campo porque hace falta ese hardware.

- **Las notas de la release salían sin ningún SHA-256 (`Release.ps1`)**: el README manda a comparar el hash de `Launch.ps1` contra el publicado en las notas, y las notas no lo traían, así que ese paso de verificación apuntaba a la nada. El cálculo estaba bien; el problema era que el hash se imprimía en pantalla para pegarlo a mano. Ahora las notas lo llevan embebido.

### Changed

- **Los handlers de las acciones individuales salieron a su propio archivo (`core/ActionHandlers.ps1`)**: `core/Router.ps1` había llegado a 2.737 líneas y 42 funciones, mezclando el dibujo del menú, el despacho y los handlers de las 19 acciones `[A]`. Los handlers eran más de la mitad, así que el archivo quedó en 1.303 líneas con lo que le corresponde -menú y despacho- y los handlers viven aparte.

  **Sin cambio de comportamiento**: las funciones se movieron tal cual, sin tocarles una línea. Es higiene interna y no cambia nada de lo que se ve en pantalla.

## [2.6.0] - 2026-08-01

Release: **el paquete del cierre viaja solo al CRM**. Hasta acá el `[L]` dejaba el ZIP en el Escritorio del cliente y de ahí en adelante lo movía el operador a mano — abrir el WhatsApp del cliente, o su mail, o pendrive. Ahora se sube desde la misma PC, con una llave que sólo sirve para eso.

Va como *minor* y no como parche porque agrega funcionalidad: SemVer, igual que el resto del changelog.

### Added

- **#41 — el `[L]` sube el paquete al CRM (`modules/CrmUpload.ps1`, `core/Router.ps1`)**: después de armar el ZIP, el cierre pregunta *"¿Subir el paquete al CRM?"* y lo manda. La conexión se pide **una sola vez por PC** y se pega en una línea (dirección y token juntos), porque esto se tipea en la casa de un cliente y muchas veces por AnyDesk, donde cada pegado del portapapeles es un viaje. Vive en `output\state\`, así que **muere con el desinstalador**.

  **Esto nunca traba el cierre de un service.** Sin internet, sin token, con el servidor caído o detrás de un proxy raro: el ZIP ya está hecho y sigue en el Escritorio, no se perdió nada, y el `[L]` termina igual. Todo error de acá es un aviso, jamás una excepción.

  El token del CRM es de **sólo subir** —no lee, no lista, no borra— y tiene tope diario. Si se filtra de la PC de un cliente, lo peor que hace el que lo tenga es mandar basura hasta que se corte. Y es **uno por PC**: cortar el de una no toca a las demás.

  El identificador de la subida sale del **nombre del ZIP** y no de un azar. Eso es lo que hace que reintentar sea gratis: el mismo paquete manda siempre el mismo identificador y el servidor contesta "ya lo tenía" en vez de guardar una segunda copia.

- **#34 — estado de HAGS en el escaneo (`core/MachineProfile.ps1`)**: se lee `HwSchMode` del registro y viaja al perfil, al snapshot, al bundle y al `[R]`. El aviso sale en **un solo caso** —HAGS encendido con GPU integrada y nada más—, donde no es opinión sino limitación técnica. En todo lo demás el signo depende del equipo, así que se informa y no se recomienda.

### Changed

- **Reintentar la subida ya no arma otro paquete (`modules/ServiceState.ps1`, `core/Router.ps1`)**: el marcador del bundle decía que el paquete se **hizo**, pero no si se **subió**. Sin ese dato, la única forma de reintentar una subida fallida era apretar el `[L]` de nuevo — y eso arma un paquete nuevo, con otro nombre y otra hora. Medido en campo el 2026-08-01: **dos ZIP a 41 segundos uno del otro** en el Escritorio, y la protección anti-duplicados del servidor sin poder ayudar, porque el identificador sale del nombre del archivo y el archivo era otro. Ahora el `[L]`, antes de empaquetar, mira si hay un paquete de esa PC sin subir y ofrece subir **ése**. Re-empaquetar sigue disponible contestando que no: se muestra la opción barata primero, no se decide por el operador.

### Fixed

- **#43 — el menú se entera del resize sin esperar una tecla (`utils/ConsoleMenu.ps1`)**: maximizar la ventana con el menú abierto dejaba la barra de selección desalineada hasta que se apretaba algo.

- **La subida podía reportar éxito sin haber subido nada (`modules/CrmUpload.ps1`)**: .NET sigue las redirecciones por su cuenta, así que si la ruta de subida quedara detrás del login de Cloudflare, el 302 se seguía hasta la pantalla de acceso — que contesta **200 con HTML** — y eso se tomaba como subida exitosa. Le habría dicho al operador *"el paquete ya está en el CRM"* sin que el paquete estuviera. Ahora no se siguen redirecciones y un 2xx **no alcanza**: hace falta que el servidor lo confirme con todas las letras. Verificado contra una ruta realmente protegida.

### Security

- **La llave de subida no viaja en el paquete ni en el repo.** Vive sólo en `output\state\` de la PC donde se configuró, y esa carpeta la borra el desinstalador. La dirección del CRM tampoco está en el código: se la pega el operador, así que este repo público no dice dónde vive el CRM de nadie.

## [2.5.0] - 2026-07-26

Release: cierre del ciclo de bugs de campo. El `[L]` y el `[U]` dejan de duplicar el paquete, la clave de recuperación de BitLocker deja de morir con la desinstalación, el `[6]` deja de mezclar BSOD con apagones, y se enciende una tanda de código que estaba escrito y sin cablear (`[I]` informe técnico, submenú de Defender, Autoruns).

### Added

- **`[I]` — informe técnico del equipo (`modules/RawAudit.ps1`, `core/Router.ps1`)**: vuelca CPU / RAM / discos / térmica / USB / programas / Steam a un `.txt` legible. La función existía completa y **no tenía menú, ni caller, ni test**. Se diferencia del `[8]`: el `[8]` es para el **cliente** (HTML honesto, imprimible); el `[I]` es para el **técnico** (crudo, completo). El bundle del `[L]` lo incluye (`output\audits\`).
- **`[A][19]` — submenú de Defender (`modules/Diagnostics.ps1`, `core/Router.ps1`)**: reagendar el escaneo programado, ver exclusiones, aplicar el set de exclusiones de desarrollo (WSL2 + Docker + VS Code) y quitarlas. Cablea tres funciones que estaban huérfanas.
- **`[A][10] A` — abrir Autoruns**: el `[T]` bajaba el ejecutable y nada lo lanzaba.
- **#28 — modelo y Service Tag del equipo (`core/MachineProfile.ps1`, `modules/Telemetry.ps1`, `core/Router.ps1`, `modules/ResearchPrompt.ps1`)**: el `ComputerName` que se guardaba es el hostname (`DESKTOP-XXXX`), inútil para identificar la máquina. El modelo y el serial ya se leían (`Win32_ComputerSystem` y `Win32_BIOS` se consultaban para RAM y detección de VM) y se tiraban. Ahora el perfil y el snapshot los exponen —así que viajan al bundle—, el **banner los muestra** y el research prompt `[R]` lleva el modelo. En Dell el `SerialNumber` **es** el Service Tag: con eso se entra al soporte del fabricante y se sacan los part-numbers exactos, sin correr `wmic` a mano en cada visita. Los placeholders del SMBIOS (`To Be Filled By O.E.M.`, `Default string`) se normalizan a `N/A` al mostrarse, sin tocar el dato guardado. Validado en HW real: Lenovo / 82K2 / serial de 8 caracteres.
- **Datos del técnico configurables (`data/tecnico.json`, `modules/ClientReport.ps1`)**: nombre y teléfono estaban hardcodeados en un módulo. Si el archivo falta o está roto, el reporte se genera igual y esas líneas se **omiten** (no queda una etiqueta `Técnico:` colgada en el papel que ve el cliente).
- **Rollback de servicios (`modules/Debloat.ps1`, `core/Router.ps1`)**: `Disable-BloatServices` guarda el `StartType` **original** de cada servicio tocado y el comando exacto para restaurarlo; se imprime y queda en el audit. Antes revertir era adivinar entre `Automatic` y `Manual` — y con el Spooler esa diferencia es "no me imprime" resuelto o no.
- **Térmica y plan de energía en el reporte `[8]`**: el snapshot ya guardaba `CpuTempC`, `ThermalZones` y `PowerPlan`, y el reporte no los miraba. Se suman al panel "Tu equipo", con aviso de pasta térmica a ≥90 °C. Sin sensores las secciones **no se dibujan**: nada de paneles vacíos.
- **Logo PCTk en el encabezado del reporte `[8]`**: embebido como PNG base64, así que el HTML sigue siendo self-contained.

### Changed

- **`[L]` y `[U]` unificados (`modules/ServiceState.ps1`, `modules/ExportClientLogs.ps1`, `modules/UninstallToolkit.ps1`, `core/Router.ps1`)**: el `[L]` cerraba el service y el `[U]` empaquetaba igual, así que el flujo natural —me llevo el paquete y dejo la PC limpia— dejaba **dos ZIP en el Escritorio del cliente**, y el segundo peor (con el service ya cerrado salía como "bundle parcial", sin POST). Ahora el `[L]` deja un marcador (`output\state\last-bundle.json`) y el `[U]` **no re-empaqueta** si el bundle de esa PC ya se generó: muestra dónde quedó. El `[L]` además ofrece dejar la PC limpia al terminar, y el `[U]` directo sigue funcionando como atajo para "no hubo service, sólo saco el toolkit".
- **`[6]` — BSOD real separado de apagón sucio (`modules/Diagnostics.ps1`)**: se sumaban los tres event IDs en un solo total: 1001 (BSOD real, apunta a driver o RAM) junto con 41 y 6008 (apagón sucio, apunta a la eléctrica o la fuente). Ese número mezclado era lo que se mostraba **y lo único que quedaba en el audit**. Ahora son dos líneas con umbrales propios. Validado en HW real: 32 eventos, 0 BSOD, 32 apagones — el código viejo pintaba eso en rojo como "32 crashes".
- **Etiqueta del `[L]`**: decía "Empaquetar logs de esta PC", que era el nombre de antes de v2.4.0. Ahora dice lo que hace.
- **Descargas del `[T]` más rápidas (`Bootstrap-Tools.ps1`, `Launch.ps1`)**: se redibujaba la barra de progreso en **cada chunk de 64 KB** (~4000 veces para un ZIP de 250 MB), y eso —no la red— frenaba la descarga. Ahora sólo redibuja al cambiar el porcentaje entero. El self-installer silencia `$ProgressPreference` alrededor del `Invoke-WebRequest` (en PS5.1 la barra visible descarga ~10× más lento).

### Fixed

- **#29 — el bundle del `[L]` no llevaba el reporte del cliente (`modules/ExportClientLogs.ps1`)**: el HTML se quedaba en la PC del cliente y había que ir a buscarlo aparte. Ahora `output\reports\` viaja en el ZIP.
- **#30 — el reporte `[8]` salía vacío en visita de diagnóstico (`core/Router.ps1`)**: sólo se buscaban snapshots `*_post.json`; sin pipeline automático no hay POST, así que el reporte salía con el nombre del técnico y nada más. Ahora cae al PRE más reciente, que trae la misma ficha del equipo. El panel Antes/Después **sigue diciendo "no disponible"**: no se fabrica ningún delta que no exista.
- **#38 — el SHA-256 publicado de `Launch.ps1` no coincidía con el que baja el usuario (`Release.ps1`)**: el repo usa `core.autocrlf=true`, así que git almacena LF y checkoutea CRLF; se hasheaba el archivo del árbol de trabajo mientras `raw.githubusercontent` sirve el blob. El que seguía el paso de verificación del README obtenía mismatch y concluía que el archivo estaba adulterado. Publicar un hash equivocado es peor que no publicar ninguno: entrena a ignorar la verificación.
- **#39 — el ZIP del `[U]` salía sin `bundle-meta.json`**: el desinstalador empaquetaba por el camino a-la-carte, y sin meta el CRM no puede ingerirlo. Ahora arma el mismo paquete que el `[L]`.
- **El `[8]` crasheaba sin ningún snapshot (`core/Router.ps1`)**: quedó una lectura de una variable que sólo se asignaba dentro de un `if`; sin snapshots ninguna rama corre y StrictMode tira `VariableIsUndefined`. Introducido después de v2.4.0 — **la v2.4.0 publicada no lo tiene**.
- **`[A][19][V]` imprimía el objeto crudo**: el handler iteraba `{Available; Paths[]}` como si fuera un array de strings y mostraba `@{Available=True; Paths=System.String[]}`. Ahora lee `.Paths` y distingue "Defender no disponible" de "sin exclusiones".
- **El `[L]` imprimía su objeto de resultado en la consola del cliente**: el dispatch llamaba a `Invoke-CloseService` suelto. Misma clase de bug que el anterior.
- **El `[U]` nunca veía el service abierto (`modules/ExportClientLogs.ps1`)**: se le pasaba el *output root* a `Get-ServiceState`, que espera la raíz del toolkit. En el `[L]` no se notaba (ambos vacíos resuelven a la raíz real), pero el `[U]` sí pasa un override → se salteaba el POST automático en silencio.
- **`Disable-BloatServices` crasheaba con una lista de UN servicio (`modules/Debloat.ps1`)**: la trampa de PS5.1 con `$x = if (c) { $lista }`, que desenrolla una colección de un elemento a escalar y hace que `.Count` tire `PropertyNotFoundStrict`. Una receta con un solo servicio a desactivar rompía el pipeline automático. Cazado por un test nuevo.
- **`Get-BsodHistory` se tragaba los errores de lectura del Event Log**: "falló la lectura" y "no hubo crashes" se veían idénticos. Ahora expone `ReadFailed`/`ReadError` y la UI avisa que el resultado no es confiable. Además, un `$raw` reasignado pisaba la variable del `foreach` de afuera.

### Security

- **#40 — el `[U]` destruía la clave de recuperación de BitLocker (`modules/UninstallToolkit.ps1`)**: el desinstalador preservaba `clients\` + `audit\` + el ZIP, pero **nunca** `output\recovery\`, y borra la instalación entera. Capturar una clave con `[A][18][C]` y después desinstalar la destruía sin avisar; si el disco pedía recovery más tarde, el cliente quedaba afuera de su propia PC. Ahora el `[U]` frena **antes de cualquier confirmación**, muestra las claves en pantalla y exige escribir `GUARDADA`. No se copian al Escritorio del cliente a propósito: es un secreto suyo, no algo para dejar suelto en su máquina.
- **El Service Tag no va al research prompt `[R]` (`modules/ResearchPrompt.ps1`)**: el `[R]` suma el modelo, que es el dato útil para buscar drivers y foros del equipo exacto, pero **no** el serial. Ese texto se copia al portapapeles para pegarlo en un LLM de terceros: el modelo lo comparten millones de equipos, el serial identifica el del cliente. Hay un canario que falla si el serial vuelve a aparecer.
- **`[A][2]` Limpieza ahora confirma (`core/Router.ps1`)**: era el único camino destructivo del toolkit sin `Confirm-Action`. Borra el Temp de todos los perfiles y las cachés de cinco navegadores, irreversible y sin papelera. Confirma con el detalle de lo que se lleva, default No.
- **El `[R]` pregunta siempre por los identificadores**: sólo preguntaba si el sistema **no** era Home, o sea que en la mayoría de las PCs de cliente el nombre del equipo salía en claro sin avisar. Ahora pregunta siempre y el default es scrubear.
- **`Set-UltimatePowerPlan`: la guarda de X3D dejó de saltearse en silencio (`modules/Performance.ps1`)**: el `catch` de la detección estaba vacío, así que si fallaba la lectura de la CPU se caía a Ultimate Performance — justo lo que la guarda evita (en un X3D de dos chiplets, Ultimate cuesta fps). Ante la duda ya no cambia el plan. Además `$ErrorActionPreference` local: la función llama a `powercfg` siete veces y decide por `$LASTEXITCODE`.

### Notes

- Smoke 203 → **239**, 0 fallos. La tanda suma canarios que ejercitan **el handler, no la función pura** — la lección de #30, donde el test probaba el renderer y el crash vivía en el handler. El canario de `[L]`+`[U]` corre los dos handlers reales y cuenta los ZIP; verificado con mutación (sin el marcador reporta "hay 2").
- **#26-A1**: red estática que verifica el cierre transitivo de los 14 sitios de serialización a background jobs. Corre en cada smoke.

## [2.4.0] - 2026-07-25

Release: recolección de estado del service reboot-safe + bundle de cliente con metadatos (evolución del `[L]`), fix del reporte de cliente en laptops, y Cinebench R23 al menú de herramientas.

### Added

- **Recolector — estado de service + bundle `[L]` (`modules/ServiceState.ps1` nuevo, `modules/ExportClientLogs.ps1`, `core/Router.ps1`, `core/ProfileEngine.ps1`)**: el run de service ahora lleva un estado persistente reboot-safe. Al abrir PCTk avisa si falta el snapshot PRE (no lo toma solo) y muestra un indicador "último PRE" arriba a la derecha. El hook de PRE quedó cableado también en el flujo de perfil `[1]`/`[2]` (`Invoke-AutoProfile`), que antes no abría el service. El `[L]` pasó de "exportar logs" a **cerrar el service**: corre el POST automático y arma un bundle ZIP con `meta.json` + snapshots `*_pre.json`/`*_post.json` + `audit/*.jsonl`, listo para ingerir en el CRM.
- **Cinebench R23 al menú `[T]` (`tools/manifest.json`)**: benchmark de CPU + test térmico (complementa CPU-Z/HWiNFO). URL de descarga directa verificada; despacho por extensión como el resto del `[T]`.

### Fixed

- **#2 — el panel de batería crasheaba el reporte `[8]` en laptops (`modules/ClientReport.ps1`)**: se pasaba un `if` como argumento de `_CR_Row`, que PS5.1 parsea como el cmdlet `if`; bajo `$ErrorActionPreference='Stop'` (main.ps1) tira `CommandNotFound` terminante. Las PCs de escritorio no tienen batería, así que el bug escapaba al smoke y al gate en Sandbox. Fix con temp vars (`$x = if ...`, forma de asignación válida). Canario en smoke con Battery + EAP=Stop.
- **Recolector — bundle con API .NET en vez de `Compress-Archive` (`modules/ExportClientLogs.ps1`)**: `Compress-Archive` depende del módulo `Microsoft.PowerShell.Archive`, que en instancias degradadas (Sandbox, ciertos Win) falla con "could not be loaded"; ahora el ZIP se arma con `System.IO.Compression` (.NET), siempre disponible. Además, el service NO se cierra si el ZIP no se llegó a crear (no perder el estado; se puede reintentar el `[L]`).
- **Audit `.jsonl` en UTF-8 sin BOM (`utils/ToolkitSupport.ps1`)**: el log de auditoría se escribía con la code page del sistema (CP1252 en es-AR), que mangla caracteres no-ASCII; ahora se escribe en UTF-8 sin BOM (como corresponde a JSONL).

### Security

- **Clave de recuperación de BitLocker fuera del bundle (`modules/Encryption.ps1`, `modules/ExportClientLogs.ps1`)**: la captura de la clave va a un directorio dedicado (`output\recovery\`) que el bundle ZIP del `[L]` **nunca** incluye (el `[L]` zipea `clients\` + snapshots + audit). Evita que un secreto del cliente viaje en el paquete que se archiva/sube al CRM. Defensa en profundidad.

### Notes

- Smoke 187 → **203**, 0 fallos.
- **Gate Sandbox del path mutante: PASS.** El recolector se ejercitó end-to-end en Windows Sandbox limpia (PRE → perfil `[1]` generic → `[L]` cierre de service), con `Status=Success` y sin `output\recovery\` en el bundle. El candidato gateado es idéntico al código de esta release en los 73 archivos del paquete (única diferencia: `VERSION`).
- El paquete ya no incluye `CLAUDE.md` (doc interna del repo, desde ahora fuera del artefacto publicado).

## [2.3.1] - 2026-06-14

Fix de release: el diagnóstico de red `[A][5] D` (#24) crasheaba al ejecutarse. Cazado en el gate Sandbox limpia de v2.3.0.

### Fixed

- **#24 — `Start-NetworkDiagnosticsProcess` serializa la clausura completa al job (`modules/Network.ps1`)**: el diagnóstico de red corre en un background job (runspace fresco, sin las funciones del módulo). Se serializaba solo `Get-NetworkDiagnostics` pero no sus helpers transitivos (`Get-NetworkAdapterReport` → `ConvertTo-PowerPropState` / `Test-LinkSuspect` → `ConvertTo-Mbps`), así que el job tiraba `CommandNotFoundException` al recibirse y `[A][5] D` crasheaba. El gate HW de v2.3.0 había probado los helpers sueltos (existen en esa sesión), no el path del job; el smoke igual. Ahora se embebe toda la clausura. `Optimize-Network` (`[A][5] O`) no estaba afectado (es self-contained). Auditados los otros 13 sitios de serialización a job: clausuras completas.

### Notes

- Smoke 186 → **187**: nuevo test de regresión que ejercita el path REAL (corre `Start-NetworkDiagnosticsProcess` y falla si reaparece el `CommandNotFound`), no los helpers sueltos. **Gate Sandbox limpio de v2.3.1 pendiente** (re-instalar el one-liner real de `v2.3.1` + ejercitar `[A][5] D` y el resto).

## [2.3.0] - 2026-06-14

Release: capa de diagnóstico/mantenimiento ampliada (red, disco, cifrado, AnyDesk) + reporte de cliente al cierre del run + fixes de UI de consola.

### Added

- **#9 — AnyDesk ID en `meta.json` (`modules/AnyDesk.ps1`, `core/ProfileEngine.ps1`)**: captura read-only del ID de AnyDesk de la PC (desde `system.conf`, clave `ad.anynet.id`) y lo escribe en el `meta.json` del run, para atar el run al cliente en el CRM. No invoca el binario AnyDesk (puro file-read, StrictMode-safe, sin exe nativo); `$null` si AnyDesk no está instalado, y la captura nunca aborta la escritura del run-dir. Validado en HW real.
- **#24 — capa PC de red `[A][5]` (`modules/Network.ps1`, `core/Router.ps1`)**: diagnóstico expandido read-only (driver + EEE/ahorro + Interrupt Moderation + duplex + aviso de "link bajo" en Ethernet ≤100 Mbps + NetworkThrottlingIndex report-only por ser mito) y **test de bufferbloat** que mide el ping idle al gateway y delega la medición bajo carga a waveform.com. Helpers puros con fixtures 0/1/N.
- **Mantenimiento de discos `[A][17]` (`modules/DiskMaintenance.ps1`)**: TRIM en SSD / defrag en HDD según `MediaType` (guardrail: ante la duda, Skip).
- **Antimalware on-demand en `[T]`**: KVRT (Kaspersky Virus Removal Tool) + AdwCleaner al manifest de herramientas.
- **#18 — cifrado/BitLocker `[A][18]` (`modules/Encryption.ps1`)**: detección de cifrado (CIM numérico), captura de la clave de recuperación y decrypt `manage-bde` (con EAP local); gate de captura-primero antes de habilitar HVCI en `[A][12]`.
- **#15 — reporte de cliente `[8]` (`modules/ClientReport.ps1`)**: HTML de 3 paneles honestos (sin panel que no se pueda respaldar con datos del run) generado al cierre.
- **#23 — advisories y herramientas**: avisos para CPU X3D, reagendar el escaneo de Defender (`[A][19]`), PresentMon + DDU al manifest `[T]`.
- **Inicio `[10]`**: descripciones de arranque ampliadas (16 reglas nuevas, 2 updaters marcados "seguro apagar") + deshabilitado en bloque de los "seguro apagar" (atajo `S`).
- **Perfil gaming nombrado — receta `gaming.cfg` (OOSU)**: incluida en el paquete. **Validación de la receta en VM Win11 pendiente**; no se auto-aplica (el operador la elige desde `[2]`).

### Fixed

- **#24 — adapters de red filtrados por `HardwareInterface`**: antes se filtraba por `PhysicalMediaType`, lo que dejaba colar adapters virtuales (VirtualBox, ZeroTier) que reportan `802.3` y se metían en el target de optimización; ahora solo entran NIC físicas reales. Además, neutralización de EAP local en `Optimize-Network`: las llamadas a `netsh`/`ipconfig` bajo `$ErrorActionPreference='Stop'` podían volverse `NativeCommandError` terminante (misma clase que el fix de USB `[16]`).
- **#25 — UI de consola (`core/Router.ps1`, `utils/ConsoleTheme.ps1`)**: la ventana ahora entra el menú completo (`Set-PctkConsoleSize`) y el highlight de navegación sobrevive a maximizar/restaurar la ventana.
- **Hardening EAP — `Invoke-WslShutdown` (`modules/Wsl.ps1`)**: `wsl.exe --shutdown` corría bajo `$ErrorActionPreference='Stop'` sin neutralizar EAP local pese a depender de `$LASTEXITCODE`; su stderr podía volverse `NativeCommandError` terminante (misma clase que USB `[16]`). No crasheaba hoy (el caller lo envolvía en try/catch) pero la función no cumplía la regla. Detectado por una auditoría sistemática de las dos clases de crash (StrictMode `[0]`/`.Count` + exe-nativo/EAP); el resto del barrido salió limpio.

### Changed

- **HVCI fuera del template default del perfil gaming**: se chequea GPO antes de ofrecer habilitarlo (`[A][12]`).

### Notes

- Smoke 145 → **186**. Pre-gate del candidato (Claude): smoke 186/0 + BOM/parse de 55 `.ps1` trackeados OK. **Gate Sandbox canónico pendiente** (instalar el one-liner real de `v2.3.0` en Sandbox limpia + ejercitar a mano). Fecha a confirmar al publicar.

## [2.2.0] - 2026-06-08

Release: tema de consola PCTk (ANSI/VT truecolor con fallback a 16-color) aplicado a TODA la interfaz + agrupado y descripciones en el menu de Inicio `[10]`.

### Added

- **Tema de consola PCTk (`utils/ConsoleTheme.ps1` + adopcion en todo el codigo)**: paleta ambar/slate/teal con banner block, caja doble de info de la PC, firma del operador, headers de seccion, highlight de menu y badges. Usa ANSI/VT truecolor cuando se puede habilitar (`Enable-PctkVT`); si no (Windows viejo / output redirigido) **degrada solo** al estilo clasico de 16-color, sin emitir ANSI crudo. Cost-zero (estatico, sin animacion; pensado para AnyDesk). Capa de helpers de salida (`Write-Pctk*`) adoptada por todos los handlers del Router, el pipeline de perfil `[1]`, la receta nombrada `[2]` y los reportes (compare PRE/POST, BSOD, salud de disco, desinstalacion, export de logs).
- **Menu de Inicio `[10]` agrupado + descripciones (`core/Router.ps1`, `modules/StartupManager.ps1`)**: las entradas se agrupan ACTIVAS (ON) primero y DESACTIVADAS (OFF) despues; las mas comunes muestran una descripcion corta con sugerencia (dejar / opcional / seguro apagar) via `Get-StartupDescription`. El indice para alternar entradas se mantiene consistente.

### Fixed

- **El menu crasheaba al lanzar con `& main.ps1` (`core/Router.ps1`)**: el `renderHeader` del banner usaba `.GetNewClosure()`, que ata el scriptblock a un modulo dinamico que solo ve funciones globales; con `& main.ps1` (vs `powershell -File`, que es como instala el one-liner real) `Show-MachineBanner` no se resolvia (`CommandNotFoundException`). Fix: scriptblock plano + variable `$script:` (el lookup dinamico encuentra la funcion). No afectaba la instalacion real (siempre via `-File`); es defensa en profundidad. Canary estructural en smoke para que no reincida.

### Notes

- Smoke baseline 138 -> 145 (helpers de tema + canary GetNewClosure + Get-StartupDescription). Pre-gate del ZIP (BOM + parse de los 38 `.ps1`) OK.

## [2.1.5] - 2026-06-02

Release: fix de robustez en la lectura de disco (timeout honesto en HDD lento) + neutralizacion de EAP=Stop en el backup de drivers (`pnputil`).

### Fixed

- **Lectura de disco en HDD lento devolvia el disco vacio (`modules/DiskHealth.ps1` + `modules/Telemetry.ps1`)**: en PCs con disco lento la lectura SMART/reliability cruzaba el timeout (10/8s) e `Invoke-WithTimeout` devolvia el `-Default` vacio; como el flag `TimedOut` se descartaba, el disco quedaba nulo e indistinguible de "no hay disco" -- tanto en el diagnostico `[7]` como en el snapshot PRE/POST (el "antes/despues" del cliente). Ahora el timeout se propaga: `[7]` muestra "se agoto el tiempo (PC o disco lento), no es que no haya disco", y el snapshot marca `SmartTimedOut` por disco en vez de un vacio silencioso. Timeouts subidos 10/8s -> 20/12s (constantes tuneables; el valor exacto queda por calibrar en HW con HDD lento). Bug de campo (sesion de taller).
- **`pnputil` crasheaba el backup de drivers bajo EAP=Stop (`modules/Diagnostics.ps1`)**: la llamada nativa a `pnputil` corria bajo `$ErrorActionPreference='Stop'` de `main.ps1`; en PS5.1 su stderr se vuelve `NativeCommandError` terminante y abortaba el backup. Fix: neutralizar EAP localmente (misma clase que el fix de USB `[16]` de v2.1.4).

## [2.1.4] - 2026-06-01

Release: recetas auto consolidadas a schema v2.0 + nuevo diagnostico de salud de discos `[7]` + 5 modulos expuestos en `[A][12]-[16]` + 2 fixes de crash por trap StrictMode (USB `[16]`, marca de 1 palabra).

### Added

- **Salud de discos SMART/wear (`modules/DiskHealth.ps1`, menu `[7]`)**: nuevo diagnostico que lee estado SMART y wear-level (SSD) y avisa en el menu cuando un disco esta WARN/CRIT (prediccion de falla, wear sobre umbral). Read-only.
- **5 modulos huerfanos expuestos como `[A][12]-[16]` (`core/Router.ps1`)**: modulos que existian pero no tenian entrada de menu ahora son accesibles desde el submenu avanzado `[A]`.
- **Clase `Normal` en `[15]` Process Priority (`modules/ProcessPriority.ps1`)**: ademas de las clases altas, se puede devolver un proceso a prioridad Normal.

### Fixed

- **Crash de arranque con marca de 1 palabra (`core/MachineProfile.ps1`, confirmado en cliente real)**: `Get-NormalizedManufacturer` con una marca off-brand de una sola palabra (ej. `EXO`) hacia que `$value.Split(' ') | Where-Object {...}` se desenrollara a escalar y `$parts.Count` tirara `PropertyNotFoundStrict` bajo StrictMode, crasheando `Get-MachineProfile` en el arranque y el toolkit no levantaba. Fix con el patron del repo (`[object[]] $parts = @(...)`). Canary en smoke con fixture de 1 palabra.
- **`[16]` USB crasheaba al deshabilitar (`modules/UsbPower.ps1`)**: las llamadas a `powercfg` corrian bajo `$ErrorActionPreference='Stop'` de `main.ps1`; en PS5.1 el stderr de un exe nativo se vuelve `NativeCommandError` terminante y crasheaba el toolkit entero. Fix: neutralizar EAP localmente (`Continue`) en las funciones que invocan `powercfg` y dependen de `$LASTEXITCODE`.
- **Labels `[1]` y `[A]` desalineados con el schema v2.0 (`core/Router.ps1`)**: textos de menu actualizados.

### Changed

- **Consolidación de recetas auto (data schema v1.0 → v2.0)**. Las 12 recetas auto (`<use_case>_<tier>.json` con 4 use-cases × 3 tiers) se redujeron a 3 (`<use_case>.json`, uno por use-case): `generic.json`, `work.json` (fusión de `office_*` + `study_*` que eran funcionalmente idénticos en runtime), `multimedia.json`. El audit `_local-dev/recipes-audit.md` mostró que 11 de 12 archivos tenían contenido funcional idéntico (todos `visual_profile=Balanced`, mismos services por use-case), y que el `_tier` del JSON sólo se usaba para validación de schema y display — no condicionaba ningún tweak. La diferenciación por hardware (laptop vs desktop, RAM ≤ 8 GB) sigue viviendo en los módulos `Performance` (`Set-UltimatePowerPlan`, `Set-SystemTweaks`) y `Debloat` al ejecutarse, como antes. Cambios:
  - `core/ProfileEngine.ps1`: `Get-AutoProfilePath` sin parámetro `-Tier`; `Test-AutoProfileSchema` exige `_schema_version: "2.0"`, `_tier` removido, `_use_case` con whitelist (`generic|work|multimedia|named`); `Get-AutoProfilePreviewLines` reformulada; `Invoke-AutoProfile` lee tier del `MachineProfile` (HW real) en vez del JSON.
  - `core/Router.ps1`: menú principal `[1] Generic / [2] Work / [3] Multimedia` (era 4 entradas con office + study separados). Audit-action `Profile.Apply.Work` reemplaza `Profile.Apply.Office`/`Profile.Apply.Study`.
  - `core/NamedProfileEditor.ps1` + `data/profiles/named/_sample.json`: builder y fixture en schema v2.0 (sin `_tier`, sin `_future` blocks).
  - `data/profiles/auto/`: 12 archivos viejos eliminados; 3 nuevos creados; README actualizado.
  - `docs/recipes/`: `office.md` + `study.md` reemplazados por `work.md`; `generic.md` + `multimedia.md` reescritos sin tier; índice README actualizado.
  - `data/oosu10-profiles/README.md`: referencias a `office_*`/`study_*` actualizadas a `work.json`.
  - `tests/smoke.ps1`: 13 tests de Import (1 Get-AutoProfilePath + 12 por receta) → 4 tests (1 Get-AutoProfilePath + 3 por receta). Smoke baseline 103 → 94.
  - `tests/stage3-validate.ps1`, `tests/stage2-harness.ps1`, `tests/stage4-validate.ps1`, `tests/postqueue-validate.ps1`: actualizados al shape v2.0.
- **Fix (bug latente desde v2.0)**: `multimedia_high.json` tenía `visual_profile: "Full"` que invocaba `Set-FullOptimizedVisuals` (Windows "Adjust for best performance" = apaga ClearType + thumbnails + drag-full-windows). Contraintuitivo para el use-case streaming. La nueva `multimedia.json` aplica `Balanced` para todos los casos (preserva ClearType y thumbnails — preview de archivos de video importa).

### Notes

- **`meta.json` del cliente — `schema_version` cambia, shape no**. El campo `schema_version` del `output/clients/<slug>_<ts>/meta.json` se hereda del `_schema_version` del recipe aplicado. Post v2.0, los `meta.json` nuevos tendrán `schema_version: "2.0"`. Las 11 keys del meta.json (`client`, `date`, `computer_name`, `anydesk_id`, `tier`, `use_case`, `schema_version`, `compare_score`, `status`, `amount_charged_ars`, `notes`) **NO cambian** — solo el label. Si un agregador externo lee meta.json y depende del valor literal `"1.0"` para algo, va a tener que aceptar `"2.0"` como sinónimo (mismo shape).
- **`use_case` en meta.json**: post v2.0 los valores válidos son `generic` / `work` / `multimedia` / `named`. Los `meta.json` históricos pueden tener `office` / `study` — son inmutables (audit del pasado) y siguen siendo legibles.

## [2.1.3] - 2026-05-23

Patch: fix de bug confirmado en cliente real — `[U]` perdía snapshots del workflow diagnóstico-only.

### Fixed

- **P1: `[U]` perdía `output\snapshots\` silenciosamente (bug confirmado en cliente real, 2026-05-21).** El bloque "preservar historial" de `Invoke-UninstallToolkit` estaba gateado por la existencia de `output\clients\`; en el workflow diagnóstico-only (solo `[3]` Pre, sin perfil), ese directorio no existe, el bloque se saltaba íntegramente y los snapshots se borraban junto con la instalación sin ningún aviso. Fix en dos capas: (1) `modules/ExportClientLogs.ps1` — nuevo parámetro `-TagOverride [string]` que omite el `Read-Host` interactivo cuando se pasa explícitamente (comportamiento del `[L]` standalone sin cambio). (2) `modules/UninstallToolkit.ps1` — nueva función `Save-PreUninstallArtifacts` extrae toda la lógica de preservación; el bloque (A) mantiene la UX de `output\clients\` + `output\audit\` en carpeta plana en Desktop (sin regresión); el bloque (B) NUEVO invoca `Invoke-ExportClientLogs -TagOverride 'preuninstall'` incondicionalmente, generando `<HOST>-preuninstall_<ts>.zip` en Desktop con `audit\` + `snapshots\`. Si no había ningún artifact (PCTk recién instalado), `[L]` retorna `Status='Empty'` silenciosamente y el `[U]` prosigue. Fallo del zip no aborta la desinstalación (se avisa y continúa). Gate: Sandbox limpia pendiente.

## [2.1.2] - 2026-05-20

Patch: fix de regresión crítica en self-uninstall + QoL en selectores de apps y startup + preservar audit del operador al desinstalar.

### Added

- **Apps uninstall — selector con rango (`core/Router.ps1` `Invoke-ActionApps`)**: el parser ahora acepta `N-M` además de número suelto y lista coma/espacio (también `N-M` invertido se normaliza). UI base de desinstalación ya existía en v2.1.1 (commit `7ab6b79`); este patch cubre el único gap conocido del selector.
- **Startup toggle real (`core/Router.ps1` `Invoke-ActionStartup` + `modules/StartupManager.ps1`)**: el handler `[A]→[10]` antes listaba pero el toggle era un stub no-op. Ahora togglea de verdad multi-hive — Registry `Run`/`Run32`/`RunOnce` (vía clave nativa `StartupApproved`, round-trip exacto al estilo del Administrador de tareas), carpeta Startup (rename `.lnk` ↔ `.lnk.disabled`), y **tareas programadas** (`Enable-`/`Disable-ScheduledTask`, soporte nuevo en `Get-StartupEntries`). Selección por número / lista / rango; confirm `[s/N]` si alguna entrada va a OFF. El pipeline auto NO cambia (sigue report-only por decisión de producto: Mateo deshabilita startup a mano con esta opción).
- **`F1` — preservar `output\audit\` al desinstalar (`modules/UninstallToolkit.ps1` `Invoke-UninstallToolkit`)**: cuando el operador acepta preservar el historial, además de `output\clients\` se copia también `output\audit\` al mismo destino (`Desktop\PCTk-historial-clientes\audit\*.jsonl`). El audit `Toolkit.Uninstall` se escribe ANTES del copy para quedar incluido. Alimenta el tracking persistente de clientes.

### Fixed

- **P1: el self-uninstall `[U]` no borraba `C:\PCTk` (afectaba también v2.1.0 y v2.1.1).** Causa raíz: `Run.bat` hace `pushd "%~dp0"` → el `cmd.exe` que lanzó PCTk retiene `CWD = C:\PCTk` un instante después de que `powershell.exe` muere; el deleter desprendido disparaba un único `Remove-Item -ErrorAction SilentlyContinue` antes de que `cmd.exe` muriera, perdía la race contra el CWD lock, y el fallo quedaba mudo. Fix en `New-PctkUninstallScript`: CWD propio neutral (`Set-Location $env:TEMP`) + loop de retry con verificación (80 × 750 ms ≈ 60 s, `Remove-Item` + `Test-Path`) que gana la race del `cmd.exe` y cubre además latencias de AV/handles + log persistente en `$env:TEMP\pctk-uninstall-<ts>.log` con resultado real (Deleted: True/False + intentos + último error). El mensaje al usuario deja de afirmar "borrará la carpeta" con certeza y muestra la ruta del log. Test headless `tests/uninstall-validate.ps1` T2 extendido con un `cwdHolder` separado para reproducir la race sin necesitar Sandbox. Cazado por el gate Sandbox limpia.

## [2.1.1] - 2026-05-19

Patch: icono de PCTk en la ventana de consola en runtime (branding cosmético; no toca la cadena de confianza ni el one-liner).

### Added

- **Icono de consola en runtime (`utils/ConsoleIcon.ps1`, `assets/pctk.ico`)**: `Set-PctkConsoleIcon` setea el icono de la ventana de PowerShell al arrancar `main.ps1`, vía P/Invoke (`GetConsoleWindow` + `LoadImageW` + `SendMessageW`/`WM_SETICON`, ICON_SMALL+ICON_BIG). Defensivo total: no-op silencioso si no hay consola / falta el `.ico` / falla la API; jamás aborta el toolkit. Sin proceso residente ni timers. NO toca `Launch.ps1` ni el one-liner → SHA-256 de la cadena de confianza intacto. Smoke read-only nuevo (presencia de la función + header ICO; no muta la ventana del runner).

## [2.1.0] - 2026-05-19

Minor: perfiles O&O ShutUp10++ para la rama de privacidad por receta + dos bugfixes de v2.0.1 hallados probando el release publicado en Windows Sandbox limpia.

### Added

- **Perfiles O&O ShutUp10++ (`data/oosu10-profiles/*.cfg`)**: `basic.cfg`, `medium.cfg`, `multimedia.cfg`, `aggressive.cfg` generados por ID estable desde el catálogo OOSU V2.2.1024, espejando los niveles de `modules/Privacy.ps1`. Las recetas (generic→basic, office/study→medium, multimedia→multimedia, named-aggressive→aggressive) aplican OOSU vía `Invoke-ProfilePrivacyStep` con fallback nativo si falta el `.cfg`/`OOSU10.exe`. Determinístico (272 entradas, `+` solo en el scope del nivel); historial de portapapeles / SmartScreen / Windows Update / permisos por-app quedan intactos.

### Fixed

- **Instalación rota (Execution Policy)**: el one-liner de v2.0.1 (`… -OutFile $f; & $f`) fallaba en toda máquina nueva con `SecurityError / running scripts is disabled` — la Execution Policy default (`Restricted`) bloquea ejecutar un `.ps1`. El fix de v2.0.1 había resuelto el BOM/`#Requires` (cambiando `| iex` por `& $f`) pero `& archivo` SÍ está sujeto a Execution Policy mientras que `iex` no. README ahora usa `powershell -NoProfile -ExecutionPolicy Bypass -File $f` (maneja BOM + `#Requires` + Policy). Pin a `v2.1.0`.
- **`New-ResearchPrompt` crash en máquinas con 1 módulo de RAM** (`modules/ResearchPrompt.ps1`): el hardening de v2.0.1 usaba `$slotsArr = if (c) { @($x) } else { $null }`; la expresión-`if` enumera la salida del bloque y con 1 solo elemento el `@()` se desenrolla a escalar → un PSCustomObject suelto no tiene `.Count` → `PropertyNotFoundException` bajo StrictMode. Se disparaba en VM/Sandbox/laptops (1 slot RAM). Corregido a variable tipada `[object[]]` + asignación por statement. + regresión smoke con colecciones de 1 elemento (la fixture sparse anterior no tenía `RamSlots`, por eso no lo cazó).

## [2.0.1] - 2026-05-18

Patch: bugs hallados probando el v2.0.0 publicado + endurecimiento.

### Fixed

- **Instalación rota**: el one-liner `irm … | iex` fallaba porque `Launch.ps1` arranca con BOM UTF-8 + `#Requires` (el BOM queda como carácter antes de `#Requires` y PowerShell lo trata como comando). Las instrucciones del README ahora **descargan a archivo y lo ejecutan** (`& $f`), que maneja BOM/`#Requires` correctamente.
- **`New-NamedProfileInteractive` (`core/NamedProfileEditor.ps1`)**: `Add-Tweak` escribía `$script:gt` (scope nunca seteado) → crash StrictMode al primer toggle; rompía **todo** el builder interactivo de recetas nombradas (`[2] → [1] Nueva`). Además leía un `$gt` local distinto del retornado (receta vacía). Corregido a `$gt` (scope dinámico) + regresión en smoke.
- **`New-ResearchPrompt` (`modules/ResearchPrompt.ps1`)**: decenas de accesos anidados a `$Snapshot`/`$MachineProfile` sin guarda bajo StrictMode podían crashear el generador de research según el hardware/PC. Blindados con helper `_Rp_Prop` + `PSObject.Properties` (modelo `Show-MachineBanner`); output de campos presentes intacto. + regresión smoke (snapshot sparse).
- **`.gitattributes`**: los rigs `tests/uninstall-*` se filtraron al ZIP público de v2.0.0 (la lista enumeraba rigs por nombre y no incluía los nuevos). Glob `tests/*-{validate.ps1,sandbox-launcher.ps1,sandbox.wsb,sandbox-test.wsb,harness.ps1}` cubre presente y futuro sin enumerar (no afecta `tests/smoke.ps1`).

### Changed

- **`README.md`**: método de instalación documentado = descargar-a-archivo + ejecutar (no `irm|iex`); one-liner pineado a `v2.0.1`.
- **`data/oosu10-profiles/README.md`**: set real de `.cfg` que consumen las recetas — `basic.cfg` (generic), `medium.cfg` (office/study), **`multimedia.cfg`** (multimedia); `aggressive.cfg` solo el named. CLI real `OOSU10.exe <cfg> /quiet` (antes documentaba `/ofile=`, incorrecto).

### Added

- **`tests/smoke.ps1` — harness de abort-seguro de handlers interactivos**: Bugs StrictMode (named-builder, research-prompt) shippearon porque ningún test ejercitaba los handlers interactivos del Router. Nuevos tests drivean `Invoke-ActionStartup` / `Invoke-ActionApps` / `Invoke-ResearchPrompt` a su abort-seguro verificado (Read-Host shadow) y asertan no-crash bajo StrictMode.

## [2.0.0] - 2026-05-17

Rework completo del toolkit. Arquitectura rediseñada de "menú con stubs" a **optimizador por perfiles**: el técnico elige el use-case del cliente (Generic / Office / Study / Multimedia), el toolkit detecta el hardware tier (Low / Mid / High) y aplica una receta pre-fabricada con snapshot PRE/POST automatizado.

### Added

- **Modelo de perfiles auto (4 use-cases × 3 tiers = 12 recetas)**: `data/profiles/auto/<use_case>_<tier>.json`. Cada receta declara qué servicios deshabilitar, perfil visual, nivel de privacidad y limpieza de temporales. El engine orquesta los módulos existentes a partir del JSON.
- **`core/ProfileEngine.ps1`**: orquestador de recetas — carga JSON, valida schema, aplica steps (Debloat → Performance → Privacy → Cleanup → Startup report), genera log de ejecución.
- **`core/MachineProfile.ps1` — tier classification**: detección de `Tier` (Low/Mid/High) basada en RAM, clase de CPU y VRAM de GPU. El banner del menú muestra el tier y el vendor OEM.
- **`core/Router.ps1` — menú v2 Opción A**: cuatro secciones — PERFILES, DIAGNÓSTICO, ACCIONES MANUALES (submenú `[A]`), HERRAMIENTAS. Opción `[1]` aplica perfil auto con selector de use-case; `[R]` abre el generador de research prompts.
- **`modules/ResearchPrompt.ps1`**: genera prompt estructurado para LLMs con el perfil de hardware + snapshot. 5 plantillas (Optimización, Troubleshooting, DriverAudit, MigrationReadiness, Custom). Copia al clipboard y guarda en `output/research/`.
- **`modules/CoreIsolation.ps1`**: toggle de Memory Integrity (HVCI) preservando VBS/WSL2.
- **`modules/UsbPower.ps1`**: deshabilitar/habilitar USB Selective Suspend via powercfg + registro global.
- **`modules/Hags.ps1`**: toggle de Hardware-Accelerated GPU Scheduling (HAGS).
- **`modules/Wsl.ps1`**: generador/editor de `.wslconfig` con presets (Default/Gaming/DevHeavy/DevDocker).
- **`modules/RawAudit.ps1`**: `New-RawAuditReport` — genera `.txt` human-readable en `output/audits/` desde el snapshot.
- **`modules/Privacy.ps1` — `Invoke-OOSU10Profile`**: invoca OOSU10.exe con el `.cfg` de la receta; fallback al perfil nativo si OOSU10 no está disponible.
- **`modules/Privacy.ps1` — `Add/Remove-WslDefenderExclusions`**: discovery dinámico de paths LXSS + Docker para exclusiones de Defender.
- **Snapshot enriquecido** (`Get-SystemSnapshot`): 8 campos nuevos — `DeviceGuard`, `UsbDevices`, `HidDevices`, `DnsServers`, `ThermalZones`, `InstalledPrograms`, `Steam`, `PowerPlan`. Snapshot PRE automático antes de aplicar receta; POST al final. Comparación mostrada en pantalla.
- **VM-mode** (`Get-SystemSnapshot`): detección de hypervisor via WMI. Queries que no aplican en VM (SMART, PnP, ACPI, Battery) se omiten automáticamente; el banner muestra `VM : <vendor>`. Timeout per-query configurable para evitar cuelgues en entornos virtualizados.
- **Carpeta de cliente**: `output/clients/<slug>_<fecha>/` creada automáticamente en cada run de receta — log de ejecución, snapshot PRE/POST y audit log en un solo lugar.
- **Audit log distribuido**: `Write-ActionAudit` invocado desde cada handler; log a `output/audit/<date>.jsonl`.
- **`Confirm-Action` helper**: preview de qué se va a aplicar + confirmación S/n antes de cada acción destructiva.
- **`tests/smoke.ps1`**: harness read-only que valida 76 funciones de detección y carga de recetas sin tocar el sistema.
- **`tools/manifest.json`**: DDU, LatencyMon, TimerResolution agregados. URLs rotas corregidas; versiones actualizadas (BCUninstaller 6.1.0.1, WizTree 4.31, CPU-Z 2.20, BleachBit 6.0.0).
- **`tools/Check-ToolUpdates.ps1`** + **`tools/README.md`**: helper para verificar herramientas en el manifest.
- **Self-uninstall (`core/Router.ps1` + `modules/UninstallToolkit.ps1`)**: `[X]` pasa a **"Salir"** (deja todo instalado); nueva opción **`[U]` "Desinstalar PCTk de esta PC"** — doble confirmación (preview + tipear `BORRAR`), preserva `output/clients/` fuera de la instalación, y un desinstalador desprendido borra solo el footprint de PCTk (carpeta de instalación + `%TEMP%\PCTk-*`) recién después de cerrar el proceso. Validado en Windows Sandbox.
- **Apps — desinstalación interactiva (`core/Router.ps1` `Invoke-ActionApps` + `modules/Apps.ps1`)**: la opción `[8]` ahora lista Win32 + UWP indexado, selección múltiple, preview del método (Quiet / MSI / Interactive para Win32, `Remove-AppxPackage` usuario actual para UWP) y confirmación única; desinstala con audit por app + batch.
- **Startup — toggle interactivo (`core/Router.ps1` `Invoke-ActionStartup` + `modules/StartupManager.ps1`)**: la opción `[10]` ahora activa/desactiva entradas de inicio (Registry StartupApproved + carpeta Startup), respeta `RunOnce` (no editable) y re-lee el estado tras cada cambio.
- Con lo anterior se cierran los **2 últimos stubs de menú** (`Stage 2+ extiende este handler`): la transición de "menú con stubs" a optimizador por perfiles queda 100% real.

### Changed

- **Branding**: `ServiceKit v2` → `PCTk v2` en `main.ps1` y `core/Router.ps1`.
- **Performance.ps1 `Set-UltimatePowerPlan`**: detecta laptop; en laptops aplica Balanced en lugar de Ultimate Performance (evita throttle por TDP locked vía EC). Muestra el power plan previo y el comando para revertir.
- **`RestorePoint.ps1`**: muestra el punto de restauración existente y ofrece bypass de cooldown opt-in.
- **`Release.ps1`**: excluye `_local-dev/`, `.claude/` y rigs de test/sandbox del ZIP de distribución.
- **VERSION**: `1.0.3` → `2.0.0`.

### Fixed

- **Encoding**: UTF-8 BOM en 13 archivos `.ps1` — sin BOM, PowerShell 5.1 en locale es-AR leía con Windows-1252 y reventaba el parser en strings con tildes o em-dash.
- **Network.ps1 `Optimize-Network`**: acceso a propiedad inexistente en StrictMode; `netsh fastopen` no válido para `set global` en Win11 24H2; autotuning ya default en 22H2+ (no-op eliminado).
- **Network.ps1 `Get-NetworkDiagnostics`**: primera fila de `Get-NetTCPSetting` tenía campo vacío; filtra ahora por `SettingName='Internet'` + fallback locale-agnostic.
- **Telemetry.ps1**: falso positivo en `MultipleAvProblem` cuando Defender está en Passive Mode con AV tercero activo; ahora separa `Enabled` de `IsActive` via `AMRunningMode`.
- **Telemetry.ps1**: parsing de `powercfg /getactivescheme` reemplazado por regex locale-agnostic (el header varía entre locales de Windows).
- **Telemetry.ps1**: Defender duplicado en SecurityCenter2 eliminado.
- **UsbPower.ps1**: regex locale-agnostic para AC Power Setting Index (es-AR, en-US, pt-BR).
- **Telemetry.ps1 `Compare-Snapshot`**: crash con `volDiff` vacío en PS5.1 StrictMode corregido.
- **Router.ps1**: Enter vacío ya no crashea el dispatcher del menú principal.
- **`main.ps1`**: dot-source inline de módulos corregido (bug de scope que tiraba "Falta Get-MachineProfile").
- **`core/JobManager.ps1`**: `Wait-ToolkitJobs` devuelve array siempre para evitar unwrap incorrecto.

## [1.0.3] - 2026-03-14

### Fixed
- Descargas de herramientas externas endurecidas con resolución de URL final cuando el proveedor entrega HTML intermedio.
- Validación de payload para ZIP/EXE antes de extraer o ejecutar.
- Manifest de herramientas actualizado para enlaces caídos.
- Detección y resolución de ruta de lanzamiento mejorada para extraídos con carpetas versionadas.

## [1.0.2] - 2026-03-14

### Fixed
- Bootstrap: reintentos de descarga y validación de payload ZIP antes de extraer.
- Menú de herramientas: Enter vacío ya no sale del submenú; `D N -f` habilita re-descarga forzada.
- Privacidad: detección/lanzamiento de ShutUp10 unificado.
- Telemetría: referencias PRE/POST alineadas a opciones [7]/[8].
- Windows Update: fallback de fechas endurecido.
