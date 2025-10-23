function Get-CustomerDataFromApi {
    param (
        [string]$SavePath = (Join-Path $Global:LogPath "kundendaten.json"),
        [switch]$ForceReentry
    )

    # --- Konfiguration ---
    $api    = $Global:Config.api
    $regex  = $Global:Config.validation
    $logDir = $Global:LogPath
    $ErrorActionPreference = 'Stop'

    # --- Zielbasis anlegen ---
    $saveDir = Split-Path -Path $SavePath -Parent
    if (-not (Test-Path $saveDir)) {
        New-Item -Path $saveDir -ItemType Directory -Force | Out-Null
    }

    New-Header -Text "Kundendaten erfassen" -Char "=" -Color Cyan -Width 60

    # --- Alte JSON-Datei prüfen (nur wenn nicht erzwungen) ---
    if ((Test-Path $SavePath) -and -not $ForceReentry) {
        try {
            $existing = Get-Content $SavePath -Raw | ConvertFrom-Json
            if ($existing) {
                Write-Host ""
                Write-Host "Vorhandene Kundendaten gefunden:" -ForegroundColor Cyan
                Write-Host ""
                Write-Host ("  Kundennummer:              " + $existing.CustomerNumberIn)
                if ($existing.PSObject.Properties.Name -contains 'OrderNumberOriginal') {
                    Write-Host ("  Bestellnummer:             " + $existing.OrderNumberOriginal)
                }
                Write-Host ("  Seriennummer:              " + $existing.SerialNumber)
                Write-Host ""
            }
        } catch {
            Write-Host "⚠️ Alte Datei ist ungültig oder kein JSON-Format – wird ggf. überschrieben." -ForegroundColor Yellow
        }

        $choice = Read-Host "Datei löschen und neue Daten eingeben? (J/N)"
        if ($choice.ToUpper() -ne 'J') {
            Write-Host "Bestehende Kundendaten werden beibehalten." -ForegroundColor Yellow
            return
        }

        # --- Beim Löschen: zugehörigen Bestellordner ebenfalls entfernen ---
        $existingOrderNumber = $null
        try {
            $existingJson = Get-Content $SavePath -Raw | ConvertFrom-Json
            if ($existingJson -and $existingJson.PSObject.Properties.Name -contains 'OrderNumber') {
                $existingOrderNumber = $existingJson.OrderNumber
            }
        } catch {
            # Ignorieren – wir löschen mindestens die Datei
        }

        # 1) Kompatibilitäts-Datei löschen
        if (Test-Path $SavePath) {
            Remove-Item $SavePath -Force -ErrorAction SilentlyContinue
        }

        # 2) Bestellordner löschen (falls ermittelbar)
        if ($existingOrderNumber) {
            $orderDirToDelete = Join-Path $saveDir $existingOrderNumber
            if (Test-Path $orderDirToDelete) {
                try {
                    Remove-Item $orderDirToDelete -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Host "⚠️ Konnte Ordner nicht entfernen: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }
    # --- Eingabe ---
    do {
        Write-Host ""
        $customerNumber = Read-Host "Kundennummer eingeben"
    } until ($customerNumber -match $regex.customerNumberRegex)

    do {
        $orderNumberRaw = Read-Host "Bestellnummer eingeben"
        $orderNumber    = ConvertTo-OrderNumber -RawInput $orderNumberRaw
    } until ($orderNumber -match $regex.orderNumberRegex)

    # --- Zielpfade für neuen Bestellordner vorbereiten ---
    $orderDir  = Join-Path $saveDir $orderNumber
    $orderJson = Join-Path $orderDir 'kundendaten.json'
    if (-not (Test-Path $orderDir)) {
        New-Item -ItemType Directory -Path $orderDir -Force | Out-Null
    }

    # --- API-Aufruf ---
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
        CustomerNumberIn     = $customerNumber
        CustomerNumberApi    = $customerFromApi
        OrderNumber          = $orderNumber
        OrderNumberOriginal  = $orderNumberRaw
        SerialNumber         = $serial
    }

    # --- JSON speichern: 1) alter Pfad (Kompatibilität), 2) neuer Bestellordner ---
    $customerData | ConvertTo-Json -Depth 3 | Out-File -FilePath $SavePath  -Encoding UTF8 -Force
    $customerData | ConvertTo-Json -Depth 3 | Out-File -FilePath $orderJson -Encoding UTF8 -Force

    Write-Host ""
    Write-Host "✅ Seriennummer $serial gespeichert" -ForegroundColor Green
}

function Set-OEMInformationFromJson {
    [CmdletBinding()]
    param(
        [string]$RootDir,  # optional; wenn nicht angegeben, wird $RootDir (global/script) oder der Skriptordner verwendet
        [string]$Manufacturer = "dubaro.de - many electronics GmbH",
        [string]$SupportHours = "Montag - Freitag: 9:00 - 16:00 Uhr",
        [string]$SupportPhone = "Tel: +49 (0) 4462 - 9582525",
        [string]$SupportURL   = "https://www.dubaro.de/"
    )

    # --- Admin erforderlich ---
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Administratorrechte erforderlich. Starte PowerShell 'Als Administrator'." }

    # --- RootDir ermitteln ---
    if (-not $RootDir) {
        if ($script:RootDir)      { $RootDir = $script:RootDir }
        elseif ($global:RootDir)  { $RootDir = $global:RootDir }
        elseif ($PSCommandPath)   { $RootDir = Split-Path -Parent $PSCommandPath }
        elseif ($MyInvocation.MyCommand.Path) { $RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
        else { $RootDir = (Get-Location).Path }
    }

    # --- Pfad zur JSON-Datei ---
    $jsonPath = Join-Path $RootDir 'docs\logs\kundendaten.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        throw "kundendaten.json nicht gefunden: $jsonPath"
    }

    # --- JSON laden ---
    try {
        $data = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "kundendaten.json konnte nicht gelesen/geparst werden: $($_.Exception.Message)"
    }

    # --- Seriennummer auslesen ---
    $serial = $data.SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial)) {
        throw "In kundendaten.json fehlt 'SerialNumber' oder ist leer."
    }
    $serial = $serial.Trim()

    # --- OEMInformation schreiben ---
    $rk = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"
    New-Item -Path $rk -Force | Out-Null

    New-ItemProperty -Path $rk -Name "Manufacturer" -PropertyType String -Value $Manufacturer -Force | Out-Null
    New-ItemProperty -Path $rk -Name "Model"        -PropertyType String -Value $serial      -Force | Out-Null
    New-ItemProperty -Path $rk -Name "SupportHours" -PropertyType String -Value $SupportHours -Force | Out-Null
    New-ItemProperty -Path $rk -Name "SupportPhone" -PropertyType String -Value $SupportPhone -Force | Out-Null
    New-ItemProperty -Path $rk -Name "SupportURL"   -PropertyType String -Value $SupportURL   -Force | Out-Null

    Write-Host ""
    Write-Host "✅ OEM-Informationen gesetzt." -ForegroundColor Green
    Write-Host ""
    return $true | Out-Null
}
function ConvertTo-OrderNumber {
    param([string]$RawInput)

    if (-not $RawInput) { return "" }

    $s = ($RawInput -replace '\s+', '')     # Leerzeichen entfernen
    $s = ($s -replace '(?i)NB$', '')        # NB am Ende entfernen
    $s = ($s -replace '[^\d]', '')          # nur Ziffern behalten
    return $s
}

function Save-OrderArticles {
    [CmdletBinding()]
    param(
        [string]$RootDir
    )

    try {
        # --- Root & Pfade
        if (-not $RootDir) {
            if ($global:RootDir) { $RootDir = $global:RootDir } else { $RootDir = (Get-Location).Path }
        }
        $logsDir = Join-Path $RootDir "docs\logs"
        $kundendatenPath = Join-Path $logsDir "kundendaten.json"
        if (-not (Test-Path $kundendatenPath)) { throw "kundendaten.json nicht gefunden: $kundendatenPath" }

        # --- Kundendaten.json lesen (Serial + Order)
        $kd = Get-Content -LiteralPath $kundendatenPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $serial = $kd.SerialNumber
        $order  = $kd.OrderNumber
        if ([string]::IsNullOrWhiteSpace($serial)) { throw "Seriennummer fehlt in kundendaten.json." }

        # --- Ziel festlegen (ohne neue Ordner zu erzeugen)
        $orderDir = if ($order) { Join-Path $logsDir $order } else { $null }
        $targetDir = if ($orderDir -and (Test-Path $orderDir)) { $orderDir } else { $logsDir }
        $targetFile = Join-Path $targetDir "auftrag.json"

        # --- API-Aufruf (Config.api baseUrl2/token2/user2/function2)
        if (-not $Global:Config) { throw "Config nicht geladen. Bitte vorher Import-AppConfig ausführen." }
        $api = $Global:Config.api
        $url = "{0}?token={1}&user={2}&function={3}&serial={4}" -f $api.baseUrl2, $api.token2, $api.user2, $api.function2, $serial

        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
        $raw  = $resp.Content
        $json = $raw | ConvertFrom-Json

        # --- Nur gewünschte Felder behalten (article_id != 0)
        $values = @()
        foreach ($v in $json.values) {
            if ($v.article_id -eq 0) { continue }
            $values += [pscustomobject]@{
                article_id     = $v.article_id
                article_amount = $v.article_amount
                article_name   = ($v.article_name).ToString().Trim()
            }
        }

        # --- Speichern als auftrag.json (nur die Liste)
        $values | ConvertTo-Json -Depth 4 | Out-File -FilePath $targetFile -Encoding UTF8 -Force
        Write-Host "✅ Auftragsdaten wurden erfasst" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Save-OrderArticles: $($_.Exception.Message)" -ForegroundColor Red
    }
}


Export-ModuleMember -Function Get-CustomerDataFromApi, Set-OEMInformationFromJson, ConvertTo-OrderNumber, Save-OrderArticles
