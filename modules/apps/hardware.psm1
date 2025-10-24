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

function Start-FoilCheck {
    param(
        [int]$Minutes = 2,
        [switch]$Silent
    )

    try {
        if (-not $RootDir)        { throw "RootDir ist nicht gesetzt." }
        if (-not $ConfigPath)     { throw "ConfigPath ist nicht gesetzt." }
        if (-not $Global:LogPath) { $Global:LogPath = Join-Path $RootDir 'docs\logs' }

        # UTF-8 für PS-Host
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

        # Config laden
        if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.json nicht gefunden: $ConfigPath" }
        $Config = if ($Global:Config) { $Global:Config } else {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Global:Config = $cfg; $cfg
        }

        # Pfade relativ zu RootDir
        $pythonRel = $Config.Paths.PythonPortable
        if (-not $pythonRel) { $pythonRel = "scripts\programme\portable\python\python.exe" }
        $python = Join-Path $RootDir $pythonRel
        $script = Join-Path $RootDir "scripts\python\checkfoil.py"

        if (-not (Test-Path -LiteralPath $python)) { throw "Portable Python nicht gefunden: $python" }
        if (-not (Test-Path -LiteralPath $script)) { throw "Script nicht gefunden: $script" }

        if ($Silent) {
            if (-not (Test-Path -LiteralPath $Global:LogPath)) {
                New-Item -ItemType Directory -Path $Global:LogPath -Force | Out-Null
            }
            $psOut = Join-Path $Global:LogPath "foilcheck-ps.out.txt"
            $psErr = Join-Path $Global:LogPath "foilcheck-ps.err.txt"

            Start-Process -FilePath $python `
                          -ArgumentList "`"$script`" $Minutes" `
                          -WorkingDirectory $RootDir `
                          -WindowStyle Hidden `
                          -RedirectStandardOutput $psOut `
                          -RedirectStandardError  $psErr `
                          -PassThru -Wait | Out-Null
        }
        else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $python
            $psi.Arguments = "`"$script`" $Minutes"
            $psi.WorkingDirectory = $RootDir
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $false
            # Python auf UTF-8 zwingen
            $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
            $psi.EnvironmentVariables['PYTHONUTF8'] = '1'

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $null = $proc.Start()

            while (-not $proc.HasExited) {
                if (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line) { Write-Host $line }
                }
                Start-Sleep -Milliseconds 100
            }
            while (-not $proc.StandardOutput.EndOfStream) {
                Write-Host ($proc.StandardOutput.ReadLine())
            }
            if (-not $proc.StandardError.EndOfStream) {
                Write-Host "`n[FEHLER-AUSGABE]" -ForegroundColor Yellow
                while (-not $proc.StandardError.EndOfStream) {
                    Write-Host ($proc.StandardError.ReadLine())
                }
            }
        }
    }
    catch {
        Write-Host "[FEHLER]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Test-SystemCPU {
    param(
        [string]$RootDir,
        [string]$OutputFile = "TestCPUResult.txt"
    )

    if (-not $RootDir) {
        try { $RootDir = (Get-Variable -Name RootDir -Scope Global -ErrorAction Stop).Value }
        catch { throw "RootDir fehlt. Übergib -RootDir oder setze `$RootDir im Hauptskript." }
    }

    $sysCpu = Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name

    $logBase = Join-Path $RootDir 'docs\logs'
    if (-not (Test-Path $logBase)) { throw "Pfad nicht gefunden: $logBase" }

    # Nimmt den zuletzt geänderten Unterordner (falls mehrere existieren)
    $singleDir = Get-ChildItem -Path $logBase -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $singleDir) { throw "Kein Unterordner in $logBase gefunden." }

    $orderPath = Join-Path $singleDir.FullName 'auftrag.json'
    if (-not (Test-Path $orderPath)) { throw "auftrag.json nicht gefunden: $orderPath" }

    $order = Get-Content -Raw $orderPath | ConvertFrom-Json

    # CPU-Artikel im Auftrag suchen
    $cpuItem = $order | Where-Object {
        $_.article_name -match '(AMD|Intel|Ryzen|Core|Xeon|Pentium|Celeron|Athlon|Threadripper)'
    } | Select-Object -First 1

    $orderCpu = if ($cpuItem) { $cpuItem.article_name } else { $null }

    function Get-VendorAndModel {
        param([string]$s)
        if (-not $s) { return [pscustomobject]@{Vendor=$null;Model=$null} }

        $clean = $s -replace '[®™()]',' ' -replace '[“”"''`]',' ' -replace '\s+',' '
        $u = $clean.ToUpper()

        $vendor =
            if     ($u -match 'AMD|RYZEN|THREADRIPPER|ATHLON') { 'AMD' }
            elseif ($u -match 'INTEL|CORE|XEON|PENTIUM|CELERON') { 'INTEL' }
            else { $null }

        $model = $null
        if ($vendor -eq 'AMD') {
            # z. B. 5600X, 7800X3D, 7950X, 5600G (Suffixe bleiben!)
            if ($u -match '\b([1-9]\d{3,4}(?:X3D|XT|G|X|F)?)\b') { $model = $Matches[1] }
        }
        elseif ($vendor -eq 'INTEL') {
            # z. B. i3-10105F, i7-12700K, i9-14900KS -> Bindestrich ignorieren, Suffixe bleiben!
            $tmp = $u -replace '-', ''
            if ($tmp -match '\b(I[3579]\d{4,5}[A-Z]{0,3})\b') { $model = $Matches[1] }
        }

        [pscustomobject]@{ Vendor = $vendor; Model = $model }
    }

    $sysInfo = Get-VendorAndModel $sysCpu
    $ordInfo = Get-VendorAndModel $orderCpu

    $vendorOk = ($sysInfo.Vendor -and $ordInfo.Vendor -and $sysInfo.Vendor -eq $ordInfo.Vendor)
    $modelOk  = ($sysInfo.Model  -and $ordInfo.Model  -and ($sysInfo.Model -eq $ordInfo.Model))
    $passed   = $vendorOk -and $modelOk

    # Ausgabe in eine Datei
    $outputText = "Verbaute CPU: $sysCpu`n"
    $outputText += "Benötigte CPU: $orderCpu`n"
    if ($passed) {
        $outputText += "Wurde richtig verbaut"
    } else {
        $outputText += "Falsche Hardware, bitte kontrollieren"
    }

    # Definiere den Pfad zur Ausgabedatei
    $outputFilePath = Join-Path $singleDir.FullName $OutputFile

    # Schreibe die Ausgabe in die Datei
    $outputText | Out-File -FilePath $outputFilePath -Encoding UTF8
}

