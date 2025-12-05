# ImagePS Copilot Instructions

## Project Overview
ImagePS is a PowerShell utility collection for automating photo metadata operations using **ExifTool**. Scripts are in `scripts/` and manipulate EXIF, IPTC, and XMP metadata across image batches.

## Architecture & Components

### Core Scripts
- **`Set-Rights.ps1`**: Sets MWG creator/copyright tags via ExifTool args file (UTF-8 without BOM)
- **`Set-ImageUniqueID.ps1`**: Assigns random GUIDs (dashless format) to ImageUniqueID tag, skipping existing
- **`Set-TimeZone.ps1`**: Updates timezone offset metadata across XMP and EXIF datetime fields
- **`Set-GeoTag.ps1`**: Assigns GPS coordinates to images based on external CSV file lookup
- **`Set-Lens.ps1`**: Injects lens metadata into images, supporting multiple lens formats
- **`Set-WeatherTags.ps1`**: Tags images with weather conditions from external API lookup

### Key Design Patterns

#### 1. **ExifTool Command Building**
All scripts invoke ExifTool as external process. Key patterns:
- Use `-overwrite_original` flag for in-place edits
- Charset declarations for UTF-8 support: `-charset filename=utf8`, `-charset exif=utf8`, etc.
- Args file approach (`.txt` file with arguments) for complex metadata sets - see `Set-Rights.ps1`
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
- `-FilePath` or `-Path`: Directory containing images
- `-Timezone`: ISO 8601 offset format `+/-HH:MM`
- `-Recurse`: Switch for nested directories
- `-Name`: Creator/author name
- `-Extensions`: Array of file extensions (without dots initially, scripts handle normalization)
- `-GeoData`: Path to external CSV file for geotagging
- `-LensData`: Lens information string or file path
- `-WeatherAPI`: Weather data source API URL

### Metadata Tag Conventions
- **MWG tags**: `mwg:creator`, `mwg:copyright` (unified standard)
- **XMP paths**: Full namespace paths like `XMP-photoshop:DateCreated`
- **EXIF**: `ImageUniqueID`, `OffsetTime*` (wildcard for variants)
- **GPS tags**: `GPSLatitude`, `GPSLongitude`, `GPSLatitudeRef`, `GPSLongitudeRef`
- **Weather tags**: Custom tags as defined by external API response

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
- **Supported**: JPG, JPEG, PNG, TIF, TIFF, HEIC, HEIF
- **Metadata preservation**: ExifTool preserves all metadata by default with `-overwrite_original`

### External Data Files
- **Geotagging**: CSV file with latitude/longitude data, header row optional
- **Lens data**: Can be embedded string or external file, format consistent with lens metadata standards
- **Weather data**: Fetched from API, requires internet access and valid API URL

## Common Gotchas

1. **ExifTool not found**: Script exits with `exit 1` - check PATH before running
2. **Timezone format validation**: Must match `^[\+\-](0[0-9]|1[0-4]):[0-5][0-9]$` - covers UTC-14 to UTC+14
3. **UTF-8 BOM issues**: Windows PowerShell defaults to UTF-16 LE; use `UTF8Encoding($false)` explicitly
4. **Blank timezone input**: `Set-TimeZone.ps1` falls back to local system timezone if `-Timezone` is empty string
5. **File globbing**: Use `Join-Path` to build patterns (e.g., `*.jpg`) to avoid issues on non-Windows systems
6. **Dry-run mode**: Use `-DryRun` switch to preview changes without writing to files

## When Enhancing Scripts

- Preserve parameter validation order (path validation → tool validation → input validation)
- Add progress indication for loops processing >20 files
- Clean up temporary files in `finally` blocks (see args file cleanup in `Set-Rights.ps1`)
- Document mandatory parameters and expected formats in comment headers
- Consider adding `-WhatIf` or `-DryRun` parameters for non-destructive testing of new features
