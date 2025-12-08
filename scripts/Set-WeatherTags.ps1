<#
.SYNOPSIS
    Annotates image files with weather readings based on EXIF CreateDate.

.DESCRIPTION
    Reads a weatherhistory.csv file containing weather readings (DateTime, Temperature, Humidity, Pressure).
    Matches each image's EXIF CreateDate to the nearest weather reading and writes the values back to the image metadata using exiftool.

.PARAMETER FilePath
    Path to the folder containing image files (.jpg, .jpeg, .heic).

.PARAMETER Write
    Switch to enable writing weather tags into image metadata. Without this, only preview is shown.

.PARAMETER Threshold
    Maximum difference in minutes allowed between photo time and weather reading.
    Defaults to 30 minutes if not specified.

.EXAMPLE
    PS> .\Set-WeatherTags.ps1 -FilePath "C:\Photos" -Write -Threshold 15

.NOTES
    Author: Adapted from José Oliver-Didier's Photo Weather Tag (C#)
    https://github.com/josemoliver/PhotoWeatherTag
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$FilePath,

    [switch]$Write,

    [int]$Threshold = 30,

    [switch]$Recurse
)

# --- Helper classes and functions ---

# WeatherReading class: Stores a single weather observation with timestamp and measurements
# Uses nullable doubles to allow missing values (e.g., if sensor data is unavailable)
class WeatherReading {
    [datetime]$ReadingDate              # Timestamp when weather was recorded
    [Nullable[Double]]$AmbientTemperature  # Temperature in Celsius (-100 to 150°C range)
    [Nullable[Double]]$Humidity            # Relative humidity percentage (0-100%)
    [Nullable[Double]]$Pressure            # Atmospheric pressure in hPa (800-1100 hPa range)

    # Constructor: Initialize weather reading with all measurements
    WeatherReading([datetime]$date, [Nullable[Double]]$temp, [Nullable[Double]]$hum, [Nullable[Double]]$press) {
        $this.ReadingDate = $date
        $this.AmbientTemperature = $temp
        $this.Humidity = $hum
        $this.Pressure = $press
    }
}

# Validates ExifTool availability and returns version number
# Exits script if ExifTool is not found in system PATH
function Get-ExiftoolVersion {
    try {
        $version = & exiftool.exe -ver
        return [double]$version
    } catch {
        Write-Error "Exiftool not found. Please install exiftool.exe and ensure it's in PATH."
        exit 1
    }
}

# Strips all non-numeric characters from input, keeping only digits, decimal points, and minus signs
# Used to extract numeric values from strings like "25.2 °C" or "1,013.24 hPa"
function Remove-NonNumeric {
    param([string]$InputString)
    # Regex pattern [^0-9\.\-] matches anything that is NOT a digit, period, or minus sign
    return ([regex]::Replace($InputString, "[^0-9\.\-]", ""))
}

# Parses a string to double with range validation
# Returns null if parsing fails or value is outside valid range
# Example: "25.2 °C" with Min=-100, Max=150 returns 25.2
function Try-ParseDouble {
    param(
        [string]$Value,      # Input string (e.g., "25.2 °C", "87 %", "1,013.24 hPa")
        [double]$Min,        # Minimum valid value (inclusive)
        [double]$Max         # Maximum valid value (inclusive)
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        # Strip units and formatting characters, keeping only numeric content
        $clean = Remove-NonNumeric $Value
        if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
        
        # Parse using InvariantCulture to handle decimal points consistently
        $val = [double]::Parse($clean, [System.Globalization.CultureInfo]::InvariantCulture)
        
        # Validate range (e.g., temperature -100 to 150°C, humidity 0-100%, pressure 800-1100 hPa)
        if ($val -lt $Min -or $val -gt $Max) { return $null }
        return $val
    } catch { return $null }
}

