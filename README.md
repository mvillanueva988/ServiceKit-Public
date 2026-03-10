# PC Optimización Toolkit

Toolkit de optimización y diagnóstico para Windows 10/11. Diseñado para uso técnico — servicio a PC de clientes, tanto local como vía AnyDesk.

## Instalación rápida

Abrir PowerShell como administrador y ejecutar:

```powershell
irm https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/Launch.ps1 | iex
```

Instala en `C:\PCTk\` y lanza el toolkit. Cada ejecución descarga la versión más reciente.

## Qué hace

- **Optimización**: Servicios bloat, temporales, registro, privacidad, telemetría
- **Diagnóstico**: Snapshot pre/post optimización, comparación de resultados
- **Mantenimiento**: Windows Update, chkdsk, SFC, puntos de restauración
- **Performance**: Perfiles de energía, startup apps, RAM
- **Herramientas externas**: Descarga on-demand (Autoruns, WinDirStat, WinUtil, Sophia, y más)

## Uso sin one-liner (método manual)

1. Descargar el último release: [Releases](https://github.com/TU_USUARIO/TU_REPO/releases)
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

## Licencia

MIT — ver [LICENSE](LICENSE)
