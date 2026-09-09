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

$LUNsBackupPath = "${BackupPath}\luns"
$UserBackupPath = "${BackupPath}\userdata"
$PartitionsBackupPath = "${BackupPath}\partitions"

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

function Select-BackupFolder {
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
        Write-Log "Operation cancelled by user." "Info"
        return $null
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

            return [PSCustomObject]@{
                Path = $pastedPath
                Type = $detectedType
            }
        } else {
            Write-Log "The provided folder does not contain a valid backup set." "Error"
            return $null
        }
    }

    # Proceed with numeric selection
    if ([int]::TryParse($selection, [ref]$null) -and [int]$selection -ge 1 -and [int]$selection -le $backupFolders.Count) {
        $targetBackup = $backupFolders[[int]$selection - 1]
        Write-Log "Selected backup: ${cCyan}$($targetBackup.Name)${cReset} [${cYellow}$($targetBackup.BackupType)${cReset}] ${cGreen}($($targetBackup.CreationTime))${cReset}" "Success"
        Wait-Continue

        return [PSCustomObject]@{
            Path = $targetBackup.FullName
            Type = $targetBackup.BackupType
        }
    }

    Write-Log "Invalid input: [${cYellow}$selection${cReset}]" "Error"
    return $null
}

function Prepare-Downgrade {
    Write-Header "Select Pico Firmware"

    $FirmwareData = [ordered]@{
        "Pico 4/4 Enterprise" = [ordered]@{
            "Global" = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.4.0" = "https://drive.google.com/file/d/1zs66s6-S3K3NinkwEtoEaFokNDIvuBTK/view?usp=sharing"
                }
                "NON-OEM" = [ordered]@{
                    "5.4.0" = "https://drive.google.com/file/d/1KGg35ydXZo-3J0-PGeOrB09mFcUyzC7y/view?usp=sharing"
                }
            }
        }
        "Pico 4 Pro"          = [ordered]@{
            "Global" = [ordered]@{
                "OEM"     = [ordered]@{
                    "5.4.0" = "https://drive.google.com/file/d/1q1pln-9w2Qx8_0KBVnba9os5iD-Pbt7O/view?usp=sharing"
                }
                "NON-OEM" = [ordered]@{
                    "5.4.0" = "https://drive.google.com/file/d/10pTWnO5kjNBtSpraTEAQJEC7-0Malz4d/view?usp=sharing"
                }
            }
        }
    }

    $currentMenu = $FirmwareData
    $path = ""

    while ($currentMenu -is [System.Collections.IDictionary]) {
        $options = @($currentMenu.Keys)
        Write-Log "${cYellow}Select an option${cReset}$path"
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Log " [${cCyan}$( $i + 1 )${cReset}] $($options[$i])"
        }
        Write-Log " [${cCyan}0${cReset}] Cancel"

        $selection = Read-HostLog "Choice [${cYellow}0-$($options.Count)${cReset}], press [${cYellow}Enter]${cReset} to skip"
        if ($selection -eq '0') {
            return 
        } elseif ([string]::IsNullOrWhiteSpace($selection)) {
            break
        }

        if ([int]::TryParse($selection, [ref]$null) -and [int]$selection -le $options.Count) {
            $key = $options[[int]$selection - 1]
            $path += " > ${cCyan}$key${cReset}"
            $currentMenu = $currentMenu[$key]

            Write-Header "Select Pico Firmware"
        } else {
            Write-Header "Select Pico Firmware"
            Write-Log "Invalid selection." "Warning"
        }
    }

    if ($currentMenu -is [string]) {
        $firmwareUrl = $currentMenu
        Write-Log "Firmware selection complete$path" "Success"
        Write-Log "Download Link: ${cCyan}$firmwareUrl${cReset}" "Info"

        $openUrl = Read-HostLog "Would you like to open this URL in your browser? [${cYellow}Y${cReset}/n]"
        if ($openUrl -cin ('Y', 'y')) {
            Start-Process $firmwareUrl
        }
    }

    Write-Log "Using ${cCyan}Restore Device${cReset} menu to perform downgrade." "Info"
    Write-Log "Option 1: Select downloaded ${cCyan}Pico4.7z${cReset} file in ${cCyan}Restore Device${cReset} menu." "Info"
    Write-Log "Option 2: Using ${cCyan}PICO4_GLOBAL_OS_540_Downgrader${cReset} partitions file set." "Info"
    Write-Log "     - Check in '${cCyan}.\helper\Flasher\Flash${cReset}' is it empty or not." "Info"
    Write-Log "         - If folder empty, navigate to '${cCyan}.\UNBRICK\P4_Unbrick.exe${cReset}'. Finish only extraction process and close the program." "Info"
    Write-Log "         - Recheck '${cCyan}.\helper\Flasher\Flash${cReset}' to confirm the partitions file exist." "Info"
    Write-Log "     - Select '${cCyan}.\helper\Flasher\Flash${cReset}' folder in ${cCyan}Restore Device${cReset} menu." "Info"
}