# Parses EXIF date strings which can be in various formats
# Primary format: "2025:11:17 08:29:00" (EXIF standard with colons)
# Falls back to general datetime parsing for other formats
function Parse-ExifDate {
    param([string]$Raw)  # Raw date string from EXIF data
    
    # Check if it matches EXIF standard format: yyyy:MM:dd HH:mm:ss
    if ($Raw -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$') {
        return [datetime]::ParseExact(
            $Raw,
            'yyyy:MM:dd HH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    # Fall back to general parsing for non-standard formats
    try { return [datetime]::Parse($Raw, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

# Extracts creation timestamps from image files using ExifTool
# Returns array of objects with file path, parsed date, and raw EXIF string
function Get-ImageDates {
    param([string[]]$Files)  # Array of full file paths to process

    # Query ExifTool for date fields: DateTimeOriginal (preferred) and CreateDate (fallback)
    # -mwg flag enables Metadata Working Group compatibility
    # -json returns structured JSON output for easy parsing
    $json = & exiftool.exe -CreateDate -DateTimeOriginal -mwg -json $Files
    $data = $json | ConvertFrom-Json

    return $data | ForEach-Object {
        # Prefer DateTimeOriginal (when photo was taken), fall back to CreateDate
        $raw = $_.DateTimeOriginal
        if (-not $raw) { $raw = $_.CreateDate }

        # Parse the EXIF date string into a DateTime object
        $photoDate = Parse-ExifDate -Raw $raw

        # Return custom object with file info and parsed date
        [PSCustomObject]@{
            File       = $_.SourceFile  # Full path to image file
            CreateDate = $photoDate     # Parsed DateTime object (or null if parsing failed)
            RawCreate  = $raw           # Original EXIF string for debugging
        }
    }
}

# Imports weather data from CSV file and parses into WeatherReading objects
# CSV format: Date,Time,Temperature,Humidity,Pressure (e.g., "11/17/2025,12:04 AM,25.2 °C,87 %,1,013.24 hPa")
# Returns sorted list of weather readings, skipping invalid rows and header if present
function Import-WeatherHistory {
    param([string]$CsvPath)  # Path to weatherhistory.csv file

    if (-not (Test-Path $CsvPath)) { throw "Weather history file not found: $CsvPath" }

    # Use typed List for better performance than array concatenation
    $readings = New-Object System.Collections.Generic.List[WeatherReading]
    $isFirstRow = $true

    # Import CSV with explicit headers (no header row in file)
    # Column order: Date, Time, Temperature, Humidity, Pressure
    Import-Csv -Path $CsvPath -Header Date,Time,Temp,Humidity,Pressure | ForEach-Object {
        # Combine date and time columns into single datetime string
        $rawDate = "$( ($_.Date) ) $( ($_.Time) )".Trim()
        $parsed = $null
        try { $parsed = [datetime]::Parse($rawDate, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $parsed = $null }

        # Auto-detect and skip header row if present (header text won't parse as date)
        if ($isFirstRow) {
            $isFirstRow = $false
            if (-not $parsed) {
                Write-Verbose "Header row detected and skipped."
                return  # Skip this row and continue to next
            }
        }

        # Skip rows with invalid dates
        if (-not $parsed) { return }

        # Parse numeric values with range validation
        # Temperature: -100 to 150°C (handles extreme climates)
        # Humidity: 0 to 100% (relative humidity)
        # Pressure: 800 to 1100 hPa (atmospheric pressure at various altitudes)
        $temp = Try-ParseDouble -Value $_.Temp -Min -100 -Max 150
        $hum  = Try-ParseDouble -Value $_.Humidity -Min 0 -Max 100
        $press= Try-ParseDouble -Value $_.Pressure -Min 800 -Max 1100

        # Add reading to collection (nullable values preserved if parsing failed)
        $readings.Add([WeatherReading]::new($parsed, $temp, $hum, $press))
    }

    # Sort chronologically for efficient nearest-neighbor search
    return ($readings | Sort-Object ReadingDate)
}

# Finds the weather reading closest in time to a photo's timestamp
# Uses linear search with absolute time difference, filtered by threshold
# Returns null if no reading is within the threshold window
function Find-NearestWeather {
    param(
        [datetime]$PhotoDate,              # When the photo was taken
        [WeatherReading[]]$Readings,       # Array of available weather readings
        [int]$ThresholdMinutes = 30        # Maximum time difference allowed (default: 30 minutes)
    )

    # Validate inputs
    if (-not $PhotoDate -or -not $Readings -or $Readings.Count -eq 0) { return $null }

    # Find reading with smallest absolute time difference from photo timestamp
    # Sort by absolute difference in minutes, take first (nearest) result
    $nearest = $Readings |
        Sort-Object { [math]::Abs(($_.ReadingDate - $PhotoDate).TotalMinutes) } |
        Select-Object -First 1

    if (-not $nearest) { return $null }

    # Calculate time difference in minutes
    $delta = [math]::Abs(($nearest.ReadingDate - $PhotoDate).TotalMinutes)
    
    # Only return reading if within threshold (e.g., photo at 8:15, reading at 8:20, delta=5min)
    if ($delta -le $ThresholdMinutes) { return $nearest } else { return $null }
}

# Writes weather metadata to multiple image files in a single ExifTool batch operation
# Uses temporary args file for performance: reduces N ExifTool processes to 1
# This optimization is critical for large image collections (e.g., 125 images = 1 call instead of 125)
function Write-WeatherTagsBatch {
    param(
        [hashtable]$FileReadings  # Hashtable mapping file paths to WeatherReading objects
    )

    if ($FileReadings.Count -eq 0) { return }

    # Create temporary file to hold ExifTool arguments
    # Args file format: one argument per line, processed sequentially by ExifTool
    $argsFile = [System.IO.Path]::GetTempFileName()
    
    # UTF-8 without BOM ensures compatibility with international characters
    # BOM (Byte Order Mark) can cause issues with ExifTool argument parsing
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lines = New-Object System.Collections.Generic.List[string]

    # Add global options that apply to all files in batch
    $lines.Add("-charset")              # Enable charset options
    $lines.Add("filename=utf8")          # Handle UTF-8 filenames
    $lines.Add("-overwrite_original")   # Modify files in-place (no backup _original files)

    # Build per-file metadata arguments
    # Format: -TagName=value followed by filename
    # ExifTool processes tags until it encounters a filename, then applies accumulated tags to that file
    foreach ($entry in $FileReadings.GetEnumerator()) {
        $file = $entry.Key       # Full path to image file
        $reading = $entry.Value  # WeatherReading object with measurements

        # Only write non-null values (respects missing sensor data)
        if ($reading.AmbientTemperature) {
            $lines.Add("-AmbientTemperature=$($reading.AmbientTemperature)")
        }
        if ($reading.Humidity) {
            $lines.Add("-Humidity=$($reading.Humidity)")
        }
        if ($reading.Pressure) {
            $lines.Add("-Pressure=$($reading.Pressure)")
        }
        
        # Filename signals ExifTool to write accumulated tags to this file
        $lines.Add($file)
    }

    try {
        # Write args file with UTF-8 encoding
        [System.IO.File]::WriteAllLines($argsFile, $lines, $utf8NoBom)
        
        # Execute ExifTool with args file: -@ reads arguments from file
        # Redirect output to null (success messages not needed)
        & exiftool.exe -@ $argsFile 2>&1 | Out-Null
        
        # Check exit code (non-zero indicates warnings or errors)
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ExifTool batch operation completed with warnings or errors."
        }
    } finally {
        # Always clean up temporary file, even if errors occur
        if (Test-Path $argsFile) {
            Remove-Item $argsFile -Force
        }
    }
}

# --- Main Execution ---

# Verify ExifTool is available before processing
$version = Get-ExiftoolVersion
Write-Verbose "Exiftool version $version detected."

# Define supported image formats
# Covers common photo formats (JPG, HEIC, PNG) and RAW formats from major camera manufacturers
$extensions = @(
    '.jpg', '.jpeg', '.jxl', '.png', '.tif', '.tiff', '.heic', '.heif', '.arw', '.cr2', '.cr3', '.nef', '.rw2', '.orf', '.raf', '.dng', '.webp'
)

# Discover all image files in target directory
# -Recurse:$Recurse enables subdirectory processing if user specified -Recurse parameter
$imageFiles = Get-ChildItem -Path $FilePath -Recurse:$Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $extensions -contains $_.Extension.ToLower() }

if (-not $imageFiles) {
    Write-Error "No supported image files found in $FilePath"
    exit 1
}

# Extract EXIF creation dates from all images in batch
$imageDates = Get-ImageDates -Files $imageFiles.FullName

# Load weather history from CSV file (must be in same directory as images)
$weatherFile = Join-Path $FilePath 'weatherhistory.csv'
$readings = Import-WeatherHistory -CsvPath $weatherFile
if (-not $readings -or $readings.Count -eq 0) {
    Write-Error "No valid weather readings found in $weatherFile"
    exit 1
}

# Initialize counters for summary statistics
$matchedCount = 0                        # Images with matching weather data within threshold
$writtenCount = 0                        # Images actually written (only in -Write mode)
$noPhotoDateCount = 0                    # Images missing EXIF DateTimeOriginal
$noReadingWithinThresholdCount = 0       # Images with no weather reading within time threshold
$totalImages = $imageDates.Count
$processed = 0

# Collect files for batch write operation (optimization: write all at once instead of per-file)
$filesToWrite = @{}  # Hashtable: filepath -> WeatherReading object

# Main processing loop: match each image to nearest weather reading
foreach ($img in $imageDates) {
    $processed++
    # Update progress bar with current file
    $statusMsg = "Processing $processed of $totalImages - $([System.IO.Path]::GetFileName($img.File))"
    Write-Progress -Activity "Tagging weather data" -Status $statusMsg -PercentComplete (($processed / $totalImages) * 100)

    # Find weather reading closest in time to photo timestamp
    $nearest = Find-NearestWeather -PhotoDate $img.CreateDate -Readings $readings -ThresholdMinutes $Threshold

    # Determine status for reporting
    $status = 'NoPhotoDate'
    if ($img.CreateDate) {
        $status = if ($nearest) { 'Matched' } else { 'NoReadingWithinThreshold' }
    }

    # Build result object with all data for display
    $result = [PSCustomObject]@{
        File               = $img.File
        PhotoDate          = $img.CreateDate
        ReadingDate        = if ($nearest) { $nearest.ReadingDate } else { $null }
        AmbientTemperature = if ($nearest) { $nearest.AmbientTemperature } else { $null }
        Humidity           = if ($nearest) { $nearest.Humidity } else { $null }
        Pressure           = if ($nearest) { $nearest.Pressure } else { $null }
        Status             = $status
    }

    # Format output values (use '--' for missing data)
    $tempOut = if ($result.AmbientTemperature -ne $null) { $result.AmbientTemperature } else { '--' }
    $humOut  = if ($result.Humidity -ne $null) { $result.Humidity } else { '--' }
    $pressOut= if ($result.Pressure -ne $null) { $result.Pressure } else { '--' }

    # Display result for this image
    Write-Host ("{0} | {1} | Temp={2} °C, Hum={3} %, Press={4} hPa" -f 
        [System.IO.Path]::GetFileName($img.File),
        $result.Status,
        $tempOut,
        $humOut,
        $pressOut)

    # Update statistics counters
    switch ($status) {
        'Matched' { $matchedCount++ }
        'NoPhotoDate' { $noPhotoDateCount++ }
        'NoReadingWithinThreshold' { $noReadingWithinThresholdCount++ }
    }

    # If in write mode and weather data matched, add to batch collection
    if ($Write -and $nearest) {
        $filesToWrite[$img.File] = $nearest
        $writtenCount++
    }
}
# Clear progress bar
Write-Progress -Activity "Tagging weather data" -Completed

# Perform batch write operation if user specified -Write and we have matched files
# This single ExifTool invocation writes metadata to all matched files at once
if ($Write -and $filesToWrite.Count -gt 0) {
    Write-Host "`nWriting weather tags to $($filesToWrite.Count) files..."
    Write-WeatherTagsBatch -FileReadings $filesToWrite
    Write-Host "Weather tags written successfully."
}

Write-Host ""
Write-Host ('=' * 60)
Write-Host "SUMMARY"
Write-Host ('=' * 60)
Write-Host "Total images processed: $($imageFiles.Count)"
Write-Host "Weather readings loaded: $($readings.Count)"
Write-Host "Matched (within $Threshold min threshold): $matchedCount"
Write-Host "No photo date found: $noPhotoDateCount"
Write-Host "No reading within threshold: $noReadingWithinThresholdCount"
if ($Write) {
    Write-Host "Files written with weather data: $writtenCount"
} else {
    Write-Host "Note: Preview mode. Use -Write to save weather data to files."
}
Write-Host ('=' * 60)
