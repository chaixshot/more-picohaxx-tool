#Requires -Version 5.1

<#
.SYNOPSIS
    Root functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for installing Magisk, patching the boot image,
    and flashing the patched image to achieve superuser access.
#>

# --- Root Functions ---

$Magisk = Join-Path $WorkingDir "tools\magisk\Magisk4Pico.apk"
$MagiskBoot = Join-Path $WorkingDir "tools\magisk\magiskboot.exe"
$MagiskTMP = Join-Path $WorkingDir "tools\magisk\tmp"
$BootBackupPath = "${BackupPath}\boot"

function Perform-MagiskBoot([string]$bootImgPath) {
    # Verification Check
    foreach ($file in @($Magisk, $bootImgPath, $MagiskBoot)) {
        if (-not (Test-Path $file)) {
            Write-Log "Required file missing: ${cCyan}${file}${cReset}" "Error"
            return
        }
    }

    # Set output image path inside the same directory as the source boot image
    $bootImgDir = Split-Path -Path $bootImgPath -Parent
    $outputImgPath = Join-Path $bootImgDir "magisk_patched.img"

    # Ensure temporary directory exists
    if (-not (Test-Path $MagiskTMP)) {
        New-Item -ItemType Directory -Path $MagiskTMP -Force | Out-Null
    }

    if (Test-Path $outputImgPath) {
        Remove-Item -Path $outputImgPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Push-Location $MagiskTMP
    try {
        # Extract Required Assets from APK directly into $MagiskTMP
        Write-Log ""
        Write-Log "Extracting binaries from Magisk APK..." "Action"
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zip = [System.IO.Compression.ZipFile]::OpenRead($Magisk)
        try {
            $apkEntries = @{
                "lib/arm64-v8a/libmagiskinit.so" = "magiskinit"
                "lib/arm64-v8a/libmagisk.so"     = "magisk"
                "lib/arm64-v8a/libinit-ld.so"    = "init-ld"
                "assets/stub.apk"                = "stub.apk"
            }
            foreach ($entryKey in $apkEntries.Keys) {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryKey }
                if ($entry) {
                    $targetName = $apkEntries[$entryKey]
                    $destination = Join-Path $MagiskTMP $targetName
                    Write-Log "Extracting ${cCyan}${targetName}${cReset}..." "Action"
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
                }
            }
        } finally {
            $zip.Dispose()
        }

        # Compress payloads into XZ format (Standard modern Magisk payload)
        Write-Log "Compressing Magisk payloads with XZ..." "Action"
        & $MagiskBoot compress=xz magisk magisk.xz 2>&1 | Write-Host
        if (Test-Path "stub.apk") {
            & $MagiskBoot compress=xz stub.apk stub.xz 2>&1 | Write-Host
        }
        if (Test-Path "init-ld") {
            & $MagiskBoot compress=xz init-ld init-ld.xz 2>&1 | Write-Host
        }

        # Unpack boot.img
        Write-Log ""
        Write-Log "Unpacking $bootImgPath using magiskboot..." "Action"
        & $MagiskBoot unpack $bootImgPath 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "magiskboot unpack failed with exit code ${LASTEXITCODE}."
        }
        if (-not (Test-Path "ramdisk.cpio")) {
            throw "Failed to unpack boot image or ramdisk.cpio not found."
        }

        # Backup original ramdisk for magiskinit chainload backup
        Copy-Item -Path "ramdisk.cpio" -Destination "ramdisk.cpio.orig" -Force

        # Determine pre-init storage device
        $preinit = $null
        try {
            $adbDevices = & $ADB devices
            if ($adbDevices -match "\t(device|recovery)") {
                & $ADB push (Join-Path $MagiskTMP "magisk") /data/local/tmp/magisk 2>&1 | Out-Null
                $detectedPreinit = (& $ADB shell "chmod 755 /data/local/tmp/magisk; /data/local/tmp/magisk --preinit-device").Trim()
                if ($detectedPreinit) {
                    $preinit = $detectedPreinit
                    Write-Log "Detected pre-init storage partition: ${cGreen}$preinit${cReset}" "Info"
                }
                & $ADB shell "rm -f /data/local/tmp/magisk" 2>&1 | Out-Null
            }
        } catch {
        }
        
        if (-not $preinit) {
            $preinit = "cache"
        }

        # Magisk SHA1 Checksum
        $sha1 = (& $MagiskBoot sha1 $bootImgPath).Trim()

        # Create Magisk config file
        $cfg = @"
KEEPVERITY=false
KEEPFORCEENCRYPT=false
RECOVERYMODE=false
VENDORBOOT=false
PREINITDEVICE=$preinit
SHA1=$sha1
"@
        [System.IO.File]::WriteAllText((Join-Path $MagiskTMP "config"), $cfg.Replace("`r`n", "`n"))

        # Configure environment flags for magiskboot patch
        $env:KEEPVERITY = "false"
        $env:KEEPFORCEENCRYPT = "false"
        $env:PATCHVBMETAFLAG = "false"

        # Patch Ramdisk (Modern Magisk CPIO Injection)
        Write-Log ""
        Write-Log "Injecting modern Magisk payload into ramdisk.cpio..." "Action"

        $cpioCommands = @(
            "add 0750 init magiskinit",
            "mkdir 0750 overlay.d",
            "mkdir 0750 overlay.d/sbin",
            "add 0644 overlay.d/sbin/magisk.xz magisk.xz"
        )
        if (Test-Path "stub.xz") {
            $cpioCommands += "add 0644 overlay.d/sbin/stub.xz stub.xz"
        }
        if (Test-Path "init-ld.xz") {
            $cpioCommands += "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz"
        }

        $cpioCommands += "patch"
        $cpioCommands += "backup ramdisk.cpio.orig"
        $cpioCommands += "mkdir 000 .backup"
        $cpioCommands += "add 000 .backup/.magisk config"

        & $MagiskBoot cpio ramdisk.cpio $cpioCommands 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "magiskboot cpio patch failed with exit code ${LASTEXITCODE}." }

        # Patch DTB / fstab if present (removes AVB verification flags on Qualcomm)
        foreach ($dt in @("dtb", "kernel_dtb", "extra")) {
            if (Test-Path $dt) {
                Write-Log ""
                Write-Log "Patching $dt fstab..." "Action"
                & $MagiskBoot dtb $dt patch 2>&1 | Write-Host
            }
        }

        # Keep original raw kernel to prevent bootloop or compression mismatches
        if (Test-Path "kernel") {
            Remove-Item "kernel" -Force
        }

        # Repack Image directly to destination path
        Write-Log ""
        Write-Log "Repacking image into $outputImgPath..." "Action"
        & $MagiskBoot repack $bootImgPath $outputImgPath 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "magiskboot repack failed with exit code ${LASTEXITCODE}."
        }
    } catch {
        Write-Log ""
        Write-Log "$($_.Exception.Message)" "Error"
    } finally {
        # Safely restore original working directory
        Pop-Location

        # Cleanup Temporary Artifacts inside $MagiskTMP
        Write-Log ""
        if (Test-Path -Path $MagiskTMP) {
            Write-Log "Deleting '${cCyan}$( $MagiskTMP )${cReset}' folder..." "Action"
            Remove-Item -Path $MagiskTMP -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Verification
    if (Test-Path $outputImgPath) {
        Write-Log "Boot image patched to '${cCyan}$( $outputImgPath )${cReset}' successfully." "Success"
    } else {
        Write-Log "Repack failed. Output image was not created." "Error"
    }
}

function IsDeviceRooted {
    # Primary Check: check root uid via su -c id
    Write-Log "Checking Superuser access using ${cCyan}adb shell su -c id${cReset}..." "Action"
    $suOutputRaw = & $ADB shell "su -c id" 2>&1
    $suOutput = ($suOutputRaw -join "`n").Trim()
    Write-Log $suOutput

    if ($suOutput -match "uid=0(\(root\))?") {
        # Check and display Magisk version if available
        $magiskVer = (& $ADB shell "su -c magisk -v" 2>&1) -join ""
        if ($magiskVer -match "(:MAGISK|\d+\.\d+)") {
            Write-Log "Magisk version detected: ${cGreen}$magiskVer${cReset}" "Info"
        }
        return $true
    }

    # Fallback Check: su 0 id
    Write-Log "Checking fallback with ${cCyan}adb shell su 0 id${cReset}..." "Action"
    $altSuRaw = & $ADB shell "su 0 id" 2>&1
    $altSu = ($altSuRaw -join "`n").Trim()
    Write-Log $altSu

    if ($altSu -match "uid=0(\(root\))?") {
        return $true
    }

    # Fallback Check: adb root (if adbd runs as root)
    $idRaw = & $ADB shell "id" 2>&1
    $idOutput = ($idRaw -join "`n").Trim()
    if ($idOutput -match "uid=0(\(root\))?") {
        return $true
    }

    if ($suOutput -match "Permission denied") {
        Write-Log "Superuser prompt may have been denied or timed out on screen." "Warning"
        return $false
    }

    return $false
}

function Verify-RootState([string]$state = "root") {
    # Normalize state check
    $isCheckRoot = (-not $state) -or ($state -match "^root")
    $actionName = if ($isCheckRoot) { "Verify Root Access" } else { "Verify Unroot State" }

    Write-Header $actionName

    # Ensure device is in ADB mode
    if (IsFastbootMode) {
        Fastboot-To-System
    } elseif (IsEdlMode) {
        Edl-To-System
    } elseif (-not (IsAdbMode)) {
        Warning-ADB
    }

    if (-not (Wait-AdbMode 500)) {
        return
    }

    $isRooted = IsDeviceRooted

    if ($null -eq $isRooted) {
        $statusText = if ($isCheckRoot) { "${cGreen}'ROOTED'${cReset}" } else { "${cYellow}'UNROOTED'${cReset}" }
        Write-Log "Unable to automatically detect superuser state via ADB." "Warning"
        Write-Log "Please check your device screen for any Superuser authorization prompt." "Warning"
        Wait-Continue
        
        return
    }

    # Determine if actual device state matches desired state
    $desiredState = if ($isCheckRoot) { $true } else { $false }
    $isSuccess = ($isRooted -eq $desiredState)
    $statusText = if ($isRooted) { "ROOTED" } else { "NOT ROOTED" }

    if ($isSuccess) {
        Write-Log ""
        Write-Log "Root status confirmed: ${cGreen}$statusText${cReset}" "Success"
    } else {
        Write-Log ""
        Write-Log "Device root state: ${cRed}$statusText${cReset}." "Error"
        if ($isCheckRoot) {
            Write-Log "Ensure Magisk APK is installed and the patched boot image was successfully flashed." "Info"
            Write-Log "If Magisk prompts for Superuser access on the headset display, be sure to grant it." "Info"
        } else {
            Write-Log "Root access or su binaries are still detected on the device." "Info"
            Write-Log "Ensure the stock boot image has been properly flashed to restore unrooted state." "Info"
        }
    }
}

#########################################
#########################################
#########################################

function BootImage-Picker($imageName) {
    $bootImgPath = Join-Path $BootBackupPath "$imageName.img"

    if ($bootImgPath -and (Test-Path $bootImgPath)) {
        $bootImgPath = Get-Item -Path $bootImgPath

        Write-Log "Using '${cGreen}$( $bootImgPath.FullName )${cReset}' from previous successful boot image." "Success"

        return $bootImgPath
    }
    
    Write-Log "Could not find any ${cYellow}'$imageName.img'${cReset} file automatically." "Warning"

    $selectedPath = Get-FileOrFolderDialog "Select $imageName.img" 0 ".img"
    
    if (-not [string]::IsNullOrWhiteSpace($selectedPath) -and (Test-Path $selectedPath)) {
        Write-Log "Selected file: ${cYellow}$( $bootImgPath.FullName )${cReset}" "Info"
        $bootImgPath = Get-Item $selectedPath

        return $bootImgPath
    }
    
    return $null
}

function Pull-BootImage {
    Write-Header "Pull Boot Image"
    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to pull the boot image." "Warning"
    Write-Log "Device charging is disabled in EDL mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"

    $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
    if ($confirmation -ne 'yes') {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return $false
    }
    
    $dumpedBoot = Join-Path $BootBackupPath "boot.img"
    
    # Ensure backup directory exists
    if (-not (Test-Path $BootBackupPath)) {
        New-Item -Path $BootBackupPath -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $dumpedBoot) -or (Get-Item $dumpedBoot).Length -eq 0) {
        # Reboot EDL
        if (IsAdbMode) {
            ADB-To-Edl
        } elseif (IsFastbootMode) {
            Fastboot-To-Edl
        } elseif (-not (IsEdlMode)) {
            Warning-EDL
        }

        if (-not (Wait-EdlMode 100)) {
            return $false
        }

        Write-Log "Pulling stock 'boot' image via EDL..." "Action"

        # Pull boot image
        $null = Execute-EdlCommand "read-part boot $dumpedBoot"
        $exitcode = $LASTEXITCODE

        # Fallback to boot_a if image naming uses slot suffix
        if ($exitcode -ne 0 -or !(Test-Path $dumpedBoot) -or (Get-Item $dumpedBoot).Length -eq 0) {
            Write-Log "'boot' image not found or failed, trying 'boot_a'..." "Action"
            $null = Execute-EdlCommand "read-part boot_a ${dumpedBoot}"
            $exitcode = $LASTEXITCODE
        }

        if ($exitcode -ne 0 -or !(Test-Path $dumpedBoot) -or (Get-Item $dumpedBoot).Length -eq 0) {
            Write-Log "Pulling boot image failed with code ${cCyan}${exitcode}${cReset}." "Error"
            Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
            Wait-Continue

            return $false
        }
    }

    $bootPath = (Get-Item $dumpedBoot).FullName
    Write-Log "Stock boot image pulled to ${cGreen}'${bootPath}'${cReset} successfully." "Success"
    Wait-Continue

    return $true
}

