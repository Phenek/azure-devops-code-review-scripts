function Invoke-LLMCodeReview {
    param (
        [parameter(Mandatory)]
        [string]
        $SourceBranch,

        [parameter(Mandatory)]
        [string]
        $TargetBranch,

        [Parameter(Mandatory)]
        [string]
        $PathToReviewFile,

        [parameter(Mandatory)]
        [string]
        $ModelName,

        [parameter(Mandatory)]
        [string]
        $ModelDeploymentUrl,

        [parameter(Mandatory)]
        [string]
        $Key,

        [parameter()]
        [int]
        $BatchSize = 5
    )

    $schema = @{
        type                 = "object"
        properties           = @{
            reviews = @{
                type  = "array"
                items = @{
                    type                 = "object"
                    properties           = @{
                        fileName   = @{
                            type        = "string"
                            description = "The file path being reviewed"
                        }
                        lineNumber = @{
                            type        = "integer"
                            description = "The line number where the issue occurs"
                        }
                        comment    = @{
                            type        = "string"
                            description = "The review comment with emoji, severity, category, explanation and an optional suggested fix"
                        }
                    }
                    required             = @("fileName", "lineNumber", "comment")
                    additionalProperties = $false
                }
            }
        }
        required             = @("reviews")
        additionalProperties = $false
    }

    # Get the full list of changed files
    $allFiles = Get-ChangedFileList -SourceBranch $SourceBranch -TargetBranch $TargetBranch

    if ($allFiles.Count -eq 0) {
        Write-Host "No changed files to review."
        return '{"reviews":[]}'
    }

    # Split files into batches
    $batches = @()
    for ($i = 0; $i -lt $allFiles.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $allFiles.Count)
        $batches += , @($allFiles[$i..($end - 1)])
    }

    $totalBatches = $batches.Count
    Write-Host "Processing $($allFiles.Count) file(s) in $totalBatches batch(es) of up to $BatchSize"

    # System prompt — loaded once, reused for every batch
    $systemPrompt = Get-Content -Path $PathToReviewFile -Raw

    # Header for authentication
    $headers = [ordered]@{
        "Authorization" = "Bearer $($Key)"
    }

    $allReviews = @()

    for ($b = 0; $b -lt $totalBatches; $b++) {
        $batch = $batches[$b]
        Write-Host "`n--- Batch $($b + 1)/$totalBatches ($($batch.Count) file(s): $($batch -join ', ')) ---" -ForegroundColor Cyan

        [string] $changes = Get-CodeChanges -SourceBranch $SourceBranch -TargetBranch $TargetBranch -Files $batch | Out-String
        Write-Host "Code changes to review:`n$changes"

        $messages = @(
            @{
                role    = 'system'
                content = @(
                    @{
                        type = "text"
                        text = $systemPrompt
                    }
                )
            },
            @{
                role    = 'user'
                content = @(
                    @{
                        type = "text"
                        text = $changes
                    }
                )
            }
        )

        $body = [ordered]@{
            model           = $ModelName
            messages        = $messages
            response_format = @{
                type        = "json_schema"
                json_schema = @{
                    name   = "CodeReviewResponse"
                    strict = $true
                    schema = $schema
                }
            }
        } | ConvertTo-Json -Depth 99

        $response = Invoke-RestMethod `
            -Uri $ModelDeploymentUrl `
            -Headers $headers `
            -Body $body `
            -Method Post `
            -ContentType 'application/json'

        $modelUsed = if ($ModelName -eq "model-router") { $response.model } else { $ModelName }
        Write-Host "Response from $($modelUsed):"
        Write-Host ($response.choices.message.content | ConvertTo-Json)

        $batchResult = $response.choices.message.content | ConvertFrom-Json
        if ($batchResult.reviews) {
            $allReviews += $batchResult.reviews
        }
    }

    # Aggregate all reviews into a single JSON output
    $aggregated = @{ reviews = @($allReviews) } | ConvertTo-Json -Depth 10
    Write-Host "`nTotal reviews collected: $($allReviews.Count)" -ForegroundColor Green
    return $aggregated
}
