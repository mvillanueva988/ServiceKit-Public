# Matriz de Compatibilidad

PC Optimización Toolkit v2.0.0 — soporte por feature × edición Windows.

**Leyenda:** ✅ Funciona completo · ⚠️ Funciona con limitaciones (ver notas) · ❌ No disponible · 🔄 Degrada gracefully (muestra advertencia y continúa)

---

## Modelo de perfiles

El toolkit organiza la optimización en **use-cases × tiers**. Mateo elige el use-case del cliente en el menú; el toolkit detecta el tier de hardware automáticamente.

### Use-cases

| Use-case | Para qué cliente | Servicios tocados | Privacy | Visuales |
|----------|-----------------|-------------------|---------|---------|
| **Generic** | PC sin contexto claro de uso | Fax, WMPNetworkSvc, RemoteRegistry, DiagTrack, dmwappushservice | Basic | Balanced |
| **Office** | Trabajo administrativo (Office, Outlook, Teams) | Base + Xbox×4 | Medium | Balanced |
| **Study** | Estudiante (browser pesado, videollamadas, impresión) | Base + Xbox×4 | Medium | Balanced |
| **Multimedia** | Streaming series/deportes/películas | Base (preserva Xbox) | Medium | Balanced (Low/Mid) · Full (High) |

**Preservados en todos los use-cases salvo excepción explícita:**
- `Spooler` / `PrintNotify` (impresión) — preservados en Office, Study. Neutral en Generic/Multimedia.
- `RemoteAccess` (VPN corporativa) — preservado en Office. Neutral en resto.
- Xbox×4 (`XblAuthManager`, `XblGameSave`, `XboxNetApiSvc`, `XboxGipSvc`) — preservados en Generic y Multimedia; deshabilitados en Office y Study (no son PCs de juego).

### Tiers de hardware

| Tier | RAM típica | CPU | GPU |
|------|-----------|-----|-----|
| **Low** | ≤8 GB | U-series ≤i5 / Celeron / Pentium / Ryzen U ≤R3 | iGPU only |
| **Mid** | 12–16 GB | U-series alto (i7-U, R7-U) / H-series ≤i5/R5 | iGPU o dGPU ≤4 GB VRAM |
| **High** | ≥16 GB | H-series ≥i7/R7 / desktop K/X | dGPU ≥6 GB VRAM |

La diferencia funcional entre tiers la aplica `Start-PerformanceProcess` (power plan laptop-aware, svchost si ≤8 GB RAM, etc.) — no el JSON de la receta directamente.

---

## Soporte por edición Windows

| Feature / Módulo | W10 Home | W10 Pro | W10 LTSC | W11 Home | W11 Pro | W11 24H2 | Notas |
|-----------------|----------|---------|----------|----------|---------|----------|-------|
| **Aplicar receta auto** (Debloat) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Servicios inexistentes se omiten silenciosamente |
| **Cleanup** — temporales | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Rutas via `Win32_UserProfile` + fallback `C:\Users` |
| **Mantenimiento** — DISM + SFC | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ | DISM requiere internet o fuente ISO en LTSC |
| **Punto de restauración** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `Checkpoint-Computer` en try/catch; falla silenciosa si SR deshabilitado |
| **Red** — NIC + TCP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Propiedades ausentes se omiten; `netsh fastopen` solo en builds compatibles |
| **Performance** — perfil visual | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Registry HKCU — no requiere admin |
| **Performance** — Ultimate Power Plan | 🔄 | ✅ | 🔄 | 🔄 | ✅ | ✅ | Fallback automático a High Performance en Home/LTSC; en laptops aplica Balanced |
| **Performance** — System Tweaks | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | SvcHostSplitThreshold omitido si RAM > 8 GB |
| **Privacy** — perfiles nativos | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Solo registry HKCU/HKLM — sin dependencias UWP |
| **Privacy** — OOSU10 opcional | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | El engine cae a privacy nativo si OOSU10.exe o `.cfg` no están presentes |
| **Telemetría** — snapshot PRE/POST | ✅ | ✅ | 🔄 | ✅ | ✅ | ✅ | Campos CIM degradan a vacío si WMI inaccesible |
| **Telemetría** — discos SMART | 🔄 | 🔄 | 🔄 | 🔄 | 🔄 | 🔄 | `Get-PhysicalDisk` requiere módulo Storage; lista vacía si ausente |
| **Telemetría** — antivirus | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ | `root/SecurityCenter2` puede estar vacío en LTSC sin Defender activo |
| **Apps Win32** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Lee 3 hives (HKLM 64/32-bit + HKCU) |
| **Apps UWP** | ✅ | ✅ | 🔄 | ✅ | ✅ | ✅ | LTSC: `Get-AppxPackage` devuelve lista mínima — OK |
| **Startup Manager** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | `StartupApproved` registry disponible desde W8; report-only en v2.0 |
| **Research Prompt** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Scrubbing automático de ComputerName/dominio en Pro/Enterprise |
| **Herramientas externas** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Requiere internet; SHA-256 no validado (URLs "latest") |

