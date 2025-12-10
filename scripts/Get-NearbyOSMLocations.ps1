<#
.SYNOPSIS
    Query OpenStreetMap (OSM) for locations near a GPS coordinate and export to GeoJSON.

.DESCRIPTION
    Searches OpenStreetMap via the Overpass API for points of interest (POIs), buildings,
    landmarks, and other features within a specified radius of a given latitude/longitude
    coordinate. Results include OSM IDs, feature types, tags, and administrative hierarchy
    (city/state/country) when available.
    
    Outputs a formatted list to console and optionally exports to GeoJSON format for use
    with mapping tools or the Set-GeoTag.ps1 script.

.PARAMETER Latitude
    Center point latitude in decimal degrees (-90 to 90).

.PARAMETER Longitude
    Center point longitude in decimal degrees (-180 to 180).

.PARAMETER RadiusMeters
    Search radius in meters. Recommended maximum: 1000m for performance.

.PARAMETER Output
    Optional path to output GeoJSON file. If omitted, no file is written (console only).

.PARAMETER FeatureTypes
    Optional array of OSM feature types to include. Default: all notable features.
    Examples: "tourism", "historic", "amenity", "natural", "leisure"

.EXAMPLE
    .\Get-NearbyOSMLocations.ps1 -Latitude 40.7829 -Longitude -73.9654 -RadiusMeters 500
    
    Displays nearby OSM features within 500m of Central Park (console output only).

.EXAMPLE
    .\Get-NearbyOSMLocations.ps1 -Latitude 18.4663 -Longitude -66.1057 -RadiusMeters 500 -Output osm_locations.geojson
    
    Searches Old San Juan and exports results to osm_locations.geojson.

.EXAMPLE
    .\Get-NearbyOSMLocations.ps1 -Latitude 40.7589 -Longitude -73.9851 -RadiusMeters 300 -FeatureTypes "tourism","historic"
    
    Searches for only tourism and historic features near Times Square.

.NOTES
    Requires internet connection to query Overpass API.
    Please respect Overpass API usage limits and rate limiting.
    Distance calculations use Haversine formula for accuracy.

.LINK
    https://www.openstreetmap.org/
    https://wiki.openstreetmap.org/wiki/Overpass_API
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="Center point latitude in decimal degrees")]
    [ValidateRange(-90, 90)]
    [double]$Latitude,

    [Parameter(Mandatory=$true, HelpMessage="Center point longitude in decimal degrees")]
    [ValidateRange(-180, 180)]
    [double]$Longitude,

    [Parameter(Mandatory=$true, HelpMessage="Search radius in meters")]
    [ValidateRange(1, 10000)]
    [int]$RadiusMeters,

    [Parameter(Mandatory=$false, HelpMessage="Optional path to output GeoJSON file")]
    [string]$Output = "",

    [Parameter(Mandatory=$false, HelpMessage="OSM feature types to include (e.g., tourism, historic, amenity)")]
    [string[]]$FeatureTypes = @()
)

# ===== SCRIPT INITIALIZATION =====
$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 for secure HTTPS connections to Overpass API
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Load System.Web assembly for URL encoding
Add-Type -AssemblyName System.Web

# ===== HAVERSINE DISTANCE CALCULATION =====
# Calculate great-circle distance between two GPS coordinates
# Returns distance in meters accounting for Earth's curvature
# More accurate than simple Euclidean distance for geographic coordinates
function Get-HaversineDistance {
    param(
        [double]$Lat1,    # Point 1 latitude
        [double]$Lon1,    # Point 1 longitude
        [double]$Lat2,    # Point 2 latitude
        [double]$Lon2     # Point 2 longitude
    )
    
    # Earth's mean radius in meters (WGS84 approximation)
    $R = 6371000.0
    
    # Helper: Convert degrees to radians
    function ToRad([double]$deg) { 
        return [Math]::PI * $deg / 180.0 
    }
    
    # Calculate coordinate differences in radians
    $dLat = ToRad($Lat2 - $Lat1)
    $dLon = ToRad($Lon2 - $Lon1)
    
    # Haversine formula: a = sin²(Δφ/2) + cos(φ1)·cos(φ2)·sin²(Δλ/2)
    $a = [Math]::Pow([Math]::Sin($dLat / 2.0), 2) +
         [Math]::Cos((ToRad $Lat1)) * [Math]::Cos((ToRad $Lat2)) *
         [Math]::Pow([Math]::Sin($dLon / 2.0), 2)
    
    # Calculate angular distance: c = 2·arcsin(√a)
    $c = 2.0 * [Math]::Asin([Math]::Sqrt($a))
    
    # Convert to linear distance: distance = radius × angle
    return $R * $c
}

