function Get-ChangedFileList {
    param (
        [parameter(Mandatory)]
        [string]$TargetBranch,

        [parameter(Mandatory)]
        [string]$SourceBranch,

        [string[]]$FileExtensions = @('.cs', '.ts', '.tsx', '.js', '.jsx', '.dart', '.json', '.yaml', '.yml'),
        [string[]]$FileExtensionExcludes = @('.designer.cs')
    )

    Write-Host "`n[Get-ChangedFileList] Discovering changed files..." -ForegroundColor Cyan
    Write-Host "[Get-ChangedFileList] Source: $SourceBranch | Target: $TargetBranch" -ForegroundColor Cyan
    Write-Host "[Get-ChangedFileList] Allowed extensions: $($FileExtensions -join ', ')" -ForegroundColor Cyan
    Write-Host "[Get-ChangedFileList] Excluded patterns: $($FileExtensionExcludes -join ', ')" -ForegroundColor Cyan

    $renamedSourceBranch = $SourceBranch -replace 'refs/heads/', 'origin/'
    $renamedTargetBranch = $TargetBranch -replace 'refs/heads/', 'origin/'

    $changedFiles = git diff --name-only --diff-filter=AM "$renamedTargetBranch...$renamedSourceBranch"
    Write-Host "[Get-ChangedFileList] Raw files from git diff: $(@($changedFiles).Count)"

    $changedFiles = $changedFiles | Where-Object {
        $file = $_
        $included = $FileExtensions | Where-Object { $file.EndsWith($_) }
        $excluded = $FileExtensionExcludes | Where-Object { $file.EndsWith($_) }
        $included -and -not $excluded
    }

    Write-Host "[Get-ChangedFileList] Files after filtering: $($changedFiles.Count)" -ForegroundColor Green
    foreach ($f in $changedFiles) { Write-Host "  - $f" }
    return @($changedFiles)
}

function Get-CodeChanges {
    param (
        [parameter(Mandatory)]
        [string]$TargetBranch,

        [parameter(Mandatory)]
        [string]$SourceBranch,

        [string[]]$Files
    )

    Write-Host "`n[Get-CodeChanges] Building diff output..." -ForegroundColor Cyan

    $renamedSourceBranch = $SourceBranch -replace 'refs/heads/', 'origin/'
    $renamedTargetBranch = $TargetBranch -replace 'refs/heads/', 'origin/'

    # Use provided file list, or discover all changed files (backward-compatible)
    if ($Files) {
        $changedFiles = $Files
        Write-Host "[Get-CodeChanges] Using provided file list ($($changedFiles.Count) file(s))"
    } else {
        $changedFiles = Get-ChangedFileList -TargetBranch $TargetBranch -SourceBranch $SourceBranch
        Write-Host "[Get-CodeChanges] Discovered $($changedFiles.Count) file(s)"
    }

    # Add legend for diff markers
    $llmOutput = @"
# Code Review - Changes from $renamedSourceBranch to $renamedTargetBranch

## Legend:
- `+` = Added lines (new code)
- `-` = Removed lines (deleted code)
- `  ` = Unchanged lines (context)

---

"@

    $fileIndex = 0
    foreach ($file in $changedFiles) {
        $fileIndex++
        Write-Host "[Get-CodeChanges] [$fileIndex/$($changedFiles.Count)] Extracting diff for: $file"

        # Ensure file path starts with / for full path from repository root
        $fullPath = if ($file.StartsWith('/')) { $file } else { "/$file" }

        # Get the unified diff with more context
        $diffLines = git diff "$renamedTargetBranch...$renamedSourceBranch" --unified=5 -- $file

        $llmOutput += "## File: $fullPath`n`n"

        # Parse the diff output line by line
        $inHunk = $false
        $oldLineNum = 0
        $newLineNum = 0
        $hunkContent = @()
        $addedLines = 0
        $removedLines = 0

        foreach ($line in $diffLines) {
            # Check for hunk header
            if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
                # If we were processing a previous hunk, output it
                if ($hunkContent.Count -gt 0) {
                    $llmOutput += "### Changes: +$addedLines lines, -$removedLines lines`n"
                    $llmOutput += ($hunkContent -join "`n")
                    $llmOutput += "`n`n"
                }

                # Reset for new hunk
                $hunkContent = @()
                $addedLines = 0
                $removedLines = 0
                $inHunk = $true
                $oldLineNum = [int]$matches[1]
                $newLineNum = [int]$matches[3]
                continue
            }

            # Skip file headers
            if ($line -match '^(diff --git|index|\+\+\+|---|\\ No newline)' -or $line.StartsWith('Binary file')) {
                continue
            }

            # Process hunk content
            if ($inHunk) {
                if ($line.StartsWith('+')) {
                    # Added line
                    $hunkContent += "{0,4}+ {1}" -f $newLineNum, $line.Substring(1)
                    $newLineNum++
                    $addedLines++
                }
                elseif ($line.StartsWith('-')) {
                    # Removed line
                    $hunkContent += "{0,4}- {1}" -f $oldLineNum, $line.Substring(1)
                    $oldLineNum++
                    $removedLines++
                }
                elseif ($line.StartsWith(' ')) {
                    # Context line (unchanged)
                    $hunkContent += "{0,4}  {1}" -f $newLineNum, $line.Substring(1)
                    $oldLineNum++
                    $newLineNum++
                }
                else {
                    # End of hunk
                    $inHunk = $false
                }
            }
        }

        # Output the last hunk if any
        if ($hunkContent.Count -gt 0) {
            $llmOutput += "### Changes: +$addedLines lines, -$removedLines lines`n"
            $llmOutput += ($hunkContent -join "`n")
            $llmOutput += "`n"
        }
        $llmOutput += "`n---`n"
    }

    Write-Host "[Get-CodeChanges] Diff output ready ($($llmOutput.Length) chars)" -ForegroundColor Green
    return $llmOutput
}
