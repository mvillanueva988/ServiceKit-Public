@echo off
color 0B
title PC Optimizacion Toolkit - Launcher

:: 1. Verificar si tenemos permisos de Administrador usando un comando de red fantasma
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :ejecutar
) else (
    echo.
    echo Solicitando elevacion de privilegios...
    :: Se relanza a si mismo pidiendo permisos UAC
    powershell -Command "Start-Process '%~dpnx0' -Verb RunAs"
    exit /b
)

:ejecutar
:: 2. Forzar a que la consola se posicione exactamente donde esta el .bat
:: pushd maneja rutas UNC (ej: \\VBOXSVR\Toolkit) mapeandolas a una letra temporal
pushd "%~dp0"

:: 3. Lanzar el frontend esquivando la Execution Policy
:: %CD% usa la letra de unidad asignada por pushd (evita que $PSScriptRoot resuelva a UNC)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CD%\main.ps1"