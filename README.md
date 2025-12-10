
# ImagePS

PowerShell scripts for automating photo metadata operations using ExifTool.

## Overview

ImagePS is a collection of PowerShell utilities designed to batch process image metadata (EXIF, IPTC, XMP tags) across large photo collections. Each script targets a specific metadata operation and is designed to work seamlessly with ExifTool.

## Features

- **Creator & Copyright Management** - Batch set creator and copyright information
- **Unique ID Assignment** - Assign random GUIDs to image files automatically
- **Timezone Offset Correction** - Update datetime and timezone metadata across images
- **Photo Time Synchronization** - Correct camera clock errors using reference images
- **Geolocation Tagging** - Match GPS coordinates to locations and add location metadata
  - Polygon support with point-in-polygon logic
  - Priority of specific Point features over containing Polygons
  - Default radius of 50m when missing in GeoJSON
- **Lens Metadata** - Add Microsoft XMP lens information to files based on camera Make/Model/LensID
- **Weather Annotation** - Tag images with weather data based on photo timestamp
- **Nearby Location Discovery** - Generate GeoJSON from external sources
  - Wikidata SPARQL (Get-NearbyWikidataLocations.ps1)
  - OpenStreetMap Overpass API (Get-NearbyOSMLocations.ps1)

## Requirements

- **PowerShell 5.0+** (or PowerShell Core/7+)
- **ExifTool** - Must be installed and available in system PATH
  - Download: https://exiftool.org/
  - Windows Package Managers: `choco install exiftool` or `scoop install exiftool`
  - Verify installation: `exiftool -ver`

## Scripts

### Set-Rights.ps1

Sets creator and copyright metadata on images using MWG (Metadata Working Group) standards.

**Parameters:**
- `-Name` (required): Creator/author name
- `-Filepath` (required): Directory containing images
- `-Year` (optional): Copyright year (defaults to current year)
- `-Recurse` (optional): Process subdirectories recursively

**Example:**
```powershell
.\Set-Rights.ps1 -Name "Jane Doe" -Filepath "C:\Photos" -Recurse
```

**Supported Formats:** JPG, JPEG, PNG, TIF, TIFF, HEIC, HEIF

---

### Set-ImageUniqueID.ps1

Assigns random dashless GUIDs to the ImageUniqueID EXIF tag, skipping files that already have a unique ID.

**Parameters:**
- `-Filepath` (required): Directory containing images
- `-Extensions` (optional): File extensions to process (default: `@("jpg")`)
- `-Recurse` (optional): Process subdirectories recursively

**Example:**
```powershell
.\Set-ImageUniqueID.ps1 -Path "C:\Photos" -Extensions @("jpg","png") -Recurse
```

**Output:** Progress bar showing processing status; skipped files marked with `✓`, new assignments marked with `→`

---

### Set-TimeZone.ps1

Updates timezone offset metadata across EXIF and XMP datetime fields. Useful for correcting photos taken in different timezones.

**Parameters:**
- `-Timezone` (required): ISO 8601 offset format (e.g., `+02:00`, `-05:00`)
  - Format: `±HH:MM` where HH ranges from 00-14
  - Leave blank to use local system timezone
- `-Filepath` (required): Directory containing images

**Example:**
```powershell
.\Set-TimeZone.ps1 -Timezone "+02:00" -Filepath "C:\Photos"
```

**Updated Fields:**
- `OffsetTime*` (all variants)
- `XMP-photoshop:DateCreated`
- `XMP-xmp:CreateDate`
- `XMP-exif:DateTimeOriginal`

---

### Sync-PhotoTime.ps1

Synchronizes photo timestamps across a collection by calculating the time difference between a reference image and its correct time, then applying that correction to all images.

**Parameters:**
- `-BaseFile` (required): Reference image file (e.g., photo of a clock showing correct time)
- `-CorrectDate` (required): The correct date in `yyyy-MM-dd` format
- `-CorrectTime` (required): The correct time in `HH:mm:ss` format (24-hour)
- `-FilePath` (required): Directory containing images to synchronize, or single file path

**Workflow:**
1. Extracts EXIF DateTimeOriginal from the reference image
2. Calculates time delta between actual and correct time
3. Prompts user to Accept, Dry run, or Cancel
4. Updates all datetime fields conditionally across EXIF, IPTC, and XMP
5. Preserves timezone offsets if present

**Example:**
```powershell
.\Sync-PhotoTime.ps1 -BaseFile "C:\Photos\IMG_0001.JPG" -CorrectDate "2025-12-07" -CorrectTime "14:23:00" -FilePath "C:\Photos"
```