function Prepare-Firmware {
    Write-Header "Select Pico Firmware"
    
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
        Write-Log "${cYellow}Select an option${cReset}$path"
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Log " [${cCyan}$( $i + 1 )${cReset}] $($options[$i])"
        }
        Write-Log " [${cCyan}0${cReset}] Cancel"

        $choice = Read-HostLog "Choice"
        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }

        if ([int]::TryParse($selection, [ref]$null) -and [int]$selection -le $options.Count) {
            $key = $options[[int]$selection - 1]
            $path += " > ${cCyan}$key${cReset}"
            $currentMenu = $currentMenu[$key]
        } else {
            Write-Header "Select Pico Firmware"
            Write-Log "Invalid selection." "Warning"
        }
    }

    if ($currentMenu -is [string]) {
        $firmwareUrl = $currentMenu
        Write-Log "Firmware selection complete$path" "Success"
        Write-Log "Download Link: ${cCyan}$firmwareUrl${cReset}" "Info"

        $openUrl = Read-HostLog "Would you like to open this URL in your browser? [${cYellow}Y${cReset}/n]"
        if ($openUrl -cin ('Y', 'y')) {
            Start-Process $firmwareUrl
        }
    }
}

function Get-LunsSizeGB {
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
            return [math]::Round($totalSizeGB - $userdataSize, 2) + 1
        }
    } catch {
    }

    Write-Log "Could not determine partition size." "Warning"
    return 15
}

function Get-UserdataSizeGB {
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
                return [math]::Round($sizeMiB / 1024, 2) + 1
            }
            # If we hit a new partition or header, reset the flag
            if ($line -match "Name:" -or $line -match "--- GPT Header") {
                $isUserdataBlock = $false
            }
        }
    } catch {
    }

    Write-Log "Could not determine userdata partition size." "Warning"
    Write-Log "Userdata size depends on your device model (e.g., 128GB, 256GB, or 512GB)." "Warning"
    return 110
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
    $waitMinutes = 10

    if ($backupMode -eq "userdata") {
        $waitMinutes = 40
    }

    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the partition." "Warning"
    Write-Log "This process takes at least ${cGreen}${waitMinutes} minutes${cReset}. High speed ${cGreen}USB 3.0${cReset} is recommended." "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"
    Write-Log ""
    Write-Log "Do not disconnect the device and interrupt the process." "Warning"
    Write-Log "In the ${cCyan}backup process${cReset}, getting interrupted might cause the backup data to collapse, but the device is fine." "Warning"
    Write-Log "In the ${cCyan}restore process${cReset}, getting interrupted might brick the device." "Warning"
    Write-Log "This can take a long time, do not panic if it looks stuck." "Warning"
    Write-Log ""
    $confirmation = Read-HostLog "To proceed with rebooting to EDL, type [${cYellow}YES${cReset}] and press Enter"
    if ($confirmation -ne 'yes') {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return $false
    }

    return $true
}