function Prepare-Magisk {
    Write-Header "Preparing Magisk"

    # Find image
    $bootImgPath = BootImage-Picker "boot"

    if (-not $bootImgPath) {
        return
    }

    # Reboot system
    if (IsFastbootMode) {
        Fastboot-To-System
    } elseif (IsEdlMode) {
        Edl-To-System
    } elseif (-not (IsAdbMode)) {
        Warning-ADB
    }

    if (-not (Wait-AdbMode 500)) {
        return
    }

    Write-Log "Installing ${cYellow}Magisk APK${cReset}..." "Action"
    if (Test-Path $Magisk) {
        & $ADB install $Magisk
        if ($LASTEXITCODE -eq 0) {
            Write-Log "${cCyan}Magisk${cReset} installed successfully." "Success"
        } else {
            Write-Log "Failed to install ${cYellow}Magisk${cReset}." "Error"
            return
        }
    } else {
        Write-Log "Magisk APK not found at ${cYellow}${Magisk}${cReset}" "Error"
    }

    Perform-MagiskBoot $bootImgPath
}

function Flash-BootImage([string]$imageName) {
    Write-Header "Flash Boot Image"

    # Find image
    $bootImgPath = BootImage-Picker $imageName

    if (-not $bootImgPath) {
        return $false
    }

    if (IsAdbMode) {
        ADB-To-Fastboot
    } elseif (-not (IsFastbootMode)) {
        Warning-FASTBOOT
    }

    if (-not (Wait-FastbootMode 100)) {
        return $false
    }

    if (-not (Execute-UnlockCommand)) {
        return $false
    }

    Write-Log "Flashing boot image with '${cCyan}$( $bootImgPath.FullName )${cReset}'..." "Action"
    & $FASTBOOT flash boot $bootImgPath.FullName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Flash successful." "Success"
        Wait-Continue

        return $true
    } else {
        Write-Log "Failed to flash boot image." "Error"
        Wait-Continue
        
        return $false
    }
}

