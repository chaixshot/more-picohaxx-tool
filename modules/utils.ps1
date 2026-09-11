#Requires -Version 5.1

<#
.SYNOPSIS
    Utility functions for the PicoUnlock project.
.DESCRIPTION
    Provides common functions for logging, UI headers, device mode detection,
    and rebooting operations. Used across all PicoUnlock modules.
#>

# --- Utility Functions ---
$SelectedFirehose = 0

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

function Write-Log([string]$message, [string]$type, [string]$ForegroundColor) {
    $params = @{}
    if ($ForegroundColor) { $params['ForegroundColor'] = $ForegroundColor }

    if ($type -in $null, "") {
        Write-Host " $message" @params
    } else {
        $Color = switch ($type) {
            "Success" {
                if ($IsWindows -or $env:OS -like "*Windows*") { [System.Media.SystemSounds]::Asterisk.Play() }
                $cGreen
            }
            "Warning" {
                if ($IsWindows -or $env:OS -like "*Windows*") { [System.Media.SystemSounds]::Exclamation.Play() }
                $cYellow
            }
            "Error" {
                if ($IsWindows -or $env:OS -like "*Windows*") { [System.Media.SystemSounds]::Hand.Play() }
                $cRed
            }
            "Action" {
                $cMagenta
            }
            Default {
                $cGray
            }
        }

        Write-Host " ${Color}[$type] ${cReset}$message" @params
    }
}

function Read-HostLog([string]$prompt) {
    [Console]::Write("`n${cGreen}>${cReset} ${prompt}: ${cGreen}")

    $inputResult = [Console]::ReadLine()

    [Console]::Write($cReset)

    # Force transcript stream capture without displaying text to the screen
    & {
        $InformationPreference = 'Continue'
        Write-Information "`n> ${prompt}: ${inputResult}"
    } 6>$null

    return $inputResult.ToString().ToLower().Trim()
}

function Clean-LogFormat([string]$LogFile) {
    if (Test-Path $LogFile) {
        $content = Get-Content $LogFile -Raw

        # Remove ANSI escape sequences (colors, styles, etc.)
        # This covers $cReset, $cCyan, $cYellow, $cGreen, $cMagenta, $cRed, $cBold, $cGray, $cWhite
        $esc = [char]27
        $pattern = "$( $esc )\[[0-9;]*[a-zA-Z]"

        $cleanContent = $content -replace $pattern, ""
        $cleanContent | Set-Content $LogFile -Force
    }
}

function Write-Header([string]$title) {
    Write-Log ""
    Write-Log ""
    Write-Log "================================================================="
    Write-Log "================================================================="
    Write-Log ""
    Write-Log ""
    Clear-Host

    # Calculate the exact width needed for the border
    # 4 accounts for the " # " prefix and the trailing space/hashtag spacing
    $BorderLength = $title.Length + 4
    $Border = "#" * $BorderLength

    Write-Log "${cDarkGray}$Border${cReset} "
    Write-Log "${cDarkGray}#${cReset}${cCyan} $title ${cReset}${cDarkGray}#${cReset} "
    Write-Log "${cDarkGray}$Border${cReset} "
    Write-Log ""
}

# Function to check if a command exists
function Test-CommandExists([string]$Command) {
    return (Get-Command $Command -ErrorAction SilentlyContinue)
}

#########################################
#########################################
#########################################

function IsEdlMode {
    # Returns $true if a Qualcomm 9008 device is present.
    # Checks for both the standard Qualcomm VID/PID and the HS-USB / QDLoader strings
    $edlDevice = Get-CimInstance -ClassName Win32_PnPEntity |
    Where-Object { $_.Name -match "Qualcomm.*9008" -or $_.DeviceID -like "*VID_05C6&PID_9008*" }
    return [bool]$edlDevice
}

function IsAdbMode {
    $adbOutput = & $ADB devices
    return $adbOutput | Select-String -Pattern "`tdevice$" -Quiet
}

function IsFastbootMode {
    $fbDevices = & $FASTBOOT devices
    return $fbDevices -match "fastboot$"
}

#########################################
#########################################
#########################################

