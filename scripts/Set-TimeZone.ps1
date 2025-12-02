param(
    [Parameter(Mandatory=$true)]
    [string]$Timezone,

    [Parameter(Mandatory=$true)]
    [string]$Filepath
)

# Regex pattern for timezone offset format (+/-HH:MM)
$tzPattern = '^[\+\-](0[0-9]|1[0-4]):[0-5][0-9]$'

# Resolve and validate Filepath
try {
    $Filepath = (Resolve-Path $Filepath).Path
} catch {
    Write-Error "The specified Filepath '$Filepath' does not exist."
    exit 1
}

# Validate exiftool availability in PATH
$exiftoolPath = Get-Command exiftool -ErrorAction SilentlyContinue
if (-not $exiftoolPath) {
    Write-Error "ExifTool is not available in the system PATH. Please install or add it to PATH."
    exit 1
}

# If Timezone is blank (user pressed Enter), use local system timezone offset
if ([string]::IsNullOrWhiteSpace($Timezone)) {
    $localOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::UtcNow)
    $sign = if ($localOffset.Hours -lt 0 -or $localOffset.Minutes -lt 0) { "-" } else { "+" }
    $Timezone = "{0}{1:00}:{2:00}" -f $sign, [math]::Abs($localOffset.Hours), [math]::Abs($localOffset.Minutes)
}

# Validate Timezone format
if ($Timezone -notmatch $tzPattern) {
    Write-Error "Invalid Timezone format. Please use format +/-HH:MM (e.g., -04:00)."
    exit 1
}

# Build target file pattern
$targetFiles = Join-Path -Path $Filepath -ChildPath "*.jpg"

# Build exiftool command
$exifCommand = @(
    "exiftool",
    $targetFiles,
    ('"-OffsetTime*=' + $Timezone + '"'),
    ('"-XMP-photoshop:DateCreated<${XMP-photoshop:DateCreated}s' + $Timezone + '"'),
    ('"-XMP-xmp:CreateDate<${XMP-xmp:CreateDate}s' + $Timezone + '"'),
    ('"-XMP-exif:DateTimeOriginal<${XMP-exif:DateTimeOriginal}s' + $Timezone+ '"'),
    "-overwrite_original"
) -join " "

Write-Output "Running command: $exifCommand"
Invoke-Expression $exifCommand
