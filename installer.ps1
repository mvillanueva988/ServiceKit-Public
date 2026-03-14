# Bootstrap ServiceKit
$repo = "mvillanueva988/ServiceKit-Public"
$file = "ServiceKit_v1.7.exe" # Asegúrate que coincida con tu versión actual
$url = "https://github.com/$repo/releases/latest/download/$file"
$out = "$env:TEMP\$file"

Write-Host "Descargando ServiceKit desde GitHub..." -F Cyan

# --- ESTA ES LA LINEA MAGICA ---
# Desactiva la barra de progreso para liberar la velocidad de descarga
$ProgressPreference = 'SilentlyContinue'
# -------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ahora la descarga volará
Invoke-WebRequest -Uri $url -OutFile $out

Write-Host "Iniciando..." -F Green
Start-Process $out