function Wait-Continue([string]$action = "continue...") {
    Write-Log "`nPress ${cCyan}Enter${cReset} to $action" -NoNewline
    Read-Host | Out-Null
}

function Wait-FastbootMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Log ""
    
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
            Write-Log "`r$msg                                " -ForegroundColor Green
            $success = $true
            break
        }

        [System.Console]::Write("`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] ")

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Log "`rSkipped by user.                                " -ForegroundColor Yellow
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
    
    Write-Log ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-FASTBOOT
    }

    return $success
}

function Wait-EdlMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Log ""
    
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
            Write-Log "`r$msg                                " -ForegroundColor Green
            if (-not $waitForDisconnect) { Start-Sleep -Seconds 5 }
            $success = $true
            break
        }

        [System.Console]::Write("`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] ")

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Log "`rSkipped by user.                                " -ForegroundColor Yellow
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
    
    Write-Log ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-EDl
    }

    return $success
}

function Wait-AdbMode([int]$timeout = 100, [switch]$waitForDisconnect) {
    Write-Log ""
    
    if ($waitForDisconnect) {
        Write-Log "Waiting for device to ${cCyan}DISCONNECT${cReset}..." "Action"
    } else {
        Write-Log "Waiting for device to connect in ${cCyan}ADB${cReset} mode..." "Action"
    }
    
    $success = $false
    for ($i = 1; $i -le $timeout; $i++) {
        $isDetected = IsAdbMode

        if (($waitForDisconnect -and -not $isDetected) -or (-not $waitForDisconnect -and $isDetected)) {
            
            # If connecting, verify stability to avoid post-reboot ADB dropouts
            if (-not $waitForDisconnect) {
                [System.Console]::Write("`r  Validating stable ADB connection...                        ")
                
                # Check 1: Wait until Android OS reports boot complete
                $rawBoot = & $ADB shell getprop sys.boot_completed 2>$null
                $bootCompleted = (($rawBoot -join '').Trim()) -eq "1"
                
                # Check 2: Ensure connection stays active for 2 consecutive seconds
                Start-Sleep -Seconds 2
                $stillConnected = IsAdbMode

                if (-not $bootCompleted -or -not $stillConnected) {
                    # Device is still rebooting or dropped off; resume main loop
                    continue
                }
            }

            $msg = if ($waitForDisconnect) { "ADB device disconnected." } else { "ADB device detected and ready." }
            Write-Log "`r$msg                                " -ForegroundColor Green
            $success = $true
            break
        }

        [System.Console]::Write("`r  ...waiting ($i/$timeout) [${cCyan}ESC to skip${cReset}] ")

        $skipped = $false
        for ($j = 0; $j -lt 10; $j++) {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq "Escape") {
                    Write-Log "`rSkipped by user.                                " -ForegroundColor Yellow
                    $skipped = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($skipped) { break }
    }
    
    Write-Log ""
    if (-not $success -and -not $waitForDisconnect) {
        Warning-ADB
    }

    return $success
}

#########################################
#########################################
#########################################

function Select-Firehose {
    while ($SelectedFirehose -eq 0) {
        Write-Header "Select Firehose"
        Write-Log "[${cCyan}1${cReset}] Pico 4 ${cYellow}/${cReset} Pico 4 Enterprise ${cYellow}/${cReset} Pico Neo 3 ${cDarkGray}(DDR 4)${cReset}"
        Write-Log "[${cCyan}2${cReset}] Pico 4 Pro ${cDarkGray}(DDR 5)${cReset}"

        $selection = Read-HostLog "Select your device model to use the correct firehose"
        switch ($selection) {
            "1" { 
                $script:SelectedFirehose = 1
                Write-Log "Using DDR 4 Firehose." "Info"
            }
            "2" { 
                $script:SelectedFirehose = 2
                Write-Log "Using DDR 5 Firehose." "Info"
            }
            Default {
                Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
                Wait-Continue
            }
        }
    }
}

function Invoke-PicoHaxxScript {
    $unlockCommand = $null

    try {
        if (-not (Test-Path $DeviceSerial)) {
            throw "Serial number not provided and '${DeviceSerial}' not found."
        }

        $Serial = [long](Get-Content -Path $DeviceSerial -Raw).Trim()

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
        Write-Log ""
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $unlockCommand
}

function Execute-UnlockCommand {
    $success = $false

    try {
        $unlockCmd = Invoke-PicoHaxxScript
        if (-not $unlockCmd) {
            throw "Unlock command generation failed. Please run 'Generate UnlockCode' first."
        }

        Write-Log "Executing commands: ${cCyan}$unlockCmd${cReset}" "Action"
        $cmdToRun = "& " + ($unlockCmd -replace 'fastboot', "`"$FASTBOOT`"")
        Invoke-Expression $cmdToRun

        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to execute unlock command." "Error"
            throw "Please make sure ${cYellow}Flash engineering ABL${cReset} is successful and don't ${cYellow}Flash backup ABL${cReset} yet."
        }

        $success = $true
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Unlock command executed successfully." "Success"
        }
    }

    return $success
}

function Execute-EdlCommand([string]$sCMDLine, [bool]$silent = $false, [bool]$get = $false) {
    $outputLines = [System.Collections.Generic.List[string]]::new()
    $lastWasProgress = $false
    $success = $false

    try {
        if ($SelectedFirehose -eq 0) {
            throw "No firesose selected"
        }

        $firehose = switch ($SelectedFirehose) {
            1 { $FirehoseDDR4Path }
            2 { $FirehoseDDR5Path }
            Default { $FirehoseDDR4Path }
        }

        # Execute edl-ng and capture its output stream.
        # 2>&1 redirects stderr to stdout so we can process all output.
        $expression = "& `"$EDLNG`" --loader $firehose --memory UFS $sCMDLine 2>&1"

        Invoke-Expression $expression | ForEach-Object {
            $line = $_.ToString().TrimEnd()
            $outputLines.Add($line)

            if (-not $silent) {
                # Identify progress lines (Reading/Writing percentage updates)
                if ($line -match "^(Reading|Writing):\s+\d+\.\d+%") {
                    # Use [Console]::Write to output to the console without a newline.
                    # This stays on the same line and typically bypasses Start-Transcript logging.
                    [System.Console]::Write("`r$line".PadRight(100))
                    $lastWasProgress = $true
                } else {
                    # If the previous output was progress, ensure we start the next message on a new line
                    if ($lastWasProgress) {
                        Write-Log ""
                        $lastWasProgress = $false
                    }
                    Write-Log $line
                }
            }
        }

        if ($LASTEXITCODE -ne 0) {
            throw "edl-ng failed with ExitCode: $LASTEXITCODE"
        }

        $success = $true
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        # Final cleanup newline if silent was false and last output was progress
        if (-not $silent -and $lastWasProgress) {
            Write-Log ""
        }
    }

    if ($get) {
        return $outputLines
    } else {
        return $success
    }
}

function Perform-Reboot {
    Write-Header "Reboot Selection"

    try {
        if (IsFastbootMode) {
            Write-Log "Device detected: ${cCyan}FASTBOOT${cReset}"
        } elseif (IsAdbMode) {
            Write-Log "Device detected: ${cGreen}ADB${cReset}"
        } elseif (IsEdlMode) {
            Write-Log "Device detected: ${cGreen}EDL${cReset}"
        } else {
            Write-Log "No device detected." "Error"
            throw "Please connect your device and ensure it is powered on."
        }

        Write-Log "[${cCyan}1${cReset}] Boot to SYSTEM"
        if (-not (IsEdlMode)) {
            Write-Log "[${cCyan}2${cReset}] Boot to FASTBOOT"
        }
        Write-Log "[${cCyan}3${cReset}] Boot to RECOVERY"
        Write-Log "[${cCyan}4${cReset}] Boot to EDL"

        $selection = Read-HostLog "Select an option"

        if (IsFastbootMode) {
            if ($selection -eq "1") { Fastboot-To-System; throw "" }
            elseif ($selection -eq "2") { Fastboot-To-Fastboot; throw "" }
            elseif ($selection -eq "3") { Fastboot-To-Recovery; throw "" }
            elseif ($selection -eq "4") { Fastboot-To-Edl; throw "" }
        } elseif (IsAdbMode) {
            if ($selection -eq "1") { ADB-To-System; throw "" }
            elseif ($selection -eq "2") { ADB-To-Fastboot; throw "" }
            elseif ($selection -eq "3") { ADB-To-Recovery; throw "" }
            elseif ($selection -eq "4") { ADB-To-Edl; throw "" }
        } elseif (IsEdlMode) {
            if ($selection -eq "1") { Edl-To-System; throw "" }
            elseif ($selection -eq "3") { Edl-To-Recovery; throw "" }
            elseif ($selection -eq "4") { Edl-To-Edl; throw "" }
        }

        throw "Invalid input: [${cYellow}$selection${cReset}]"
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function Play-BeepBeep {
    # Track objects to dispose in finally block if an error occurs
    $msStream = $null
    $writer = $null
    $player = $null

    try {
        $sampleRate = 22050
        $bpm = 100
        
        # Base duration units based on tempo (100 BPM)
        $quarter = [int](60000 / $bpm)          # 600ms
        $triplet = [int]($quarter / 3)         # 200ms

        # Sheet music transcription (Freq in Hz, Duration in ms, Rest in ms)
        $notes = @(
            # --- INTRO ---
            @{ Freq = 659; Duration = 100; Rest = 50 },  # E5
            @{ Freq = 659; Duration = 100; Rest = 200 }, # E5
            @{ Freq = 659; Duration = 100; Rest = 200 }, # E5
            @{ Freq = 523; Duration = 100; Rest = 50 },  # C5
            @{ Freq = 659; Duration = 100; Rest = 200 }, # E5
            @{ Freq = 784; Duration = 200; Rest = 400 }, # G5
            @{ Freq = 392; Duration = 200; Rest = 400 }, # G4

            # --- MAIN THEME (SYNCATED LINE) ---
            @{ Freq = 523; Duration = 200; Rest = 250 }, # C5
            @{ Freq = 392; Duration = 200; Rest = 250 }, # G4
            @{ Freq = 330; Duration = 200; Rest = 250 }, # E4
            
            @{ Freq = 440; Duration = 120; Rest = 30 },  # A4
            @{ Freq = 494; Duration = 120; Rest = 30 },  # B4
            @{ Freq = 466; Duration = 120; Rest = 30 },  # Bb4
            @{ Freq = 440; Duration = 150; Rest = 150 }, # A4

            # Triplet run up
            @{ Freq = 392; Duration = $triplet - 30; Rest = 30 }, # G4
            @{ Freq = 659; Duration = $triplet - 30; Rest = 30 }, # E5
            @{ Freq = 784; Duration = $triplet - 30; Rest = 30 }, # G5

            @{ Freq = 880; Duration = 200; Rest = 100 }, # A5
            @{ Freq = 698; Duration = 100; Rest = 50 },  # F5
            @{ Freq = 784; Duration = 100; Rest = 150 }, # G5
            @{ Freq = 659; Duration = 200; Rest = 100 }, # E5
            @{ Freq = 523; Duration = 100; Rest = 50 },  # C5
            @{ Freq = 587; Duration = 100; Rest = 50 },  # D5
            @{ Freq = 494; Duration = 200; Rest = 200 }  # B4
        )

        $msStream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($msStream)

        # WAV Header setup
        $writer.Write([char[]]"RIFF")
        $writer.Write([int]0)
        $writer.Write([char[]]"WAVEfmt ")
        $writer.Write([int]16)
        $writer.Write([int16]1)                  # PCM format
        $writer.Write([int16]1)                  # Mono channel
        $writer.Write([int]$sampleRate)
        $writer.Write([int]($sampleRate * 2))     # Byte rate
        $writer.Write([int16]2)                  # Block align
        $writer.Write([int16]16)                 # Bits per sample
        $writer.Write([char[]]"data")
        $writer.Write([int]0)

        # Pre-roll silence (500ms)
        $prerollSamples = [int]($sampleRate * 0.5)
        for ($i = 0; $i -lt $prerollSamples; $i++) { $writer.Write([int16]0) }

        # Generate PCM Audio Data
        foreach ($note in $notes) {
            $totalDuration = $note.Duration + $(if ($null -ne $note.Rest) { $note.Rest } else { 0 })
            $totalSamples = [int]($sampleRate * ($totalDuration / 1000))
            $noteSamples = [int]($sampleRate * ($note.Duration / 1000))

            for ($i = 0; $i -lt $totalSamples; $i++) {
                if ($i -lt $noteSamples -and $note.Freq -gt 0) {
                    $period = $sampleRate / $note.Freq
                    $wavePosition = $i % $period
                    $amplitude = 0.2
                    
                    $sample = if ($wavePosition -lt ($period / 2)) { $amplitude * 32767 } else { - $amplitude * 32767 }
                    $writer.Write([int16][int]$sample)
                } else {
                    $writer.Write([int16]0)
                }
            }
        }

        # Finalize WAV headers
        $dataLength = [int]($msStream.Length - 44)
        $msStream.Position = 4
        $writer.Write([int]($msStream.Length - 8))
        $msStream.Position = 40
        $writer.Write([int]$dataLength)

        # Play audio
        $msStream.Position = 0
        $player = New-Object System.Media.SoundPlayer($msStream)
        $player.Play()

        # Prevent Garbage Collection during playback
        $global:ActiveAudioPlayer = @{
            Player = $player
            Stream = $msStream
            Writer = $writer
        }

        return $true
    } catch {
        # Clean up stream objects if synthesis failed midway
        if ($writer) { $writer.Dispose() }
        if ($msStream) { $msStream.Dispose() }
        if ($player) { $player.Dispose() }
        
        return $false
    }
}

function Select-InteractiveMenu([string]$header = "", [string[]]$options, [int]$defaultIndex = 0, [int]$maxVisible = 10) {
    if ($options.Count -eq 0) { return -1 }

    $selectedIndex = $defaultIndex
    $pageSize = [Math]::Min($maxVisible, $options.Count)
    
    try { [Console]::CursorVisible = $false } catch {}

    # Initial Render Helper Function
    function Render-Menu {

        param([int]$selected, [int]$pSize)

        # Determine visible window start index
        $startIndex = [Math]::Max(0, [Math]::Min($selected - [Math]::Floor($pSize / 2), $options.Count - $pSize))
        $endIndex = $startIndex + $pSize - 1

        for ($i = $startIndex; $i -le $endIndex; $i++) {
            $num = $i + 1
            $prefix = if ($i -eq $selected) { " > " } else { "   " }
            $line = "${prefix}[${num}] $($options[$i])"

            if ($i -eq $selected) {
                Write-Host $line.PadRight([Console]::WindowWidth - 1) -ForegroundColor Cyan
            } else {
                Write-Host $line.PadRight([Console]::WindowWidth - 1)
            }
        }
        
        # Display page navigation indicator
        $pageInfo = "--- Page $([Math]::Ceiling(($selected + 1) / $pSize)) of $([Math]::Ceiling($options.Count / $pSize)) [${cYellow}Up/Down${cReset}] or [${cYellow}Left/Right${cReset}] to Navigate) ---"
        Write-Host $pageInfo.PadRight([Console]::WindowWidth - 1) -ForegroundColor DarkGray
    }

    # First Pass Render
    Write-Log $header "Info"
    Render-Menu -selected $selectedIndex -pSize $pageSize

    while ($true) {
        $key = [Console]::ReadKey($true)
        
        if ($key.Key -eq "UpArrow") {
            $selectedIndex = ($selectedIndex - 1 + $options.Count) % $options.Count
        } elseif ($key.Key -eq "DownArrow") {
            $selectedIndex = ($selectedIndex + 1) % $options.Count
        } elseif ($key.Key -eq "LeftArrow") {
            $selectedIndex = [Math]::Max(0, $selectedIndex - $pageSize)
        } elseif ($key.Key -eq "RightArrow") {
            $selectedIndex = [Math]::Min($options.Count - 1, $selectedIndex + $pageSize)
        } elseif ($key.Key -eq "Enter") {
            break
        } elseif ($key.Key -eq "Escape") {
            $selectedIndex = -1
            break
        }

        # Safe In-Place Redraw Calculation
        $linesToMoveUp = $pageSize + 1
        $targetTop = [Console]::CursorTop - $linesToMoveUp

        if ($targetTop -ge 0) {
            [Console]::SetCursorPosition(0, $targetTop)
        } else {
            [Console]::SetCursorPosition(0, 0)
        }

        Render-Menu -selected $selectedIndex -pSize $pageSize
    }

    try { [Console]::CursorVisible = $true } catch {}

    return $selectedIndex
}

function Get-FileOrFolderDialog([string]$title = "", [int]$mode = 0, [string]$extension = "") {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Determine effective title (falls back to a default based on mode if $title is empty)
    $dialogTitle = if ([string]::IsNullOrWhiteSpace($title)) {
        switch ($mode) {
            0 { "Select a file" }
            1 { "Select a destination folder" }
            2 { "Select File or Folder" }
        }
    } else {
        $title
    }

    # Helper function that splits comma-separated extensions (e.g., "rar, zip") into valid filter patterns
    $getFilter = {
        param([string]$ext)
        if ([string]::IsNullOrWhiteSpace($ext)) {
            return "All Files (*.*)|*.*"
        } else {
            $extList = $ext.Split(',') | ForEach-Object {
                $clean = $_.Trim()
                if (-not $clean.StartsWith("*")) {
                    if (-not $clean.StartsWith(".")) {
                        "*.$clean"
                    } else {
                        "*$clean"
                    }
                } else {
                    $clean
                }
            }
            $joinedExts = $extList -join ";"
            return "Custom Files ($joinedExts)|$joinedExts"
        }
    }

    switch ($mode) {
        0 {
            Write-Log "Please select ${cYellow}'$extension'${cReset} file from explorer." "Info"
            Wait-Continue $dialogTitle

            # File picker only
            $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $openFileDialog.Title = $dialogTitle
            $openFileDialog.Filter = &$getFilter $extension
            if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                return $openFileDialog.FileName
            } else {
                Write-Log "No file was selected." "Warning"
                Wait-Continue

                return ""
            }
        }
        1 {
            Write-Log "Please select ${cYellow}folder${cReset} from explorer." "Info"
            Wait-Continue $dialogTitle

            # Folder picker only
            $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderDialog.Description = $dialogTitle
            $folderDialog.ShowNewFolderButton = $true
            if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                return $folderDialog.SelectedPath
            } else {
                Write-Log "No folder was selected." "Warning"
                Wait-Continue

                return ""
            }
        }
        2 {
            Write-Log "Please select ${cYellow}'$extension'${cReset} file or ${cYellow}folder${cReset} from explorer." "Info"
            Wait-Continue $dialogTitle
            
            # Both (Modern Fluent Custom Dialog window)
            $form = New-Object System.Windows.Forms.Form
            $form.Text = $dialogTitle
            $form.Size = New-Object System.Drawing.Size(480, 195)
            $form.StartPosition = "CenterScreen"
            $form.FormBorderStyle = 'FixedDialog'
            $form.MaximizeBox = $false
            $form.MinimizeBox = $false
            $form.TopMost = $true
            $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
            $form.BackColor = [System.Drawing.SystemColors]::Control

            $textBox = New-Object System.Windows.Forms.TextBox
            $textBox.Location = New-Object System.Drawing.Point(20, 25)
            $textBox.Size = New-Object System.Drawing.Size(320, 25)
            $form.Controls.Add($textBox)

            $btnFile = New-Object System.Windows.Forms.Button
            $btnFile.Location = New-Object System.Drawing.Point(350, 24)
            $btnFile.Size = New-Object System.Drawing.Size(90, 27)
            $btnFile.Text = "File..."
            $btnFile.FlatStyle = 'System'
            $btnFile.Add_Click({
                    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
                    $openFileDialog.Title = $dialogTitle
                    $openFileDialog.Filter = &$getFilter $extension
                    if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $textBox.Text = $openFileDialog.FileName
                    }
                })
            $form.Controls.Add($btnFile)

            $btnFolder = New-Object System.Windows.Forms.Button
            $btnFolder.Location = New-Object System.Drawing.Point(350, 58)
            $btnFolder.Size = New-Object System.Drawing.Size(90, 27)
            $btnFolder.Text = "Folder..."
            $btnFolder.FlatStyle = 'System'
            $btnFolder.Add_Click({
                    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
                    $folderDialog.Description = $dialogTitle
                    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $textBox.Text = $folderDialog.SelectedPath
                    }
                })
            $form.Controls.Add($btnFolder)

            $btnOk = New-Object System.Windows.Forms.Button
            $btnOk.Location = New-Object System.Drawing.Point(260, 105)
            $btnOk.Size = New-Object System.Drawing.Size(85, 30)
            $btnOk.Text = "OK"
            $btnOk.FlatStyle = 'System'
            $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.AcceptButton = $btnOk
            $form.Controls.Add($btnOk)

            $btnCancel = New-Object System.Windows.Forms.Button
            $btnCancel.Location = New-Object System.Drawing.Point(355, 105)
            $btnCancel.Size = New-Object System.Drawing.Size(85, 30)
            $btnCancel.Text = "Cancel"
            $btnCancel.FlatStyle = 'System'
            $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.CancelButton = $btnCancel
            $form.Controls.Add($btnCancel)

            if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                return $textBox.Text
            } else {
                Write-Log "No file or folder was selected." "Warning"
                Wait-Continue

                return ""
            }
        }
    }
}

