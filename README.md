# PC Optimización Toolkit

Toolkit de optimización y diagnóstico para Windows 10/11. Diseñado para uso técnico — servicio a PC de clientes, tanto local como vía AnyDesk.

## Instalación rápida

Abrir PowerShell como administrador y ejecutar:

```powershell
irm https://raw.githubusercontent.com/mvillanueva988/ServiceKit-Public/main/Launch.ps1 | iex
```

Instala en `C:\PCTk\` y lanza el toolkit. Cada ejecución descarga la versión más reciente y valida su integridad (SHA-256) antes de instalar.

## Uso sin one-liner (método manual)

1. Descargar el último release: [Releases](https://github.com/mvillanueva988/ServiceKit-Public/releases)
2. Extraer a cualquier carpeta
3. Click derecho en `Run.bat` → Ejecutar como administrador

## Qué hace

- **Optimización**: servicios bloat, temporales, registro, privacidad, telemetría
- **Diagnóstico**: snapshot pre/post optimización y comparación de resultados
- **Mantenimiento**: Windows Update, chkdsk, SFC, puntos de restauración
- **Performance**: perfiles de energía, apps de inicio, RAM
- **Herramientas externas**: descarga on-demand (Autoruns, WinUtil y más)
- **Trazabilidad**: log persistente de acciones para revisar los cambios aplicados

## Requisitos

- Windows 10 / Windows 11
- PowerShell 5.1 (incluido en Windows)
- Permisos de administrador

## Licencia

MIT — ver [LICENSE](LICENSE)
