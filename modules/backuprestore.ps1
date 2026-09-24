#Requires -Version 5.1

<#
.SYNOPSIS
    Backup and Restore functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for backing up device partitions using edl-ng
    and restoring them.
#>

# --- Backup & Restore Functions ---
$7ZIP = Join-Path $WorkingDir "tools\7z.exe"

$BROTLI = Join-Path $WorkingDir "tools\rollback\brotli.exe"
$Sdat2Img = Join-Path $WorkingDir "tools\rollback\sdat2img.exe"
$Img2Simg = Join-Path $WorkingDir "tools\rollback\img2simg.exe"
$LPMAKE = Join-Path $WorkingDir "tools\rollback\lpmake.exe"

$LUNsBackupPath = Join-Path $BackupPath "luns"
$UserBackupPath = Join-Path $BackupPath "userdata"
$PartitionsBackupPath = Join-Path $BackupPath "partitions"

# Define Kernel32 API for reliable NTFS compressed size calculation
if (-not ([System.Management.Automation.PSTypeName]'Native.Win32').Type) {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll", EntryPoint="GetCompressedFileSizeW", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);' -Name 'Win32' -Namespace 'Native'
}

function Extract-CompressedFile($filePath) {
    $parentDir = Split-Path -Parent $filePath
    if (-not $parentDir) { 
        $parentDir = Get-Location
    }
    $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $destPath = Join-Path $parentDir $fileNameNoExt

    if (-not (Test-Path -Path $destPath)) {
        New-Item -Path $destPath -ItemType Directory -Force | Out-Null
    }

    Write-Log "Extracting '${cYellow}$(Split-Path -Leaf $filePath)${cReset}' to '${cCyan}$destPath${cReset}'..." "Action"
    & $7ZIP x "$filePath" "-o$destPath" -y | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Extraction completed successfully." "Success"

        # Check for a single nested subfolder
        $items = Get-ChildItem -Path $destPath
        if (@($items).Count -eq 1 -and $items.PSIsContainer) {
            $subFolder = $items.FullName
            Get-ChildItem -Path $subFolder | Move-Item -Destination $destPath -Force
            Remove-Item -Path $subFolder -Recurse -Force
        }

        return @{ Success = $true; Path = $destPath }
    } else {
        Write-Log "Extraction failed for ${cYellow}$filePath${cReset}." "Error"
        return @{ Success = $false; Path = $destPath }
    }
}

function Show-MenuTree([System.Collections.IDictionary]$MenuData, [scriptblock]$HeaderCallback) {
    $currentMenu = $MenuData
    $selectPath = ""

    while ($currentMenu -is [System.Collections.IDictionary]) {
        & $HeaderCallback 
        Write-Log ""

        $options = @($currentMenu.Keys)
        Write-Log "${cYellow}Select an option${cReset}$selectPath"
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Log " [${cCyan}$( $i + 1 )${cReset}] $($options[$i])"
        }

        $selection = Read-HostLog "Select [${cYellow}0-$($options.Count)${cReset}], press [${cYellow}Enter]${cReset} to skip"
        if ([string]::IsNullOrWhiteSpace($selection)) { 
            return $null 
        }

        if ([int]::TryParse($selection, [ref]$null) -and [int]$selection -ge 1 -and [int]$selection -le $options.Count) {
            $key = $options[[int]$selection - 1]
            $selectPath += " > ${cCyan}$key${cReset}"
            $currentMenu = $currentMenu[$key]
        } else {
            Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
            Wait-Continue
        }
    }

    & $HeaderCallback 
    if ($currentMenu -is [string]) {
        $uri = [System.Uri]$currentMenu
        Write-Log "Firmware selected$($selectPath)" "Success"
        Write-Log "Download Link: ${cCyan}$($uri)${cReset}" "Info"

        $openUrl = Read-HostLog "Would you like to open this URL in your browser? [${cYellow}Y${cReset}/n]"
        if ($openUrl -eq 'y') {
            Write-Log "Opening URL in default browser..." "Action"
            Start-Process $uri.AbsoluteUri
        }
    }
}

function Select-BackupFolder {
    $result = $null

    try {
        Write-Header "Select Backup Folder"

        $backupSources = @(
            @{ Path = $LUNsBackupPath; Type = "luns" },
            @{ Path = $UserBackupPath; Type = "userdata" },
            @{ Path = $PartitionsBackupPath; Type = "partitions" }
        )

        $allBackupFolders = New-Object System.Collections.Generic.List[PSObject]

        foreach ($source in $backupSources) {
            if (Test-Path $source.Path) {
                $folders = Get-ChildItem -Path $source.Path -Directory
                foreach ($f in $folders) {
                    $f | Add-Member -MemberType NoteProperty -Name "BackupType" -Value $source.Type
                    $allBackupFolders.Add($f)
                }
            }
        }

        $backupFolders = $allBackupFolders | Sort-Object CreationTime -Descending

        if ($backupFolders.Count -gt 0) {
            Write-Log "Available Backup Folders:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $backupFolders.Count; $i++) {
                $folder = $backupFolders[$i]
                Write-Log "[${cCyan}$( $i + 1 )${cReset}] $( $folder.Name ) ${cYellow}[$( $folder.BackupType )]${cReset} ${cGreen}($( $folder.CreationTime ))${cReset}"
            }
            $selection = Read-HostLog "Select backup [${cYellow}1-$( $backupFolders.Count )${cReset}], custom backup [${cYellow}A${cReset}], cancel [${cYellow}C${cReset}]"

            if ($selection -eq 'a') {
                $selection = Get-FileOrFolderDialog "Select backup folder for file" 2 ".rar, .zip, .7z"
            }
        } else {
            Write-Log "No backup folders found in default directories." "Warning"
            $selection = Get-FileOrFolderDialog "Select backup folder for file" 2 ".rar, .zip, .7z"
        }

        if ($selection -eq 'c') {
            throw "Aborted by user. No changes have been made."
        }

        if ([string]::IsNullOrEmpty($selection)) {
            throw "Invalid input: [${cYellow}$selection${cReset}]"
        }

        # Check if user pasted a compressed file
        if ($selection -match '\.(rar|zip|7z)$' -and (Test-Path -Path $selection -PathType Leaf)) {
            $result = Extract-CompressedFile $selection
            $selection = $result.Path
            if (-not $result.Success) {
                throw ""
            }
        }

        # Check if user pasted a path
        if (Test-Path -Path $selection -PathType Container) {
            $pastedPath = (Get-Item -Path $selection).FullName
            $detectedType = $null

            foreach ($type in @("luns", "userdata", "partitions", "downgrade")) {
                if (Verify-Backup -backupMode $type -folderPath $pastedPath -silent) {
                    $detectedType = $type
                    break
                }
            }

            if ($null -ne $detectedType) {
                $typeName = switch ($detectedType) {
                    "luns" { "LUNs" }
                    "userdata" { "User Data" }
                    "partitions" { "Partitions" }
                    "downgrade" { "Downgrade Pico 4 / 4 Enterprice / 4 Pro" }
                    default { $detectedType }
                }
                Write-Log "Detected valid ${cYellow}$typeName${cReset} backup at: ${cCyan}$pastedPath${cReset}" "Success"
                Wait-Continue

                $result = [PSCustomObject]@{
                    Path = $pastedPath
                    Type = $detectedType
                }
                throw ""
            } else {
                throw "The provided folder does not contain a valid backup set."
            }
        }

        # Proceed with numeric selection
        if ([int]::TryParse($selection, [ref]$null) -and [int]$selection -ge 1 -and [int]$selection -le $backupFolders.Count) {
            $targetBackup = $backupFolders[[int]$selection - 1]
            Write-Log "Selected backup: ${cCyan}$($targetBackup.Name)${cReset} [${cYellow}$($targetBackup.BackupType)${cReset}] ${cGreen}($($targetBackup.CreationTime))${cReset}" "Success"
            Wait-Continue

            $result = [PSCustomObject]@{
                Path = $targetBackup.FullName
                Type = $targetBackup.BackupType
            }
            throw ""
        }

        throw "Invalid input: [${cYellow}$selection${cReset}]"
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $result
}

