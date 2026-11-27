#!/bin/bash
# Multicam desde Sincro (Mac). Doble clic, y arrastra el .prproj a la ventana de Terminal.
DIR="$(cd "$(dirname "$0")" && pwd)"
PWSH="$(command -v pwsh)"
for p in /usr/local/bin/pwsh /opt/homebrew/bin/pwsh /usr/local/microsoft/powershell/7/pwsh; do
  if [ -z "$PWSH" ] && [ -x "$p" ]; then PWSH="$p"; fi
done
clear
echo
echo " MULTICAM DESDE SINCRO"
echo " Cerra el proyecto en Premiere antes de seguir."
echo " Se genera una COPIA del .prproj con las multicam; el original no se toca."
echo
if [ -z "$PWSH" ]; then
  echo " Falta PowerShell para Mac (se instala una sola vez)."
  echo " Bajalo de: https://aka.ms/powershell-release?tag=stable  (el .pkg de macOS: arm64 para Apple Silicon, x64 para Intel)"
  echo " o con Homebrew:  brew install --cask powershell"
  echo; read -r -p " Enter para cerrar" _; exit 1
fi
"$PWSH" -NoProfile -File "$DIR/MulticamDesdeSincro.ps1" "$@"
echo; read -r -p " Enter para cerrar" _
