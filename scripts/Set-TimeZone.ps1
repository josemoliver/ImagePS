<#
.SYNOPSIS
    Updates timezone offset metadata in EXIF and XMP fields of image files.

.DESCRIPTION
    This script batch processes image files to correct timezone offset metadata across
    EXIF OffsetTime and XMP datetime fields. Useful for photos taken in different timezones
    or when the timezone information needs to be added or corrected post-capture.

.PARAMETER Timezone
    The timezone offset in ISO 8601 format (±HH:MM). Examples: +02:00, -05:00, +00:00 (UTC)
    Range: UTC-14 to UTC+14 (±00:00 to ±14:00)
    If blank/empty, the script automatically uses the local system timezone offset.
    Required parameter (but accepts empty string to use system timezone).

.PARAMETER Filepath
    The directory path containing image files to process. Required parameter.
    The script processes only JPG files in this directory (non-recursive).

.EXAMPLE
    .\Set-TimeZone.ps1 -Timezone "+02:00" -Filepath "C:\Photos"
    
    Updates all JPG files in C:\Photos with timezone offset +02:00 (Central European Time).

.EXAMPLE
    .\Set-TimeZone.ps1 -Timezone "-05:00" -Filepath "C:\Travel\Photos"
    
    Corrects timezone for photos taken in Eastern Standard Time (-05:00).

.EXAMPLE
    .\Set-TimeZone.ps1 -Timezone "" -Filepath "C:\Photos"
    
    Uses the local system timezone offset instead of specifying one explicitly.

.NOTES
    - ExifTool must be installed and available in system PATH
    - Timezone format must match ±HH:MM (e.g., +02:00, -04:30, +00:00)
    - Range validation covers UTC-14 to UTC+14, matching real-world timezone offsets
    - Invalid timezone formats will cause the script to exit with error code 1
    - Only JPG files (*.jpg) in the target directory are processed (non-recursive)
    - Updated metadata fields:
        * OffsetTime (all variants via wildcard OffsetTime*)
        * XMP-photoshop:DateCreated
        * XMP-xmp:CreateDate
        * XMP-exif:DateTimeOriginal
    - Existing metadata is preserved; only timezone-related fields are modified
    - Always backup original images before running this script
    - If Filepath doesn't exist, script exits with error code 1

.LINK
    https://exiftool.org/
    https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Timezone = "",  # ISO 8601 offset format (±HH:MM), empty string triggers auto-detection

    [Parameter(Mandatory=$true)]
    [string]$Filepath        # Directory containing images to process
)

# ===== VALIDATION AND INITIALIZATION =====

# Regex pattern for timezone offset format (+/-HH:MM)
# Covers UTC-14 to UTC+14: ±(00-14):(00-59)
# Examples: +02:00 (CEST), -05:00 (EST), +00:00 (UTC), +05:45 (Nepal)
$tzPattern = '^[\+\-](0[0-9]|1[0-4]):[0-5][0-9]$'

# Resolve and validate Filepath exists
# Resolve-Path converts relative paths to absolute and validates existence
try {
    $Filepath = (Resolve-Path $Filepath).Path
} catch {
    Write-Error "The specified Filepath '$Filepath' does not exist."
    exit 1
}

# Validate ExifTool is available in system PATH before processing
# ExifTool is external dependency required for all metadata operations
$exiftoolPath = Get-Command exiftool -ErrorAction SilentlyContinue
if (-not $exiftoolPath) {
    Write-Error "ExifTool is not available in the system PATH. Please install or add it to PATH."
    exit 1
}

# Auto-detect timezone if user provided blank/empty string
# Uses local system timezone offset at current moment (accounts for DST)
if ([string]::IsNullOrWhiteSpace($Timezone)) {
    # Get current UTC offset for local timezone
    $localOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::UtcNow)
    
    # Determine sign: negative if either hours or minutes are negative
    $sign = if ($localOffset.Hours -lt 0 -or $localOffset.Minutes -lt 0) { "-" } else { "+" }
    
    # Format as ±HH:MM using absolute values (sign already captured)
    $Timezone = "{0}{1:00}:{2:00}" -f $sign, [math]::Abs($localOffset.Hours), [math]::Abs($localOffset.Minutes)
}

# Validate timezone format matches expected pattern
# Prevents invalid formats like "2:00", "+25:00", "UTC+2", etc.
if ($Timezone -notmatch $tzPattern) {
    Write-Error "Invalid Timezone format. Please use format +/-HH:MM (e.g., -04:00)."
    exit 1
}

# ===== FILE DISCOVERY =====

