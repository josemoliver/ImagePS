<#
.SYNOPSIS
    Set-WeatherTags.ps1
    Optimized WeatherTag replication in PowerShell.

.DESCRIPTION
    Reads weatherhistory.csv containing weather readings and matches them
    to photo timestamps. Writes AmbientTemperature, Humidity, and Pressure
    into EXIF metadata using exiftool.exe. Optimized for performance and
    pipeline use.

.PARAMETER Write
    Write matched weather tags back to photo metadata.

.PARAMETER Overwrite
    Overwrite original files when writing metadata.

.EXAMPLE
    .\Set-WeatherTags.ps1
    Preview tags without writing.

.EXAMPLE
    .\Set-WeatherTags.ps1 -Write -Overwrite
    Write tags and overwrite originals.
#>

[CmdletBinding()]
param(
    [switch]$Write,
    [switch]$Overwrite,
    [string]$WeatherFile = "weatherhistory.csv"
)

function Check-Exiftool {
    try {
        $output = & exiftool.exe -ver 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            return [double]$output
        }
        else { return 0 }
    }
    catch { return 0 }
}

function Remove-NonNumeric([string]$input) {
    return ($input -replace '[^0-9\.\-]', '')
}

# Hard-coded ranges
$ranges = @{
    TempMin = -100; TempMax = 150
    HumMin  = 0;    HumMax  = 100
    PressMin= 800;  PressMax= 1100
}

# Verify exiftool
$version = Check-Exiftool
if ($version -eq 0) {
    Write-Error "Exiftool not found! WeatherTag requires exiftool.exe."
    exit
}
else {
    Write-Verbose "Exiftool version $version"
}

# Find image files
$imageFiles = Get-ChildItem -File | Where-Object {
    $_.Extension -match '^\.(jpg|jpeg|heic)$'
}
if (-not $imageFiles) {
    Write-Error "No supported image files found."
    exit
}

# Load weather history
if (-not (Test-Path $WeatherFile)) {
    Write-Error "$WeatherFile not found."
    exit
}

$readings = @()
Import-Csv $WeatherFile -Header Date,Time,Temp,Humidity,Pressure | ForEach-Object {
    $dateWeatherReading = [datetime]"$($_.Date) $($_.Time)"

    $ambient = $null
    $humidity = $null
    $pressure = $null

    try {
        $val = [double](Remove-NonNumeric $_.Temp)
        if ($val -ge $ranges.TempMin -and $val -le $ranges.TempMax) { $ambient = $val }
    } catch {}

    try {
        $val = [double](Remove-NonNumeric $_.Humidity)
        if ($val -ge $ranges.HumMin -and $val -le $ranges.HumMax) { $humidity = $val }
    } catch {}

    try {
        $val = [double](Remove-NonNumeric $_.Pressure)
        if ($val -ge $ranges.PressMin -and $val -le $ranges.PressMax) { $pressure = $val }
    } catch {}

    $readings += [pscustomobject]@{
        ReadingDate       = $dateWeatherReading
        AmbientTemperature= $ambient
        Humidity          = $humidity
        Pressure          = $pressure
    }
}

# Batch query photo dates
$json = & exiftool.exe ($imageFiles.FullName) -CreateDate -mwg -json
$photoDates = $json | ConvertFrom-Json

# Process each image
$results = foreach ($img in $imageFiles) {
    $photoInfo = $photoDates | Where-Object { $_.SourceFile -eq $img.FullName }
    $photoDate = $null
    if ($photoInfo.CreateDate) {
        $parts = $photoInfo.CreateDate.Trim().Split(' ')
        $date = $parts[0] -replace ":", "/"
        $time = $parts[1]
        $photoDate = [datetime]("$date $time")
    }

    $closest = $null
    $minDiff = 30
    if ($photoDate) {
        foreach ($r in $readings) {
            $diff = ($photoDate - $r.ReadingDate).TotalMinutes
            if ([math]::Abs($diff) -lt $minDiff) {
                $closest = $r
                $minDiff = [math]::Abs($diff)
            }
        }
    }

    if ($closest -and $minDiff -lt 30) {
        if ($Write) {
            $args = @()
            if ($closest.AmbientTemperature) { $args += "-`"AmbientTemperature=$($closest.AmbientTemperature)`"" }
            if ($closest.Humidity)           { $args += "-`"Humidity=$($closest.Humidity)`"" }
            if ($closest.Pressure)           { $args += "-`"Pressure=$($closest.Pressure)`"" }
            if ($Overwrite)                  { $args += "-overwrite_original" }

            $cmd = @($img.FullName) + $args
            $output = & exiftool.exe @cmd
            [pscustomobject]@{
                File   = $img.Name
                Date   = $photoDate
                Temp   = $closest.AmbientTemperature
                Hum    = $closest.Humidity
                Press  = $closest.Pressure
                Status = "Written"
                Output = $output
            }
        }
        else {
            [pscustomobject]@{
                File   = $img.Name
                Date   = $photoDate
                Temp   = $closest.AmbientTemperature
                Hum    = $closest.Humidity
                Press  = $closest.Pressure
                Status = "Preview"
            }
        }
    }
    else {
        [pscustomobject]@{
            File   = $img.Name
            Date   = $photoDate
            Temp   = $null
            Hum    = $null
            Press  = $null
            Status = if (-not $photoDate) { "NoDate" } else { "NoReading" }
        }
    }
}

# Output results to pipeline
$results