---

## Modo VM (entorno virtualizado)

Cuando el toolkit detecta que se ejecuta dentro de una máquina virtual (Hyper-V, VMware, VirtualBox, etc.) via WMI, entra en **modo VM**:

- El banner del menú muestra `VM : <vendor>` (ej. `VM : Microsoft Corporation`).
- Los queries de snapshot que no aplican en VM se omiten automáticamente:
  - Discos SMART (`Get-PhysicalDisk`) — no hay disco físico real.
  - Dispositivos PnP/HID — puede devolver resultados incompletos o vacíos.
  - Zonas térmicas ACPI — no hay sensores físicos.
  - Estado de batería — no aplica en VM de escritorio.
- Los queries que sí aplican (red, procesos, registry, servicios, telemetría) se ejecutan normalmente.
- Un timeout por query evita cuelgues si el host WMI está degradado.

El modo VM es útil para testear el toolkit en Windows Sandbox antes de aplicarlo en PCs reales.

---

## Notas de Compatibilidad

### LTSC — caveat de licenciamiento

Windows 10/11 LTSC está disponible solo bajo licencia de volumen (OEM Sistema/COEM o licencias de volumen empresariales). **No está pensado para PCs de consumo general.** El toolkit funciona en LTSC pero:

- DISM `/RestoreHealth` requiere fuente de reparación explícita (internet o ISO con `/Source:wim:`).
- `Get-AppxPackage` devuelve lista mínima (sin Store, sin Xbox, etc.) — el módulo lo maneja correctamente.
- `root/SecurityCenter2` puede estar vacío si Defender está deshabilitado y no hay AV de terceros.
- Ultimate Power Plan puede no estar disponible — el toolkit cae a High Performance automáticamente.

**Recomendación**: usar W10 Home/Pro o W11 Home/Pro para clientes de servicio técnico típico. LTSC solo si el cliente ya lo tiene por política de IT.

### Win11 24H2

Totalmente soportado. La fix de `netsh fastopen` (no válido en `set global` en 24H2) ya está aplicada. La optimización de Branch Prediction (KB5041587) se aplica automáticamente al estar en 24H2+ — sin acción del toolkit.

### Ultimate Power Plan en laptops

En laptops con TDP limitado por EC (la mayoría de notebooks de oficina y estudio), Ultimate Performance activa el procesador a frecuencia sostenida máxima — lo que resulta en más calor y throttle más agresivo, no en mejor performance. El toolkit detecta si es laptop y aplica Balanced automáticamente, informando al usuario.

### OOSU10 (ShutUp10++) — opcional

Los `.cfg` de OOSU10 (`basic.cfg`, `medium.cfg`, `multimedia.cfg`) son opcionales y no están incluidos en el ZIP de distribución (son deliverables manuales de configuración). Si OOSU10.exe o el `.cfg` correspondiente a la receta no están en `data/oosu10-profiles/`, el engine aplica el perfil de privacy nativo equivalente (registry HKCU/HKLM) sin interrupción.

---

## Arquitectura

| Feature | x64 | x86 | ARM64 |
|---------|-----|-----|-------|
| Core toolkit | ✅ | ✅ | ⚠️ best-effort |
| Ultimate Power Plan | ✅ | ✅ | 🔄 fallback a High Performance |
| `pnputil` driver backup | ✅ | ✅ | ✅ |
| WOW6432Node (Apps Win32) | ✅ | ✅ | ✅ |

ARM64: no testeado. PowerShell nativo en ARM64 tiene paridad funcional con x64 para todos los cmdlets usados.

---

## Out of Scope

| Feature | Razón |
|---------|-------|
| Revertir tweaks (Restore-SystemTweaks) | El Restore Point automático cumple el mismo propósito de forma más completa |
| Validación SHA-256 de herramientas externas | URLs apuntan a "latest" — sin hash fijo estable |
| Soporte Windows 7/8/8.1 | EOL, fuera del target |
| Soporte Windows Server (2016/2019/2022) | No es el caso de uso — puede funcionar parcialmente |
| Perfiles nombrados (gaming personalizado) | Stage 4 — diferido |
| Auto-disable de startup items | Stage 4 — en v2.0 es report-only |
| `.cfg` OOSU10 incluidos en el ZIP | Deliverables manuales de configuración |