function Get-InstalledDriverInfo([string]$infName) {
    # Run pnputil quickly as raw text lines
    $raw = pnputil /enum-drivers
    if (-not $raw) { return $null }

    # Group output lines into driver blocks separated by empty lines
    $blocks = ($raw -join "`n") -split "(?m)^\s*`r?\n"

    foreach ($block in $blocks) {
        # Check if this block belongs to the target INF file
        if ($block -match "(?i)\b$([regex]::Escape($infName))\b") {
            
            # Extract key-value pairs (Line Title : Line Value)
            $lines = $block -split "`n" | Where-Object { $_ -match ":" }
            $fields = @()
            foreach ($line in $lines) {
                $parts = $line -split ":", 2
                if ($parts.Count -eq 2) {
                    $fields += $parts[1].Trim()
                }
            }

            # Map fields by standard pnputil block structure position:
            # Field 0: Published Name (oemXX.inf)
            # Field 1: Original Name (qcser.inf)
            # Field 2: Provider Name (Qualcomm Incorporated)
            # Field 3: Class / Category
            # Field 4: Driver Date and Version

            $info = [PSCustomObject]@{
                Version  = $null
                Date     = $null
                Provider = $null
            }

            # Search specifically for version (X.X.X.X) and date (XX/XX/XXXX or XX.XX.XXXX) across fields
            foreach ($field in $fields) {
                if ($field -match "(\d{1,2}[\/\.]\d{1,2}[\/\.]\d{2,4})\s+(.*)") {
                    $info.Date = $matches[1]
                    $info.Version = $matches[2]
                } elseif ($field -match "^\d+\.\d+\.\d+\.\d+$" -and -not $info.Version) {
                    $info.Version = $field
                }
            }

            # Provider is almost always Field 2 (or Field 1 depending on pnputil header order)
            # We select the field that is NOT an INF name, NOT a date/version, and NOT a class
            foreach ($field in $fields) {
                if ($field -notmatch "\.inf$" -and $field -notmatch "\d+\.\d+" -and $field -ne "Ports (COM & LPT)" -and $field -ne "Порты (COM и LPT)") {
                    # Skip Signer Name if present (usually contains "Publisher" or "Microsoft")
                    if ($field -notmatch "Publisher" -and $field -notmatch "Compatibility") {
                        $info.Provider = $field
                        break
                    }
                }
            }

            if ($null -ne $info.Version) {
                return $info
            }
        }
    }

    return $null
}

