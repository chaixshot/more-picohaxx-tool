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

$PatchedImagePath = $null

function Perform-MagiskBoot([string]$bootImgPath) {
    # Verification Check
    foreach ($file in @($Magisk, $bootImgPath, $MagiskBoot)) {
        if (-not (Test-Path $file)) {
            Write-Log "Required file missing: ${cCyan}${file}${cReset}" "Error"
            return $null
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
        Write-Host ""
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
        Write-Host ""
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
            # Fallback to default
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
        Write-Host ""
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
                Write-Host ""
                Write-Log "Patching $dt fstab..." "Action"
                & $MagiskBoot dtb $dt patch 2>&1 | Write-Host
            }
        }

        # Keep original raw kernel to prevent bootloop or compression mismatches
        if (Test-Path "kernel") {
            Remove-Item "kernel" -Force
        }

        # Repack Image directly to destination path
        Write-Host ""
        Write-Log "Repacking image into $outputImgPath..." "Action"
        & $MagiskBoot repack $bootImgPath $outputImgPath 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "magiskboot repack failed with exit code ${LASTEXITCODE}."
        }
    } catch {
        Write-Host ""
        Write-Log "$($_.Exception.Message)" "Error"
    } finally {
        # Safely restore original working directory
        Pop-Location

        # Cleanup Temporary Artifacts inside $MagiskTMP
        Write-Host ""
        if (Test-Path -Path $MagiskTMP) {
            Write-Log "Deleting '${cCyan}$( $MagiskTMP )${cReset}' folder..." "Action"
            Remove-Item -Path $MagiskTMP -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Verification
    if (Test-Path $outputImgPath) {
        Write-Log "Boot image patched to '${cCyan}$( $outputImgPath )${cReset}' successfully." "Success"

        return $outputImgPath
    } else {
        Write-Log "Repack failed. Output image was not created." "Error"
        return $null
    }
}

function BootImage-Picker($imageName) {
    Write-Log "Please select your ${cYellow}'$imageName.img'${cReset} file from explorer." "Info"
    Wait-Continue "Select file"

    # Initialize the File Dialog
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = "Select your $imageName.img file"
    $fileDialog.Filter = "Magisk Patched Image (*$imageName*.img)|*$imageName*.img|All Files (*.*)|*.*"
    $fileDialog.InitialDirectory = (Get-Location).Path
    $fileDialog.ShowHelp = $false

    # Show the dialog using an invisible top-most owner
    $topForm = New-Object System.Windows.Forms.Form
    $topForm.TopMost = $true

    $dialogResult = $fileDialog.ShowDialog($topForm)
    $topForm.Dispose()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $bootImgPath = Get-Item $fileDialog.FileName

        Write-Log "Selected file: ${cYellow}$( $bootImgPath.FullName )${cReset}" "Info"

        return $bootImgPath
    } else {
        Write-Log "No file was selected from explorer." "Warning"

        $bootImgPath = Read-HostLog "Enter the full path to your ${cYellow}'$imageName.img'${cReset} (e.g., C:\Downloads\$imageName.img)"
        $bootImgPath = $bootImgPath.Trim('"').Trim()

        if (Test-Path $bootImgPath -PathType Leaf) {
            $tempItem = Get-Item $bootImgPath
            if ($tempItem.Extension -eq ".img") {
                Write-Log "Selected file: ${cYellow}$( $tempItem.FullName )${cReset}" "Info"

                return $tempItem
            } else {
                Write-Log "Selected file '${cYellow}$bootImgPath${cReset}' is not a '.img' file." "Error"

                return $null
            }
        } else {
            Write-Log "File not found at '${cYellow}$bootImgPath${cReset}'. Please ensure the path is correct and try again." "Error"

            return $null
        }
    }
}

