<#
.SYNOPSIS
    Set-Lens.ps1 - Apply lens metadata rules in order to set the Microsoft Lens XMP Values using exiftool.

.DESCRIPTION
    Scans image files in Filepath (optionally recurse), reads Make/Model/LensID via exiftool JSON,
    matches against rules in LensRules.json (supports wildcards), and sets XMP-microsoft Lens tags.
    If -DryRun is specified, no changes are written; intended operations are printed instead.
    At the end, a summary report is displayed.

.PARAMETER Filepath
    The directory path containing image files to process.

.PARAMETER Recurse
    If specified, subfolders within Filepath will also be scanned.

.PARAMETER DryRun
    If specified, the script will not write to files but will output intended operations.

.EXAMPLE
    .\Set-Lens.ps1 -Filepath "D:\test\test1"
    .\Set-Lens.ps1 -Filepath "D:\test\test1" -Recurse
    .\Set-Lens.ps1 -Filepath "D:\test\test1" -DryRun
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Filepath,      # Directory containing images to process

    [switch]$Recurse,       # Process subdirectories recursively
    [switch]$DryRun         # Preview mode: show intended operations without writing
)

# ===== EXTERNAL DEPENDENCY VALIDATION =====
# Validate ExifTool is available in system PATH before processing
# ExifTool is required for reading metadata (JSON) and writing XMP-microsoft tags
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    Write-Error "ExifTool is not installed or not in PATH."
    exit 1
}

# ===== LOAD LENS MAPPING RULES =====
# Load rules from LensRules.json (must be in same directory as script)
# Rules file format: JSON array of objects with Make, Model, LensId (source patterns)
#                    and LensModel, LensManufacturer (target values to write)
# Patterns support wildcards (*) for flexible matching
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rulesFile = Join-Path $scriptDir "LensRules.json"

# Validate rules file exists before attempting to load
if (-not (Test-Path $rulesFile)) {
    Write-Error "LensRules.json not found in $scriptDir"
    exit 1
}

# Parse JSON rules file with error handling
# ConvertFrom-Json converts JSON array to PowerShell object array
try {
    $rules = Get-Content $rulesFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse LensRules.json: $_"
    exit 1
}

# Ensure at least one rule exists before processing files
if (-not $rules -or $rules.Count -eq 0) {
    Write-Error "No rules found in LensRules.json."
    exit 1
}

# ===== FILE DISCOVERY =====
# Validate target directory exists before scanning
if (-not (Test-Path $Filepath)) {
    Write-Error "Filepath not found: $Filepath"
    exit 1
}

# Regex pattern for supported image extensions (case-insensitive)
# Covers 17 formats: common photos (JPG, JXL, PNG, HEIC, HEIF, WEBP, TIFF)
#                    and RAW formats (ARW, CR2/CR3, NEF, RW2, ORF, RAF, DNG)
# Uses regex alternation with anchors (^\.) to match extension start
# JPEG: jpe?g matches both .jpg and .jpeg
# TIFF: tiff? matches both .tif and .tiff
$extensions = '^\.jpe?g$|^\.jxl$|^\.png$|^\.tiff?$|^\.heic$|^\.heif$|^\.arw$|^\.cr2$|^\.cr3$|^\.nef$|^\.rw2$|^\.orf$|^\.raf$|^\.dng$|^\.webp$'

# Gather all matching image files
# -File: Only files, not directories
# -Recurse:$Recurse: Conditional recursion based on switch parameter
# Where-Object: Filter by extension using regex match (case-insensitive by default)
$files = Get-ChildItem -Path $Filepath -File -Recurse:$Recurse |
    Where-Object { $_.Extension -match $extensions }

# Exit gracefully if no matching files found
if ($files.Count -eq 0) {
    Write-Host "No image files found in: $Filepath"
    if (-not $Recurse) { Write-Host "Tip: try -Recurse if images are in subfolders." }
    exit 0
}

# ===== SUMMARY COUNTERS =====
# Track processing statistics for final report
$processed = 0  # Total files examined
$matched   = 0  # Files matching a rule
$skipped   = 0  # Files with no matching rule or parse errors
$updated   = 0  # Files actually modified (DryRun mode sets this to 0)