function Prepare-Downgrade {
    $FirmwareData = [ordered]@{
        "Pico 4/4 Enterprise" = [ordered]@{
            "Global" = [ordered]@{
                "OEM"     = [ordered]@{ "5.4.0" = "https://drive.google.com/file/d/1zs66s6-S3K3NinkwEtoEaFokNDIvuBTK/view?usp=sharing" }
                "NON-OEM" = [ordered]@{ "5.4.0" = "https://drive.google.com/file/d/1KGg35ydXZo-3J0-PGeOrB09mFcUyzC7y/view?usp=sharing" }
            }
        }
        "Pico 4 Pro"          = [ordered]@{
            "Global" = [ordered]@{
                "OEM"     = [ordered]@{ "5.4.0" = "https://drive.google.com/file/d/1q1pln-9w2Qx8_0KBVnba9os5iD-Pbt7O/view?usp=sharing" }
                "NON-OEM" = [ordered]@{ "5.4.0" = "https://drive.google.com/file/d/10pTWnO5kjNBtSpraTEAQJEC7-0Malz4d/view?usp=sharing" }
            }
        }
    }

    $header = {
        Write-Header "Downgrade Device"
        Write-Log "Downgrade device OS to 5.4.0. Using ${cCyan}Restore Device${cReset} menu to perform downgrade." "Info"
        Write-Log "Option 1: Use provided ${cCyan}Pico4.7z${cReset} file downloaded from this menu in ${cCyan}Restore Device${cReset} menu." "Info"
        Write-Log "Option 2: Using ${cCyan}PICO4_GLOBAL_OS_540_Downgrader${cReset} partitions file set." "Info"
        Write-Log "     - Check in '${cCyan}.\helper\Flasher\Flash${cReset}' is it empty or not." "Info"
        Write-Log "         - If folder empty, navigate to '${cCyan}.\UNBRICK\P4_Unbrick.exe${cReset}'. Finish only extraction process and close the program." "Info"
        Write-Log "         - Recheck '${cCyan}.\helper\Flasher\Flash${cReset}' to confirm the partitions file exist." "Info"
        Write-Log "     - Select '${cCyan}.\helper\Flasher\Flash${cReset}' folder in ${cCyan}Restore Device${cReset} menu." "Info"
    }

    Show-MenuTree -MenuData $FirmwareData -HeaderCallback $header
}

