<# 
.SYNOPSIS
    Adds a dashless GUID to the ImageUniqueID tag of image files (using ExifTool).

.PARAMETER Filepath
    The folder path containing image files.

.PARAMETER Extensions
    File extensions to process. Default: jpg

.PARAMETER Recurse
    Process files recursively.

.EXAMPLE
    ./Set-ImageUniqueID.ps1 -Path "C:\Photos" -Recurse
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Filepath,

    [string[]]$Extensions = @("jpg"),

    [switch]$Recurse
)

# Global error behavior
$ErrorActionPreference = "Stop"

try {
    # Validate input path
    if (-not (Test-Path -LiteralPath $Filepath)) {
        throw "ERROR: The path '$Path' does not exist."
    }

    # Build search parameters
    $searchParams   = @{
        Path    = $Filepath
        File        = $true
        Recurse     = $Recurse.IsPresent
    }

    # Collect files
    $allFiles = @()
    foreach ($ext in $Extensions) {
        $allFiles += Get-ChildItem @searchParams -Filter "*.$ext" -ErrorAction Stop
    }

    if ($allFiles.Count -eq 0) {
        Write-Warning "No image files found with extensions: $($Extensions -join ', ')"
        return
    }

    $total = $allFiles.Count
    $index = 0

    foreach ($file in $allFiles) {

        $index++

        $status = "Processing $index of $total - $($file.Name)"

        Write-Progress `
            -Activity "Updating ImageUniqueID" `
            -Status $status `
            -PercentComplete (($index / $total) * 100)

        try {
            $full = $file.FullName

            # Read existing tag
            $uid = exiftool -s3 -ImageUniqueID "$full" 2>$null

            if ([string]::IsNullOrWhiteSpace($uid)) {

                # Create GUID without dashes
                $guid = ([guid]::NewGuid().ToString("N"))

                # Write EXIF tag
                $result = exiftool -overwrite_original "-ImageUniqueID=$guid" "$full" 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to write ImageUniqueID for '$full': $result"
                }
                else {
                    Write-Host "→ Set GUID $guid for: $full"
                }
            }
            else {
                Write-Host "✓ Skipped (already has ImageUniqueID): $full"
            }
        }
        catch {
            Write-Error "Unexpected error with file '$full': $_"
        }

    } # end foreach

    Write-Host ""
    Write-Host "Completed. Processed $total file(s)."

}
catch {
    Write-Error $_
}
