<#
.SYNOPSIS
  Set_GeoTag.ps1 - Scan images, match nearest location from locations.json, and write MWG location tags via exiftool.

.PARAMETER FilePath
  Folder containing images to scan.

.PARAMETER Write
  If supplied, the script will write metadata. Otherwise, it performs a dry run.

.DESCRIPTION
  For each image with GPSLatitude/GPSLongitude:
    - Finds the nearest location from locations.json using Haversine distance (meters).
    - Rule 1: If within the location's Radius, writes MWG:Location, MWG:City, MWG:State, MWG:Country, CountryCode,
              and appends LocationIdentifiers to XMP-iptcExt:LocationCreated as LocationId.
    - Rule 2: If not within Radius but within 500 meters, writes MWG:City, MWG:State, MWG:Country, CountryCode.
  If -Write is not provided, the script simulates and prints intended changes.

.NOTES
  Requires exiftool in PATH. Tested with ExifTool 12.x.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true)]
  [ValidateScript({
    if (-not (Test-Path $_ -PathType Container)) {
      throw "FilePath '$_' does not exist or is not a directory."
    }
    $true
  })]
  [string] $FilePath,

  [switch] $Write
)

# -----------------------------
# Helpers
# -----------------------------

function Test-ExifTool {
  $exe = Get-Command exiftool -ErrorAction SilentlyContinue
  if (-not $exe) {
    throw "ExifTool is not available in PATH. Please install and ensure 'exiftool' is accessible."
  }
}

function Get-LocationsJsonPath {
  param([string]$Folder)
  $candidate1 = Join-Path $Folder 'locations.json'
  if (Test-Path $candidate1) { return $candidate1 }
  $candidate2 = Join-Path (Split-Path $PSCommandPath) 'locations.json'
  if (Test-Path $candidate2) { return $candidate2 }
  throw "locations.json not found in '$Folder' or script directory."
}

function Read-Locations {
  param([string]$JsonPath)
  try {
    $json = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
  } catch {
    throw "Failed to read or parse locations.json: $($_.Exception.Message)"
  }
  if (-not $json -or $json.Count -eq 0) {
    throw "locations.json contains no locations."
  }

  # Basic validation of required fields
  foreach ($loc in $json) {
    foreach ($field in 'Location','Latitude','Longitude','City','StateProvince','Country','Radius') {
      if (-not ($loc.PSObject.Properties.Name -contains $field)) {
        throw "locations.json missing field '$field' in one or more entries."
      }
    }
  }
  return $json
}

function Get-ImageFiles {
  param([string]$Folder)
  # Common photo extensions; adjust if needed
  $exts = @('*.jpg','*.jpeg','*.tif','*.tiff','*.png','*.heic','*.arw','*.cr2','*.cr3','*.nef','*.rw2','*.orf','*.raf','*.dng')
  $files = foreach ($ext in $exts) {
    Get-ChildItem -LiteralPath $Folder -Recurse -Filter $ext -File -ErrorAction SilentlyContinue
  }
  $files | Sort-Object -Property FullName -Unique
}

function Get-ImageGps {
  param([string]$Path)
  # Use numeric output (-n) and JSON (-j) for reliable parsing
  $args = @('-n','-j','-gpslatitude','-gpslongitude','-charset','filename=UTF8','-charset','EXIF=UTF8','-q','-q', $Path)
  $out = & exiftool @args 2>$null
  if (-not $out) { return $null }
  try {
    $data = $out | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $data -or $data.Count -lt 1) { return $null }
  $lat = $data[0].GPSLatitude
  $lon = $data[0].GPSLongitude
  if ($null -eq $lat -or $null -eq $lon) { return $null }
  return [pscustomobject]@{ Latitude = [double]$lat; Longitude = [double]$lon }
}

function Get-DistanceMeters {
  param(
    [double]$Lat1, [double]$Lon1,
    [double]$Lat2, [double]$Lon2
  )
  # Haversine (meters)
  $R = 6371000.0
  function ToRad([double]$deg) { return [math]::PI * $deg / 180.0 }

  $dLat = ToRad ($Lat2 - $Lat1)
  $dLon = ToRad ($Lon2 - $Lon1)

  $a = [math]::Pow([math]::Sin($dLat/2.0),2) +
       [math]::Cos((ToRad $Lat1)) * [math]::Cos((ToRad $Lat2)) *
       [math]::Pow([math]::Sin($dLon/2.0),2)

  $c = 2.0 * [math]::Asin([math]::Sqrt($a))
  return $R * $c
}