function Perform-RollbackOS {
    $success = $true
    $lastError = $null
    $isTempExtraction = $false
    $extractedFolder = $null
    $pushedLocation = $false

    try {
        Write-Header "Rollback OS"
        Write-Log "Select firmware downloaded file." "Warning"
        $firmwarePath = Get-FileOrFolderDialog "Select firmware downloaded file" 0 ".rar, .zip, .7z"

        if ([string]::IsNullOrEmpty($firmwarePath) -or -not (Test-Path -Path $firmwarePath) -or -not ([System.IO.Path]::GetExtension($firmwarePath) -in @('.zip', '.rar', '.7z'))) {
            throw "No firmware file provided."
        }

        Write-Log ""
        Write-Log "Source: ${cCyan}$firmwarePath${cReset}" "Info"
        if (-not (Wait-UserConfirm "rollback")) {
            throw "Aborted by user. No changes have been made."
        }


        $extractedFolder = $firmwarePath
        $fileList = Get-ChildItem -Path $firmwarePath -Recurse -File -Force -ErrorAction SilentlyContinue
        $maxFileSizeBytes = ($fileList | Measure-Object -Property Length -Maximum).Maximum
        $requiredSpaceGB = [math]::Max(1.0, [math]::Round($maxFileSizeBytes / 1GB, 2))

        if ($false -eq (Verify-DiskSpace -targetPath $firmwarePath -manualSizeGB ($requiredSpaceGB * 5))) {
            throw "Aborted by disk space verify. No changes have been made."
        }

        # Handle archive extraction
        if ($firmwarePath -match '\.(rar|zip|7z)$' -and (Test-Path -Path $firmwarePath -PathType Leaf)) {
            $isTempExtraction = $true
            $result = Extract-CompressedFile $firmwarePath
            $extractedFolder = $result.Path
            if (-not $result.Success) {
                throw ""
            }
        } elseif (-not (Test-Path -Path $extractedFolder -PathType Container)) {
            throw "Target firmware directory '${cCyan}$extractedFolder${cReset}' does not exist."
        }

        Push-Location $extractedFolder
        $pushedLocation = $true

        # Brotli Decompression
        Write-Log ""
        Write-Log "Decompressing Brotli archives..." "Action"
        $brFiles = @("system", "vendor", "product", "odm")
        foreach ($part in $brFiles) {
            $brPath = ".\${part}.new.dat.br"
            $datPath = ".\${part}.new.dat"
            if (Test-Path $brPath) {
                & $BROTLI -d $brPath -o $datPath -v -f 2>&1 | Write-Host
                Remove-Item -Path $brPath -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                throw "Required archive missing: $brPath"
            }
        }

        # Convert Transfer Lists to Raw Images
        Write-Log ""
        Write-Log "Converting transfer lists to raw images..." "Action"
        foreach ($part in $brFiles) {
            $listPath = ".\${part}.transfer.list"
            $datPath = ".\${part}.new.dat"
            $imgPath = ".\${part}.img"
            if ((Test-Path $listPath) -and (Test-Path $datPath)) {
                & $Sdat2Img $listPath $datPath $imgPath 2>&1 | Write-Host
                Remove-Item -Path $datPath -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                throw "Required conversion inputs missing for $part"
            }
        }

        # Convert Input Images to Sparse Format
        Write-Log ""
        Write-Log "Converting raw images to sparse format..." "Action"
        foreach ($part in $brFiles) {
            $rawImg = ".\${part}.img"
            $sparseImg = ".\${part}_sparse.img"
            if (Test-Path $rawImg) {
                & $Img2Simg $rawImg $sparseImg 2>&1 | Write-Host
            } else {
                throw "Raw image missing for sparse conversion: $rawImg"
            }
        }

        # Calculate exact raw sizes for lpmake boundary allocation
        $sysSize = (Get-Item .\system.img).Length
        $venSize = (Get-Item .\vendor.img).Length
        $prdSize = (Get-Item .\product.img).Length
        $odmSize = (Get-Item .\odm.img).Length

        $superSize = 8589934592
        $groupSize = $superSize - 4194304

        # Build RAW super.img for EDL
        Write-Log ""
        Write-Log "Building raw super.img with lpmake..." "Action"
        & $LPMAKE `
            --metadata-size 65536 `
            --super-name super `
            --metadata-slots 2 `
            --device super:${superSize} `
            --group qti_dynamic_partitions:${groupSize} `
            --partition system:readonly:${sysSize}:qti_dynamic_partitions `
            --image system=.\system_sparse.img `
            --partition vendor:readonly:${venSize}:qti_dynamic_partitions `
            --image vendor=.\vendor_sparse.img `
            --partition product:readonly:${prdSize}:qti_dynamic_partitions `
            --image product=.\product_sparse.img `
            --partition odm:readonly:${odmSize}:qti_dynamic_partitions `
            --image odm=.\odm_sparse.img `
            --output .\super.img | Write-Host

        # Cleanup system.img, vendor.img, product.img, odm.img, system_sparse.img, vendor_sparse.img, product_sparse.img, odm_sparse.img
        foreach ($part in @("system", "vendor", "product", "odm")) {
            $Path = ".\${part}.img"
            if (Test-Path $Path) {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }

            $Path = ".\${part}_sparse.img"
            if (Test-Path $Path) {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $superImg = Get-Item ".\super.img" -ErrorAction SilentlyContinue
        if (-not $superImg) {
            throw "Failed to build super.img target."
        } elseif ($superImg.Length -lt ($superSize / 2)) {
            throw "super.img falls short of the minimum size."
        } elseif ($superImg.Length -eq 0) {
            throw "super.img was created but is 0 bytes (empty file)."
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

        # Flash Firmware Partitions via EDL
        $xblSuffix = if ($SelectedFirehose -eq 2) { "_ddr5" } else { "" }
        $flashMap = @(
            @{ Part = "boot"; Path = ".\boot.img" },
            @{ Part = "recovery"; Path = ".\recovery.img" },
            @{ Part = "dtbo"; Path = ".\firmware-update\dtbo.img" },
            @{ Part = "vbmeta"; Path = ".\firmware-update\vbmeta.img" },
            @{ Part = "abl"; Path = ".\firmware-update\abl.elf" },
            @{ Part = "aop"; Path = ".\firmware-update\aop.mbn" },
            @{ Part = "tz"; Path = ".\firmware-update\tz.mbn" },
            @{ Part = "hyp"; Path = ".\firmware-update\hyp.mbn" },
            @{ Part = "devcfg"; Path = ".\firmware-update\devcfg.mbn" },
            @{ Part = "dsp"; Path = ".\firmware-update\dspso.bin" },
            @{ Part = "modem"; Path = ".\firmware-update\NON-HLOS.bin" },
            @{ Part = "bluetooth"; Path = ".\firmware-update\BTFM.bin" },
            @{ Part = "qupfw"; Path = ".\firmware-update\qupv3fw.elf" },
            @{ Part = "imagefv"; Path = ".\firmware-update\imagefv.elf" },
            @{ Part = "cmnlib"; Path = ".\firmware-update\cmnlib.mbn" },
            @{ Part = "cmnlib64"; Path = ".\firmware-update\cmnlib64.mbn" },
            @{ Part = "xbl"; Path = ".\firmware-update\xbl$xblSuffix.elf" },
            @{ Part = "xbl_config"; Path = ".\firmware-update\xbl_config$xblSuffix.elf" },
            @{ Part = "vbmeta_system"; Path = ".\firmware-update\vbmeta_system.img" },
            @{ Part = "super"; Path = ".\super.img" }
        )

        foreach ($item in $flashMap) {
            if (Test-Path $item.Path) {
                $sCMDLine = "write-part $($item.Part) $($item.Path)"
                $logMsg = "Flashing firmware ${cCyan}$($item.Part)${cReset} to device..."

                Invoke-EdlCommandWithRetry -CommandLine $sCMDLine -LogMessage $logMsg -ItemLabel $item.Part -ActionName "flashing partition"
            } else {
                Write-Log "Skipping missing non-critical image file: $($item.Path)" "Warning"
            }
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($pushedLocation) {
            Pop-Location
        }

        # Safely remove extracted files if created from archive input
        if ($isTempExtraction -and (Test-Path -Path $extractedFolder)) {
            Write-Log ""
            Write-Log "Cleaning up temporary directory '${cCyan}${extractedFolder}${cReset}'..." "Action"
            Remove-Item -Path $extractedFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($lastError.Message -notlike "*Abort*") {
        Play-BeepBeep
    }

    if ($success) {
        Write-Log "Device has rollbacked successfully." "Success"

        $choice = Read-HostLog "Would you like to reboot to system? [${cYellow}Y${cReset}/n]"
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

function Prepare-Firmware {    
    $FirmwareData = [ordered]@{
        "Pico 4"     = [ordered]@{
            "Global"  = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.13.8" = "https://lf-stone-iot-my.dlpicovr.com/obj/stone-iot-my/5.13.8-202609021949-RELEASE-user-phoenix-b10102-5cc013c385.zip"
                    "5.13.7" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.7-202510301735-RELEASE-user-phoenix-b9665-42be801fae.zip"
                    "5.13.3" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.3-202507030112-RELEASE-user-phoenix-b9480-6746cfb44c.zip"
                    "5.13.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.2-202506120743-RELEASE-user-phoenix-b9458-40cdda249c.zip"
                    "5.12.0" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.12.0-202412240712-RELEASE-user-phoenix-b9053-6468a45872.zip"
                    "5.11.2" = "https://static.us-pui.picovr.com/5.11.2-202409110320-RELEASE-user-phoenix-b8729-c376dd9f4c.zip"
                    "5.11.1" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.11.1-202408281328-RELEASE-user-phoenix-b8620-54688783a7.zip"
                    "5.9.9"  = "https://static.us-pui.picovr.com/5.9.9-202408300231-RELEASE-user-phoenix-b8638-d1796ec251.zip"
                    "5.9.8"  = "https://static.us-pui.picovr.com/5.9.8-202406140215-RELEASE-user-phoenix-b8266-6d08c202c9.zip"
                    "5.9.2"  = "https://static.us-pui.picovr.com/5.9.2-202403020343-RELEASE-user-phoenix-b7710-fb66acdc51.zip"
                    "5.9.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.1-202401171309-RELEASE-user-phoenix-b7502-2df0deb43f.zip"
                    "5.9.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.0-202401110404-RELEASE-user-phoenix-b7425-85edfedf03.zip"
                    "5.8.2"  = "https://static.us-pui.picovr.com/5.8.2-202310121309-RELEASE-user-phoenix-b6292-09d46f3777.zip"
                    "5.8.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.8.0-20230907-SEKOSA.falconcv3plusoversea-user/202309202309/5.8.0-202309201937-RELEASE-user-phoenix-b6076-56c1e9da71.zip"
                    "5.7.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKOSA.falconcv3plusoversea-user/202308230205/5.7.2-202308222237-RELEASE-user-phoenix-b5653-7220475cd5.zip"
                    "5.7.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKOSA.falconcv3plusoversea-user/202308042218/5.7.1-202308041830-RELEASE-user-phoenix-b5295-b0b9317377.zip"
                    "5.7.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_mol_phoenix-rom-pui-5.0.0-SEKOSA.falconcv3plusoversea-user/202306271745/5.7.0-202306271628-RELEASE-user-phoenix-b4692-ca15d7c21c.zip"
                    "5.6.1"  = "https://static.us-pui.picovr.com/5.6.1-202305240403-RELEASE-user-phoenix-b4346-fc60348a73.zip"
                    "5.6.0"  = "https://static.us-pui.picovr.com/5.6.0-202305190440-RELEASE-user-phoenix-b4261-1a0a729e58.zip"
                    "5.5.0"  = "https://static.us-pui.picovr.com/5.5.0-202304070244-RELEASE-user-phoenix-b3843-412cf6f56c.zip"
                    "5.4.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.4.0-20230201-SEKOSA.falconcv3plusoversea-user/202302171510/5.4.0-202302171231-RELEASE-user-phoenix-b3159-21724b5b8e.zip"
                    "5.3.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKOSA.falconcv3plusoversea-user/202301072132/5.3.2-202301071817-RELEASE-user-phoenix-b2705-0d2c0cb6ec.zip"
                    "5.3.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKOSA.falconcv3plusoversea-user/202301052007/5.3.1-202301051855-RELEASE-user-phoenix-b2672-e5008f4620.zip"
                    "5.2.7"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.2.0-20221021-SEKOSA.falconcv3plusoversea-user/202212020659/5.2.7-202212020445-RELEASE-user-phoenix-b2122-a15f46c085.zip"
                }
                "NON-OEM" = [ordered]@{
                    "5.13.8" = "https://lf-stone-iot-my.dlpicovr.com/obj/stone-iot-my/5.13.8-202609031155-RELEASE-user-phoenix-b10113-8e443f50c3.zip"
                    "5.13.7" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.7-202510301739-RELEASE-user-phoenix-b9666-26140cfa0d.zip"
                    "5.13.3" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.3-202507030047-RELEASE-user-phoenix-b9479-aa79997682.zip"
                    "5.13.2" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.2-202506120651-RELEASE-user-phoenix-b9456-87235e7686.zip"
                    "5.12.0" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.12.0-202412240315-RELEASE-user-phoenix-b9051-1f2c7043f5.zip"
                    "5.11.2" = "https://static.us-pui.picovr.com/5.11.2-202409110150-RELEASE-user-phoenix-b8727-cf87d6eb11.zip"
                    "5.11.1" = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.11.1-202408281327-RELEASE-user-phoenix-b8619-0fbe2660e6.zip"
                    "5.9.2"  = "https://static.us-pui.picovr.com/5.9.2-202403020025-RELEASE-user-phoenix-b7699-7d61a64f70.zip"
                    "5.9.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.1-202401171316-RELEASE-user-phoenix-b7504-4facd867b3.zip"
                    "5.9.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.0-202401110244-RELEASE-user-phoenix-b7416-ab85825a0c.zip"
                    "5.8.2"  = "https://static.us-pui.picovr.com/5.8.2-202310121534-RELEASE-user-phoenix-b6298-a9bbe55c2f.zip"
                    "5.8.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.8.0-20230907-SEKSA.falconcv3plusoversea-user/202309202029/5.8.0-202309201816-RELEASE-user-phoenix-b6075-284a824fac.zip"
                    "5.7.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKSA.falconcv3plusoversea-user/202308230039/5.7.2-202308222235-RELEASE-user-phoenix-b5652-af1d1e8635.zip"
                    "5.7.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.7.0-20230707-SEKSA.falconcv3plusoversea-user/202308042046/5.7.1-202308041842-RELEASE-user-phoenix-b5296-f92724093a.zip"
                    "5.7.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_mol_phoenix-rom-pui-5.0.0-SEKSA.falconcv3plusoversea-user/202306271808/5.7.0-202306271630-RELEASE-user-phoenix-b4695-51fe5d38c1.zip"
                    "5.6.0"  = "https://static.us-pui.picovr.com/5.6.0-202305190206-RELEASE-user-phoenix-b4256-a8a60c5b55.zip"
                    "5.5.0"  = "https://static.us-pui.picovr.com/5.5.0-202304070533-RELEASE-user-phoenix-b3850-bf9813ff5d.zip"
                    "5.4.0"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.4.0-20230201-SEKSA.falconcv3plusoversea-user/202302171826/5.4.0-202302171557-RELEASE-user-phoenix-b3162-3d2f0dbe1b.zip"
                    "5.3.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKSA.falconcv3plusoversea-user/202301072002/5.3.2-202301071642-RELEASE-user-phoenix-b2704-ae2fa5f1b3.zip"
                    "5.3.1"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.3.0-20221229-SEKSA.falconcv3plusoversea-user/202301051838/5.3.1-202301051632-RELEASE-user-phoenix-b2667-6c560f9e2b.zip"
                    "5.2.7"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.2.0-20221021-SEKSA.falconcv3plusoversea-user/202212020623/5.2.7-202212020323-RELEASE-user-phoenix-b2119-09638d5e07.zip"
                    "5.2.2"  = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_phoenix-mol-pui-5.2.0-20221031-SEKSA.falconcv3plusoversea-user/202211180735/5.2.2-202211180529-RELEASE-user-phoenix-b1937-50134e8495.zip"
                }
            }
            "Chinese" = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.13.7" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.7-202510300008-RELEASE-user-phoenix-b9650-de69e61ba0.zip"
                    "5.13.6" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.6-202509181840-RELEASE-user-phoenix-b9584-727f2cd83b.zip"
                    "5.13.5" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.5-202508290239-RELEASE-user-phoenix-b9540-2ea26472d7.zip"
                    "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.3-202507021009-RELEASE-user-phoenix-b9472-d668fe19ea.zip"
                    "5.13.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120253-RELEASE-user-phoenix-b9448-3dd5f7afa1.zip"
                    "5.13.1" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.1-202505230516-RELEASE-user-phoenix-b9409-b8da6c97d7.zip"
                    "5.13.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.0-202505140057-RELEASE-user-phoenix-b9370-c1d8dd6122.zip"
                    "5.12.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.12.0-202412240356-RELEASE-user-phoenix-b9052-9bb67bbbfe.zip"
                    "5.11.2" = "https://alistatic.pui.picovr.com/5.11.2-202409110154-RELEASE-user-phoenix-b8728-142817eb57.zip"
                    "5.11.1" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.1-202408281321-RELEASE-user-phoenix-b8618-5c3d80b194.zip"
                    "5.11.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.0-202408201621-RELEASE-user-phoenix-b8563-a8e13df299.zip"
                    "5.9.9"  = "https://alistatic.pui.picovr.com/5.9.9-202408300028-RELEASE-user-phoenix-b8636-4aab325299.zip"
                    "5.9.8"  = "https://alistatic.pui.picovr.com/5.9.8-202406140037-RELEASE-user-phoenix-b8264-65154b9b88.zip"
                    "5.9.2"  = "https://alistatic.pui.picovr.com/5.9.2-202403020318-RELEASE-user-phoenix-b7708-5a0fa763a9.zip"
                    "5.9.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.1-202401171310-RELEASE-user-phoenix-b7503-9741d1c28b.zip"
                    "5.9.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.0-202401102317-RELEASE-user-phoenix-b7414-59528ceb9d.zip"
                    "5.8.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.2-202310121346-RELEASE-user-phoenix-b6296-1d0490fbc5.zip"
                    "5.8.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.0-202309201640-RELEASE-user-phoenix-b6072-bd5b0e292e.zip"
                    "5.7.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.2-202308222102-RELEASE-user-phoenix-b5651-f9762f8b82.zip"
                    "5.7.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.1-202308041817-RELEASE-user-phoenix-b5293-a229821078.zip"
                    "5.7.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.0-202307190236-RELEASE-user-phoenix-b4969-0a485cf6b8.zip"
                    "5.6.1"  = "https://alistatic.pui.picovr.com/5.6.1-202305240156-RELEASE-user-phoenix-b4342-34eeaf98f6.zip"
                    "5.6.0"  = "https://alistatic.pui.picovr.com/5.6.0-202305190627-RELEASE-user-phoenix-b4262-ef635462e7.zip"
                    "5.5.0"  = "https://alistatic.pui.picovr.com/5.5.0-202304070526-RELEASE-user-phoenix-b3849-fa629c69ff.zip"
                    "5.4.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.0-202302082133-RELEASE-user-phoenix-b3033-575cb027b3.zip"
                    "5.3.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.3.0-202212230826-RELEASE-user-phoenix-b2426-ed73804a5e.zip"
                }
                "NON-OEM" = [ordered]@{
                    "5.13.7" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.7-202510300015-RELEASE-user-phoenix-b9651-cb5ad9d7db.zip"
                    "5.13.6" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.6-202509181846-RELEASE-user-phoenix-b9585-d24598dd04.zip"
                    "5.13.5" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.5-202508290024-RELEASE-user-phoenix-b9536-a265297b26.zip"
                    "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.3-202507020958-RELEASE-user-phoenix-b9471-68dd78c7db.zip"
                    "5.13.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120434-RELEASE-user-phoenix-b9452-4a4dd3dcb8.zip"
                    "5.13.1" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.1-202505230240-RELEASE-user-phoenix-b9407-16f4a39dad.zip"
                    "5.13.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.0-202505140057-RELEASE-user-phoenix-b9369-02ca58377e.zip"
                    "5.12.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.12.0-202412240020-RELEASE-user-phoenix-b9048-1e2b1b2b20.zip"
                    "5.11.2" = "https://alistatic.pui.picovr.com/5.11.2-202409110014-RELEASE-user-phoenix-b8724-df7554f9e7.zip"
                    "5.11.1" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.1-202408281328-RELEASE-user-phoenix-b8621-43b247e3d2.zip"
                    "5.11.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.0-202408201622-RELEASE-user-phoenix-b8565-054d24f0fb.zip"
                    "5.9.2"  = "https://alistatic.pui.picovr.com/5.9.2-202403020013-RELEASE-user-phoenix-b7697-1bd8e00f8c.zip"
                    "5.9.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.1-202401171556-RELEASE-user-phoenix-b7505-8ca9312592.zip"
                    "5.9.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.0-202401102315-RELEASE-user-phoenix-b7413-678f03f880.zip"
                    "5.8.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.2-202310121535-RELEASE-user-phoenix-b6299-a814249094.zip"
                    "5.8.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.0-202309201937-RELEASE-user-phoenix-b6077-7bc072e754.zip"
                    "5.7.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.2-202308222102-RELEASE-user-phoenix-b5650-646a478a27.zip"
                    "5.7.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.1-202308041820-RELEASE-user-phoenix-b5294-8648d231e4.zip"
                    "5.7.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.0-202307190415-RELEASE-user-phoenix-b4974-695fd34644.zip"
                    "5.6.0"  = "https://alistatic.pui.picovr.com/5.6.0-202305190040-RELEASE-user-phoenix-b4252-81463e6b04.zip"
                    "5.5.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.0-202303210046-RELEASE-user-phoenix-b3598-75d3c842d2.zip"
                    "5.4.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.0-202302091032-RELEASE-user-phoenix-b3046-e076814e50.zip"
                    "5.3.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.3.1-202301051635-RELEASE-user-phoenix-b2669-c435f2dfde.zip"
                    "5.2.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.2.1-202211111309-RELEASE-user-phoenix-b1805-ef43d0fc06.zip"
                    "5.2.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.2.0-202210211528-RELEASE-user-phoenix-b1268-85f38c9a6d.zip"
                }
            }
        }
        "Pico Neo 3" = [ordered]@{
            "Global"   = [ordered]@{
                "5.13.7"       = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.7.0-202510301731-RELEASE-user-neo3-b3527-a84e92f190.zip"
                "5.13.3"       = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.13.3.0-202507031601-RELEASE-user-neo3-b3446-5418c43b4d.zip"
                "5.12.2"       = "https://static.us-pui.picovr.com/5.12.2.0-202412240022-RELEASE-user-neo3-b3199-7b62ef57a2.zip"
                "5.11.3"       = "https://static.us-pui.picovr.com/5.11.3.0-202409110016-RELEASE-user-neo3-b3009-b26306c648.zip"
                "5.9.9"        = "https://static.us-pui.picovr.com/5.9.9.0-202409100009-RELEASE-user-neo3-b3003-0eb48d3eb2.zip"
                "5.9.8"        = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.8.0-202406140016-RELEASE-user-neo3-b2785-d4423088ed.zip"
                "5.9.5"        = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/5.9.5.0-202403020351-RELEASE-user-neo3-b2505-7a2f1f044d.zip"
                "5.8.4"        = "https://static.us-pui.picovr.com/5.8.4.0-202310092224-RELEASE-user-neo3-b1977-e4688d78c8.zip"
                "5.7.5"        = "https://static.us-pui.picovr.com/5.7.5.0-202308042231-RELEASE-user-neo3-b1648-424b2c4282.zip"
                "5.6.3"        = "https://static.us-pui.picovr.com/5.6.3.0-202305190207-RELEASE-user-neo3-b1248-e9b86b34e8.zip"
                "5.4.0"        = "https://static.us-pui.picovr.com/5.4.0.0-202302161231-RELEASE-user-neo3-b897-e145156c6b.zip"
                "5.3.1"        = "https://static.us-pui.picovr.com/5.3.1.0-202301032255-RELEASE-user-neo3-b756-6de3f4fa71.zip"
                "4.8.19"       = "https://static.us-pui.picovr.com/4.8.19-202212231111-RELEASE-user-neo3-b2635-08a834cf61.zip"
                "4.8.15"       = "https://zstatic.us-pui.picovr.com/syspackage_web/4.8.15-202208221027-RELEASE-user-neo3-b1582-8d6ba97e7c.zip"
                "4.8.0"        = "https://static.us-pui.picovr.com/SEKSA-pico_rls_neo3-mol-tob-pui-4.8.0-20220622-falconcv3-user-20221017-225305-32g-b1981.zip"
                "4.7.1.7"      = "https://lf-stone-iot-va.dlpicovr.com/obj/stone-iot-us/ota-out/pico_oversea_rls_neo3-mol-pui4.7.0-20220613-SEKSA.falconcv3apollo-user/202207041237/4.7.1.7-202207041053-RELEASE-user-neo3-b370-60ad3df352.zip"
                "4.6.10.81.10" = "https://bytedance.larkoffice.com/file/boxcnZQe7nfa79SSu9sxq84H2mb"
                "4.6.3"        = "https://zstatic.us-pui.picovr.com/syspackage_web/update_PicoNeo3_4.6.3-202203312043-RELEASE-user-neo3-b678-55ecdee5d1_SEKSA-B678.zip"
            }
            "Chinese"  = [ordered]@{
                "5.13.7" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.7-202510301728-RELEASE-user-neo3-b5902-ddd6d04448.zip"
                "5.13.3" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.3-202507030049-RELEASE-user-neo3-b5819-fd6d64a55d.zip"
                "5.13.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.13.2-202506120456-RELEASE-user-neo3-b5809-52a79f45aa.zip"
                "5.12.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.12.2-202412240359-RELEASE-user-neo3-b5575-5b33f89d1a.zip"
                "5.11.3" = "https://alistatic.pui.picovr.com/5.11.3-202409110149-RELEASE-user-neo3-b5351-cc3c0a2612.zip"
                "5.11.2" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.2-202408281327-RELEASE-user-neo3-b5300-fd6420b7b8.zip"
                "5.11.1" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.1-202408201619-RELEASE-user-neo3-b5273-427bebf884.zip"
                "5.11.0" = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.11.0-202407230226-RELEASE-user-neo3-b5185-2708ed4d7d.zip"
                "5.9.9"  = "https://alistatic.pui.picovr.com/5.9.9-202409100313-RELEASE-user-neo3-b5349-37aaf2be54.zip"
                "5.9.5"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.5-202403020034-RELEASE-user-neo3-b4838-37010dfa96.zip"
                "5.9.4"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.4-202401171311-RELEASE-user-neo3-b4751-af264200bc.zip"
                "5.9.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.3-202401102329-RELEASE-user-neo3-b4713-eb49e76df3.zip"
                "5.9.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.2-202312300344-RELEASE-user-neo3-b4664-25dd847df2.zip"
                "5.9.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.1-202312191901-RELEASE-user-neo3-b4554-8b07e2146b.zip"
                "5.9.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.9.0-202312090328-RELEASE-user-neo3-b4498-204e75274e.zip"
                "5.8.4"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.4-202310092224-RELEASE-user-neo3-b4229-bb75569dbd.zip"
                "5.8.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.3-202309201642-RELEASE-user-neo3-b4187-1b19721fad.zip"
                "5.8.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.1-202309130147-RELEASE-user-neo3-b4140-78e518d2ac.zip"
                "5.8.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.8.0-202308231557-RELEASE-user-neo3-b4004-d76ffa8022.zip"
                "5.7.5"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.5-202308042058-RELEASE-user-neo3-b3885-e308f76ba0.zip"
                "5.7.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.3-202307190627-RELEASE-user-neo3-b3776-f7fc4edf93.zip"
                "5.7.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.2-202307110649-RELEASE-user-neo3-b3723-605bb15e85.zip"
                "5.7.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.1-202306271629-RELEASE-user-neo3-b3649-4700b99abb.zip"
                "5.7.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.7.0-202306201921-RELEASE-user-neo3-b3622-bc35be0cba.zip"
                "5.6.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.3-202305190333-RELEASE-user-neo3-b3484-31441931eb.zip"
                "5.6.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.2-202305101525-RELEASE-user-neo3-b3433-0a4ee1a5cf.zip"
                "5.6.1"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.1-202304240021-RELEASE-user-neo3-b3381-4715c18385.zip"
                "5.6.0"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.6.0-202304181715-RELEASE-user-neo3-b3357-749f1c9d49.zip"
                "5.5.4"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.4-202304060113-RELEASE-user-neo3-b3309-8a1d186f01.zip"
                "5.5.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.3-202303281900-RELEASE-user-neo3-b3222-0bbea8b7fe.zip"
                "5.5.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.5.2-202303210021-RELEASE-user-neo3-b3186-5df5f0d193.zip"
                "5.4.4"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.4-202302161153-RELEASE-user-neo3-b2967-6d52eaeb58.zip"
                "5.4.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.3-202302090023-RELEASE-user-neo3-b2915-5869286510.zip"
                "5.4.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.4.2-202302022115-RELEASE-user-neo3-b2878-1b00056c1a.zip"
                "5.3.4"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.3.4-202301032204-RELEASE-user-neo3-b2760-35084bb960.zip"
                "5.2.3"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.2.3-202212090601-RELEASE-user-neo3-b2475-c8012b4f3e.zip"
                "5.2.2"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/5.2.2-202212020144-RELEASE-user-neo3-b2405-e2f0482a98.zip"
                "4.9.6"  = "https://lf-iot-ota.picovr.com/obj/iot-ota/4.9.6-202212220929-RELEASE-user-neo3-b2617-f1ff139269.zip"
            }
            "Business" = [ordered]@{
                "5.11.3"       = "https://static.us-pui.picovr.com/5.11.3.0-202409120321-RELEASE-user-neo3-b3013-fc9cdfae2a.zip"
                "5.9.9"        = "https://static.us-pui.picovr.com/5.9.9.0-202409100359-RELEASE-user-neo3-b3006-12c1d440db.zip"
                "5.9.8"        = "https://alistatic.pui.picovr.com/5.9.8-202406140226-RELEASE-user-neo3-b5118-4f884113c0.zip"
                "5.9.5"        = "https://static.us-pui.picovr.com/5.9.5.0-202403020325-RELEASE-user-neo3-b2504-f8939b1402.zip"
                "5.8.4"        = "https://static.us-pui.picovr.com/5.8.4.0-202310100638-RELEASE-user-neo3-b1982-6f1bf961f1.zip"
                "5.7.5"        = "https://static.us-pui.picovr.com/5.7.5.0-202308042126-RELEASE-user-neo3-b1647-47a1cf2d65.zip"
                "4.9.6"        = "https://alistatic.pui.picovr.com/4.9.6-202212211251-RELEASE-user-neo3-b2617-df5d579f4f.zip"
                "4.9.3"        = "https://alistatic.pui.picovr.com/4.9.3-202209091733-RELEASE-user-neo3-b1759-7384689bc9.zip"
                "4.8.19"       = "https://static.us-pui.picovr.com/4.8.19-202212221731-RELEASE-user-neo3-b2635-11423d0586.zip"
                "4.6.10.81.10" = "https://bytedance.larkoffice.com/file/boxcnHzucBfoU9PuT9exp3XYhYU"
                "4.6.3"        = "https://zstatic.us-pui.picovr.com/syspackage/update_PicoNeo3_4.6.3-202204010348-RELEASE-user-neo3-b678-1392dddc2b_KSA-B678.zip"
            }
        }
    }

    $header = {
        Write-Header "Select Pico Firmware"
        Write-Log "Change device OS to any version." "Info"
        Write-Log "Use provided ${cCyan}firmware.zip${cReset} file downloaded from this menu in the next step." "Info"
        Write-Log "Depending on the target version, a factory reset may be required to prevent non-bootable states or bootloops." "Warning"
        Write-Log "Always perform a ${cCyan}User Personal Data${cReset} backup before proceed." "Warning"
    }

    Show-MenuTree -MenuData $FirmwareData -HeaderCallback $header
}

function Get-LunsSizeGB {
    $gpt = Execute-EdlCommand "printgpt" -silent -get
    $totalSizeGB = 0
    $lunsSize = $null

    foreach ($line in $gpt) {
        if ($line -match "Backup LBA:\s+(\d+)") {
            $lastLba = [long]$matches[1]
            # Total size of this LUN in GB (assuming 4096 sector size for UFS)
            $totalSizeGB += ($lastLba + 1) * 4096 / 1GB
        }
    }

    if ($totalSizeGB -gt 0) {
        $userdataSize = Get-UserdataSizeGB -fullPartition
        $lunsSize = [math]::Round($totalSizeGB - $userdataSize, 2)
    }

    if ($lunsSize) {
        return $lunsSize
    } else {
        Write-Log "Could not determine userdata partition size" "Error"
        return 0
    }
}

function Get-UserdataSizeGB([switch]$fullPartition) {
    $gpt = Execute-EdlCommand "printgpt --lun 0" -silent -get
    $isUserdataBlock = $false
    $userdataSize = $null
    $obPInfo = $null
    $sizeMiB = $null

    foreach ($line in $gpt) {
        if ($line -match "Name:\s+userdata") {
            $isUserdataBlock = $true
            continue
        }
        # Look for the LBA and Size line following the userdata Name line
        if ($isUserdataBlock -and $line -match "LBA:\s+(\d+)-(\d+)\s+\(Size:\s+([\d.]+)\s+MiB\)") {
            $iStart = [uint64]$matches[1]
            $iEnd = [uint64]$matches[2]
            $sizeMiB = [double]$matches[3]
            $iSectors = ($iEnd + 1) - $iStart
            $userdataSize = [math]::Round($sizeMiB / 1024, 2)

            $obPInfo = [PSCustomObject]@{
                sLabel   = "userdata"
                iLUN     = 0
                iStart   = $iStart
                iEnd     = $iEnd
                iSectors = $iSectors
            }
        } elseif ($isUserdataBlock -and $line -match "Size:\s+([\d.]+)\s+MiB") {
            $sizeMiB = [double]$matches[1]
            $userdataSize = [math]::Round($sizeMiB / 1024, 2)
        }
        # If we hit a new partition or header, reset the flag
        if ($line -match "Name:" -or $line -match "--- GPT Header") {
            $isUserdataBlock = $false
        }
    }

    if (-not $fullPartition -and $obPInfo -and (Get-Command Get-AllocatedRanges -ErrorAction SilentlyContinue)) {
        try {
            $ranges = Get-AllocatedRanges -obPInfo $obPInfo
            if ($null -ne $ranges -and $ranges.Count -gt 0) {
                $totalUsedSectors = [uint64]0
                foreach ($r in $ranges) { $totalUsedSectors += [uint64]$r.Sectors }
                if ($totalUsedSectors -gt 0 -and $totalUsedSectors -lt $obPInfo.iSectors) {
                    # UFS uses 4096-byte sectors
                    $userdataSize = [math]::Round(($totalUsedSectors * 4096) / 1GB, 2)
                    Write-Log "Userdata sparse total: ${cCyan}$($ranges.Count) chunks${cReset}, ${cYellow}$totalUsedSectors sectors${cReset} (${cGreen}$userdataSize GB${cReset} estimated)." "Info"
                }
            }
        } catch {
            Write-Log "Failed to calculate userdata size from ranges: $($_.Exception.Message)" "Warning"
        }
    }

    if ($userdataSize) {
        return $userdataSize
    } else {
        Write-Log "Could not determine userdata partition size" "Error"
        return 0
    }
}

function Verify-DiskSpace([string]$backupMode, [string]$targetPath, [double]$manualSizeGB = 0) {
    if ($manualSizeGB -gt 0) {
        $diskSize = $manualSizeGB
    } else {
        # Determind partition size via EDL
        if ($backupMode -eq "luns") {
            $diskSize = Get-LunsSizeGB
        } elseif ($backupMode -eq "userdata") {
            $diskSize = Get-UserdataSizeGB
        } elseif ($backupMode -eq "userdatafull") {
            $diskSize = Get-UserdataSizeGB -fullPartition
        } elseif ($backupMode -eq "partitions") {
            $diskSize = Get-LunsSizeGB
        }
    }

    # Size 0
    if ($diskSize -eq 0) {
        Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        return $false
    } else {
        $diskSize += 1
    }

    $targetDrivePath = if ($targetPath) { $targetPath } else { $WorkingDir }
    $driveLetter = Split-Path -Path $targetDrivePath -Qualifier

    # Strip trailing colon if needed (e.g., "C:" -> "C")
    $driveName = $driveLetter.TrimEnd(':')
    $targetDrive = Get-PSDrive $driveName -ErrorAction SilentlyContinue

    $freeSpaceGB = if ($targetDrive) {
        [math]::Round($targetDrive.Free / 1GB, 2)
    } else {
        0
    }

    Write-Log "Required disk space: ${cGreen}$diskSize GB${cReset}" "Info"
    Write-Log "Current disk space (${cCyan}Drive ${driveName}${cReset}): ${cGreen}$freeSpaceGB GB${cReset}" "Info"

    if ($freeSpaceGB -lt $diskSize) {
        Write-Log "Free space on drive ${cCyan}${driveLetter}${cReset} is less than the required size (${cCyan}$diskSize GB${cReset})." "Error"
        Write-Log "Please ensure you have enough space on drive ${cCyan}${driveLetter}${cReset} before proceeding." "Error"

        return $false
    } else {
        Write-Log "Please preserve disk space ${cCyan}${diskSize} GB${cReset} on drive ${cCyan}${driveLetter}${cReset} for this process." "Interactive"
        $confirmation = Read-HostLog "Enter to continue, type [${cYellow}C${cReset}] to cancel"
        if ($confirmation -eq 'c') {
            return $false
        }

        return $diskSize - 1
    }
}

function Wait-UserConfirm([string]$backupMode) {
    $waitMinutes = switch ($backupMode) {
        "userdata" { 40 }
        "userdatafull" { 40 }
        "rollback" { 20 }
        default { 10 }
    }

    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the partition." "Warning"
    Write-Log "This process takes about ${cGreen}${waitMinutes} minutes${cReset}, depends on PC power and USB speed." "Warning"
    Write-Log "High speed ${cGreen}USB 3.2${cReset} is recommended." "Warning"
    Write-Log "Device charging is disabled in ${cCyan}EDL${cReset} mode. Make sure the battery is '${cCyan}Fully Charged${cReset}'." "Warning"
    Write-Log ""
    Write-Log "Do not disconnect the device and interrupt the process." "Warning"
    Write-Log "In the ${cCyan}backup process${cReset}, getting interrupted might cause the backup data to collapse, but the device is fine." "Warning"
    Write-Log "In the ${cCyan}restore process${cReset}, getting interrupted might brick the device." "Warning"
    
    $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
    if ($confirmation -ne 'yes') {
        return $false
    }

    return $true
}

function Verify-Backup([string]$backupMode, [string]$folderPath, [int]$diskSize = 6, [switch]$silent) {
    $verifySuccess = $true

    try {
        if ($backupMode -eq "luns") {
            $lunsFiles = @("lun0_complete.bin", "lun1_complete.bin", "lun2_complete.bin", "lun3_complete.bin", "lun4_complete.bin", "lun5_complete.bin")
            foreach ($file in $lunsFiles) {
                if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                    throw "Required backup file missing: $file"
                }
            }
        }

        if ($backupMode -eq "userdata") {
            $requiredGptFiles = @("lun0_gpt_header.bin", "lun1_gpt_header.bin", "lun2_gpt_header.bin", "lun3_gpt_header.bin", "lun4_gpt_header.bin", "lun5_gpt_header.bin")
            foreach ($file in $requiredGptFiles) {
                $filePath = Join-Path $folderPath $file
                if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                    throw "Required userdata file missing or empty: $file"
                }
            }

            # Accept either: sparse manifest + chunk files, OR monolithic lun0_userdata.bin
            $manifestFile = Join-Path $folderPath "userdata_manifest.json"
            if (Test-Path $manifestFile) {
                try {
                    $manifestJson = Get-Content -Path $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($chunk in $manifestJson.chunks) {
                        $chunkPath = Join-Path $folderPath $chunk.file
                        if (-not (Test-Path -Path $chunkPath) -or (Get-Item $chunkPath).Length -eq 0) {
                            throw "Chunk file missing or empty: $($chunk.file)"
                        }
                    }
                } catch {
                    throw "Manifest verification failed: $($_.Exception.Message)"
                }
            } else {
                $monoPath = Join-Path $folderPath "lun0_userdata.bin"
                if (-not (Test-Path -Path $monoPath) -or (Get-Item $monoPath).Length -eq 0) {
                    throw "Required userdata file missing or empty: lun0_userdata.bin"
                }
            }
        }

        if ($backupMode -eq "partitions") {
            $partitionFiles = @("lun0_cache.bin", "lun0_frp.bin", "lun0_keystore.bin", "lun0_metadata.bin", "lun0_misc.bin", "lun0_persist.bin", "lun0_picocfg.bin", "lun0_rawdump.bin", "lun0_recovery.bin", "lun0_ssd.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun0_vm_system.bin", "lun0_vm_systembak.bin", "lun1_last_parti.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_last_parti.bin", "lun2_xblbak.bin", "lun2_xbl_configbak.bin", "lun3_align_to_128k_1.bin", "lun3_cdt.bin", "lun3_ddr.bin", "lun3_last_parti.bin", "lun3_mdmddr.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_apdp.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_devinfo.bin", "lun4_dip.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_featenabler.bin", "lun4_featenablerbak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_keymaster.bin", "lun4_keymasterbak.bin", "lun4_last_parti.bin", "lun4_limits.bin", "lun4_limits_cdsp.bin", "lun4_logdump.bin", "lun4_logfs.bin", "lun4_mdtp.bin", "lun4_mdtpbak.bin", "lun4_mdtpsecapp.bin", "lun4_mdtpsecappbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_msadp.bin", "lun4_multiimgoem.bin", "lun4_multiimgoembak.bin", "lun4_multiimgqti.bin", "lun4_multiimgqtibak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_secdata.bin", "lun4_spunvm.bin", "lun4_storsec.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_uefisecapp.bin", "lun4_uefisecappbak.bin", "lun4_uefivarstore.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin", "lun4_vm_data.bin", "lun4_vm_keystore.bin", "lun4_vm_linux.bin", "lun4_vm_linuxbak.bin", "lun5_align_to_128k_2.bin", "lun5_fsc.bin", "lun5_fsg.bin", "lun5_last_parti.bin", "lun5_mdm1m9kefs1.bin", "lun5_mdm1m9kefs2.bin", "lun5_mdm1m9kefs3.bin", "lun5_mdm1m9kefsc.bin", "lun5_modemst1.bin", "lun5_modemst2.bin")
            foreach ($file in $partitionFiles) {
                $filePath = Join-Path $folderPath $file
                if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                    throw "Required partition file missing or empty: $file"
                }
            }
        }

        if ($backupMode -eq "downgrade") {
            $partitionFiles = @("lun0_recovery.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin")
            foreach ($file in $partitionFiles) {
                $filePath = Join-Path $folderPath $file
                if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                    throw "Required downgrade file missing or empty: $file"
                }
            }
        }

        $folderSize = (Get-ChildItem -Path $folderPath -Recurse | Measure-Object -Property Length -Sum).Sum
        $sizeGB = $folderSize / 1GB
        $sizeFormatted = "{0:N2}" -f $sizeGB

        if ($sizeGB -lt $diskSize) {
            throw "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is less than minimum expected (${cYellow}$diskSize GB${cReset})."
        }

        if (-not $silent) { 
            $typeName = switch ($backupMode) {
                "luns" { "LUNs" }
                "userdata" { "User Data" }
                "partitions" { "Partitions" }
                "downgrade" { "Downgrade Pico 4 / 4 Enterprice / 4 Pro" }
                default { $backupMode }
            }
            Write-Log "Backup verification successful." "Success" 
            Write-Log "Total size: ${cCyan}$sizeFormatted GB${cReset}" "Success" 
            Write-Log "Type: ${cCyan}$typeName${cReset}" "Success" 
        }
    } catch {
        $verifySuccess = $false
        if (-not $silent -and $_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $verifySuccess
}

function Folder-Compression([string]$folderPath) {
    try {
        Write-Header "Folder Compression"

        if (-not (Test-Path -Path $folderPath)) {
            throw "Target path '${cYellow}$folderPath${cReset}' does not exist."
        }

        $fileList = Get-ChildItem -Path $folderPath -Recurse -File -Force -ErrorAction SilentlyContinue
        $maxFileSizeBytes = ($fileList | Measure-Object -Property Length -Maximum).Maximum
        $requiredSpaceGB = [math]::Max(1.0, [math]::Round($maxFileSizeBytes / 1GB, 2))

        Write-Log "Using Windows native ${cCyan}LZX${cReset} algorithm to compress folder for maximum space savings up to ${cGreen}60%${cReset}." "Info"
        Write-Log "Files stay as files, ${cGreen}negligible CPU impact${cReset} during decompression." "Info"
        Write-Log "Required free disk space is for the shadow copy; it will be deleted after the compression finished." "Info"
        Write-Log "This process takes at least ${cGreen}10 minutes${cReset} depends on PC power." "Warning"
        Write-Log ""

        if ($false -eq (Verify-DiskSpace -targetPath $folderPath -manualSizeGB $requiredSpaceGB)) {
            throw "Aborted by disk space verify. No changes have been made."
        }

        Write-Log ""
        Write-Log "You are about to compress folder '${cCyan}${folderPath}${cReset}'"
        $confirmation = Read-HostLog "To proceed, type [${cYellow}YES${cReset}] and press Enter"

        if ($confirmation -ne 'yes') {
            throw "Aborted by user. No changes have been made."
        }

        Write-Log ""
        Write-Log "Scanning target directory..." "Action"

        $totalFiles = $fileList.Count
        if ($totalFiles -eq 0) {
            throw "Folder is empty or contains no readable files."
        }

        $sizeBeforeBytes = ($fileList | Measure-Object -Property Length -Sum).Sum
        $sizeBeforeGB = [math]::Round($sizeBeforeBytes / 1GB, 2)

        Write-Log "Original size: ${cCyan}${sizeBeforeGB} GB${cReset} across ${cCyan}${totalFiles}${cReset} files." "Info"
        Write-Log "Compressing folder using ${cCyan}LZX${cReset}..." "Action"

        & compact.exe /c /s /a /i /f /exe:lzx "$folderPath\*" 2>&1 | ForEach-Object {
            $line = $_.ToString().Trim()

            # Skip blank lines
            if ([string]::IsNullOrWhiteSpace($line)) { return }

            # Log every line returned by compact.exe directly
            Write-Log $line "Action"
        }

        $sizeAfterBytes = [long]0
        foreach ($file in $fileList) {
            $high = 0
            $low = [Native.Win32]::GetCompressedFileSize($file.FullName, [ref]$high)

            if ($low -eq 0xFFFFFFFF -and ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0)) {
                $sizeAfterBytes += $file.Length
            } else {
                $fileCompressedSize = ([long]$high -shl 32) -bor [long]$low
                $sizeAfterBytes += $fileCompressedSize
            }
        }

        # Metrics calculation
        $sizeAfterGB = [math]::Round($sizeAfterBytes / 1GB, 2)
        $savedBytes = $sizeBeforeBytes - $sizeAfterBytes
        $savedGB = [math]::Round($savedBytes / 1GB, 2)

        $ratio = 0
        if ($sizeBeforeBytes -gt 0) {
            $ratio = [math]::Round(($savedBytes / $sizeBeforeBytes) * 100, 2)
        }

        Write-Log ""
        Write-Log "------------------------------------------------" "Info"
        Write-Log "Size Before: ${cYellow}${sizeBeforeGB} GB${cReset}" "Info"
        Write-Log "Size After:  ${cGreen}${sizeAfterGB} GB${cReset}" "Info"

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Compression complete." "Success"
            Write-Log "Total Saved: ${cCyan}${savedGB} GB${cReset} (${cGreen}${ratio}%${cReset})" "Success"
        } else {
            Write-Log "Compression finished with warnings/errors (Exit Code: ${cRed}$LASTEXITCODE${cReset})." "Warning"
            Write-Log "Total Saved: ${cCyan}${savedGB} GB${cReset} (${cYellow}${ratio}%${cReset})" "Info"
        }
        Write-Log "------------------------------------------------" "Info"

        Play-BeepBeep
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function Select-BackupMode {
    Write-Header " Select Backup Mode"
    Write-Log "[${cCyan}1${cReset}] Physical Binary Dump (LUNs)"
    Write-Log "    ${cGray}-> Sector-by-sector clone of physical drives (LUN 0-6).${cReset}"
    Write-Log "    ${cGray}-> Best for unbricking, GPT repair, and low-level recovery.${cReset}"
    Write-Log "    ${cGray}-> Excludes partition of 'userdata'.${cReset}"
    Write-Log ""
    Write-Log "[${cCyan}2${cReset}] Full User Personal Data (UserData)"
    Write-Log "    ${cGray}-> Backup of the full partition 'userdata' only.${cReset}"
    Write-Log "    ${cGray}-> Includes all apps, games, photos, and internal storage files.${cReset}"
    Write-Log "    ${cGray}-> Size depends on device model (e.g., 128/256/512 GB).${cReset}"
    Write-Log ""
    Write-Log "[${cCyan}3${cReset}] Usage Of User Personal Data (Used UserData)"
    Write-Log "    ${cGray}-> Backup of the usage of 'userdata' sector only.${cReset}"
    Write-Log "    ${cGray}-> Includes all apps, games, photos, and internal storage files.${cReset}"
    Write-Log "    ${cGray}-> Size depends on the usage of the device data. Good for a 256/512GB device.${cReset}"
    Write-Log "    ${cYellow}-> This is experimental to reduce the backup disk space. It might be unreliable.${cReset}"
    Write-Log ""
    Write-Log "[${cCyan}4${cReset}] System Partition Dump (Partitions)"
    Write-Log "    ${cGray}-> Individual file per system partition (boot, abl, system, etc.).${cReset}"
    Write-Log "    ${cGray}-> Best for general firmware backup or modding. Excludes 'userdata'.${cReset}"
    Write-Log "    ${cGray}-> Balanced safety and manageable size (~10-15 GB).${cReset}"
    Write-Log ""

    $selection = Read-HostLog "Select an option"
    $mode = $null

    if ($selection -eq "1") {
        $mode = "luns"
    } elseif ($selection -eq "2") {
        $mode = "userdatafull"
    } elseif ($selection -eq "3") {
        $mode = "userdata"
    } elseif ($selection -eq "4") {
        $mode = "partitions"
    }

    if ($null -ne $mode) {
        $inputPath = Read-HostLog "Custom backup folder [${cYellow}A${cReset}], enter to default"
        if ($inputPath -eq 'a') {
            $inputPath = Get-FileOrFolderDialog "Select backup folder" 1
        }

        # Check if user entered text AND whether that path actually exists
        if ([string]::IsNullOrWhiteSpace($inputPath) -or -not (Test-Path -Path $inputPath)) {
            if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
                Write-Log "Custom path '${cCyan}$inputPath${cReset}' does not exist. Falling back to default." "Warning"
                Wait-Continue
            }
            $customPath = $null
        } else {
            $customPath = $inputPath
        }

        return [PSCustomObject]@{ backupMode = $mode; customPath = $customPath }
    }

    Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"

    return $null
}

function Backup-Device($selection) {
    $success = $true
    $lastError = $null
    $backupPath = $null

    try {
        Write-Header "Backup Device"
        $backupMode = $selection.backupMode
        $customPath = $selection.customPath

        # Determine target path
        $basePaths = @{
            "luns"         = $LUNsBackupPath
            "userdata"     = $UserBackupPath
            "userdatafull" = $UserBackupPath
            "partitions"   = $PartitionsBackupPath
        }
        $targetFolder = if (-not ([string]::IsNullOrWhiteSpace($customPath))) { $customPath } else { $basePaths[$backupMode] }
        $backupPath = Join-Path -Path $targetFolder -ChildPath $TimeStamp

        Write-Log "Destination: ${cCyan}${backupPath}${cReset}" "Info"
        if (-not (Wait-UserConfirm $backupMode)) {
            throw "Aborted by user. No changes have been made."
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

        $diskSize = Verify-DiskSpace $backupMode $customPath
        if ($diskSize -eq $false) {
            throw "Aborted by disk space verify. No changes have been made."
        }

        # Start the automated helper - suppress any stray pipeline outputs using [void] or $null =
        switch ($backupMode) {
            "luns" { BackupLUNs $backupPath }
            "userdata" { BackupUserData $backupPath }
            "userdatafull" { BackupUserData $backupPath -fullPartition }
            "partitions" { BackupPartitions $backupPath }
        }

        # Verify folder existence
        if ([string]::IsNullOrEmpty($backupPath) -or -not (Test-Path -Path $backupPath)) {
            throw "Could not find the backup folder in '${cCyan}$backupPath${cReset}'."
        }

        if (-not(Verify-Backup -backupMode $backupMode -folderPath $backupPath -diskSize $diskSize)) {
            throw "Found backup folder at '${cCyan}$( $backupPath )${cReset}', but validation failed."
        }
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    if ($success) {
        Write-Log "Backup: ${cCyan}$( $backupPath )${cReset}" "Success"
        Wait-Continue

        Folder-Compression $backupPath
        Wait-Continue

        $choice = Read-HostLog "Would you like to reboot to system? [${cYellow}Y${cReset}/n]"
        if ($choice -eq 'y') {
            Edl-To-System
        }
    } else {
        if ($backupPath -and (Test-Path -Path $backupPath)) {
            Write-Log "Deleting invalid backup folder..." "Action"
            Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        }
            
        if ($lastError.Message -notlike "*Abort*") {
            Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        }
        Warning-EDL-ManualReboot
    }
}

function Restore-Backup($backupInfo) {
    $success = $true
    $lastError = $null

    try {
        $flashPath = $backupInfo.Path
        $backupMode = $backupInfo.Type
        Write-Header "Restore Device"

        if (-not (Verify-Backup -backupMode $backupMode -folderPath $flashPath)) {
            throw ""
        }

        Write-Log "Source: ${cCyan}$flashPath${cReset}" "Info"
        if (-not (Wait-UserConfirm $backupMode)) {
            throw "Aborted by user. No changes have been made."
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

        # Start the automated helper
        $success = FlashFirmware $flashPath
    } catch {
        $success = $false
        if ($_.Exception.Message) {
            $lastError = $_.Exception
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    if ($success) {
        Write-Log "Device restore successfully" "Success"
            
        $choice = Read-HostLog "Would you like to reboot to system? [${cYellow}Y${cReset}/n]"
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

function Test-DeviceManufacturing {
    try {
        Write-Header "Test Device Manufacturing"

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

        Write-Log "${cCyan}Fetching device properties via ADB...${cReset}" "Action"
    
        try {
            $getpropOutput = adb @("shell", "getprop") 2>&1
        } catch {
            throw "Failed to execute ADB. Ensure ADB is installed and in your PATH."
        }

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($getpropOutput)) {
            throw "ADB command failed or no device detected."
        }

        # Parse getprop output into a hashtable
        $props = @{}
        foreach ($line in $getpropOutput) {
            if ($line -match '^\[([^\]]+)\]:\s*\[([^\]]*)\]$') {
                $props[$matches[1]] = $matches[2]
            }
        }

        # Extract required properties
        $picoTag = $props['ro.pico.tag']
        $buildType = $props['ro.build.type']
        $secureBoot = $props['ro.secure.boot.tag']
        $oemState = $props['ro.oem.state']
        $rawProduct = $props['ro.product.model']

        # Map raw model identifiers to display names
        $product = switch ($rawProduct) {
            "A8110" { "Pico 4" }
            "A8E50" { "Pico 4 Enterprise" }
            "A8Pro" { "Pico 4 Pro" }
            "A9210" { "Pico 4 Ultra" }
            "A7H10" { "Pico Neo 3" }
            "A7E10" { "Pico Neo 3 Pro" }
            default { $rawProduct }
        }

        Write-Header "Test Device Manufacturing"
        Write-Log "Model              : ${cCyan}$product${cReset}"
        Write-Log "ro.pico.tag        : ${cCyan}$picoTag${cReset}"
        Write-Log "ro.build.type      : ${cCyan}$buildType${cReset}"
        Write-Log "ro.secure.boot.tag : ${cCyan}$secureBoot${cReset}"
        Write-Log "ro.oem.state       : ${cCyan}$oemState${cReset}"
        Write-Log ("-" * 35)

        # Tag / Variant Checks
        # Check 'SE' tag (Secure Boot)
        if ($secureBoot -eq "true") {
            Write-Log "Variant contains '${cCyan}SE${cReset}' : ${cGreen}PASS${cReset} (${cYellow}ro.secure.boot.tag = true${cReset})"
        } else {
            Write-Log "Variant contains '${cCyan}SE${cReset}' : ${cRed}MISMATCH${cReset} (${cYellow}Expected ro.secure.boot.tag = true${cReset})"
        }

        # Check 'K' tag (User Build)
        if ($buildType -eq "user") {
            Write-Log "Variant contains '${cCyan}K${cReset}'  : ${cGreen}PASS${cReset} (${cYellow}ro.build.type = user${cReset})"
        } else {
            Write-Log "Variant contains '${cCyan}K${cReset}'  : ${cRed}MISMATCH${cReset} (${cYellow}Expected ro.build.type = user${cReset})"
        }

        # Check 'O' tag (OEM State - Pico 4 / Pro / Enterprise)
        if ($oemState -eq "true") {
            Write-Log "Variant contains '${cCyan}O${cReset}'  : ${cGreen}PASS${cReset} (${cYellow}ro.oem.state = true${cReset})"
            Write-Log "OEM                   : ${cGreen}Yes${cReset}"
        } else {
            Write-Log "Variant contains '${cCyan}O${cReset}'  : ${cRed}MISMATCH${cReset} (${cYellow}Expected ro.oem.state = true${cReset})"
            Write-Log "OEM                   : ${cRed}No${cReset}"
        }

        # Note on SA omission
        if (-not $picoTag.EndsWith("SA")) {
            Write-Log "Tag Structure         : ${cGreen}Valid${cReset} ('${cCyan}SA${cReset}' omitted at end)${cReset}"
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function Show-BackupRestoreMenu {
    $menuQuit = $false
    while (-not $menuQuit) {
        Write-Header "Backup / Restore / Downgrade"
        Write-Log "[${cCyan}1${cReset}] Backup Device"
        Write-Log "[${cCyan}2${cReset}] Restore Device"
        Write-Log "[${cCyan}4${cReset}] Downgrade Device ${cDarkGray}(Legacy)${cReset}"
        Write-Log "[${cCyan}5${cReset}] Rollback OS"
        Write-Log ""
        Write-Log "[${cCyan}t${cReset}] Test Device Manufacturing"
        Write-Log "[${cCyan}c${cReset}] Compress Backup"
        Write-Log "[${cCyan}r${cReset}] Reboot"
        Write-Log "[${cCyan}0${cReset}] Back to Main Menu"

        $selection = Read-HostLog "Select an option"
        switch ($selection) {
            "1" {
                $targetBackup = Select-BackupMode
                if ($null -ne $targetBackup) {
                    Select-Firehose
                    Backup-Device $targetBackup
                }
            }
            "2" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Select-Firehose
                    Restore-Backup $backupInfo
                }
            }
            "4" {
                Prepare-Downgrade
            }
            "5" {
                Select-Firehose
                Prepare-Firmware
                Perform-RollbackOS
            }
            "t" {
                Test-DeviceManufacturing
            }
            "c" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Folder-Compression $backupInfo.Path
                }
            }
            "r" {
                Perform-Reboot
            }
            "0" {
                $menuQuit = $true
            }
            default {
                Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
            }
        }
        if (-not $menuQuit) {
            Wait-Continue "return '${cCyan}Backup / Restore / Downgrade${cReset}'..."
        }
    }
}