# ===== FORMAT DISTANCE FOR DISPLAY =====
# Convert meters to human-readable format
# Uses meters for distances < 1km, kilometers with 2 decimals for >= 1km
function Format-Distance {
    param([double]$Meters)
    
    if ($Meters -lt 1000) {
        # Less than 1 km: show meters as integer
        return "{0:N0} m" -f $Meters
    }
    else {
        # 1 km or more: show kilometers with 2 decimal places
        $km = $Meters / 1000.0
        return "{0:N2} km" -f $km
    }
}

# ===== GET COUNTRY INFO FROM NOMINATIM =====
# Query Nominatim reverse geocoding API for administrative information
# Returns country, state/province, city, and ISO country code
function Get-CountryInfo {
    param(
        [double]$Lat,
        [double]$Lon
    )
    
    # Nominatim reverse geocoding endpoint
    # Returns administrative hierarchy for coordinates
    $nominatimUrl = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$Lat&lon=$Lon&zoom=18&addressdetails=1"
    
    try {
        # Query Nominatim with required User-Agent header
        # Nominatim requires User-Agent to prevent abuse
        $response = Invoke-RestMethod -Uri $nominatimUrl -Headers @{
            "User-Agent" = "PowerShell-OSM-Nearby/1.0"
        } -TimeoutSec 10
        
        # Extract address components from response
        $address = $response.address
        
        # Build administrative hierarchy object
        # Try multiple field names as OSM uses different keys for different regions
        return [PSCustomObject]@{
            City        = if ($address.city) { $address.city } 
                         elseif ($address.town) { $address.town }
                         elseif ($address.village) { $address.village }
                         elseif ($address.municipality) { $address.municipality }
                         else { "" }
            State       = if ($address.state) { $address.state }
                         elseif ($address.province) { $address.province }
                         elseif ($address.region) { $address.region }
                         elseif ($address.county) { $address.county }
                         else { "" }
            Country     = if ($address.country) { $address.country } else { "" }
            CountryCode = if ($address.country_code) { $address.country_code.ToUpper() } else { "" }
        }
    }
    catch {
        # Return empty object if geocoding fails
        Write-Warning "Failed to get country info: $($_.Exception.Message)"
        return [PSCustomObject]@{
            City        = ""
            State       = ""
            Country     = ""
            CountryCode = ""
        }
    }
}

# ===== OVERPASS API CONFIGURATION =====
$overpassEndpoint = "https://overpass-api.de/api/interpreter"

Write-Host "Querying OpenStreetMap for locations within $RadiusMeters meters..." -ForegroundColor Cyan

# ===== BUILD OVERPASS QUERY =====
# Overpass QL (Query Language) syntax for spatial searches
# Query structure:
# 1. Define search area (around: radius, lat, lon)
# 2. Filter by feature tags (tourism, historic, amenity, etc.)
# 3. Output format: json with geometry, tags, and metadata

# Build feature type filters for Overpass query
# Default: query common notable features if no types specified
if ($FeatureTypes.Count -eq 0) {
    # Default feature types: notable landmarks and points of interest
    # tourism: attractions, viewpoints, museums, monuments
    # historic: archaeological sites, castles, memorials
    # amenity: places of worship, theatres, libraries
    # natural: peaks, caves, beaches
    # leisure: parks, gardens, stadiums
    $featureFilters = @(
        'node["tourism"](around:RADIUS,LAT,LON);',
        'way["tourism"](around:RADIUS,LAT,LON);',
        'node["historic"](around:RADIUS,LAT,LON);',
        'way["historic"](around:RADIUS,LAT,LON);',
        'node["amenity"~"place_of_worship|theatre|arts_centre|library"](around:RADIUS,LAT,LON);',
        'way["amenity"~"place_of_worship|theatre|arts_centre|library"](around:RADIUS,LAT,LON);',
        'node["natural"~"peak|cave_entrance|beach|spring"](around:RADIUS,LAT,LON);',
        'way["natural"~"peak|cave_entrance|beach|spring"](around:RADIUS,LAT,LON);',
        'node["leisure"~"park|garden|stadium|playground"](around:RADIUS,LAT,LON);',
        'way["leisure"~"park|garden|stadium|playground"](around:RADIUS,LAT,LON);'
    )
}
else {
    # User-specified feature types
    # Build filters for both nodes and ways for each type
    $featureFilters = @()
    foreach ($type in $FeatureTypes) {
        $featureFilters += "node[`"$type`"](around:RADIUS,LAT,LON);"
        $featureFilters += "way[`"$type`"](around:RADIUS,LAT,LON);"
    }
}

