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
$BootBackupPath = Join-Path $BackupPath "boot"

function Perform-MagiskBoot([string]$bootImgPath) {
    $success = $true
    $outputImgPath = $null

    try {
        # Verification Check
        foreach ($file in @($Magisk, $bootImgPath, $MagiskBoot)) {
            if (-not (Test-Path $file)) {
                throw "Required file missing: ${cCyan}${file}${cReset}"
            }
        }

        # Set output image path inside the same directory as the source boot image
        $bootImgDir = Split-Path -Path $bootImgPath -Parent
        $outputImgPath = Join-Path $bootImgDir "magisk_patched.img"

        # Ensure temporary directory exists
        if (-not (Test-Path $MagiskTMP)) {
            New-Item -Path $MagiskTMP -ItemType Directory -Force | Out-Null
        }

        if (Test-Path $outputImgPath) {
            Remove-Item -Path $outputImgPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Push-Location $MagiskTMP

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
        if ($LASTEXITCODE -ne 0) {
            throw "magiskboot cpio patch failed with exit code ${LASTEXITCODE}."
        }

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

        if (-not (Test-Path $outputImgPath)) {
            throw "Repack failed. Output image was not created."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        # Safely restore original working directory if dynamic location push occurred
        if ((Get-Location).Path -eq $MagiskTMP) {
            Pop-Location
        }

        # Cleanup Temporary Artifacts inside $MagiskTMP
        Write-Log ""
        if (Test-Path -Path $MagiskTMP) {
            Write-Log "Deleting '${cCyan}$( $MagiskTMP )${cReset}' folder..." "Action"
            Remove-Item -Path $MagiskTMP -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($success) {
            Write-Log "Boot image patched to '${cCyan}$( $outputImgPath )${cReset}' successfully." "Success"
        }
    }

    return $success
}

function IsDeviceRooted {
    # Primary Check: check Magisk directly using su -c magisk -v / magisk -v
    Write-Log "Checking Superuser access using '${cCyan}adb shell su -c magisk -v${cReset}'..." "Action"
    $magiskVerRaw = & $ADB shell "magisk -v" 2>&1
    $magiskVer = ($magiskVerRaw -join "`n").Trim()

    if ($magiskVer -match "(:MAGISK|\d+\.\d+|\b\d{5}\b)") {
        Write-Log "Magisk version: ${cGreen}$magiskVer${cReset}" "Info"
        return $true
    }

    # Secondary Primary Check: check root uid via su -c id
    Write-Log ""
    Write-Log "Checking Superuser access using '${cCyan}adb shell -c id${cReset}'..." "Action"
    $suOutputRaw = & $ADB shell "su -c id" 2>&1
    $suOutput = ($suOutputRaw -join "`n").Trim()
    Write-Log $suOutput "Info"
    if ($suOutput -match "uid=0(\(root\))?") {
        return $true
    }

    # Fallback Check: su 0 id
    Write-Log ""
    Write-Log "Checking fallback with ${cCyan}adb shell su 0 id${cReset}..." "Action"
    $altSuRaw = & $ADB shell "su 0 id" 2>&1
    $altSu = ($altSuRaw -join "`n").Trim()
    Write-Log $altSu "Info"
    if ($altSu -match "uid=0(\(root\))?") {
        return $true
    }

    # Fallback Check: adb root (if adbd runs as root)
    Write-Log ""
    Write-Log "Checking fallback with ${cCyan}adb shell id${cReset}..." "Action"
    $idRaw = & $ADB shell "id" 2>&1
    $idOutput = ($idRaw -join "`n").Trim()
    if ($idOutput -match "uid=0(\(root\))?") {
        return $true
    }

    return $false
}

function Verify-RootState([string]$state) {
    $success = $true
    $isCheckRoot = (-not $state) -or ($state -match "^root")
    $actionName = if ($isCheckRoot) { "Verify Root Access" } else { "Verify Unroot State" }
    $statusText = "UNKNOW"

    try {
        Write-Header $actionName

        # Ensure device is in ADB mode
        if (IsFastbootMode) {
            Fastboot-To-System
        } elseif (IsEdlMode) {
            Edl-To-System
        } elseif (-not (IsAdbMode)) {
            Warning-ADB
        }

        if (-not (Wait-AdbMode)) {
            throw ""
        }

        $isRooted = IsDeviceRooted

        if ($null -eq $isRooted) {
            Write-Log "Please check your device screen for any Superuser authorization prompt." "Warning"
            throw "Unable to automatically detect superuser state."
        }

        # Determine if actual device state matches desired state
        $desiredState = if ($isCheckRoot) { $true } else { $false }
        $success = ($isRooted -eq $desiredState)
        $statusText = if ($isRooted) { "ROOTED" } else { "NOT ROOTED" }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log ""
            Write-Log "Root status confirmed: ${cGreen}$statusText${cReset}" "Success"
        } else {
            Write-Log ""
            Write-Log "Device root state: ${cRed}$statusText${cReset}." "Error"
            if ($isCheckRoot) {
                Write-Log "Ensure Magisk is installed, ${cCyan}Prepare Magisk${cReset} and ${cCyan}Root With Magisk${cReset} was successfully flashed." "Info"
                Write-Log "If Magisk prompts for Superuser access on the headset display, be sure to grant it." "Interactive"
            } else {
                Write-Log "Root access or su binaries are still detected on the device." "Info"
                Write-Log "Ensure the stock boot image has been properly flashed to restore unrooted state." "Interactive"
            }
        }

        if ($isCheckRoot) {
            Wait-Continue
            SystemUpdate-Management "1"
        }
    }
}

function Test-Superuser-Access {
    Write-Header "Test Superuser Access"

    # Reboot system
    if (IsFastbootMode) {
        Fastboot-To-System
    } elseif (IsEdlMode) {
        Edl-To-System
    } elseif (-not (IsAdbMode)) {
        Warning-ADB
    }

    if (-not (Wait-AdbMode)) {
        return
    }

    $isRooted = IsDeviceRooted
    Write-Log ""
    if ($isRooted) {
        Write-Log "Superuser access is granted." "Success"
    } else {
        Write-Log "Superuser access is denied or device is not rooted." "Error"
    }
}

#########################################
#########################################
#########################################

function ImageFile-Picker($imageName) {
    $bootImgPath = $null

    try {
        $targetPath = Join-Path $BootBackupPath "$imageName.img"

        if ($targetPath -and (Test-Path $targetPath)) {
            $bootImgPath = Get-Item -Path $targetPath
            Write-Log "Using '${cGreen}$( $bootImgPath.FullName )${cReset}' from previous successful boot image." "Success"
            throw ""
        }

        if (-not [string]::IsNullOrEmpty($imageName)) {
            Write-Log "Could not find any ${cYellow}'$imageName.img'${cReset} file automatically." "Warning"
        }

        $selectedPath = Get-FileOrFolderDialog "Select $imageName.img" 0 ".img"

        if (-not [string]::IsNullOrWhiteSpace($selectedPath) -and (Test-Path $selectedPath)) {
            $bootImgPath = Get-Item $selectedPath
            Write-Log "Selected file: ${cYellow}$( $bootImgPath.FullName )${cReset}" "Info"
            throw ""
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $bootImgPath
}

function Pull-BootImage {
    $success = $true
    $lastError = $null
    $bootPath = $null
    $dumpedBoot = Join-Path $BootBackupPath "boot.img"

    try {
        Write-Header "Pull Boot Image"
        Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to pull the boot image." "Warning"
        Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"

        $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
        if ($confirmation -ne 'yes') {
            throw "Aborted by user. No changes have been made."
        }

        # Ensure backup directory exists
        if (-not (Test-Path $BootBackupPath)) {
            New-Item -Path $BootBackupPath -ItemType Directory -Force | Out-Null
        }

        # Delete existing boot.img
        if ((Test-Path $dumpedBoot) -or (Get-Item $dumpedBoot).Length -ne 0) {
            Remove-Item -Path $dumpedBoot -Recurse -Force -ErrorAction SilentlyContinue
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

        Write-Log "Pulling stock '${cCyan}boot${cReset}' image..." "Action"

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
            throw "Pulling boot image failed with code ${cCyan}${exitcode}${cReset}."
        }
        
        $bootPath = (Get-Item $dumpedBoot).FullName
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Stock boot image pulled to ${cGreen}'${bootPath}'${cReset} successfully." "Success"
            Write-Log ""
            Write-Log "The next step is perform ${cCyan}Prepare Magisk${cReset}." "Info"
            Write-Log "Device will boot to system normally." "Info"
            
            if (IsEdlMode) {
                Wait-Continue
                Edl-To-System
            }
        } else {
            if ($lastError.Message -notlike "*Abort*") {
                Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
                Wait-Continue
            }

            Warning-EDL-ManualReboot
        }
    }
}

function Prepare-Magisk {
    $success = $true

    try {
        Write-Header "Preparing Magisk"

        # Find image
        $bootImgPath = ImageFile-Picker "boot"

        if (-not $bootImgPath) {
            throw ""
        }

        # Reboot system
        if (IsFastbootMode) {
            Fastboot-To-System
        } elseif (IsEdlMode) {
            Edl-To-System
        } elseif (-not (IsAdbMode)) {
            Warning-ADB
        }

        if (-not (Wait-AdbMode)) {
            throw ""
        }

        Write-Log "Installing ${cYellow}Magisk APK${cReset}..." "Action"
        if (-not (Test-Path $Magisk)) {
            throw "Magisk APK not found at ${cYellow}${Magisk}${cReset}"
        }

        & $ADB install $Magisk
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install ${cYellow}Magisk${cReset}."
        }

        Write-Log "${cCyan}Magisk${cReset} installed successfully." "Success"

        $success = Perform-MagiskBoot $bootImgPath
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log ""
            Write-Log "The next step is perform ${cCyan}Root With Magisk${cReset}." "Info"
        }
    }
}

function FlashBoot-ViaFastboot([string]$partition, [string]$imageName) {
    $success = $true

    try {
        Write-Header "Fastboot Flash Image"

        # Find image
        $imagePath = ImageFile-Picker $imageName

        if (-not $imagePath) {
            throw ""
        }

        if (IsAdbMode) {
            ADB-To-Fastboot
        } elseif (-not (IsFastbootMode)) {
            Warning-FASTBOOT
        }

        if (-not (Wait-FastbootMode)) {
            throw ""
        }

        if (-not (Execute-UnlockCommand)) {
            throw ""
        }

        Write-Log "Flashing ${cCyan}$partition${cReset} image with '${cCyan}$( $imagePath.FullName )${cReset}'..." "Action"
        & $FASTBOOT flash $partition $imagePath.FullName

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to flash ${cCyan}$partition${cReset} image."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Flash successful." "Success"
            Wait-Continue
        }
    }

    return $success
}