#########################################
#########################################
#########################################

function Show-RootMenu {
    $rootQuit = $false
    while (-not $rootQuit) {
        Write-Header "Pico Root Menu"
        Write-Log "[${cCyan}1${cReset}] Prepare Boot Image"
        Write-Log "[${cCyan}2${cReset}] Prepare Magisk"
        Write-Log "[${cCyan}3${cReset}] Root With Magisk"
        Write-Log ""
        Write-Log "[${cCyan}u${cReset}] Unroot"
        Write-Log "[${cCyan}r${cReset}] Reboot"
        Write-Log "[${cCyan}0${cReset}] Back to Main Menu"

        $selection = Read-HostLog "Select an option"

        switch ($selection) {
            "1" {
                Select-Firehose

                if ([bool](Pull-BootImage)) {
                    if (IsEdlMode) {
                        Edl-To-System
                    }
                } else {
                    Warning-EDL-ManualReboot
                }
            }
            "2" {
                Prepare-Magisk
            }
            "3" {
                if (Flash-BootImage "magisk_patched") {
                    Verify-RootState "root"
                }
            }
            "u" {
                if (Flash-BootImage "boot") {
                    Verify-RootState "unroot"
                }
            }
            "r" {
                Perform-Reboot
            }
            "0" {
                $rootQuit = $true
            }
            default {
                Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
            }
        }
        if (-not $rootQuit) {
            Wait-Continue "return to the Root menu..."
        }
    }
}
