################################################
# Allgemiene Module für die Gestaltung der
# Powershell Oberfläche
################################################

function new-Header {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [string]$Char = "#",

        [int]$Width = 48,

        [ValidateSet("Black","DarkBlue","DarkGreen","DarkCyan","DarkRed","DarkMagenta","DarkYellow",
                     "Gray","DarkGray","Blue","Green","Cyan","Red","Magenta","Yellow","White")]
        [string]$Color = "White"
    )

    # obere Linie
    Write-Host ($Char * $Width) -ForegroundColor $Color

    # Text-Zeile mittig ausrichten
    $padding = [Math]::Max(0, ($Width - $Text.Length) / 2)
    $line = (" " * [Math]::Floor($padding)) + $Text
    Write-Host $line -ForegroundColor $Color

    # untere Linie
    Write-Host ($Char * $Width) -ForegroundColor $Color
}

function Show-Readme {
    <#
    .SYNOPSIS
        Zeigt eine README-Datei in der PowerShell-Konsole an, wenn sie nicht älter als 5 Tage ist.
    .DESCRIPTION
        Liest und zeigt den Inhalt von $RootDir\docs\readme.txt an.
        Wenn die Datei älter als 5 Tage (Erstellungsdatum) ist, wird sie nicht angezeigt.
    .PARAMETER RootDir
        Das Wurzelverzeichnis, in dem der Ordner "docs" liegt.
    .EXAMPLE
        Show-Readme -RootDir $RootDir
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RootDir
    )

    $ReadmePath = Join-Path $RootDir "docs\readme.txt"

    if (-not (Test-Path $ReadmePath)) {
        Write-Host "❌ Datei nicht gefunden: $ReadmePath" -ForegroundColor Red
        return
    }

    # Dateiinformationen abrufen
    $FileInfo = Get-Item $ReadmePath
    $CreationDate = $FileInfo.CreationTime
    $Age = (Get-Date) - $CreationDate

    # Prüfen, ob Datei älter als 5 Tage ist
    if ($Age.TotalDays -gt 5) {
        Write-Host "ℹ️ Keine Änderungen." -ForegroundColor Yellow
        return
    }

    # Datei anzeigen
    Write-Host "📄 Änderungen gefunden" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray

    try {
        Get-Content -Path $ReadmePath -Encoding UTF8 | ForEach-Object {
            Write-Host $_
        }
    }
    catch {
        Write-Host "❌ Fehler beim Lesen der Datei: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ("-" * 60) -ForegroundColor DarkGray
}

Export-ModuleMember -Function new-Header, Show-Readme