#########################################
#########################################
#########################################

function Warning-ADB {
    Write-Log ""
    Write-Log "Device not detected in ${cCyan}ADB${cReset} mode." "Error"
    Write-Log "Please connect your device and enable USB Debug." "Info"
    Write-Log ""
    Write-Log "1. Open PicoOS settings menu" "Info"
    Write-Log "2. Goto General > About" "Info"
    Write-Log "3. Tap '${cCyan}Software version${cReset}' 7 times quickly until the '${cCyan}Developer${cReset}' tab appears" "Info"
    Write-Log "4. Goto '${cCyan}Developer${cReset}' tab and enable the USB Debug option" "Info"
}

function Warning-RECOVERY {
    Write-Log ""
    Write-Log "Device not detected in ${cCyan}RECOVERY${cReset} mode." "Error"
    Write-Log "Please ensure device connected and in ${cCyan}RECOVERY${cReset} mode." "Error"
    Write-Log "Manually boot to ${cCyan}RECOVERY${cReset} by keep holding ${cYellow}Vol Up + Power${cReset} until dead robot shows up." "Info"
}

function Warning-FASTBOOT {
    Write-Log ""
    Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
    Write-Log "Please ensure device connected and in ${cCyan}FASTBOOT${cReset} mode." "Error"
    Write-Log "Manually boot to ${cCyan}FASTBOOT${cReset} by keep holding ${cYellow}Vol Down + Power${cReset} until menu shows up." "Info"
}

