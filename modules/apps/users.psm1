function Get-CustomerDataFromApi {
    param (
        [string]$SavePath = (Join-Path $Global:LogPath "kundendaten.json"),
        [switch]$ForceReentry
    )

    # --- Konfiguration ---
    $api   = $Global:Config.api
    $regex = $Global:Config.validation
    $logDir = $Global:LogPath
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path (Split-Path $SavePath))) {
        New-Item -Path (Split-Path $SavePath) -ItemType Directory -Force | Out-Null
    }

    New-Header -Text "Kundendaten erfassen" -Char "=" -Color Cyan -Width 60

    # --- Alte JSON-Datei prüfen ---
    if ((Test-Path $SavePath) -and -not $ForceReentry) {
        try {
            $existing = Get-Content $SavePath -Raw | ConvertFrom-Json
            if ($existing) {
                Write-Host "Vorhandene Kundendaten gefunden:" -ForegroundColor Cyan
                Write-Host ("  Kundennummer: " + $existing.CustomerNumberIn)
                Write-Host ("  Bestellnummer: " + $existing.OrderNumber)
                Write-Host ("  Seriennummer: " + $existing.SerialNumber)
                Write-Host ""
            }
        } catch {
            Write-Host "⚠️ Alte Datei ist ungültig oder kein JSON-Format – wird überschrieben." -ForegroundColor Yellow
        }

        $choice = Read-Host "Datei löschen und neue Daten eingeben? (J/N)"
        if ($choice.ToUpper() -ne 'J') {
            Write-Host "Bestehende Kundendaten werden beibehalten." -ForegroundColor Yellow
            return
        }

        Remove-Item $SavePath -Force
        Write-Host "Datei gelöscht.`n"
    }

    # --- Eingabe ---
    do {
        $customerNumber = Read-Host "Kundennummer eingeben"
    } until ($customerNumber -match $regex.customerNumberRegex)

    do {
        $orderNumber = Read-Host "Bestellnummer eingeben"
    } until ($orderNumber -match $regex.orderNumberRegex)

    # --- URL bauen ---
    $targetUrl = "$($api.baseUrl)?token=$($api.token)&user=$($api.user)&function=$($api.function)&order=$orderNumber"

    try {
        $response = Invoke-WebRequest -Uri $targetUrl -UseBasicParsing
        $json = $response.Content | ConvertFrom-Json
    } catch {
        Write-Host "❌ Fehler beim Abrufen der Daten: $($_.Exception.Message)" -ForegroundColor Red
        Add-Content -Path (Join-Path $logDir "kundendaten.log") -Value "[ERROR] $($_.Exception.Message)"
        return
    }

    if ($json.code -ne 200 -or !$json.values) {
        Write-Host "❌ Keine gültigen Daten gefunden (Code: $($json.code))." -ForegroundColor Red
        return
    }

    $systems = $json.values
    $customerFromApi = $systems[0].customer

    if ($null -eq $customerFromApi) {
        Write-Host "⚠️ Kundennummer in API ist leer oder null – wird akzeptiert." -ForegroundColor Yellow
    } elseif ("$customerFromApi" -ne "$customerNumber") {
        Write-Host "❌ Kundennummer stimmt nicht überein!" -ForegroundColor Red
        Write-Host "Eingegeben: $customerNumber / API: $customerFromApi"
        return
    }

    # --- System auswählen ---
    if ($systems.Count -gt 1) {
        Write-Host "Mehrere Systeme gefunden:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $systems.Count; $i++) {
            $serial = if ($systems[$i].pc_serial) { $systems[$i].pc_serial } else { "unbekannt" }
            Write-Host "$($i + 1): Seriennummer: $serial"
        }
        do {
            $selection = Read-Host "Welche Seriennummer soll verwendet werden? (1-$($systems.Count))"
        } until ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $systems.Count)
        $chosen = $systems[[int]$selection - 1]
    } else {
        $chosen = $systems[0]
    }

    # --- JSON-Datenobjekt erstellen ---
    $serial = $chosen.pc_serial.ToString()
    $customerData = [PSCustomObject]@{
        CustomerNumberIn  = $customerNumber
        CustomerNumberApi = $customerFromApi
        OrderNumber       = $orderNumber
        SerialNumber      = $serial
    }
    $customerData | ConvertTo-Json -Depth 3 | Out-File -FilePath $SavePath -Encoding UTF8 -Force
}

Export-ModuleMember -Function Get-CustomerDataFromApi