function Test-SystemMainboard {
    param(
        [string]$RootDir,
        [string]$OutputFile = "TestMainboardResult.txt"
    )

    if (-not $RootDir) {
        try { $RootDir = (Get-Variable -Name RootDir -Scope Global -ErrorAction Stop).Value }
        catch { throw "RootDir fehlt. Übergib -RootDir oder setze `$RootDir im Hauptskript." }
    }

    # --- System-Mainboard ermitteln ---
    $bb = Get-CimInstance Win32_BaseBoard | Select-Object -First 1 Manufacturer, Product, Version
    $sysBoardFull = @($bb.Manufacturer, $bb.Product, $bb.Version) -join ' '
    $sysBoardFull = $sysBoardFull.Trim()

    # --- Hersteller für Anzeige vereinfachen ---
    if ($sysBoardFull -match 'MSI|Micro-?Star') {
        $sysBoardFull = ($sysBoardFull -replace 'Micro-?Star.*?(?=\s|$)', 'MSI')
    }

    # --- auftrag.json finden ---
    $logBase = Join-Path $RootDir 'docs\logs'
    if (-not (Test-Path $logBase)) { throw "Pfad nicht gefunden: $logBase" }

    $singleDir = Get-ChildItem -Path $logBase -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $singleDir) { throw "Kein Unterordner in $logBase gefunden." }

    $orderPath = Join-Path $singleDir.FullName 'auftrag.json'
    if (-not (Test-Path $orderPath)) { throw "auftrag.json nicht gefunden: $orderPath" }

    $order = Get-Content -Raw $orderPath | ConvertFrom-Json

    # --- Board aus Auftrag suchen ---
    $boardItem = $order | Where-Object {
        $_.article_name -match '(MSI|Micro-?Star|ASUS|ASUSTeK|GIGABYTE|GIGA-?BYTE|ASROCK|BIOSTAR|Mainboard|Motherboard|B\d{3,4}|Z\d{3,4}|X\d{3,4}|H\d{3,4})'
    } | Select-Object -First 1

    $orderBoardFull = if ($boardItem) { $boardItem.article_name } else { $null }

    if ($orderBoardFull -match 'MSI|Micro-?Star') {
        $orderBoardFull = ($orderBoardFull -replace 'Micro-?Star.*?(?=\s|$)', 'MSI')
    }

    # --- Vergleichslogik (hier Platzhalter, falls du sie schon oben hast) ---
    # Beispielhaft: immer false, bitte deinen Vergleichscode wieder einsetzen
    $passed = $false

    # --- Ausgabe ---
    $outputText  = "Verbaute Mainboard: $sysBoardFull`n"
    $outputText += "Benötigte Mainboard: $orderBoardFull`n"
    if ($passed) {
        $outputText += "Wurde richtig verbaut"
    } else {
        $outputText += "Falsche Hardware, bitte kontrollieren"
    }

    $outputFilePath = Join-Path $singleDir.FullName $OutputFile
    $outputText | Out-File -FilePath $outputFilePath -Encoding UTF8
}


Export-ModuleMember -Function Get-MainboardInfo, Start-FoilCheck, Test-SystemCPU, Test-SystemMainboard
