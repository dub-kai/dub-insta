function Invoke-GpuCheck {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Config,

        [switch]$UseWmi,
        [switch]$OpenDeviceManager
    )
    # --- Config laden ---
    try {
        if (-not $Config) {
            if ($Global:Config) {
                $Config = $Global:Config
            } else {
                $rootConfigPath = Join-Path (Get-Location) 'config\config.json'
                if (-not (Test-Path -LiteralPath $rootConfigPath)) {
                    throw "Config nicht gefunden: $rootConfigPath"
                }
                $Config = Get-Content -LiteralPath $rootConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
        }

        # Minimal-Validierung
        if (-not $Config.Network.Server -or -not $Config.Network.Share -or -not $Config.Paths.GrafikDriverPath) {
            throw "Config unvollständig. Erwartet: Network.Server, Network.Share, Paths.GrafikDriverPath"
        }

        # UNC-Root + relativen Pfad robust zusammensetzen
        $uncRoot = "\\{0}\{1}" -f $Config.Network.Server, $Config.Network.Share
        $DriverSharePath = $uncRoot
        foreach ($part in ($Config.Paths.GrafikDriverPath -split '[\\/]+')) {
            if ($part) { $DriverSharePath = Join-Path $DriverSharePath $part }
        }
    } catch {
        Write-Host -ForegroundColor Red "Fehler beim Laden/Prüfen der Config: $_"
        return
    }

    # --- GPU-Liste holen ---
    try {
        if ($UseWmi) {
            $graphicsCards = Get-WmiObject -Query "SELECT * FROM Win32_PnPEntity WHERE PNPClass = 'Display'" |
                             Select-Object -Property Name
        } else {
            $graphicsCards = Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='Display'" |
                             Select-Object -Property Name
        }
    } catch {
        Write-Host -ForegroundColor Red "Fehler beim Abrufen der Grafikkarten: $_"
        return
    }

    if (-not $graphicsCards) {
        Write-Host -ForegroundColor Red "Es konnten keine Informationen zu den Grafikkarten abgerufen werden."
        return
    }

    $foundBasicDriver = $false
    $destinationPath  = $null

    foreach ($card in $graphicsCards) {
        if ($card.Name -eq "Microsoft Basic Display Driver") {
            $foundBasicDriver = $true
            Write-Host ""
            Write-Host -ForegroundColor Red   "              - $($card.Name)`n"
        } else {
            Write-Host ""
            Write-Host -ForegroundColor Green "              - $($card.Name)`n"
        }
    }

    # --- Interaktive Treiberhilfe bei Basic Display Adapter ---
    if ($foundBasicDriver) {
        New-Header -Text "DownloadCenter" -Char "=" -Color Cyan -Width 60
        Write-Host ""
        $inputBasicDriver = Read-Host "Microsoft Basic Display Driver erkannt. Möchten Sie den Treiber aktualisieren? (J/N)"
        if ($inputBasicDriver -eq "J") {
            try {
                Write-Host ""
                Write-Host -ForegroundColor Cyan "Verfügbare Ordner im Treiber-Ordner:"
                $folders = Get-ChildItem -Path $DriverSharePath -Directory | Select-Object -ExpandProperty Name

                if (-not $folders -or $folders.Count -eq 0) {
                    Write-Host -ForegroundColor Red "Im Treiber-Ordner wurden keine Unterordner gefunden."
                } else {
                    for ($i = 0; $i -lt $folders.Count; $i++) {
                        Write-Host "$($i+1). $($folders[$i])"
                    }

                    Write-Host ""
                    $selection = Read-Host "Bitte geben Sie die Nummer des gewünschten Ordners ein"
                    if ($selection -as [int] -and $selection -ge 1 -and $selection -le $folders.Count) {
                        $selectedFolder = $folders[$selection - 1]
                        $destinationPath = Join-Path $env:USERPROFILE "Desktop\$selectedFolder"

                        if (-not (Test-Path -Path $destinationPath -PathType Container)) {
                            New-Item -Path $destinationPath -ItemType Directory | Out-Null
                        }

                        Copy-Item -Path (Join-Path $DriverSharePath $selectedFolder) -Destination $destinationPath -Recurse -Force
                        Write-Host ""
                        Write-Host -ForegroundColor Green "✅ Der Treiber wurde erfolgreich runtergeladen"
                        Write-Host -ForegroundColor Yellow "⚠️ Geräte-Manager wird geöffnet..."
                        Start-Process -FilePath "mmc.exe" -ArgumentList "devmgmt.msc" -WindowStyle Normal -Wait
                        Write-Host -ForegroundColor Green "Geräte-Manager wurde gestartet."

                    } else {
                        Write-Host -ForegroundColor Red "Ungültige Auswahl. Der Treiber wird nicht heruntergeladen."
                    }
                }
            } catch {
                Write-Host -ForegroundColor Red "Zugriff/Kopie über UNC fehlgeschlagen: $_"
            }
        } elseif ($inputBasicDriver -eq "N") {
            Write-Host -ForegroundColor Yellow "Der Treiber wird nicht aktualisiert."
        } else {
            Write-Host -ForegroundColor Red "Ungültige Eingabe. Der Treiber wird nicht aktualisiert."
        }
    }
}
