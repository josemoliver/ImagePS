<#
.SYNOPSIS
  Sync-PhotoMetadata.ps1 - Two-way safe synchronization of EXIF, XMP and IPTC metadata

.DESCRIPTION
  Reads metadata via ExifTool (JSON), compares canonical fields across EXIF/XMP/IPTC
  and optionally writes changes using ExifTool args file. Default is dry-run (report only).

.NOTES
  - Requires `exiftool` in PATH.
  - Does not re-encode images; writes metadata only via ExifTool.
  - Creates a JSON report describing proposed and applied changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Folder,

    [ValidateSet('merge','exif2xmp','xmp2exif')]
    [string]$Mode = 'merge',

    [ValidateSet('source','target','most-recent','report')]
    [string]$Prefer = 'source',

    [switch]$Write,
    [switch]$Backup,

    [string]$ReportPath = '',

    [int]$BatchSize = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ErrAndExit($msg){ Write-Error $msg; exit 1 }

# Validate ExifTool
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) { Write-ErrAndExit 'ExifTool not found in PATH.' }

# Resolve folder
try { $Folder = (Resolve-Path -LiteralPath $Folder).Path } catch { Write-ErrAndExit "Folder not found: $Folder" }

# Default report path
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ReportPath = Join-Path $Folder "sync-report-$ts.json"
}

Write-Host "Scanning: $Folder";

# Supported file extensions to scan
$exts = @('*.jpg','*.jpeg','*.jxl','*.png','*.tif','*.tiff','*.heic','*.heif','*.arw','*.cr2','*.cr3','*.nef','*.rw2','*.orf','*.raf','*.dng','*.webp')

$files = @()
foreach ($pat in $exts) { $files += Get-ChildItem -Path $Folder -Filter $pat -File -Recurse -ErrorAction SilentlyContinue }
$files = $files | Sort-Object -Property FullName -Unique

if (-not $files -or $files.Count -eq 0) { Write-Host 'No supported image files found.'; exit 0 }

# Canonical mapping: logical name -> source tags (EXIF/XMP/IPTC)
$mappings = @{
    DateTimeOriginal = @('DateTimeOriginal','XMP-exif:DateTimeOriginal','XMP-xmp:CreateDate')
    CreateDate = @('CreateDate','XMP-xmp:CreateDate')
    ModifyDate = @('ModifyDate','XMP-xmp:ModifyDate')
    OffsetTime = @('OffsetTime','OffsetTimeOriginal','OffsetTimeDigitized')
    ImageUniqueID = @('ImageUniqueID','XMP-photoshop:ImageID')
    Title = @('XMP-dc:Title','IPTC:Headline')
    Description = @('XMP-dc:Description','IPTC:Caption-Abstract')
    Keywords = @('IPTC:Keywords','XMP-dc:Subject','XMP-lr:hierarchicalSubject')
    Creator = @('mwg:creator','XMP-dc:Creator')
    Copyright = @('mwg:copyright','XMP-dc:Rights')
    GPSLatitude = @('GPSLatitude')
    GPSLongitude = @('GPSLongitude')
    GPSAltitude = @('GPSAltitude')
}

function Invoke-ExifToolRead($filelist){
    # Read all relevant tags in one exiftool call; use -j JSON output
    $tags = @()
    foreach ($vals in $mappings.Values) { foreach ($t in $vals) { $tags += "-$t" } }
    $tags = $tags | Select-Object -Unique

    # Create temporary file with file list
    $tmp = [System.IO.Path]::GetTempFileName()
    try { $filelist | ForEach-Object { $_ } | Out-File -FilePath $tmp -Encoding utf8 } catch { Remove-Item $tmp -ErrorAction SilentlyContinue; throw }

    # Build exiftool args
    $args = @('-j') + $tags + @('-@',$tmp)
    $out = & exiftool @args 2>&1
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $out) { return @() }
    try { return $out | ConvertFrom-Json } catch { Write-Warning 'Failed to parse exiftool JSON output'; return @() }
}

function Get-Prop($obj,$tag){
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$tag]
    if ($p) { return $p.Value } else { return $null }
}

function Normalize-Date($val){
    if (-not $val) { return $null }
    try {
        # exiftool DateTime may be 'YYYY:MM:DD HH:MM:SS'
        if ($val -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})') {
            return [datetime]::ParseExact($val,'yyyy:MM:dd HH:mm:ss',[System.Globalization.CultureInfo]::InvariantCulture)
        }
        return [datetime]::Parse($val)
    } catch { return $null }
}