**Updated Fields:**
- Always: `ExifIFD:DateTimeOriginal/CreateDate/ModifyDate`, `XMP-photoshop:DateCreated`, `XMP-xmp:CreateDate/MetadataDate/ModifyDate`
- Conditional: `IPTC:DateCreated/TimeCreated`, `XMP-tiff:DateTime`, `XMP-exif:DateTimeOriginal/DateTimeDigitized/DateTimeModified`
- Timezone: `OffsetTime`, `OffsetTimeDigitized` (if OffsetTimeOriginal exists)

**Supported Formats:** JPG, JPEG, JXL, PNG, TIF, TIFF, HEIC, HEIF, ARW, CR2, CR3, NEF, RW2, ORF, RAF, DNG, WEBP

**Requirements:** PowerShell 7+

---

### Set-GeoTag.ps1

Matches GPS coordinates in image files to nearest locations from a locations database and writes location metadata tags.

**Parameters:**
- `-FilePath` (required): Directory containing images with GPS data
- `-Write` (optional): Switch to enable writing metadata. Without this, performs a dry run

**Matching Rules:**
- **Rule 1 (Exact Location):** If GPS within location's Radius, writes:
  - `MWG:Location`, `MWG:City`, `MWG:State`, `MWG:Country`, `CountryCode`
  - Appends LocationIdentifiers to `XMP-iptcExt:LocationCreated`
- **Rule 2 (Nearby):** If within 500m but outside Radius, writes:
  - `MWG:City`, `MWG:State`, `MWG:Country`, `CountryCode`

**Behavior Notes:**
- When inside a Polygon feature, the script also checks for the nearest Point feature; if the Point is within its own radius, it takes priority over the Polygon (more specific tagging).
- If a feature in `locations.geojson` does not include a `Radius` property or it is empty, the script uses a default of 50 meters.

**Example:**
```powershell
.\Set-GeoTag.ps1 -FilePath "C:\Photos" -Write
```

**Dependencies:** Requires `locations.geojson` in script directory or target folder

---

### Get-NearbyWikidataLocations.ps1

Queries the Wikidata SPARQL endpoint for locations near a GPS coordinate and prints a clean, formatted list. Optionally exports a GeoJSON FeatureCollection compatible with `Set-GeoTag.ps1`.

**Parameters:**
- `-Latitude` (required): Decimal degrees
- `-Longitude` (required): Decimal degrees
- `-RadiusMeters` (required): Search radius in meters
- `-Output` (optional): Path to GeoJSON file; omit for console-only

**Example:**
```powershell
.\Get-NearbyWikidataLocations.ps1 -Latitude 18.4663 -Longitude -66.1057 -RadiusMeters 500 -Output wikidata.geojson
```

**GeoJSON Properties:**
- `Location`, `LocationType`, `City`, `StateProvince`, `Country`, `CountryCode`, `Radius` (defaults to 50), `LocationIdentifiers` (Wikidata URI)

---

### Get-NearbyOSMLocations.ps1

Queries OpenStreetMap via the Overpass API to find nearby POIs and prints a clean, formatted list. Optionally exports a GeoJSON FeatureCollection compatible with `Set-GeoTag.ps1`.

**Parameters:**
- `-Latitude` (required): Decimal degrees
- `-Longitude` (required): Decimal degrees
- `-RadiusMeters` (required): Search radius in meters
- `-Output` (optional): Path to GeoJSON file; omit for console-only
- `-FeatureTypes` (optional): Array of OSM tag keys to include (e.g., `"tourism"`, `"historic"`, `"amenity"`)

**Example:**
```powershell
.\Get-NearbyOSMLocations.ps1 -Latitude 40.7589 -Longitude -73.9851 -RadiusMeters 300 -FeatureTypes "tourism","historic" -Output osm.geojson
```

**GeoJSON Properties:**
- `Location`, `LocationType`, `City`, `StateProvince`, `Country`, `CountryCode`, `Radius` (defaults to 50), `LocationIdentifiers` (OSM URL), `OsmId`

### Set-Lens.ps1

Applies lens metadata based on camera Make/Model/LensID using rules from LensRules.json.

**Parameters:**
- `-Filepath` (required): Directory containing images
- `-Recurse` (optional): Process subdirectories recursively
- `-DryRun` (optional): Preview changes without writing to files

**Example:**
```powershell
.\Set-Lens.ps1 -Filepath "C:\Photos" -Recurse
.\Set-Lens.ps1 -Filepath "C:\Photos" -DryRun
```

**Output:** Sets `XMP-microsoft:Lens` metadata based on matched rules. Displays summary report at completion.

**Dependencies:** Requires `LensRules.json` in script directory

---

### Set-WeatherTags.ps1

Annotates images with weather data (temperature, humidity, pressure) by matching photo EXIF timestamps to weather readings.

