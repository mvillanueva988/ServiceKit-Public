---
status: complete
phase: 04-compatibility-qualification
source:
  - 04-01-SUMMARY.md
started: 2026-03-10T00:00:00
updated: 2026-03-10T00:05:00
---

## Current Test

[testing complete]

## Tests

### 1. Snapshot PRE completa sin crash

expected: Seleccionar [7] en el menú principal. El spinner gira, el job termina, y se muestran resultados de CPU, RAM, disco, batería y AV sin ningún mensaje de error en rojo. No aparece "Cannot index into null" ni excepción de PowerShell.
result: pass

### 2. Snapshot funciona con hardware faltante o en VM

expected: Si la máquina es una VM o no tiene GPU dedicada / enclosure físico, el snapshot igual completa y muestra campos con "N/A" o "Unknown" en lugar de crashear. El menú no queda en loop de error.
result: issue
reported: "En caso de doble GPU (laptops híbridas con iGPU que maneja la pantalla y dedicada para alto rendimiento), qué pasa?"
severity: minor

### 3. COMPATIBILITY.md existe con tabla de compatibilidad

expected: En la raíz del proyecto existe COMPATIBILITY.md. Al abrirlo, contiene una tabla Feature × Edición (Home/Pro/LTSC) y Feature × Arquitectura (x64/x86/ARM64), con notas de comportamiento por entorno.
result: pass

## Summary

total: 3
passed: 2
issues: 1
pending: 0
skipped: 0

## Gaps

- truth: "En laptops con GPU híbrida (iGPU + dGPU), el snapshot y el header del menú muestran ambas GPUs o al menos la correcta (dedicada), no solo la primera que devuelve WMI"
  status: failed
  reason: "User reported: en laptops híbridas con iGPU + dGPU, Select-Object -First 1 puede devolver la integrada en lugar de la dedicada, o ignorar la segunda GPU completamente"
  severity: minor
  test: 2
  artifacts: []
  missing: []

## Tests

### 1. Snapshot PRE completa sin crash

expected: Seleccionar [7] en el menú principal. El spinner gira, el job termina, y se muestran resultados de CPU, RAM, disco, batería y AV sin ningún mensaje de error en rojo. No aparece "Cannot index into null" ni excepción de PowerShell.
result: pass

### 2. Snapshot funciona con hardware faltante o en VM

expected: Si la máquina es una VM o no tiene GPU dedicada / enclosure físico, el snapshot igual completa y muestra campos con "N/A" o "Unknown" en lugar de crashear. El menú no queda en loop de error.
result: issue
reported: "En caso de doble GPU (laptops híbridas con iGPU que maneja la pantalla y dedicada para alto rendimiento), qué pasa?"
severity: minor

### 3. COMPATIBILITY.md existe con tabla de compatibilidad

expected: En la raíz del proyecto existe COMPATIBILITY.md. Al abrirlo, contiene una tabla Feature × Edición (Home/Pro/LTSC) y Feature × Arquitectura (x64/x86/ARM64), con notas de comportamiento por entorno.
result: pending

## Summary

total: 3
passed: 1
issues: 1
pending: 1
skipped: 0

## Gaps

- truth: "En laptops con GPU híbrida (iGPU + dGPU), el snapshot y el header del menú muestran ambas GPUs o al menos la correcta (dedicada), no solo la primera que devuelve WMI"
  status: failed
  reason: "User reported: en laptops híbridas con iGPU + dGPU, Select-Object -First 1 puede devolver la integrada en lugar de la dedicada, o ignorar la segunda GPU completamente"
  severity: minor
  test: 2
  artifacts: []
  missing: []
