# PC Optimizacion Toolkit

## What This Is

Toolkit de optimización de PC escrito íntegramente en PowerShell 5.1, sin dependencias externas de código. Permite a técnicos aplicar optimizaciones de rendimiento, limpieza, privacidad, diagnóstico y gestión de aplicaciones sobre máquinas Windows desde una consola interactiva con menú, todo en background asíncrono via `Start-Job`.

## Core Value

El técnico ejecuta una acción y la consola nunca bloquea — cada operación pesada corre en background con spinner visual, confirmación previa donde aplica, y resultado claro al finalizar.

## Requirements

### Validated

- ✓ Privacy.ps1: lanzador de ShutUp10++ GUI con check de disponibilidad — Phase 2
- ✓ Motor asíncrono (`JobManager.ps1`) — sesión 1
- ✓ Debloat de servicios con selección granular — sesión 1
- ✓ Limpieza de temporales con preview de espacio — sesión 1/3
- ✓ Mantenimiento del sistema (DISM + SFC) — sesión 1
- ✓ Punto de restauración automático — sesión 1
- ✓ Optimización de red (NICs + TCP/DNS) — sesión 1
- ✓ Rendimiento: 4 perfiles visuales + Ultimate Power Plan + System Tweaks — sesión 3/4
- ✓ Auditoría PRE/POST con score comparativo — sesión 2
- ✓ Historial de BSOD con lookup de stop codes — sesión 3/4
- ✓ Backup de drivers (terceros + red) — sesión 3
- ✓ Apps Win32 + UWP: listar, filtrar, desinstalar — sesión 5
- ✓ Startup Manager: Run keys + carpetas, toggle enable/disable — sesión 5
- ✓ Herramientas externas: manifest + Bootstrap con barra de progreso — sesión 4/5

### Active

_(nada pendiente — Phase 2 completa)_

### Out of Scope

- SHA-256 llenos en manifest.json — diferido a pre-producción cuando se fijen versiones específicas
- `Restore-SystemTweaks` — revierte tweaks de registro; baja prioridad, no solicitado aún
- GUI / interfaz gráfica — el target es consola PowerShell, sin WPF ni WinForms
- Descarga automática de updates de Windows — fuera del scope del toolkit
- BCUninstaller integrado al flujo — disponible como herramienta externa descargable, no integrado nativamente
- Privacy.ps1 con perfiles `.cfg` nativos — descartado: el formato no tiene especificación pública estable; ShutUp10++ tiene su propio sistema de export/import

## Context

- PowerShell 5.1 sobre Windows 10/11. Sin PS 7 ni módulos de terceros.
- Todo via CIM/WMI, APIs nativas de Windows, y snippets `Add-Type` donde aplica.
- El patrón de serialización de funciones al job (`.ToString()` + `Invoke-Expression`) es el mecanismo estándar ya establecido para pasar funciones a runspaces aislados de `Start-Job`.
- Privacy.ps1 lanza `OOSU10.exe` GUI directamente (check de disponibilidad incluido). La gestión de perfiles queda dentro de ShutUp10++ nativo.
- `tools/bin/` está en `.gitignore` — los binarios no se versionen, se descargan via Bootstrap.
- La carpeta `/oldscripts` es referencia temporal (sesiones 1-2 para rescatar lógica) — se elimina al cierre del proyecto.

## Constraints

- **Tech stack**: PowerShell 5.1 únicamente — sin dependencias de código externo descargable en runtime
- **Asincronismo**: `Start-Job` obligatorio para operaciones pesadas — nunca bloquear la consola principal
- **Strictmode**: `Set-StrictMode -Version Latest` en todos los archivos — no negociable
- **No external binaries in repo**: Herramientas externas declaradas en `manifest.json`, descargadas por el usuario via Bootstrap

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| `Start-Job` para toda operación pesada | Sin bloqueo de consola. Patrón universal; spinner visual como feedback | ✓ Bueno |
| Preview→Confirm para operaciones destructivas | `-WhatIf` no funciona en `Start-Job`. Preview síncrono logra el mismo objetivo sin complejidad | ✓ Bueno |
| Serialización de funciones al job via `.ToString()` | Los jobs corren en runspace aislado sin acceso al scope padre | ✓ Bueno |
| Privacy via OOSU10.exe GUI (lanzador directo) | Formato `.cfg` no tiene especificación pública estable; ShutUp10++ maneja sus propios perfiles internamente | ✓ Bueno |
| `StartupApproved` para toggle de entradas de inicio | Método oficial Windows 10/11. No destruye la entrada original | ✓ Bueno |
| `SvcHostSplitThreshold` condicional a ≤ 8 GB RAM | En sistemas con más RAM el split no genera overhead medible | ✓ Bueno |
| manifest.json + Bootstrap script para herramientas externas | Sin git-lfs, sin submodules, sin inflar el repo | ✓ Bueno |

---

_Last updated: 2026-03-10 — Phase 2 completa. Privacy.ps1 = lanzador GUI._
