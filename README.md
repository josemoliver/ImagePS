
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

### Set-ImageAutoRotate.ps1

Losslessly rotates and/or mirrors images based on the EXIF `Orientation` tag and then sets the tag to `1` (Horizontal / Normal). Uses `jpegtran` (libjpeg/libjpeg-turbo) for lossless JPEG transforms when available and `exiftool` for metadata inspection and updates. Skips files with missing Orientation or already set to `1`.

**Parameters:**
- `-Path` (required): Single file or directory to process
- `-Recursive` (optional): Process subdirectories when `-Path` is a directory

**Example:**
```powershell
.
\Set-ImageAutoRotate.ps1 -Path "C:\Photos" -Recursive
```

**Notes:**
- Requires `exiftool` in PATH. For lossless pixel transforms on JPEGs, install `jpegtran` (part of libjpeg-turbo). If `jpegtran` is not available the script will still update the EXIF `Orientation` tag to `1` but will not perform a pixel transform.


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

Matches GPS coordinates in image files to nearest locations from one or more GeoJSON FeatureCollections and writes location metadata tags.

**Parameters:**
- `-FilePath` (required): Directory containing images with GPS data
- `-GeoJson` (required): Path to a `.geojson`/`.json` file OR a folder containing one or more such files (recursively merged)
- `-Write` (optional): Switch to enable writing metadata. Without this, performs a dry run

**Matching Rules:**
- **Rule 1 (Exact Location):** If GPS within location's Radius, writes:
  - `MWG:Location`, `MWG:City`, `MWG:State`, `MWG:Country`, `CountryCode`
  - Appends LocationIdentifiers to `XMP-iptcExt:LocationCreated`
- **Rule 2 (Nearby):** If within 500m but outside Radius, writes:
  - `MWG:City`, `MWG:State`, `MWG:Country`, `CountryCode`
- **Rule 3 (Region Polygons):** If the image point lies inside a Polygon feature whose `properties.Type` is one of the configured RegionTypes (default: `city`, `state`, `admin_region`), then override the City/StateProvince/Country/CountryCode produced by Rule 1 or Rule 2 using the non-empty values from that region polygon.

**Behavior Notes:**
- Polygon support with point-in-polygon detection. If inside a Polygon, a nearby Point within its own radius takes precedence (more specific).
- Default `Radius` is 50 m when missing/empty.
- Conditional writes: Location/Sublocation, City, StateProvince, Country, CountryCode are only written when values are non-empty (prevents blank tags).
- Validation requires coordinates only (Latitude/Longitude). Location/City/StateProvince/Country may be missing.
- Multiple GeoJSON inputs: when `-GeoJson` is a folder, all `.geojson` and `.json` files are merged and processed together.
- RegionTypes are configurable at the top of the script: `$RegionTypes = @('city','state','admin_region')`.

**Example Scenarios:**
- Inside polygon and Point within radius: Point chosen; specific Location + identifiers written (Rule 1). If also inside a region polygon, the region can override City/State/Country/CountryCode (Rule 3).
- Inside overlapping polygons, no Point match: Nearest polygon centroid chosen; Location written if present (Rule 1), then region overrides may apply (Rule 3).
- Within 500 m but outside radius: General locality tags only, no Location (Rule 2); region overrides may still apply (Rule 3).
- Point within radius but Location empty: Rule 1 applies; Location omitted; City/State/Country/CountryCode written if present; region overrides may apply.

**Examples:**
```powershell
# Single GeoJSON file
.\Set-GeoTag.ps1 -FilePath "C:\Photos" -GeoJson "C:\Data\locations.geojson" -Write

# Folder with multiple GeoJSON/JSON files (recursive merge)
.\Set-GeoTag.ps1 -FilePath "C:\Photos" -GeoJson "C:\Data\geo" -Write
```

**Dependencies:** Provide path via `-GeoJson` to a `.geojson`/`.json` file or a folder containing such files

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
