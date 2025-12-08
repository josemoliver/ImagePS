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

    $matchedCount = 0
    $writtenCount = 0
    $noPhotoDateCount = 0
    $noReadingWithinThresholdCount = 0
    $totalImages = $imageDates.Count
    $processed = 0

    foreach ($img in $imageDates) {
        $processed++
        $statusMsg = "Processing $processed of $totalImages - $([System.IO.Path]::GetFileName($img.File))"
        Write-Progress -Activity "Tagging weather data" -Status $statusMsg -PercentComplete (($processed / $totalImages) * 100)

        $nearest = Find-NearestWeather -PhotoDate $img.CreateDate -Readings $readings -ThresholdMinutes $Threshold

        $status = 'NoPhotoDate'
        if ($img.CreateDate) {
            $status = if ($nearest) { 'Matched' } else { 'NoReadingWithinThreshold' }
        }

        $result = [PSCustomObject]@{
            File               = $img.File
            PhotoDate          = $img.CreateDate
            ReadingDate        = if ($nearest) { $nearest.ReadingDate } else { $null }
            AmbientTemperature = if ($nearest) { $nearest.AmbientTemperature } else { $null }
            Humidity           = if ($nearest) { $nearest.Humidity } else { $null }
            Pressure           = if ($nearest) { $nearest.Pressure } else { $null }
            Status             = $status
        }

        $tempOut = if ($result.AmbientTemperature -ne $null) { $result.AmbientTemperature } else { '--' }
        $humOut  = if ($result.Humidity -ne $null) { $result.Humidity } else { '--' }
        $pressOut= if ($result.Pressure -ne $null) { $result.Pressure } else { '--' }

        Write-Host ("{0} | {1} | Temp={2} °C, Hum={3} %, Press={4} hPa" -f 
            [System.IO.Path]::GetFileName($img.File),
            $result.Status,
            $tempOut,
            $humOut,
            $pressOut)

        switch ($status) {
            'Matched' { $matchedCount++ }
            'NoPhotoDate' { $noPhotoDateCount++ }
            'NoReadingWithinThreshold' { $noReadingWithinThresholdCount++ }
        }

        if ($Write -and $nearest) {
            Write-WeatherTags -File $img.File -Reading $nearest
            $writtenCount++
        }
    }
    Write-Progress -Activity "Tagging weather data" -Completed
        $val = [double]::Parse($clean, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($val -lt $Min -or $val -gt $Max) { return $null }
        return $val
    } catch { return $null }
}

