# Bootstrap ServiceKit
$repo = "mvillanueva988/ServiceKit-Installer"
$url = "https://github.com/$repo/releases/latest/download/ServiceKit_v1.6.exe"
$out = "$env:TEMP\ServiceKit_v1.6.exe"

Write-Host "Descargando ServiceKit desde GitHub..." -F Cyan
Invoke-WebRequest -Uri $url -OutFile $out

Write-Host "Iniciando..." -F Green
Start-Process $out