# Construct complete Overpass QL query
# Format: [out:json]; ( ...filters... ); out center tags;
# out center: for ways, return center point instead of all nodes
# out tags: include all OSM tags for each element
$query = @"
[out:json][timeout:25];
(
  $($featureFilters -join "`n  ")
);
out center tags;
"@

# Replace placeholders with actual values
$query = $query.Replace("RADIUS", $RadiusMeters)
$query = $query.Replace("LAT", $Latitude)
$query = $query.Replace("LON", $Longitude)

# ===== EXECUTE OVERPASS QUERY =====
# Send POST request to Overpass API with query
try {
    Write-Host "Executing Overpass API query..." -ForegroundColor Gray
    
    $response = Invoke-RestMethod -Uri $overpassEndpoint -Method Post -Body @{
        data = $query
    } -Headers @{
        "User-Agent" = "PowerShell-OSM-Nearby/1.0"
    } -TimeoutSec 30
}
catch {
    Write-Error "Failed to query Overpass API: $($_.Exception.Message)"
    exit 1
}

# ===== PROCESS QUERY RESULTS =====
# Convert Overpass JSON response to structured location objects

Write-Host "Processing results..." -ForegroundColor Cyan
Write-Host "Raw results count: $($response.elements.Count)" -ForegroundColor Gray

$locations = @()

# Get country info once for the center point to use as fallback
# This avoids excessive Nominatim queries
Write-Host "Getting administrative information..." -ForegroundColor Gray
$centerCountryInfo = Get-CountryInfo -Lat $Latitude -Lon $Longitude
Start-Sleep -Milliseconds 1000  # Respect Nominatim rate limiting

foreach ($element in $response.elements) {
    # ===== EXTRACT COORDINATES =====
    # Nodes have lat/lon directly, ways have center point
    $lat = $null
    $lon = $null
    
    if ($element.type -eq "node" -and $element.lat -and $element.lon) {
        $lat = [double]$element.lat
        $lon = [double]$element.lon
    }
    elseif ($element.type -eq "way" -and $element.center) {
        $lat = [double]$element.center.lat
        $lon = [double]$element.center.lon
    }
    else {
        # Skip elements without coordinates
        Write-Host "  Skipping element: no coordinates" -ForegroundColor Yellow
        continue
    }
    
    # ===== CALCULATE DISTANCE FROM CENTER POINT =====
    $distanceMeters = Get-HaversineDistance -Lat1 $Latitude -Lon1 $Longitude -Lat2 $lat -Lon2 $lon
    
    # ===== EXTRACT OSM TAGS AND METADATA =====
    $tags = $element.tags
    
    # Get name from tags (try multiple name fields)
    $name = if ($tags.name) { $tags.name }
           elseif ($tags.'name:en') { $tags.'name:en' }
           elseif ($tags.'official_name') { $tags.'official_name' }
           elseif ($tags.'alt_name') { $tags.'alt_name' }
           else { "Unnamed Feature" }
    
    # Determine feature type from tags
    # Priority: tourism > historic > amenity > natural > leisure > other
    $featureType = if ($tags.tourism) { "Tourism: $($tags.tourism)" }
                  elseif ($tags.historic) { "Historic: $($tags.historic)" }
                  elseif ($tags.amenity) { "Amenity: $($tags.amenity)" }
                  elseif ($tags.natural) { "Natural: $($tags.natural)" }
                  elseif ($tags.leisure) { "Leisure: $($tags.leisure)" }
                  elseif ($tags.building) { "Building: $($tags.building)" }
                  else { "Other: $($element.type)" }
    
    # Build OSM identifier URL
    $osmId = "$($element.type)/$($element.id)"
    $osmUrl = "https://www.openstreetmap.org/$osmId"
    
    # Use center country info as fallback (already queried once)
    # This avoids rate limiting issues with Nominatim
    $city = $centerCountryInfo.City
    $state = $centerCountryInfo.State
    $country = $centerCountryInfo.Country
    $countryCode = $centerCountryInfo.CountryCode
    
    # Build administrative hierarchy string
    $adminParts = @()
    if ($city) { $adminParts += $city }
    if ($state -and $state -ne $city) { $adminParts += $state }
    if ($country) { $adminParts += $country }
    $adminHierarchy = $adminParts -join ", "
    if ([string]::IsNullOrWhiteSpace($adminHierarchy)) {
        $adminHierarchy = "Unknown"
    }
    
    # ===== CREATE LOCATION OBJECT =====
    $location = [PSCustomObject]@{
        Name            = $name
        OsmId           = $osmId
        OsmUrl          = $osmUrl
        LocationType    = $featureType
        Distance        = $distanceMeters
        Latitude        = $lat
        Longitude       = $lon
        City            = $city
        State           = $state
        Country         = $country
        CountryCode     = $countryCode
        AdminHierarchy  = $adminHierarchy
        Tags            = $tags
    }
    
    $locations += $location
}