**Parameters:**
- `-FilePath` (required): Directory containing images
- `-Write` (optional): Switch to enable writing metadata. Without this, only preview is shown
- `-Threshold` (optional): Maximum time difference in minutes between photo and weather reading (default: 30)

**Example:**
```powershell
.\Set-WeatherTags.ps1 -FilePath "C:\Photos" -Write -Threshold 15
.\Set-WeatherTags.ps1 -FilePath "C:\Photos" -Write
```

**Supported Formats:** JPG, JPEG, JXL, PNG, TIF, TIFF, HEIC, HEIF, ARW, CR2, CR3, NEF, RW2, ORF, RAF, DNG, WEBP

**Dependencies:** Requires `weatherhistory.csv` file in target directory (CSV format: Date,Time,Temperature,Humidity,Pressure)

**Performance:** Uses batch ExifTool operations for optimal performance with large image collections

---

## Usage

1. **Navigate to script directory:**
	```powershell
	cd D:\Path\To\ImagePS\scripts
	```

2. **Run desired script:**
	```powershell
	pwsh -File Set-Rights.ps1 -Name "Your Name" -FilePath "C:\Photos" -Recurse
	```

3. **Nearby discovery (Wikidata):**
  ```powershell
  # Console only
  ./Get-NearbyWikidataLocations.ps1 -Latitude 18.4663 -Longitude -66.1057 -RadiusMeters 500

  # Export to GeoJSON
  ./Get-NearbyWikidataLocations.ps1 -Latitude 18.4663 -Longitude -66.1057 -RadiusMeters 500 -Output wikidata.geojson
  ```

4. **Nearby discovery (OpenStreetMap):**
  ```powershell
  # Console only
  ./Get-NearbyOSMLocations.ps1 -Latitude 40.7589 -Longitude -73.9851 -RadiusMeters 300 -FeatureTypes "tourism","historic"

  # Export to GeoJSON
  ./Get-NearbyOSMLocations.ps1 -Latitude 40.7589 -Longitude -73.9851 -RadiusMeters 300 -FeatureTypes "tourism","historic" -Output osm.geojson
  ```

3. **Verify changes:**
	```powershell
	exiftool -a "C:\Photos\image.jpg"
	```

## Important Notes

- **Backup First**: Scripts modify files in place. Always backup original images before running.
- **UTF-8 Handling**: Creator/copyright metadata is processed as UTF-8 without BOM to support international characters.
- **ExifTool Path**: ExifTool must be in system PATH. If not found, scripts will exit with error.
- **Timezone Format**: Must use `±HH:MM` format. Invalid formats will cause script to exit.
- **File Preservation**: All metadata is preserved by default; only specified tags are modified.
- **Dry Run / Preview Mode**: `Set-GeoTag.ps1`, `Set-Lens.ps1`, and `Set-WeatherTags.ps1` support preview modes without writing:
  - `Set-GeoTag.ps1` (no `-Write` flag)
  - `Set-Lens.ps1` with `-DryRun`
  - `Set-WeatherTags.ps1` (no `-Write` flag)
- **External Data Files**: Some scripts require companion data files in the script directory:
  - `Set-GeoTag.ps1` requires `locations.geojson`
  - `Set-Lens.ps1` requires `LensRules.json`
  - `Set-WeatherTags.ps1` requires `weatherhistory.csv`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "ExifTool not found" | Install ExifTool and add to system PATH, then restart PowerShell |
| "The specified path does not exist" | Verify the `-FilePath` or `-Path` parameter points to an existing directory |
| "Invalid Timezone format" | Use format `±HH:MM` (e.g., `+02:00` or `-05:00`) |
| No files processed | Check image file extensions match script filters (JPG, PNG, etc.) |
| Changes not saved | Ensure ExifTool has write permissions to image directory |
| "locations.geojson not found" | Ensure `locations.geojson` exists in script directory or target folder (required by `Set-GeoTag.ps1`) |
| "LensRules.geojson not found" | Ensure `LensRules.geojson` exists in script directory (required by `Set-Lens.ps1`) |
| "weatherhistory.csv not found" | Ensure `weatherhistory.csv` exists in target directory (required by `Set-WeatherTags.ps1`) |
| GPS data not tagged | Verify images contain valid GPS coordinates (latitude/longitude) readable by ExifTool |
| Weather threshold issues | Adjust `-Threshold` parameter (default 30 minutes) to match your weather data intervals |
| Date/Time format errors (Sync-PhotoTime) | Use `yyyy-MM-dd` for CorrectDate and `HH:mm:ss` (24-hour) for CorrectTime |
| "This script requires PowerShell 7" | Install PowerShell 7+ for `Sync-PhotoTime.ps1`: https://github.com/PowerShell/PowerShell/releases |

## Development

For AI coding agents working with this codebase, see [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture details, design patterns, and conventions.

## License

See LICENSE file for details.