function Normalize-Keywords($val){
    if (-not $val) { return @() }
    if ($val -is [System.Array]) { $arr = $val } else { $arr = ,$val }
    $clean = $arr | ForEach-Object { ($_ -as [string]).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    return $clean
}

function Normalize-Value($key,$val){
    switch ($key) {
        'DateTimeOriginal' { return Normalize-Date $val }
        'CreateDate' { return Normalize-Date $val }
        'ModifyDate' { return Normalize-Date $val }
        'OffsetTime' { return $val }
        'Keywords' { return Normalize-Keywords $val }
        default { return if ($val -is [System.Array]) { ($val | ForEach-Object { $_ }) } else { $val } }
    }
}

# Read metadata in batches to avoid very long command lines
$records = @()
$batch = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    [void]$batch.Add($f.FullName)
    if ($batch.Count -ge $BatchSize) {
        $records += Invoke-ExifToolRead $batch
        $batch.Clear()
    }
}
if ($batch.Count -gt 0) { $records += Invoke-ExifToolRead $batch }

# Build per-file canonical structure and diffs
$report = [System.Collections.Generic.List[object]]::new()

foreach ($rec in $records) {
    $srcFile = $rec.SourceFile
    $entry = [ordered]@{ File = $srcFile; Changes = @(); Summary = @{} }

    # For each canonical key, gather available values by group
    foreach ($canon in $mappings.Keys) {
        $vals = @{}
        foreach ($tag in $mappings[$canon]) {
            $v = Get-Prop $rec $tag
            if ($v -ne $null) { $vals[$tag] = $v }
        }

        # Normalize values for comparison
        $norm = $null
        if ($vals.Count -gt 0) {
            # Choose first found as 'extracted' representative
            $firstTag = $vals.Keys | Select-Object -First 1
            $raw = $vals[$firstTag]
            $norm = Normalize-Value $canon $raw
        }

        $entry.Summary[$canon] = @{ Raw = $vals; Normalized = $norm }
    }

    $report.Add($entry)
}

# Determine proposed actions per file
$changesTotal = 0
$proposed = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $report) {
    $file = $entry.File
    $perFileActions = @()

    foreach ($canon in $mappings.Keys) {
        $summary = $entry.Summary[$canon]
        $values = $summary.Raw
        $norm = $summary.Normalized

        # pick canonical source/target depending on mode
        # For merge: decide based on Prefer
        # For exif2xmp: source=EXIF, target=XMP; for xmp2exif inverse
        $exifTag = $mappings[$canon] | Where-Object { $_ -notlike 'XMP-*' -and $_ -notlike 'IPTC:*' } | Select-Object -First 1
        $xmpTag = $mappings[$canon] | Where-Object { $_ -like 'XMP-*' } | Select-Object -First 1
        $iptcTag = $mappings[$canon] | Where-Object { $_ -like 'IPTC:*' } | Select-Object -First 1

        $exifVal = if ($exifTag) { Get-Prop $((($records | Where-Object { $_.SourceFile -eq $file })[0])) $exifTag } else { $null }
        $xmpVal = if ($xmpTag) { Get-Prop $((($records | Where-Object { $_.SourceFile -eq $file })[0])) $xmpTag } else { $null }
        $iptcVal = if ($iptcTag) { Get-Prop $((($records | Where-Object { $_.SourceFile -eq $file })[0])) $iptcTag } else { $null }

        $exifNorm = Normalize-Value $canon $exifVal
        $xmpNorm = Normalize-Value $canon $xmpVal
        $iptcNorm = Normalize-Value $canon $iptcVal

        # Decide desired target values based on Mode and Prefer
        $action = $null
        switch ($Mode) {
            'exif2xmp' {
                # copy EXIF -> XMP/IPTC
                if ($exifNorm -and (-not $xmpNorm -or $xmpNorm -ne $exifNorm)) {
                    $action = @{ Canon = $canon; From = $exifTag; To = $xmpTag; Value = $exifNorm }
                }
            }
            'xmp2exif' {
                if ($xmpNorm -and (-not $exifNorm -or $exifNorm -ne $xmpNorm)) {
                    $action = @{ Canon = $canon; From = $xmpTag; To = $exifTag; Value = $xmpNorm }
                }
            }
            default {
                # merge: if one empty copy; if both non-empty and different resolve by Prefer
                if ($exifNorm -and -not $xmpNorm -and -not $iptcNorm) {
                    # copy exif to xmp (when present)
                    if ($xmpTag) { $action = @{ Canon = $canon; From = $exifTag; To = $xmpTag; Value = $exifNorm } }
                }
                elseif ($xmpNorm -and -not $exifNorm) {
                    if ($exifTag) { $action = @{ Canon = $canon; From = $xmpTag; To = $exifTag; Value = $xmpNorm } }
                }
                elseif (-not $exifNorm -and $iptcNorm) {
                    if ($exifTag) { $action = @{ Canon = $canon; From = $iptcTag; To = $exifTag; Value = $iptcNorm } }
                }
                elseif ($exifNorm -and $xmpNorm) {
                    if ($exifNorm -ne $xmpNorm) {
                        switch ($Prefer) {
                            'source' { $action = @{ Canon = $canon; From = $exifTag; To = $xmpTag; Value = $exifNorm } }
                            'target' { $action = @{ Canon = $canon; From = $xmpTag; To = $exifTag; Value = $xmpNorm } }
                            'most-recent' {
                                # choose based on DateTime fields if available
                                $d1 = if ($exifNorm -is [datetime]) { $exifNorm } else { $null }
                                $d2 = if ($xmpNorm -is [datetime]) { $xmpNorm } else { $null }
                                if ($d1 -and $d2) {
                                    if ($d1 -gt $d2) { $action = @{ Canon=$canon; From=$exifTag; To=$xmpTag; Value=$exifNorm } }
                                    else { $action = @{ Canon=$canon; From=$xmpTag; To=$exifTag; Value=$xmpNorm } }
                                }
                                else { $action = @{ Canon=$canon; From=$exifTag; To=$xmpTag; Value=$exifNorm } }
                            }
                            default { $action = $null }
                        }
                    }
                }
            }
        }

        if ($action) { $perFileActions += $action }
    }

    if ($perFileActions.Count -gt 0) {
        $proposed.Add([PSCustomObject]@{ File = $file; Actions = $perFileActions })
        $changesTotal += $perFileActions.Count
    }
}

