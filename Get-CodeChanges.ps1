function Get-CodeChanges {
    param (
        [string]$TargetBranch,
        [string]$SourceBranch
    )

    $step = 1
    $logStep = {
        param([string]$Message)
        Write-Host "[Get-CodeChanges][Step $step] $Message"
        $step++
    }

    $fail = {
        param([string]$Message)
        Write-Error "[Get-CodeChanges] $Message"
        throw "[Get-CodeChanges] $Message"
    }

    & $logStep "Starting diff collection. SourceBranch='$SourceBranch', TargetBranch='$TargetBranch'"

    if ([string]::IsNullOrWhiteSpace($SourceBranch) -or [string]::IsNullOrWhiteSpace($TargetBranch)) {
        & $fail "SourceBranch and TargetBranch are required. Received SourceBranch='$SourceBranch', TargetBranch='$TargetBranch'."
    }

    $renamedSourceBranch = $SourceBranch -replace 'refs/heads/', 'origin/'
    $renamedTargetBranch = $TargetBranch -replace 'refs/heads/', 'origin/'
    & $logStep "Normalized branches. Source='$renamedSourceBranch', Target='$renamedTargetBranch'"

    # Get changed code files only, excluding generated C# artifacts
    & $logStep "Collecting changed files from git diff."
    $allChangedFiles = @(git diff --name-only --diff-filter=AM "$renamedTargetBranch...$renamedSourceBranch")
    if ($LASTEXITCODE -ne 0) {
        & $fail "git diff --name-only failed with exit code $LASTEXITCODE for '$renamedTargetBranch...$renamedSourceBranch'."
    }
    Write-Host "[Get-CodeChanges] Found $($allChangedFiles.Count) added/modified file(s) before exclusion."

    $excludedFiles = @($allChangedFiles | Where-Object { $_ -match '(\.Designer\.cs|Snapshot\.cs)$' })
    if ($excludedFiles.Count -gt 0) {
        Write-Host "[Get-CodeChanges] Excluding $($excludedFiles.Count) generated file(s): $($excludedFiles -join ', ')"
    }

    $changedFiles = @($allChangedFiles | Where-Object { $_ -notmatch '(\.Designer\.cs|Snapshot\.cs)$' })
    & $logStep "Processing $($changedFiles.Count) file(s) after exclusion."

    # Add legend for diff markers
    $llmOutput = @"
# Code Review - Changes from $renamedSourceBranch to $renamedTargetBranch

## Legend:
- `+` = Added lines (new code)
- `-` = Removed lines (deleted code)
- `  ` = Unchanged lines (context)

---

"@

    if ($changedFiles.Count -eq 0) {
        & $logStep "No eligible files to include in the review payload."
        return $llmOutput
    }

    foreach ($file in $changedFiles) {
        Write-Host "[Get-CodeChanges] Processing file: $file"

        # Ensure file path starts with / for full path from repository root
        $fullPath = if ($file.StartsWith('/')) { $file } else { "/$file" }
        Write-Host "[Get-CodeChanges] Normalized file path: $fullPath"

        # Get the unified diff with more context
        Write-Host "[Get-CodeChanges] Loading unified diff for '$file'."
        $diffLines = @(git diff "$renamedTargetBranch...$renamedSourceBranch" --unified=5 -- $file)
        if ($LASTEXITCODE -ne 0) {
            & $fail "git diff failed with exit code $LASTEXITCODE while loading '$file'."
        }
        Write-Host "[Get-CodeChanges] Retrieved $($diffLines.Count) diff line(s) for '$file'."

        $llmOutput += "## File: $fullPath`n`n"

        # Parse the diff output line by line
        $inHunk = $false
        $oldLineNum = 0
        $newLineNum = 0
        $hunkContent = @()
        $addedLines = 0
        $removedLines = 0
        $fileAddedLines = 0
        $fileRemovedLines = 0
        $hunkCount = 0

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
                $hunkCount++
                Write-Host "[Get-CodeChanges] Found hunk #$hunkCount in '$file' at old line $($matches[1]), new line $($matches[3])."
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
                    $fileAddedLines++
                }
                elseif ($line.StartsWith('-')) {
                    # Removed line
                    $hunkContent += "{0,4}- {1}" -f $oldLineNum, $line.Substring(1)
                    $oldLineNum++
                    $removedLines++
                    $fileRemovedLines++
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

        Write-Host "[Get-CodeChanges] Completed '$file'. Hunks=$hunkCount, AddedLines=$fileAddedLines, RemovedLines=$fileRemovedLines"
        $llmOutput += "`n---`n"
    }

    & $logStep "Finished building review payload. Payload length: $($llmOutput.Length) characters."

    return $llmOutput
}
