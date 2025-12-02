## Repo Overview

This repository contains PowerShell scripts for managing photo metadata (EXIF/XMP) using ExifTool as the external engine. Primary scripts live in the `scripts/` directory and are intended to be run from Windows PowerShell/PowerShell Core.

Key files:
- `README.md` — one-line project description.
- `scripts/Set-CreatorAndCopyright.ps1` — writes creator/copyright metadata; uses a temporary ExifTool args file (UTF-8 without BOM).
- `scripts/Set-ImageUniqueID.ps1` — enumerates image files, creates dashless GUIDs, uses `exiftool -overwrite_original` and checks `$LASTEXITCODE`.
- `scripts/Set-TimeZone.ps1` — sets timezone offsets on images via ExifTool (note: script contains non-obvious variable usage; inspect carefully before edits).

**Big picture / data flow**
- User runs a PowerShell script which finds files under a given path (Get-ChildItem).
- The script constructs ExifTool command-line usage (sometimes via a temp args file) and invokes the `exiftool` binary to read/write metadata.
- Output and error handling are done with `Write-Host`, `Write-Error`, and checks against `$LASTEXITCODE`.

**Why this shape?**
- ExifTool is the authoritative CLI tool for metadata; scripts are thin wrappers providing discovery, batching, and safe argument generation.

Guardrails & project-specific conventions for AI editing or generating code
- Scripts assume `exiftool` is available on `PATH`. Always preserve or re-check the `Get-Command exiftool` validation before changing invocation sites.
- Filenames use `PascalCase` and each script exposes parameters through a `param()` block — preserve parameter names and types when adding features.
- For cross-platform safety, scripts use `Get-ChildItem` and `-File` + extension filtering; follow that pattern rather than custom globbing.
- When writing args files for ExifTool, the repo uses UTF-8 without BOM. Use .NET UTF8Encoding($false) when writing such files.
- Prefer `-overwrite_original` for in-place updates (this repo relies on that behavior); keep or explicitly document when creating backups.

Examples and idioms (copyable patterns)
- Check for ExifTool availability:
  ```powershell
  if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
      Write-Error "ExifTool not found. Ensure it is installed and in your PATH."
      exit 1
  }
  ```
- Discover image files (extensions list is used in code):
  ```powershell
  $extensions = @('.jpg','.jpeg','.png','.tif','.tiff','.heic','.heif')
  $files = Get-ChildItem -Path $FilePath -File -Recurse:$Recurse | Where-Object { $extensions -contains $_.Extension.ToLower() }
  ```
- Invoke ExifTool with an args file (safe for UTF-8/complex fields): create a text file with one arg per line and call `exiftool -@ args.txt -- <filename>`.

Known patterns to watch for (useful for AI agents)
- Error handling: some scripts set `$ErrorActionPreference = 'Stop'` and wrap logic in `try/catch`. Keep that approach when adding new bulk operations.
- Progress UI: `Set-ImageUniqueID.ps1` uses `Write-Progress` for long runs — maintain UX parity when adding longer operations.
- Shell safety: use `--` after args file and before filenames when calling ExifTool to avoid problems with filenames that begin with `-`.
- Temporary files: scripts write and clean up temporary files in `%TEMP%`. Ensure `finally` blocks remove temp files.

Subtle issues discovered
- `Set-TimeZone.ps1` constructs ExifTool command elements referencing `$sTimezone` (for example: `DateCreated$sTimezone`). This variable doesn't appear defined in the script; review or test augmented changes running on a small sample before bulk runs.

Developer workflows and run commands
- Install ExifTool and ensure it is in `PATH`.
- Example invocation from PowerShell (run in repository root or anywhere):
  ```pwsh
  pwsh -File .\scripts\Set-ImageUniqueID.ps1 -Path 'C:\Photos' -Recurse
  pwsh -File .\scripts\Set-CreatorAndCopyright.ps1 -Name 'Jane Doe' -FilePath 'C:\Photos' -Year 2025 -Recurse
  pwsh -File .\scripts\Set-TimeZone.ps1 -Timezone '+01:00' -Filepath 'C:\Photos'
  ```

Testing & safety
- There are no automated tests in this repo. Validate changes manually on a small sample folder first.
- For dangerous operations (bulk metadata writes) prefer making a copy of a few files or use ExifTool's default backup behavior by omitting `-overwrite_original` when testing.

What to do when uncertain
- If a script references a variable that isn't defined (e.g., `$sTimezone`), do not guess—open an issue or run the script in a sandbox to observe the failure and fix with a small, well-tested change.

Files to inspect when working on features
- `scripts/Set-CreatorAndCopyright.ps1` — shows args-file usage and UTF-8-without-BOM pattern.
- `scripts/Set-ImageUniqueID.ps1` — shows batch enumeration, `$LASTEXITCODE` validation and progress reporting.
- `scripts/Set-TimeZone.ps1` — timezone handling, timezone format regex, and potential variable typo to double-check.

If any part of this summary is unclear or you want more examples (e.g., a templated test harness or a safe dry-run mode), tell me which areas to expand and I will update this file.
