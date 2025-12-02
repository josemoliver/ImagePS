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

# Build copyright
$copyright = "© Copyright $Year $Name. All Rights Reserved."

Write-Host "Creator:   $Name"
Write-Host "Year:      $Year"
Write-Host "Copyright: $copyright"
Write-Host ""

# --- discover files reliably ---
$extensions = @(".jpg",".jpeg",".png",".tif",".tiff",".heic",".heif")
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
