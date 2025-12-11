<#
.SYNOPSIS
    Query Wikidata for locations near a GPS coordinate and export to GeoJSON.

.DESCRIPTION
    Searches the Wikidata knowledge base for locations (places, landmarks, buildings, etc.)
    within a specified radius of a given latitude/longitude coordinate. Results include
    Wikidata identifiers, location types, administrative hierarchy (city/state/country),
    and Wikipedia articles when available.
    
    Outputs a formatted list to console and optionally exports to GeoJSON format for use
    with mapping tools or the Set-GeoTag.ps1 script.

.PARAMETER Latitude
    Center point latitude in decimal degrees (-90 to 90).

.PARAMETER Longitude
    Center point longitude in decimal degrees (-180 to 180).

.PARAMETER RadiusMeters
    Search radius in meters. Wikidata query service supports up to 1km (1000m) radius.

.PARAMETER Output
    Optional path to output GeoJSON file. If omitted, no file is written (console only).

.EXAMPLE
    .\Get-NearbyWikidataLocations.ps1 -Latitude 40.7829 -Longitude -73.9654 -RadiusMeters 500
    
    Displays nearby locations within 500m of Central Park (console output only).

.EXAMPLE
    .\Get-NearbyWikidataLocations.ps1 -Latitude 18.4663 -Longitude -66.1057 -RadiusMeters 500 -Output locations.geojson
    
    Searches Old San Juan and exports results to locations.geojson.

.NOTES
    Requires internet connection to query Wikidata SPARQL endpoint.
    Query results may vary based on Wikidata coverage in the area.
    Distance calculations use Haversine formula for accuracy.

.LINK
    https://www.wikidata.org/
    https://query.wikidata.org/
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
    [string]$Output = ""
)

# ===== SCRIPT INITIALIZATION =====
$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 for secure HTTPS connections to Wikidata
# Required for modern API endpoints that reject older TLS versions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Load System.Web assembly for URL encoding
# Required for properly encoding SPARQL query in URL parameters
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

# ===== WIKIDATA SPARQL ENDPOINT =====
$endpoint = "https://query.wikidata.org/sparql"
$radiusKm = $RadiusMeters / 1000.0

Write-Host "Querying Wikidata for locations within $RadiusMeters meters..." -ForegroundColor Cyan

# ===== SPARQL QUERY CONSTRUCTION =====
# Query retrieves locations with:
# - Geographic coordinates (wdt:P625)
# - Instance type (wdt:P31) for categorization
# - Administrative hierarchy (city P1376, state P131, country P17)
# - ISO 3166-1 alpha-3 country code (P298)
# - English Wikipedia articles (optional)
# - OpenStreetMap tags (optional)
#
# SPARQL query uses raw string to avoid PowerShell variable interpolation
# Placeholders (LAT, LON, RADIUSKM) are replaced after definition
$query = @'
SELECT ?item ?itemLabel ?coord ?instanceLabel ?cityLabel ?stateLabel ?countryLabel ?countryCode ?article
WHERE {
  # Spatial search: Find items within radius of center point
  SERVICE wikibase:around {
    ?item wdt:P625 ?coord .
    bd:serviceParam wikibase:center "Point(LON LAT)"^^geo:wktLiteral .
    bd:serviceParam wikibase:radius "RADIUSKM" .
    bd:serviceParam wikibase:distance ?distance .
  }

  # Get instance type (building, park, monument, etc.)
  OPTIONAL {
    ?item wdt:P31 ?instance .
  }

  # Get city (P1376 = capital of, or P131 = located in administrative territory)
  OPTIONAL {
    ?item wdt:P131 ?state .
    ?state wdt:P31 ?stateType .
    FILTER(?stateType IN (wd:Q7930614, wd:Q34876))  # City or state
    BIND(?state AS ?city)
  }

  # Get state/province (P131 = located in administrative territory)
  OPTIONAL {
    ?item wdt:P131 ?adminLevel1 .
    ?adminLevel1 wdt:P31 ?adminType .
    FILTER(?adminType IN (wd:Q10864048, wd:Q7930614, wd:Q26018))  # Province, city, region
    BIND(?adminLevel1 AS ?state)
  }

  # Get country (P17)
  OPTIONAL {
    ?item wdt:P17 ?country .
    
    # Get ISO 3166-1 alpha-3 country code (P298)
    OPTIONAL {
      ?country wdt:P298 ?countryCode .
    }
  }

  # Get English Wikipedia article (optional)
  OPTIONAL {
    ?article schema:about ?item ;
             schema:inLanguage "en" ;
             schema:isPartOf <https://en.wikipedia.org/> .
  }

  # Retrieve human-readable labels in English
  SERVICE wikibase:label { 
    bd:serviceParam wikibase:language "en" . 
  }
}
ORDER BY ?distance
'@

# Replace placeholders with actual coordinates and radius
# String replacement avoids complex SPARQL string interpolation issues
$query = $query.Replace("LAT", $Latitude.ToString())
$query = $query.Replace("LON", $Longitude.ToString())
$query = $query.Replace("RADIUSKM", $radiusKm.ToString())

# ===== HTTP REQUEST CONSTRUCTION =====
# Build URL with properly encoded query parameter
# URL encoding prevents special characters from breaking the request

# Encode SPARQL query for URL parameter
$encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)