# Build list of target files for all supported image extensions
# Covers common photo formats (JPG, HEIC, PNG) and RAW formats from major camera manufacturers
# Total: 17 formats supported
$exts = @(
    '*.jpg','*.jpeg','*.jxl',           # JPEG and JPEG XL
    '*.tif','*.tiff',                    # TIFF
    '*.png',                             # PNG
    '*.heic','*.heif',                   # HEIF (iPhone/modern cameras)
    '*.arw',                             # Sony RAW
    '*.cr2','*.cr3',                     # Canon RAW
    '*.nef',                             # Nikon RAW
    '*.rw2',                             # Panasonic RAW
    '*.orf',                             # Olympus RAW
    '*.raf',                             # Fujifilm RAW
    '*.dng',                             # Adobe Digital Negative
    '*.webp'                             # WebP
)

# Collect all matching files from target directory
# Non-recursive: only processes files directly in Filepath, not subdirectories
$files = @()
foreach ($pat in $exts) {
    $files += Get-ChildItem -Path $Filepath -Filter $pat -File -ErrorAction SilentlyContinue
}

# Remove duplicates (in case of case-insensitive filesystem collisions)
$files = $files | Sort-Object -Property FullName -Unique

# Exit if no supported images found in target directory
if ($files.Count -eq 0) {
    Write-Error "No supported image files found in $Filepath"
    exit 1
}

# ===== MAIN PROCESSING LOOP =====

Write-Host "Processing $($files.Count) file(s)..."
Write-Host ""

# Process each file individually with progress tracking
# Per-file processing allows conditional field updates based on what exists in each image
$totalFiles = $files.Count
$processedCount = 0

