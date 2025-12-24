<#
.SYNOPSIS
    Losslessly rotate/mirror images based on EXIF Orientation and set Orientation to 1.

.DESCRIPTION
    Reads EXIF Orientation using ExifTool. If Orientation exists and is not 1,
    performs a lossless transform to normalize the image data and updates the
    EXIF Orientation tag to 1. If Orientation is missing or empty, the file is
    skipped.

.PARAMETER Path
    Single file or directory to process.

.PARAMETER Recursive
    When set and Path is a directory, process files in subdirectories.

.NOTES
    - Requires `exiftool` in PATH.
    - Uses `jpegtran` for JPEG lossless rotations. If `jpegtran` is not available,
      falls back to updating Orientation to 1 only (no pixel transform).
    - Other image formats are handled by ExifTool-only update (if transform tool
      for that format is not available) to avoid lossy conversions.
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Path,

    [switch]$Recursive
)

Set-StrictMode -Version Latest

function Write-ErrorAndExit($msg) {
    Write-Error $msg
    exit 1
}

# Validate ExifTool availability
$exiftool = Get-Command exiftool -ErrorAction SilentlyContinue
if (-not $exiftool) {
    Write-ErrorAndExit 'ExifTool not found in PATH. Install exiftool and retry.'
}

# Check for jpegtran for lossless JPEG transforms
$jpegtran = Get-Command jpegtran -ErrorAction SilentlyContinue

# Supported extensions (lowercase)
$extensions = @('.jpg','.jpeg','.jxl','.png','.tif','.tiff','.heic','.heif','.webp')

function Get-FilesToProcess([string]$inputPath, [bool]$recurse) {
    if (Test-Path $inputPath -PathType Leaf) {
        return ,(Get-Item -LiteralPath $inputPath)
    }

    if (Test-Path $inputPath -PathType Container) {
        if ($recurse) {
            return Get-ChildItem -LiteralPath $inputPath -File -Recurse | Where-Object { $extensions -contains $_.Extension.ToLower() }
        }
        else {
            return Get-ChildItem -LiteralPath $inputPath -File | Where-Object { $extensions -contains $_.Extension.ToLower() }
        }
    }

    Write-ErrorAndExit "Path not found: $inputPath"
}

function Read-Orientation($file) {
    $cmd = "-s -s -s -Orientation# `"$($file)`""
    $out = & exiftool -s -s -s -Orientation# -- "$file" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $val = $out -as [string]
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    return [int]$val
}

function Update-OrientationTag($file) {
    # Set numeric orientation to 1 and overwrite original
    & exiftool -overwrite_original -Orientation#=1 -- "$file" | Out-Null
    return $LASTEXITCODE -eq 0
}

function Do-JPEG-Transform($file, $orientation) {
    if (-not $jpegtran) { return $false }

    # Build jpegtran arguments for lossless rotation/mirror
    $args = @()
    switch ($orientation) {
        2 { $args += '-transpose' }        # mirror horizontal
        3 { $args += '-rotate' ; $args += '180' }
        4 { $args += '-transverse' }       # mirror vertical
        5 { $args += '-transpose' ; $args += '-rotate' ; $args += '90' }  # mirror horizontal and rotate 270CW -> complex
        6 { $args += '-rotate' ; $args += '90' }
        7 { $args += '-transverse' ; $args += '-rotate' ; $args += '270' }
        8 { $args += '-rotate' ; $args += '270' }
        default { return $false }
    }

    # jpegtran doesn't accept combined options like -rotate 90 for some builds; prefer -rotate 90
    $tmp = [System.IO.Path]::GetTempFileName()
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $tmpOut = $tmp + (Get-Item $file).Extension

    # Prepare command: jpegtran [opts] -outfile tmpOut infile
    $cmd = @($args) + @('-outfile', $tmpOut, $file)
    try {
        & jpegtran @cmd | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpOut)) {
            Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
            return $false
        }

        # Replace original with transformed file, preserving attributes
        Copy-Item -LiteralPath $tmpOut -Destination $file -Force
        Remove-Item -LiteralPath $tmpOut -Force
        return $true
    }
    catch {
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        return $false
    }
}

# Main processing
$items = Get-FilesToProcess -inputPath $Path -recurse:$Recursive.IsPresent
$count = $items.Count
if ($count -eq 0) { Write-Host 'No supported image files found.'; exit 0 }

$i = 0
foreach ($item in $items) {
    $i++
    $file = $item.FullName
    Write-Host "[$i/$count] Processing: $file"

    $orientation = Read-Orientation $file
    if ($null -eq $orientation) {
        Write-Host "  Orientation: (missing) — skipping"
        continue
    }

    if ($orientation -eq 1) {
        Write-Host "  Orientation: 1 (normal) — skipping"
        continue
    }

    Write-Host "  Orientation: $orientation — transforming"

    $ext = $item.Extension.ToLower()
    $transformed = $false

    if ($ext -in @('.jpg','.jpeg') -and $jpegtran) {
        $transformed = Do-JPEG-Transform -file $file -orientation $orientation
        if (-not $transformed) {
            Write-Host "  JPEG transform failed or not supported — will update metadata only"
        }
    }

    # After applying pixel transform (if any), set Orientation tag to 1
    $ok = Update-OrientationTag -file $file
    if ($ok) {
        Write-Host "  Orientation tag set to 1"
    }
    else {
        Write-Host "  Failed to update Orientation tag"
    }
}

Write-Host 'Processing complete.'
