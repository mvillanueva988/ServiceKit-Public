# PC Optimizacion Toolkit — Sesión de Desarrollo 5

## Resumen

Quinta sesión. Foco: análisis de arquitectura para features de privacidad y aplicaciones, implementación de `modules/Apps.ps1`, submenú de Herramientas Externas, redesign del menú principal con descripciones, y refactor completo de `Bootstrap-Tools.ps1`.

---

## Decisiones de arquitectura

### ShutUp10++ — integración por CLI

`OOSU10.exe` acepta un archivo `.cfg` y el flag `/quiet`:
```
OOSU10.exe perfil.cfg /quiet
```
El `.cfg` es texto plano con formato `SETTING_NAME=1|2|3`. Los perfiles se versionen en el repo (`tools/privacy-profiles/`), el binario se descarga vía manifest. Esto cubre los 200+ tweaks sin copiar código.

### Clasificación de features por método de implementación

| Feature | Decisión |
|---------|----------|
| Privacy tweaks (telemetría, Cortana, ads) | Invocar ShutUp10++ CLI + `.cfg` versionados |
| Desinstalar apps UWP | Nativo — `Remove-AppxPackage` |
| Listar apps Win32 | Nativo — lectura de registro `Uninstall` keys |
| Desinstalar apps Win32 (MSI/silent) | Nativo — `QuietUninstallString` / `MsiExec /qn` |
| Desinstalar con limpieza de leftovers | BCUninstaller — descarga opcional (~370 MB) |
| Startup manager básico | Nativo — Run keys + carpetas de inicio |
| Startup manager completo | Autoruns GUI / `autorunsc.exe` CLI |
| Análisis de disco visual | WizTree / WinDirStat — descarga opcional |

### Win32 apps — lógica de uninstall por prioridad

1. `QuietUninstallString` — si existe, usar directo
2. MSI (`MsiExec /X{GUID}`) → convertir a `/qn /norestart`
3. `UninstallString` con UI — abrir interactivo como fallback

---

## Cambios implementados

### `modules/Apps.ps1` — NUEVO

#### `Get-InstalledWin32Apps -Filter`

- Lee 3 hives: `HKLM\...\Uninstall\*` (x64 + WOW6432Node) + `HKCU`
- Deduplica por `DisplayName` (HashSet OrdinalIgnoreCase)
- Excluye: sin nombre, `SystemComponent=1`, entradas con `ParentKeyName`
- Retorna: `Name`, `Version`, `Publisher`, `UninstallString`, `QuietUninstallString`, `SizeMB`
- `-Filter` soporta regex con fallback a `-like` si el regex es inválido

#### `Get-InstalledUwpApps -Filter`

- `Get-AppxPackage` filtrado: excluye resource packages, bundles y NonRemovable
- Construye `DisplayName` legible (strip publisher prefix + CamelCase split)
- Flag `IsMicrosoft` para colorear diferente en la UI
- Ordena: terceros primero (IsMicrosoft=false), luego Microsoft

#### `Invoke-Win32Uninstall -App`

- Prioridad: QuietUninstallString → MSI `/qn /norestart` → UninstallString interactivo
- Helper privado `_Invoke-UninstallCommand` parsea `"exe" args` y `exe args` sin comillas
- Retorna `Success`, `Method`, `App`, `ExitCode` / `Error`

---

### `main.ps1` — MODIFICADO

#### Menú principal — descripciones

Todas las opciones tienen ahora 2 líneas de descripción en `DarkGray`:

