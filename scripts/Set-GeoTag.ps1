<#
.SYNOPSIS
  Set_GeoTag.ps1 - Scan images, match nearest location from a GeoJSON file, and write MWG location tags via exiftool.

.PARAMETER FilePath
  Folder containing images to scan.

.PARAMETER GeoJson
  Path to the GeoJSON file containing location features (FeatureCollection). Accepts `.geojson` or `.json`.

.PARAMETER Write
  If supplied, the script will write metadata. Otherwise, it performs a dry run.

.DESCRIPTION
  For each image with GPSLatitude/GPSLongitude:
    - Finds the nearest location from the provided GeoJSON file (FeatureCollection) using Haversine distance (meters).
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

  [Parameter(Mandatory=$true)]
  [ValidateScript({
    # Validate path exists and extension is .geojson or .json
    if (-not (Test-Path $_ -PathType Leaf)) { throw "GeoJson file '$_' does not exist." }
    $ext = [System.IO.Path]::GetExtension($_).ToLower()
    if (@('.geojson','.json') -notcontains $ext) { throw "GeoJson must be a .geojson or .json file." }
    $true
  })]
  [string] $GeoJson,   # Path to GeoJSON FeatureCollection file

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

# Resolve and validate the provided GeoJSON path
# Ensures the file exists and is accessible
function Get-LocationsJsonPath {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "GeoJson file not found: '$Path'"
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

# Parse locations.geojson and extract location database
# GeoJSON format: FeatureCollection with Point or Polygon geometries and custom properties
# Each feature represents a known location with radius and metadata
# Point features: Use coordinates directly
# Polygon features: Calculate centroid for distance matching
function Read-Locations {
  param([string]$JsonPath)
  
  # Load and parse GeoJSON file
  try {
    $geojson = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
  } catch {
    throw "Failed to read or parse GeoJSON: $($_.Exception.Message)"
  }

  # Validate GeoJSON is a FeatureCollection with features
  if (-not $geojson -or -not $geojson.type -or $geojson.type -ne 'FeatureCollection') {
    throw "GeoJSON file must be a FeatureCollection."
  }
  if (-not $geojson.features -or $geojson.features.Count -eq 0) {
    throw "GeoJSON contains no features."
  }

  $locations = @()

  # Extract each feature as a location object
  foreach ($feature in $geojson.features) {
    # Skip features missing geometry or properties
    if (-not $feature.geometry -or -not $feature.properties) {
      continue
    }

    $geomType = $feature.geometry.type
    $coords = $feature.geometry.coordinates
    
    # Initialize location coordinates
    $lat = $null
    $lon = $null
    $polygon = $null

    if ($geomType -eq 'Point') {
      # ===== POINT GEOMETRY =====
      # Extract coordinates from Point geometry
      if (-not $coords -or $coords.Count -lt 2) {
        continue
      }
      # GeoJSON coordinate order is [longitude, latitude] (reversed from typical lat/lon)
      # See RFC 7946 Section 3.1.1: https://datatracker.ietf.org/doc/html/rfc7946#section-3.1.1
      $lon = [double]$coords[0]
      $lat = [double]$coords[1]
    }
    elseif ($geomType -eq 'Polygon') {
      # ===== POLYGON GEOMETRY =====
      # Polygon coordinates: Array of linear rings (first = exterior, rest = holes)
      # Each ring: Array of [lon, lat] positions
      # First and last position must be identical (closed ring)
      if (-not $coords -or $coords.Count -eq 0 -or $coords[0].Count -lt 3) {
        continue  # Invalid polygon (need at least 3 vertices)
      }
      
      # Extract exterior ring (first element)
      $exteriorRing = $coords[0]
      
      # Store polygon coordinates for point-in-polygon testing
      # Convert to array of [lon, lat] pairs
      $polygon = @()
      foreach ($point in $exteriorRing) {
        if ($point.Count -ge 2) {
          $polygon += ,@([double]$point[0], [double]$point[1])
        }
      }
      
      # Calculate centroid of polygon for distance matching
      # Centroid = average of all vertices (simple approximation for small polygons)
      # More accurate for convex polygons; acceptable for typical location boundaries
      $sumLon = 0.0
      $sumLat = 0.0
      $count = 0
      foreach ($point in $exteriorRing) {
        if ($point.Count -ge 2) {
          $sumLon += [double]$point[0]
          $sumLat += [double]$point[1]
          $count++
        }
      }
      
      if ($count -gt 0) {
        $lon = $sumLon / $count
        $lat = $sumLat / $count
      } else {
        continue  # No valid points in polygon
      }
    }
    else {
      # Unsupported geometry type (LineString, MultiPoint, etc.)
      continue
    }

    # Build location object from GeoJSON feature
    $loc = [pscustomobject]@{
      Location        = $feature.properties.Location        # Specific location name (e.g., "Central Park")
      Latitude        = $lat                                # Point: actual coords, Polygon: centroid latitude
      Longitude       = $lon                                # Point: actual coords, Polygon: centroid longitude
      City            = $feature.properties.City            # City name
      StateProvince   = $feature.properties.StateProvince   # State/Province/Region
      Country         = $feature.properties.Country         # Country name
      CountryCode     = $feature.properties.CountryCode     # ISO 3166-1 alpha-3 code (e.g., "USA", "CAN")
      Radius          = if ($feature.properties.Radius) { [double]$feature.properties.Radius } else { 50.0 }  # Default 50m if missing/empty
      LocationIdentifiers = $feature.properties.LocationIdentifiers  # Optional array of identifiers (URLs, codes)
      GeometryType    = $geomType                           # 'Point' or 'Polygon'
      Polygon         = $polygon                            # Polygon coordinates (null for Point)
    }

    # Validate required fields are present
    # Allow missing or empty Location, City, StateProvince, Country values; require coordinates only
    foreach ($field in 'Latitude','Longitude') {
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

# Test if a point is inside a polygon using ray casting algorithm
# Algorithm: Cast horizontal ray from point to infinity, count polygon edge crossings
# Odd number of crossings = inside, even number = outside
# Works for any simple polygon (convex or concave, but not self-intersecting)
function Test-PointInPolygon {
  param(
    [double]$Lat,      # Test point latitude
    [double]$Lon,      # Test point longitude
    [array]$Polygon    # Array of [lon, lat] coordinate pairs
  )
  
  if (-not $Polygon -or $Polygon.Count -lt 3) {
    return $false  # Invalid polygon
  }
  
  $inside = $false
  $n = $Polygon.Count
  
  # Ray casting: count how many polygon edges the ray crosses
  # Ray goes from (Lon, Lat) horizontally to the right (increasing longitude)
  for ($i = 0; $i -lt $n; $i++) {
    # Get current edge: vertex i to vertex j (wraps around to 0)
    $j = ($i + 1) % $n
    
    $lon1 = $Polygon[$i][0]
    $lat1 = $Polygon[$i][1]
    $lon2 = $Polygon[$j][0]
    $lat2 = $Polygon[$j][1]
    
    # Check if ray crosses this edge
    # Conditions:
    # 1. Edge spans the ray's latitude: (lat1 > Lat) != (lat2 > Lat)
    # 2. Ray's longitude is left of the edge's intersection with ray's latitude
    if ((($lat1 -gt $Lat) -ne ($lat2 -gt $Lat)) -and
        ($Lon -lt ($lon2 - $lon1) * ($Lat - $lat1) / ($lat2 - $lat1) + $lon1)) {
      $inside = -not $inside  # Toggle inside/outside
    }
  }
  
  return $inside
}


# Find nearest location from database with polygon support
# Algorithm: Prioritize Point features over Polygon features for specificity
# 1. Check if point is inside any polygons (track all containing polygons)
# 2. Find nearest Point feature (if any exist)
# 3. If nearest Point is inside a containing polygon AND within its radius, use Point (more specific)
# 4. Otherwise, use containing polygon with nearest centroid (broader area match)
# 5. If no containing polygons, use nearest location by distance (Point or Polygon centroid)
function Find-NearestLocation {
  param(
    [double]$Lat, [double]$Lon,  # Image GPS coordinates
    [object[]]$Locations          # Location database from GeoJSON
  )
  
  $best = $null              # Track closest location found so far
  $containingPolygons = @()  # Track all polygons that contain the point
  $nearestPoint = $null      # Track nearest Point feature
  
  # ===== PASS 1: FIND ALL CONTAINING POLYGONS AND NEAREST POINT =====
  # Check if point is inside any polygon geometries and find nearest Point
  foreach ($loc in $Locations) {
    if ($loc.GeometryType -eq 'Polygon' -and $loc.Polygon) {
      # Test if point is inside this polygon
      if (Test-PointInPolygon -Lat $Lat -Lon $Lon -Polygon $loc.Polygon) {
        # Calculate distance to centroid for ranking overlapping polygons
        $dist = Get-DistanceMeters -Lat1 $Lat -Lon1 $Lon -Lat2 $loc.Latitude -Lon2 $loc.Longitude
        
        # Store polygon with distance to centroid
        $containingPolygons += [pscustomobject]@{
          Location      = $loc
          CentroidDist  = $dist
        }
      }
    }
    elseif ($loc.GeometryType -eq 'Point') {
      # Calculate distance to Point feature
      $dist = Get-DistanceMeters -Lat1 $Lat -Lon1 $Lon -Lat2 $loc.Latitude -Lon2 $loc.Longitude
      
      # Track nearest Point feature
      if (-not $nearestPoint -or $dist -lt $nearestPoint.Distance) {
        $nearestPoint = [pscustomobject]@{
          Location = $loc
          Distance = $dist
        }
      }
    }
  }
  
  # ===== HANDLE POINT INSIDE POLYGON(S) WITH PRIORITY LOGIC =====
  # Priority: Point features (specific locations) take precedence over Polygons (areas)
  # if the Point is inside a polygon AND within its effective radius
  if ($containingPolygons.Count -gt 0) {
    # Check if nearest Point feature should override polygon match
    # Conditions: 1) Point exists, 2) Point is within its defined radius (high confidence)
    if ($nearestPoint -and $nearestPoint.Distance -le $nearestPoint.Location.Radius) {
      # Point feature is more specific than polygon - use it instead
      $loc = $nearestPoint.Location
      
      return [pscustomobject]@{
        Location      = $loc.Location
        Latitude      = $loc.Latitude
        Longitude     = $loc.Longitude
        City          = $loc.City
        StateProv     = $loc.StateProvince
        Country       = $loc.Country
        CountryCode   = $loc.CountryCode
        Radius        = $loc.Radius
        Identifiers   = @($loc.LocationIdentifiers)
        Distance      = $nearestPoint.Distance
        GeometryType  = $loc.GeometryType
        InsidePolygon = $false           # Using Point match, not polygon
      }
    }
    
    # No Point feature within radius - use containing polygon
    # Sort by centroid distance and select closest polygon
    $nearestContaining = $containingPolygons | Sort-Object -Property CentroidDist | Select-Object -First 1
    $loc = $nearestContaining.Location
    
    # Build result object with polygon metadata
    # Distance = 0 since point is inside polygon (exact match)
    return [pscustomobject]@{
      Location    = $loc.Location
      Latitude    = $loc.Latitude      # Centroid latitude
      Longitude   = $loc.Longitude     # Centroid longitude
      City        = $loc.City
      StateProv   = $loc.StateProvince
      Country     = $loc.Country
      CountryCode = $loc.CountryCode
      Radius      = $loc.Radius
      Identifiers = @($loc.LocationIdentifiers)
      Distance    = 0.0                # Inside polygon = distance 0
      GeometryType = $loc.GeometryType
      InsidePolygon = $true            # Flag for Rule 1 logic
    }
  }
  
  # ===== PASS 2: FIND NEAREST LOCATION BY DISTANCE (NO CONTAINING POLYGONS) =====
  # Point is not inside any polygon
  # Find nearest location by distance to centroid (Point or Polygon)
  foreach ($loc in $Locations) {
    # Calculate great-circle distance using Haversine formula
    # For Points: distance to actual point
    # For Polygons: distance to centroid
    $dist = Get-DistanceMeters -Lat1 $Lat -Lon1 $Lon -Lat2 $loc.Latitude -Lon2 $loc.Longitude
    
    # Update best match if this is the first location or closer than previous best
    if (-not $best -or $dist -lt $best.Distance) {
      # Create result object with location metadata and calculated distance
      $best = [pscustomobject]@{
        Location      = $loc.Location
        Latitude      = $loc.Latitude      # Point coords or Polygon centroid
        Longitude     = $loc.Longitude
        City          = $loc.City
        StateProv     = $loc.StateProvince
        Country       = $loc.Country
        CountryCode   = $loc.CountryCode
        Radius        = $loc.Radius
        Identifiers   = @($loc.LocationIdentifiers)
        Distance      = $dist
        GeometryType  = $loc.GeometryType
        InsidePolygon = $false             # Not inside any polygon
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
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Location)) {
      $lines += "-IPTC:Sub-location=$($Nearest.Location)"      # Specific location name
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-IPTC:City=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-IPTC:Province-State=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-IPTC:Country-PrimaryLocationName=$($Nearest.Country)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.CountryCode)) {
      $lines += "-IPTC:Country-PrimaryLocationCode=$($Nearest.CountryCode)" # ISO 3166-1 alpha-2
    }

    # ===== XMP IPTC CORE =====
    # XMP version of IPTC tags - modern metadata standard (2000s)
    # Stored in XML format, better Unicode support, extensible
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Location)) {
      $lines += "-XMP-iptcCore:Location=$($Nearest.Location)"  # Specific location (sublocation)
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.CountryCode)) {
      $lines += "-XMP-iptcCore:CountryCode=$($Nearest.CountryCode)"    # ISO country code
    }

    # ===== XMP PHOTOSHOP =====
    # Adobe Photoshop-specific XMP namespace
    # Used by Adobe applications (Lightroom, Photoshop, Bridge)
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-XMP-photoshop:City=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-XMP-photoshop:State=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-XMP-photoshop:Country=$($Nearest.Country)"
    }

    # ===== XMP IPTC EXTENSION =====
    # Extended IPTC metadata for more detailed location information
    # LocationCreated vs LocationShown: Created = where photo was taken, Shown = subject location
    # We use LocationCreated since we're tagging based on GPS coordinates (capture location)
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Location)) {
      $lines += "-XMP-iptcExt:LocationCreatedSubLocation=$($Nearest.Location)"    # Specific location
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-XMP-iptcExt:LocationCreatedCity=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-XMP-iptcExt:LocationCreatedProvinceState=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-XMP-iptcExt:LocationCreatedCountryName=$($Nearest.Country)"
    }

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
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-IPTC:City=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-IPTC:Province-State=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-IPTC:Country-PrimaryLocationName=$($Nearest.Country)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.CountryCode)) {
      $lines += "-IPTC:Country-PrimaryLocationCode=$($Nearest.CountryCode)"
    }

    # ===== XMP IPTC CORE =====
    # Write CountryCode only (no Location field)
    if (-not [string]::IsNullOrWhiteSpace($Nearest.CountryCode)) {
      $lines += "-XMP-iptcCore:CountryCode=$($Nearest.CountryCode)"
    }

    # ===== XMP PHOTOSHOP =====
    # Write City/State/Country for Adobe compatibility
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-XMP-photoshop:City=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-XMP-photoshop:State=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-XMP-photoshop:Country=$($Nearest.Country)"
    }

    # ===== XMP IPTC EXTENSION =====
    # Write City/State/Country only (no SubLocation or LocationIdentifiers)
    if (-not [string]::IsNullOrWhiteSpace($Nearest.City)) {
      $lines += "-XMP-iptcExt:LocationCreatedCity=$($Nearest.City)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.StateProv)) {
      $lines += "-XMP-iptcExt:LocationCreatedProvinceState=$($Nearest.StateProv)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Nearest.Country)) {
      $lines += "-XMP-iptcExt:LocationCreatedCountryName=$($Nearest.Country)"
    }

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
  $locPath = Get-LocationsJsonPath -Path $GeoJson    # Resolve provided GeoJSON path
  $locations = Read-Locations -JsonPath $locPath     # Parse and validate GeoJSON FeatureCollection
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
    Write-Host ("       Geometry: {0} | Distance: {1} m | Radius: {2} m" -f $nearest.GeometryType, $dist, $radius)

    # ===== APPLY GEOTAGGING RULES =====
    # Two-tier matching strategy based on distance thresholds
    # Special case: If inside polygon, always apply Rule 1 regardless of centroid distance
    
    if ($nearest.InsidePolygon -or $nearest.Distance -le $nearest.Radius) {
      # ===== RULE 1: INSIDE POLYGON OR INSIDE LOCATION RADIUS =====
      # High confidence match: Image taken at specific known location
      # Condition A: Point is inside polygon boundary (distance = 0)
      # Condition B: Point is within location's effective radius from centroid
      # Write full metadata: Location name, City, State, Country, CountryCode, LocationIdentifiers
      if ($nearest.InsidePolygon) {
        Write-Host ("       Action: Rule 1 (inside polygon) -> set Location, City, StateProvince, Country, CountryCode + LocationIdentifiers") -ForegroundColor Green
      } else {
        Write-Host ("       Action: Rule 1 (inside radius) -> set Location, City, StateProvince, Country, CountryCode + LocationIdentifiers") -ForegroundColor Green
      }
      
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
