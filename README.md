# Multicam desde Sincro — v1.3

Herramienta para **Premiere Pro** (Windows y Mac).

## Qué hace

Arma **una Multicamera Source Sequence por cada grupo** de una secuencia de sincro de Premiere.

- Escribe una **copia** del proyecto (`<nombre>_MULTICAM.prproj`) con un bin `<secuencia>_multicams`. El proyecto original no se toca.
- Deja al lado un `_log.txt` con el detalle.

## Requisitos

- **Premiere cerrado.**
- El proyecto tiene que tener **al menos una multicam hecha a mano**, que se usa de modelo (mejor si es con audio Multichannel).
- Windows 10/11: nada extra. Mac: PowerShell para Mac (https://aka.ms/powershell-release?tag=stable o `brew install --cask powershell`).

## Cómo se usa

Se elige la secuencia de sincro por número (Enter = la primera; las SYNC aparecen arriba).

**Windows**
- `Windows/1_Usar/`: arrastrá el `.prproj` sobre `MulticamDesdeSincro.bat` (el `.bat` y el `.ps1` tienen que estar juntos).
- `Windows/2_Compilar_EXE/`: doble clic en `Compilar_EXE.bat` para generar `MulticamDesdeSincro.exe`, que corre en cualquier PC con Windows sin instalar nada. La primera vez instala el módulo `ps2exe`. Algunos antivirus desconfían de los `.exe` hechos con ps2exe: si lo bloquea, agregalo como excepción o usá el `.bat`.

**Mac**
- Doble clic en `Mac/MulticamDesdeSincro.command` y arrastrá el `.prproj` a la Terminal.
- `Mac/Compilar_App.command` genera `MulticamDesdeSincro.app` (soltás el `.prproj` encima).

Detalle en `LEEME.txt`.
