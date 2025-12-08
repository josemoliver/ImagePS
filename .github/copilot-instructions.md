# ImagePS Copilot Instructions

## Project Overview
ImagePS is a PowerShell utility collection for automating photo metadata operations using **ExifTool**. Scripts are in `scripts/` and manipulate EXIF, IPTC, and XMP metadata across image batches.

## Architecture & Components

### Core Scripts
- **`Set-Rights.ps1`**: Sets MWG creator/copyright tags via ExifTool args file (UTF-8 without BOM)
- **`Set-ImageUniqueID.ps1`**: Assigns random GUIDs (dashless format) to ImageUniqueID tag, skipping existing
- **`Set-TimeZone.ps1`**: Updates timezone offset metadata across XMP and EXIF datetime fields
- **`Sync-PhotoTime.ps1`**: Synchronizes photo timestamps using reference image and correct time (PowerShell 7+)
- **`Set-GeoTag.ps1`**: Assigns GPS coordinates to images based on external CSV file lookup
- **`Set-Lens.ps1`**: Injects lens metadata into images, supporting multiple lens formats
- **`Set-WeatherTags.ps1`**: Tags images with weather data from CSV file using batch operations

### Key Design Patterns

#### 1. **ExifTool Command Building**
All scripts invoke ExifTool as external process. Key patterns:
- Use `-overwrite_original` flag for in-place edits
- Charset declarations for UTF-8 support: `-charset filename=utf8`, `-charset exif=utf8`, etc.
- Args file approach (`.txt` file with arguments) for complex metadata sets - see `Set-Rights.ps1`
- **Batch operations**: Collect all files and metadata, write once via args file (reduces N ExifTool processes to 1)
  - Example: `Set-WeatherTags.ps1` collects hashtable of files→readings, writes all in single batch
  - Performance: 125 images = 1 ExifTool call instead of 125 separate calls
- Tag format: `OffsetTime*`, `XMP-photoshop:DateCreated`, `XMP-xmp:CreateDate`, `ImageUniqueID`, `mwg:creator`

#### 2. **File Discovery & Filtering**
Scripts build file lists with `Get-ChildItem`:
```powershell
$extensions = @(".jpg",".jpeg",".png",".tif",".tiff",".heic",".heif")
$files = Get-ChildItem -Path $FilePath -File -Recurse:$Recurse | Where-Object { $extensions -contains $_.Extension.ToLower() }
```

Use `-Recurse` switch consistently for batch operations.

#### 3. **Error Handling & Validation**
- Validate external tool availability: `Get-Command exiftool -ErrorAction SilentlyContinue`
- Validate input paths: `Test-Path` and `Resolve-Path` with error handling
- Input validation (format/regex): `$Timezone -notmatch $tzPattern` pattern in `Set-TimeZone.ps1`
- Wrap ExifTool calls in error detection: check `$LASTEXITCODE -ne 0`

#### 4. **Output & Progress**
- Use `Write-Host` for user feedback
- Use `Write-Progress` for long operations (see `Set-ImageUniqueID.ps1`)
- Visual indicators: `→` for actions, `✓` for skipped
- Summary messages at end of execution

## Critical Developer Workflows

### Testing Scripts Locally
1. Ensure ExifTool is installed and in PATH: `exiftool -ver`
2. Run script with test images: `pwsh -File scripts/Set-TimeZone.ps1 -Timezone "+02:00" -Filepath $testDir`
3. Verify metadata changes: `exiftool -a $imagefile` to inspect all tags

### Adding New Metadata Operations
- Follow parameter pattern: `[Parameter(Mandatory=$true)]` declarations at top
- Add external tool validation before file processing
- Use consistent file discovery code (see extension filter pattern above)
- Test with small image set before scaling

## Project-Specific Conventions

### Parameter Naming
- `-FilePath` or `-Path`: Directory containing images (some scripts support single file path)
- `-Timezone`: ISO 8601 offset format `+/-HH:MM`
- `-Recurse`: Switch for nested directories
- `-Write`: Switch to enable writing (preview mode without this)
- `-Name`: Creator/author name
- `-Extensions`: Array of file extensions (without dots initially, scripts handle normalization)
- `-GeoData`: Path to external CSV file for geotagging
- `-LensData`: Lens information string or file path
- `-BaseFile`: Reference image for time synchronization
- `-CorrectDate`/`-CorrectTime`: Known correct timestamp for reference image (yyyy-MM-dd, HH:mm:ss)
- `-Threshold`: Time difference threshold in minutes (e.g., weather matching)

### Metadata Tag Conventions
- **MWG tags**: `mwg:creator`, `mwg:copyright` (unified standard)
- **XMP paths**: Full namespace paths like `XMP-photoshop:DateCreated`
- **EXIF**: `ImageUniqueID`, `OffsetTime*` (wildcard for variants), `DateTimeOriginal`, `CreateDate`, `ModifyDate`
- **GPS tags**: `GPSLatitude`, `GPSLongitude`, `GPSLatitudeRef`, `GPSLongitudeRef`
- **Weather tags**: `AmbientTemperature`, `Humidity`, `Pressure` (EXIF composite tags)
- **Conditional XMP/IPTC writes**: Check field existence with `exiftool -s -s -s -"FieldName"` before updating
  - Avoids creating unnecessary fields in files that don't have them
  - Used in `Sync-PhotoTime.ps1` and `Set-TimeZone.ps1` for XMP-exif, XMP-tiff, IPTC fields

