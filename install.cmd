@echo off
rem Doble clic para instalar PC Optimizer (solicita permisos de administrador).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -RunNow
pause
