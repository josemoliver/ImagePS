<#
.SYNOPSIS
    Adds a dashless GUID to the ImageUniqueID tag of image files (using ExifTool).

.DESCRIPTION
    Streams image files from a target folder and assigns a dashless GUID to the
    ImageUniqueID EXIF tag for files that don't already have one. Designed for
    large collections: the script avoids building large in-memory file arrays and
    provides a progress indicator.

.PARAMETER Filepath
    The folder path containing image files.

.PARAMETER Extensions
    File extensions to process. Defaults to common EXIF-capable formats.

.PARAMETER Recurse
    Process files recursively when specified.

.PARAMETER Parallel
    When supplied and running under PowerShell 7+, performs writes in parallel using
    `ForEach-Object -Parallel` with a throttle limit. Falls back to serial mode on
    older PowerShell versions.

.PARAMETER ThrottleLimit
    Maximum number of concurrent exiftool processes when `-Parallel` is used. Default: 2

.PARAMETER BatchSize
    Number of files per batch when querying ExifTool for existing ImageUniqueID values. Default: 200

.EXAMPLE
    ./Set-ImageUniqueID.ps1 -Filepath "C:\Photos" -Recurse

#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Filepath,  # Directory containing images to process

    # Supported image extensions (17 formats)
    # Common: JPG, JXL, PNG, HEIC, HEIF, TIFF, WEBP
    # RAW: ARW (Sony), CR2/CR3 (Canon), NEF (Nikon), RW2 (Panasonic), ORF (Olympus), RAF (Fujifilm), DNG (Adobe)
    # Note: Extensions provided WITHOUT leading dots
    [string[]]$Extensions = @(
        "jpg",
        "jpeg",
        "jxl",
        "png",
        "tif",
        "tiff",
        "heic",
        "heif",
        "arw",
        "cr2",
        "cr3",
        "nef",
        "rw2",
        "orf",
        "raf",
        "dng",
        "webp"
    ),

    [switch]$Recurse,        # Process subdirectories recursively
    [switch]$Parallel,       # Enable parallel processing (PowerShell 7+ only)
    [int]$ThrottleLimit = 2, # Max concurrent ExifTool processes in parallel mode (default: 2 to avoid overwhelming system)
    [int]$BatchSize = 200    # Files per batch for reading/writing (larger = fewer ExifTool calls, more memory)
)

# ===== SCRIPT INITIALIZATION =====
# Global error behavior: Stop on any error for fail-fast debugging
$ErrorActionPreference = "Stop"

# ExifTool executable name/path
# Assumes exiftool is in system PATH; can be overridden to full path if needed
$exiftool = "exiftool"

