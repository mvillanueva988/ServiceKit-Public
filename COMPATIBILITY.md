# Compatibility Matrix

PC Optimización Toolkit — soporte por feature × edición Windows.

**Leyenda:** ✅ Funciona completo · ⚠️ Funciona con limitaciones · ❌ No disponible · 🔄 Degrada gracefully

---

## Soporte por Módulo

| Módulo / Feature | W10 Home | W10 Pro | W10 LTSC | W11 Home | W11 Pro | Notas |
|-----------------|----------|---------|----------|----------|---------|-------|
| **[1] Debloat** — deshabilitar servicios | ✅ | ✅ | ✅ | ✅ | ✅ | Servicios inexistentes se omiten silenciosamente |
| **[2] Cleanup** — archivos temporales | ✅ | ✅ | ✅ | ✅ | ✅ | Rutas de usuario vía `Win32_UserProfile` + fallback `C:\Users` |
| **[3] Maintenance** — DISM + SFC | ✅ | ✅ | ⚠️ | ✅ | ✅ | DISM requiere internet o WSUS en LTSC; SFC siempre funciona |
| **[4] Restore Point** | ✅ | ✅ | ✅ | ✅ | ✅ | `Checkpoint-Computer` en try/catch; falla silenciosa si SR deshabilitado |
| **[5] Network** — NIC + TCP | ✅ | ✅ | ✅ | ✅ | ✅ | Propiedades de NIC no presentes se omiten silenciosamente |
| **[6] Performance** — perfiles visuales | ✅ | ✅ | ✅ | ✅ | ✅ | Registry HKCU — no requiere admin |
| **[6] Performance** — Ultimate Power Plan | 🔄 | ✅ | 🔄 | 🔄 | ✅ | Fallback automático a High Performance en Home/LTSC |
| **[6] Performance** — System Tweaks | ✅ | ✅ | ✅ | ✅ | ✅ | SvcHostSplitThreshold omitido si RAM > 8 GB |
| **[7] Telemetría** — snapshot PRE/POST | ✅ | ✅ | 🔄 | ✅ | ✅ | CIM blocks degradan a valores vacíos/cero si WMI inaccesible |
| **[7] Telemetría** — discos SMART | 🔄 | 🔄 | 🔄 | 🔄 | 🔄 | `Get-PhysicalDisk` requiere módulo Storage; lista vacía si ausente |
| **[7] Telemetría** — antivirus | ✅ | ✅ | ⚠️ | ✅ | ✅ | `root/SecurityCenter2` puede estar vacío en LTSC sin WD activo |
| **[8] Diagnósticos** — BSOD history | ✅ | ✅ | ✅ | ✅ | ✅ | Lee Event Log System — no requiere admin |
| **[8] Diagnósticos** — Driver backup | ✅ | ✅ | ✅ | ✅ | ✅ | `pnputil /export-driver` disponible W8+ |
| **[9] Apps Win32** | ✅ | ✅ | ✅ | ✅ | ✅ | Lee 3 hives (HKLM 64/32-bit + HKCU) |
| **[10] Apps UWP** | ✅ | ✅ | 🔄 | ✅ | ✅ | LTSC: `Get-AppxPackage` devuelve lista vacía o mínima — OK |
| **[11] Startup Manager** | ✅ | ✅ | ✅ | ✅ | ✅ | `StartupApproved` registry disponible desde W8 |
| **[12] Privacy** — perfiles nativos | ✅ | ✅ | ✅ | ✅ | ✅ | Solo registry HKCU/HKLM — sin dependencias UWP |
| **[13] Privacy** — opciones | ✅ | ✅ | ✅ | ✅ | ✅ | |
| **[T] Tools** — descarga herramientas | ✅ | ✅ | ✅ | ✅ | ✅ | Requiere internet; SHA-256 no validado (URLs apuntan a "latest") |

---

## Arquitectura

| Feature | x64 | x86 | ARM64 |
|---------|-----|-----|-------|
| Core toolkit | ✅ | ✅ | ⚠️ best-effort |
| Ultimate Power Plan | ✅ | ✅ | 🔄 fallback a High Performance |
| `pnputil` driver backup | ✅ | ✅ | ✅ |
| WOW6432Node (Apps Win32) | ✅ (leído) | ✅ | ✅ |

ARM64: No testeado. PowerShell native en ARM64 tiene paridad funcional con x64 para todos los cmdlets usados.

---

## Notas de Compatibilidad

### DISM /RestoreHealth en LTSC
LTSC no incluye fuente de reparación por defecto. DISM retorna código `50` (error) si no hay acceso a Windows Update o fuente ISO. El toolkit captura el exit code y lo muestra al usuario — no crashea.

**Workaround manual** (fuera del scope del toolkit):
```
DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:1
```

### Ultimate Power Plan en Home/LTSC
El plan "Ultimate Performance" no está disponible en Windows Home ni en algunas LTSC. El toolkit detecta su ausencia y activa "High Performance" automáticamente, informando al usuario del fallback.

### Get-PhysicalDisk (SMART)
El cmdlet `Get-PhysicalDisk` pertenece al módulo `Storage`, que no está disponible en Server Core ni instalaciones mínimas de LTSC. En esos entornos, la sección de discos en el snapshot aparece vacía (`Disks: []`). El resto del snapshot funciona normalmente.

### SecurityCenter2 en LTSC
El namespace WMI `root/SecurityCenter2` puede devolver resultados vacíos en LTSC si Windows Defender está deshabilitado y no hay AV de terceros registrado. El código usa try/catch — resultado: lista de antivirus vacía, sin crash.

### Apps UWP en LTSC
LTSC 2019/2021 incluye `Get-AppxPackage` pero la lista de apps es mínimamente poblada (no hay Store, no hay Xbox, etc.). El módulo de Apps funciona correctamente — simplemente lista lo que hay.

---

## Out of Scope

Funcionalidad explícitamente no implementada en este toolkit:

| Feature | Razón |
|---------|-------|
| `Restore-SystemTweaks` (revertir tweaks) | No solicitado. System Restore Point cumple el mismo propósito de forma más completa |
| Validación SHA-256 de herramientas externas | URLs apuntan a "latest" — sin hash fijo estable. Decisión documentada en manifest.json |
| Soporte Windows 7/8/8.1 | EOL, fuera del target del toolkit |
| Soporte Server (2016/2019/2022) | No es el caso de uso — puede funcionar parcialmente |
