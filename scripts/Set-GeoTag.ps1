<#
.SYNOPSIS
  Set_GeoTag.ps1 - Scan images, match nearest location from locations.geojson, and write MWG location tags via exiftool.

.PARAMETER FilePath
  Folder containing images to scan.

.PARAMETER Write
  If supplied, the script will write metadata. Otherwise, it performs a dry run.

.DESCRIPTION
  For each image with GPSLatitude/GPSLongitude:
    - Finds the nearest location from locations.geojson (GeoJSON format) using Haversine distance (meters).
    - Rule 1: If within the location's Radius, writes MWG:Location, MWG:City, MWG:State, MWG:Country, CountryCode,
              and appends LocationIdentifiers to XMP-iptcExt:LocationCreated as LocationId.
    - Rule 2: If not within Radius but within 500 meters, writes MWG:City, MWG:State, MWG:Country, CountryCode.
  If -Write is not provided, the script simulates and prints intended changes.

.NOTES
  Requires exiftool in PATH. Tested with ExifTool 12.x.

.LINK
  https://en.wikipedia.org/wiki/GeoJSON
  
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true)]
  [ValidateScript({
    # Validate that FilePath exists and is a directory (not a file)
    if (-not (Test-Path $_ -PathType Container)) {
      throw "FilePath '$_' does not exist or is not a directory."
    }
    $true
  })]
  [string] $FilePath,  # Directory containing images to geotag

  [switch] $Write      # Enable write mode (default is dry-run/preview)
)

# ===== HELPER FUNCTIONS =====
# Modular functions for validation, GeoJSON parsing, GPS extraction, and distance calculations

# Validate ExifTool availability in system PATH
# ExifTool is required for reading GPS coordinates and writing location metadata
function Test-ExifTool {
  $exe = Get-Command exiftool -ErrorAction SilentlyContinue
  if (-not $exe) {
    throw "ExifTool is not available in PATH. Please install and ensure 'exiftool' is accessible."
  }
}

# Locate locations.geojson file using fallback strategy
# Search order: 1) Image folder, 2) Script directory
# This allows per-folder location databases or a shared central database
function Get-LocationsJsonPath {
  param([string]$Folder)
  
  # Candidate 1: locations.geojson in the image folder (project-specific)
  $candidate1 = Join-Path $Folder 'locations.geojson'
  if (Test-Path $candidate1) { return $candidate1 }
  
  # Candidate 2: locations.geojson in the script directory (shared database)
  $candidate2 = Join-Path (Split-Path $PSCommandPath) 'locations.geojson'
  if (Test-Path $candidate2) { return $candidate2 }
  
  # No locations file found in either location
  throw "locations.geojson not found in '$Folder' or script directory."
}

# Parse locations.geojson and extract location database
# GeoJSON format: FeatureCollection with Point geometries and custom properties
# Each feature represents a known location with radius and metadata
function Read-Locations {
  param([string]$JsonPath)
  
  # Load and parse GeoJSON file
  try {
    $geojson = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
  } catch {
    throw "Failed to read or parse GeoJSON: $($_.Exception.Message)"
  }

  # Validate GeoJSON structure contains features array
  if (-not $geojson -or -not $geojson.features -or $geojson.features.Count -eq 0) {
    throw "GeoJSON contains no features."
  }

  $locations = @()

  # Extract each feature as a location object
  foreach ($feature in $geojson.features) {
    # Skip features missing geometry or properties
    if (-not $feature.geometry -or -not $feature.properties) {
      continue
    }

    # Extract coordinates from Point geometry
    $coords = $feature.geometry.coordinates
    if (-not $coords -or $coords.Count -lt 2) {
      continue
    }

    # Build location object from GeoJSON feature
    # IMPORTANT: GeoJSON coordinate order is [longitude, latitude] (reversed from typical lat/lon)
    # See RFC 7946 Section 3.1.1: https://datatracker.ietf.org/doc/html/rfc7946#section-3.1.1
    $loc = [pscustomobject]@{
      Location        = $feature.properties.Location        # Specific location name (e.g., "Central Park")
      Latitude        = [double]$coords[1]                  # GeoJSON order: [lon, lat], so index 1 = latitude
      Longitude       = [double]$coords[0]                  # GeoJSON order: [lon, lat], so index 0 = longitude
      City            = $feature.properties.City            # City name
      StateProvince   = $feature.properties.StateProvince   # State/Province/Region
      Country         = $feature.properties.Country         # Country name
      CountryCode     = $feature.properties.CountryCode     # ISO 3166-1 alpha-2 code (e.g., "US", "CA")
      Radius          = [double]$feature.properties.Radius  # Effective radius in meters for Rule 1 matching
      LocationIdentifiers = $feature.properties.LocationIdentifiers  # Optional array of identifiers (URLs, codes)
    }

    # Validate required fields are present
    # LocationIdentifiers is optional, all others are mandatory
    foreach ($field in 'Location','Latitude','Longitude','City','StateProvince','Country','Radius') {
      if (-not $loc.$field) {
        throw "GeoJSON missing field '$field' in one or more features."
      }
    }

    $locations += $loc
  }

  return $locations
}


