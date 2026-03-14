# PC Optimización Toolkit

Toolkit de optimización y diagnóstico para Windows 10/11. Diseñado para uso técnico — servicio a PC de clientes, tanto local como vía AnyDesk.

## Instalación rápida

Abrir PowerShell como administrador y ejecutar:

```powershell
irm https://raw.githubusercontent.com/mvillanueva988/ServiceKit-Public/main/Launch.ps1 | iex
```

Instala en `C:\PCTk\` y lanza el toolkit. Cada ejecución descarga la versión más reciente.
El launcher valida el SHA-256 del ZIP antes de instalar (requiere asset `.sha256` en el release).

## Qué hace

- **Optimización**: Servicios bloat, temporales, registro, privacidad, telemetría
- **Diagnóstico**: Snapshot pre/post optimización, comparación de resultados
- **Mantenimiento**: Windows Update, chkdsk, SFC, puntos de restauración
- **Performance**: Perfiles de energía, startup apps, RAM
- **Herramientas externas**: Descarga on-demand (Autoruns, WinDirStat, WinUtil y más)
- **Trazabilidad**: Log persistente de acciones en `output\audit\` para revisar cambios aplicados

## Uso sin one-liner (método manual)

1. Descargar el último release: [Releases](https://github.com/mvillanueva988/ServiceKit-Public/releases)
2. Extraer a cualquier carpeta
3. Click derecho en `Run.bat` → Ejecutar como administrador

## Requisitos

- Windows 10 / Windows 11
- PowerShell 5.1 (incluido en Windows)
- Permisos de administrador

## Publicar nuevo release

Desde la raíz del repositorio:

```powershell
.\Release.ps1                         # genera dist\PCTk-YYYY.MM.DD.zip
.\Release.ps1 -Publish                # genera + sube a GitHub Releases (requiere $env:GITHUB_TOKEN)
.\Release.ps1 -Version '2026.03.10'   # versión manual
```

Cada release genera también `dist\PCTk-YYYY.MM.DD.zip.sha256` y, con `-Publish`, se sube como asset para validación en `Launch.ps1`.

## Licencia

MIT — ver [LICENSE](LICENSE)
