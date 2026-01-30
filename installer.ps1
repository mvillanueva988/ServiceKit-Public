# Bootstrap ServiceKit
$repo = "mvillanueva988/ServiceKit-Public"
$url = "https://github.com/$repo/releases/latest/download/ServiceKit_v1.7.exe"
$out = "$env:TEMP\ServiceKit_v1.7.exe"

Write-Host "Descargando ServiceKit desde GitHub..." -F Cyan
Invoke-WebRequest -Uri $url -OutFile $out

Write-Host "Iniciando..." -F Green

Start-Process $out

