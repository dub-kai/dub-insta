function Get-MainboardInfo {
    [CmdletBinding()]
    param(
        [switch]$IncludeSystemIds,
        [switch]$PassThru
    )

    # --- Hersteller normalisieren ---
    function Convert-MbManufacturer {
        param([string]$Manufacturer)
        if ($Manufacturer -match "Micro[-\s]?Star") { return "MSI" }
        elseif ($Manufacturer -match "ASRock")      { return "ASRock" }
        elseif ($Manufacturer -match "Gigabyte")    { return "Gigabyte" }
        elseif ($Manufacturer -match "ASUS")        { return "Asus" }
        return $Manufacturer
    }

    # --- OS normalisieren (Arch, Name, Nummer) ---
    function Convert-OSInfo {
        param(
            [string]$Caption,
            [string]$Architecture
        )
        $osArchieName = if ($Architecture -match "64") { "64" } else { "32" }
        $osArchie     = if ($osArchieName -eq "64") { "64-bit" } else { "32-bit" }

        $lower = $Caption.ToLower()
        $osName = "unknown"
        if ($lower -match "home" -or $lower -match "famille") { $osName = "Home" }
        elseif ($lower -match "pro")                          { $osName = "Pro" }
        elseif ($lower -match "enterprise")                   { $osName = "Enterprise" }
        elseif ($lower -match "education")                    { $osName = "Education" }
        elseif ($lower -match "core")                         { $osName = "Core" }

        $osNb = $null
        if ($lower -match "windows\s*(\d{1,2})") { $osNb = $matches[1] }

        [pscustomobject]@{
            OSArchieName = $osArchieName
            osArchie     = $osArchie
            OSName       = $osName
            OSNb         = $osNb
        }
    }

    try {
        # Basis: $rootDir\docs\logs
        $basePath = if ($Global:rootDir) { $Global:rootDir } else { (Get-Location).Path }
        $logPath  = Join-Path $basePath "docs\logs"
        if (-not (Test-Path $logPath)) { New-Item -ItemType Directory -Path $logPath -Force | Out-Null }

        # --- Hardware auslesen ---
        $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        if (-not $bb) { throw "Win32_BaseBoard lieferte keine Daten." }

        $mainboard = [pscustomobject]@{
            Manufacturer = Convert-MbManufacturer $bb.Manufacturer
            Product      = $bb.Product
            BiosVersion  = $bb.Version
            SerialNumber = $bb.SerialNumber
            PartNumber   = $bb.PartNumber
            AssetTag     = $bb.Tag
        }

        if ($IncludeSystemIds) {
            $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($csp) {
                $mainboard | Add-Member NoteProperty UUID       $csp.UUID
                $mainboard | Add-Member NoteProperty SystemSKU  $csp.SKUNumber
                $mainboard | Add-Member NoteProperty Name       $csp.Name
                $mainboard | Add-Member NoteProperty Vendor     $csp.Vendor
            }
        }

        # --- Windows ---
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        $osNorm = Convert-OSInfo -Caption $os.Caption -Architecture $os.OSArchitecture

        $windows = [pscustomobject]@{
            OSsystemName  = $os.Caption
            Version       = $os.Version
            BuildNumber   = $os.BuildNumber
            OSArchieName  = $osNorm.OSArchieName
            osArchie      = $osNorm.osArchie
            OSName        = $osNorm.OSName
            OSNb          = $osNorm.OSNb
        }

        # --- Ergebnisobjekt für die Datei ---
        $result = [pscustomobject]@{
            Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Mainboard = $mainboard
            Windows   = $windows
        }

        # --- Bestellnummer & Seriennummer aus kundendaten.json laden ---
        $orderNumberFromJson  = $null
        $serialFromJson       = $null
        $compatJson           = Join-Path $logPath "kundendaten.json"

        if (Test-Path $compatJson) {
            try {
                $kd = Get-Content -LiteralPath $compatJson -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($kd) {
                    if ($kd.PSObject.Properties.Name -contains 'OrderNumber' -and $kd.OrderNumber) {
                        $orderNumberFromJson = "$($kd.OrderNumber)"
                    }
                    if ($kd.PSObject.Properties.Name -contains 'SerialNumber' -and $kd.SerialNumber) {
                        $serialFromJson = "$($kd.SerialNumber)"
                    }
                }
            } catch { }
        }

        # Fallback Bestellnummer: eindeutigen Unterordner mit kundendaten.json suchen
        if (-not $orderNumberFromJson) {
            $candidateDirs = Get-ChildItem -LiteralPath $logPath -Directory -ErrorAction SilentlyContinue
            $withKd = @()
            foreach ($dir in $candidateDirs) {
                $p = Join-Path $dir.FullName 'kundendaten.json'
                if (Test-Path $p) { $withKd += $dir }
            }
            if ($withKd.Count -eq 1) {
                $orderNumberFromJson = $withKd[0].Name
                # falls keine Serial aus Root/kundendaten.json, versuche aus dem Unterordner
                if (-not $serialFromJson) {
                    try {
                        $kd2 = Get-Content -LiteralPath (Join-Path $withKd[0].FullName 'kundendaten.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($kd2 -and $kd2.PSObject.Properties.Name -contains 'SerialNumber' -and $kd2.SerialNumber) {
                            $serialFromJson = "$($kd2.SerialNumber)"
                        }
                    } catch { }
                }
            }
        }

        # --- Zielordner bestimmen ---
        $targetDir = if ($orderNumberFromJson) { Join-Path $logPath $orderNumberFromJson } else { $logPath }
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

        # --- Dateiname: hardware_info_<SerialNumber>.json (Seriennummer bevorzugt aus kundendaten.json) ---
        $serialForFile = if (-not [string]::IsNullOrWhiteSpace($serialFromJson)) { $serialFromJson } else { $mainboard.SerialNumber }
        if ([string]::IsNullOrWhiteSpace($serialForFile)) { $serialForFile = "unknown_serial" }
        $serialForFile = ($serialForFile -replace '[\\/:*?"<>|]', '_').Trim()

        $fileName = "hardware_info_{0}.json" -f $serialForFile
        $jsonPath = Join-Path $targetDir $fileName

        # --- Schreiben ---
        $result | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

        Write-Host ""
        Write-Host "✅ Systemdaten erfasst."
        if ($PassThru) { return $result }
    }
    catch {
        Write-Host -ForegroundColor Red "Fehler beim Auslesen der Systeminformationen: $_"
    }
}

Export-ModuleMember -Function Get-MainboardInfo
