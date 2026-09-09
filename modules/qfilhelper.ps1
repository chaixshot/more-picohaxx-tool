#Requires -Version 5.1

<#
.SYNOPSIS
    EDL Helper logic for backing up and flashing devices.
.DESCRIPTION
    Provides functions for backing up LUNs and individual partitions using edl-ng.
#>

# --- Local Variables ---
$edlTMP = Join-Path $WorkingDir "tools\TMP"

$galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
$gaLunsOnline = @()
$gsBackupDir = $null
$geFailed = 0 # 0: NOERR, 1: FAILD, 2: ABORT

# --- Functions ---

function BackupLUNs([string]$backupPath) {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder $backupPath

    # Read GPT Headers to get partition layouts for each LUN
    if (-not (ReadGPTHeaders -isTemp $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $isExec = $false

    # Iterate through LUN 0 to 5
    $totalParts = 5

    for ($iCnt = 0; $iCnt -le $totalParts; $iCnt++) {
        $obPInfo = [PSCustomObject]@{
            iLUN     = $iCnt
            iStart   = 0
            iEnd     = 0
            sLabel   = "complete"
            iSectors = 0
        }

        if (-not (CalcBounds $obPInfo)) {
            break
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false

        Write-Log ""
        Write-Log "[$( $iCnt + 1 )/$( $totalParts + 1 )] Backing up partition '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

        if (-not (Execute-EdlCommand $sCMDLine)) {
            $script:geFailed = 1
            break
        }

        $isExec = $true
    }

    CleanUpBackupFolder
    ProcessCompleted -isExec $isExec
}

function BackupUserData([string]$backupPath) {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder $backupPath

    # Read GPT Headers with sorting enabled to allow looking up partition names
    if (-not (ReadGPTHeaders -isTemp $false -isSort $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $obPInfo = [PSCustomObject]@{
        sLabel   = "userdata"
        iLUN     = $null
        iStart   = 0
        iEnd     = 0
        iSectors = 0
    }

    if (-not (LookUpNames $obPInfo)) {
        Write-Log "Failed to resolve LUN and sectors for partition 'userdata'." "Error"
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false

    Write-Log ""
    Write-Log "[1/1] Backing up partition '${cCyan}lun0_userdata.bin${cReset}'..." "Action"

    if (-not (Execute-EdlCommand $sCMDLine)) {
        $script:geFailed = 1
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    CleanUpBackupFolder
    ProcessCompleted -isExec $true
}

function BackupPartitions([string]$backupPath) {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder $backupPath

    # Read GPT Headers to populate $galoLookUp
    if (-not (ReadGPTHeaders -isTemp $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $isExec = $false
    $totalParts = 97
    $iCnt = 0

    # Iterate through LUN 0 to 6
    for ($iLUN = 0; $iLUN -le 5; $iLUN++) {
        foreach ($part in $galoLookUp[$iLUN]) {
            # Skip userdata partition as it's handled separately
            if ($part.sLabel -eq "userdata") {
                continue
            }

            $obPInfo = [PSCustomObject]@{
                iLUN     = $part.iLUN
                sLabel   = $part.sLabel
                iStart   = $part.iStart
                iEnd     = $part.iEnd
                iSectors = $part.iSectors
            }

            $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false
            $iCnt++
            
            Write-Log ""
            Write-Log "[$iCnt/$totalParts] Backing up partition '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

            if (-not (Execute-EdlCommand $sCMDLine)) {
                $script:geFailed = 1
                break
            }
            $isExec = $true
        }

        if ($geFailed -eq 1) {
            break
        }
    }

    CleanUpBackupFolder
    ProcessCompleted -isExec $isExec
}

function FlashFirmware([string]$flashPath) {
    if ( [string]::IsNullOrEmpty($flashPath)) {
        return $false
    }

    if (-not (ValidateCQF)) {
        return $false
    }

    ResetLookUp

    # Read GPT Headers to get partition layouts for each LUN
    if (-not (ReadGPTHeaders -isTemp $true)) {
        ProcessCompleted -isExec $false
        return $false
    }

    $flashList = LoadFileList -FlashPath $flashPath
    if ($flashList.Count -eq 0) {
        Write-Log "No firmware files found in '${cCyan}${flashPath}${cCyan}'." "Error"
        ProcessCompleted -isExec $false
        return $false
    }

    $isExec = $false

    # Flash LUNs
    if (-not (FlashLUNs -flashList $flashList -FlashPath $flashPath)) {
        ProcessCompleted -isExec $isExec
        return $false
    }
    if ($flashList.LUNs.Count -gt 0) {
        $isExec = $true
    }

    # Flash GPTs
    if (-not (FlashGPTs -flashList $flashList -FlashPath $flashPath)) {
        ProcessCompleted -isExec $isExec
        return $false
    }
    if ($flashList.GPTs.Count -gt 0) {
        $isExec = $true
    }

    # Re-read GPT headers before flashing partitions to ensure we use the new layout
    ResetLookUp
    if (-not (ReadGPTHeaders -isTemp $true -isSort $true)) {
        ProcessCompleted -isExec $isExec
        return $false
    }

    # Flash Partitions
    $totalParts = $flashList.Partitions.Count
    for ($iCnt = 0; $iCnt -lt $totalParts; $iCnt++) {
        $fileInfo = $flashList.Partitions[$iCnt]

        if ($gaLunsOnline -notcontains $fileInfo.iLUN) {
            Write-Log "Skipping partition flash: lun$($fileInfo.iLUN) is offline." "Warning"
            continue
        }

        $obPInfo = [PSCustomObject]@{
            sLabel   = $fileInfo.sLabel
            iLUN     = $fileInfo.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        if (-not (LookUpNames $obPInfo)) {
            Display-NotFound -obPInfo $obPInfo
            continue
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $flashPath

        Write-Log ""
        Write-Log "[$( $iCnt + 1 )/$( $totalParts )] Flashing partition '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

        if (-not (Execute-EdlCommand $sCMDLine)) {
            $script:geFailed = 1
            break
        }
        $isExec = $true
    }

    $success = ($geFailed -eq 0)
    ProcessCompleted -isExec $isExec
    return $success
}

function LoadFileList([string]$flashPath) {
    $flashList = [PSCustomObject]@{
        LUNs       = @()
        GPTs       = @()
        Partitions = @()
        Count      = 0
    }

    if (-not (Test-Path $flashPath)) {
        return $flashList
    }

    $files = Get-ChildItem -Path $flashPath -Filter "*.bin"
    foreach ($file in $files) {
        if ($file.Length -eq 0) {
            Write-Log "Skipping empty file: '$($file.Name)'" "Warning"
            continue
        }
        
        $name = $file.BaseName.ToLower()

        # Determine if it needs renaming (Short2Long)
        if (-not $name.StartsWith("lun")) {
            $name = Short2Long -fileName $file.Name -FlashPath $flashPath
            if ($null -eq $name) {
                continue
            }
        }

        # Parse name: lunX_label.bin or lunX.bin or lunX_gpt.bin
        if ($name -match "^lun(\d+)$" -or $name -match "^lun(\d+)_complete$") {
            $sLabel = if ( $name.Contains("_complete")) {
                "complete"
            } else {
                ""
            }
            $flashList.LUNs += [PSCustomObject]@{ iLUN = [int]$matches[1]; sLabel = $sLabel; Path = $file.FullName }
            $flashList.Count++
        } elseif ($name -match "^lun(\d+)_gpt$" -or $name -match "^lun(\d+)_gpt_header$") {
            $sLabel = if ( $name.Contains("_gpt_header")) {
                "gpt_header"
            } else {
                "gpt"
            }
            $flashList.GPTs += [PSCustomObject]@{ iLUN = [int]$matches[1]; sLabel = $sLabel; Path = $file.FullName }
            $flashList.Count++
        } elseif ($name -match "^lun(\d+)_(.+)$") {
            $flashList.Partitions += [PSCustomObject]@{
                iLUN   = [int]$matches[1]
                sLabel = $matches[2]
                Path   = $file.FullName
            }
            $flashList.Count++
        }
    }

    return $flashList
}

function FlashLUNs($flashList, [string]$flashPath) {
    $totalParts = $flashList.LUNs.Count
    for ($iCnt = 0; $iCnt -lt $totalParts; $iCnt++) {
        $lunFile = $flashList.LUNs[$iCnt]

        $obPInfo = [PSCustomObject]@{
            sLabel   = $lunFile.sLabel
            iLUN     = $lunFile.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $flashPath

        Write-Log ""
        Write-Log "[$( $iCnt + 1 )/$( $totalParts + 1 )] Flashing LUN '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

        if (-not (Execute-EdlCommand $sCMDLine)) {
            $script:geFailed = 1
            return $false
        }
    }
    return $true
}

function FlashGPTs($flashList, [string]$flashPath) {
    $totalParts = $flashList.GPTs.Count
    for ($iCnt = 0; $iCnt -lt $totalParts; $iCnt++) {
        $gptFile = $flashList.GPTs[$iCnt]

        if ($gaLunsOnline -notcontains $gptFile.iLUN) {
            Write-Log "Skipping GPT flash: lun$($gptFile.iLUN) is offline." "Warning"
            continue
        }

        $obPInfo = [PSCustomObject]@{
            sLabel   = $gptFile.sLabel
            iLUN     = $gptFile.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $flashPath

        Write-Log ""
        Write-Log "[$( $iCnt + 1 )/$( $totalParts + 1 )] Flashing GPT '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

        if (-not (Execute-EdlCommand $sCMDLine)) {
            $script:geFailed = 1
            return $false
        }
    }
    return $true
}

function Short2Long($fileName, [string]$flashPath) {
    # Check all LUNs for a partition matching the filename
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    for ($iCnt = 0; $iCnt -le 5; $iCnt++) {
        foreach ($part in $galoLookUp[$iCnt]) {
            if ($part.sLabel -eq $baseName) {
                $newName = "lun$( $iCnt )_$( $baseName ).bin"
                $oldPath = Join-Path $flashPath $fileName

                Write-Log "Renaming '${cCyan}$fileName${cReset}' to '${cCyan}$newName${cReset}'..." "Action"
                try {
                    Rename-Item -Path $oldPath -NewName $newName -ErrorAction Stop
                    return [System.IO.Path]::GetFileNameWithoutExtension($newName).ToLower()
                } catch {
                    Write-Log "Failed to rename '${cCyan}$fileName${cReset}': ${cCyan}$( $_.Exception.Message )${cReset}" "Error"
                    return $null
                }
            }
        }
    }
    return $null
}

function Display-NotFound($obPInfo) {
    Write-Log "Partition '$( $obPInfo.sLabel )' not found on device (LUN $( $obPInfo.iLUN )). Skipping." "Warning"
}

function LookUpNames($obPInfo) {
    $targetLabel = $obPInfo.sLabel.ToLower()
    $iLBound = 0
    $iUBound = $galoLookUp.Count - 1

    if ($null -ne $obPInfo.iLUN) {
        $iLBound = $obPInfo.iLUN
        $iUBound = $obPInfo.iLUN
    }

    for ($iCnt = $iLBound; $iCnt -le $iUBound; $iCnt++) {
        foreach ($part in $galoLookUp[$iCnt]) {
            if ($part.sLabel -eq $targetLabel) {
                # Update the object with found values
                $obPInfo.iLUN = $part.iLUN
                $obPInfo.iStart = $part.iStart
                $obPInfo.iEnd = $part.iEnd
                $obPInfo.iSectors = $part.iSectors
                return $true
            }
        }
    }
    return $false
}

function ValidateCQF {
    # Create/Clean TMP folder
    if (-not (Test-Path $edlTMP)) {
        New-Item -ItemType Directory -Path $edlTMP  | Out-Null
    } else {
        Remove-Item -Path "$edlTMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function ResetLookUp {
    $script:galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
    $script:gaLunsOnline = @()
    $script:geFailed = 0
}

function CreateBackupFolder([string]$backupPath) {
    $script:gsBackupDir = $backupPath

    if (-not (Test-Path $gsBackupDir)) {
        New-Item -ItemType Directory -Path $gsBackupDir | Out-Null
    }
}

function ReadGPTHeaders([bool]$isTemp = $false, [bool]$isSort = $false) {
    $totalParts = 5

    for ($iCnt = 0; $iCnt -le $totalParts; $iCnt++) {

        $obPInfo = [PSCustomObject]@{
            sLabel   = "gpt_header"
            iLUN     = $iCnt
            iStart   = 0
            iEnd     = 0
            iSectors = 6
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $isTemp

        Write-Log ""
        Write-Log "[$( $iCnt + 1 )/$( $totalParts + 1 )] Reading gpt header '${cCyan}lun$( $obPInfo.iLUN )_$( $obPInfo.sLabel ).bin${cReset}'..." "Action"

        if (-not (Execute-EdlCommand $sCMDLine)) {
            if ($iCnt -eq 0) {
                $script:geFailed = 1
                return $false # LUN 0 is mandatory
            }
            
            Write-Log "Skipping lun${iCnt}: LUN not detected on device." "Warning"
            $script:geFailed = 0
            continue
        }

        $script:gaLunsOnline += $iCnt
        LoadGPTData -obPInfo $obPInfo -isTemp $isTemp -isSort $isSort
    }

    return $true
}

function LoadGPTData($obPInfo, [bool]$isTemp, [bool]$isSort = $false) {
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp
    if (-not (Test-Path $sFileName)) {
        return
    }

    $fileStream = [System.IO.File]::OpenRead($sFileName)
    $binaryReader = New-Object System.IO.BinaryReader($fileStream)

    try {
        # GPT Partition entries structure starts at offset 0x2000 (standard for many devices)
        # VB code uses 0x2020 as offset for First LBA
        $binaryReader.BaseStream.Position = 0x2020
        $fileLength = $binaryReader.BaseStream.Length

        while ($binaryReader.BaseStream.Position -lt ($fileLength - 128)) {
            # Read first LBA (8 bytes)
            $iaStart = $binaryReader.ReadBytes(8)
            $iStart = [BitConverter]::ToUInt64($iaStart, 0)

            # Read last LBA (8 bytes)
            $iaEnd = $binaryReader.ReadBytes(8)
            $iEnd = [BitConverter]::ToUInt64($iaEnd, 0)

            $binaryReader.BaseStream.Position += 8 # Skip attributes

            # Read partition name (72 bytes, UTF-16LE)
            $iaLabel = $binaryReader.ReadBytes(72)
            $sLabel = [System.Text.Encoding]::Unicode.GetString($iaLabel).Replace("`0", "").Trim().ToLower()

            if ($iStart -eq 0 -and $sLabel -eq "") {
                break
            }

            $pInfo = [PSCustomObject]@{
                iLUN     = $obPInfo.iLUN
                sLabel   = $sLabel
                iStart   = $iStart
                iEnd     = $iEnd
                iSectors = ($iEnd + 1) - $iStart
            }

            $script:galoLookUp[$obPInfo.iLUN] += $pInfo

            # Move to next GPT entry (128 bytes total, we already read 96 bytes)
            $binaryReader.BaseStream.Position += 32
        }

        if ($isSort) {
            $script:galoLookUp[$obPInfo.iLUN] = $galoLookUp[$obPInfo.iLUN] | Sort-Object sLabel
        }
    } catch {
        Write-Log "Failed to parse GPT data for LUN '${cCyan}$( $obPInfo.iLUN )${cReset}'" "Warning"
    } finally {
        $binaryReader.Close()
        $fileStream.Close()
    }
}

function CalcBounds($obPInfo) {
    try {
        if ($obPInfo.iLUN -eq 0) {
            # For LUN0, we typically want the size up to userdata or the grow partition
            # Logic from VB: index = count - 3
            $lun0 = $galoLookUp[0]
            if ($lun0.Count -ge 3) {
                $targetPart = $lun0[$lun0.Count - 3]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        } else {
            # For other LUNs, we take the size up to the end of the last partition
            $iCnt = $obPInfo.iLUN
            $lun = $galoLookUp[$iCnt]
            if ($lun.Count -gt 0) {
                $targetPart = $lun[$lun.Count - 1]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        }

        # Fallback if no partitions found (unlikely for valid headers)
        $obPInfo.iSectors = 0
        return $false
    } catch {
        $script:geFailed = 1
        return $false
    }
}

function BuildCommand($obPInfo, [bool]$isTemp, [bool]$isFlash = $false, [string]$flashPath = "") {
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp -isFlash $isFlash -FlashPath $flashPath

    $cmd = ""
    if ($isFlash) {
        $cmd = "write-sector $($obPInfo.iStart) `"$sFileName`""
    } else {
        $cmd = "read-sector $($obPInfo.iStart) $($obPInfo.iSectors) `"$sFileName`""
    }

    $cmd += " --lun $($obPInfo.iLUN)"

    return $cmd
}

function CleanUpBackupFolder() {
    if ($null -eq $gsBackupDir) {
        return
    }
    if (Test-Path $gsBackupDir) {
        if ((Get-ChildItem -Path $gsBackupDir -Filter "*.bin").Count -eq 0) {
            Remove-Item -Path $gsBackupDir -Recurse -Force
        }
    }
}

function ProcessCompleted([bool]$isExec = $true) {
    Play-BeepBeep

    Write-Log ""

    # Delete /tools/TMP folder
    if (Test-Path -Path $edlTMP) {
        Write-Log "Deleting '${cCyan}$( $edlTMP )${cReset}' folder..." "Action"
        Remove-Item -Path $edlTMP -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($geFailed -eq 1) {
        Write-Log "Process finished with errors." "Error"
        $script:geFailed = 0
        return
    }

    if (-not $isExec) {
        return
    }

    Write-Log "Process completed successfully." "Success"
}

# --- Internal Helper ---
function BuildFileName($obPInfo, [bool]$isTemp, [bool]$isFlash = $false, [string]$flashPath = "") {
    $sDir = if ($isFlash) {
        $flashPath
    } elseif ($isTemp) {
        "$edlTMP\"
    } else {
        $gsBackupDir
    }

    $sName = "lun$( $obPInfo.iLUN )"
    if ($isFlash) {
        if (-not [string]::IsNullOrEmpty($obPInfo.sLabel)) {
            $sName += "_$( $obPInfo.sLabel )"
        }
    } else {
        if (-not [string]::IsNullOrEmpty($obPInfo.sLabel)) {
            $safeLabel = $obPInfo.sLabel -replace '[^a-zA-Z0-9_]', '_'
            $sName += "_$safeLabel"
        }
    }

    return Join-Path $sDir "$sName.bin"
}