# Discover all supported image files in target directory
# Searches recursively through all subdirectories
function Get-ImageFiles {
  param([string]$Folder)
  
  # Supported image extensions: 17 formats
  # Common: JPG, JXL, PNG, HEIC, HEIF, TIFF, WEBP
  # RAW: ARW (Sony), CR2/CR3 (Canon), NEF (Nikon), RW2 (Panasonic), ORF (Olympus), RAF (Fujifilm), DNG (Adobe)
  $exts = @('*.jpg','*.jpeg','*.jxl','*.tif','*.tiff','*.png','*.heic','*.heif','*.arw','*.cr2','*.cr3','*.nef','*.rw2','*.orf','*.raf','*.dng','*.webp')
  
  # Collect files for each extension pattern
  # -Recurse: Search all subdirectories
  # -File: Only files, not directories
  # -ErrorAction SilentlyContinue: Skip inaccessible directories
  $files = foreach ($ext in $exts) {
    Get-ChildItem -LiteralPath $Folder -Recurse -Filter $ext -File -ErrorAction SilentlyContinue
  }
  
  # Remove duplicates and sort for consistent processing order
  $files | Sort-Object -Property FullName -Unique
}

# Extract GPS coordinates from image EXIF metadata
# Returns $null if image has no GPS data (allows caller to skip processing)
function Get-ImageGps {
  param([string]$Path)
  
  # Build ExifTool command arguments
  # -n: Numeric output (converts GPS from degrees/minutes/seconds to decimal)
  # -j: JSON output format for reliable parsing
  # -gpslatitude, -gpslongitude: Only extract GPS fields (faster than reading all metadata)
  # -charset: UTF-8 encoding for international filenames and metadata
  # -q -q: Double quiet mode (suppress warnings and errors)
  $args = @('-n','-j','-gpslatitude','-gpslongitude','-charset','filename=UTF8','-charset','EXIF=UTF8','-q','-q', $Path)
  
  # Execute ExifTool and capture JSON output
  # 2>$null: Suppress stderr (tag not found messages)
  $out = & exiftool @args 2>$null
  if (-not $out) { return $null }
  
  # Parse JSON output
  try {
    $data = $out | ConvertFrom-Json
  } catch {
    return $null  # Invalid JSON (corrupted metadata)
  }
  
  # Validate JSON structure and extract coordinates
  if (-not $data -or $data.Count -lt 1) { return $null }
  $lat = $data[0].GPSLatitude
  $lon = $data[0].GPSLongitude
  
  # Return null if either coordinate is missing (both required for geotagging)
  if ($null -eq $lat -or $null -eq $lon) { return $null }
  
  # Return GPS coordinates as object
  return [pscustomobject]@{ Latitude = [double]$lat; Longitude = [double]$lon }
}

# Calculate great-circle distance between two GPS coordinates using Haversine formula
# Returns distance in meters (accurate for Earth's spherical approximation)
# Formula accounts for Earth's curvature, more accurate than simple Euclidean distance
function Get-DistanceMeters {
  param(
    [double]$Lat1, [double]$Lon1,  # Point 1: Image GPS coordinates
    [double]$Lat2, [double]$Lon2   # Point 2: Location from GeoJSON database
  )
  
  # Earth's mean radius in meters (WGS84 approximation)
  # Actual radius varies: 6356.752 km (poles) to 6378.137 km (equator)
  $R = 6371000.0
  
  # Helper function: Convert degrees to radians
  # Radians = Degrees × (π / 180)
  function ToRad([double]$deg) { return [math]::PI * $deg / 180.0 }

  # Calculate coordinate differences in radians
  $dLat = ToRad ($Lat2 - $Lat1)
  $dLon = ToRad ($Lon2 - $Lon1)

  # Haversine formula: a = sin²(Δφ/2) + cos(φ1) · cos(φ2) · sin²(Δλ/2)
  # Where φ = latitude, λ = longitude
  # This calculates the square of half the chord length between the points
  $a = [math]::Pow([math]::Sin($dLat/2.0),2) +
       [math]::Cos((ToRad $Lat1)) * [math]::Cos((ToRad $Lat2)) *
       [math]::Pow([math]::Sin($dLon/2.0),2)

  # Calculate angular distance in radians
  # c = 2 · arcsin(√a)
  $c = 2.0 * [math]::Asin([math]::Sqrt($a))
  
  # Convert angular distance to linear distance: distance = radius × angle
  return $R * $c
}


