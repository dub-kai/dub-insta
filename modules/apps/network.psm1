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

Export-ModuleMember -Function Test-NetworkConnection