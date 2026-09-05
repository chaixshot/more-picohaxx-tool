#Requires -Version 5.1

<#
.SYNOPSIS
    Backup and Restore functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for backing up device partitions using edl-ng
    and restoring them.
#>

# --- Backup & Restore Functions ---

$LUNsBackupPath = "${BackupPath}\luns"
$UserBackupPath = "${BackupPath}\userdata"
$PartitionsBackupPath = "${BackupPath}\partitions"

# Define Kernel32 API for reliable NTFS compressed size calculation
if (-not ([System.Management.Automation.PSTypeName]'Native.Win32').Type) {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll", EntryPoint="GetCompressedFileSizeW", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);' -Name 'Win32' -Namespace 'Native'
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
        Write-Host "Available Backup Folders:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $backupFolders.Count; $i++) {
            $folder = $backupFolders[$i]
            Write-Host " [${cCyan}$( $i + 1 )${cReset}] $( $folder.Name ) ${cYellow}[$( $folder.BackupType )]${cReset} ${cGreen}($( $folder.CreationTime ))${cReset}"
        }
        $selection = Read-HostLog "Select a backup folder [${cCyan}1-$( $backupFolders.Count )${cReset}] or paste folder path, [${cCyan}c${cReset}] to cancel"
    } else {
        Write-Log "No backup folders found in default directories." "Warning"
        
        # Prompt using colored helper
        $selection = Read-HostLog "Paste your backup folder path here, or [${cCyan}c${cReset}] to cancel"
    }

    if ($selection -eq 'c') {
        Write-Log "Operation cancelled by user." "Info"
        return $null
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
            Write-Log "Detected valid ${cYellow}$detectedType${cReset} backup at: ${cCyan}$pastedPath${cReset}" "Success"
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

    Write-Log "Invalid selection or path: '$selection'." "Error"
    return $null
}

function Get-LunsSizeGB {
    if (IsAdbMode) {
        try {
            # Query /proc/partitions for total blocks of internal storage (usually sda to sdf)
            $partitions = (& $ADB shell "cat /proc/partitions").Split("`n")
            $totalBlocks = 0
            foreach ($line in $partitions) {
                if ($line -match "\s+(\d+)\s+sd[a-f]$") {
                    $totalBlocks += [long]$matches[1]
                }
            }

            if ($totalBlocks -gt 0) {
                $totalSize = [math]::Round(($totalBlocks * 1KB) / 1GB, 2)
                # Get userdata size to subtract it (since BackupLUNs cuts it off)
                $userdataSize = Get-UserdataSizeGB
                $systemSize = $totalSize - $userdataSize

                if ($systemSize -gt 0 -and $systemSize -lt $totalSize) {
                    return $systemSize + 1
                }
            }
        } catch {
        }
    } elseif (IsEdlMode) {
        try {
            # In EDL mode, use edl-ng to find total sectors across all LUNs
            $gpt = & $EDLNG --loader $FirehoseTargetPath --memory UFS printgpt 2>&1
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
    }

    Write-Log "Could not determine partition size." "Warning"
    return 15
}

function Get-UserdataSizeGB {
    if (IsAdbMode) {
        try {
            # Query mounted /data directory using standard df (in 1K blocks)
            $dfOutput = (& $ADB shell "df -k /data").Split("`n") | Select-Object -Last 1
            $columns = ($dfOutput.Trim()) -split '\s+'

            if ($columns.Count -ge 2 -and $columns[1] -match '^\d+$') {
                $sizeKB = [long]$columns[1]
                return [math]::Round(($sizeKB * 1KB) / 1GB, 2) + 1
            }
        } catch {
        }
    } elseif (IsEdlMode) {
        try {
            # In EDL mode, use edl-ng to find userdata partition size
            $gpt = & $EDLNG --loader $FirehoseTargetPath --memory UFS printgpt --lun 0 2>&1
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
    }

    Write-Log "Could not determine userdata partition size." "Warning"
    Write-Log "Userdata size depends on your device model (e.g., 128GB, 256GB, or 512GB)." "Warning"
    return 110
}

function Get-PartitionsSizeGB {
    if (IsAdbMode) {
        try {
            $partitions = (& $ADB shell "cat /proc/partitions").Split("`n")

            # Find the largest partition on sda (likely userdata) to exclude it
            $maxSdaSize = 0
            $userdataName = ""
            foreach ($line in $partitions) {
                if ($line -match "\s+(\d+)\s+(sda\d+)$") {
                    $size = [long]$matches[1]
                    if ($size -gt $maxSdaSize) {
                        $maxSdaSize = $size
                        $userdataName = $matches[2]
                    }
                }
            }

            $totalBlocks = 0
            foreach ($line in $partitions) {
                # Sum all partitions (sd[a-f][0-9]+) except the detected userdata
                if ($line -match "\s+(\d+)\s+(sd[a-f]\d+)$") {
                    if ($matches[2] -ne $userdataName) {
                        $totalBlocks += [long]$matches[1]
                    }
                }
            }

            if ($totalBlocks -gt 0) {
                return [math]::Round(($totalBlocks * 1KB) / 1GB, 2) + 1
            }
        } catch { }
    } elseif (IsEdlMode) {
        # Can use the same logic as LunsSize in EDL mode since it's an estimate of system partitions
        return Get-LunsSizeGB
    }

    Write-Log "Could not determine partition size." "Warning"
    return 15 # Default system partitions size
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
            $diskSize = Get-PartitionsSizeGB
        }
    }

    $targetDrivePath = if ($targetPath) { $targetPath } else { $PSScriptRoot }
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
        Write-Log "Free space on drive ${cCyan}${driveLetter}${cReset} is less than the required size (${cCyan}$diskSize GB${cReset})!" "Error"
        Write-Log "Please ensure you have enough space on drive ${cCyan}${driveLetter}${cReset} before proceeding." "Error"
        Wait-Continue
        return $false
    } else {
        Write-Log "Please preserve disk space ${cCyan}${diskSize} GB${cReset} on drive ${cCyan}${driveLetter}${cReset} for this process." "Info"
        Write-Host ""

        return $true
    }
}

