@echo off
setlocal
cd /d "%~dp0"
echo Iniciando Databricks App desde el ultimo MAIN del backend...
powershell.exe -NoProfile -File "%~dp0Encender-Databricks-Main.ps1" -AbrirApp
if errorlevel 1 (
  echo.
  echo Error al iniciar o desplegar. Revisa GitHub, CLI Databricks y el perfil asistente-cloud-erp.
  pause
)