# Sort locations by distance (nearest first)
$locations = $locations | Sort-Object -Property Distance

# ===== CONSOLE OUTPUT =====
# Display formatted list of locations with clean, professional layout

Write-Host ""
Write-Host "NEARBY OPENSTREETMAP LOCATIONS" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan
Write-Host "Center Point: $Latitude, $Longitude" -ForegroundColor Gray
Write-Host "Search Radius: $RadiusMeters meters" -ForegroundColor Gray
Write-Host "Results Found: $($locations.Count)" -ForegroundColor Gray
Write-Host ""

if ($locations.Count -eq 0) {
    Write-Host "No locations found within search radius." -ForegroundColor Yellow
}
else {
    foreach ($loc in $locations) {
        # Format distance for display (meters or kilometers)
        $distanceFormatted = Format-Distance -Meters $loc.Distance
        
        # Display location information in structured format
        Write-Host $loc.Name -ForegroundColor Green
        Write-Host "  Type        : $($loc.LocationType)" -ForegroundColor Gray
        Write-Host "  Distance    : $distanceFormatted" -ForegroundColor Gray
        Write-Host "  Location    : $($loc.AdminHierarchy)" -ForegroundColor Gray
        Write-Host "  OSM         : $($loc.OsmUrl)" -ForegroundColor Gray
        
        Write-Host ""
    }
}

# ===== GEOJSON EXPORT (OPTIONAL) =====
# Write results to GeoJSON file if output parameter provided
# GeoJSON format compatible with mapping tools and Set-GeoTag.ps1

if (-not [string]::IsNullOrWhiteSpace($Output)) {
    Write-Host "Exporting to GeoJSON..." -ForegroundColor Cyan
    
    # Build GeoJSON FeatureCollection
    $features = @()
    
    foreach ($loc in $locations) {
        # Create GeoJSON Feature with Point geometry
        # Properties include all metadata for Set-GeoTag.ps1 compatibility
        $feature = [ordered]@{
            type = "Feature"
            geometry = @{
                type = "Point"
                coordinates = @($loc.Longitude, $loc.Latitude)  # GeoJSON order: [lon, lat]
            }
            properties = [ordered]@{
                Location            = $loc.Name
                LocationType        = $loc.LocationType
                City                = $loc.City
                StateProvince       = $loc.State
                Country             = $loc.Country
                CountryCode         = $loc.CountryCode
                Radius              = 50  # Default radius in meters for geotagging
                LocationIdentifiers = @($loc.OsmUrl)
                OsmId               = $loc.OsmId
                Distance            = [Math]::Round($loc.Distance, 2)
            }
        }
        
        $features += $feature
    }
    
    # Create GeoJSON FeatureCollection structure
    $geojson = @{
        type = "FeatureCollection"
        features = $features
    }
    
    # Convert to JSON with deep nesting support
    # Depth 15 ensures all nested structures are serialized
    $geojsonText = $geojson | ConvertTo-Json -Depth 15
    
    # Write to file with UTF-8 encoding (no BOM for better compatibility)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Output, $geojsonText, $utf8NoBom)
    
    Write-Host "✓ GeoJSON saved to: $Output" -ForegroundColor Green
    Write-Host ""
}

Write-Host "Query complete." -ForegroundColor Cyan