function Verify-Backup([string]$backupMode, [string]$folderPath, [switch]$silent) {
    $verifySuccess = $true

    if ($backupMode -eq "luns") {
        $lunsFiles = @("lun0_complete.bin", "lun1_complete.bin", "lun2_complete.bin", "lun3_complete.bin", "lun4_complete.bin", "lun5_complete.bin")
        foreach ($file in $lunsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "userdata") {
        $userDataFiles = @("lun0_gpt_header.bin", "lun0_userdata.bin", "lun1_gpt_header.bin", "lun2_gpt_header.bin", "lun3_gpt_header.bin", "lun4_gpt_header.bin", "lun5_gpt_header.bin")
        foreach ($file in $userDataFiles) {
            $filePath = Join-Path $folderPath $file
            if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "partitions") {
        $partitionFiles = @("lun0_cache.bin", "lun0_frp.bin", "lun0_keystore.bin", "lun0_metadata.bin", "lun0_misc.bin", "lun0_persist.bin", "lun0_picocfg.bin", "lun0_rawdump.bin", "lun0_recovery.bin", "lun0_ssd.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun0_vm_system.bin", "lun0_vm_systembak.bin", "lun1_last_parti.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_last_parti.bin", "lun2_xblbak.bin", "lun2_xbl_configbak.bin", "lun3_align_to_128k_1.bin", "lun3_cdt.bin", "lun3_ddr.bin", "lun3_last_parti.bin", "lun3_mdmddr.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_apdp.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_devinfo.bin", "lun4_dip.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_featenabler.bin", "lun4_featenablerbak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_keymaster.bin", "lun4_keymasterbak.bin", "lun4_last_parti.bin", "lun4_limits.bin", "lun4_limits_cdsp.bin", "lun4_logdump.bin", "lun4_logfs.bin", "lun4_mdtp.bin", "lun4_mdtpbak.bin", "lun4_mdtpsecapp.bin", "lun4_mdtpsecappbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_msadp.bin", "lun4_multiimgoem.bin", "lun4_multiimgoembak.bin", "lun4_multiimgqti.bin", "lun4_multiimgqtibak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_secdata.bin", "lun4_spunvm.bin", "lun4_storsec.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_uefisecapp.bin", "lun4_uefisecappbak.bin", "lun4_uefivarstore.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin", "lun4_vm_data.bin", "lun4_vm_keystore.bin", "lun4_vm_linux.bin", "lun4_vm_linuxbak.bin", "lun5_align_to_128k_2.bin", "lun5_fsc.bin", "lun5_fsg.bin", "lun5_last_parti.bin", "lun5_mdm1m9kefs1.bin", "lun5_mdm1m9kefs2.bin", "lun5_mdm1m9kefs3.bin", "lun5_mdm1m9kefsc.bin", "lun5_modemst1.bin", "lun5_modemst2.bin")
        foreach ($file in $partitionFiles) {
            $filePath = Join-Path $folderPath $file
            if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "downgrade") {
        $partitionFiles = @("lun0_recovery.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin")
        foreach ($file in $partitionFiles) {
            $filePath = Join-Path $folderPath $file
            if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                $verifySuccess = $false
                break
            }
        }
    }
    
    if ($backupMode -eq "downgradeDDR5") {
        $partitionFiles = @("lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin")
        foreach ($file in $partitionFiles) {
            $filePath = Join-Path $folderPath $file
            if (-not (Test-Path -Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
                $verifySuccess = $false
                break
            }
        }
    }

    if (-not $verifySuccess) {
        if (-not $silent) { Write-Log "Backup verification failed: required backup sets are missing or empty." "Error" }
        return $false
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
        if (-not $silent) { Write-Log "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is less than minimum expected (${cYellow}$minSizeGB GB${cReset})." "Error" }
        return $false
    }

    if (-not $silent) { Write-Log "Backup verification successful. Total size: ${cGreen}$sizeFormatted GB${cReset}" "Success" }
    return $true
}

function Folder-Compression([string]$folderPath) {
    Write-Header "Folder Compression"

    if (-not (Test-Path -Path $folderPath)) {
        Write-Log "Target path '${cYellow}$folderPath${cReset}' does not exist." "Error"
        return
    }

    $fileList = Get-ChildItem -Path $folderPath -Recurse -File -Force -ErrorAction SilentlyContinue
    $maxFileSizeBytes = ($fileList | Measure-Object -Property Length -Maximum).Maximum
    $requiredSpaceGB = [math]::Max(1.0, [math]::Round($maxFileSizeBytes / 1GB, 2))

    if (-not (Verify-DiskSpace -targetPath $folderPath -manualSizeGB $requiredSpaceGB)) {
        return
    }

    Write-Log "Using Windows native ${cCyan}LZX${cReset} algorithm to compress folder for maximum space savings up to ${cGreen}60%${cReset}." "Info"
    Write-Log "Files stay as files, ${cGreen}negligible CPU impact${cReset} during decompression." "Info"
    Write-Log "This process takes at least ${cGreen}10 minutes${cReset}." "Warning"
    Write-Log ""

    Write-Log "You are about to compress folder '${cCyan}${folderPath}${cReset}'"
    $confirmation = Read-HostLog "To proceed, type [${cYellow}YES${cReset}] and press Enter"

    if ($confirmation -eq 'yes') {
        Write-Log ""
        Write-Log "Scanning target directory..." "Action"


        $totalFiles = $fileList.Count
        if ($totalFiles -eq 0) {
            Write-Log "Folder is empty or contains no readable files." "Warning"
            return
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
    } else {
        Write-Log "Folder compression ${cRed}cancelled${cReset} by user." "Warning"
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
        return $false
    }

    if (-not (Verify-DiskSpace $backupMode $customPath)) {
        return $false
    }

    if (-not (Wait-UserConfirm $backupMode)) {
        return $false
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
        Write-Log "Could not find the backup folder in '${cCyan}$backupPath${cReset}'." "Warning"
        Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
        Wait-Continue

        return $false
    }

    $backupFolder = Get-Item -Path $backupPath

    if (Verify-Backup $backupMode $backupFolder.FullName) {
        Write-Log "Detected new backup at: ${cCyan}$( $backupFolder.FullName )${cReset}" "Success"
        Wait-Continue

        Folder-Compression $backupFolder.FullName
        Wait-Continue

        return $true
    } else {
        Write-Log "Found backup folder at '${cCyan}$( $backupFolder.FullName )${cReset}', but validation failed." "Error"
        if (Test-Path -Path $backupFolder.FullName) {
            Write-Log "Deleting invalid backup folder..." "Action"
            Remove-Item -Path $backupFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Wait-Continue

        return $false
    }
}

function Restore-Backup($backupInfo) {
    $flashPath = $backupInfo.Path
    $backupMode = $backupInfo.Type
    Write-Header "Restore Device"

    if (-not (Verify-Backup -backupMode $backupMode -folderPath $flashPath)) {
        return $false
    }

    if (-not (Wait-UserConfirm $backupMode)) {
        return $false
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
        return $false
    }

    # Start the automated helper
    $success = FlashFirmware $flashPath

    if (-not $success) {
        Write-Log "EDL mode might have timed out. Reboot EDL and try again." "Warning"
    }
    Wait-Continue
    
    return $success
}

function Show-BackupRestoreMenu {
    $menuQuit = $false
    while (-not $menuQuit) {
        Write-Header "Backup/Restore Menu"
        Write-Log "[${cCyan}1${cReset}] Backup Device"
        Write-Log "[${cCyan}2${cReset}] Restore Device"
        Write-Log "[${cCyan}3${cReset}] Compress Backup"
        Write-Log "[${cCyan}4${cReset}] Downgrade Device"
        Write-Log "[${cCyan}5${cReset}] Get Firmware"
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
                Prepare-Firmware
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
