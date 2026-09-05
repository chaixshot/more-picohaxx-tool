#Requires -Version 5.1

<#
.SYNOPSIS
    Utility functions for the PicoUnlock project.
.DESCRIPTION
    Provides common functions for logging, UI headers, device mode detection,
    and rebooting operations. Used across all PicoUnlock modules.
#>

# --- Utility Functions ---

$e = [char]27
$cReset = "$e[0m"
$cCyan = "$e[36m"
$cYellow = "$e[33m"
$cGreen = "$e[32m"
$cMagenta = "$e[35m"
$cRed = "$e[31m"
$cBold = "$e[1m"
$cGray = "$e[90m"
$cDarkGray = "$e[90m"
$cWhite = "$e[97m"

function Write-Log([string]$message, [string]$type = "Info") {
    $Color = switch ($type) {
        "Success" {
            [System.Media.SystemSounds]::Asterisk.Play()
            $cGreen
        }
        "Warning" {
            [System.Media.SystemSounds]::Exclamation.Play()
            $cYellow
        }
        "Error" {
            [System.Media.SystemSounds]::Hand.Play()
            $cRed
        }
        "Action" {
            $cMagenta
        }
        Default {
            $cGray
        }
    }
    Write-Host "${Color}[$type] ${cReset}$message"
}

function Read-HostLog([string]$prompt) {
    [Console]::Write("`n${prompt}: ${cGreen}")

    $inputResult = [Console]::ReadLine()

    [Console]::Write($cReset)

    # Force transcript stream capture without displaying text to the screen
    & {
        $InformationPreference = 'Continue'
        Write-Information "`n> ${prompt}: ${inputResult}"
    } 6>$null

    return $inputResult
}

function Clean-LogFormat {
    param([string]$LogFile)

    if (Test-Path $LogFile) {
        $content = Get-Content $LogFile -Raw

        # Remove ANSI escape sequences (colors, styles, etc.)
        # This covers $cReset, $cCyan, $cYellow, $cGreen, $cMagenta, $cRed, $cBold, $cGray, $cWhite
        $esc = [char]27
        $pattern = "$( [char]27 )\[[0-9;]*[a-zA-Z]"

        $cleanContent = $content -replace $pattern, ""
        $cleanContent | Set-Content $LogFile -Force
    }
}

function Write-Header([string]$title) {
    Write-Host ""
    Write-Host ""
    Write-Host "================================================================="
    Write-Host "================================================================="
    Write-Host ""
    Write-Host ""
    Clear-Host

    # Calculate the exact width needed for the border
    # 4 accounts for the " # " prefix and the trailing space/hashtag spacing
    $BorderLength = $title.Length + 4
    $Border = "#" * $BorderLength

    Write-Host " ${cDarkGray}$Border${cReset} "
    Write-Host " ${cCyan}# $title #${cReset} "
    Write-Host " ${cDarkGray}$Border${cReset} "
    Write-Host ""
}

# Function to check if a command exists
function Test-CommandExists([string]$Command) {
    return (Get-Command $Command -ErrorAction SilentlyContinue)
}

function IsEdlMode {
    # Returns $true if a Qualcomm 9008 device is present.
    # Checks for both the standard Qualcomm VID/PID and the HS-USB / QDLoader strings
    $edlDevice = Get-CimInstance -ClassName Win32_PnPEntity |
    Where-Object { $_.Name -match "Qualcomm.*9008" -or $_.DeviceID -like "*VID_05C6&PID_9008*" }
    return [bool]$edlDevice
}

function IsAdbMode {
    $adbOutput = & $ADB devices
    return $adbOutput | Select-String -Pattern "`t" -Quiet
}

function IsFastbootMode {
    $fbDevices = & $FASTBOOT devices
    return $fbDevices -match "fastboot$"
}

function Wait-Continue([string]$action = "continue...") {
    Write-Host "`nPress ${cCyan}Enter${cReset} to $action" -NoNewline
    Read-Host | Out-Null
    Write-Host ""
}