function Prepare-Firmware {
    Write-Header "Select Pico Firmware"

    if (IsAdbMode) {
        Write-Log "Device detected in ADB mode. Retrieving device info..." "Action"

        $picoVersion = (& $ADB shell getprop ro.build.display.id).Trim()
        $model = (& $ADB shell getprop ro.product.model).Trim()
        if (-not $model) { $model = (& $ADB shell getprop ro.product.name).Trim() }
        if (-not $model) { $model = (& $ADB shell getprop ro.build.product).Trim() }

        $region = (& $ADB shell getprop ro.pico.region).Trim()
        if (-not $region) { $region = (& $ADB shell getprop ro.product.locale).Trim() }
        $oemState = (& $ADB shell getprop ro.oem.state).Trim()

        # Interpret Model
        $modelFriendly = switch -Wildcard ($model) {
            "A8110" { "Pico 4" }
            "*phoenix*" { "Pico 4" }
            "A8150" { "Pico 4 Pro" }
            "A7H10" { "Pico Neo 3" }
            "*falcon*" { "Pico Neo 3" }
            Default { $model }
        }

        # Interpret Region
        $regionFriendly = switch -Wildcard ($region) {
            "cn" { "Chinese" }
            "*Hans-CN*" { "Chinese" }
            "global" { "Global" }
            "en-US" { "Global" }
            Default { "Unknown ($region)" }
        }

        # Interpret OEM Status
        $oemFriendly = if ($oemState -eq "true") { "OEM" } else { "NON-OEM" }

        Write-Log "Detected Model  : ${cGreen}$modelFriendly${cReset}" "Info"
        Write-Log "Detected Region : ${cGreen}$regionFriendly${cReset}" "Info"
        Write-Log "Detected Type   : ${cGreen}$oemFriendly${cReset}" "Info"
        Write-Log "OS Version      : ${cGreen}$picoVersion${cReset}" "Info"
        Write-Host ""
    } else {
        Write-Log "Device in ADB mode can automatically detect model, region, and version." "Info"
        Wait-Continue
    }

    $FirmwareData = [ordered]@{
        "Pico 4" = [ordered]@{
            "Global"  = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.13.7" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.7-202510301735-RELEASE-user-phoenix-b9665-42be801fae.zip"
                    "5.13.3" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.3-202507030112-RELEASE-user-phoenix-b9480-6746cfb44c.zip"
                    "5.13.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.2-202506120445-RELEASE-user-phoenix-b9453-cad6c763e2.zip"
                    "5.12.0" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.12.0-202412240712-RELEASE-user-phoenix-b9053-6468a45872.zip"
                    "5.11.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.11.2-202409110320-RELEASE-user-phoenix-b8729-c376dd9f4c.zip"
                    "5.9.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.2-202403020343-RELEASE-user-phoenix-b7710-fb66acdc51.zip"
                    "5.8.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/oIAE274enAAPpnBHYaeAkhTemIb3KAFEDdA8fT.zip"
                    "5.7.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKOSA.falconcv3plusoversea-user/202308042218/5.7.1-202308041830-RELEASE-user-phoenix-b5295-b0b9317377.zip"
                    "5.6.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.6.0-20230509-SEKOSA.falconcv3plusoversea-user/202305190740/5.6.0-202305190440-RELEASE-user-phoenix-b4261-1a0a729e58.zip"
                    "5.5.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_mol_phoenix-rom-pui-5.0.0-SEKOSA.falconcv3plusoversea-user/202303210237/5.5.0-202303210100-RELEASE-user-phoenix-b3599-11e7c04f27.zip"
                    "5.4.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.4.0-20230201-SEKOSA.falconcv3plusoversea-user/202302171510/5.4.0-202302171231-RELEASE-user-phoenix-b3159-21724b5b8e.zip"
                    "5.3.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKOSA.falconcv3plusoversea-user/202301072132/5.3.2-202301071817-RELEASE-user-phoenix-b2705-0d2c0cb6ec.zip"
                }
                "NON-OEM" = [ordered]@{
                    "5.13.7" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.7-202510301739-RELEASE-user-phoenix-b9666-26140cfa0d.zip"
                    "5.13.3" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.3-202507030047-RELEASE-user-phoenix-b9479-aa79997682.zip"
                    "5.13.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.2-202506120448-RELEASE-user-phoenix-b9454-14de1976f3.zip"
                    "5.12.0" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.12.0-202412240315-RELEASE-user-phoenix-b9051-1f2c7043f5.zip"
                    "5.11.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.11.2-202409110150-RELEASE-user-phoenix-b8727-cf87d6eb11.zip"
                    "5.9.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.2-202403020025-RELEASE-user-phoenix-b7699-7d61a64f70.zip"
                    "5.8.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/okPl0fYeAGAbApETQI8yJrJnmbvnHE9DBPCBPA.zip"
                    "5.7.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKSA.falconcv3plusoversea-user/202308042046/5.7.1-202308041842-RELEASE-user-phoenix-b5296-f92724093a.zip"
                    "5.6.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.6.0-20230509-SEKSA.falconcv3plusoversea-user/202305190633/5.6.0-202305190206-RELEASE-user-phoenix-b4256-a8a60c5b55.zip"
                    "5.5.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_mol_phoenix-rom-pui-5.0.0-SEKSA.falconcv3plusoversea-user/202303210128/5.5.0-202303210013-RELEASE-user-phoenix-b3597-4335638970.zip"
                    "5.4.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.4.0-20230201-SEKSA.falconcv3plusoversea-user/202302171826/5.4.0-202302171557-RELEASE-user-phoenix-b3162-3d2f0dbe1b.zip"
                    "5.3.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKSA.falconcv3plusoversea-user/202301072002/5.3.2-202301071642-RELEASE-user-phoenix-b2704-ae2fa5f1b3.zip"
                }
            }
            "Chinese" = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.13.7" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.7-202510300008-RELEASE-user-phoenix-b9650-de69e61ba0.zip"
                    "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.3-202507021009-RELEASE-user-phoenix-b9472-d668fe19ea.zip"
                    "5.13.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120253-RELEASE-user-phoenix-b9448-3dd5f7afa1.zip"
                    "5.12.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.12.0-202411300320-RELEASE-user-phoenix-b8995-88422e1189.zip"
                    "5.11.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.2-202409110154-RELEASE-user-phoenix-b8728-142817eb57.zip"
                    "5.9.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.2-202403020318-RELEASE-user-phoenix-b7708-5a0fa763a9.zip"
                    "5.8.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.2-202310121346-RELEASE-user-phoenix-b6296-1d0490fbc5.zip"
                    "5.7.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.2-202308222102-RELEASE-user-phoenix-b5651-f9762f8b82.zip"
                    "5.6.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.0-202305190627-RELEASE-user-phoenix-b4262-ef635462e7.zip"
                    "5.5.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.0-202303210104-RELEASE-user-phoenix-b3600-4aa67fc5c2.zip"
                    "5.4.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.0-202302082133-RELEASE-user-phoenix-b3033-575cb027b3.zip"
                    "5.3.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.3.1-202301051635-RELEASE-user-phoenix-b2669-c435f2dfde.zip"
                }
                "NON-OEM" = [ordered]@{
                    "5.13.7" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.7-202510300015-RELEASE-user-phoenix-b9651-cb5ad9d7db.zip"
                    "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.3-202507020958-RELEASE-user-phoenix-b9471-68dd78c7db.zip"
                    "5.13.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120434-RELEASE-user-phoenix-b9452-4a4dd3dcb8.zip"
                    "5.12.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.12.0-202411300021-RELEASE-user-phoenix-b8991-11aac801da.zip"
                    "5.11.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.2-202409110014-RELEASE-user-phoenix-b8724-df7554f9e7.zip"
                    "5.9.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.2-202403020013-RELEASE-user-phoenix-b7697-1bd8e00f8c.zip"
                    "5.8.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.2-202310121535-RELEASE-user-phoenix-b6299-a814249094.zip"
                    "5.7.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.2-202308222102-RELEASE-user-phoenix-b5650-646a478a27.zip"
                    "5.6.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.0-202305190040-RELEASE-user-phoenix-b4252-81463e6b04.zip"
                    "5.5.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.0-202303210046-RELEASE-user-phoenix-b3598-75d3c842d2.zip"
                    "5.4.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.0-202302091032-RELEASE-user-phoenix-b3046-e076814e50.zip"
                }
            }
        }
        "Pico 3" = [ordered]@{
            "Global"   = [ordered]@{
                "5.13.7" = "https://static.us-pui.picovr.com/5.13.7.0-202510301731-RELEASE-user-neo3-b3527-a84e92f190.zip"
                "5.13.3" = "https://static.us-pui.picovr.com/5.13.3.0-202507031601-RELEASE-user-neo3-b3446-5418c43b4d.zip"
            }
            "Chinese"  = [ordered]@{
                "5.13.7" = "https://alistatic.pui.picovr.com/5.13.7-202510301728-RELEASE-user-neo3-b5902-ddd6d04448.zip?_gl=1*1n8xuja*_gcl_au*MTM2ODg0NzA2MS4xNzYwMDUxMTY3"
                "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120456-RELEASE-user-neo3-b5809-52a79f45aa.zip"
            }
            "Business" = [ordered]@{
                "5.11.3" = "http://corntube.net/index.php/s/p529wTbWWgdFfor"
                "5.9.9"  = "https://static.us-pui.picovr.com/5.9.9.0-202409100359-RELEASE-user-neo3-b3006-12c1d440db.zip"
                "5.7.5"  = "https://static.us-pui.picovr.com/5.7.5.0-202308042126-RELEASE-user-neo3-b1647-47a1cf2d65.zip"
            }
        }
    }

    $currentMenu = $FirmwareData
    $path = ""

    while ($currentMenu -is [System.Collections.IDictionary]) {
        $options = @($currentMenu.Keys)
        Write-Host "`nSelect an option for ${cCyan}$path${cReset}:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host " [${cCyan}$( $i + 1 )${cReset}] $($options[$i])"
        }
        Write-Host " [${cCyan}0${cReset}] Cancel"

        $choice = Read-HostLog "Choice"
        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }

        if ([int]::TryParse($choice, [ref]$null) -and [int]$choice -le $options.Count) {
            $key = $options[[int]$choice - 1]
            $path += " > $key"
            $currentMenu = $currentMenu[$key]
        } else {
            Write-Log "Invalid selection." "Warning"
        }
    }

    if ($currentMenu -is [string]) {
        $firmwareUrl = $currentMenu
        Write-Log "Firmware selection complete: ${cGreen}$path${cReset}" "Success"
        Write-Log "Download Link: ${cCyan}$firmwareUrl${cReset}" "Info"

        Write-Host "`nWould you like to open this URL in your browser? (${cCyan}y${cReset}/n): " -NoNewline
        $openUrl = Read-Host
        if ($openUrl -eq 'y' -or $openUrl -eq 'Y') {
            Start-Process $firmwareUrl
        }

        Write-Log "Extract ${cYellow}'boot.img'${cReset}" "Action"
        Write-Log "Once the firmware is downloaded, extract ${cYellow}'boot.img'${cReset} from the ZIP file." "Info"
    }
}

