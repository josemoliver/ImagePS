<#
.SYNOPSIS
    Synchronizes photo timestamps using a reference image and a known correct time.

.DESCRIPTION
    Given a base image (BaseFile) and the correct date/time for that image, calculates the time difference needed to synchronize all images in a folder. Prompts the user to accept, dry run, or cancel. If accepted, updates EXIF and XMP date/time fields for all images, copying the corrected EXIF date to all relevant metadata fields. Handles timezone offsets if present. Displays a progress bar and summarizes the operation.

.PARAMETER BaseFile
    The reference image file (photo of a clock) whose EXIF DateTimeOriginal is used as the base for time correction.

.PARAMETER CorrectDate
    The correct date (yyyy-MM-dd) as displayed in the reference image.

.PARAMETER CorrectTime
    The correct time (HH:mm:ss) as displayed in the reference image.

.PARAMETER FilePath
    The directory containing images to synchronize.

.EXAMPLE
    ./Sync-PhotoTime.ps1 -BaseFile "C:\Photos\IMG_0001.JPG" -CorrectDate "2025-12-07" -CorrectTime "14:23:00" -FilePath "C:\Photos"
#>

param(
    [Parameter(Mandatory)]
    [string]$BaseFile,
    [Parameter(Mandatory)]
    [string]$CorrectDate, # Format: yyyy-MM-dd
    [Parameter(Mandatory)]
    [string]$CorrectTime, # Format: HH:mm:ss
    [Parameter(Mandatory)]
    [string]$FilePath
)

# Ensure PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or later."
    exit 1
}

# Validate exiftool
$exiftool = Get-Command exiftool -ErrorAction SilentlyContinue
if (-not $exiftool) {
    Write-Error "ExifTool is not available in the system PATH."
    exit 1
}

# Validate BaseFile
if (-not (Test-Path $BaseFile)) {
    Write-Error "BaseFile '$BaseFile' does not exist. Please provide a valid path to an image file."
    exit 1
}
if ((Test-Path $BaseFile -PathType Container)) {
    Write-Error "BaseFile '$BaseFile' is a directory, not a file. Please specify an image file."
    exit 1
}

# Validate FilePath (can be file or directory)
if (-not (Test-Path $FilePath)) {
    Write-Error "FilePath '$FilePath' does not exist."
    exit 1
}

