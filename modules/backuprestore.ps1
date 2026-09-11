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
        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
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
    } else {
        Write-Log "Extraction failed for ${cYellow}$filePath${cReset}." "Error"
    }
    
    return $destPath
}

function Show-MenuTree([System.Collections.IDictionary]$MenuData, [scriptblock]$HeaderCallback) {
    $currentMenu = $MenuData
    $destinationPath = ""
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
            $outFile = Get-FileOrFolderDialog "Select save location" 1
        
            if (-not $outFile) {
                Write-Log "No save location selected." "Error"
                return $null 
            }

            $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)

            if ([string]::IsNullOrWhiteSpace($fileName)) { 
                $fileName = "firmware.zip" 
            }

            $destinationPath = Join-Path -Path $outFile -ChildPath $fileName
            try {
                Write-Log "Downloading firmware to '${cCyan}$destinationPath${cReset}'..." "Action"
                Invoke-WebRequest -Uri $uri -OutFile $destinationPath

                # Verify download success via disk check
                if ((Test-Path -Path $destinationPath -PathType Leaf) -and ((Get-Item $destinationPath).Length -gt 0)) {
                    Write-Log "Downloaded '${cCyan}$fileName${cReset}' successfully." "Success"
                } else {
                    throw "Downloaded file is missing or empty."
                }
            } catch {
                if ($_.Exception.Message) {
                    Write-Log "$($_.Exception.Message)" "Error"
                }
            } finally {
                Wait-Continue
            }
        }
    }

    return $destinationPath
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

        # Check if user pasted a compressed file
        if ($selection -match '\.(rar|zip|7z)$' -and (Test-Path -Path $selection -PathType Leaf)) {
            $selection = Extract-CompressedFile $selection
        }

        # Check if user pasted a path
        if (Test-Path -Path $selection -PathType Container) {
            $pastedPath = (Get-Item -Path $selection).FullName
            $detectedType = $null

            foreach ($type in @("luns", "userdata", "partitions", "downgrade", "downgradeDDR5")) {
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
                    "downgrade" { "Downgrade Pico 4/4 Enterprice" }
                    "downgradeDDR5" { "Downgrade Pico 4 Pro" }
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

    $null = Show-MenuTree -MenuData $FirmwareData -HeaderCallback $header
}

function Perform-RollbackOS([string]$firmwarePath) {
    $success = $false
    $isTempExtraction = $false
    $extractedFolder = $null
    $pushedLocation = $false
    $lastError = $null

    try {
        Write-Header "Rollback OS"

        if (-not (Wait-UserConfirm "rollback")) {
            throw "Aborted by user. No changes have been made."
        }

        Write-Log ""
        if ((Test-Path -Path $firmwarePath -PathType Leaf)) {
            Write-Log "Using downloaded '${cGreen}$firmwarePath${cReset}' from previous step." "Success"
        } else {
            Write-Log "Select firmware downloaded file." "Warning"
            $firmwarePath = Get-FileOrFolderDialog "Select firmware downloaded file" 0 ".rar, .zip, .7z"
        }

        if (-not (Test-Path -Path $firmwarePath) -or -not ([System.IO.Path]::GetExtension($firmwarePath) -in @('.zip', '.rar', '.7z'))) {
            throw "No firmware file provided."
        }

        $extractedFolder = $firmwarePath
        $fileList = Get-ChildItem -Path $firmwarePath -Recurse -File -Force -ErrorAction SilentlyContinue
        $maxFileSizeBytes = ($fileList | Measure-Object -Property Length -Maximum).Maximum
        $requiredSpaceGB = [math]::Max(1.0, [math]::Round($maxFileSizeBytes / 1GB, 2))

        if (-not (Verify-DiskSpace -targetPath $firmwarePath -manualSizeGB ($requiredSpaceGB * 5))) {
            throw ""
        }
        Wait-Continue

        # Handle archive extraction
        if ($firmwarePath -match '\.(rar|zip|7z)$' -and (Test-Path -Path $firmwarePath -PathType Leaf)) {
            $extractedFolder = Extract-CompressedFile $firmwarePath
            $isTempExtraction = $true
        }

        if (-not (Test-Path -Path $extractedFolder -PathType Container)) {
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

        if (-not (Wait-EdlMode 100)) {
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
                Write-Log ""
                Write-Log "Flashing firmware ${cCyan}$($item.Part)${cReset} to device..." "Action"
                if (-not (Execute-EdlCommand "write-part $($item.Part) $($item.Path)")) {
                    throw "Failed writing partition $($item.Part)"
                }
            } else {
                Write-Log "Skipping missing non-critical image file: $($item.Path)" "Warning"
            }
        }

        $success = $true
    } catch {
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

        if ($lastError.Message -notlike "*Abort*") {
            Play-BeepBeep
        }

        if ($success) {
            Write-Log "Device has rollbacked successfully." "Success"
        } else {
            Write-Log "Rollback process encountered errors." "Error"
        }

        Wait-Continue
    }

    return $success
}

function Prepare-Firmware {    
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

    $header = {
        Write-Header "Select Pico Firmware"
        Write-Log "Change device OS to any version." "Info"
        Write-Log "Use provided ${cCyan}firmware.zip${cReset} file downloaded from this menu in the next step." "Info"
        Write-Log "Depending on the target version, a factory reset may be required to prevent non-bootable states or bootloops." "Warning"
        Write-Log "Always perform a ${cCyan}User Personal Data${cReset} backup before proceed." "Warning"
    }

    return Show-MenuTree -MenuData $FirmwareData -HeaderCallback $header
}

function Get-LunsSizeGB {
    $lunsSize = 15

    try {
        # In EDL mode, use edl-ng to find total sectors across all LUNs
        $gpt = Execute-EdlCommand "printgpt" -silent $true
        $totalSizeGB = 0

        foreach ($line in $gpt) {
            if ($line -match "Backup LBA:\s+(\d+)") {
                $lastLba = [long]$matches[1]
                # Total size of this LUN in GB (assuming 4096 sector size for UFS)
                $totalSizeGB += ($lastLba + 1) * 4096 / 1GB
            }
        }

        if ($totalSizeGB -gt 0) {
            $userdataSize = Get-UserdataSizeGB
            $lunsSize = [math]::Round($totalSizeGB - $userdataSize, 2) + 1
            throw ""
        }

        throw "Could not determine partition size."
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $lunsSize
}

function Get-UserdataSizeGB {
    $userdataSize = 110

    try {
        # In EDL mode, use edl-ng to find userdata partition size
        $gpt = Execute-EdlCommand "printgpt --lun 0" $true
        $isUserdataBlock = $false

        foreach ($line in $gpt) {
            if ($line -match "Name:\s+userdata") {
                $isUserdataBlock = $true
                continue
            }
            # Look for the Size line following the userdata Name line
            if ($isUserdataBlock -and $line -match "Size:\s+([\d.]+)\s+MiB") {
                $sizeMiB = [double]$matches[1]
                $userdataSize = [math]::Round($sizeMiB / 1024, 2) + 1
                throw ""
            }
            # If we hit a new partition or header, reset the flag
            if ($line -match "Name:" -or $line -match "--- GPT Header") {
                $isUserdataBlock = $false
            }
        }

        throw "Could not determine userdata partition size."
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
            Write-Log "Userdata size depends on your device model (e.g., 128GB, 256GB, or 512GB)." "Warning"
        }
    }

    return $userdataSize
}

function Verify-DiskSpace([string]$backupMode, [string]$targetPath, [double]$manualSizeGB) {
    if ($manualSizeGB -gt 0) {
        $diskSize = $manualSizeGB
    } else {
        if ($backupMode -eq "luns") {
            $diskSize = Get-LunsSizeGB
        } elseif ($backupMode -eq "userdata") {
            $diskSize = Get-UserdataSizeGB
        } elseif ($backupMode -eq "partitions") {
            $diskSize = Get-LunsSizeGB
        }
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
        Wait-Continue

        return $false
    } else {
        Write-Log "Please preserve disk space ${cCyan}${diskSize} GB${cReset} on drive ${cCyan}${driveLetter}${cReset} for this process." "Info"
        Write-Log ""

        return $true
    }
}

function Wait-UserConfirm([string]$backupMode) {
    $waitMinutes = switch ($backupMode) {
        "userdata" { 40 }
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

function Verify-Backup([string]$backupMode, [string]$folderPath, [switch]$silent) {
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
            $userDataFiles = @("lun0_gpt_header.bin", "lun0_userdata.bin", "lun1_gpt_header.bin", "lun2_gpt_header.bin", "lun3_gpt_header.bin", "lun4_gpt_header.bin", "lun5_gpt_header.bin")
            foreach ($file in $userDataFiles) {
                $filePath = Join-Path $folderPath $file
                if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                    throw "Required userdata file missing or empty: $file"
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
        
        if ($backupMode -eq "downgradeDDR5") {
            $partitionFiles = @("lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin")
            foreach ($file in $partitionFiles) {
                $filePath = Join-Path $folderPath $file
                if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                    throw "Required downgradeDDR5 file missing or empty: $file"
                }
            }
        }

        $folderSize = (Get-ChildItem -Path $folderPath -Recurse | Measure-Object -Property Length -Sum).Sum
        $sizeGB = $folderSize / 1GB
        $sizeFormatted = "{0:N2}" -f $sizeGB

        $minSizeGB = switch ($backupMode) {
            "downgrade" { 9 }
            "downgradeDDR5" { 8 }
            "firmware" { 6 }
            default { 12 }
        }

        if ($sizeGB -lt $minSizeGB) {
            throw "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is less than minimum expected (${cYellow}$minSizeGB GB${cReset})."
        }

        if (-not $silent) { 
            Write-Log "Backup verification successful. Total size: ${cGreen}$sizeFormatted GB${cReset}" "Success" 
        }
    } catch {
        $verifySuccess = $false
        if (-not $silent -and $_.Exception.Message) {
            Write-Log "Backup verification failed: required backup sets are missing or empty." "Error"
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

        if (-not (Verify-DiskSpace -targetPath $folderPath -manualSizeGB $requiredSpaceGB)) {
            throw ""
        }

        Write-Log "Using Windows native ${cCyan}LZX${cReset} algorithm to compress folder for maximum space savings up to ${cGreen}60%${cReset}." "Info"
        Write-Log "Files stay as files, ${cGreen}negligible CPU impact${cReset} during decompression." "Info"
        Write-Log "This process takes at least ${cGreen}10 minutes${cReset}." "Warning"
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
    Write-Log "    ${cGray}-> Excludes bulk of UserData to save space (~12-15 GB).${cReset}"
    Write-Log ""
    Write-Log "[${cCyan}2${cReset}] User Personal Data (UserData)"
    Write-Log "    ${cGray}-> Backup of the 'userdata' partition ONLY.${cReset}"
    Write-Log "    ${cGray}-> Includes all apps, games, photos, and internal storage files.${cReset}"
    Write-Log "    ${cGray}-> Size depends on usage (up to 128/256/512 GB).${cReset}"
    Write-Log ""
    Write-Log "[${cCyan}3${cReset}] System Partition Dump (Partitions)"
    Write-Log "    ${cGray}-> Individual file per system partition (boot, abl, system, etc.).${cReset}"
    Write-Log "    ${cGray}-> Best for general firmware backup or modding. Excludes userdata.${cReset}"
    Write-Log "    ${cGray}-> Balanced safety and manageable size (~10-15 GB).${cReset}"
    Write-Log ""

    $selection = Read-HostLog "Select an option"
    $mode = $null

    if ($selection -eq "1") {
        $mode = "luns"
    } elseif ($selection -eq "2") {
        $mode = "userdata"
    } elseif ($selection -eq "3") {
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
    $success = $false
    $backupPath = $null
    $backupFolder = $null

    try {
        Write-Header "Backup Device"
        $backupMode = $selection.backupMode
        $customPath = $selection.customPath

        # Reboot EDL
        if (IsAdbMode) {
            ADB-To-Edl
        } elseif (IsFastbootMode) {
            Fastboot-To-Edl
        } elseif (-not (IsEdlMode)) {
            Warning-EDL
        }

        if (-not (Wait-EdlMode 100)) {
            throw ""
        }

        if (-not (Verify-DiskSpace $backupMode $customPath)) {
            throw ""
        }

        if (-not (Wait-UserConfirm $backupMode)) {
            throw "Aborted by user. No changes have been made."
        }

        # Start the automated helper - suppress any stray pipeline outputs using [void] or $null =
        if ($backupMode -eq "luns") {
            $basePath = if (-not [string]::IsNullOrWhiteSpace($customPath)) { $customPath } else { $LUNsBackupPath }
            $backupPath = Join-Path -Path $basePath -ChildPath $TimeStamp
            BackupLUNs $backupPath
        } elseif ($backupMode -eq "userdata") {
            $basePath = if (-not [string]::IsNullOrWhiteSpace($customPath)) { $customPath } else { $UserBackupPath }
            $backupPath = Join-Path -Path $basePath -ChildPath $TimeStamp
            BackupUserData $backupPath
        } elseif ($backupMode -eq "partitions") {
            $basePath = if (-not [string]::IsNullOrWhiteSpace($customPath)) { $customPath } else { $PartitionsBackupPath }
            $backupPath = Join-Path -Path $basePath -ChildPath $TimeStamp
            BackupPartitions $backupPath
        }

        # Verify folder existence
        if (-not (Test-Path -Path $backupPath)) {
            throw "Could not find the backup folder in '${cCyan}$backupPath${cReset}'."
        }

        $backupFolder = Get-Item -Path $backupPath
        if (Verify-Backup $backupMode $backupFolder.FullName) {
            $success = $true
        } else {
            throw "Found backup folder at '${cCyan}$( $backupFolder.FullName )${cReset}', but validation failed."
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    } finally {
        if ($success) {
            Write-Log "Detected new backup at: ${cCyan}$( $backupFolder.FullName )${cReset}" "Success"
            Wait-Continue
            Folder-Compression $backupFolder.FullName
        } else {
            if (Test-Path -Path $backupFolder.FullName) {
                Write-Log "Deleting invalid backup folder..." "Action"
                Remove-Item -Path $backupFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        }
        Wait-Continue
    }

    return $success
}

function Restore-Backup($backupInfo) {
    $success = $false

    try {
        $flashPath = $backupInfo.Path
        $backupMode = $backupInfo.Type
        Write-Header "Restore Device"

        if (-not (Verify-Backup -backupMode $backupMode -folderPath $flashPath)) {
            throw ""
        }

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

        if (-not (Wait-EdlMode 100)) {
            throw ""
        }

        # Start the automated helper
        $success = FlashFirmware $flashPath

        if (-not $success) {
            Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        }

        Wait-Continue
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $success
}

function Show-BackupRestoreMenu {
    $menuQuit = $false
    while (-not $menuQuit) {
        Write-Header "Backup/Restore/Downgrade"
        Write-Log "[${cCyan}1${cReset}] Backup Device"
        Write-Log "[${cCyan}2${cReset}] Restore Device"
        Write-Log "[${cCyan}3${cReset}] Compress Backup"
        Write-Log "[${cCyan}4${cReset}] Downgrade Device ${cDarkGray}(Legacy)${cReset}"
        Write-Log "[${cCyan}5${cReset}] Rollback OS"
        Write-Log ""
        Write-Log "[${cCyan}r${cReset}] Reboot"
        Write-Log "[${cCyan}0${cReset}] Back to Main Menu"

        $selection = Read-HostLog "Select an option"
        switch ($selection) {
            "1" {
                $targetBackup = Select-BackupMode
                if ($null -ne $targetBackup) {
                    Select-Firehose
                    if ([bool](Backup-Device $targetBackup)) {
                        Edl-To-System
                    } else {
                        Warning-EDL-ManualReboot
                    }
                }
            }
            "2" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Select-Firehose
                    if ([bool](Restore-Backup $backupInfo)) {
                        Edl-To-System
                    } else {
                        Warning-EDL-ManualReboot
                    }
                }
            }
            "3" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Folder-Compression $backupInfo.Path
                }
            }
            "4" {
                Prepare-Downgrade
            }
            "5" {
                Select-Firehose
                $downloadedPath = Prepare-Firmware
                if ([bool](Perform-RollbackOS $downloadedPath)) {
                    Edl-To-System
                } else {
                    Warning-EDL-ManualReboot
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
            Wait-Continue "return to the Backup/Restore menu..."
        }
    }
}
