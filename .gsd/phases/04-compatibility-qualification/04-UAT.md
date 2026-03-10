---
status: complete
phase: 04-compatibility-qualification
source:
  - 04-01-SUMMARY.md
started: 2026-03-10T00:00:00
updated: 2026-03-10T00:06:00
---
## Current Test
[testing complete]
## Tests
### 1. Snapshot PRE completa sin crash
expected: Seleccionar [7] en el menu principal. El spinner gira, el job termina, y se muestran resultados de CPU, RAM, disco, bateria y AV sin ningun mensaje de error en rojo. No aparece "Cannot index into null" ni excepcion de PowerShell.
result: pass
### 2. Snapshot funciona con hardware faltante o en VM
expected: Si la maquina es una VM o no tiene GPU dedicada / enclosure fisico, el snapshot igual completa y muestra campos con "N/A" o "Unknown" en lugar de crashear. El menu no queda en loop de error.
result: issue
reported: "En caso de doble GPU (laptops hibridas con iGPU que maneja la pantalla y dedicada para alto rendimiento), que pasa?"
severity: minor
### 3. COMPATIBILITY.md existe con tabla de compatibilidad
expected: En la raiz del proyecto existe COMPATIBILITY.md. Al abrirlo, contiene una tabla Feature x Edicion (Home/Pro/LTSC) y Feature x Arquitectura (x64/x86/ARM64), con notas de comportamiento por entorno.
result: pass
## Summary
total: 3
passed: 2
issues: 1
pending: 0
skipped: 0
## Gaps
- truth: "En laptops con GPU hibrida (iGPU + dGPU), el header del menu muestra ambas GPUs o prioriza la dGPU, no solo la primera que retorna WMI"
  status: failed
  reason: "User reported: en laptops hibridas con iGPU + dGPU, Select-Object -First 1 puede devolver la integrada en lugar de la dedicada"
  severity: minor
  test: 2
  root_cause: "main.ps1 line 40: Get-CimInstance Win32_VideoController | Select-Object -First 1 trunca a una sola GPU. Telemetry.ps1 Get-SystemSnapshot ya itera todas con ForEach-Object — snapshot OK. Solo el header de menu esta afectado."
  fix: "main.ps1: reemplazar Select-Object -First 1 por logica que prioriza dGPU (NVIDIA/AMD/Radeon/GeForce sobre Intel/UHD). Si hay 2+ GPUs, mostrar label con ambas."
  artifacts:
    - main.ps1 line 40
  missing: []
