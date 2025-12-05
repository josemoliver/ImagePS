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
    [string]$Filepath,

    [switch]$Recurse,
    [switch]$DryRun
)

# Ensure exiftool is available
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    Write-Error "ExifTool is not installed or not in PATH."
    exit 1
}

# Load rules from LensRules.json (same directory as script)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rulesFile = Join-Path $scriptDir "LensRules.json"

if (-not (Test-Path $rulesFile)) {
    Write-Error "LensRules.json not found in $scriptDir"
    exit 1
}

try {
    $rules = Get-Content $rulesFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse LensRules.json: $_"
    exit 1
}

if (-not $rules -or $rules.Count -eq 0) {
    Write-Error "No rules found in LensRules.json."
    exit 1
}

# Gather files
if (-not (Test-Path $Filepath)) {
    Write-Error "Filepath not found: $Filepath"
    exit 1
}


$extensions = '^\.jpe?g$|^\.jxl$|^\.png$|^\.tiff?$|^\.heic$|^\.heif$|^\.arw$|^\.cr2$|^\.cr3$|^\.nef$|^\.rw2$|^\.orf$|^\.raf$|^\.dng$|^\.webp$'

$files = Get-ChildItem -Path $Filepath -File -Recurse:$Recurse |
    Where-Object { $_.Extension -match $extensions }

if ($files.Count -eq 0) {
    Write-Host "No image files found in: $Filepath"
    if (-not $Recurse) { Write-Host "Tip: try -Recurse if images are in subfolders." }
    exit 0
}

# Summary counters
$processed = 0
$matched   = 0
$skipped   = 0
$updated   = 0

foreach ($file in $files) {
    $processed++
    Write-Host "Processing $($file.FullName)..."

    $json = & exiftool -j -Make -Model -LensID $file.FullName
    if (-not $json) {
        Write-Host "  No metadata returned by exiftool. Skipping."
        $skipped++
        continue
    }

    try {
        $data = $json | ConvertFrom-Json
    } catch {
        Write-Host "  Failed to parse exiftool JSON. Skipping."
        $skipped++
        continue
    }

    $rec = $data[0]
    $make   = ($rec.Make   ?? "").ToString()
    $model  = ($rec.Model  ?? "").ToString()
    $lensId = ($rec.LensID ?? "").ToString()

    $matchedRule = ($rules | Where-Object {
        $rMake   = $_.Make   ; if (-not $rMake)   { $rMake   = "*" }
        $rModel  = $_.Model  ; if (-not $rModel)  { $rModel  = "*" }
        $rLensId = $_.LensId ; if (-not $rLensId) { $rLensId = "*" }

        ($rMake   -eq "*" -or $make  -like $rMake)   -and
        ($rModel  -eq "*" -or $model -like $rModel)  -and
        ($rLensId -eq "*" -or $lensId -like $rLensId)
    }) | Select-Object -First 1

    if ($null -ne $matchedRule) {
        $matched++
        $lensModel        = $matchedRule.LensModel
        $lensManufacturer = $matchedRule.LensManufacturer

        Write-Host ("  Rule matched: Make='{0}' Model='{1}' LensID='{2}'" -f $make, $model, $lensId)
        Write-Host ("  Intended LensModel='{0}', LensManufacturer='{1}'" -f $lensModel, $lensManufacturer)

        if ($DryRun) {
            Write-Host "  DryRun: Would run -> exiftool -overwrite_original -XMP-microsoft:LensModel='$lensModel' -XMP-microsoft:LensManufacturer='$lensManufacturer' '$($file.FullName)'"
        }
        else {
            & exiftool -overwrite_original `
                "-XMP-microsoft:LensModel=$lensModel" `
                "-XMP-microsoft:LensManufacturer=$lensManufacturer" `
                $file.FullName | Out-Null
            $updated++
        }
    }
    else {
        Write-Host "  No matching rule. Skipping."
        $skipped++
    }
}

Write-Host ""
Write-Host "===== Summary Report ====="
Write-Host "Total files processed : $processed"
Write-Host "Matched rules         : $matched"
Write-Host "Skipped (no match)    : $skipped"
if ($DryRun) {
    Write-Host "DryRun mode: No files updated."
} else {
    Write-Host "Files updated         : $updated"
}
Write-Host "=========================="
