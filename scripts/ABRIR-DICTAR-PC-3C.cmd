@echo off
setlocal
cd /d "%~dp0"
py -3 "DictarPC3C-Wispr.py"
if errorlevel 1 (
  echo.
  echo No se inicio DICTAR PC 3C. Verifica que Python 3 incluya Tkinter.
  echo Desde una consola Windows puedes verificar: py -m tkinter
  pause
)