Write-Host "Proposed changes: $changesTotal files/fields";

# Create JSON report of proposed changes
$reportObj = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Folder = $Folder
    Mode = $Mode
    Prefer = $Prefer
    Write = $Write.IsPresent
    ChangesCount = $changesTotal
    Changes = $proposed
}

[System.IO.File]::WriteAllText($ReportPath, ($reportObj | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
Write-Host "Report written to: $ReportPath"

if (-not $Write.IsPresent) { Write-Host 'Dry-run complete. No files modified.'; exit 0 }

# Build ExifTool args file for writes (UTF-8 no BOM)
$argsLines = New-Object System.Collections.Generic.List[string]
$argsLines.Add('-charset') ; $argsLines.Add('filename=utf8')
if ($Backup.IsPresent) { $argsLines.Add('-overwrite_original_in_place') } else { $argsLines.Add('-overwrite_original') }

# Construct per-file tag writes
foreach ($p in $proposed) {
    $file = $p.File
    foreach ($a in $p.Actions) {
        $canon = $a.Canon
        $to = $a.To
        $val = $a.Value
        if (-not $to) { continue }

        # For Keywords (arrays) write multiple -IPTC:Keywords=value lines
        if ($canon -eq 'Keywords') {
            $vals = if ($val -is [System.Array]) { $val } else { ,$val }
            foreach ($kw in $vals) { $argsLines.Add("-${to}=$kw") }
        }
        elseif ($val -is [datetime]) { $argsLines.Add("-`$to=$($val.ToString('yyyy:MM:dd HH:mm:ss'))") }
        else { $argsLines.Add("-`$to=$val") }
    }
    $argsLines.Add($file)
}

# Write args file and execute exiftool
$argsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "exif_args_{0}.txt" -f ([guid]::NewGuid().ToString()))
[System.IO.File]::WriteAllLines($argsFile, $argsLines, (New-Object System.Text.UTF8Encoding($false)))
try {
    Write-Host "Applying changes via ExifTool..."
    $res = & exiftool -@ $argsFile 2>&1
    $res | ForEach-Object { Write-Host "    $_" }
    Write-Host 'ExifTool run completed.'
}
finally { if (Test-Path $argsFile) { Remove-Item $argsFile -ErrorAction SilentlyContinue } }

Write-Host 'Sync complete.'