| Opción | Título | Descripción |
|--------|--------|-------------|
| [1] | Deshabilitar Servicios Bloat | Detecta y deshabilita: Xbox, telemetría, Remote Registry, Fax. Selección granular. |
| [2] | Limpieza de Temporales | Scan + preview MB/GB antes de confirmar. 12 rutas incluyendo navegadores. |
| [3] | Mantenimiento del Sistema | DISM RestoreHealth + SFC /scannow. Repara archivos corruptos. |
| [4] | Crear Punto de Restauración | System Restore checkpoint. Habilita C:\ si estaba desactivado. |
| [5] | Optimizar Red | Power saving en NICs + TCP Auto-Tuning + Fast Open + DNS flush. |
| [6] | Rendimiento | Perfiles visuales + Ultimate Performance plan + GameDVR/timeouts/SvcHost. |
| [7] | Snapshot PRE-service | Foto del estado: servicios, startup, disco, batería, AV. |
| [8] | Snapshot POST-service | Segunda foto post-cambios. |
| [9] | Comparar PRE vs POST | Score 0/6 con áreas mejoradas coloreadas. |
| [10] | Historial BSOD | Event Log 90 días + stop codes + guía diagnóstica. |
| [11] | Backup de Drivers | Exporta terceros + red a `output\driver_backup\`. |
| [12] | Apps Win32 + UWP | Listar + desinstalar programas. |
| [T] | Herramientas Externas | Status checker + download on demand + launcher. |

Headers de sección: `[OPTIMIZACION]`, `[DIAGNOSTICO Y AUDITORIA]`, `[APLICACIONES]`, `[HERRAMIENTAS EXTERNAS]`.

#### Opción [12] — Apps Win32 + UWP — NUEVO

Sub-submenú a 2 niveles:

**Win32:**
- Tabla `#` / Nombre / Version / Tamaño MB
- Filtrado con `f texto` (regex + fallback literal), limpiar con `c`
- Antes de desinstalar: preview del método (silencioso / MSI / interactivo)
- Se refresca el listado después de cada desinstalación

**UWP:**
- Apps de Microsoft en `DarkGray`, terceros en `White`
- Filtrado igual que Win32
- Advertencia antes de eliminar paquetes Microsoft
- `Remove-AppxPackage` directo

#### Opción [T] — Herramientas Externas — NUEVO

- Lee `manifest.json` en cada entrada al submenú para calcular estado live
- Tabla `Estado / # / Nombre / Descripcion` con `[OK]` verde o `[--]` gris
- Comandos: `[numero]` abrir, `[D numero]` descargar una, `[DA]` descargar todas las faltantes
- Si se intenta abrir una no descargada: mensaje con sugerencia `[D N]`
- Usa `launchExe` del manifest para saber qué ejecutable lanzar (soporte para ZIPs con subcarpeta)

---

### `tools/manifest.json` — MODIFICADO (v1 → v2)

Campos nuevos: `launchExe` en todas las entradas. Nuevas herramientas:

| Nombre | Archivo | URL | Notas |
|--------|---------|-----|-------|
| `autorunsc` | `autorunsc.exe` | `live.sysinternals.com` | CLI de Autoruns, exporta CSV |
| `shutup10` | `OOSU10.exe` | `dl5.oo-software.com` | Requiere `.cfg` para modo silent |
| `bcu` | `BCUninstaller_portable.zip` | GitHub Releases v5.7 | `type: zip`, `extractDir: BCUninstaller` |

Herramientas existentes: `autoruns`, `procmon`, `procexp`, `tcpview` — mantenidas, con `launchExe` agregado.

---

### `Bootstrap-Tools.ps1` — REESCRITO

| Cambio | Detalle |
|--------|---------|
| `-ToolName` flag | Descarga solo la herramienta especificada por nombre |
| Barra de progreso | `HttpWebRequest` + loop chunked 64 KB. Muestra `X.X / Y.Y MB` en tiempo real |
| Soporte ZIP | `Expand-Archive` → directorio de extracción configurable → elimina el `.zip` |
| `Test-ToolInstalled` | Chequea `extractDir` o `filename` según el tipo |
| `UserAgent` en request | Evita bloqueos de servidores que requieren cabecera |
| Limpieza on error | Si el hash falla o hay error de descarga, elimina el archivo parcial |

---

## Pendiente

| Feature | Prioridad |
|---------|-----------|
| `modules/Privacy.ps1` + perfiles `.cfg` para ShutUp10++ | **Alta** |
| `modules/StartupManager.ps1` (Run keys nativo + launcher Autoruns) | Media |
| SHA-256 en `manifest.json` (fijar versiones de producción) | Baja |
| `Restore-SystemTweaks` en `Performance.ps1` | Baja |
| Tests en VM (testing2) | — |

---

*10/3/2026*
