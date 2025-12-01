 # Add GUIDs to ImageUniqueID metadata field for image files in a specified folder.

function Set-ImageUniqueID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        # Default extensions
        [string[]]$Extensions = @("jpg"),

        # Include subdirectories
        [switch]$Recurse
    )

    try {
        # Validate folder
        if (-not (Test-Path $Path)) {
            throw "ERROR: The path '$Path' does not exist."
        }

        # Prepare search parameters
        $searchParams = @{
            Path        = $Path
            Recurse     = $Recurse.IsPresent
            File        = $true
        }

        # Gather all matching files
        $allFiles = foreach ($ext in $Extensions) {
            Get-ChildItem @searchParams -Filter "*.$ext" -ErrorAction Stop
        }

        if ($allFiles.Count -eq 0) {
            Write-Warning "No image files found with extensions: $($Extensions -join ', ')"
            return
        }

        $total = $allFiles.Count
        $index = 0

        foreach ($file in $allFiles) {
            $index++

            # --- Progress Bar ---
            $percent = [math]::Round(($index / $total) * 100, 2)
            Write-Progress `
                -Activity "Updating ImageUniqueID" `
                -Status "Processing $index of $total: $($file.Name)" `
                -PercentComplete $percent

            try {
                $full = $file.FullName

                # Read existing metadata (safe mode)
                $uid = exiftool -s3 -ImageUniqueID "$full" 2>$null

                if ([string]::IsNullOrWhiteSpace($uid)) {
                    # Generate dashless GUID
                    $guid = ([guid]::NewGuid().ToString("N"))

                    # Attempt to set the field
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
        }

        Write-Host "`nCompleted. Processed $total file(s)."
    }
    catch {
        Write-Error $_
    }
}

Export-ModuleMember -Function Set-ImageUniqueID