# Find nearest location from database using brute-force distance comparison
# Algorithm: Calculate distance to all locations, return closest match
# For large databases, consider spatial indexing (quadtree, R-tree)
function Find-NearestLocation {
  param(
    [double]$Lat, [double]$Lon,  # Image GPS coordinates
    [object[]]$Locations          # Location database from GeoJSON
  )
  
  $best = $null  # Track closest location found so far
  
  # Iterate through all locations to find minimum distance
  # O(N) complexity: acceptable for small-to-medium databases (<1000 locations)
  foreach ($loc in $Locations) {
    # Calculate great-circle distance using Haversine formula
    $dist = Get-DistanceMeters -Lat1 $Lat -Lon1 $Lon -Lat2 ([double]$loc.Latitude) -Lon2 ([double]$loc.Longitude)
    
    # Update best match if this is the first location or closer than previous best
    if (-not $best -or $dist -lt $best.Distance) {
      # Create result object with location metadata and calculated distance
      $best = [pscustomobject]@{
        Location  = $loc.Location
        Latitude  = [double]$loc.Latitude
        Longitude = [double]$loc.Longitude
        City      = $loc.City
        StateProv = $loc.StateProvince
        Country   = $loc.Country
        CountryCode = $loc.CountryCode
        Radius    = [double]$loc.Radius           # Effective radius for Rule 1
        Identifiers = @($loc.LocationIdentifiers) # Array of location IDs (may be $null)
        Distance  = [double]$dist                 # Calculated distance in meters
      }
    }
  }
  
  return $best  # Guaranteed to have a match if $Locations is non-empty
}

