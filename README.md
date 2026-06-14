# PC Optimización Toolkit

Toolkit de optimización y diagnóstico para Windows 10/11. Diseñado para uso técnico — servicio a PC de clientes, tanto local como vía AnyDesk.

## Instalación rápida

Abrir PowerShell como administrador y ejecutar:

```powershell
$f = "$env:TEMP\PCTk-Launch.ps1"; irm https://raw.githubusercontent.com/mvillanueva988/ServiceKit-Public/v2.3.1/Launch.ps1 -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

Reemplaza `v2.3.1` por el tag de la última release estable. Instala en `C:\PCTk\` y lanza el toolkit. Cada ejecución descarga la versión más reciente y valida su integridad (SHA-256) antes de instalar.

> Nota: se descarga a un archivo y se ejecuta con `powershell -NoProfile -ExecutionPolicy Bypass -File`, no `| iex` ni `& archivo` directo. Motivo: `| iex` rompe porque Launch.ps1 usa `#Requires` y tiene BOM UTF-8 (necesario para el parser en locales no-inglés); y `& archivo` directo lo bloquea la Execution Policy `Restricted` de una máquina nueva. `-ExecutionPolicy Bypass -File` maneja ambos correctamente.

### Verificación (opcional, recomendada)

Para validar Launch.ps1 antes de ejecutarlo, comparar el SHA-256 contra el valor publicado en las [release notes](https://github.com/mvillanueva988/ServiceKit-Public/releases):

```powershell
$f = "$env:TEMP\Launch.ps1"
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/mvillanueva988/ServiceKit-Public/v2.3.1/Launch.ps1' -OutFile $f
(Get-FileHash $f -Algorithm SHA256).Hash
# Si el hash coincide con el publicado, ejecutar el archivo:
# powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

## Uso sin one-liner (método manual)

1. Descargar el último release: [Releases](https://github.com/mvillanueva988/ServiceKit-Public/releases)
2. Extraer a cualquier carpeta
3. Click derecho en `Run.bat` → Ejecutar como administrador

## Qué hace

Optimizador por perfiles: el técnico elige el use-case del cliente desde el menú y el toolkit aplica una receta pre-fabricada con snapshot PRE/POST automatizado. La diferenciación por hardware (laptop vs desktop, RAM ≤ 8 GB, etc.) la aplica el módulo `Performance` al ejecutarse — no hay que elegir tier.

**Use-cases disponibles:**
- **Generic** — PC sin contexto claro de uso (receta neutra y segura)
- **Work** — trabajo administrativo o estudio: Office, Outlook, Teams, browser pesado, videollamadas, impresión
- **Multimedia** — streaming de series, deportes y películas (preserva Xbox/Game Pass casual)

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