function Parse-ExifDate {
    param([string]$Raw)
    if ($Raw -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$') {
        return [datetime]::ParseExact(
            $Raw,
            'yyyy:MM:dd HH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    try { return [datetime]::Parse($Raw, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

function Get-ImageDates {
    param([string[]]$Files)

    $json = & exiftool.exe -CreateDate -DateTimeOriginal -mwg -json $Files
    $data = $json | ConvertFrom-Json

    return $data | ForEach-Object {
        $raw = $_.DateTimeOriginal
        if (-not $raw) { $raw = $_.CreateDate }

        $photoDate = Parse-ExifDate -Raw $raw

        [PSCustomObject]@{
            File       = $_.SourceFile
            CreateDate = $photoDate
            RawCreate  = $raw
        }
    }
}

function Import-WeatherHistory {
    param([string]$CsvPath)

    if (-not (Test-Path $CsvPath)) { throw "Weather history file not found: $CsvPath" }

    $readings = New-Object System.Collections.Generic.List[WeatherReading]
    $isFirstRow = $true

    Import-Csv -Path $CsvPath -Header Date,Time,Temp,Humidity,Pressure | ForEach-Object {
        $rawDate = "$( ($_.Date) ) $( ($_.Time) )".Trim()
        $parsed = $null
        try { $parsed = [datetime]::Parse($rawDate, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $parsed = $null }

        if ($isFirstRow) {
            $isFirstRow = $false
            if (-not $parsed) {
                Write-Verbose "Header row detected and skipped."
                return
            }
        }

        if (-not $parsed) { return }

        $temp = Try-ParseDouble -Input $_.Temp -Min -100 -Max 150
        $hum  = Try-ParseDouble -Input $_.Humidity -Min 0 -Max 100
        $press= Try-ParseDouble -Input $_.Pressure -Min 800 -Max 1100

        $readings.Add([WeatherReading]::new($parsed, $temp, $hum, $press))
    }

    return ($readings | Sort-Object ReadingDate)
}

function Find-NearestWeather {
    param(
        [datetime]$PhotoDate,
        [WeatherReading[]]$Readings,
        [int]$ThresholdMinutes = 30
    )

    if (-not $PhotoDate -or -not $Readings -or $Readings.Count -eq 0) { return $null }

    $nearest = $Readings |
        Sort-Object { [math]::Abs(($_.ReadingDate - $PhotoDate).TotalMinutes) } |
        Select-Object -First 1

    if (-not $nearest) { return $null }

    $delta = [math]::Abs(($nearest.ReadingDate - $PhotoDate).TotalMinutes)
    if ($delta -le $ThresholdMinutes) { return $nearest } else { return $null }
}

function Write-WeatherTags {
    param(
        [string]$File,
        [WeatherReading]$Reading
    )

    $args = @()
    if ($Reading.AmbientTemperature) { $args += "-AmbientTemperature=$($Reading.AmbientTemperature)" }
    if ($Reading.Humidity)           { $args += "-Humidity=$($Reading.Humidity)" }
    if ($Reading.Pressure)           { $args += "-Pressure=$($Reading.Pressure)" }

    # Always overwrite original file
    $args += "-overwrite_original"

    if ($args.Count -gt 0) {
        & exiftool.exe $File @args | Out-Null
    }
}

# --- Main Execution ---

$version = Get-ExiftoolVersion
Write-Verbose "Exiftool version $version detected."


$extensions = @(
    '.jpg', '.jpeg', '.jxl', '.png', '.tif', '.tiff', '.heic', '.heif', '.arw', '.cr2', '.cr3', '.nef', '.rw2', '.orf', '.raf', '.dng', '.webp'
)

$imageFiles = Get-ChildItem -Path $FilePath -Recurse:$Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $extensions -contains $_.Extension.ToLower() }

if (-not $imageFiles) {
    Write-Error "No supported image files found in $FilePath"
    exit 1
}

$imageDates = Get-ImageDates -Files $imageFiles.FullName

$weatherFile = Join-Path $FilePath 'weatherhistory.csv'
$readings = Import-WeatherHistory -CsvPath $weatherFile
if (-not $readings -or $readings.Count -eq 0) {
    Write-Error "No valid weather readings found in $weatherFile"
    exit 1
}

$matchedCount = 0
$writtenCount = 0
$noPhotoDateCount = 0
$noReadingWithinThresholdCount = 0

foreach ($img in $imageDates) {
    $nearest = Find-NearestWeather -PhotoDate $img.CreateDate -Readings $readings -ThresholdMinutes $Threshold

    $status = 'NoPhotoDate'
    if ($img.CreateDate) {
        $status = if ($nearest) { 'Matched' } else { 'NoReadingWithinThreshold' }
    }

    $result = [PSCustomObject]@{
        File               = $img.File
        PhotoDate          = $img.CreateDate
        ReadingDate        = if ($nearest) { $nearest.ReadingDate } else { $null }
        AmbientTemperature = if ($nearest) { $nearest.AmbientTemperature } else { $null }
        Humidity           = if ($nearest) { $nearest.Humidity } else { $null }
        Pressure           = if ($nearest) { $nearest.Pressure } else { $null }
        Status             = $status
    }

    $tempOut = if ($result.AmbientTemperature -ne $null) { $result.AmbientTemperature } else { '--' }
    $humOut  = if ($result.Humidity -ne $null) { $result.Humidity } else { '--' }
    $pressOut= if ($result.Pressure -ne $null) { $result.Pressure } else { '--' }

    Write-Host ("{0} | {1} | Temp={2} °C, Hum={3} %, Press={4} hPa" -f 
        [System.IO.Path]::GetFileName($img.File),
        $result.Status,
        $tempOut,
        $humOut,
        $pressOut)

    switch ($status) {
        'Matched' { $matchedCount++ }
        'NoPhotoDate' { $noPhotoDateCount++ }
        'NoReadingWithinThreshold' { $noReadingWithinThresholdCount++ }
    }

    if ($Write -and $nearest) {
        Write-WeatherTags -File $img.File -Reading $nearest
        $writtenCount++
    }
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