# Manually construct URL to avoid UriBuilder parsing issues
# UriBuilder can fail when query string is very long or contains complex characters
$url = "$endpoint`?query=$encodedQuery&format=json"

# ===== EXECUTE WIKIDATA QUERY =====
# Send HTTP GET request to Wikidata SPARQL endpoint
# User-Agent header identifies the client for rate limiting and debugging
try {
    $response = Invoke-RestMethod -Uri $url -Headers @{
        "User-Agent" = "PowerShell-Wikidata-Nearby/1.0"
        "Accept" = "application/sparql-results+json"
    }
}
catch {
    Write-Error "Failed to query Wikidata: $($_.Exception.Message)"
    exit 1
}

# ===== PROCESS QUERY RESULTS =====
# Convert SPARQL JSON response to structured location objects
# Each binding represents one location result from Wikidata

Write-Host "Processing results..." -ForegroundColor Cyan

$locations = @()

foreach ($b in $response.results.bindings) {
    # ===== PARSE GEOGRAPHIC COORDINATES =====
    # Wikidata returns coordinates in WKT format: "Point(longitude latitude)"
    # Extract numeric values using regex pattern matching
    
    # Safely access coord.value property
    if (-not ($b.PSObject.Properties['coord'] -and $b.coord.PSObject.Properties['value'])) {
        Write-Host "  Skipping item: no coord property" -ForegroundColor Yellow
        continue
    }
    
    $coordText = $b.coord.value
    $lon = $null
    $lat = $null
    
    if ($coordText -match "Point\(([-0-9\.]+)\s+([-0-9\.]+)\)") {
        $lon = [double]$matches[1]
        $lat = [double]$matches[2]
    }
    else {
        # Skip items without valid coordinates
        Write-Host "  Skipping item: invalid coord format: $coordText" -ForegroundColor Yellow
        continue
    }
    
    # ===== CALCULATE DISTANCE FROM CENTER POINT =====
    # Use Haversine formula for accurate great-circle distance
    $distanceMeters = Get-HaversineDistance -Lat1 $Latitude -Lon1 $Longitude -Lat2 $lat -Lon2 $lon
    
    # ===== EXTRACT METADATA FIELDS =====
    # Build location object with all available information
    # Safely access nested properties using PSObject.Properties for null-safe access
    
    $locationName = if ($b.PSObject.Properties['itemLabel'] -and $b.itemLabel.PSObject.Properties['value']) { 
        $b.itemLabel.value 
    } else { 
        "Unknown" 
    }
    
    $wikidataUri = if ($b.PSObject.Properties['item'] -and $b.item.PSObject.Properties['value']) { 
        $b.item.value 
    } else { 
        "" 
    }
    
    $locationType = if ($b.PSObject.Properties['instanceLabel'] -and $b.instanceLabel.PSObject.Properties['value']) { 
        $b.instanceLabel.value 
    } else { 
        "Unknown" 
    }
    
    $city = if ($b.PSObject.Properties['cityLabel'] -and $b.cityLabel.PSObject.Properties['value']) { 
        $b.cityLabel.value 
    } else { 
        "" 
    }
    
    $state = if ($b.PSObject.Properties['stateLabel'] -and $b.stateLabel.PSObject.Properties['value']) { 
        $b.stateLabel.value 
    } else { 
        "" 
    }
    
    $country = if ($b.PSObject.Properties['countryLabel'] -and $b.countryLabel.PSObject.Properties['value']) { 
        $b.countryLabel.value 
    } else { 
        "" 
    }
    
    $countryCode = if ($b.PSObject.Properties['countryCode'] -and $b.countryCode.PSObject.Properties['value']) { 
        $b.countryCode.value 
    } else { 
        "" 
    }
    
    $wikipedia = if ($b.PSObject.Properties['article'] -and $b.article.PSObject.Properties['value']) { 
        $b.article.value 
    } else { 
        "" 
    }
    
    # ===== BUILD ADMINISTRATIVE HIERARCHY STRING =====
    # Format: City, State/Province, Country
    # Omit empty components for cleaner display
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
        Name            = $locationName
        WikidataUri     = $wikidataUri
        LocationType    = $locationType
        Distance        = $distanceMeters
        Latitude        = $lat
        Longitude       = $lon
        City            = $city
        State           = $state
        Country         = $country
        CountryCode     = $countryCode
        AdminHierarchy  = $adminHierarchy
        Wikipedia       = $wikipedia
    }
    
    $locations += $location
}

# Sort locations by distance (nearest first)
$locations = $locations | Sort-Object -Property Distance

# ===== CONSOLE OUTPUT =====
# Display formatted list of locations with clean, professional layout

Write-Host ""

Write-Host "NEARBY WIKIDATA LOCATIONS" -ForegroundColor Cyan
Write-Host "=========================" 
Write-Host "Center Point: $Latitude, $Longitude" -ForegroundColor Gray
Write-Host "Search Radius: $RadiusMeters meters" -ForegroundColor Gray
Write-Host "Results Found: $($locations.Count)" -ForegroundColor Gray
Write-Host ""
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
        Write-Host "  Wikidata    : $($loc.WikidataUri)" -ForegroundColor Gray
        
        if ($loc.Wikipedia) {
            Write-Host "  Wikipedia   : $($loc.Wikipedia)" -ForegroundColor Gray
        }
        
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
                LocationIdentifiers = @($loc.WikidataUri)
                Wikipedia           = $loc.Wikipedia
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
