function Test-NetworkConnection {
    param(
        [int]$IntervalSeconds = 1,
        [int]$TimeoutSeconds  = 0,
        [switch]$Quiet
    )

    $Server = $Global:Config.ConnectionTest.PingAddress
    if (-not $Server) { $Server = $Global:Config.Network.Server }

    if ($Global:Config.ConnectionTest.RetryInterval) {
        $IntervalSeconds = [int]$Global:Config.ConnectionTest.RetryInterval
    }

    if ($Global:Config.ConnectionTest.TimeoutSeconds) {
        $TimeoutSeconds = [int]$Global:Config.ConnectionTest.TimeoutSeconds
    }

    # --- Verbindung prüfen ---
    $start = Get-Date
    $warningShown = $false

    while ($true) {
        try {
            $ping1 = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop
            Start-Sleep -Seconds 1
            $ping2 = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop

            if ($ping1 -and $ping2) { return }   # stiller Erfolg
        }
        catch { }

        if (-not $Quiet -and -not $warningShown) {
            Write-Host "⚠️  Keine Netzverbindung" -ForegroundColor Yellow
            $warningShown = $true
        }

        if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $TimeoutSeconds) {
            if (-not $Quiet) { Write-Host "⏱️ Timeout nach $TimeoutSeconds s – keine Verbindung zu $Server." -ForegroundColor Red }
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Connect-NetworkShare {
    [CmdletBinding()]
    param($Config)

    # --- Config laden ---
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

    if (-not $Config.Network) { throw "In der Config fehlt der Abschnitt 'Network'." }
    $net = $Config.Network

    if ([string]::IsNullOrWhiteSpace($net.Server) -or [string]::IsNullOrWhiteSpace($net.Share)) {
        throw "Ungültige Server/Share-Angaben in der Config."
    }

    $serverRoot = "\\$($net.Server)"
    $unc = "$serverRoot\$($net.Share)"
    if ($net.PSObject.Properties.Name -contains 'SubPath' -and -not [string]::IsNullOrWhiteSpace($net.SubPath)) {
        $unc = $unc.TrimEnd('\') + '\' + $net.SubPath.TrimStart('\')
    }
    Write-Host "" 
    Write-Host "🔄 Netzlaufwerk wird verbunden ..." -ForegroundColor Cyan

    # --- Alle bestehenden Netzlaufwerke löschen (leise, ignoriert Fehler) ---
    cmd.exe /c "net use * /delete /y" | Out-Null

    # --- Verbindung aufbauen ---
    $cmdArgs = @('use', $unc, $net.Password, "/user:$($net.Username)", '/persistent:no')
    $output = & cmd.exe /c net @cmdArgs 2>&1

    # --- Prüfen, ob verbunden ---
    if (Test-Path -LiteralPath $unc) {
        Write-Host "✅ Netzlaufwerk verbunden" -ForegroundColor Green
        return $true | Out-Null
    } else {
        Write-Host "❌ Verbindung fehlgeschlagen:`n$output" -ForegroundColor Red
        throw "Verbindung zu $unc fehlgeschlagen."
    }
}

Export-ModuleMember -Function Test-NetworkConnection, Connect-NetworkShare