function Wait-FastbootMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Host ""
    
    # Set labels based on mode
    if ($waitForDisconnect) {
        Write-Log "Waiting for device to ${cCyan}DISCONNECT${cReset}..." "Action"
    } else {
        Write-Log "Waiting for device to enter ${cCyan}FASTBOOT${cReset} mode..." "Action"
    }
    
    $success = $false
    for ($i = 1; $i -le $timeout; $i++) {
        $isDetected = IsFastbootMode

        # Check condition: when waiting for disconnect, $isDetected must be $false
        if (($waitForDisconnect -and -not $isDetected) -or (-not $waitForDisconnect -and $isDetected)) {
            $msg = if ($waitForDisconnect) { "Fastboot device disconnected." } else { "Fastboot device detected." }
            Write-Host "`r$msg                                       " -ForegroundColor Green
            $success = $true
            break
        }

        Write-Host "`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] " -NoNewline

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Host "`r  Skipped by user.                                         " -ForegroundColor Yellow
                    $skipped = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($skipped) {
            break
        }
    }
    
    Write-Host ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-FASTBOOT
    }

    return $success
}

function Wait-EdlMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Host ""
    
    # Set labels based on mode
    if ($waitForDisconnect) {
        Write-Log "Waiting for device to ${cCyan}DISCONNECT${cReset}..." "Action"
    } else {
        Write-Log "Waiting for device to enter ${cCyan}EDL${cReset} mode..." "Action"
    }
    
    $success = $false
    for ($i = 1; $i -le $timeout; $i++) {
        $isDetected = IsEdlMode

        # Check condition: when waiting for disconnect, $isDetected must be $false
        if (($waitForDisconnect -and -not $isDetected) -or (-not $waitForDisconnect -and $isDetected)) {
            $msg = if ($waitForDisconnect) { "EDL device disconnected." } else { "EDL device detected." }
            Write-Host "`r$msg                                       " -ForegroundColor Green
            if (-not $waitForDisconnect) { Start-Sleep -Seconds 5 }
            $success = $true
            break
        }

        Write-Host "`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] " -NoNewline

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Host "`r  Skipped by user.                                         " -ForegroundColor Yellow
                    $skipped = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($skipped) {
            break
        }
    }
    
    Write-Host ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-EDl
    }

    return $success
}

function Wait-AdbMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Host ""
    
    # Set labels based on mode
    if ($waitForDisconnect) {
        Write-Log "Waiting for device to ${cCyan}DISCONNECT${cReset}..." "Action"
    } else {
        Write-Log "Waiting for device to connect in ${cCyan}ADB${cReset} mode..." "Action"
    }
    
    $success = $false
    for ($i = 1; $i -le $timeout; $i++) {
        $isDetected = IsAdbMode

        # Check condition: when waiting for disconnect, $isDetected must be $false
        if (($waitForDisconnect -and -not $isDetected) -or (-not $waitForDisconnect -and $isDetected)) {
            $msg = if ($waitForDisconnect) { "ADB device disconnected." } else { "ADB device detected." }
            Write-Host "`r$msg                                       " -ForegroundColor Green
            $success = $true
            break
        }

        Write-Host "`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] " -NoNewline

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Host "`r  Skipped by user.                                         " -ForegroundColor Yellow
                    $skipped = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($skipped) {
            break
        }
    }
    
    Write-Host ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-ADB
    }

    return $success
}

function Select-Firehose {
    if ($null -eq $FirehoseTargetPath) {
        Write-Header "Select Firehose"
        Write-Host " [${cCyan}1${cReset}] Pico 4 / Pico Neo 3 (DDR 4)"
        Write-Host " [${cCyan}2${cReset}] Pico 4 Pro (DDR 5)"

        $fhChoice = Read-HostLog "Select your device model to use the correct firehose"

        if ($fhChoice -in "1", "") {
            $script:FirehoseTargetPath = $FirehoseDDR4Path
            Write-Log "Using DDR 4 Firehose." "Info"
        } elseif ($fhChoice -eq "2") {
            $script:FirehoseTargetPath = $FirehoseDDR5Path
            Write-Log "Using DDR 5 Firehose." "Info"
        }

        if (-not $fhChoice) {
            Wait-Continue
        }
    }
}