# Parse CorrectDate and CorrectTime (explicit formats)
try {
    $correctDateTime = [datetime]::ParseExact("$CorrectDate $CorrectTime", 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
} catch {
    Write-Error "CorrectDate or CorrectTime is not in the expected format. Expected CorrectDate=yyyy-MM-dd and CorrectTime=HH:mm:ss."
    exit 1
}

# Get EXIF DateTimeOriginal from BaseFile
$baseJson = & exiftool -j -DateTimeOriginal "$BaseFile" | ConvertFrom-Json
$baseExif = $baseJson[0].DateTimeOriginal
if (-not $baseExif) {
    Write-Error "BaseFile does not contain EXIF DateTimeOriginal."
    exit 1
}
$baseDateTime = [datetime]::ParseExact($baseExif, 'yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

# Calculate time difference
$delta = $correctDateTime - $baseDateTime
$sign = if ($delta.Ticks -ge 0) { "+" } else { "-" }
$absDelta = $delta.Duration()

Write-Host "BaseFile: $BaseFile"
Write-Host "  EXIF DateTimeOriginal: $($baseDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Correct Date/Time:    $($correctDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  Time difference:      $sign$($absDelta.Days) days, $($absDelta.Hours) hours, $($absDelta.Minutes) minutes, $($absDelta.Seconds) seconds"

# Prompt user for action
Write-Host ""
Write-Host "Choose an action:"
Write-Host "  [A]ccept and write changes"
Write-Host "  [D]ry run (simulate, no write)"
Write-Host "  [C]ancel"
$choice = Read-Host "Enter A, D, or C"
if ($choice -notin @('A','a','D','d','C','c')) {
    Write-Error "Invalid choice. Exiting."
    exit 1
}
if ($choice -in @('C','c')) {
    Write-Host "Operation cancelled."
    exit 0
}
$doWrite = $choice -in @('A','a')

# Gather files to process (single file or directory)
$exts = @('*.jpg','*.jpeg','*.jxl','*.tif','*.tiff','*.png','*.heic','*.heif','*.arw','*.cr2','*.cr3','*.nef','*.rw2','*.orf','*.raf','*.dng','*.webp')

$files = @()
if ((Test-Path $FilePath -PathType Leaf)) {
    # Single file path
    $files = Get-Item -Path $FilePath -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Error "File '$FilePath' could not be accessed."
        exit 1
    }
} else {
    foreach ($pat in $exts) {
        $files += Get-ChildItem -Path $FilePath -Filter $pat -File -ErrorAction SilentlyContinue
    }
    $files = $files | Sort-Object -Property FullName -Unique
}

if (-not $files -or $files.Count -eq 0) {
    Write-Error "No supported image files found in $FilePath"
    exit 1
}

Write-Host "Processing $($files.Count) file(s)..."

# Main processing loop
$updated = 0
$skipped = 0
$progress = 0
foreach ($file in $files) {
    $progress++
    $status = "Processing $progress of $($files.Count) - $($file.Name)"
    Write-Progress -Activity "Syncing photo times" -Status $status -PercentComplete (($progress / $files.Count) * 100)

    # Get original DateTimeOriginal and OffsetTimeOriginal
    $json = & exiftool -j -DateTimeOriginal -OffsetTimeOriginal "$($file.FullName)" | ConvertFrom-Json
    $orig = $json[0].DateTimeOriginal
    if (-not $orig) {
        Write-Host "  Skipped (no DateTimeOriginal): $($file.Name)"
        $skipped++
        continue
    }
    $origDate = [datetime]::ParseExact($orig, 'yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $newDate = $origDate.Add($delta)
    $newDateStr = $newDate.ToString('yyyy:MM:dd HH:mm:ss')

    Write-Host "  $($file.Name): $orig -> $newDateStr"

    # Get OffsetTimeOriginal if present (used for XMP timezone suffix and OffsetTime/OffsetTimeDigitized)
    $offset = $json[0].OffsetTimeOriginal
    $tzSuffix = ''
    if ($offset) {
        $tzSuffix = $offset
    }

    # Check which optional fields exist (for conditional writes)
    # Query each XMP/IPTC field separately to avoid name conflicts
    $iptcCheck = & exiftool -s -s -s -"IPTC:DateCreated" -"IPTC:TimeCreated" "$($file.FullName)" 2>$null
    $hasIptcDate = -not [string]::IsNullOrWhiteSpace($iptcCheck)
    
    $xmpTiffCheck = & exiftool -s -s -s -"XMP-tiff:DateTime" "$($file.FullName)" 2>$null
    $hasXmpTiffDateTime = -not [string]::IsNullOrWhiteSpace($xmpTiffCheck)
    
    $xmpExifOrigCheck = & exiftool -s -s -s -"XMP-exif:DateTimeOriginal" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeOriginal = -not [string]::IsNullOrWhiteSpace($xmpExifOrigCheck)
    
    $xmpExifModCheck = & exiftool -s -s -s -"XMP-exif:DateTimeModified" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeModified = -not [string]::IsNullOrWhiteSpace($xmpExifModCheck)
    
    $xmpExifDigCheck = & exiftool -s -s -s -"XMP-exif:DateTimeDigitized" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeDigitized = -not [string]::IsNullOrWhiteSpace($xmpExifDigCheck)

    if ($doWrite) {
        # Build exiftool args
        $args = @(
            '-overwrite_original',
            "-ExifIFD:DateTimeOriginal=$newDateStr",
            "-ExifIFD:CreateDate=$newDateStr",
            "-ExifIFD:ModifyDate=$newDateStr"
        )

        # Copy to IPTC Date/Time only if they already exist
        if ($hasIptcDate) {
            $args += "-IPTC:DateCreated=$($newDate.ToString('yyyyMMdd'))"
            $args += "-IPTC:TimeCreated=$($newDate.ToString('HHmmss'))"
        }

        # Copy to XMP fields, with timezone if present
        $xmpDate = if ($tzSuffix) { $newDate.ToString('yyyy-MM-ddTHH:mm:ss') + $tzSuffix } else { $newDate.ToString('yyyy-MM-ddTHH:mm:ss') }
        $args += "-XMP-photoshop:DateCreated=$xmpDate"
        $args += "-XMP-xmp:CreateDate=$xmpDate"
        $args += "-XMP-xmp:MetadataDate=$xmpDate"
        $args += "-XMP-xmp:ModifyDate=$xmpDate"
        if ($hasXmpExifDateTimeOriginal) {
            $args += "-XMP-exif:DateTimeOriginal=$xmpDate"
        }
        if ($hasXmpExifDateTimeModified) {
            $args += "-XMP-exif:DateTimeModified=$xmpDate"
        }
        if ($hasXmpExifDateTimeDigitized) {
            $args += "-XMP-exif:DateTimeDigitized=$xmpDate"
        }
        if ($hasXmpTiffDateTime) {
            $args += "-XMP-tiff:DateTime=$xmpDate"
        }

        # If timezone offset is present, also set OffsetTime and OffsetTimeDigitized
        if ($tzSuffix) {
            $args += "-OffsetTime=$tzSuffix"
            $args += "-OffsetTimeDigitized=$tzSuffix"
        }
        & exiftool @args "$($file.FullName)" | Out-Null
        $updated++
    }
}
Write-Progress -Activity "Syncing photo times" -Completed

Write-Host ""
Write-Host "Summary:"
Write-Host "  Files processed: $($files.Count)"
Write-Host "  Files updated:   $updated"
Write-Host "  Files skipped:   $skipped"
Write-Host "  Mode:            $($doWrite ? 'Write' : 'Dry run')"

# If dry run, prompt user to run with write or exit
if (-not $doWrite) {
    Write-Host ""
    Write-Host "This was a dry run - no files were modified."
    Write-Host "Would you like to apply these changes now?"
    Write-Host "  [Y]es - Apply changes and write to files"
    Write-Host "  [N]o - Exit without making changes"
    $applyChoice = Read-Host "Enter Y or N"
    if ($applyChoice -in @('Y','y')) {
        Write-Host ""
        Write-Host "Applying changes..."
        $doWrite = $true
        $updated = 0
        $skipped = 0
        $progress = 0
        
        foreach ($file in $files) {
            $progress++
            $status = "Writing $progress of $($files.Count) - $($file.Name)"
            Write-Progress -Activity "Applying photo time changes" -Status $status -PercentComplete (($progress / $files.Count) * 100)

            # Get original DateTimeOriginal and OffsetTimeOriginal
            $json = & exiftool -j -DateTimeOriginal -OffsetTimeOriginal "$($file.FullName)" | ConvertFrom-Json
            $orig = $json[0].DateTimeOriginal
            if (-not $orig) {
                $skipped++
                continue
            }
            $origDate = [datetime]::ParseExact($orig, 'yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $newDate = $origDate.Add($delta)
            $newDateStr = $newDate.ToString('yyyy:MM:dd HH:mm:ss')

            # Get OffsetTimeOriginal if present
            $offset = $json[0].OffsetTimeOriginal
            $tzSuffix = ''
            if ($offset) {
                $tzSuffix = $offset
            }

            # Check which optional fields exist
            $iptcCheck = & exiftool -s -s -s -"IPTC:DateCreated" -"IPTC:TimeCreated" "$($file.FullName)" 2>$null
            $hasIptcDate = -not [string]::IsNullOrWhiteSpace($iptcCheck)
            
            $xmpTiffCheck = & exiftool -s -s -s -"XMP-tiff:DateTime" "$($file.FullName)" 2>$null
            $hasXmpTiffDateTime = -not [string]::IsNullOrWhiteSpace($xmpTiffCheck)
            
            $xmpExifOrigCheck = & exiftool -s -s -s -"XMP-exif:DateTimeOriginal" "$($file.FullName)" 2>$null
            $hasXmpExifDateTimeOriginal = -not [string]::IsNullOrWhiteSpace($xmpExifOrigCheck)
            
            $xmpExifModCheck = & exiftool -s -s -s -"XMP-exif:DateTimeModified" "$($file.FullName)" 2>$null
            $hasXmpExifDateTimeModified = -not [string]::IsNullOrWhiteSpace($xmpExifModCheck)
            
            $xmpExifDigCheck = & exiftool -s -s -s -"XMP-exif:DateTimeDigitized" "$($file.FullName)" 2>$null
            $hasXmpExifDateTimeDigitized = -not [string]::IsNullOrWhiteSpace($xmpExifDigCheck)

            # Build exiftool args
            $args = @(
                '-overwrite_original',
                "-ExifIFD:DateTimeOriginal=$newDateStr",
                "-ExifIFD:CreateDate=$newDateStr",
                "-ExifIFD:ModifyDate=$newDateStr"
            )

            if ($hasIptcDate) {
                $args += "-IPTC:DateCreated=$($newDate.ToString('yyyyMMdd'))"
                $args += "-IPTC:TimeCreated=$($newDate.ToString('HHmmss'))"
            }

            $xmpDate = if ($tzSuffix) { $newDate.ToString('yyyy-MM-ddTHH:mm:ss') + $tzSuffix } else { $newDate.ToString('yyyy-MM-ddTHH:mm:ss') }
            $args += "-XMP-photoshop:DateCreated=$xmpDate"
            $args += "-XMP-xmp:CreateDate=$xmpDate"
            $args += "-XMP-xmp:MetadataDate=$xmpDate"
            $args += "-XMP-xmp:ModifyDate=$xmpDate"
            if ($hasXmpExifDateTimeOriginal) {
                $args += "-XMP-exif:DateTimeOriginal=$xmpDate"
            }
            if ($hasXmpExifDateTimeModified) {
                $args += "-XMP-exif:DateTimeModified=$xmpDate"
            }
            if ($hasXmpExifDateTimeDigitized) {
                $args += "-XMP-exif:DateTimeDigitized=$xmpDate"
            }
            if ($hasXmpTiffDateTime) {
                $args += "-XMP-tiff:DateTime=$xmpDate"
            }

            if ($tzSuffix) {
                $args += "-OffsetTime=$tzSuffix"
                $args += "-OffsetTimeDigitized=$tzSuffix"
            }
            & exiftool @args "$($file.FullName)" | Out-Null
            $updated++
        }
        Write-Progress -Activity "Applying photo time changes" -Completed
        
        Write-Host ""
        Write-Host "Final Summary:"
        Write-Host "  Files processed: $($files.Count)"
        Write-Host "  Files updated:   $updated"
        Write-Host "  Files skipped:   $skipped"
    } else {
        Write-Host "Exiting without making changes."
    }
}

Write-Host "Done."
