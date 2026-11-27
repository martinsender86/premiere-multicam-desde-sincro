@echo off
chcp 65001 >nul
title Compilar MulticamDesdeSincro.exe
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Compilar_EXE.ps1"
echo.
pause
