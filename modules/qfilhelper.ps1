#Requires -Version 5.1

<#
.SYNOPSIS
    EDL Helper logic for backing up and flashing devices.
.DESCRIPTION
    Provides functions for backing up LUNs and individual partitions using edl-ng.
#>

# --- Local Variables ---
$edlTMP = Join-Path $WorkingDir "tools\tmp"

$galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
$gaLunsOnline = @()
$gsBackupDir = $null
$geFailed = 0 # 0: NOERR, 1: FAILD, 2: ABORT

# --- Functions ---

function BackupLUNs([string]$backupPath) {
    try {
        if (-not (ValidateCQF)) {
            throw "CQF validation failed."
        }

        ResetLookUp
        CreateBackupFolder $backupPath

        # Read GPT Headers to get partition layouts for each LUN
        if (-not (ReadGPTHeaders -isTemp $true)) {
            CleanUpBackupFolder
            ProcessCompleted -isExec $false
            throw "Failed to read GPT Headers."
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
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function BackupUserData([string]$backupPath) {
    try {
        if (-not (ValidateCQF)) {
            throw "CQF validation failed."
        }

        ResetLookUp
        CreateBackupFolder $backupPath

        # Read GPT Headers with sorting enabled to allow looking up partition names
        if (-not (ReadGPTHeaders -isTemp $false -isSort $true)) {
            CleanUpBackupFolder
            ProcessCompleted -isExec $false
            throw "Failed to read GPT Headers."
        }

        $obPInfo = [PSCustomObject]@{
            sLabel   = "userdata"
            iLUN     = $null
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        if (-not (LookUpNames $obPInfo)) {
            CleanUpBackupFolder
            ProcessCompleted -isExec $false
            throw "Failed to resolve LUN and sectors for partition 'userdata'."
        }

        $fullSectors = $obPInfo.iSectors

        # Try sparse/chunked range backup first
        $ranges = Get-AllocatedRanges -obPInfo $obPInfo

        if ($null -eq $ranges -or $ranges.Count -eq 0) {
            # Fallback: full partition backup as single file
            Write-Log "Could not determine allocated ranges; falling back to full partition backup." "Warning"
            $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false
            Write-Log ""
            Write-Log "[1/1] Backing up partition '${cCyan}lun0_userdata.bin${cReset}'..." "Action"
            if (-not (Execute-EdlCommand $sCMDLine)) {
                $script:geFailed = 1
                CleanUpBackupFolder
                ProcessCompleted -isExec $false
                throw "Execution of EDL command failed."
            }
            CleanUpBackupFolder
            ProcessCompleted -isExec $true
        } elseif ($ranges.Count -eq 1 -and $ranges[0].StartSector -eq $obPInfo.iStart) {
            # Single contiguous range covering from partition start -> use standard filename
            $obSingle = [PSCustomObject]@{
                sLabel   = "userdata"
                iLUN     = $obPInfo.iLUN
                iStart   = $ranges[0].StartSector
                iEnd     = $ranges[0].StartSector + $ranges[0].Sectors - 1
                iSectors = $ranges[0].Sectors
            }
            $sCMDLine = BuildCommand -obPInfo $obSingle -isTemp $false
            Write-Log ""
            Write-Log "[1/1] Backing up partition '${cCyan}lun0_userdata.bin${cReset}' (${cYellow}$($ranges[0].Sectors) sectors${cReset})..." "Action"
            if (-not (Execute-EdlCommand $sCMDLine)) {
                $script:geFailed = 1
                CleanUpBackupFolder
                ProcessCompleted -isExec $false
                throw "Execution of EDL command failed."
            }
            # Write manifest even for single-chunk so restore logic is uniform
            $manifestPath = Join-Path $gsBackupDir "userdata_manifest.json"
            $manifest = [PSCustomObject]@{
                version          = 1
                partition        = "userdata"
                iLUN             = $obPInfo.iLUN
                fullSectors      = $fullSectors
                totalUsedSectors = $ranges[0].Sectors
                chunkCount       = 1
                chunks           = @(
                    [PSCustomObject]@{
                        file        = "lun0_userdata.bin"
                        startSector = $ranges[0].StartSector
                        sectors     = $ranges[0].Sectors
                    }
                )
            }
            $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
            Write-Log "Manifest written: '${cCyan}userdata_manifest.json${cReset}'." "Info"
            CleanUpBackupFolder
            ProcessCompleted -isExec $true
        } else {
            # Multi-chunk: back up each range to lun0_userdata_partN.bin
            $totalChunks = $ranges.Count
            $totalUsedSectors = [uint64]0
            foreach ($r in $ranges) { $totalUsedSectors += [uint64]$r.Sectors }

            $chunkObjects = @()
            for ($ci = 0; $ci -lt $totalChunks; $ci++) {
                $range = $ranges[$ci]
                $partNum = $ci + 1
                $chunkLabel = "userdata_part$partNum"
                $chunkFileName = "lun0_${chunkLabel}.bin"

                $obChunk = [PSCustomObject]@{
                    sLabel   = $chunkLabel
                    iLUN     = $obPInfo.iLUN
                    iStart   = $range.StartSector
                    iEnd     = $range.StartSector + $range.Sectors - 1
                    iSectors = $range.Sectors
                }

                $sCMDLine = BuildCommand -obPInfo $obChunk -isTemp $false
                $chunkGB = [Math]::Round($range.Sectors * 4096 / 1GB, 2)

                Write-Log ""
                Write-Log "[$partNum/$totalChunks] Backing up userdata chunk '${cCyan}$chunkFileName${cReset}' (sectors ${cYellow}$($range.StartSector)${cReset} - ${cYellow}$($range.StartSector + $range.Sectors - 1)${cReset}, ${cGreen}${chunkGB} GB${cReset})..." "Action"

                if (-not (Execute-EdlCommand $sCMDLine)) {
                    $script:geFailed = 1
                    CleanUpBackupFolder
                    ProcessCompleted -isExec $false
                    throw "Execution of EDL command failed."
                }

                $chunkObjects += [PSCustomObject]@{
                    file        = $chunkFileName
                    startSector = $range.StartSector
                    sectors     = $range.Sectors
                }
            }

            # Write manifest
            $manifestPath = Join-Path $gsBackupDir "userdata_manifest.json"
            $manifest = [PSCustomObject]@{
                version          = 1
                partition        = "userdata"
                iLUN             = $obPInfo.iLUN
                fullSectors      = $fullSectors
                totalUsedSectors = $totalUsedSectors
                chunkCount       = $totalChunks
                chunks           = $chunkObjects
            }
            $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

            $totalGB = [Math]::Round($totalUsedSectors * 4096 / 1GB, 2)
            Write-Log ""
            Write-Log "Sparse backup complete: ${cCyan}$totalChunks chunks${cReset}, ${cYellow}$totalUsedSectors sectors${cReset} (${cGreen}$totalGB GB${cReset}) of ${cYellow}$fullSectors${cReset} total sectors backed up." "Success"
            Write-Log "Manifest written: '${cCyan}userdata_manifest.json${cReset}'." "Info"

            CleanUpBackupFolder
            ProcessCompleted -isExec $true
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function Get-AllocatedRanges($obPInfo) {
    $result = $null

    try {
        if (-not (Test-Path $edlTMP)) {
            New-Item -Path $edlTMP -ItemType Directory -Force | Out-Null
        }

        $obSB = [PSCustomObject]@{
            sLabel   = "userdata_sb_tmp"
            iLUN     = $obPInfo.iLUN
            iStart   = $obPInfo.iStart
            iEnd     = $obPInfo.iStart + 7
            iSectors = 8
        }

        Write-Log "Reading userdata superblock for range detection..." "Action"
        if (-not (Execute-EdlCommand (BuildCommand -obPInfo $obSB -isTemp $true) -silent $true)) {
            throw "Failed to read superblock for range detection."
        }

        $sSBFile = BuildFileName -obPInfo $obSB -isTemp $true
        if (-not (Test-Path $sSBFile)) { throw "" }

        try { $sbBytes = [System.IO.File]::ReadAllBytes($sSBFile) }
        catch { throw "" }

        $sbBase = 1024
        if ($sbBytes.Length -lt ($sbBase + 0x80)) { throw "" }

        $isF2FS = ($sbBytes[$sbBase + 0] -eq 0x10 -and $sbBytes[$sbBase + 1] -eq 0x20 -and
            $sbBytes[$sbBase + 2] -eq 0xF5 -and $sbBytes[$sbBase + 3] -eq 0xF2)
        if ($isF2FS) {
            $result = Get-AllocatedRanges-F2FS -obPInfo $obPInfo -sbBytes $sbBytes -sbBase $sbBase
        } else {
            $isExt4 = ($sbBytes[$sbBase + 0x38] -eq 0x53 -and $sbBytes[$sbBase + 0x39] -eq 0xEF)
            if ($isExt4) {
                $result = Get-AllocatedRanges-Ext4 -obPInfo $obPInfo -sbBytes $sbBytes -sbBase $sbBase
            } else {
                Write-Log "Unknown filesystem; cannot determine allocated ranges." "Warning"
            }
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $result
}

function Get-AllocatedRanges-F2FS($obPInfo, $sbBytes, $sbBase) {
    $ranges = $null

    try {
        if ($sbBytes.Length -lt ($sbBase + 0x60)) { throw "" }

        $logBlockSize = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x10)
        $logBlocksPerSeg = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x14)
        $logSectorsPerBlock = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x0C)
        $segmentCountCkpt = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x34)
        $segmentCountSit = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x38)
        $segmentCountMain = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x44)
        $cpBlkAddr = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x4C)
        $sitBlkAddr = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x50)
        $mainBlkAddr = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x5C)

        $blockSize = [uint64](1 -shl [int]$logBlockSize)
        $blocksPerSeg = [uint64](1 -shl [int]$logBlocksPerSeg)
        $sectorsPerBlock = [uint64](1 -shl [int]$logSectorsPerBlock)
        $sectorsPerSeg = $blocksPerSeg * $sectorsPerBlock

        if ($blockSize -eq 0 -or $blocksPerSeg -eq 0 -or $cpBlkAddr -eq 0) { throw "" }

        # Gap-merge threshold: 64 segments = 128 MiB (with 4K pages / 512-byte sectors)
        $gapThresholdSegs = [uint64]64

        # --- Read & select the active checkpoint ---
        $cpSectors = [uint64][Math]::Max(8, $sectorsPerBlock)
        $cpSecStart = $obPInfo.iStart + ($cpBlkAddr * $sectorsPerBlock)
        $obCP = [PSCustomObject]@{
            sLabel = "userdata_cp_tmp"; iLUN = $obPInfo.iLUN
            iStart = $cpSecStart; iEnd = $cpSecStart + $cpSectors - 1; iSectors = $cpSectors
        }
        if (-not (Execute-EdlCommand (BuildCommand -obPInfo $obCP -isTemp $true) -silent $true)) { throw "" }
        $sCPFile = BuildFileName -obPInfo $obCP -isTemp $true
        if (-not (Test-Path $sCPFile)) { throw "" }
        try { $cpBytes = [System.IO.File]::ReadAllBytes($sCPFile) } catch { throw "" }
        if ($cpBytes.Length -lt 0x84) { throw "" }

        # Check CP1
        if ($segmentCountCkpt -ge 2) {
            $cp1BlkAddr = $cpBlkAddr + ($blocksPerSeg * [uint64]($segmentCountCkpt / 2))
            $cp1SecStart = $obPInfo.iStart + ($cp1BlkAddr * $sectorsPerBlock)
            $obCP1 = [PSCustomObject]@{
                sLabel = "userdata_cp1_tmp"; iLUN = $obPInfo.iLUN
                iStart = $cp1SecStart; iEnd = $cp1SecStart + $cpSectors - 1; iSectors = $cpSectors
            }
            if (Execute-EdlCommand (BuildCommand -obPInfo $obCP1 -isTemp $true) -silent $true) {
                $sCP1File = BuildFileName -obPInfo $obCP1 -isTemp $true
                if (Test-Path $sCP1File) {
                    try {
                        $cp1Bytes = [System.IO.File]::ReadAllBytes($sCP1File)
                        if ($cp1Bytes.Length -ge 0x84) {
                            $ver0 = [BitConverter]::ToUInt64($cpBytes, 0x00)
                            $ver1 = [BitConverter]::ToUInt64($cp1Bytes, 0x00)
                            if ($ver1 -gt $ver0) { $cpBytes = $cp1Bytes }
                        }
                    } catch { }
                }
            }
        }

        # Build active-segment set from CP cur_node_segno[8] @ 0x24 and cur_data_segno[8] @ 0x54
        $activeSegs = @{}
        for ($i = 0; $i -lt 8; $i++) {
            $n = [BitConverter]::ToUInt32($cpBytes, 0x24 + $i * 4)
            $d = [BitConverter]::ToUInt32($cpBytes, 0x54 + $i * 4)
            if ($n -ne 0xFFFFFFFF -and $n -lt $segmentCountMain) { $activeSegs[[int]$n] = $true }
            if ($d -ne 0xFFFFFFFF -and $d -lt $segmentCountMain) { $activeSegs[[int]$d] = $true }
        }

        # --- Read SIT table ---
        $sitSecStart = $obPInfo.iStart + ($sitBlkAddr * $sectorsPerBlock)
        $sitSectors = $segmentCountSit * $blocksPerSeg * $sectorsPerBlock
        $obSIT = [PSCustomObject]@{
            sLabel = "userdata_sit_tmp"; iLUN = $obPInfo.iLUN
            iStart = $sitSecStart; iEnd = $sitSecStart + $sitSectors - 1; iSectors = $sitSectors
        }
        Write-Log "Scanning ${cCyan}F2FS SIT${cReset} table for allocated segment ranges..." "Action"
        if (-not (Execute-EdlCommand (BuildCommand -obPInfo $obSIT -isTemp $true) -silent $true)) { throw "" }
        $sSITFile = BuildFileName -obPInfo $obSIT -isTemp $true
        if (-not (Test-Path $sSITFile)) { throw "" }
        try { $sitBytes = [System.IO.File]::ReadAllBytes($sSITFile) } catch { throw "" }

        # SIT dirty bitmap
        $sitBitmapBytes = [BitConverter]::ToUInt32($cpBytes, 0x9C)
        $bitmap = if ($cpBytes.Length -ge (0xC0 + $sitBitmapBytes)) {
            $cpBytes[0xC0 .. (0xC0 + $sitBitmapBytes - 1)]
        } else { @() }

        $sit0Offset = [uint64]0
        $sit1Offset = [uint64](($blocksPerSeg * [uint64]($segmentCountSit / 2)) * $blockSize)
        $sitEntriesPerBlock = [int]($blockSize / 74)

        # Build per-segment used flag array
        $segUsed = [bool[]]::new([int]$segmentCountMain)
        for ($seg = 0; $seg -lt [int]$segmentCountMain; $seg++) {
            if ($activeSegs.ContainsKey($seg)) { $segUsed[$seg] = $true; continue }
            $blkIdx = [int64]($seg / $sitEntriesPerBlock)
            $entryIdx = [int64]($seg % $sitEntriesPerBlock)
            $byteIdx = [int]($blkIdx / 8)
            $bitIdx = [int]($blkIdx % 8)
            $isPack1 = if ($byteIdx -lt $bitmap.Length) { ($bitmap[$byteIdx] -shr $bitIdx) -band 1 } else { 0 }
            $packBase = if ($isPack1 -eq 1) { $sit1Offset } else { $sit0Offset }
            $offset = $packBase + ($blkIdx * $blockSize) + ($entryIdx * 74)
            if (($offset + 2) -gt $sitBytes.Length) { continue }
            $vblocks = [BitConverter]::ToUInt16($sitBytes, [int]$offset)
            $segUsed[$seg] = (($vblocks -band 0x3FF) -gt 0)
        }

        # --- Range 0: always include the F2FS metadata prefix (SB..SSA) ---
        # This covers sectors 0..(mainBlkAddr * sectorsPerBlock - 1)
        $metaEndSector = $obPInfo.iStart + ($mainBlkAddr * $sectorsPerBlock)
        $ranges = [System.Collections.Generic.List[PSCustomObject]]::new()
        $ranges.Add([PSCustomObject]@{
                StartSector = $obPInfo.iStart
                Sectors     = $mainBlkAddr * $sectorsPerBlock
            })

        # --- Coalesce main-area segments into ranges ---
        $rangeStartSeg = [int64]-1
        $gapCount = [uint64]0
        $lastUsedSeg = [int64]-1

        for ($seg = 0; $seg -lt [int]$segmentCountMain; $seg++) {
            if ($segUsed[$seg]) {
                if ($rangeStartSeg -lt 0) {
                    $rangeStartSeg = $seg   # start a new range
                }
                $gapCount = 0
                $lastUsedSeg = $seg
            } else {
                if ($rangeStartSeg -ge 0) {
                    $gapCount++
                    if ($gapCount -ge $gapThresholdSegs) {
                        # Emit the current range (up to last used segment)
                        $rStart = $obPInfo.iStart + ($mainBlkAddr * $sectorsPerBlock) + ([uint64]$rangeStartSeg * $sectorsPerSeg)
                        $rSectors = ([uint64]($lastUsedSeg - $rangeStartSeg + 1)) * $sectorsPerSeg
                        $ranges.Add([PSCustomObject]@{ StartSector = $rStart; Sectors = $rSectors })
                        $rangeStartSeg = -1
                        $gapCount = 0
                    }
                }
            }
        }

        # Flush the last open range
        if ($rangeStartSeg -ge 0 -and $lastUsedSeg -ge 0) {
            $safeLastSeg = [Math]::Min([int]$segmentCountMain - 1, $lastUsedSeg + 4)
            $rStart = $obPInfo.iStart + ($mainBlkAddr * $sectorsPerBlock) + ([uint64]$rangeStartSeg * $sectorsPerSeg)
            $rSectors = ([uint64]($safeLastSeg - $rangeStartSeg + 1)) * $sectorsPerSeg
            $ranges.Add([PSCustomObject]@{ StartSector = $rStart; Sectors = $rSectors })
        }

        $usedCount = ($segUsed | Where-Object { $_ }).Count
        Write-Log "F2FS range scan: ${cCyan}$usedCount${cReset} used segments -> ${cCyan}$($ranges.Count)${cReset} ranges (gap threshold=${cYellow}$gapThresholdSegs segs${cReset})." "Info"
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $ranges
}

function Get-AllocatedRanges-Ext4($obPInfo, $sbBytes, $sbBase) {
    $ranges = $null

    try {
        if ($sbBytes.Length -lt ($sbBase + 0x200)) { throw "" }

        $blocksCountLo = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x04)
        $logBlockSize = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x18)
        $blocksPerGroup = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x20)
        $featureIncompat = [BitConverter]::ToUInt32($sbBytes, $sbBase + 0x60)
        $descSize = [uint32][BitConverter]::ToUInt16($sbBytes, $sbBase + 0xFE)
        if ($descSize -lt 32) { $descSize = 32 }

        $blocksCountHi = [uint64]0
        if (($featureIncompat -band 0x80) -and ($sbBytes.Length -ge ($sbBase + 0x154))) {
            $blocksCountHi = [uint64][BitConverter]::ToUInt32($sbBytes, $sbBase + 0x150)
        }

        $blockSize = [uint64](1024 -shl [int]$logBlockSize)
        $totalBlocks = ($blocksCountHi -shl 32) -bor [uint64]$blocksCountLo
        if ($totalBlocks -eq 0 -or $blockSize -eq 0 -or $blocksPerGroup -eq 0) { throw "" }

        $sectorSize = if ($obPInfo.iSectors -gt 0) {
            $calc = [double]($totalBlocks * $blockSize) / [double]$obPInfo.iSectors
            [uint64][Math]::Round($calc)
        } else { 4096 }
        if ($sectorSize -ne 4096 -and $sectorSize -ne 512) {
            $sectorSize = if ($blockSize -ge 4096) { 4096 } else { 512 }
        }
        $sectorsPerBlock = [uint64][Math]::Max(1, $blockSize / $sectorSize)
        $sectorsPerGroup = [uint64]$blocksPerGroup * $sectorsPerBlock

        # Gap threshold: 128 MiB expressed in block groups
        $gapThresholdGroups = [uint64][Math]::Max(1, [uint64](128MB / ($blockSize * $blocksPerGroup)))

        $numGroups = [uint64][Math]::Ceiling([double]$totalBlocks / [double]$blocksPerGroup)
        $bgdStartBlock = if ($blockSize -eq 1024) { [uint64]2 } else { [uint64]1 }
        $bgdStartSector = $obPInfo.iStart + ($bgdStartBlock * $sectorsPerBlock)
        $bgdTableBytes = $numGroups * [uint64]$descSize
        $bgdSectors = [uint64][Math]::Ceiling([double]$bgdTableBytes / [double]$sectorSize)

        if ($bgdSectors -gt 65536) {
            throw "BGD table too large (${cYellow}$bgdSectors sectors${cReset}); cannot scan ranges."
        }

        $obBGD = [PSCustomObject]@{
            sLabel = "userdata_bgd_tmp"; iLUN = $obPInfo.iLUN
            iStart = $bgdStartSector; iEnd = $bgdStartSector + $bgdSectors - 1; iSectors = $bgdSectors
        }
        Write-Log "Scanning ext4 ${cCyan}BGD${cReset} table for allocated group ranges..." "Action"
        if (-not (Execute-EdlCommand (BuildCommand -obPInfo $obBGD -isTemp $true) -silent $true)) { throw "" }
        $sBGDFile = BuildFileName -obPInfo $obBGD -isTemp $true
        if (-not (Test-Path $sBGDFile)) { throw "" }
        try { $bgdBytes = [System.IO.File]::ReadAllBytes($sBGDFile) } catch { throw "" }

        # Build per-group used flag
        $groupUsed = [bool[]]::new([int]$numGroups)
        for ($g = 0; $g -lt [int]$numGroups; $g++) {
            $bgdOffset = $g * [int64]$descSize
            if (($bgdOffset + 0x0E) -gt $bgdBytes.Length) { continue }
            $freeInGroup = [BitConverter]::ToUInt16($bgdBytes, [int]($bgdOffset + 0x0C))
            $groupStart = [uint64]$g * [uint64]$blocksPerGroup
            $blocksInGroup = [uint64][Math]::Min($blocksPerGroup, $totalBlocks - $groupStart)
            $groupUsed[$g] = ([uint64]$freeInGroup -lt $blocksInGroup)
        }

        # Coalesce into ranges
        $ranges = [System.Collections.Generic.List[PSCustomObject]]::new()
        $rangeStartGrp = [int64]-1
        $gapCount = [uint64]0
        $lastUsedGrp = [int64]-1

        for ($g = 0; $g -lt [int]$numGroups; $g++) {
            if ($groupUsed[$g]) {
                if ($rangeStartGrp -lt 0) { $rangeStartGrp = $g }
                $gapCount = 0
                $lastUsedGrp = $g
            } else {
                if ($rangeStartGrp -ge 0) {
                    $gapCount++
                    if ($gapCount -ge $gapThresholdGroups) {
                        $rStart = $obPInfo.iStart + ([uint64]$rangeStartGrp * $sectorsPerGroup)
                        $rSectors = ([uint64]($lastUsedGrp - $rangeStartGrp + 1)) * $sectorsPerGroup
                        $ranges.Add([PSCustomObject]@{ StartSector = $rStart; Sectors = $rSectors })
                        $rangeStartGrp = -1
                        $gapCount = 0
                    }
                }
            }
        }

        # Flush the last open range
        if ($rangeStartGrp -ge 0 -and $lastUsedGrp -ge 0) {
            $rStart = $obPInfo.iStart + ([uint64]$rangeStartGrp * $sectorsPerGroup)
            $rSectors = ([uint64]($lastUsedGrp - $rangeStartGrp + 1)) * $sectorsPerGroup
            $ranges.Add([PSCustomObject]@{ StartSector = $rStart; Sectors = $rSectors })
        }

        $usedCount = ($groupUsed | Where-Object { $_ }).Count
        Write-Log "ext4 range scan: ${cCyan}$usedCount${cReset} used groups -> ${cCyan}$($ranges.Count)${cReset} ranges (gap threshold=${cYellow}$gapThresholdGroups groups${cReset})." "Info"
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $ranges
}