function Find-NearestLocation {
  param(
    [double]$Lat, [double]$Lon,
    [object[]]$Locations
  )
  $best = $null
  foreach ($loc in $Locations) {
    $dist = Get-DistanceMeters -Lat1 $Lat -Lon1 $Lon -Lat2 ([double]$loc.Latitude) -Lon2 ([double]$loc.Longitude)
    if (-not $best -or $dist -lt $best.Distance) {
      $best = [pscustomobject]@{
        Location  = $loc.Location
        Latitude  = [double]$loc.Latitude
        Longitude = [double]$loc.Longitude
        City      = $loc.City
        StateProv = $loc.StateProvince
        Country   = $loc.Country
        CountryCode = $loc.CountryCode
        Radius    = [double]$loc.Radius
        Identifiers = @($loc.LocationIdentifiers) # may be $null
        Distance  = [double]$dist
      }
    }
  }
  return $best
}

function Write-MetadataRule1 {
  param(
    [string]$Path,
    [object]$Nearest
  )
  $args = @(
    '-overwrite_original',
    '-charset','filename=UTF8',
    '-charset','EXIF=UTF8',

    # IPTC legacy tags
    ('-IPTC:Sub-location=' + $Nearest.Location),
    ('-IPTC:City=' + $Nearest.City),
    ('-IPTC:Province-State=' + $Nearest.StateProv),
    ('-IPTC:Country-PrimaryLocationName=' + $Nearest.Country),
    ('-IPTC:Country-PrimaryLocationCode=' + $Nearest.CountryCode),

    # XMP-iptcCore tags
    ('-XMP-iptcCore:Location=' + $Nearest.Location),
    ('-XMP-iptcCore:CountryCode=' + $Nearest.CountryCode),

    # XMP-photoshop tags
    ('-XMP-photoshop:City=' + $Nearest.City),
    ('-XMP-photoshop:State=' + $Nearest.StateProv),
    ('-XMP-photoshop:Country=' + $Nearest.Country),

    # XMP-iptcExt: tags
    ('-XMP-iptcExt:LocationCreatedSubLocation=' + $Nearest.Location),
    ('-XMP-iptcExt:LocationCreatedCity=' + $Nearest.City),
    ('-XMP-iptcExt:LocationCreatedProvince=' + $Nearest.StateProv),
    ('-XMP-iptcExt:LocationCreatedCountry=' + $Nearest.Country)

  )

  # Append identifiers into LocationCreated struct (XMP-iptcExt)
  $structNeeded = $false
  if ($Nearest.Identifiers -and $Nearest.Identifiers.Count -gt 0) {
    $structNeeded = $true
    foreach ($id in $Nearest.Identifiers) {
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      $args += ('-XMP-iptcExt:LocationCreated+={LocationId=' + $id + '}')
    }
  }
  if ($structNeeded) { $args = @('-struct','1') + $args }

  $args += $Path
  & exiftool @args
}


function Write-MetadataRule2 {
  param(
    [string]$Path,
    [object]$Nearest
  )
  $args = @(
    '-overwrite_original',
    '-charset','filename=UTF8',
    '-charset','EXIF=UTF8',

    # IPTC legacy tags
    ('-IPTC:City=' + $Nearest.City),
    ('-IPTC:Province-State=' + $Nearest.StateProv),
    ('-IPTC:Country-PrimaryLocationName=' + $Nearest.Country),
    ('-IPTC:Country-PrimaryLocationCode=' + $Nearest.CountryCode),

    # XMP-iptcCore tags
    ('-XMP-iptcCore:CountryCode=' + $Nearest.CountryCode),

    # XMP-photoshop tags
    ('-XMP-photoshop:City=' + $Nearest.City),
    ('-XMP-photoshop:State=' + $Nearest.StateProv),
    ('-XMP-photoshop:Country=' + $Nearest.Country),

    # XMP-iptcExt: tags
    ('-XMP-iptcExt:LocationCreatedCity=' + $Nearest.City),
    ('-XMP-iptcExt:LocationCreatedProvince=' + $Nearest.StateProv),
    ('-XMP-iptcExt:LocationCreatedCountry=' + $Nearest.Country)

  )

  $args += $Path
  & exiftool @args
}



# -----------------------------
# Main
# -----------------------------