function FlashBoot-ViaEDL([string]$partition, [string]$imageName) {
    $success = $true

    try {
        Write-Header "EDL Flash Image"
        Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to flash ${cCyan}$partition${cReset} partition." "Warning"
        Write-Log "${cRed}Bootloop${cReset} might occur if the bootloader is still in a ${cRed}locked${cReset} state." "Warning"
        Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"

        $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
        if ($confirmation -ne 'yes') {
            throw "Aborted by user. No changes have been made."
        }

        # Find image
        $imagePath = ImageFile-Picker $imageName

        if (-not $imagePath) {
            throw ""
        }

        # Device Reboot to EDL Mode
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

        Write-Log "Flashing ${cCyan}$partition${cReset} image with '${cCyan}$( $imagePath.FullName )${cReset}'..." "Action"
        if (-not (Execute-EdlCommand "write-part $partition $($imagePath.FullName)")) {
            throw "Failed to flash ${cCyan}$partition${cReset} image."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Flash successful." "Success"
            Wait-Continue
        }
    }

    return $success
}

function Perform-FlashImage([string]$partition = "", [string]$imageName = "") {
    Write-Header "Select Flash Method"
    
    $success = $true

    try {
        # Define all partitions present in the GPT printout
        $validPartitions = @("abl", "ablbak", "aop", "aopbak", "apdp", "bluetooth", "bluetoothbak", "boot", "bootbak", "cache", "cdt", "cmnlib", "cmnlib64", "cmnlib64bak", "cmnlibbak", "ddr", "devcfg", "devcfgbak", "devinfo", "dip", "dsp", "dspbak", "dtbo", "dtbobak", "featenabler", "featenablerbak", "frp", "fsc", "fsg", "hyp", "hypbak", "imagefv", "imagefvbak", "keymaster", "keymasterbak", "keystore", "limits", "limits-cdsp", "logdump", "logfs", "mdm1m9kefs1", "mdm1m9kefs2", "mdm1m9kefs3", "mdm1m9kefsc", "mdmddr", "mdtp", "mdtpbak", "mdtpsecapp", "mdtpsecappbak", "metadata", "misc", "modem", "modembak", "modemst1", "modemst2", "msadp", "multiimgoem", "multiimgoembak", "multiimgqti", "multiimgqtibak", "persist", "picocfg", "qupfw", "qupfwbak", "rawdump", "recovery", "secdata", "spunvm", "ssd", "storsec", "super", "tz", "tzbak", "uefisecapp", "uefisecappbak", "uefivarstore", "userdata", "vbmeta", "vbmeta_system", "vbmeta_systembak", "vbmetabak", "vm-data", "vm-keystore", "vm-linux", "vm-linuxbak", "vm-system", "vm-systembak", "xbl", "xbl_config", "xbl_configbak", "xblbak")

        # Select partition
        if ([string]::IsNullOrWhiteSpace($partition)) {
            $selectedIndex = Select-InteractiveMenu -header "Select partition to flash." -options $validPartitions
            if ($selectedIndex -ge 0) {
                $partition = $validPartitions[$selectedIndex]
            }

            Write-Header "Select Flash Method"
        }

        # Validate Partition Existence
        if ($validPartitions -notcontains $partition) {
            throw "Partition '${cCyan}$partition${cReset}' does not exist on this device!"
        }

        Write-Log "Target Partition: '${cCyan}$partition${cReset}'"
        Write-Log "[${cCyan}1${cReset}] EDL ${cDarkGray}(Require bootloader unlocked)${cReset}"
        Write-Log "[${cCyan}2${cReset}] Fastboot ${cDarkGray}(Require bootloader unlocked and engineering ABL)${cReset}"
        
        $selection = Read-HostLog "Select an option"
        switch ($selection) {
            "1" { 
                Select-Firehose
                Write-Log "Using EDL." "Info"
                $success = FlashBoot-ViaEDL $partition $imageName
            }
            "2" { 
                Write-Log "Using Fastboot." "Info"
                $success = FlashBoot-ViaFastboot $partition $imageName
            }
            Default {
                throw "Invalid input: [${cYellow}$selection${cReset}]"
            }
        }
    } catch {
        $success = $false

        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $success
}

#########################################
#########################################
#########################################

function Show-RootMenu {
    $rootQuit = $false
    while (-not $rootQuit) {
        Write-Header "Root / Flash Image"
        Write-Log "[${cCyan}1${cReset}] Prepare Boot Image"
        Write-Log "[${cCyan}2${cReset}] Prepare Magisk"
        Write-Log "[${cCyan}3${cReset}] Root With Magisk"
        Write-Log ""
        Write-Log "[${cCyan}f${cReset}] Flash Custom Image"
        Write-Log "[${cCyan}t${cReset}] Test Superuser Access"
        Write-Log "[${cCyan}u${cReset}] Unroot"
        Write-Log "[${cCyan}r${cReset}] Reboot"
        Write-Log "[${cCyan}0${cReset}] Back to Main Menu"

        $selection = Read-HostLog "Select an option"
        switch ($selection) {
            "1" {
                Select-Firehose
                Pull-BootImage
            }
            "2" {
                Prepare-Magisk
            }
            "3" {
                if (Perform-FlashImage "boot" "magisk_patched") {
                    Verify-RootState "root"
                }
            }
            "f" {
                $null = Perform-FlashImage
            }
            "t" {
                Test-Superuser-Access
            }
            "u" {
                if (Perform-FlashImage "boot" "boot") {
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
