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
        $BatchSize = 5,

        [parameter()]
        [int]
        $TimeoutSec = 120
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

    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "[Invoke-LLMCodeReview] STEP 1/3 - Discovering changed files" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "[Invoke-LLMCodeReview] Model: $ModelName | BatchSize: $BatchSize | Timeout: ${TimeoutSec}s"

    $allFiles = Get-ChangedFileList -SourceBranch $SourceBranch -TargetBranch $TargetBranch

    if ($allFiles.Count -eq 0) {
        Write-Host "[Invoke-LLMCodeReview] No changed files to review." -ForegroundColor Yellow
        return '{"reviews":[]}'
    }

    # Split files into batches
    $batches = @()
    for ($i = 0; $i -lt $allFiles.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $allFiles.Count)
        $batches += , @($allFiles[$i..($end - 1)])
    }

    $totalBatches = $batches.Count

    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "[Invoke-LLMCodeReview] STEP 2/3 - Sending batches to LLM" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "[Invoke-LLMCodeReview] $($allFiles.Count) files -> $totalBatches batches of up to $BatchSize"

    # System prompt — loaded once, reused for every batch
    $systemPrompt = Get-Content -Path $PathToReviewFile -Raw

    # Header for authentication
    $headers = [ordered]@{
        "Authorization" = "Bearer $($Key)"
    }

    $allReviews = @()

    for ($b = 0; $b -lt $totalBatches; $b++) {
        $batch = $batches[$b]
        Write-Host "`n--- Batch $($b + 1)/$totalBatches - $($batch.Count) files: $($batch -join ', ') ---" -ForegroundColor Cyan

        Write-Host "[Invoke-LLMCodeReview] Extracting diffs for batch $($b + 1)..."
        [string] $changes = Get-CodeChanges -SourceBranch $SourceBranch -TargetBranch $TargetBranch -Files $batch | Out-String
        Write-Host "Code changes to review:`n$changes"

        Write-Host "[Invoke-LLMCodeReview] Sending batch $($b + 1)/$totalBatches to $ModelName..." -ForegroundColor Yellow
        $batchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

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

        $payloadSizeKB = [math]::Round($body.Length / 1024, 1)
        Write-Host "[Invoke-LLMCodeReview] Payload size: ${payloadSizeKB} KB ($($body.Length) chars)" -ForegroundColor Yellow
        if ($payloadSizeKB -gt 200) {
            Write-Warning "[Invoke-LLMCodeReview] Large payload - ${payloadSizeKB} KB -- consider reducing BatchSize"
        }

        try {
            $response = Invoke-RestMethod `
                -Uri $ModelDeploymentUrl `
                -Headers $headers `
                -Body $body `
                -Method Post `
                -ContentType 'application/json' `
                -TimeoutSec $TimeoutSec
        }
        catch {
            Write-Warning "[Invoke-LLMCodeReview] Batch $($b + 1) FAILED after $([math]::Round($batchStopwatch.Elapsed.TotalSeconds, 1))s: $_"
            Write-Warning "[Invoke-LLMCodeReview] Skipping batch $($b + 1), continuing with next batch..."
            continue
        }

        $batchStopwatch.Stop()
        $modelUsed = if ($ModelName -eq "model-router") { $response.model } else { $ModelName }
        Write-Host "[Invoke-LLMCodeReview] Batch $($b + 1) completed in $([math]::Round($batchStopwatch.Elapsed.TotalSeconds, 1))s (model: $modelUsed)" -ForegroundColor Green
        Write-Host "Response:"
        Write-Host ($response.choices.message.content | ConvertTo-Json)

        $batchResult = $response.choices.message.content | ConvertFrom-Json
        if ($batchResult.reviews) {
            $allReviews += $batchResult.reviews
            Write-Host "[Invoke-LLMCodeReview] Batch $($b + 1) returned $($batchResult.reviews.Count) reviews"
        } else {
            Write-Host "[Invoke-LLMCodeReview] Batch $($b + 1) returned 0 reviews"
        }
    }

    # Aggregate all reviews into a single JSON output
    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "[Invoke-LLMCodeReview] STEP 3/3 - Aggregating results" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta

    $aggregated = @{ reviews = @($allReviews) } | ConvertTo-Json -Depth 10
    Write-Host "[Invoke-LLMCodeReview] Total reviews collected: $($allReviews.Count) from $totalBatches batches" -ForegroundColor Green
    return $aggregated
}
