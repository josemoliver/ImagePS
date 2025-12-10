<#
.SYNOPSIS
    Downloads comprehensive photo metadata from a Flickr user account using the Flickr API.

.DESCRIPTION
    Authenticates with Flickr API using credentials from a JSON configuration file and
    retrieves detailed metadata for all photos in the specified user's account. Metadata
    includes basic fields (title, description, tags), dates, URLs, location data, and EXIF
    information. Results are exported to a JSON file.

.PARAMETER ConfigPath
    Path to the JSON configuration file containing Flickr API credentials.
    Default: "flickrconfig.json" in the current directory.

.PARAMETER OutputPath
    Path for the output JSON file containing downloaded metadata.
    Default: "flickr-metadata-<timestamp>.json" in the current directory.

.PARAMETER MaxPhotos
    Maximum number of photos to retrieve (for testing). Omit to retrieve all photos.

.PARAMETER PerPage
    Number of photos to retrieve per API request (1-500). Default: 100

.EXAMPLE
    ./Get-FlickrMetadata.ps1 -ConfigPath "flickrconfig.json" -OutputPath "my-photos.json"

.EXAMPLE
    ./Get-FlickrMetadata.ps1 -MaxPhotos 50

.NOTES
    Requires a Flickr API key and secret. Get them at: https://www.flickr.com/services/apps/create/
    The config JSON file should contain: apiKey, apiSecret, and userNsid

#>

param(
    [Parameter()]
    [string]$ConfigPath = "flickrconfig.json",
    
    [Parameter()]
    [string]$OutputPath = "",
    
    [Parameter()]
    [int]$MaxPhotos = 0,  # 0 = retrieve all photos
    
    [Parameter()]
    [ValidateRange(1, 500)]
    [int]$PerPage = 100
)

# ===== SCRIPT INITIALIZATION =====
$ErrorActionPreference = "Stop"
$scriptStart = Get-Date

# Load System.Web for URL encoding (required by helper functions)
Add-Type -AssemblyName System.Web

# ===== FLICKR API CONFIGURATION =====
# Base URL for Flickr REST API
$flickrApiBase = "https://api.flickr.com/services/rest/"

# ===== HELPER FUNCTIONS =====

<#
.SYNOPSIS
    Generates MD5 signature for Flickr API requests (required for authenticated calls).
#>
function Get-FlickrApiSignature {
    param(
        [hashtable]$Params,
        [string]$ApiSecret
    )
    
    # Sort parameters alphabetically by key (required by Flickr)
    $sortedKeys = $Params.Keys | Sort-Object
    
    # Build signature string: secret + key1value1 + key2value2 + ...
    $sigString = $ApiSecret
    foreach ($key in $sortedKeys) {
        $sigString += "$key$($Params[$key])"
    }
    
    # Calculate MD5 hash
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sigString))
    $signature = [System.BitConverter]::ToString($hash).Replace("-", "").ToLower()
    
    return $signature
}

<#
.SYNOPSIS
    Makes a signed Flickr API request and returns the JSON response.
