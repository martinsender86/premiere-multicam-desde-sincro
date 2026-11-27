#!/bin/bash
# Arma MulticamDesdeSincro.app: una app donde soltas el .prproj encima (o doble clic y lo arrastras a la Terminal).
# Usa osacompile, que viene con macOS. La app necesita PowerShell para Mac instalado (una sola vez).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/MulticamDesdeSincro.app"
TMP="$(mktemp -d)"
cat > "$TMP/app.applescript" <<'APPLESCRIPT'
on run
	my lanzar({})
end run
on open theFiles
	my lanzar(theFiles)
end open
on lanzar(theFiles)
	set res to POSIX path of (path to me) & "Contents/Resources/"
	set cmd to "clear; " & quoted form of (res & "MulticamDesdeSincro.command")
	repeat with f in theFiles
		set cmd to cmd & " " & quoted form of (POSIX path of f)
	end repeat
	tell application "Terminal"
		activate
		do script cmd
	end tell
end lanzar
APPLESCRIPT
rm -rf "$APP"
osacompile -o "$APP" "$TMP/app.applescript"
cp "$DIR/MulticamDesdeSincro.ps1" "$DIR/MulticamDesdeSincro.command" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/MulticamDesdeSincro.command"
xattr -cr "$APP" 2>/dev/null || true
rm -rf "$TMP"
echo
echo " Listo: $APP"
echo " Soltale un .prproj encima, o doble clic y arrastralo a la Terminal."
echo; read -r -p " Enter para cerrar" _