try {
  Test-ExifTool
  $locPath = Get-LocationsJsonPath -Folder $FilePath
  $locations = Read-Locations -JsonPath $locPath
  $files = Get-ImageFiles -Folder $FilePath

  Write-Host ("Scanning folder: {0}" -f (Resolve-Path $FilePath)) -ForegroundColor Cyan
  Write-Host ("Locations file:  {0}" -f (Resolve-Path $locPath)) -ForegroundColor Cyan
  Write-Host ("Mode:            {0}" -f ($(if ($Write) {'WRITE'} else {'DRY-RUN'}))) -ForegroundColor Cyan
  Write-Host ("Files found:     {0}" -f $files.Count) -ForegroundColor Cyan
  Write-Host ""

  $summary = [pscustomobject]@{
    TotalFiles        = $files.Count
    WithGPS           = 0
    NoGPS             = 0
    Rule1Applied      = 0
    Rule2Applied      = 0
    OutsideThreshold  = 0
    Errors            = 0
  }

  foreach ($f in $files) {
    $gps = Get-ImageGps -Path $f.FullName
    if (-not $gps) {
      $summary.NoGPS++
      Write-Host ("[SKIP] No GPS: {0}" -f $f.FullName) -ForegroundColor Yellow
      continue
    }

    $summary.WithGPS++
    $nearest = Find-NearestLocation -Lat $gps.Latitude -Lon $gps.Longitude -Locations $locations
    $dist = [math]::Round($nearest.Distance, 2)
    $radius = [math]::Round($nearest.Radius, 2)

    Write-Host ("[INFO] {0}" -f $f.FullName) -ForegroundColor Gray
    Write-Host ("       GPS: {0}, {1}" -f $gps.Latitude, $gps.Longitude)
    Write-Host ("       Nearest: {0} (City={1}, State={2}, Country={3})" -f $nearest.Location, $nearest.City, $nearest.StateProv, $nearest.Country)
    Write-Host ("       Distance: {0} m | Radius: {1} m" -f $dist, $radius)

    if ($nearest.Distance -le $nearest.Radius) {
      # Rule 1
      Write-Host ("       Action: Rule 1 (inside radius) -> set Location, City, StateProvince, Country, CountryCode + LocationIdentifiers") -ForegroundColor Green
      if ($Write) {
        try {
          Write-MetadataRule1 -Path $f.FullName -Nearest $nearest | Out-Null
          $summary.Rule1Applied++
          Write-Host "       Result: WRITE OK" -ForegroundColor Green
        } catch {
          $summary.Errors++
          Write-Host ("       Result: WRITE ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
      } else {
        $summary.Rule1Applied++
        Write-Host "       Result: DRY-RUN (no changes written)" -ForegroundColor Yellow
      }
    }
    elseif ($nearest.Distance -le 500.0) {
      # Rule 2
      Write-Host ("       Action: Rule 2 (≤ 500 m) -> set City, StateProvince, Country, CountryCode") -ForegroundColor Green
      if ($Write) {
        try {
          Write-MetadataRule2 -Path $f.FullName -Nearest $nearest | Out-Null
          $summary.Rule2Applied++
          Write-Host "       Result: WRITE OK" -ForegroundColor Green
        } catch {
          $summary.Errors++
          Write-Host ("       Result: WRITE ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
      } else {
        $summary.Rule2Applied++
        Write-Host "       Result: DRY-RUN (no changes written)" -ForegroundColor Yellow
      }
    }
    else {
      $summary.OutsideThreshold++
      Write-Host ("       Action: None (>{0} m from nearest and outside radius)" -f 500) -ForegroundColor DarkGray
    }

    # Show identifiers (for visibility)
    if ($nearest.Identifiers -and $nearest.Identifiers.Count -gt 0) {
      Write-Host ("       Identifiers:") -ForegroundColor Gray
      foreach ($id in $nearest.Identifiers) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        Write-Host ("         - {0}" -f $id)
      }
    }
    Write-Host ""
  }

  # Summary
  Write-Host "================ Summary ================" -ForegroundColor Cyan
  Write-Host ("Total files:           {0}" -f $summary.TotalFiles)
  Write-Host ("With GPS:              {0}" -f $summary.WithGPS)
  Write-Host ("No GPS:                {0}" -f $summary.NoGPS)
  Write-Host ("Rule 1 applied:        {0}" -f $summary.Rule1Applied)
  Write-Host ("Rule 2 applied:        {0}" -f $summary.Rule2Applied)
  Write-Host ("Outside threshold:      {0}" -f $summary.OutsideThreshold)
  Write-Host ("Errors:                {0}" -f $summary.Errors)
  Write-Host "=========================================" -ForegroundColor Cyan
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
