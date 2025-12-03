
# ImagePS

PowerShell scripts for automating photo metadata operations using ExifTool.

## Overview

ImagePS is a collection of PowerShell utilities designed to batch process image metadata (EXIF, IPTC, XMP tags) across large photo collections. Each script targets a specific metadata operation and is designed to work seamlessly with ExifTool.

## Features

- **Creator & Copyright Management** - Batch set creator and copyright information
- **Unique ID Assignment** - Assign random GUIDs to image files automatically
- **Timezone Offset Correction** - Update datetime and timezone metadata across images

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

## Usage

1. **Navigate to script directory:**
	```powershell
	cd D:\Path\To\ImagePS\scripts
	```

2. **Run desired script:**
	```powershell
	pwsh -File Set-Rights.ps1 -Name "Your Name" -FilePath "C:\Photos" -Recurse
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

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "ExifTool not found" | Install ExifTool and add to system PATH, then restart PowerShell |
| "The specified path does not exist" | Verify the `-FilePath` or `-Path` parameter points to an existing directory |
| "Invalid Timezone format" | Use format `±HH:MM` (e.g., `+02:00` or `-05:00`) |
| No files processed | Check image file extensions match script filters (JPG, PNG, etc.) |
| Changes not saved | Ensure ExifTool has write permissions to image directory |

## Development

For AI coding agents working with this codebase, see [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture details, design patterns, and conventions.

## License

See LICENSE file for details.
