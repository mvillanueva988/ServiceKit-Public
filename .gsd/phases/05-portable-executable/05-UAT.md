---
status: complete
phase: 05-portable-executable
source:
  - 05-01-SUMMARY.md
  - 05-02-SUMMARY.md
started: 2026-03-10T00:10:00
updated: 2026-03-10T00:15:00
---

## Current Test

[testing complete]

## Tests

### 1. Release.ps1 genera ZIP local

expected: Ejecutar `.\Release.ps1` (sin -Publish). Debe crear `dist\PCTk-<version>.zip` de ~0.1 MB en la raíz del proyecto. El ZIP debe abrirse y contener los archivos del toolkit sin carpeta raíz (main.ps1, modules/, etc. directamente en la raíz del ZIP).
result: pass
auto_verified: "Release.ps1 -Version uat-test generó dist\PCTk-uat-test.zip (0.1 MB) sin errores"

### 2. Launch.ps1 fallback local sin repo configurado

expected: Ejecutar: powershell -ExecutionPolicy Bypass -File .\Launch.ps1 — Como el repo sigue en 'TU_USUARIO/TU_REPO', la llamada a GitHub falla. Launch.ps1 debe detectar que C:\PCTk\ no existe (primera instalación) y mostrar un mensaje claro con la URL de descarga manual — sin excepción de PowerShell sin capturar.
result: pass

### 3. Bootstrap detecta descarga parcial (approxSizeMB)

expected: En tools/manifest.json, una herramienta tiene approxSizeMB definido. Si el ejecutable existe pero pesa menos del 50% de ese valor, Bootstrap-Tools.ps1 muestra "[!] nombre: archivo incompleto, forzando re-descarga" en amarillo, y trata la herramienta como no instalada.
result: pass

### 4. README documenta el one-liner y módulos

expected: Abriendo README.md, la primera sección visible muestra el comando `irm .../Launch.ps1 | iex` (con el placeholder TU_USUARIO/TU_REPO o la URL real). Hay una lista de módulos/funcionalidades del toolkit. No contiene contenido del framework GSD.
result: pass

## Summary

total: 4
passed: 4
issues: 0
pending: 0
skipped: 0

## Gaps

[none]

## Tests

### 1. Release.ps1 genera ZIP local

expected: Ejecutar `.\Release.ps1` (sin -Publish). Debe crear `dist\PCTk-<version>.zip` de ~0.1 MB en la raíz del proyecto. El ZIP debe abrirse y contener los archivos del toolkit sin carpeta raíz (main.ps1, modules/, etc. directamente en la raíz del ZIP).
result: pass
auto_verified: "Release.ps1 -Version uat-test generó dist\PCTk-uat-test.zip (0.1 MB) sin errores"

### 2. Launch.ps1 fallback local sin repo configurado

expected: Ejecutar: powershell -ExecutionPolicy Bypass -File .\Launch.ps1 — Como el repo sigue en 'TU_USUARIO/TU_REPO', la llamada a GitHub falla. Launch.ps1 debe detectar que C:\PCTk\ no existe (primera vez) y mostrar un mensaje claro de error con la URL de descarga manual, sin crashear ni lanzar una excepción de PowerShell sin capturar.
result: pending

### 3. Bootstrap detecta descarga parcial (approxSizeMB)

expected: En tools/manifest.json, una herramienta tiene approxSizeMB definido. Si el ejecutable existe pero pesa menos del 50% de ese valor, Bootstrap-Tools.ps1 muestra "[!] nombre: archivo incompleto, forzando re-descarga" en amarillo y trata la herramienta como no instalada.
result: pending

### 4. README documenta el one-liner y módulos

expected: Abriendo README.md, la primera sección visible muestra el comando `irm .../Launch.ps1 | iex` (con el placeholder TU_USUARIO/TU_REPO o la URL real). Hay una lista de módulos/funcionalidades del toolkit. No contiene contenido del framework GSD.
result: pending

## Summary

total: 4
passed: 1
issues: 0
pending: 3
skipped: 0

## Gaps

[none yet]