function Prepare-Magisk {
    Write-Header "Preparing Magisk"

    if (IsFastbootMode) {
        Fastboot-To-System
    } elseif (-not (IsAdbMode)) {
        Warning-ADB
    }

    if (-not (Wait-AdbMode 100)) {
        return
    }

    Write-Log "Installing ${cYellow}Magisk APK${cReset}..." "Action"
    if (Test-Path $Magisk) {
        & $ADB install $Magisk
        if ($LASTEXITCODE -eq 0) {
            Write-Log "${cGreen}Magisk${cReset} installed successfully." "Success"
        } else {
            Write-Log "Failed to install ${cYellow}Magisk${cReset}." "Error"
            return
        }
    } else {
        Write-Log "Magisk APK not found at ${cYellow}${Magisk}${cReset}" "Error"
    }

    $bootImgPath = BootImage-Picker "boot"
    if ($bootImgPath) {
        $script:PatchedImagePath = Perform-MagiskBoot $bootImgPath
    }
}

function Flash-Magisk {
    Write-Header "Flashing Magisk"

    # Find patched image
    $bootImgPath = $null
    if ($PatchedImagePath -and (Test-Path $PatchedImagePath)) {
        $bootImgPath = Get-Item $PatchedImagePath
        Write-Log "Using '${cGreen}$( $bootImgPath.FullName )${cReset}' from preparing magisk." "Success"
    } else {
        $bootImgPath = Get-ChildItem -Path "." -Filter "magisk_patched*.img" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    # No image path found automatically
    if (-not $bootImgPath) {
        Write-Log "Could not find any ${cYellow}'magisk_patched.img'${cReset} file automatically." "Warning"

        $bootImgPath = BootImage-Picker "magisk_patched"
        if (-not $bootImgPath) {
            return
        }
    }

    if (IsAdbMode) {
        ADB-To-Fastboot
    } elseif (-not (IsFastbootMode)) {
        Warning-FASTBOOT
    }

    if (-not (Wait-FastbootMode 100)) {
        return
    }

    if (-not (Execute-UnlockCommand)) {
        return
    }

    Write-Log "Flashing boot image with '${cCyan}$( $bootImgPath.FullName )${cReset}'..." "Action"
    & $FASTBOOT flash boot $bootImgPath.FullName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Flash successful!" "Success"
        Fastboot-To-System
    } else {
        Write-Log "Failed to flash boot image." "Error"
    }
}

function Show-RootMenu {
    $rootQuit = $false
    while (-not $rootQuit) {
        Write-Header "Pico Root Menu"
        Write-Host " [${cCyan}1${cReset}] Prepare Firmware ${cDarkGray}(Firmware link)${cReset}"
        Write-Host " [${cCyan}2${cReset}] Prepare Magisk ${cDarkGray}(Install APK)${cReset}"
        Write-Host " [${cCyan}3${cReset}] Flash Magisk ${cDarkGray}(Fastboot)${cReset}"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}0${cReset}] Back to Main Menu"

        $choice = Read-HostLog "Select an option"

        switch ($choice) {
            "1" {
                Prepare-Firmware
            }
            "2" {
                Prepare-Magisk
            }
            "3" {
                Flash-Magisk
            }
            "r" {
                Perform-Reboot
            }
            "0" {
                $rootQuit = $true
            }
            default {
                Write-Log "Invalid option. Please try again." "Warning"
            }
        }
        if (-not $rootQuit) {
            Wait-Continue "return to the Root menu..."
        }
    }
}