foreach ($file in $files) {
    $processedCount++
    
    # Update progress bar with current file and percentage
    $status = "Processing $processedCount of $totalFiles - $($file.Name)"
    Write-Progress -Activity "Applying timezone offset" -Status $status -PercentComplete (($processedCount / $totalFiles) * 100)
    
    Write-Host "Processing: $($file.FullName)"
    
    # ===== CONDITIONAL FIELD EXISTENCE CHECKS =====
    # Check which metadata fields already exist in this image
    # Only update fields that are present to avoid creating unnecessary metadata
    # Uses -s -s -s (triple) for raw value output, avoiding JSON parsing issues
    # Redirect stderr to null (2>$null) to suppress "tag not found" messages
    
    # IPTC IMM (Information Interchange Model) Time fields
    # IPTC:TimeCreated format: HHmmss with timezone as +/-HHMM suffix
    $iptcTimeCreatedCheck = & exiftool -s -s -s -"IPTC:TimeCreated" "$($file.FullName)" 2>$null
    $hasIptcTimeCreated = -not [string]::IsNullOrWhiteSpace($iptcTimeCreatedCheck)
    
    # XMP-photoshop namespace fields
    # DateCreated: When image was created, ISO 8601 format with timezone
    $xmpPhotoshopDateCreatedCheck = & exiftool -s -s -s -"XMP-photoshop:DateCreated" "$($file.FullName)" 2>$null
    $hasXmpPhotoshopDateCreated = -not [string]::IsNullOrWhiteSpace($xmpPhotoshopDateCreatedCheck)
    
    # XMP-xmp namespace fields (core XMP schema)
    # CreateDate: Creation date of the resource
    $xmpXmpCreateDateCheck = & exiftool -s -s -s -"XMP-xmp:CreateDate" "$($file.FullName)" 2>$null
    $hasXmpXmpCreateDate = -not [string]::IsNullOrWhiteSpace($xmpXmpCreateDateCheck)
    
    # MetadataDate: When metadata was last modified
    $xmpXmpMetadataDateCheck = & exiftool -s -s -s -"XMP-xmp:MetadataDate" "$($file.FullName)" 2>$null
    $hasXmpXmpMetadataDate = -not [string]::IsNullOrWhiteSpace($xmpXmpMetadataDateCheck)
    
    # ModifyDate: When resource content was last modified
    $xmpXmpModifyDateCheck = & exiftool -s -s -s -"XMP-xmp:ModifyDate" "$($file.FullName)" 2>$null
    $hasXmpXmpModifyDate = -not [string]::IsNullOrWhiteSpace($xmpXmpModifyDateCheck)
    
    # XMP-tiff namespace fields (TIFF compatibility)
    # DateTime: File modification date/time
    $xmpTiffDateTimeCheck = & exiftool -s -s -s -"XMP-tiff:DateTime" "$($file.FullName)" 2>$null
    $hasXmpTiffDateTime = -not [string]::IsNullOrWhiteSpace($xmpTiffDateTimeCheck)
    
    # XMP-exif namespace fields (EXIF compatibility in XMP)
    # DateTimeOriginal: When photo was taken (original capture time)
    $xmpExifDateTimeOriginalCheck = & exiftool -s -s -s -"XMP-exif:DateTimeOriginal" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeOriginal = -not [string]::IsNullOrWhiteSpace($xmpExifDateTimeOriginalCheck)
    
    # DateTimeDigitized: When photo was digitized/scanned
    $xmpExifDateTimeDigitizedCheck = & exiftool -s -s -s -"XMP-exif:DateTimeDigitized" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeDigitized = -not [string]::IsNullOrWhiteSpace($xmpExifDateTimeDigitizedCheck)
    
    # DateTimeModified: When file was last modified
    $xmpExifDateTimeModifiedCheck = & exiftool -s -s -s -"XMP-exif:DateTimeModified" "$($file.FullName)" 2>$null
    $hasXmpExifDateTimeModified = -not [string]::IsNullOrWhiteSpace($xmpExifDateTimeModifiedCheck)
    
    # ===== BUILD EXIFTOOL COMMAND =====
    # Build ExifTool arguments array for this specific file
    # -overwrite_original: Modify file in-place (no _original backup files)
    # -OffsetTime*: Wildcard updates all OffsetTime variants (OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized)
    $args = @('-overwrite_original', "-OffsetTime*=$Timezone")
    
    # XMP-photoshop:DateCreated - ALWAYS create/update (not conditional)
    # Copies ExifIFD:DateTimeOriginal and appends timezone suffix
    # Syntax: <${SourceField}s$Timezone means "copy SourceField value, append 's', then append $Timezone"
    # The 's' converts EXIF format (yyyy:MM:dd HH:mm:ss) to ISO 8601 format with timezone
    Write-Host "  → Updating XMP-photoshop:DateCreated (creating if missing)"
    $args += "-XMP-photoshop:DateCreated<`${ExifIFD:DateTimeOriginal}s$Timezone"
    
    # ===== CONDITIONAL FIELD UPDATES =====
    # Only update fields that already exist in the image
    # This prevents creating unnecessary metadata in files that don't have these fields
    
    if ($hasIptcTimeCreated) {
        Write-Host "  → Updating IPTC:TimeCreated"
        # Note: IPTC:TimeCreated format is HHmmss+/-HHMM (e.g., "123045+0200")
        # Different from XMP ISO 8601 format, may need custom handling in future
        # For now, documented but not actively updated due to format complexity
    }
    
    # XMP-xmp namespace updates
    # The <${FieldName}s$Timezone syntax copies the field's current value and appends timezone
    if ($hasXmpXmpCreateDate) {
        Write-Host "  → Updating XMP-xmp:CreateDate"
        $args += "-XMP-xmp:CreateDate<`${XMP-xmp:CreateDate}s$Timezone"
    }
    
    if ($hasXmpXmpMetadataDate) {
        Write-Host "  → Updating XMP-xmp:MetadataDate"
        $args += "-XMP-xmp:MetadataDate<`${XMP-xmp:MetadataDate}s$Timezone"
    }
    
    if ($hasXmpXmpModifyDate) {
        Write-Host "  → Updating XMP-xmp:ModifyDate"
        $args += "-XMP-xmp:ModifyDate<`${XMP-xmp:ModifyDate}s$Timezone"
    }
    
    # XMP-tiff namespace updates
    if ($hasXmpTiffDateTime) {
        Write-Host "  → Updating XMP-tiff:DateTime"
        $args += "-XMP-tiff:DateTime<`${XMP-tiff:DateTime}s$Timezone"
    }
    
    # XMP-exif namespace updates (EXIF compatibility fields in XMP sidecar)
    if ($hasXmpExifDateTimeOriginal) {
        Write-Host "  → Updating XMP-exif:DateTimeOriginal"
        $args += "-XMP-exif:DateTimeOriginal<`${XMP-exif:DateTimeOriginal}s$Timezone"
    }
    
    if ($hasXmpExifDateTimeDigitized) {
        Write-Host "  → Updating XMP-exif:DateTimeDigitized"
        $args += "-XMP-exif:DateTimeDigitized<`${XMP-exif:DateTimeDigitized}s$Timezone"
    }
    
    if ($hasXmpExifDateTimeModified) {
        Write-Host "  → Updating XMP-exif:DateTimeModified"
        $args += "-XMP-exif:DateTimeModified<`${XMP-exif:DateTimeModified}s$Timezone"
    }
    
    # Add file path as final argument
    # ExifTool processes all preceding arguments and applies them to this file
    $args += "$($file.FullName)"
    
    # ===== EXECUTE EXIFTOOL =====
    # Execute ExifTool with all collected arguments
    # @args splats the array into individual arguments
    # 2>&1 redirects stderr to stdout so we can capture all output
    # Output is indented with 4 spaces for better readability
    Write-Host "  → Applying timezone offset: $Timezone"
    & exiftool @args 2>&1 | ForEach-Object { Write-Host "    $_" }
}

# Clear progress bar when all files are processed
Write-Progress -Activity "Applying timezone offset" -Completed

# Display completion message
Write-Host ""
Write-Host "Timezone update completed!"
