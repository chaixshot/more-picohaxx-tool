#Requires -Version 5.1

<#
.SYNOPSIS
    Automates the bootloader unlock and root process for Pico 4 devices.
.DESCRIPTION
    This script follows the steps outlined in more-picohaxx.py to unlock the bootloader and root the device.
    It handles getting the serial number, generating the unlock code, downloading necessary files,
    executing required edl, fastboot, and Magisk rooting operations.

    WARNING:
    - Unlocking the bootloader will wipe your data partition. BACKUP YOUR DATA.
    - Rooting may void your warranty.
    - Incorrect flashing can brick your device.
    - This is a complex process. Proceed only if you are familiar with adb, edl, and fastboot.
    - The script authors and I are not responsible for any damage to your device.

.NOTES
    Prerequisites:
    - adb.exe and fastboot.exe must be in your PATH or the script's directory.
    - edl-ng.exe (from https://github.com/strongtz/edl-ng) must be in the script's directory.
    - The 'more-picohaxx.py' script must be in the same directory.
    - Magisk4Pico.apk must be in the .\tools directory for rooting.
#>

# ----------------------------
# --- Script Configuration ---
# ----------------------------
$WorkingDir = $PSScriptRoot
$LogsPath = Join-Path $WorkingDir "logs"
$DriverInstall = Join-Path $WorkingDir "tools\driver\install.ps1"

$FirehoseDDR4Path = Join-Path $WorkingDir "tools\firehoses\prog_firehose_ddr.elf"
$FirehoseDDR5Path = Join-Path $WorkingDir "tools\firehoses\prog_firehose_lite.elf"

$AblPath = Join-Path $WorkingDir "tools\engineering\abl.elf"
$DevInfoPath = Join-Path $WorkingDir "tools\engineering\devinfo"

$BackupPath = Join-Path $WorkingDir "backup"
$AblBackupPath = Join-Path $BackupPath "abl"
$DeviceSerial = Join-Path $BackupPath "serial_number.txt"

$EDLNG = Join-Path $WorkingDir "tools\edl-ng.exe"
$ADB = Join-Path $WorkingDir "tools\adb.exe"
$FASTBOOT = Join-Path $WorkingDir "tools\fastboot.exe"
$FASTBOOTNEO = Join-Path $WorkingDir "tools\neo\fastboot.exe"

$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$VersionStr = "Pico Unlock 1.3.3"

$IsRetryBootloader = 0

# ----------------------------
# ----- Helper Functions -----
# ----------------------------

. "$WorkingDir/modules/utils.ps1"
. "$WorkingDir/modules/root.ps1"
. "$WorkingDir/modules/backuprestore.ps1"
. "$WorkingDir/modules/qfilhelper.ps1"

function Check-Prerequisites {
    Write-Header "Running Prerequisite Checks"
    Write-Log $VersionStr  "Info"

    $isReady = $true

    if (-not (Test-Path $ADB) -and -not (Test-CommandExists "adb")) {
        Write-Log "${cYellow}$ADB${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
        Write-Log ""
        $isReady = $false
    }
    if (-not (Test-Path $FASTBOOT) -and -not (Test-CommandExists "fastboot")) {
        Write-Log "${cYellow}$FASTBOOT${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
        Write-Log ""
        $isReady = $false
    }
    if (-not (Test-Path $EDLNG)) {
        Write-Log "${cYellow}edl-ng${cReset} not found. Please place it in the script directory." "Error"
        Write-Log ""
        $isReady = $false
    }
    if (-not (Test-Path $AblPath)) {
        Write-Log "'${cYellow}$AblPath${cReset}' not found. Please download it and place it correctly." "Error"
        Write-Log ""
        $isReady = $false
    }
    if (-not (Test-Path $FirehoseDDR4Path)) {
        Write-Log "'${cYellow}$FirehoseDDR4Path${cReset}' not found. Please download it and place it correctly." "Error"
        Write-Log ""
        $isReady = $false
    }
    if (-not (Test-Path $FirehoseDDR5Path)) {
        Write-Log "'${cYellow}$FirehoseDDR5Path${cReset}' not found. Please download it and place it correctly." "Error"
        Write-Log ""
        $isReady = $false
    }

    # Detect legacy/conflicting qdl_winusb.inf driver
    $allDrivers = pnputil /enum-drivers
    $qdlDrivers = $allDrivers | Select-String -Pattern "qdl_winusb\.inf" -Context 1, 0
    if ($qdlDrivers) {
        Write-Log "Found legacy/conflicting driver '${cYellow}qdl_winusb.inf${cReset}' installed." "Warning"
        Write-Log "This driver is known to cause issues with current EDL flashing tools." "Info"
        $deleteChoice = Read-HostLog "Do you want to ${cRed}delete${cReset} it? [${cYellow}Y${cReset}/n]"
        if ($deleteChoice -eq 'y') {
            foreach ($match in $qdlDrivers) {
                # Extract oemXX.inf from the line above the match
                $publishedName = ($match.Context.PreContext[0] -replace "Published Name:\s+", "").Trim()
                if ($publishedName -match "oem\d+\.inf") {
                    Write-Log "Deleting driver ${cCyan}$publishedName${cReset} (qdl_winusb.inf)..." "Action"
                    pnputil /delete-driver $publishedName /uninstall /force | Out-Null
                }
            }

            Write-Log "Rescanning hardware devices to rebind correct driver..." "Action"
            pnputil /scan-devices | Out-Null

            # Verification step
            Write-Log ""
            $verifyDrivers = pnputil /enum-drivers
            if ($verifyDrivers -match "qdl_winusb\.inf") {
                Write-Log "Failed to completely remove '${cYellow}qdl_winusb.inf${cReset}'. Manual removal may be required." "Error"
                Write-Log "Use DriverStoreExplorer (https://github.com/lostindark/driverstoreExplorer) to proceed." "Interactive"
                $isReady = $false
            } else {
                Write-Log "'${cYellow}qdl_winusb.inf${cReset}' has been removed." "Success"
            }
        } else {
            $isReady = $false
        }

        Write-Log ""
    }

    # Check for EDL driver and offer to install it
    $qcser_version = "1.1.0.2"
    $qcser_provider = "Qualcomm Incorporated"
    $qcser_date = "11/26/2021"
    $android_winusb_version = "11.0.0.0"
    $android_provider = "LeMobile"
    $android_date = "08/28/2016"

    $currentQcser = Get-InstalledDriverInfo "qcser.inf"
    $currentWinusb = Get-InstalledDriverInfo "android_winusb.inf"

    $needsInstall = $false
    $needsUpdate = $false

    if ($null -eq $currentQcser -or $null -eq $currentWinusb) {
        $needsInstall = $true
    } elseif ($currentQcser.Version -ne $qcser_version -or $currentQcser.Provider -ne $qcser_provider -or $currentQcser.Date -ne $qcser_date -or $currentWinusb.Version -ne $android_winusb_version -or $currentWinusb.Provider -ne $android_provider -or $currentWinusb.Date -ne $android_date) {
        $needsUpdate = $true
    }

    if ($needsInstall -or $needsUpdate) {
        if ($needsInstall) {
            Write-Log "The required drivers for ${cCyan}EDL/Fastboot mode${cReset} do not appear to be installed." "Warning"
        } else {
            Write-Log "A driver version, provider, or date mismatch was detected." "Warning"
            Write-Log "Installed:" "Info"
            Write-Log "   qcser: ${cRed}$($currentQcser.Version)${cReset} - ${cMagenta}$($currentQcser.Date)${cReset} (${cYellow}$($currentQcser.Provider)${cReset})" "Info"
            Write-Log "   winusb: ${cRed}$($currentWinusb.Version)${cReset} - ${cMagenta}$($currentWinusb.Date)${cReset} (${cYellow}$($currentWinusb.Provider)${cReset})" "Info"
            Write-Log ""
            Write-Log "Required:" "Info"
            Write-Log "   qcser: ${cGreen}$qcser_version${cReset} - ${cMagenta}$($qcser_date)${cReset} (${cYellow}$qcser_provider${cReset})" "Info"
            Write-Log "   winusb: ${cGreen}$android_winusb_version${cReset} - ${cMagenta}$($android_date)${cReset} (${cYellow}$android_provider${cReset})" "Info"
            Write-Log ""
        }

        Write-Log "This is required for flashing the ${cYellow}bootloader${cReset}." "Info"
        $actionVerb = if ($needsUpdate) { "update" } else { "install" }

        $choice = Read-HostLog "Would you like to $actionVerb drivers? [${cYellow}Y${cReset}/n]"
        if ($choice -eq 'y') {
            if (-not (Test-Path $DriverInstall)) {
                Write-Log "Driver installation script not found at '${cYellow}$DriverInstall${cReset}'." "Error"
                $isReady = $false
            } else {
                # Start the install script elevated
                Write-Log "Launching driver installer..." "Action"
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$DriverInstall`"" -NoNewWindow -Wait

                Write-Log "Driver installation process finished. Re-checking versions..." "Action"
                $checkQcser = Get-InstalledDriverInfo "qcser.inf"
                $checkWinusb = Get-InstalledDriverInfo "android_winusb.inf"

                if ($null -eq $checkQcser -or $checkQcser.Version -ne $qcser_version -or $checkQcser.Provider -ne $qcser_provider -or $checkQcser.Date -ne $qcser_date -or
                    $null -eq $checkWinusb -or $checkWinusb.Version -ne $android_winusb_version -or $checkWinusb.Provider -ne $android_provider -or $checkWinusb.Date -ne $android_date) {
                    Write-Log "Driver mismatch still detected after installation." "Error"
                    Write-Log "Please run '${cYellow}$DriverInstall${cReset}' manually and then re-run this script." "Error"
                    $isReady = $false
                } else {
                    Write-Log "Drivers successfully installed/updated." "Success"
                }

                Write-Log "Rescanning hardware devices to rebind correct driver..." "Action"
                pnputil /scan-devices | Out-Null
            }
        } else {
            $isReady = $false
            Write-Log "Skipping driver installation. The script may fail if the driver is not installed correctly." "Warning"
        }
    }

    Write-Log "Starting ADB server..." "Action"
    Execute-ADBCommand "start-server"

    return $isReady
}

function Generate-UnlockCode {
    Write-Header "Generate-Get Unlock Code"

    if (IsAdbMode) {
        $rawSerial = Execute-ADBCommand "shell cat /sys/devices/soc0/serial_number" -get $true
        $serialNumber = ($rawSerial -join '').Trim()
        if ($serialNumber -match "^\d+$") {
            # Create backup directory if it doesn't exist
            if (-not (Test-Path $BackupPath)) {
                New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
            }

            $serialNumber | Set-Content -Path $DeviceSerial -Encoding Ascii
            Write-Log "Saved: ${cCyan}$DeviceSerial${cReset}" "Success"
            Write-Log "Serial number: ${cCyan}$serialNumber${cReset}" "Success"
            $null = Invoke-PicoHaxxScript
        } else {
            Write-Log "Failed to get a valid serial number from the device. Is it connected and authorized?" "Warning"
        }
    } elseif (Test-Path $DeviceSerial) {
        Write-Log "Using existing serial number from ${cCyan}'$DeviceSerial'${cReset}." "Info"
        $null = Invoke-PicoHaxxScript
    } else {
        Warning-ADB
    }
}

# ----------------------------
# ---------- ABL -------------
# ----------------------------

function Flash-EngineeringABL {
    Write-Header "Flash Engineering ABL"
    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to flash engineering files." "Warning"
    Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"

    $success = $true
    $lastError = $null

    try {
        $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
        if ($confirmation -ne 'yes') {
            throw "Aborted by user. No changes have been made."
        }

        # Create backup directory if it doesn't exist
        if (-not (Test-Path $AblBackupPath)) {
            New-Item -Path $AblBackupPath -ItemType Directory -Force | Out-Null
        }

        # Reboot EDL
        if (IsAdbMode) {
            ADB-To-Edl
        } elseif (IsFastbootMode) {
            Fastboot-To-Edl
        } elseif (-not (IsEdlMode)) {
            Warning-EDL
        }
        
        if (-not (Wait-EdlMode)) {
            throw ""
        }
        
        # Create a timestamped backup folder
        $currentBackupPath = Join-Path $AblBackupPath $TimeStamp
        New-Item -Path $currentBackupPath -ItemType Directory -Force | Out-Null
        $backupAbl = Join-Path $currentBackupPath "abl.bin"
        $backupDevInfo = Join-Path $currentBackupPath "devinfo.bin"
        
        # Backup ABL
        Write-Log "Backing up original ABL to '${cCyan}${backupAbl}${cReset}'..." "Action"
        if (-not (Execute-EdlCommand "read-part abl $backupAbl") -or !(Test-Path $backupAbl) -or (Get-Item $backupAbl).Length -eq 0) { 
            throw "Backing up ABL failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }

        # Backup Devinfo
        Write-Log ""
        Write-Log "Backing up original Devinfo to '${cCyan}${backupDevInfo}${cReset}'..." "Action"
        if (-not (Execute-EdlCommand "read-part devinfo $backupDevInfo") -or !(Test-Path $backupDevInfo) -or (Get-Item $backupDevInfo).Length -eq 0) {
            throw "Backing up Devinfo failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }

        # Flash custom ABL
        Write-Log ""
        Write-Log "Flashing engineering ABL..." "Action"
        if (-not (Execute-EdlCommand "write-part abl $AblPath")) { 
            throw "Flashing engineering ABL failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }

        # Flash custom Devinfo
        Write-Log ""
        Write-Log "Flashing engineering Devinfo..." "Action"
        if (-not (Execute-EdlCommand "write-part devinfo $DevInfoPath")) { 
            throw "Flashing engineering Devinfo failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Original ABL backed up to '${cGreen}$currentBackupPath${cReset}'." "Success"
            Write-Log "Engineering ${cCyan}ABL${cReset} and ${cCyan}Devinfo${cReset} flashed successfully." "Success"
            Write-Log ""
            Write-Log "Engineering ABL might reboot the device to EDL mode (Black screen) sometimes and perform a slower boot time." "Warning"
            Write-Log "If it boots into EDL mode, manually boot to ${cCyan}SYSTEM${cReset} by keep holding ${cYellow}Power Button${cReset} until Pico logo shows up." "Warning"
            Write-Log ""
            Write-Log "The next step is perform ${cCyan}Unlock Bootloader${cReset}." "Info"
            
            $choice = Read-HostLog "Would you like to skip and reboot to system? [y/${cYellow}N${cReset}]"
            if ($choice -eq 'y') {
                Edl-To-System
            }
        } else {
            if ($lastError.Message -notlike "*Abort*") {
                Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
            }
            Warning-EDL-ManualReboot
        }
    }
}

function Flash-BackupABL {
    $success = $true
    $lastError = $null
    $header = {
        Write-Header "Flash Backup ABL"
        Write-Log "This fix resolves issues like slow reboots and unwanted booting into ${cCyan}EDL${cReset} mode." "Info"
        Write-Log "SELinux will return to ${cYellow}Enforcing${cReset} mode, using ${cCyan}https://github.com/evdenis/selinux_permissive${cReset} to change back to Permissive mode." "Info"
        Write-Log "Fastboot will no longer work for device modification." "Warning"
        Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"
    }

    try {
        if (-not (Test-Path -Path $AblBackupPath -PathType Container)) {
            throw "Aborted. The specified backup directory '${cYellow}$AblBackupPath${cReset}' does not exist."
        }

        $folders = Get-ChildItem -Path $AblBackupPath -Directory |
        Where-Object { $_.Name -match '^\d+$|^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$' } |
        Sort-Object -Property LastWriteTime -Descending
        if (-not $folders) {
            throw "Aborted. No valid backup folders found in '${cYellow}$AblBackupPath${cReset}'."
        }

        # Get backupFolder
        $backupFolder = $null
        while (-not $backupFolder) {
            & $header

            Write-Log ""
            Write-Log "Available backup folders:" "Info"
            for ($i = 0; $i -lt $folders.Count; $i++) {
                Write-Log "[${cCyan}$($i + 1)${cReset}] $($folders[$i].Name) ${cGreen}($($folders[$i].CreationTime))${cReset}"
            }
            $selection = Read-HostLog "Select backup [${cYellow}1-$($folders.Count)${cReset}], cancel [${cYellow}C${cReset}]"

            if ($selection -eq 'c') {
                throw "Aborted by user. No changes have been made."
            }

            if ($selection -match '^\d+$') {
                $index = [int]$selection - 1
                if ($index -ge 0 -and $index -lt $folders.Count) {
                    $backupFolder = $folders[$index].FullName
                }
            }

            if (-not $backupFolder) {
                Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
                Wait-Continue
            }
        }

        # Test partition files
        $backupAbl = Join-Path $backupFolder "abl.bin"
        $backupDevInfo = Join-Path $backupFolder "devinfo.bin"
        if (-not (Test-Path $backupAbl) -or (Get-Item $backupAbl).Length -eq 0) {
            throw "Aborted. Backup ABL file '${cYellow}$backupAbl${cReset}' does not exist or is empty."
        } elseif (-not (Test-Path $backupDevInfo) -or (Get-Item $backupDevInfo).Length -eq 0) {
            throw "Aborted .Backup Devinfo file '${cYellow}$backupDevInfo${cReset}' does not exist or is empty."
        }
        
        # User confirm
        Write-Log "Target backup folder: ${cGreen}$backupFolder${cReset}" "Info"
        $confirmation = Read-HostLog "Are you sure you want to flash this backup? [${cYellow}Y${cReset}/n]"
        if ($confirmation -ne 'y') {
            throw "Aborted by user. No changes have been made."
        }

        # Reboot to EDl
        if (IsAdbMode) {
            ADB-To-Edl
        } elseif (IsFastbootMode) {
            Fastboot-To-Edl
        } elseif (-not (IsEdlMode)) {
            Warning-EDL
        }

        if (-not (Wait-EdlMode)) {
            throw "Device failed to enter EDL mode."
        }

        # Flash backup ABL
        Write-Log "Backing up backup ABL from '${cCyan}${backupAbl}${cReset}'..." "Action"
        if (-not (Execute-EdlCommand "write-part abl `"$backupAbl`"")) { 
            throw "Flashing backup ABL failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }

        # Flash backup Devinfo
        Write-Log ""
        Write-Log "Backing up backup Devinfo from '${cCyan}${backupDevInfo}${cReset}'..." "Action"
        if (-not (Execute-EdlCommand "write-part devinfo `"$backupDevInfo`"")) { 
            throw "Flashing backup Devinfo failed with code ${cCyan}${LASTEXITCODE}${cReset}."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Original ABL restored successfully." "Success"
            Write-Log ""
            Write-Log "The next step is perform ${cCyan}Root${cReset}." "Info"
            Write-Log "Device will boot to system normally." "Info"
            Wait-Continue

            Edl-To-System
        } else {
            if ($lastError.Message -notlike "*Abort*") {
                Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
            }
            Warning-EDL-ManualReboot
        }
    }
}

# ----------------------------
# ------- Bootloader ---------
# ----------------------------

function Perform-FastbootUnlock {
    Write-Header "Unlock Bootloader"

    $success = $true
    $requireReset = $false

    try {
        if ($IsRetryBootloader -eq 0) {
            Write-Log "This step will reboot your device into ${cCyan}FASTBOOT${cReset} mode to unlock bootloader." "Warning"
            Write-Log "If bootloader is in ${cRed}Locked${cReset} state, this process will factory reset device data." "Warning"
            Write-Log "Recommended to backup ${cCyan}User Personal Data${cReset} from the ${cCyan}Backup/Restore${cReset} menu." "Warning"

            $confirmation = Read-HostLog "To proceed with rebooting to FASTBOOT, type [${cYellow}YES${cReset}] and press Enter"
            if ($confirmation -ne 'yes') {
                throw "Aborted by user. No changes have been made."
            }
        }

        if (IsAdbMode) {
            ADB-To-Fastboot
        } elseif (-not (IsFastbootMode)) {
            Warning-FASTBOOT
        }

        if (-not (Wait-FastbootMode)) {
            throw ""
        }

        # Check current state
        if ($IsRetryBootloader -ne 2) {
            if (-not (IsFastbootUnlocked)) {
                $requireReset = $true
                Write-Log ""
                Write-Log "Bootloader status: ${cGreen}LOCKED${cReset}" "Warning"
                Write-Log "Your device will asked to perform factory reset after reboot." "Warning"
                Wait-Continue
            }
        }

        if (-not (Execute-UnlockCommand)) {
            throw ""
        }

        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot flashing unlock_critical${cReset}" "Action"
        Execute-FastbootCommand "flashing unlock_critical"
        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot flashing unlock${cReset}" "Action"
        Execute-FastbootCommand "flashing unlock"
        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot oem setenforce 0${cReset}" "Action"
        Execute-FastbootCommand "oem setenforce 0"

        if (-not (IsFastbootUnlocked)) {
            throw "Device does not report as fully unlocked. You may need to repeat the process."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log ""
            Write-Log "Bootloader status confirmed: ${cGreen}UNLOCKED${cReset}" "Success"
            Write-Log "Unplug the device and plug it back in." "Interactive"

            if ($IsRetryBootloader -ne 2) {
                $null = Wait-FastbootMode -WaitForDisconnect
                $null = Wait-FastbootMode
            }

            if (Verify-FastbootState "unlock") {
                Wait-Continue
                Show-FastbootFinalInstruction $requireReset
            }
        }
    }
}

function Perform-FastbootLock {
    Write-Header "Lock Bootloader"
    
    $success = $true
    $requireReset = $false

    try {
        if ($IsRetryBootloader -eq 0) {
            Write-Log "This step will reboot your device into ${cCyan}FASTBOOT${cReset} mode to lock bootloader." "Warning"
            Write-Log "If bootloader is in ${cGreen}Unlocked${cReset} state, this process will factory reset device data." "Warning"
            Write-Log "Recommended to backup ${cCyan}User Personal Data${cReset} from the ${cCyan}Backup/Restore${cReset} menu." "Warning"

            $confirmation = Read-HostLog "To proceed with rebooting to FASTBOOT, type [${cYellow}YES${cReset}] and press Enter"
            if ($confirmation -ne 'yes') {
                throw "Aborted by user. No changes have been made."
            }
        }

        if (IsAdbMode) {
            ADB-To-Fastboot
        } elseif (-not (IsFastbootMode)) {
            Warning-FASTBOOT
        }

        if (-not (Wait-FastbootMode)) {
            throw ""
        }

        # Check current state
        if ($IsRetryBootloader -ne 2) {
            if (IsFastbootUnlocked) {
                $requireReset = $true
                Write-Log ""
                Write-Log "Bootloader status: ${cGreen}UNLOCKED${cReset}" "Warning"
                Write-Log "Your device will asked to perform factory reset after reboot.." "Warning"
                Wait-Continue
            }
        }

        if (-not (Execute-UnlockCommand)) {
            throw ""
        }

        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot oem setenforce 1${cReset}" "Action"
        Execute-FastbootCommand "oem setenforce 1"
        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot flashing lock${cReset}" "Action"
        Execute-FastbootCommand "flashing lock"
        Write-Log ""
        Write-Log "Executing commands: ${cCyan}fastboot flashing lock_critical${cReset}" "Action"
        Execute-FastbootCommand "flashing lock_critical"

        if (IsFastbootUnlocked) {
            throw "Device does not report as fully locked. You may need to repeat the process."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log ""
            Write-Log "Bootloader status confirmed: ${cGreen}LOCKED${cReset}" "Success"
            Write-Log "Unplug the device and plug it back in." "Interactive"

            if ($IsRetryBootloader -ne 2) {
                $null = Wait-FastbootMode -WaitForDisconnect
                $null = Wait-FastbootMode
            }

            if (Verify-FastbootState "lock") {
                Wait-Continue
                Show-FastbootFinalInstruction $requireReset
            }
        }
    }
}

function Show-FastbootFinalInstruction([bool]$requireReset) {
    $button = switch (IsPicoNeo3) {
        $true { "${cYellow}Vol Up${cReset} + ${cYellow}Power${cReset} + ${cYellow}Home${cReset}" }
        Default { "${cYellow}Vol Up${cReset} + ${cYellow}Power${cReset}" }
    }

    Write-Header "Bootloader Finalizing"
    Write-Log "Check your device screen to confirm the current bootloader state." "Info"
    if ($requireReset) {
        Write-Log ""
        Write-Log "After rebooting, in the headset you will be asked to perform a ${cCyan}Factory Reset${cReset}." "Info"
        Write-Log "In the headset menu, Press ${cYellow}Vol Down${cReset} then ${cYellow}Power${cReset} to select ${cCyan}Factory data reset${cReset}." "Info"
        Write-Log "After the factory reset, your device will boot normally." "Info"
    }
    Write-Log ""
    Write-Log "If the device does not boot to system normally, a ${cCyan}Factory Reset${cReset} might be required." "Warning"
    Write-Log "Option 1: Use provided ${cCyan}Factory Reset${cReset} menu." "Info"
    Write-Log "Option 2: Manually reset by holding $button until the robot shows up with ${cCyan}No command${cReset} as recovery mode." "Info"
    Write-Log "   - In recovery mode, hold ${cYellow}Power${cReset} first then press ${cYellow}Vol Up${cReset} to access the menu." "Info"
    Write-Log "   - Use ${cYellow}Vol Up${cReset} and ${cYellow}Vol Down${cReset} to navigate, and press ${cYellow}Power${cReset} to select ${cCyan}Wipe data/factory reset${cReset}." "Info"
    Write-Log ""
    Write-Log "The next step is perform ${cCyan}Flash Backup ABL${cReset}." "Info"

    $choice = Read-HostLog "Would you like to skip and reboot to system? [y/${cYellow}N${cReset}]"
    if ($choice -eq 'y') {
        Fastboot-To-System
    } else {
        if (IsPicoNeo3) {
            Neo-Fastboot-To-Edl
        }
    }
}

function Test-Bootloader {
    Write-Header "Test Bootloader"

    if (IsFastbootUnlocked) {
        Write-Log ""
        Write-Log "Device bootloader: ${cGreen}Unlocked${cReset}" "Info"
    } else {
        Write-Log ""
        Write-Log "Device bootloader: ${cRed}Locked${cReset}" "Info"
    }
}

function Verify-FastbootState([string]$state) {
    # Normalize state check
    $isCheckUnlock = $state -match "^unlock"
    $actionName = if ($isCheckUnlock) { "Verify Unlock" } else { "Verify Lock" }

    Write-Header $actionName

    $result = $null

    try {
        if (IsFastbootMode) {
            Fastboot-To-Fastboot
        } elseif (IsAdbMode) {
            ADB-To-Fastboot
        } else {
            Warning-FASTBOOT
        }
        Start-Sleep -Seconds 1

        if (-not (Wait-FastbootMode)) {
            throw ""
        }

        $isUnlocked = IsFastbootUnlocked

        if ($null -eq $isUnlocked) {
            $statusText = if ($isCheckUnlock) { "${cGreen}'UNLOCKED'${cReset}" } else { "${cYellow}'LOCKED'${cReset}" }
            Write-Log "Unable to automatically detect bootloader state via fastboot." "Warning"
            Write-Log "Please check your device screen. The bootloader menu should now show $statusText." "Warning"
            throw ""
        }

        # Determine if actual device state matches desired state
        $desiredState = if ($isCheckUnlock) { $true } else { $false }
        $isSuccess = ($isUnlocked -eq $desiredState)
        $statusText = if ($isUnlocked) { "UNLOCKED" } else { "LOCKED" }

        if ($isSuccess) {
            Write-Log ""
            Write-Log "Bootloader status confirmed: ${cGreen}$statusText${cReset}" "Success"
            $result = $true
        } else {
            Write-Log ""
            Write-Log "Bootloader is still ${cRed}$statusText${cReset}." "Error"
            Write-Log "It is known that the unlock bits (written to protected RPMB storage) might not 'stick' immediately." "Info"
            Write-Log "Try a different USB port and cable, unplug the headset and plug it back in." "Info"
            Write-Log "You may need to repeat the process alot." "Info"
            Write-Log "Keep trying and don't lose hope." "Info"

            if ($IsRetryBootloader -ne 2) {
                Write-Log ""
                Write-Log "Do you want to retry now?" "Interactive"

                $confirmation = Read-HostLog "Manual retry [${cYellow}YES${cReset}], keep it running [${cYellow}AUTO${cReset}]"
                if ($confirmation -eq 'yes') {
                    $script:IsRetryBootloader = 1
                } elseif ($confirmation -eq 'auto') {
                    $script:IsRetryBootloader = 2
                }
            }

            if ($IsRetryBootloader -ne 0) {
                if ($isCheckUnlock) {
                    Perform-FastbootUnlock
                } else {
                    Perform-FastbootLock
                }
                throw ""
            }

            $result = $false
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $result
}

function IsFastbootUnlocked {
    $result = $null

    try {
        if (-not (IsFastbootMode)) {
            if (IsAdbMode) {
                ADB-To-Fastboot
            } elseif (IsEdlMode) { 
                Edl-To-Fastboot
            } elseif (-not (IsFastbootMode)) {
                Warning-FASTBOOT
            }
        
            if (-not (Wait-FastbootMode)) {
                throw ""
            }
        }
    
        # Primary Check: fastboot oem device-info
        Write-Log "Checking bootloader status using ${cCyan}fastboot oem device-info${cReset}..." "Action"
        $deviceInfoRaw = Execute-FastbootCommand "oem device-info" -get $true
        $deviceInfo = $deviceInfoRaw -join "`n"
        Write-Log $deviceInfo

        if ($deviceInfo -match "Device\s*Unlocked\s*[:=]\s*true") {
            $result = $true
            throw ""
        } elseif ($deviceInfo -match "Device\s*Unlocked\s*[:=]\s*false") {
            $result = $false
            throw ""
        }

        # Fallback Check: fastboot getvar unlocked
        Write-Log "OEM command unrecognized/unparseable." "Warning"
        Write-Log "Checking with ${cCyan}fastboot getvar unlocked${cReset}..." "Action"
        $unlockedVarRaw = Execute-FastbootCommand "getvar unlocked" -get $true
        $unlockedVar = $unlockedVarRaw -join "`n"
        Write-Log $unlockedVar

        if ($unlockedVar -match "unlocked:\s*yes") {
            $result = $true
        } elseif ($unlockedVar -match "unlocked:\s*no") {
            $result = $false
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
    
    return $result
}

function Perform-FactoryReset {
    Write-Header "Factory Reset"
    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to wipe user data partition." "Warning"
    Write-Log "Factory reset may be required to prevent non-bootable states or bootloops from data mismatch." "Warning"
    Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"

    $success = $true
    $lastError = $null

    try {
        $confirmation = Read-HostLog "To proceed with factory reset, type [${cYellow}YES${cReset}] and press Enter"
        if ($confirmation -ne 'yes') {
            throw "Aborted by user. No changes have been made."
        }

        # Reboot to EDL mode
        if (IsAdbMode) {
            ADB-To-Edl
        } elseif (IsFastbootMode) {
            Fastboot-To-Edl
        } elseif (-not (IsEdlMode)) {
            Warning-EDL
        }

        if (-not (Wait-EdlMode)) {
            throw ""
        }

        Write-Log "Erasing userdata partition..." "Action"
        if (-not (Execute-EdlCommand "erase-part userdata")) {
            throw "Failed to erase 'userdata' partition."
        }

        Write-Log "Erasing metadata partition..." "Action"
        if (-not (Execute-EdlCommand "erase-part metadata")) {
            throw "Failed to erase 'metadata' partition."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Factory reset completed successfully." "Success"
        } elseif ($lastError.Message -notlike "*Abort*") {
            Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        }
    }

    return $success
}

function SystemUpdate-Management([string]$selection = "") {
    Write-Header "System Update Management"

    # Ensure device is in ADB mode
    if (IsFastbootMode) {
        Fastboot-To-System
    } elseif (IsEdlMode) {
        Edl-To-System
    } elseif (-not (IsAdbMode)) {
        Warning-ADB
    }

    if (-not (Wait-AdbMode)) {
        throw "ADB device connection timed out."
    }
    try {
        while ($selection -eq "") {
            Write-Header "System Update Management"
            Write-Log "[${cCyan}1${cReset}] Disable Auto System Update"
            Write-Log "[${cCyan}2${cReset}] Enable Auto System Update"
            $selection = Read-HostLog "Select an option"
        }

        switch ($selection) {
            "1" { 
                Write-Log "Disabling system update..." "Action"

                Execute-ADBCommand "shell setprop persist.accept.systemupdates.ota 0"
                Execute-ADBCommand "shell setprop persist.accept.systemupdates.app 0"
                Execute-ADBCommand "shell setprop persist.accept.systemupdates 0"
                Execute-ADBCommand "shell setprop pvr.update.app 0"

                Execute-ADBCommand "shell settings put global pvr_update 0"
                Execute-ADBCommand "shell settings put global pvr_update_silent 0"
                Execute-ADBCommand "shell settings put global pvr_update_auto_upgrade 0"
                Execute-ADBCommand "shell settings put global pvr_update_auto_update 0"

                $out = Execute-ADBCommand "shell pm disable-user --user 0 com.pvr.version" -get $true
                if ($out -and ($out -match "Error" -or $out -match "Exception")) { throw "pm disable-user failed: $out" }

                $out = Execute-ADBCommand "shell pm uninstall --user 0 com.picovr.updatesystem" -get $true
                if ($out -and ($out -match "Failure" -and $out -notmatch "not installed")) { throw "pm uninstall updatesystem failed: $out" }

                $out = Execute-ADBCommand "shell pm uninstall --user 0 com.picovr.firmwareupdate" -get $true
                if ($out -and ($out -match "Failure" -and $out -notmatch "not installed")) { throw "pm uninstall firmwareupdate failed: $out" }

                $out = Execute-ADBCommand "shell pm uninstall --user 0 com.android.dynsystem" -get $true
                if ($out -and ($out -match "Failure" -and $out -notmatch "not installed")) { throw "pm uninstall dynsystem failed: $out" }

                Execute-ADBCommand "shell update_engine_client --suspend"
                Execute-ADBCommand "shell update_engine_client --cancel"
                Execute-ADBCommand "shell update_engine_client --reset_status"
                Execute-ADBCommand "shell update_engine_client --switch_slot=false"

                Write-Log "System update disabled. " "Success"
            }
            "2" { 
                Write-Log "Enabling system update..." "Action"

                Execute-ADBCommand "shell setprop persist.accept.systemupdates.ota 1"
                Execute-ADBCommand "shell setprop persist.accept.systemupdates.app 1"
                Execute-ADBCommand "shell setprop persist.accept.systemupdates 1"
                Execute-ADBCommand "shell setprop pvr.update.app 1"

                Execute-ADBCommand "shell settings put global pvr_update 1"
                Execute-ADBCommand "shell settings put global pvr_update_silent 1"
                Execute-ADBCommand "shell settings put global pvr_update_auto_upgrade 1"
                Execute-ADBCommand "shell settings put global pvr_update_auto_update 1"

                $out = Execute-ADBCommand "shell pm enable com.pvr.version" -get $true
                if ($out -and ($out -match "Error" -or $out -match "Exception")) { throw "pm enable failed: $out" }

                $out = Execute-ADBCommand "shell cmd package install-existing com.picovr.updatesystem" -get $true
                if ($out -and ($out -match "Failure" -or $out -match "Error")) { throw "install-existing updatesystem failed: $out" }

                $out = Execute-ADBCommand "shell cmd package install-existing com.picovr.firmwareupdate" -get $true
                if ($out -and ($out -match "Failure" -or $out -match "Error")) { throw "install-existing firmwareupdate failed: $out" }

                $out = Execute-ADBCommand "shell cmd package install-existing com.android.dynsystem" -get $true
                if ($out -and ($out -match "Failure" -or $out -match "Error")) { throw "install-existing dynsystem failed: $out" }

                Execute-ADBCommand "shell update_engine_client --reset_status"

                Write-Log "System update enabled. " "Success"
            }
            Default {
                Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
            }
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

# --------------------------------
# ---- Main Script Execution -----
# --------------------------------

if (-not (Test-Path $LogsPath)) {
    New-Item -Path $LogsPath -ItemType Directory -Force | Out-Null
}
$LogFile = "$LogsPath\${TimeStamp}_console.log"
Start-Transcript -Path $LogFile -Append

$host.UI.RawUI.WindowTitle = "more-picohaxx-tool"
[System.Console]::Title = "more-picohaxx-tool"

try {
    if (Check-Prerequisites) {
        Clear-Host
    } else {
        Write-Log "Some prerequisites are missing. Functions may not work correctly." "Warning"
        Wait-Continue
    }

    $quit = $false
    while (-not $quit) {
        try {
            Write-Header $VersionStr

            Write-Log "[${cCyan}1${cReset}] Generate-Get Unlock Code"
            Write-Log "[${cCyan}2${cReset}] Flash Engineering ABL"
            Write-Log "[${cCyan}3${cReset}] Unlock Bootloader"
            Write-Log "[${cCyan}4${cReset}] Flash Backup ABL"
            Write-Log "[${cCyan}5${cReset}] Root / Flash Image"
            Write-Log ""
            Write-Log "[${cCyan}b${cReset}] Backup / Restore / Downgrade"
            Write-Log "[${cCyan}t${cReset}] Test Bootloader"
            Write-Log "[${cCyan}l${cReset}] Lock Bootloader"
            Write-Log "[${cCyan}r${cReset}] Reboot"
            Write-Log "[${cCyan}update${cReset}] System Update Management"
            Write-Log "[${cCyan}reset${cReset}] Factory Reset"
            Write-Log "[${cCyan}0${cReset}] Exit"
            Write-Log ""
            Write-Log "Site: ${cYellow}https://github.com/chaixshot/more-picohaxx-tool${cReset}"

            $selection = Read-HostLog "Select an option"
            switch ($selection) {
                "1" {
                    Generate-UnlockCode
                }
                "2" {
                    Select-Firehose
                    Flash-EngineeringABL
                }
                "3" {
                    Perform-FastbootUnlock
                }
                "4" {
                    Select-Firehose
                    Flash-BackupABL
                }
                "5" {
                    Show-RootMenu
                }
                "b" {
                    Show-BackupRestoreMenu
                }
                "t" {
                    Test-Bootloader
                }
                "l" {
                    Perform-FastbootLock
                }
                "r" {
                    Perform-Reboot
                }
                "update" {
                    SystemUpdate-Management
                }
                "reset" {
                    Select-Firehose
                    if (Perform-FactoryReset) {
                        Edl-To-System
                    } else {
                        Warning-EDL-ManualReboot
                    }
                }
                "0" {
                    $quit = $true
                }
                default {
                    Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
                }
            }
        } catch {
            $errInfo = $_.InvocationInfo
            Write-Log ""
            Write-Log "File: ${cCyan}$($errInfo.ScriptName)${cReset}" "Error"
            Write-Log "Line: ${cCyan}$($errInfo.ScriptLineNumber)${cReset}" "Error"
            Write-Log $_ "Error"
        }

        if (-not $quit) {
            Wait-Continue "return '${cCyan}Pico Unlock${cReset}'..."
        }
    }
} finally {
    Write-Header "Exited"
    Write-Log $VersionStr "Info"
    Write-Log ""

    try {
        Stop-Transcript
        Execute-ADBCommand "kill-server"
    } catch {

    }

    Clean-LogFormat -LogFile $LogFile
}
