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
    Author: Adapted from José Oliver-Didier's WeatherTag (C#)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$FilePath,

    [switch]$Write,

    [int]$Threshold = 30
)

# --- Helper classes and functions ---

class WeatherReading {
    [datetime]$ReadingDate
    [Nullable[Double]]$AmbientTemperature
    [Nullable[Double]]$Humidity
    [Nullable[Double]]$Pressure

    WeatherReading([datetime]$date, [Nullable[Double]]$temp, [Nullable[Double]]$hum, [Nullable[Double]]$press) {
        $this.ReadingDate = $date
        $this.AmbientTemperature = $temp
        $this.Humidity = $hum
        $this.Pressure = $press
    }
}

function Get-ExiftoolVersion {
    try {
        $version = & exiftool.exe -ver
        return [double]$version
    } catch {
        Write-Error "Exiftool not found. Please install exiftool.exe and ensure it's in PATH."
        exit 1
    }
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

    $readings = @()
    Import-Csv $CsvPath -Header Date,Time,Temp,Humidity,Pressure | ForEach-Object {
        $rawDate = "$($_.Date) $($_.Time)".Trim()
        $parsed = $null
        try { $parsed = [datetime]::Parse($rawDate, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $parsed = $null }

        $temp = try {
            $v = [double]($_.Temp -replace '[^\d\.\-]')
            if ($v -lt -100 -or $v -gt 150) { $null } else { $v }
        } catch { $null }

        $hum = try {
            $v = [double]($_.Humidity -replace '[^\d\.\-]')
            if ($v -lt 0 -or $v -gt 100) { $null } else { $v }
        } catch { $null }

        $press = try {
            $v = [double]($_.Pressure -replace '[^\d\.\-]')
            if ($v -lt 800 -or $v -gt 1100) { $null } else { $v }
        } catch { $null }

        if ($parsed) {
            $readings += [WeatherReading]::new($parsed, $temp, $hum, $press)
        }
    }
    $readings | Sort-Object ReadingDate
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

$imageFiles = Get-ChildItem -Path $FilePath -Recurse -File |
    Where-Object { $_.Extension -match '^\.(jpg|jpeg|jxl|tif|tiff|png|heic|heif|arw|cr2|cr3|nef|rw2|orf|raf|dng|webp)$' }

if (-not $imageFiles) {
    Write-Error "No supported image files found in $FilePath"
    exit 1
}

$imageDates = Get-ImageDates -Files $imageFiles.FullName

$weatherFile = Join-Path $FilePath 'weatherhistory.csv'
$readings = Import-WeatherHistory -CsvPath $weatherFile

foreach ($img in $imageDates) {
    $nearest = Find-NearestWeather -PhotoDate $img.CreateDate -Readings $readings -ThresholdMinutes $Threshold

    $result = [PSCustomObject]@{
        File               = $img.File
        PhotoDate          = $img.CreateDate
        ReadingDate        = if ($nearest) { $nearest.ReadingDate } else { $null }
        AmbientTemperature = if ($nearest) { $nearest.AmbientTemperature } else { $null }
        Humidity           = if ($nearest) { $nearest.Humidity } else { $null }
        Pressure           = if ($nearest) { $nearest.Pressure } else { $null }
        Status             = if ($nearest) { 'Matched' } else { 'NoReadingWithinThreshold' }
    }

    $result

    if ($Write -and $nearest) {
        Write-WeatherTags -File $img.File -Reading $nearest
    }
}