function Warning-EDL {
    Write-Log ""
    Write-Log "Device not detected in ${cCyan}EDL${cReset} mode." "Error"
    Write-Log "Manually boot to ${cCyan}EDL${cReset} by keep holding ${cYellow}Vol Up + Vol Down + Power${cReset} until screen off and USB detected." "Info"
}

function Warning-EDL-ManualReboot {
    Write-Header "EDL Manual Reboot"
    Write-Log "Your device will not automatically reboot." "Info"
    Write-Log "Manually boot to ${cCyan}SYSTEM${cReset} by keep holding ${cYellow}Power Button${cReset} until Pico logo shows up." "Info"
    Write-Log "Manually boot to ${cCyan}RECOVERY${cReset} by keep holding ${cYellow}Vol Up + Power${cReset} until dead robot shows up." "Info"
    Write-Log "Manually boot to ${cCyan}FASTBOOT${cReset} by keep holding ${cYellow}Vol Down + Power${cReset} until menu shows up." "Info"
    Write-Log "Manually boot to ${cCyan}EDL${cReset} by keep holding ${cYellow}Vol Up + Vol Down + Power${cReset} until screen off and USB detected." "Info"
}

# ---------------------------------------------

function ADB-To-System {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    & $ADB reboot
}

function ADB-To-Recovery {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Action"
    & $ADB reboot recovery
}