try {
    # ===== PATH VALIDATION =====
    # Validate target directory exists before processing
    if (-not (Test-Path -LiteralPath $Filepath)) {
        throw "ERROR: The path '$Filepath' does not exist."
    }

    # ===== FILE COUNTING =====
    # Calculate total file count for progress tracking
    # Uses per-extension counting to avoid building large in-memory arrays
    # Memory-efficient approach: count files without storing file objects
    $total = 0
    foreach ($ext in $Extensions) {
        try {
            # Count files for this extension
            # -File: Only files, not directories
            # -Recurse:$Recurse.IsPresent: Conditional recursion based on switch
            $count = (Get-ChildItem -Path $Filepath -Filter "*.$ext" -File -Recurse:$Recurse.IsPresent -ErrorAction Stop | Measure-Object).Count
            $total += $count
        } catch {
            # Ignore errors for inaccessible directories or specific extensions
            # Allows partial processing even if some paths fail
        }
    }

    # Exit early if no supported files found
    if ($total -eq 0) {
        Write-Warning "No image files found with extensions: $($Extensions -join ', ')"
        return
    }

    $index = 0  # Track current file index for progress reporting

    # ===== BATCH SCANNING STRATEGY =====
    # Build list of files that need ImageUniqueID using chunked batch reads
    # Strategy: Process files in batches to minimize ExifTool process invocations
    # Performance: 10,000 files with BatchSize=200 = 50 ExifTool calls instead of 10,000
    Write-Host "Scanning files in batches (BatchSize=$BatchSize) to determine missing ImageUniqueID..."
    
    # List to collect files needing writes (only files without ImageUniqueID)
    $needWriteFiles = [System.Collections.Generic.List[string]]::new()
    
    # Current batch being accumulated
    $batch = New-Object System.Collections.ArrayList

    # Helper function: Process accumulated batch of files
    # Reads ImageUniqueID from all files in batch using single ExifTool call
    function Flush-Batch {
        param($batchList)
        
        # Skip empty batches
        if ($batchList.Count -eq 0) { return }
        
        # Create temporary args file with one filename per line
        # ExifTool -@ option reads filenames from file (handles special characters)
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            # Write batch file list to temp file
            $batchList | ForEach-Object { $_ } | Out-File -FilePath $tmp -Encoding utf8
            
            # Execute ExifTool with batch file list
            # -j: JSON output for reliable parsing
            # -ImageUniqueID: Only read this field (faster than reading all metadata)
            # -@ $tmp: Read file list from temp file
            # 2>$null: Suppress stderr ("tag not found" messages)
            $jsonOut = & $exiftool -j -ImageUniqueID -@ $tmp 2>$null
            
            if ($jsonOut) {
                # Parse JSON output
                try {
                    $objs = $jsonOut | ConvertFrom-Json
                } catch {
                    $objs = @()  # Failed to parse, treat as empty
                }
                
                # Check each file's ImageUniqueID field
                # JSON array order matches input file order
                for ($i = 0; $i -lt $objs.Count; $i++) {
                    $obj = $objs[$i]
                    $path = $batchList[$i]
                    
                    # Add to write list if ImageUniqueID is missing or empty
                    if (-not $obj.ImageUniqueID -or [string]::IsNullOrWhiteSpace($obj.ImageUniqueID)) {
                        [void]$needWriteFiles.Add($path)
                    }
                    # Files with existing ImageUniqueID are skipped (not added to needWriteFiles)
                }
            }
        }
        finally {
            # Cleanup temporary args file
            if (Test-Path $tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        
        # Clear batch for reuse
        $batchList.Clear()
    }

    # ===== FILE ENUMERATION =====
    # Stream files by extension and accumulate in batches
    # Memory-efficient: Processes files as enumerated, doesn't load all files into memory
    foreach ($ext in $Extensions) {
        # Get enumerator for this extension
        # Files are processed one-by-one as they're discovered (streaming)
        $enumerator = Get-ChildItem -Path $Filepath -Filter "*.$ext" -File -Recurse:$Recurse.IsPresent -ErrorAction SilentlyContinue
        
        foreach ($file in $enumerator) {
            $index++
            
            # Update progress bar with current file
            $status = "Scanning $index of $total - $($file.Name)"
            Write-Progress -Activity "Scanning files (batch)" -Status $status -PercentComplete (($index / $total) * 100)
            
            # Add file to current batch
            [void]$batch.Add($file.FullName)
            
            # Flush batch when it reaches BatchSize
            # This triggers ExifTool to read ImageUniqueID for all files in batch
            if ($batch.Count -ge $BatchSize) {
                Flush-Batch $batch
            }
        }
    }
    
    # ===== FLUSH FINAL BATCH =====
    # Process any remaining files that didn't reach BatchSize threshold
    Flush-Batch $batch

    # Display scan results
    $needCount = $needWriteFiles.Count
    Write-Host "Scanning complete. $needCount files require ImageUniqueID."

    # ===== EXECUTION MODE SELECTION =====
    if ($needCount -eq 0) {
        # All files already have ImageUniqueID
        Write-Host "Nothing to do."
    }
    else {
        # ===== PARALLEL MODE (POWERSHELL 7+ ONLY) =====
        # Uses ForEach-Object -Parallel to process multiple files concurrently
        # Faster for large collections but requires PowerShell 7+
        if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7) {
            Write-Host "Writing $needCount files in parallel (ThrottleLimit=$ThrottleLimit)..."
            $processedCount = 0
            
            # Process files in parallel with throttle limit
            # ThrottleLimit controls max concurrent ExifTool processes
            # Lower values reduce system load, higher values increase throughput
            $results = $needWriteFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                $file = $_
                
                # Generate dashless GUID (32 hex characters, no hyphens)
                # Format "N" = no hyphens: 32 contiguous hex digits
                # Example: "550e8400e29b41d4a716446655440000"
                $guid = ([guid]::NewGuid().ToString("N"))
                
                # Execute ExifTool to write ImageUniqueID
                # $using: syntax accesses parent scope variable in parallel scriptblock
                # -overwrite_original: Modify file in-place (no backup)
                # 2>&1: Capture both stdout and stderr for error handling
                $res = & $using:exiftool -overwrite_original "-ImageUniqueID=$guid" $file 2>&1
                
                # Return result string for collection
                # Format: "OK|filepath|guid" or "ERR|filepath|exitcode|message"
                if ($LASTEXITCODE -ne 0) { "ERR|$file|$LASTEXITCODE|$res" } else { "OK|$file|$guid" }
            } | ForEach-Object {
                # Update progress as results stream back
                $processedCount++
                $status = "Writing $processedCount of $needCount"
                Write-Progress -Activity "Writing ImageUniqueID (parallel)" -Status $status -PercentComplete (($processedCount / $needCount) * 100)
                $_  # Pass result through pipeline
            }
            
            # Count successes and failures from result strings
            $ok = ($results | Where-Object { $_ -like 'OK|*' }).Count
            $err = ($results | Where-Object { $_ -like 'ERR|*' }).Count
            Write-Host "Completed parallel writes. Successes: $ok, Failures: $err"
        }
        else {
            # ===== SERIAL BATCH MODE =====
            # Default mode: Write files in batches using ExifTool args file
            # Works on PowerShell 5.1+ (no parallel support requirement)
            # More efficient than one-by-one: BatchSize=200 means 1 ExifTool call per 200 files
            Write-Host "Writing $needCount files serially in batches (BatchSize=$BatchSize)..."
            
            # ===== PRE-GENERATE GUIDS =====
            # Generate all GUIDs upfront and map to files
            # Ensures consistent GUID generation regardless of batch boundaries
            $fileGuidMap = @{}
            foreach ($file in $needWriteFiles) {
                # Generate dashless GUID (32 hex characters)
                # ImageUniqueID format: No hyphens, lowercase hex string
                $guid = ([guid]::NewGuid().ToString("N"))
                $fileGuidMap[$file] = $guid
            }
            
            # ===== BATCH ACCUMULATION =====
            # Accumulate files and GUIDs into batches for writing
            $writeBatch = New-Object System.Collections.ArrayList       # Files in current batch
            $writeBatchGuids = New-Object System.Collections.ArrayList  # Corresponding GUIDs
            $wIndex = 0  # Track overall progress
            
            # ===== BATCH WRITE LOOP =====
            # Accumulate files into batches and write using ExifTool args file
            foreach ($file in $needWriteFiles) {
                $wIndex++
                
                # Add file and its pre-generated GUID to current batch
                [void]$writeBatch.Add($file)
                [void]$writeBatchGuids.Add($fileGuidMap[$file])
                
                # Flush batch when it reaches BatchSize or this is the last file
                if ($writeBatch.Count -ge $BatchSize -or $wIndex -eq $needCount) {
                    # ===== WRITE BATCH =====
                    # Create temporary args file for ExifTool batch operation
                    $tmpArgs = [System.IO.Path]::GetTempFileName()
                    $tmpUnicodeFile = [System.IO.Path]::GetTempFileName()  # Reserved for future use
                    
                    try {
                        # ===== BUILD ARGS FILE =====
                        # ExifTool args file format:
                        # -overwrite_original (applies to all files)
                        # -ImageUniqueID=<guid1>
                        # <file1>
                        # -ImageUniqueID=<guid2>
                        # <file2>
                        # ...
                        $argLines = New-Object System.Collections.ArrayList
                        [void]$argLines.Add("-overwrite_original")  # Global option for batch
                        
                        # Add file-specific arguments
                        for ($i = 0; $i -lt $writeBatch.Count; $i++) {
                            $f = $writeBatch[$i]
                            $g = $writeBatchGuids[$i]
                            # Each file gets its own ImageUniqueID tag followed by filename
                            [void]$argLines.Add("-ImageUniqueID=$g")
                            [void]$argLines.Add($f)
                        }
                        
                        # ===== WRITE ARGS FILE =====
                        # Use UTF-8 without BOM for international filename support
                        # BOM can cause issues with some ExifTool versions
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllLines($tmpArgs, $argLines, $utf8NoBom)
                        
                        # Update progress bar
                        $status = "Writing batch $([math]::Ceiling($wIndex / $BatchSize)) - $($writeBatch.Count) files"
                        Write-Progress -Activity "Writing ImageUniqueID (batch)" -Status $status -PercentComplete (($wIndex / $needCount) * 100)
                        
                        # ===== EXECUTE EXIFTOOL =====
                        # -@ reads arguments from file (one per line)
                        # 2>&1: Capture both stdout and stderr for error reporting
                        $result = & $exiftool -@ $tmpArgs 2>&1
                        
                        # Check for errors
                        if ($LASTEXITCODE -ne 0) {
                            Write-Error "Batch write failed: $result"
                        } else {
                            # Display success for each file in batch
                            for ($i = 0; $i -lt $writeBatch.Count; $i++) {
                                Write-Host "→ Set GUID $($writeBatchGuids[$i]) for: $($writeBatch[$i])"
                            }
                        }
                    }
                    finally {
                        # ===== CLEANUP TEMP FILES =====
                        # Always cleanup, even if ExifTool failed
                        if (Test-Path $tmpArgs) { Remove-Item $tmpArgs -ErrorAction SilentlyContinue }
                        if (Test-Path $tmpUnicodeFile) { Remove-Item $tmpUnicodeFile -ErrorAction SilentlyContinue }
                    }
                    
                    # Clear batch for next iteration
                    $writeBatch.Clear()
                    $writeBatchGuids.Clear()
                }
            }
            
            # ===== COMPLETION MESSAGE =====
            Write-Host ""
            Write-Host "Completed. Wrote ImageUniqueID to $needCount file(s)."
        }
    }

}
catch {
    # ===== ERROR HANDLING =====
    # Catch and display any unhandled errors
    # ErrorActionPreference="Stop" ensures all errors are caught here
    Write-Error $_
}
