# Phase 9: Deployment - Context

**Gathered:** 2026-03-10
**Status:** Ready for planning — REQUIERE acción del usuario (ver abajo)

<domain>
## Phase Boundary

Publicar el toolkit en GitHub y validar que el flujo de distribución funciona end-to-end: el técnico corre una sola línea en PowerShell, el script se descarga, descomprime, y el toolkit queda listo para usar. Incluye documentación de deployment en README.

</domain>

<decisions>
## Implementation Decisions

### 09-01: Release Setup

**$GitHubRepo en Launch.ps1:**
- El usuario debe proveer su `usuario/repo` de GitHub antes de ejecutar esta fase
- Una vez configurado, Launch.ps1 puede auto-actualizar desde GitHub Releases

**Release.ps1 validación:**
- Ejecutar Release.ps1 end-to-end: build → genera ZIP en `dist/`
- Verificar que el ZIP contiene la estructura correcta: `main.ps1`, `core/`, `modules/`, `utils/`, `tools/manifest.json`, `Launch.ps1`
- Upload manual a GitHub Releases (o via API si el token está configurado)

**Estructura esperada del ZIP:**
```
PCToolkit-vX.Y.Z.zip
├── main.ps1
├── Launch.ps1
├── core/
├── modules/
├── utils/
├── tools/manifest.json
└── README.md
```

### 09-02: Deploy Docs & First-Run

**README — sección de instalación:**
- One-liner de PowerShell para descarga e instalación (via `Launch.ps1` o iwr directo)
- Ejemplo: `iwr https://raw.githubusercontent.com/usuario/repo/main/Launch.ps1 | iex`
- Requisitos: Windows 10/11, PowerShell 5.1+, ejecutar como Administrador

**Validación del flujo completo:**
- Simular un "PC nuevo": descargar Launch.ps1 manualmente → ejecutar → verifica release → descarga ZIP → expande → lanza main.ps1
- Verificar que main.ps1 arranca correctamente desde el `$InstallPath` definido en Launch.ps1

**CHANGELOG:**
- Revisar CHANGELOG.md y asegurar que la versión actual (`v1.0.0` o la que corresponda) está documentada con todos los cambios

</decisions>

<specifics>
## Specific Ideas

- El one-liner de instalación es el "money shot" del proyecto — debe funcionar perfectamente
- El flujo de Launch.ps1 ya existe (Phase 5), esta fase lo valida y documenta, no lo reimplementa

</specifics>

<blocked>
## Blocked On

**REQUIERE DEL USUARIO antes de ejecutar:**
- Nombre del repositorio de GitHub: `usuario/repo` (ej: `mateo/pc-toolkit`)
- Sin esto, el 09-01 no puede configurar Launch.ps1 ni publicar releases

**Workaround:** Si el usuario no tiene repo aún, 09-01 puede:
1. Crear el repo en GitHub (manual por el usuario)
2. Configurar $GitHubRepo con el nombre correcto
3. Ejecutar Release.ps1 para generar el primer ZIP

</blocked>

<deferred>
## Deferred Ideas

- GitHub Actions para releases automáticos (CI/CD) — futuro
- Chocolatey package — futuro si se quiere distribución más amplia

</deferred>

---

_Phase: 09-deployment_
_Context gathered: 2026-03-10_
