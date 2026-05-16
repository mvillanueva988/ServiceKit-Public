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

Optimizador por perfiles: el técnico elige el use-case del cliente desde el menú, el toolkit detecta el tier de hardware (Low/Mid/High) y aplica una receta pre-fabricada con snapshot PRE/POST automatizado.

**Use-cases disponibles:**
- **Generic** — PC sin contexto claro de uso (receta neutra y segura)
- **Office** — trabajo administrativo con Office, Outlook, Teams
- **Study** — estudiante con browser pesado y videollamadas
- **Multimedia** — streaming de series, deportes y películas

**Cada ejecución incluye:**
- **Debloat**: servicios innecesarios deshabilitados según use-case (no toca impresión, VPN ni Xbox si el use-case los necesita)
- **Performance**: power plan laptop-aware, perfil visual, tweaks seguros
- **Privacy**: nivel Basic o Medium via registry nativo o OOSU10 (opcional)
- **Cleanup**: temporales del usuario y del sistema
- **Diagnóstico**: snapshot pre/post con comparación de resultados; carpeta de cliente en `output/clients/`
- **Herramientas externas**: descarga on-demand (BCUninstaller, WizTree, CPU-Z y más)
- **Research Prompt**: genera prompt estructurado para LLMs con el perfil del hardware detectado
- **Trazabilidad**: log persistente de acciones por sesión

## Requisitos

- Windows 10 / Windows 11
- PowerShell 5.1 (incluido en Windows)
- Permisos de administrador

## Licencia

MIT — ver [LICENSE](LICENSE)