function ADB-To-Fastboot {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Action"
    & $ADB reboot bootloader
}

function ADB-To-Edl {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Action"
    & $ADB reboot edl
}

# ---------------------------------------------

function Fastboot-To-System {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    & $FASTBOOT reboot
}

function Fastboot-To-Recovery {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Action"
    & $FASTBOOT reboot recovery
}

function Fastboot-To-Fastboot {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Action"
    & $FASTBOOT reboot bootloader
}

function Fastboot-To-Edl {
    Write-Log ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Action"
    Write-Log "Keep holding ${cYellow}Vol Up + Vol Down${cReset} before continue" "Info"
    Wait-Continue

    if (IsFastbootMode) {
        & $FASTBOOT reboot
    }
}

# ---------------------------------------------

function Edl-To-System {
    Select-Firehose

    Write-Log ""
    Write-Log "Device detected in ${cCyan}EDL${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Action"
    
    if (Execute-EdlCommand "reset" $true) { 
        Write-Log "Reboot command sent successfully." "Success"
    } else {
        Warning-EDL-ManualReboot
    }
}

function Edl-To-Recovery {
    Select-Firehose

    Write-Log ""
    Write-Log "Device detected in ${cCyan}EDL${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Action"
    Write-Log "Keep holding ${cYellow}Vol Up${cReset} before continue" "Info"
    Wait-Continue
    
    if (Execute-EdlCommand "reset" $true) { 
        Write-Log "Reboot command sent successfully." "Success"
    } else {
        Warning-EDL-ManualReboot
    }
}

function Edl-To-Fastboot {
    # Not working
}

function Edl-To-Edl {
    Select-Firehose

    Write-Log ""
    Write-Log "Device detected in ${cCyan}EDL${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Action"
    Write-Log "Keep holding ${cYellow}Vol Up + Vol Down${cReset} before continue" "Info"
    Wait-Continue
    
    if (Execute-EdlCommand "reset" $true) { 
        Write-Log "Reboot command sent successfully." "Success"
    } else {
        Warning-EDL-ManualReboot
    }
}

#########################################
#########################################
#########################################