# ===== MAIN PROCESSING LOOP =====
# Process each file individually to allow per-file rule matching
# Cannot batch because each file may have different Make/Model/LensID requiring different rules
foreach ($file in $files) {
    $processed++
    Write-Host "Processing $($file.FullName)..."

    # ===== METADATA EXTRACTION =====
    # Extract camera and lens identification fields using ExifTool JSON output
    # -j: JSON output format (easier to parse than text)
    # -Make -Model -LensID: Only extract fields needed for rule matching
    $json = & exiftool -j -Make -Model -LensID $file.FullName
    if (-not $json) {
        Write-Host "  No metadata returned by exiftool. Skipping."
        $skipped++
        continue
    }

    # Parse JSON output with error handling
    # ExifTool returns array of objects (one per file), we process one file at a time
    try {
        $data = $json | ConvertFrom-Json
    } catch {
        Write-Host "  Failed to parse exiftool JSON. Skipping."
        $skipped++
        continue
    }

    # Extract metadata fields from first (and only) record
    # Use null-coalescing operator (??) to default to empty string if field missing
    # ToString() ensures consistent string type for comparison (some fields may be objects)
    $rec = $data[0]
    $make   = ($rec.Make   ?? "").ToString()  # Camera manufacturer (e.g., "Canon", "Nikon")
    $model  = ($rec.Model  ?? "").ToString()  # Camera model (e.g., "Canon EOS 5D Mark IV")
    $lensId = ($rec.LensID ?? "").ToString()  # Lens identifier from EXIF (e.g., "EF24-105mm f/4L IS USM")

    # ===== RULE MATCHING =====
    # Find first rule that matches current file's Make/Model/LensID
    # Rules are evaluated in order from LensRules.json (first match wins)
    # Missing or empty fields in rules are treated as wildcards (match anything)
    # Uses PowerShell's -like operator for wildcard pattern matching (supports * and ?)
    $matchedRule = ($rules | Where-Object {
        # Extract rule patterns, defaulting to wildcard "*" if field missing/empty
        # This allows rules to match "any make" or "any model" by omitting the field
        $rMake   = $_.Make   ; if (-not $rMake)   { $rMake   = "*" }
        $rModel  = $_.Model  ; if (-not $rModel)  { $rModel  = "*" }
        $rLensId = $_.LensId ; if (-not $rLensId) { $rLensId = "*" }

        # Match logic: ALL three conditions must be true
        # Each condition: wildcard "*" matches anything, otherwise use -like for pattern match
        # -like is case-insensitive by default and supports wildcards:
        #   * = zero or more characters (e.g., "Canon*" matches "Canon EOS 5D")
        #   ? = exactly one character (e.g., "EF?00mm" matches "EF100mm" or "EF200mm")
        ($rMake   -eq "*" -or $make  -like $rMake)   -and
        ($rModel  -eq "*" -or $model -like $rModel)  -and
        ($rLensId -eq "*" -or $lensId -like $rLensId)
    }) | Select-Object -First 1  # Take first match only (rule order matters)

    # ===== PROCESS MATCHED RULE =====
    if ($null -ne $matchedRule) {
        $matched++
        
        # Extract target lens metadata values from matched rule
        # These are the standardized values to write to XMP-microsoft namespace
        $lensModel        = $matchedRule.LensModel        # Target lens model string (e.g., "24-105mm F4.0")
        $lensManufacturer = $matchedRule.LensManufacturer # Target manufacturer string (e.g., "Canon")

        # Display match details for user visibility
        Write-Host ("  Rule matched: Make='{0}' Model='{1}' LensID='{2}'" -f $make, $model, $lensId)
        Write-Host ("  Intended LensModel='{0}', LensManufacturer='{1}'" -f $lensModel, $lensManufacturer)

        # ===== WRITE METADATA OR PREVIEW =====
        if ($DryRun) {
            # DryRun mode: Display command that would be executed without actually running it
            # Useful for verifying rule matches before committing changes
            Write-Host "  DryRun: Would run -> exiftool -overwrite_original -XMP-microsoft:LensModel='$lensModel' -XMP-microsoft:LensManufacturer='$lensManufacturer' '$($file.FullName)'"
        }
        else {
            # Execute ExifTool to write XMP-microsoft lens metadata
            # -overwrite_original: Modify file in-place (no _original backup)
            # XMP-microsoft namespace: Used by Windows Photos and other Microsoft applications
            # Out-Null: Suppress ExifTool's verbose output (we already displayed intent above)
            & exiftool -overwrite_original `
                "-XMP-microsoft:LensModel=$lensModel" `
                "-XMP-microsoft:LensManufacturer=$lensManufacturer" `
                $file.FullName | Out-Null
            $updated++
        }
    }
    else {
        # No rule matched this file's Make/Model/LensID combination
        # This is normal for camera/lens combinations not defined in LensRules.json
        Write-Host "  No matching rule. Skipping."
        $skipped++
    }
}

# ===== SUMMARY REPORT =====
# Display final processing statistics
# Helps users understand how many files were processed, matched, and updated
Write-Host ""
Write-Host "===== Summary Report ====="
Write-Host "Total files processed : $processed"  # All image files examined
Write-Host "Matched rules         : $matched"    # Files that matched at least one rule
Write-Host "Skipped (no match)    : $skipped"    # Files with no matching rule or errors

# Display update count based on mode
# DryRun mode: No files modified (preview only)
# Normal mode: Show actual number of files that had metadata written
if ($DryRun) {
    Write-Host "DryRun mode: No files updated."
} else {
    Write-Host "Files updated         : $updated"
}
Write-Host "=========================="
