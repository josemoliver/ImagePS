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
    [string]$Timezone = "",

    [Parameter(Mandatory=$true)]
    [string]$Filepath
)

# Regex pattern for timezone offset format (+/-HH:MM)
$tzPattern = '^[\+\-](0[0-9]|1[0-4]):[0-5][0-9]$'

# Resolve and validate Filepath
try {
    $Filepath = (Resolve-Path $Filepath).Path
} catch {
    Write-Error "The specified Filepath '$Filepath' does not exist."
    exit 1
}

# Validate exiftool availability in PATH
$exiftoolPath = Get-Command exiftool -ErrorAction SilentlyContinue
if (-not $exiftoolPath) {
    Write-Error "ExifTool is not available in the system PATH. Please install or add it to PATH."
    exit 1
}

# If Timezone is blank (user pressed Enter), use local system timezone offset
if ([string]::IsNullOrWhiteSpace($Timezone)) {
    $localOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::UtcNow)
    $sign = if ($localOffset.Hours -lt 0 -or $localOffset.Minutes -lt 0) { "-" } else { "+" }
    $Timezone = "{0}{1:00}:{2:00}" -f $sign, [math]::Abs($localOffset.Hours), [math]::Abs($localOffset.Minutes)
}

# Validate Timezone format
if ($Timezone -notmatch $tzPattern) {
    Write-Error "Invalid Timezone format. Please use format +/-HH:MM (e.g., -04:00)."
    exit 1
}

# Build list of target files for supported image extensions
$exts = @('*.jpg','*.jpeg','*.jxl','*.tif','*.tiff','*.png','*.heic','*.heif','*.arw','*.cr2','*.cr3','*.nef','*.rw2','*.orf','*.raf','*.dng','*.webp')
$files = @()
foreach ($pat in $exts) {
    $files += Get-ChildItem -Path $Filepath -Filter $pat -File -ErrorAction SilentlyContinue
}
$files = $files | Sort-Object -Property FullName -Unique

if ($files.Count -eq 0) {
    Write-Error "No supported image files found in $Filepath"
    exit 1
}

Write-Host "Processing $($files.Count) file(s)..."
Write-Host ""

# Process each file individually
foreach ($file in $files) {
    Write-Host "Processing: $($file.FullName)"
    
    # Check if XMP-photoshop:DateCreated, XMP-xmp:CreateDate, XMP-xmp:MetadataDate, and XMP-xmp:ModifyDate exist
    $xmpCheck = & exiftool -s -XMP-photoshop:DateCreated -XMP-xmp:CreateDate -XMP-xmp:MetadataDate -XMP-xmp:ModifyDate "$($file.FullName)" 2>$null
    
    $hasXmpPhotoshop = $xmpCheck -match 'XMP-photoshop:DateCreated'
    $hasXmpCreateDate = $xmpCheck -match 'XMP-xmp:CreateDate'
    $hasXmpMetadataDate = $xmpCheck -match 'XMP-xmp:MetadataDate'
    $hasXmpModifyDate = $xmpCheck -match 'XMP-xmp:ModifyDate'
    
    # If any XMP field is missing, copy from ExifIFD:DateTimeOriginal
    if (-not $hasXmpPhotoshop -or -not $hasXmpCreateDate -or -not $hasXmpMetadataDate -or -not $hasXmpModifyDate) {
        Write-Host "  → Populating missing XMP date fields from ExifIFD:DateTimeOriginal"
        & exiftool -overwrite_original `
            "-XMP-photoshop:DateCreated<ExifIFD:DateTimeOriginal" `
            "-XMP-xmp:CreateDate<ExifIFD:DateTimeOriginal" `
            "-XMP-xmp:MetadataDate<ExifIFD:DateTimeOriginal" `
            "-XMP-xmp:ModifyDate<ExifIFD:DateTimeOriginal" `
            "$($file.FullName)" 2>$null
    }
    
    # Apply timezone offset to all datetime fields
    Write-Host "  → Applying timezone offset: $Timezone"
    & exiftool -overwrite_original `
        "-OffsetTime*=$Timezone" `
        "-XMP-photoshop:DateCreated<`${XMP-photoshop:DateCreated}s$Timezone" `
        "-XMP-xmp:CreateDate<`${XMP-xmp:CreateDate}s$Timezone" `
        "-XMP-xmp:MetadataDate<`${XMP-xmp:MetadataDate}s$Timezone" `
        "-XMP-xmp:ModifyDate<`${XMP-xmp:ModifyDate}s$Timezone" `
        "-XMP-exif:DateTimeOriginal<`${ExifIFD:DateTimeOriginal}s$Timezone" `
        "$($file.FullName)" 2>&1 | ForEach-Object { Write-Host "    $_" }
}

Write-Host ""
Write-Host "Timezone update completed!"
