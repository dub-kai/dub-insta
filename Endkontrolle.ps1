# Pfade definieren
$RootDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $RootDir 'config\config.json'
$Global:LogPath = Join-Path $RootDir 'docs\logs'

# Config global laden
$Global:Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Module laden
$ModuleDir = Join-Path $RootDir "Modules"
if (Test-Path $ModuleDir) {
    Get-ChildItem -Path $ModuleDir -Filter *.psm1 -Recurse | ForEach-Object {
        Import-Module $_.FullName -Force -ErrorAction SilentlyContinue
    }
}
New-Header -Text "Dubaro Endkontrolle" -Char "=" -Color Cyan -Width 60
##############################
# System vorbereiten
##############################
Test-NetworkConnection
Test-CsmAndReboot
Elevated
Set-NumLock
Connect-NetworkShare

# Show-Readme -RootDir $RootDir

##############################
# Interface
##############################

Get-CustomerDataFromApi
Set-OEMInformationFromJson

New-Header -Text "Verbaute Grafikkarte" -Char "=" -Color Cyan -Width 60

Invoke-GpuCheck

New-Header -Text "Hardwareinformationen Sammeln" -Char "=" -Color Cyan -Width 60

Get-MainboardInfo
Save-OrderArticles