function Wait-UserConfirm([string]$backupMode) {
    if ($backupMode -eq "luns") {
        $waitMinutes = 5
    } elseif ($backupMode -eq "userdata") {
        $waitMinutes = 40
    } elseif ($backupMode -eq "partitions") {
        $waitMinutes = 10
    }

    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the partition." "Warning"
    Write-Log "This process takes at least ${cGreen}${waitMinutes} minutes${cReset}. High speed ${cGreen}USB 3.0${cReset} is recommended." "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"
    Write-Host ""
    Write-Log "Do not disconnect the device and interrupt the process." "Warning"
    Write-Log "In the ${cCyan}backup process${cReset}, getting interrupted might cause the backup data to collapse, but the device is fine." "Warning"
    Write-Log "In the ${cCyan}restore process${cReset}, getting interrupted might brick the device." "Warning"
    Write-Log "This can take a long time, do not panic if it looks stuck." "Warning"
    Write-Host ""
    Write-Host "To proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES') {
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
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "partitions") {
        $partitonsFiles = @("lun0_cache.bin", "lun0_frp.bin", "lun0_keystore.bin", "lun0_metadata.bin", "lun0_misc.bin", "lun0_persist.bin", "lun0_picocfg.bin", "lun0_rawdump.bin", "lun0_recovery.bin", "lun0_ssd.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun0_vm_system.bin", "lun0_vm_systembak.bin", "lun1_last_parti.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_last_parti.bin", "lun2_xblbak.bin", "lun2_xbl_configbak.bin", "lun3_align_to_128k_1.bin", "lun3_cdt.bin", "lun3_ddr.bin", "lun3_last_parti.bin", "lun3_mdmddr.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_apdp.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_devinfo.bin", "lun4_dip.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_featenabler.bin", "lun4_featenablerbak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_keymaster.bin", "lun4_keymasterbak.bin", "lun4_last_parti.bin", "lun4_limits.bin", "lun4_limits_cdsp.bin", "lun4_logdump.bin", "lun4_logfs.bin", "lun4_mdtp.bin", "lun4_mdtpbak.bin", "lun4_mdtpsecapp.bin", "lun4_mdtpsecappbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_msadp.bin", "lun4_multiimgoem.bin", "lun4_multiimgoembak.bin", "lun4_multiimgqti.bin", "lun4_multiimgqtibak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_secdata.bin", "lun4_spunvm.bin", "lun4_storsec.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_uefisecapp.bin", "lun4_uefisecappbak.bin", "lun4_uefivarstore.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin", "lun4_vm_data.bin", "lun4_vm_keystore.bin", "lun4_vm_linux.bin", "lun4_vm_linuxbak.bin", "lun5_align_to_128k_2.bin", "lun5_fsc.bin", "lun5_fsg.bin", "lun5_last_parti.bin", "lun5_mdm1m9kefs1.bin", "lun5_mdm1m9kefs2.bin", "lun5_mdm1m9kefs3.bin", "lun5_mdm1m9kefsc.bin", "lun5_modemst1.bin", "lun5_modemst2.bin")
        foreach ($file in $partitonsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "downgrade") {
        $partitonsFiles = @("lun0_recovery.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin")
        foreach ($file in $partitonsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }
    
    if ($backupMode -eq "downgradeDDR5") {
        $partitonsFiles = @("lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_xbl_configbak.bin", "lun2_xblbak.bin")
        foreach ($file in $partitonsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if (-not $verifySuccess) {
        if (-not $silent) { Write-Log "Backup verification failed: required backup sets are missing." "Error" }
        return $false
    }

    $folderSize = (Get-ChildItem -Path $folderPath -Recurse | Measure-Object -Property Length -Sum).Sum
    $sizeGB = $folderSize / 1GB
    $sizeFormatted = "{0:N2}" -f $sizeGB

    if ($sizeGB -le 9) {
        if (-not $silent) { Write-Log "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is not greater than 10GB." "Error" }
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
    Write-Host ""

    Write-Host "You are about to compress folder '${cCyan}${folderPath}${cReset}'"
    $confirmation = Read-HostLog "To proceed, type ${cYellow}'YES'${cReset} and press Enter"

    if ($confirmation -eq 'YES') {
        Write-Host ""
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

        Write-Host ""
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
    Write-Host " [${cCyan}1${cReset}] Physical Binary Dump (LUNs)"
    Write-Host "     ${cGray}-> Sector-by-sector clone of physical drives (LUN 0-6).${cReset}"
    Write-Host "     ${cGray}-> Best for unbricking, GPT repair, and low-level recovery.${cReset}"
    Write-Host "     ${cGray}-> Excludes bulk of UserData to save space (~12-15 GB).${cReset}"
    Write-Host ""
    Write-Host " [${cCyan}2${cReset}] User Personal Data (UserData)"
    Write-Host "     ${cGray}-> Backup of the 'userdata' partition ONLY.${cReset}"
    Write-Host "     ${cGray}-> Includes all apps, games, photos, and internal storage files.${cReset}"
    Write-Host "     ${cGray}-> Size depends on usage (up to 128/256/512 GB).${cReset}"
    Write-Host ""
    Write-Host " [${cCyan}3${cReset}] System Partition Dump (Partitions)"
    Write-Host "     ${cGray}-> Individual file per system partition (boot, abl, system, etc.).${cReset}"
    Write-Host "     ${cGray}-> Best for general firmware backup or modding. Excludes userdata.${cReset}"
    Write-Host "     ${cGray}-> Balanced safety and manageable size (~10-15 GB).${cReset}"
    Write-Host ""

    $choice = Read-HostLog "Select an option"

    if ($choice -eq "1") {
        return "luns"
    } elseif ($choice -eq "2") {
        return "userdata"
    } elseif ($choice -eq "3") {
        return "partitions"
    }

    return $null
}

function Backup-Device([string]$backupMode) {
    Write-Header "Backup Device"

    if (-not (Verify-DiskSpace $backupMode)) {
        return $false
    }

    if (-not (Wait-UserConfirm $backupMode)) {
        return $false
    }

    # Reboot EDL
    if (IsAdbMode) {
        ADB-To-Edl
    } elseif (-not (IsEdlMode)) {
        Warning-EDL
    }

    if (-not (Wait-EdlMode 100)) {
        return $false
    }

    # Start the automated helper - suppress any stray pipeline outputs using [void] or $null =
    if ($backupMode -eq "luns") {
        BackupLUNs
        $backupPath = Join-Path -Path $LUNsBackupPath -ChildPath $TimeStamp
    } elseif ($backupMode -eq "userdata") {
        BackupUserData
        $backupPath = Join-Path -Path $UserBackupPath -ChildPath $TimeStamp
    } elseif ($backupMode -eq "partitions") {
        BackupPartitions
        $backupPath = Join-Path -Path $PartitionsBackupPath -ChildPath $TimeStamp
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
        Write-Host " [${cCyan}1${cReset}] Backup Device"
        Write-Host " [${cCyan}2${cReset}] Restore Device"
        Write-Host " [${cCyan}3${cReset}] Compress Backup"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}0${cReset}] Back to Main Menu"

        $choice = Read-HostLog "Select an option"

        switch ($choice) {
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
            "r" {
                Perform-Reboot
            }
            "0" {
                $menuQuit = $true
            }
            default {
                Write-Log "Invalid option. Please try again." "Warning"
            }
        }
        if (-not $menuQuit) {
            Wait-Continue "return to the Backup/Restore menu..."
        }
    }
}