function BackupPartitions([string]$backupPath) {
    try {
        if (-not (ValidateCQF)) {
            throw "CQF validation failed."
        }

        ResetLookUp
        CreateBackupFolder $backupPath

        # Read GPT Headers to populate $galoLookUp
        if (-not (ReadGPTHeaders -isTemp $true)) {
            CleanUpBackupFolder
            ProcessCompleted -isExec $false
            throw "Failed to read GPT Headers."
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
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function FlashFirmware([string]$flashPath) {
    $functionResult = $false

    try {
        if ([string]::IsNullOrEmpty($flashPath)) {
            throw ""
        }

        if (-not (ValidateCQF)) {
            throw ""
        }

        ResetLookUp

        # Read GPT Headers to get partition layouts for each LUN
        if (-not (ReadGPTHeaders -isTemp $true)) {
            ProcessCompleted -isExec $false
            throw ""
        }

        $flashList = LoadFileList -FlashPath $flashPath
        if ($flashList.Count -eq 0) {
            throw "No firmware files found in '${cCyan}${flashPath}${cCyan}'."
            ProcessCompleted -isExec $false
        }

        $isExec = $false

        # Flash LUNs
        if (-not (FlashLUNs -flashList $flashList -FlashPath $flashPath)) {
            ProcessCompleted -isExec $isExec
            throw ""
        }
        if ($flashList.LUNs.Count -gt 0) {
            $isExec = $true
        }

        # Flash GPTs
        if (-not (FlashGPTs -flashList $flashList -FlashPath $flashPath)) {
            ProcessCompleted -isExec $isExec
            throw ""
        }
        if ($flashList.GPTs.Count -gt 0) {
            $isExec = $true
        }

        # Re-read GPT headers before flashing partitions to ensure we use the new layout
        ResetLookUp
        if (-not (ReadGPTHeaders -isTemp $true -isSort $true)) {
            ProcessCompleted -isExec $isExec
            throw ""
        }

        # Flash Partitions
        $totalParts = $flashList.Partitions.Count
        for ($iCnt = 0; $iCnt -lt $totalParts; $iCnt++) {
            $fileInfo = $flashList.Partitions[$iCnt]

            if ($gaLunsOnline -notcontains $fileInfo.iLUN) {
                Write-Log ""
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

            if ($obPInfo.sLabel -eq "userdata") {
                # Userdata is handled via chunked manifest restore below; skip here
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

        # --- Chunked sparse userdata restore ---
        if ($null -ne $flashList.UserdataManifest -and $geFailed -eq 0) {
            $manifest = $flashList.UserdataManifest
            $totalChunks = $manifest.chunks.Count

            Write-Log ""
            Write-Log "Restoring ${cCyan}userdata${cReset} from sparse manifest (${cYellow}$totalChunks chunks${cReset})..." "Action"
            Write-Log "Erasing partition '${cCyan}userdata${cReset}' to clean all unwritten gaps..." "Action"

            if (-not (Execute-EdlCommand "erase-part userdata")) {
                Write-Log "Failed to erase '${cCyan}userdata${cReset}' partition." "Error"
                $script:geFailed = 1
            } else {
                for ($ci = 0; $ci -lt $totalChunks; $ci++) {
                    $chunk = $manifest.chunks[$ci]
                    $chunkPath = Join-Path $flashPath $chunk.file

                    if (-not (Test-Path $chunkPath)) {
                        Write-Log "Chunk file missing: '${cYellow}$($chunk.file)${cReset}'." "Error"
                        $script:geFailed = 1
                        break
                    }

                    $chunkGB = [Math]::Round($chunk.sectors * 4096 / 1GB, 2)
                    Write-Log ""
                    Write-Log "[$($ci + 1)/$totalChunks] Flashing userdata chunk '${cCyan}$($chunk.file)${cReset}' -> LBA ${cYellow}$($chunk.startSector)${cReset} (${cGreen}$chunkGB GB${cReset})..." "Action"

                    $sCMDLine = "write-sector $($chunk.startSector) `"$chunkPath`" --lun $($manifest.iLUN)"
                    if (-not (Execute-EdlCommand $sCMDLine)) {
                        $script:geFailed = 1
                        break
                    }
                    $isExec = $true
                }
            }
        } elseif ($null -eq $flashList.UserdataManifest -and $geFailed -eq 0) {
            # Fall back: look for monolithic lun0_userdata.bin in Partitions list
            $monoUserdata = $flashList.Partitions | Where-Object { $_.sLabel -eq "userdata" } | Select-Object -First 1
            if ($monoUserdata) {
                $obUD = [PSCustomObject]@{
                    sLabel = "userdata"
                    iLUN = $monoUserdata.iLUN
                    iStart = 0; iEnd = 0; iSectors = 0
                }
                if (LookUpNames $obUD) {
                    Write-Log ""
                    Write-Log "Erasing partition '${cCyan}userdata${cReset}' before flashing..." "Action"
                    if (-not (Execute-EdlCommand "erase-part userdata")) {
                        Write-Log "Failed to erase '${cCyan}userdata${cReset}' partition." "Error"
                        $script:geFailed = 1
                    } else {
                        $sCMDLine = BuildCommand -obPInfo $obUD -isTemp $false -isFlash $true -FlashPath $flashPath
                        Write-Log "Flashing partition '${cCyan}lun0_userdata.bin${cReset}'..." "Action"
                        if (-not (Execute-EdlCommand $sCMDLine)) {
                            $script:geFailed = 1
                        } else {
                            $isExec = $true
                        }
                    }
                }
            }
        }

        $functionResult = ($geFailed -eq 0)
        ProcessCompleted -isExec $isExec
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $functionResult
}

function LoadFileList([string]$flashPath) {
    $flashList = [PSCustomObject]@{
        LUNs             = @()
        GPTs             = @()
        Partitions       = @()
        UserdataManifest = $null
        Count            = 0
    }

    try {
        if (-not (Test-Path $flashPath)) {
            throw ""
        }

        # Detect userdata_manifest.json for chunked sparse restore
        $manifestFile = Join-Path $flashPath "userdata_manifest.json"
        if (Test-Path $manifestFile) {
            try {
                $manifestJson = Get-Content -Path $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($manifestJson.version -eq 1 -and $manifestJson.chunks) {
                    $flashList.UserdataManifest = $manifestJson
                    Write-Log "Detected userdata sparse manifest: ${cCyan}$($manifestJson.chunkCount) chunks${cReset}, ${cYellow}$($manifestJson.totalUsedSectors) sectors${cReset}." "Info"
                }
            } catch {
                Write-Log "Failed to parse userdata_manifest.json: $($_.Exception.Message)" "Warning"
            }
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

            # Skip chunk files that belong to the manifest - they are handled by chunked restore
            if ($null -ne $flashList.UserdataManifest) {
                $chunkFiles = $flashList.UserdataManifest.chunks | ForEach-Object {
                    [System.IO.Path]::GetFileNameWithoutExtension($_.file).ToLower()
                }
                if ($chunkFiles -contains $name) {
                    continue
                }
            }

            # Parse name: lunX_label.bin or lunX.bin or lunX_gpt.bin
            if ($name -match "^lun(\d+)$" -or $name -match "^lun(\d+)_complete$") {
                $sLabel = if ($name.Contains("_complete")) { "complete" } else { "" }
                $flashList.LUNs += [PSCustomObject]@{ iLUN = [int]$matches[1]; sLabel = $sLabel; Path = $file.FullName }
                $flashList.Count++
            } elseif ($name -match "^lun(\d+)_gpt$" -or $name -match "^lun(\d+)_gpt_header$") {
                $sLabel = if ($name.Contains("_gpt_header")) { "gpt_header" } else { "gpt" }
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
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
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
    # Create/Clean tmp folder
    if (-not (Test-Path $edlTMP)) {
        New-Item -Path $edlTMP -ItemType Directory -Force | Out-Null
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
        New-Item -Path $gsBackupDir -ItemType Directory -Force | Out-Null
    }
}

function ReadGPTHeaders([bool]$isTemp = $false, [bool]$isSort = $false) {
    $functionResult = $true

    try {
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
                    $functionResult = $false # LUN 0 is mandatory
                    break
                }
                
                Write-Log "Skipping lun${iCnt}: LUN not detected on device." "Warning"
                $script:geFailed = 0
                continu
            }

            $script:gaLunsOnline += $iCnt
            LoadGPTData -obPInfo $obPInfo -isTemp $isTemp -isSort $isSort
        }
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $functionResult
}

function LoadGPTData($obPInfo, [bool]$isTemp, [bool]$isSort = $false) {
    try {
        $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp
        if (-not (Test-Path $sFileName)) {
            throw ""
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
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }
}

function CalcBounds($obPInfo) {
    $functionResult = $false

    try {
        if ($obPInfo.iLUN -eq 0) {
            # For LUN0, we typically want the size up to userdata or the grow partition
            # Logic from VB: index = count - 3
            $lun0 = $galoLookUp[0]
            if ($lun0.Count -ge 3) {
                $targetPart = $lun0[$lun0.Count - 3]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                $functionResult = $true
            }
        } else {
            # For other LUNs, we take the size up to the end of the last partition
            $iCnt = $obPInfo.iLUN
            $lun = $galoLookUp[$iCnt]
            if ($lun.Count -gt 0) {
                $targetPart = $lun[$lun.Count - 1]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                $functionResult = $true
            }
        }

        if (-not $functionResult) {
            # Fallback if no partitions found (unlikely for valid headers)
            $obPInfo.iSectors = 0
        }
    } catch {
        $script:geFailed = 1
        $functionResult = $false
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $functionResult
}

function BuildCommand($obPInfo, [bool]$isTemp, [bool]$isFlash = $false, [string]$flashPath = "") {
    $cmd = ""

    try {
        $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp -isFlash $isFlash -FlashPath $flashPath

        if ($isFlash) {
            $cmd = "write-sector $($obPInfo.iStart) `"$sFileName`""
        } else {
            $cmd = "read-sector $($obPInfo.iStart) $($obPInfo.iSectors) `"$sFileName`""
        }

        $cmd += " --lun $($obPInfo.iLUN)"
    } catch {
        if ($_.Exception.Message) {
            Write-Log "$($_.Exception.Message)" "Error"
        }
    }

    return $cmd
}

function CleanUpBackupFolder() {
    if (-not [string]::IsNullOrEmpty($gsBackupDir) -and (Test-Path $gsBackupDir)) {
        if ((Get-ChildItem -Path $gsBackupDir -Filter "*.bin").Count -eq 0) {
            Remove-Item -Path $gsBackupDir -Recurse -Force
        }
    }
}

function ProcessCompleted([bool]$isExec = $true) {
    Play-BeepBeep

    Write-Log ""

    # Delete tmp folder
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