# Write metadata for Rule 1: Image is within location's effective radius
# Writes full location metadata including specific location name and identifiers
# Updates IPTC (legacy), XMP-iptcCore, XMP-photoshop, and XMP-iptcExt namespaces
function Write-MetadataRule1 {
    param(
        [string]$Path,     # Full path to image file
        [object]$Nearest   # Nearest location object with Distance ≤ Radius
    )

    # Create UTF-8 without BOM encoder for international location names
    # UTF-8 without BOM prevents encoding issues with international characters
    # ExifTool requires UTF-8 for proper handling of non-ASCII location names
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    
    # Create temporary file for ExifTool arguments
    # Using args file allows complex metadata writes with special characters
    $tempFile = [System.IO.Path]::GetTempFileName()

    # Initialize arguments array with common options
    # -overwrite_original: Modify file in-place (no _original backup)
    # -charset: Specify UTF-8 encoding for filenames and metadata
    $lines = @(
        '-overwrite_original',
        '-charset', 'Filename=UTF8',
        '-charset', 'EXIF=UTF8',
        '-charset', 'IPTC=UTF8'
    )

    # ===== IPTC LEGACY TAGS =====
    # IPTC IIM (Information Interchange Model) - original metadata standard from 1990s
    # Stored as ISO-8859-1 internally, ExifTool handles UTF-8 conversion
    # Widely supported by older software (Adobe Lightroom, Photo Mechanic)
    $lines += @(
        "-IPTC:Sub-location=$($Nearest.Location)",              # Specific location name
        "-IPTC:City=$($Nearest.City)",                          # City name
        "-IPTC:Province-State=$($Nearest.StateProv)",           # State/Province
        "-IPTC:Country-PrimaryLocationName=$($Nearest.Country)",# Country name
        "-IPTC:Country-PrimaryLocationCode=$($Nearest.CountryCode)" # ISO 3166-1 alpha-2
    )

    # ===== XMP IPTC CORE =====
    # XMP version of IPTC tags - modern metadata standard (2000s)
    # Stored in XML format, better Unicode support, extensible
    $lines += @(
        "-XMP-iptcCore:Location=$($Nearest.Location)",         # Specific location (sublocation)
        "-XMP-iptcCore:CountryCode=$($Nearest.CountryCode)"    # ISO country code
    )

    # ===== XMP PHOTOSHOP =====
    # Adobe Photoshop-specific XMP namespace
    # Used by Adobe applications (Lightroom, Photoshop, Bridge)
    $lines += @(
        "-XMP-photoshop:City=$($Nearest.City)",
        "-XMP-photoshop:State=$($Nearest.StateProv)",
        "-XMP-photoshop:Country=$($Nearest.Country)"
    )

    # ===== XMP IPTC EXTENSION =====
    # Extended IPTC metadata for more detailed location information
    # LocationCreated vs LocationShown: Created = where photo was taken, Shown = subject location
    # We use LocationCreated since we're tagging based on GPS coordinates (capture location)
    $lines += @(
        "-XMP-iptcExt:LocationCreatedSubLocation=$($Nearest.Location)",    # Specific location
        "-XMP-iptcExt:LocationCreatedCity=$($Nearest.City)",              # City
        "-XMP-iptcExt:LocationCreatedProvinceState=$($Nearest.StateProv)",# State/Province
        "-XMP-iptcExt:LocationCreatedCountryName=$($Nearest.Country)"     # Country name
    )

    # ===== LOCATION IDENTIFIERS (STRUCT) WITH DEDUPLICATION =====
    # LocationCreated can store array of LocationId structs for external references
    # Examples: Wikidata IDs (Q...), GeoNames IDs, Foursquare Venues, Google Place IDs, OSM IDs
    # Format: LocationCreated is array of structs with LocationId field
    $structNeeded = $false
    
    # Add LocationIdentifiers if present in GeoJSON
    if ($Nearest.Identifiers -and $Nearest.Identifiers.Count -gt 0) {
        # Read existing LocationCreated structs to prevent duplicates
        # -struct: Enable struct output mode
        # -j: JSON format for reliable parsing
        # -XMP-iptcExt:LocationCreated: Only read this field
        $existingJson = & exiftool -struct -j -XMP-iptcExt:LocationCreated "$Path" 2>$null
        $existingIds = @()
        
        if ($existingJson) {
            try {
                $existingData = $existingJson | ConvertFrom-Json
                if ($existingData -and $existingData.Count -gt 0) {
                    $locationCreated = $existingData[0].LocationCreated
                    # Handle both single struct and array of structs
                    if ($locationCreated) {
                        if ($locationCreated -is [array]) {
                            # Array of structs: extract LocationId from each
                            $existingIds = $locationCreated | ForEach-Object { 
                                if ($_.LocationId) { $_.LocationId } 
                            }
                        } elseif ($locationCreated.LocationId) {
                            # Single struct: extract LocationId
                            $existingIds = @($locationCreated.LocationId)
                        }
                    }
                }
            } catch {
                # If parsing fails, assume no existing identifiers
                $existingIds = @()
            }
        }
        
        # Filter out identifiers that already exist in the image
        # Case-sensitive comparison to preserve exact URLs
        $newIds = $Nearest.Identifiers | Where-Object { 
            -not [string]::IsNullOrWhiteSpace($_) -and $existingIds -notcontains $_
        }
        
        # Only add identifiers if there are new ones to add
        if ($newIds -and $newIds.Count -gt 0) {
            $structNeeded = $true
            
            # Append each new identifier as separate LocationCreated struct element
            # += syntax adds new element to array struct without removing existing ones
            foreach ($id in $newIds) {
                $lines += "-XMP-iptcExt:LocationCreated+={LocationId=$id}"
            }
        }
    }

    # Enable struct mode if we added any struct fields
    # -struct 1 must appear BEFORE any struct-related tags in args file
    # Tells ExifTool to interpret {field=value} as struct syntax instead of literal string
    if ($structNeeded) {
        $lines = @('-struct', '1') + $lines
    }

    #
    # Add the final file path
    #
    $lines += $Path

    #
    # Write argument file in UTF-8 (NO BOM)
    #
    [System.IO.File]::WriteAllLines($tempFile, $lines, $utf8)

    #
    # Run ExifTool with UTF-8 args
    #
    & exiftool -@ $tempFile

    #
    # Cleanup
    #
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}



