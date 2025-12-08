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
    [string]$Filepath,

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

    [switch]$Recurse,
    [switch]$Parallel,
    [int]$ThrottleLimit = 2,
    [int]$BatchSize = 200
)

# Global error behavior
$ErrorActionPreference = "Stop"

# ExifTool executable (can be overridden if needed)
$exiftool = "exiftool"

try {
    # Validate input path
    if (-not (Test-Path -LiteralPath $Filepath)) {
        throw "ERROR: The path '$Filepath' does not exist."
    }

    # Calculate total files (per-extension counting to avoid storing huge arrays)
    $total = 0
    foreach ($ext in $Extensions) {
        try {
            $count = (Get-ChildItem -Path $Filepath -Filter "*.$ext" -File -Recurse:$Recurse.IsPresent -ErrorAction Stop | Measure-Object).Count
            $total += $count
        } catch {
            # ignore errors for a specific extension
        }
    }

    if ($total -eq 0) {
        Write-Warning "No image files found with extensions: $($Extensions -join ', ')"
        return
    }

    $index = 0

    # Build list of files and determine which need writes using chunked batch reads
    Write-Host "Scanning files in batches (BatchSize=$BatchSize) to determine missing ImageUniqueID..."
    $needWriteFiles = [System.Collections.Generic.List[string]]::new()
    $batch = New-Object System.Collections.ArrayList

    function Flush-Batch {
        param($batchList)
        if ($batchList.Count -eq 0) { return }
        # Write temp args file with one filename per line
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $batchList | ForEach-Object { $_ } | Out-File -FilePath $tmp -Encoding utf8
            $jsonOut = & $exiftool -j -ImageUniqueID -@ $tmp 2>$null
            if ($jsonOut) {
                try {
                    $objs = $jsonOut | ConvertFrom-Json
                } catch {
                    $objs = @()
                }
                for ($i = 0; $i -lt $objs.Count; $i++) {
                    $obj = $objs[$i]
                    $path = $batchList[$i]
                    if (-not $obj.ImageUniqueID -or [string]::IsNullOrWhiteSpace($obj.ImageUniqueID)) {
                        [void]$needWriteFiles.Add($path)
                    }
                }
            }
        }
        finally {
            if (Test-Path $tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        $batchList.Clear()
    }

    foreach ($ext in $Extensions) {
        $enumerator = Get-ChildItem -Path $Filepath -Filter "*.$ext" -File -Recurse:$Recurse.IsPresent -ErrorAction SilentlyContinue
        foreach ($file in $enumerator) {
            $index++
            $status = "Scanning $index of $total - $($file.Name)"
            Write-Progress -Activity "Scanning files (batch)" -Status $status -PercentComplete (($index / $total) * 100)
            [void]$batch.Add($file.FullName)
            if ($batch.Count -ge $BatchSize) {
                Flush-Batch $batch
            }
        }
    }
    # Flush remaining
    Flush-Batch $batch

    $needCount = $needWriteFiles.Count
    Write-Host "Scanning complete. $needCount files require ImageUniqueID."

    if ($needCount -eq 0) {
        Write-Host "Nothing to do."
    }
    else {
        if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7) {
            Write-Host "Writing $needCount files in parallel (ThrottleLimit=$ThrottleLimit)..."
            $processedCount = 0
            $results = $needWriteFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                $file = $_
                $guid = ([guid]::NewGuid().ToString("N"))
                $res = & $using:exiftool -overwrite_original "-ImageUniqueID=$guid" $file 2>&1
                if ($LASTEXITCODE -ne 0) { "ERR|$file|$LASTEXITCODE|$res" } else { "OK|$file|$guid" }
            } | ForEach-Object {
                $processedCount++
                $status = "Writing $processedCount of $needCount"
                Write-Progress -Activity "Writing ImageUniqueID (parallel)" -Status $status -PercentComplete (($processedCount / $needCount) * 100)
                $_
            }
            $ok = ($results | Where-Object { $_ -like 'OK|*' }).Count
            $err = ($results | Where-Object { $_ -like 'ERR|*' }).Count
            Write-Host "Completed parallel writes. Successes: $ok, Failures: $err"
        }
        else {
            Write-Host "Writing $needCount files serially in batches (BatchSize=$BatchSize)..."
            
            # Build map of file -> GUID and prepare batch writes
            $fileGuidMap = @{}
            foreach ($file in $needWriteFiles) {
                $guid = ([guid]::NewGuid().ToString("N"))
                $fileGuidMap[$file] = $guid
            }
            
            # Write in batches using args file
            $writeBatch = New-Object System.Collections.ArrayList
            $writeBatchGuids = New-Object System.Collections.ArrayList
            $wIndex = 0
            
            foreach ($file in $needWriteFiles) {
                $wIndex++
                [void]$writeBatch.Add($file)
                [void]$writeBatchGuids.Add($fileGuidMap[$file])
                
                if ($writeBatch.Count -ge $BatchSize -or $wIndex -eq $needCount) {
                    # Flush write batch
                    $tmpArgs = [System.IO.Path]::GetTempFileName()
                    $tmpUnicodeFile = [System.IO.Path]::GetTempFileName()
                    try {
                        $argLines = New-Object System.Collections.ArrayList
                        [void]$argLines.Add("-overwrite_original")
                        for ($i = 0; $i -lt $writeBatch.Count; $i++) {
                            $f = $writeBatch[$i]
                            $g = $writeBatchGuids[$i]
                            [void]$argLines.Add("-ImageUniqueID=$g")
                            [void]$argLines.Add($f)
                        }
                        
                        # Write args file as UTF-8 without BOM
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                        [System.IO.File]::WriteAllLines($tmpArgs, $argLines, $utf8NoBom)
                        
                        $status = "Writing batch $([math]::Ceiling($wIndex / $BatchSize)) - $($writeBatch.Count) files"
                        Write-Progress -Activity "Writing ImageUniqueID (batch)" -Status $status -PercentComplete (($wIndex / $needCount) * 100)
                        
                        $result = & $exiftool -@ $tmpArgs 2>&1
                        
                        if ($LASTEXITCODE -ne 0) {
                            Write-Error "Batch write failed: $result"
                        } else {
                            for ($i = 0; $i -lt $writeBatch.Count; $i++) {
                                Write-Host "→ Set GUID $($writeBatchGuids[$i]) for: $($writeBatch[$i])"
                            }
                        }
                    }
                    finally {
                        if (Test-Path $tmpArgs) { Remove-Item $tmpArgs -ErrorAction SilentlyContinue }
                        if (Test-Path $tmpUnicodeFile) { Remove-Item $tmpUnicodeFile -ErrorAction SilentlyContinue }
                    }
                    
                    $writeBatch.Clear()
                    $writeBatchGuids.Clear()
                }
            }
            
            Write-Host ""
            Write-Host "Completed. Wrote ImageUniqueID to $needCount file(s)."
        }
    }

}
catch {
    Write-Error $_
}
