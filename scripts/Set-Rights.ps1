<#
.SYNOPSIS
    Sets creator and copyright metadata on image files using ExifTool and MWG standards.

.DESCRIPTION
    This script batch processes image files to set creator (author) and copyright information
    in EXIF, IPTC, and XMP metadata. It uses ExifTool with an arguments file to ensure proper
    UTF-8 encoding for international character support.

.PARAMETER Name
    The name of the creator/author to set in the metadata. This value is applied to the
    mwg:creator tag across all processed images. Required parameter.

.PARAMETER Filepath
    The directory path containing image files to process. This parameter is required.
    Use with -Recurse to process subdirectories.

.PARAMETER Year
    The copyright year to apply. Defaults to the current year (Get-Date).Year.
    Used in the copyright statement: "© Copyright [Year] [Name]. All rights reserved"

.PARAMETER Recurse
    Switch parameter. When specified, the script processes image files in subdirectories
    recursively. Omit this parameter to process only files in the specified directory.

.EXAMPLE
    .\Set-Rights.ps1 -Name "Jane Doe" -Filepath "C:\Photos"
    
    Sets creator to "Jane Doe" and copyright year to current year for all images in C:\Photos.

.EXAMPLE
    .\Set-Rights.ps1 -Name "John Smith" -Filepath "C:\Photos" -Year 2023 -Recurse
    
    Recursively processes all images in C:\Photos and subdirectories, setting creator to
    "John Smith" and copyright year to 2023.

.NOTES
    - ExifTool must be installed and available in system PATH
    - Metadata is written in UTF-8 without BOM for proper international character handling
    - All existing metadata is preserved; only creator and copyright tags are modified
    - Uses MWG (Metadata Working Group) standard tags: mwg:creator, mwg:copyright
    - Supported image formats: JPG, JPEG, PNG, TIF, TIFF, HEIC, HEIF
    - Always backup original images before running this script
    - The script creates a temporary ExifTool arguments file which is cleaned up after execution

.LINK
    https://exiftool.org/
    https://www.metadataworkinggroup.org/
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Filepath,

    [int]$Year = (Get-Date).Year,

    [switch]$Recurse
)

# --- Configuration ---
$exiftool = "exiftool"   # ensure exiftool is in PATH

if (-not (Get-Command $exiftool -ErrorAction SilentlyContinue)) {
    throw "ExifTool not found. Ensure it is installed and in your PATH."
}

if (-not (Test-Path $Filepath)) {
    throw "The specified path does not exist: $Filepath"
}

# Build copyright - Example: © Copyright 2025 Jane Doe. All rights reserved.
$copyright = "© Copyright $Year $Name. All rights reserved"

Write-Host "Creator:   $Name"
Write-Host "Year:      $Year"
Write-Host "Copyright: $copyright"
Write-Host ""

# --- discover files reliably ---
$extensions = @(
    ".jpg",
    ".jpeg",
    ".jxl",
    ".png",
    ".tif",
    ".tiff",
    ".heic",
    ".heif",
    ".arw",
    ".cr2",
    ".cr3",
    ".nef",
    ".rw2",
    ".orf",
    ".raf",
    ".dng",
    ".webp"
)
$files = Get-ChildItem -Path $Filepath -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
         Where-Object { $extensions -contains $_.Extension.ToLower() }

if ($files.Count -eq 0) {
    Write-Host "No image files found in: $Filepath"
    exit
}

Write-Host "Processing $($files.Count) files..."
Write-Host ""

# --- Prepare ExifTool args file (UTF-8 without BOM) ---
# We'll write each argument on a separate line. ExifTool reads this file as UTF-8.
$tempArgsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "exif_args_{0}.txt" -f ([Guid]::NewGuid().ToString()))
$argLines = @(
    "-charset",
    "filename=utf8",
    "-charset",
    "exif=utf8",
    "-charset",
    "iptc=utf8",
    "-charset",
    "xmp=utf8",

    "-mwg:creator=$Name",
    "-mwg:copyright=$copyright"
)


# Write file as UTF8 without BOM to avoid some programs treating BOM oddly
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($tempArgsFile, $argLines, $utf8NoBom)

try {
    foreach ($file in $files) {
        Write-Host "Updating: $($file.FullName)"

        # Call exiftool with -overwrite_original and -@ argsfile then the filename.
        # The '--' marks the end of options so filenames starting with '-' are safe.
        & $exiftool -overwrite_original -@ $tempArgsFile -- "$($file.FullName)" 2>&1 | ForEach-Object { Write-Host $_ }
    }
}
finally {
    # Cleanup the temporary args file
    if (Test-Path $tempArgsFile) {
        Remove-Item $tempArgsFile -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Metadata update completed!"