# Write metadata for Rule 2: Image is outside radius but within 500m threshold
# Writes general location metadata (City/State/Country) but NOT specific location name
# Omits Location/Sublocation fields and LocationIdentifiers (less specific match)
function Write-MetadataRule2 {
    param(
        [string]$Path,     # Full path to image file
        [object]$Nearest   # Nearest location object with Radius < Distance ≤ 500m
    )

    # Create UTF-8 without BOM encoder for international location names
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tempFile = [System.IO.Path]::GetTempFileName()

    # Initialize arguments with common options
    $lines = @(
        '-overwrite_original',
        '-charset', 'Filename=UTF8',
        '-charset', 'EXIF=UTF8',
        '-charset', 'IPTC=UTF8'
    )

    # ===== IPTC LEGACY TAGS =====
    # Write City/State/Country only (no Sub-location)
    # Rule 2: Less specific match, omit precise location name
    $lines += @(
        "-IPTC:City=$($Nearest.City)",
        "-IPTC:Province-State=$($Nearest.StateProv)",
        "-IPTC:Country-PrimaryLocationName=$($Nearest.Country)",
        "-IPTC:Country-PrimaryLocationCode=$($Nearest.CountryCode)"
    )

    # ===== XMP IPTC CORE =====
    # Write CountryCode only (no Location field)
    $lines += "-XMP-iptcCore:CountryCode=$($Nearest.CountryCode)"

    # ===== XMP PHOTOSHOP =====
    # Write City/State/Country for Adobe compatibility
    $lines += @(
        "-XMP-photoshop:City=$($Nearest.City)",
        "-XMP-photoshop:State=$($Nearest.StateProv)",
        "-XMP-photoshop:Country=$($Nearest.Country)"
    )

    # ===== XMP IPTC EXTENSION =====
    # Write City/State/Country only (no SubLocation or LocationIdentifiers)
    $lines += @(
        "-XMP-iptcExt:LocationCreatedCity=$($Nearest.City)",
        "-XMP-iptcExt:LocationCreatedProvinceState=$($Nearest.StateProv)",
        "-XMP-iptcExt:LocationCreatedCountryName=$($Nearest.Country)"
    )

    # Add target file path (must be last)
    $lines += $Path

    # Write args file and execute ExifTool
    [System.IO.File]::WriteAllLines($tempFile, $lines, $utf8)
    & exiftool -@ $tempFile

    # Cleanup temporary file
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}




# ===== MAIN SCRIPT LOGIC =====
# Workflow: Validate → Load locations → Discover files → Process each file → Report summary

