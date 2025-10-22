function Set-NumLock {

    # Aktuellen Status abfragen
    $numLockState = [console]::NumberLock

    if (-not $numLockState) {
        
        # NumLock aktivieren
        $wsh = New-Object -ComObject WScript.Shell
        $wsh.SendKeys('{NUMLOCK}')
        
        Start-Sleep -Milliseconds 200

        if ([console]::NumberLock) {
            Write-Host "✅ NumLock aktiviert." -ForegroundColor Green
        }
        else {
            Write-Host "⚠️ Konnte NumLock nicht aktivieren." -ForegroundColor Red
        }
    }
    else {
        Write-Host "✅ NumLock ist bereits eingeschaltet." -ForegroundColor Green
    }
}

function Elevated {
    param(
        [bool]$ExitIfDenied = $true
    )
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if ($isAdmin) { 
        Write-Host "✅ Administratorrechte erkannt." -ForegroundColor Green
        return
    }

    # Pfad zur aktuellen Script-Datei (falls vorhanden)
    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($scriptPath)) {
        Write-Host "Warnung: Kein Script-Pfad gefunden. Ensure-Elevated kann nur aus einem Script heraus korrekt neu starten." -ForegroundColor Yellow
        return $false
    }

    $exe = if ($PSVersionTable.PSEdition -and $PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $quotedArgs = @()
    foreach ($a in $args) {
        $quotedArgs += ('"{0}"' -f ($a -replace '"','\"'))
    }
    $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
    if ($quotedArgs.Count -gt 0) {
        $argumentList += $quotedArgs
    }
    $workingDir = Get-Location

    try {
        Start-Process -FilePath $exe -ArgumentList $argumentList -WorkingDirectory $workingDir -Verb RunAs -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 200
        Exit
    }
    catch {
        if ($ExitIfDenied) { Exit 1 } else { return $false }
    }
}

function Test-CsmAndReboot {
    [CmdletBinding()]
    param()

    try {
        $secureBootStatus = Confirm-SecureBootUEFI
    }
    catch {
        Write-Warning "Konnte Secure-Boot-Status nicht abfragen. Möglicherweise ist kein UEFI vorhanden oder die Abfrage schlug fehl."
        return
    }

    if ($secureBootStatus) {
        Write-Host "✅ Secure Boot ist aktiv." -ForegroundColor Green
    }
    else {
        new-Header -Text "⚠️ Secure Boot Nicht AKTIV! Bitte Einschalten" -Char "=" -Color Red -Width 60
        Pause
        
    }
}

function Disable-PowerSaving {
    try {
        # Monitor Timeout (AC)
        powercfg /change monitor-timeout-ac 0 | Out-Null

        # Standby Timeout (AC)
        powercfg /change standby-timeout-ac 0 | Out-Null

        Write-Host "✅ Monitor bleibt an" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Konnte Energiesparfunktionen nicht ändern: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Export-ModuleMember -Function Set-NumLock, Elevated, Test-CsmAndReboot, Test-NetworkConnection, Disable-PowerSaving
