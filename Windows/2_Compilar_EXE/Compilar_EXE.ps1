# Compila MulticamDesdeSincro.ps1 en MulticamDesdeSincro.exe con ps2exe.
# El .exe resultante no necesita nada instalado: usa el PowerShell que ya trae Windows.
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando ps2exe (solo la primera vez, necesita internet)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$out = Join-Path $PSScriptRoot 'MulticamDesdeSincro.exe'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
Invoke-ps2exe -inputFile (Join-Path $PSScriptRoot 'MulticamDesdeSincro.ps1') -outputFile $out `
    -title 'Multicam desde Sincro' -product 'Multicam desde Sincro' -description 'Arma Multicam Source Sequences desde una secuencia de sincro de Premiere' `
    -company 'Martin Senderowicz' -version '1.3.0.0'

if (Test-Path -LiteralPath $out) { Write-Host ''; Write-Host "Listo: $out" -ForegroundColor Green }
else { throw 'No se genero el .exe' }