### UTF-8 Handling
Create args files as UTF-8 without BOM:
```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)
```
Prevents encoding issues with international character sets in metadata.

## Integration Points & External Dependencies

### ExifTool
- **Requirement**: Must be in system PATH
- **Not bundled**: Users install separately (Windows package managers, GitHub releases)
- **Output handling**: Redirect stderr to capture warnings/errors via `2>&1` and `2>$null`
- **Command escaping**: Use literal `--` before filenames to prevent interpretation of `-` prefixed filenames

### Image Format Support
- **Supported**: JPG, JPEG, JXL, PNG, TIF, TIFF, HEIC, HEIF, ARW, CR2, CR3, NEF, RW2, ORF, RAF, DNG, WEBP (17 formats)
  - Common photos: JPG, JPEG, JXL, PNG, HEIC, HEIF, WEBP
  - RAW formats: ARW (Sony), CR2/CR3 (Canon), NEF (Nikon), RW2 (Panasonic), ORF (Olympus), RAF (Fujifilm), DNG (Adobe)
- **Metadata preservation**: ExifTool preserves all metadata by default with `-overwrite_original`

### External Data Files
- **Geotagging**: CSV file with latitude/longitude data, header row optional
- **Lens data**: Can be embedded string or external file, format consistent with lens metadata standards
- **Weather data**: CSV file with format `Date,Time,Temperature,Humidity,Pressure` (e.g., `11/17/2025,12:04 AM,25.2 °C,87 %,"1,013.24 hPa"`)
  - Auto-detects and skips header row if present
  - Handles comma thousands separators in quoted fields
  - Validates ranges: Temperature -100 to 150°C, Humidity 0-100%, Pressure 800-1100 hPa

## Common Gotchas

1. **ExifTool not found**: Script exits with `exit 1` - check PATH before running
2. **Timezone format validation**: Must match `^[\+\-](0[0-9]|1[0-4]):[0-5][0-9]$` - covers UTC-14 to UTC+14
3. **UTF-8 BOM issues**: Windows PowerShell defaults to UTF-16 LE; use `UTF8Encoding($false)` explicitly
4. **Blank timezone input**: `Set-TimeZone.ps1` falls back to local system timezone if `-Timezone` is empty string
5. **File globbing**: Use `Join-Path` to build patterns (e.g., `*.jpg`) to avoid issues on non-Windows systems
6. **Dry-run mode**: Use `-DryRun` or omit `-Write` switch to preview changes without writing to files
7. **PowerShell automatic variables**: NEVER use `$Input` as parameter name - conflicts with PowerShell's automatic pipeline variable
   - Symptom: Parameter appears empty even when explicitly bound
   - Solution: Use `$Value`, `$InputValue`, `$Data`, etc. instead
   - Bug found in `Set-WeatherTags.ps1` where `$Input` caused all weather values to parse as null
8. **CSV comma separators**: Weather CSV pressure values like `"1,013.24 hPa"` must be quoted or regex will fail
   - Solution: `Remove-NonNumeric` strips commas along with units, leaving `1013.24`
9. **PowerShell 7+ requirements**: `Sync-PhotoTime.ps1` requires PS7+ for enhanced datetime handling
   - Check version: `$PSVersionTable.PSVersion.Major -ge 7`

## When Enhancing Scripts

- Preserve parameter validation order (path validation → tool validation → input validation)
- Add progress indication for loops processing >20 files
- Clean up temporary files in `finally` blocks (see args file cleanup in `Set-Rights.ps1` and `Set-WeatherTags.ps1`)
- Document mandatory parameters and expected formats in comment headers
- Consider adding `-WhatIf` or `-DryRun` parameters for non-destructive testing of new features
- **Performance optimization**: Use batch operations for bulk writes (collect hashtable of files→metadata, single ExifTool call)
  - Pattern: Build args file with all operations, use `exiftool -@ argsfile`
  - Reduces process overhead from O(N) to O(1)
- **Conditional field updates**: Check field existence before updating to avoid creating unnecessary metadata
  - Use `exiftool -s -s -s -"FieldName" "$file" 2>$null` per field (avoids JSON name conflicts)
  - Validate with `[string]::IsNullOrWhiteSpace($check)` - empty means field doesn't exist
- **Detailed comments**: Add inline comments explaining:
  - Why certain approaches were chosen (e.g., UTF-8 without BOM, batch operations)
  - How algorithms work (e.g., nearest-neighbor matching, time delta calculation)
  - What ranges and formats are expected (e.g., temperature ranges, date formats)
  - Edge cases handled (e.g., missing values, header detection, nullable fields)
