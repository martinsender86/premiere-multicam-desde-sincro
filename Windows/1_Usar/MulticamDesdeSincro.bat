@echo off
chcp 65001 >nul
title Multicam desde Sincro
echo.
echo  MULTICAM DESDE SINCRO
echo  Cerra el proyecto en Premiere antes de seguir.
echo  Se genera una COPIA del .prproj con las multicam; el original no se toca.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MulticamDesdeSincro.ps1" "%~1"
echo.
pause