#>
function Invoke-FlickrApi {
    param(
        [string]$Method,
        [hashtable]$Params,
        [string]$ApiKey,
        [string]$ApiSecret,
        [switch]$RequireAuth  # Only sign if authentication is required
    )
    
    # Add required parameters
    $allParams = @{
        method         = $Method
        api_key        = $ApiKey
        format         = "json"
        nojsoncallback = "1"
    }
    
    # Merge custom parameters
    foreach ($key in $Params.Keys) {
        $allParams[$key] = $Params[$key]
    }
    
    # Generate API signature only if authentication is required
    # Most read-only methods don't need signatures
    if ($RequireAuth) {
        $signature = Get-FlickrApiSignature -Params $allParams -ApiSecret $ApiSecret
        $allParams["api_sig"] = $signature
    }
    
    # Build query string
    $queryParts = @()
    foreach ($key in $allParams.Keys) {
        $encodedValue = [System.Web.HttpUtility]::UrlEncode($allParams[$key].ToString())
        $queryParts += "$key=$encodedValue"
    }
    $queryString = $queryParts -join "&"
    
    # Make request - construct URL properly
    $baseUrl = "https://api.flickr.com/services/rest/"
    $url = $baseUrl + "?" + $queryString
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        return $response
    }
    catch {
        Write-Error "Flickr API request failed: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Retrieves detailed metadata for a single photo including location and EXIF data.
#>
function Get-FlickrPhotoDetails {
    param(
        [string]$PhotoId,
        [string]$ApiKey,
        [string]$ApiSecret
    )
    
    # Get comprehensive photo info (includes description, dates, URLs, tags, location)
    $infoResponse = Invoke-FlickrApi -Method "flickr.photos.getInfo" `
        -Params @{ photo_id = $PhotoId } `
        -ApiKey $ApiKey -ApiSecret $ApiSecret
    
    # Get EXIF data
    $exifResponse = Invoke-FlickrApi -Method "flickr.photos.getExif" `
        -Params @{ photo_id = $PhotoId } `
        -ApiKey $ApiKey -ApiSecret $ApiSecret
    
    # Combine results
    return @{
        info = $infoResponse.photo
        exif = $exifResponse.photo
    }
}

# ===== MAIN SCRIPT =====

try {
    Write-Host "===== Flickr Metadata Downloader ====="
    Write-Host ""
    
    # ===== LOAD CONFIGURATION =====
    Write-Host "Loading configuration from: $ConfigPath"
    
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }
    
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    
    # Validate required configuration fields
    if (-not $config.apiKey -or -not $config.apiSecret -or -not $config.userNsid) {
        throw "Configuration file must contain: apiKey, apiSecret, and userNsid"
    }
    
    Write-Host "✓ Configuration loaded for user: $($config.userNsid)"
    Write-Host ""
    
    # ===== SET OUTPUT PATH =====
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = "flickr-metadata-$timestamp.json"
    }
    
    # ===== RETRIEVE PHOTO LIST =====
    Write-Host "Retrieving photo list from Flickr..."
    
    # Get total photo count first (no auth required for public read)
    $testResponse = Invoke-FlickrApi -Method "flickr.people.getPhotos" `
        -Params @{ 
            user_id  = $config.userNsid
            per_page = "1"
            page     = "1"
            extras   = "date_upload,date_taken,media,url_o,url_k,url_h,url_l,url_c,url_m,url_s,url_t,url_sq,tags,geo"
        } `
        -ApiKey $config.apiKey -ApiSecret $config.apiSecret
    
    if ($testResponse.stat -ne "ok") {
        throw "Failed to retrieve photo list: $($testResponse.message)"
    }
    
    $totalPhotos = [int]$testResponse.photos.total
    Write-Host "✓ Found $totalPhotos photos in account"
    
    # Determine how many photos to retrieve
    if ($MaxPhotos -gt 0 -and $MaxPhotos -lt $totalPhotos) {
        $targetCount = $MaxPhotos
        Write-Host "  Limiting to first $MaxPhotos photos (for testing)"
    }
    else {
        $targetCount = $totalPhotos
    }
    
    # Calculate number of pages needed
    $totalPages = [Math]::Ceiling($targetCount / $PerPage)
    
    Write-Host "  Retrieving $targetCount photos in $totalPages page(s) ($PerPage per page)"
    Write-Host ""
    
    # ===== RETRIEVE ALL PHOTOS =====
    $allPhotos = [System.Collections.Generic.List[object]]::new()
    $photoIndex = 0
    
    for ($page = 1; $page -le $totalPages; $page++) {
        # Calculate items for this page (last page might have fewer)
        $remaining = $targetCount - $allPhotos.Count
        $currentPerPage = [Math]::Min($PerPage, $remaining)
        
        Write-Progress -Activity "Downloading photo list" `
            -Status "Page $page of $totalPages" `
            -PercentComplete (($page - 1) / $totalPages * 100)
        
        # Get photo list for this page (no auth required for public read)
        $listResponse = Invoke-FlickrApi -Method "flickr.people.getPhotos" `
            -Params @{ 
                user_id  = $config.userNsid
                per_page = $currentPerPage.ToString()
                page     = $page.ToString()
                extras   = "date_upload,date_taken,media,url_o,url_k,url_h,url_l,url_c,url_m,url_s,url_t,url_sq,tags,geo"
            } `
            -ApiKey $config.apiKey -ApiSecret $config.apiSecret
        
        if ($listResponse.stat -ne "ok") {
            Write-Warning "Failed to retrieve page $page : $($listResponse.message)"
            continue
        }
        
        # Add photos from this page
        foreach ($photo in $listResponse.photos.photo) {
            $allPhotos.Add($photo)
        }
    }
    
    Write-Progress -Activity "Downloading photo list" -Completed
    Write-Host "✓ Retrieved $($allPhotos.Count) photo records"
    Write-Host ""
    
    # ===== RETRIEVE DETAILED METADATA =====
    Write-Host "Downloading detailed metadata (info + EXIF) for each photo..."
    
    $detailedPhotos = [System.Collections.Generic.List[object]]::new()
    $processedCount = 0
    $errorCount = 0
    
    foreach ($photo in $allPhotos) {
        $processedCount++
        
        Write-Progress -Activity "Downloading detailed metadata" `
            -Status "Photo $processedCount of $($allPhotos.Count): $($photo.title)" `
            -PercentComplete (($processedCount / $allPhotos.Count) * 100)
        
        try {
            # Get detailed metadata (info + EXIF)
            $details = Get-FlickrPhotoDetails -PhotoId $photo.id `
                -ApiKey $config.apiKey -ApiSecret $config.apiSecret
            
            # Build comprehensive metadata object
            $metadata = [ordered]@{
                # Basic fields
                id             = $photo.id
                owner          = $photo.owner
                title          = $photo.title
                description    = if ($details.info.description._content) { $details.info.description._content } else { "" }
                tags           = $photo.tags
                dateUploaded   = $photo.dateupload
                dateTaken      = $photo.datetaken
                media          = $photo.media
                
                # Image URLs (all available sizes)
                urls           = @{
                    original  = if ($photo.url_o) { $photo.url_o } else { $null }
                    large2048 = if ($photo.url_k) { $photo.url_k } else { $null }
                    large1600 = if ($photo.url_h) { $photo.url_h } else { $null }
                    large1024 = if ($photo.url_l) { $photo.url_l } else { $null }
                    medium800 = if ($photo.url_c) { $photo.url_c } else { $null }
                    medium500 = if ($photo.url_m) { $photo.url_m } else { $null }
                    small320  = if ($photo.url_s) { $photo.url_s } else { $null }
                    thumbnail = if ($photo.url_t) { $photo.url_t } else { $null }
                    square    = if ($photo.url_sq) { $photo.url_sq } else { $null }
                }
                
                # Location metadata (if available)
                location       = @{
                    latitude  = if ($photo.latitude -and $photo.latitude -ne "0") { $photo.latitude } else { $null }
                    longitude = if ($photo.longitude -and $photo.longitude -ne "0") { $photo.longitude } else { $null }
                    accuracy  = if ($photo.accuracy) { $photo.accuracy } else { $null }
                    locality  = if ($details.info.location.locality._content) { $details.info.location.locality._content } else { $null }
                    region    = if ($details.info.location.region._content) { $details.info.location.region._content } else { $null }
                    country   = if ($details.info.location.country._content) { $details.info.location.country._content } else { $null }
                }
                
                # EXIF metadata (parsed from EXIF response)
                exif           = @{}
            }
            
            # Parse EXIF tags
            if ($details.exif.exif) {
                foreach ($exifTag in $details.exif.exif) {
                    # Use tag label as key, raw value as value
                    $tagLabel = $exifTag.label
                    $tagValue = if ($exifTag.raw._content) { $exifTag.raw._content } else { "" }
                    $metadata.exif[$tagLabel] = $tagValue
                }
            }
            
            $detailedPhotos.Add($metadata)
            
            Write-Host "✓ $processedCount/$($allPhotos.Count): $($photo.title)"
        }
        catch {
            $errorCount++
            Write-Warning "Failed to retrieve metadata for photo $($photo.id): $_"
        }
    }
    
    Write-Progress -Activity "Downloading detailed metadata" -Completed
    Write-Host ""
    Write-Host "✓ Successfully retrieved detailed metadata for $($detailedPhotos.Count) photos"
    
    if ($errorCount -gt 0) {
        Write-Host "  $errorCount photos had errors and were skipped"
    }
    
    # ===== EXPORT TO JSON =====
    Write-Host ""
    Write-Host "Exporting metadata to: $OutputPath"
    
    # Create output object with metadata
    $output = [ordered]@{
        exportDate   = (Get-Date -Format "o")
        userNsid     = $config.userNsid
        totalPhotos  = $detailedPhotos.Count
        photos       = $detailedPhotos
    }
    
    # Export to JSON with proper formatting
    $output | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding utf8
    
    Write-Host "✓ Metadata exported successfully"
    Write-Host ""
    
    # ===== SUMMARY =====
    $elapsed = (Get-Date) - $scriptStart
    $duration = '{0:hh\:mm\:ss}' -f $elapsed
    
    Write-Host "===== Summary ====="
    Write-Host "Photos exported      : $($detailedPhotos.Count)"
    Write-Host "Errors               : $errorCount"
    Write-Host "Output file          : $OutputPath"
    Write-Host "Execution duration   : $duration"
    Write-Host ""
    Write-Host "Done!"
}
catch {
    Write-Error $_
    exit 1
}