try {
  # ===== INITIALIZATION =====
  # Validate prerequisites and load configuration
  Test-ExifTool                                      # Ensure ExifTool is available
  $locPath = Get-LocationsJsonPath -Folder $FilePath # Find locations.geojson
  $locations = Read-Locations -JsonPath $locPath     # Parse GeoJSON database
  $files = Get-ImageFiles -Folder $FilePath          # Discover all image files

  # ===== DISPLAY CONFIGURATION =====
  # Show user what will be processed
  Write-Host ("Scanning folder: {0}" -f (Resolve-Path $FilePath)) -ForegroundColor Cyan
  Write-Host ("Locations file:  {0}" -f (Resolve-Path $locPath)) -ForegroundColor Cyan
  Write-Host ("Mode:            {0}" -f ($(if ($Write) {'WRITE'} else {'DRY-RUN'}))) -ForegroundColor Cyan
  Write-Host ("Files found:     {0}" -f $files.Count) -ForegroundColor Cyan
  Write-Host ""

  # ===== SUMMARY COUNTERS =====
  # Track processing statistics for final report
  $summary = [pscustomobject]@{
    TotalFiles        = $files.Count  # All image files found
    WithGPS           = 0             # Files with GPS coordinates
    NoGPS             = 0             # Files without GPS (skipped)
    Rule1Applied      = 0             # Files within location radius (specific location)
    Rule2Applied      = 0             # Files within 500m but outside radius (general location)
    OutsideThreshold  = 0             # Files >500m from any location (no metadata written)
    Errors            = 0             # Files with write errors
  }

  # ===== MAIN PROCESSING LOOP =====
  # Process each image file individually
  foreach ($f in $files) {
    # ===== EXTRACT GPS COORDINATES =====
    # Skip files without GPS data (indoor photos, scanned images, etc.)
    $gps = Get-ImageGps -Path $f.FullName
    if (-not $gps) {
      $summary.NoGPS++
      Write-Host ("[SKIP] No GPS: {0}" -f $f.FullName) -ForegroundColor Yellow
      continue
    }

    # ===== FIND NEAREST LOCATION =====
    # Calculate distances to all locations in database, find closest match
    $summary.WithGPS++
    $nearest = Find-NearestLocation -Lat $gps.Latitude -Lon $gps.Longitude -Locations $locations
    
    # Round distances for display (2 decimal places)
    $dist = [math]::Round($nearest.Distance, 2)
    $radius = [math]::Round($nearest.Radius, 2)

    # ===== DISPLAY FILE INFO =====
    # Show GPS coordinates, nearest location, and distance for user visibility
    Write-Host ("[INFO] {0}" -f $f.FullName) -ForegroundColor Gray
    Write-Host ("       GPS: {0}, {1}" -f $gps.Latitude, $gps.Longitude)
    Write-Host ("       Nearest: {0} (City={1}, State={2}, Country={3})" -f $nearest.Location, $nearest.City, $nearest.StateProv, $nearest.Country)
    Write-Host ("       Distance: {0} m | Radius: {1} m" -f $dist, $radius)

    # ===== APPLY GEOTAGGING RULES =====
    # Two-tier matching strategy based on distance thresholds
    
    if ($nearest.Distance -le $nearest.Radius) {
      # ===== RULE 1: INSIDE LOCATION RADIUS =====
      # High confidence match: Image taken at specific known location
      # Write full metadata: Location name, City, State, Country, CountryCode, LocationIdentifiers
      Write-Host ("       Action: Rule 1 (inside radius) -> set Location, City, StateProvince, Country, CountryCode + LocationIdentifiers") -ForegroundColor Green
      
      if ($Write) {
        # Write mode: Actually modify file metadata
        try {
          Write-MetadataRule1 -Path $f.FullName -Nearest $nearest | Out-Null
          $summary.Rule1Applied++
          Write-Host "       Result: WRITE OK" -ForegroundColor Green
        } catch {
          # Capture write errors (permission denied, corrupted file, etc.)
          $summary.Errors++
          Write-Host ("       Result: WRITE ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
      } else {
        # Dry-run mode: Preview what would be written
        $summary.Rule1Applied++
        Write-Host "       Result: DRY-RUN (no changes written)" -ForegroundColor Yellow
      }
    }
    elseif ($nearest.Distance -le 500.0) {
      # ===== RULE 2: WITHIN 500M BUT OUTSIDE RADIUS =====
      # Medium confidence match: Image taken near location but not precisely at it
      # Write general metadata only: City, State, Country, CountryCode (no specific location)
      # 500m threshold: Typical city block size, reasonable proximity for general location
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
      # ===== NO RULE APPLIED: TOO FAR FROM ANY LOCATION =====
      # Low confidence: Image taken >500m from nearest location
      # No metadata written (avoid incorrect location tagging)
      $summary.OutsideThreshold++
      Write-Host ("       Action: None (>{0} m from nearest and outside radius)" -f 500) -ForegroundColor DarkGray
    }

    # ===== DISPLAY LOCATION IDENTIFIERS =====
    # Show external reference IDs if present (Wikidata, GeoNames, etc.)
    # Helps user verify location matching and understand what identifiers were written
    if ($nearest.Identifiers -and $nearest.Identifiers.Count -gt 0) {
      Write-Host ("       Identifiers:") -ForegroundColor Gray
      foreach ($id in $nearest.Identifiers) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        Write-Host ("         - {0}" -f $id)
      }
    }
    Write-Host ""  # Blank line between files for readability
  }

  # ===== SUMMARY REPORT =====
  # Display final statistics for entire batch operation
  Write-Host "================ Summary ================" -ForegroundColor Cyan
  Write-Host ("Total files:           {0}" -f $summary.TotalFiles)         # All images found
  Write-Host ("With GPS:              {0}" -f $summary.WithGPS)            # Files processed (had GPS)
  Write-Host ("No GPS:                {0}" -f $summary.NoGPS)              # Files skipped (no GPS)
  Write-Host ("Rule 1 applied:        {0}" -f $summary.Rule1Applied)      # High confidence matches
  Write-Host ("Rule 2 applied:        {0}" -f $summary.Rule2Applied)      # Medium confidence matches
  Write-Host ("Outside threshold:      {0}" -f $summary.OutsideThreshold) # Low confidence (>500m)
  Write-Host ("Errors:                {0}" -f $summary.Errors)             # Write failures
  Write-Host "=========================================" -ForegroundColor Cyan
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