function Invoke-PicoHaxxScript {
    if (Test-Path $DeviceSerial) {
        $Serial = [long](Get-Content -Path $DeviceSerial -Raw).Trim()
    } else {
        Write-Log "Serial number not provided and '${DeviceSerial}' not found." "Error"
        return $null
    }

    $key = "0XD9J6FB3ATQIHNM46XYZZZOPQRSTUVWXYZ"
    $val = [int64]$Serial -band 0xF7F3F37F

    $encoded_serial = ""
    if ($val -eq 0) {
        $encoded_serial = $key[0]
    } else {
        $encoded_chars = New-Object System.Collections.Generic.List[char]
        while ($val -gt 0) {
            $index = $val -band 0xF
            $encoded_chars.Add($key[[int]$index])
            $val = [math]::Floor($val / 16)
        }
        $encoded_chars.Reverse()
        $encoded_serial = -join $encoded_chars
    }

    $unlockCommand = "fastboot oem pico$encoded_serial unlock"
    Write-Log "Generated Unlock Command: ${cCyan}$unlockCommand${cReset}" "Success"
    Write-Host ""

    return $unlockCommand
}

function Execute-UnlockCommand {
    $unlockCmd = Invoke-PicoHaxxScript
    if (-not $unlockCmd) {
        Write-Log "Unlock command generation failed. Please run 'Generate UnlockCode' first." "Error"
        return $false
    }

    Write-Log "Executing commands: ${cCyan}$unlockCmd${cReset}" "Action"
    $cmdToRun = "& " + ($unlockCmd -replace 'fastboot', "`"$FASTBOOT`"")
    Invoke-Expression $cmdToRun

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Unlock command executed successfully." "Success"
        return $true
    } else {
        Write-Log "Failed to execute unlock command." "Error"
        Write-Log "Please make sure ${cYellow}Flash Engineering ABL${cReset} is successful." "Error"
        Write-Log "And do not flash ${cYellow}Flash backup ABL${cReset}!" "Error"
        return $false
    }
}

function Perform-Reboot {
    Write-Header "Reboot Selection"
    Write-Host " [${cCyan}1${cReset}] Boot to SYSTEM"
    if (-not (IsEdlMode)) {
        Write-Host " [${cCyan}2${cReset}] Boot to FASTBOOT"
        Write-Host " [${cCyan}3${cReset}] Boot to recovery"
        if (-not (IsFastbootMode)) {
            Write-Host " [${cCyan}4${cReset}] Boot to EDL"
        }
    }
    Write-Host ""

    if (IsFastbootMode) {
        Write-Host "Device detected: ${cCyan}FASTBOOT${cReset}"
    } elseif (IsAdbMode) {
        Write-Host "Device detected: ${cGreen}ADB${cReset}"
    } elseif (IsEdlMode) {
        Write-Host "Device detected: ${cGreen}EDL${cReset}"
    } else {
        Write-Log "No device detected." "Error"
        Write-Log "Please connect your device and ensure it is powered on." "Info"
        return
    }

    $choice = Read-HostLog "Select an option"

    if (IsFastbootMode) {
        if ($choice -eq "1") {
            Fastboot-To-System
        } elseif ($choice -eq "2") {
            Fastboot-To-Fastboot
        } elseif ($choice -eq "3") {
            Fastboot-To-Recovery
        } elseif ($choice -eq "4") {
            Write-Log "Device is detected in ${cCyan}FASTBOOT${cReset} mode." "Warning"
            Write-Log "Unable to reboot to EDL." "Error"
        }
    } elseif (IsAdbMode) {
        if ($choice -eq "1") {
            ADB-To-System
        } elseif ($choice -eq "2") {
            ADB-To-Fastboot
        } elseif ($choice -eq "3") {
            ADB-To-Recovery
        } elseif ($choice -eq "4") {
            ADB-To-Edl
        }
    } elseif (IsEdlMode) {
        if ($choice -eq "1") {
            Edl-To-System
        }
    }
}

function Play-BeepBeep {
    [Console]::Beep(523, 150) # C5 tone for 150ms
    [Console]::Beep(784, 300) # G5 tone for 300ms
}

function Get-InstalledDriverInfo([string]$infName) {
    $drivers = pnputil /enum-drivers
    $found = $false
    $info = [PSCustomObject]@{
        Version  = $null
        Date     = $null
        Provider = $null
    }
    foreach ($line in $drivers) {
        if ($line -match "Original Name:\s+$infName") {
            $found = $true
        }
        if ($found) {
            if ($line -match "Driver Version:\s+(.*)") {
                $fullVersion = $matches[1].Trim()
                if ($fullVersion -match "(\d{2}/\d{2}/\d{4})\s+(.*)") {
                    $info.Date = $matches[1]
                    $info.Version = $matches[2]
                } else {
                    $info.Version = $fullVersion
                }
            }
            if ($line -match "Provider Name:\s+(.*)") {
                $info.Provider = $matches[1].Trim()
            }
        }
        # If we reach the next driver block or the end, return what we found
        if ($found -and $line -match "Published Name:" -and $null -ne $info.Version) {
            return $info
        }
    }
    if ($null -ne $info.Version) {
        return $info
    }
    return $null
}

function Warning-ADB {
    Write-Host ""
    Write-Log "Device not detected in ${cCyan}ADB${cReset} mode." "Error"
    Write-Log "Please connect your device and enable USB Debug." "Info"
    Write-Host ""
    Write-Log "1. Open PicoOS settings menu" "Info"
    Write-Log "2. Goto General > About" "Info"
    Write-Log "3. Tap '${cCyan}Software version${cReset}' 7 times quickly until the '${cCyan}Developer${cReset}' tab appears" "Info"
    Write-Log "4. Goto '${cCyan}Developer${cReset}' tab and enable the USB Debug option" "Info"
}

function Warning-FASTBOOT {
    Write-Host ""
    Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
    Write-Log "Please ensure device connected and in FASTBOOT mode." "Error"
    Write-Host "Manually boot to FASTBOOT by keep hold ${cYellow}Vol Down + Power${cReset}."
}

function Warning-EDL {
    Write-Host ""
    Write-Log "Device not detected in EDL mode." "Error"
    Write-Log "Manually boot to EDL by keep hold ${cYellow}Vol Up + Vol Down + Power${cReset}." "Info"
}

function Warning-EDL-ManualReboot {
    Write-Header "Post Steps"
    Write-Log "Your device will not automatically reboot." "Info"
    Write-Log "Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to ${cCyan}SYSTEM${cReset}." "Info"
    Write-Log "Hold ${cYellow}Vol Up + Vol Down + Power${cReset} for 10 seconds to reboot to ${cCyan}EDL${cReset}." "Info"
}

function ADB-To-System {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    & $ADB reboot
}

function ADB-To-Fastboot {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Action"
    & $ADB reboot bootloader
}

function ADB-To-Recovery {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Action"
    & $ADB reboot recovery
}

function ADB-To-Edl {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Action"
    & $ADB reboot edl
}

function Fastboot-To-System {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    & $FASTBOOT reboot
}

function Fastboot-To-Fastboot {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Action"
    & $FASTBOOT reboot bootloader
}

function Fastboot-To-Recovery {
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Action"
    & $FASTBOOT reboot recovery
}

function Edl-To-System {
    Select-Firehose

    Write-Host ""
    Write-Log "Device detected in ${cCyan}EDL${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    
    # Run silently using Out-Null
    & $EDLNG --loader $FirehoseTargetPath --memory UFS reset 2>&1 | Out-Null

    $exitcode = $LASTEXITCODE
    if ($exitcode -ne 0) { 
        Warning-EDL-ManualReboot
    } else {
        Write-Log "Reboot command sent successfully." "Success"
    }
}
