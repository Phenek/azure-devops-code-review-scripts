function Set-PullRequestComments {
    param (
        [parameter(Mandatory)]
        [string]
        $Organization,

        [parameter(Mandatory)]
        [int]
        $PullRequestId,

        [Parameter(Mandatory)]
        [string]
        $RepositoryName,

        [parameter(Mandatory)]
        [string]
        $Project,

        [parameter(Mandatory)]
        [string]
        $Reviews,

        [parameter()]
        [switch]
        $AutoApprove
    )

    $logState = [pscustomobject]@{ Step = 1 }
    $logStep = {
        param([string]$Message)
        Write-Host "[Set-PullRequestComments][Step $($logState.Step)] $Message"
        $logState.Step++
    }

    $fail = {
        param([string]$Message)
        Write-Error "[Set-PullRequestComments] $Message"
        throw "[Set-PullRequestComments] $Message"
    }

    $getHttpErrorDetails = {
        param($Exception)

        $details = [ordered]@{
            Message      = $Exception.Message
            StatusCode   = $null
            ReasonPhrase = $null
            ResponseBody = $null
        }

        $response = $Exception.Response
        if ($null -ne $response) {
            try {
                if ($null -ne $response.StatusCode) {
                    $details.StatusCode = [int]$response.StatusCode
                }
            }
            catch {
            }

            try {
                if (-not [string]::IsNullOrWhiteSpace($response.ReasonPhrase)) {
                    $details.ReasonPhrase = $response.ReasonPhrase
                }
            }
            catch {
            }

            if ([string]::IsNullOrWhiteSpace($details.ReasonPhrase)) {
                try {
                    if (-not [string]::IsNullOrWhiteSpace($response.StatusDescription)) {
                        $details.ReasonPhrase = $response.StatusDescription
                    }
                }
                catch {
                }
            }

            try {
                if ($null -ne $response.Content) {
                    $details.ResponseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    $responseStream = $response.GetResponseStream()
                    if ($null -ne $responseStream) {
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        try {
                            $details.ResponseBody = $reader.ReadToEnd()
                        }
                        finally {
                            $reader.Dispose()
                            $responseStream.Dispose()
                        }
                    }
                }
            }
            catch {
            }
        }

        [pscustomobject]$details
    }

    & $logStep "Starting pull request comment publication. Organization='$Organization', Project='$Project', Repository='$RepositoryName', PullRequestId='$PullRequestId'"

    if ([string]::IsNullOrWhiteSpace($Organization) -or [string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($RepositoryName)) {
        & $fail "Organization, Project and RepositoryName are required."
    }

    if ($PullRequestId -le 0) {
        & $fail "PullRequestId must be greater than zero. Received '$PullRequestId'."
    }

    if ([string]::IsNullOrWhiteSpace($Reviews)) {
        & $fail "Reviews payload is required."
    }

    & $logStep "Requesting Azure DevOps access token."
    try {
        $token = (New-Object System.Management.Automation.PSCredential("token", (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798" -AsSecureString).token)).GetNetworkCredential().Password
    }
    catch {
        & $fail "Failed to obtain Azure DevOps access token. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        & $fail "Received an empty Azure DevOps access token."
    }

    $headers = @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    }
    & $logStep "Authorization headers prepared."

    # Get current authenticated user from Azure DevOps
    & $logStep "Loading current authenticated Azure DevOps user."
    try {
        $connectionData = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/connectionData" -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        $httpError = & $getHttpErrorDetails $_.Exception
        Write-Error "[Set-PullRequestComments] Failed to load authenticated user. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
        if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
            Write-Host "[Set-PullRequestComments] HTTP error response body:`n$($httpError.ResponseBody)"
        }
        throw
    }

    if ($null -eq $connectionData.authenticatedUser -or [string]::IsNullOrWhiteSpace($connectionData.authenticatedUser.id)) {
        & $fail "Connection data did not contain an authenticated user."
    }

    $currentUserName = $connectionData.authenticatedUser.providerDisplayName
    Write-Host "Checking for existing comments from: $currentUserName"
    Write-Host "[Set-PullRequestComments] Authenticated user id: $($connectionData.authenticatedUser.id)"

    # Get existing threads
    $getThreadsUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"
    & $logStep "Loading existing pull request threads."

    try {
        $existingThreads = Invoke-RestMethod -Uri $getThreadsUrl -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "[Set-PullRequestComments] Retrieved $($existingThreads.value.Count) existing thread(s)."
    }
    catch {
        $httpError = & $getHttpErrorDetails $_.Exception
        Write-Warning "Failed to retrieve existing threads, continuing without duplicate check..."
        Write-Warning "[Set-PullRequestComments] Thread retrieval error. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
        if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
            Write-Host "[Set-PullRequestComments] HTTP error response body:`n$($httpError.ResponseBody)"
        }
        $existingThreads = $null
    }

    # Build a lookup hashtable of existing comments by file:line
    & $logStep "Building lookup of existing comments for duplicate detection."
    $existingComments = @{}
    if ($existingThreads) {
        foreach ($thread in $existingThreads.value) {
            # Skip deleted threads or threads without context
            if ($thread.isDeleted -or -not $thread.threadContext -or -not $thread.threadContext.filePath) {
                continue
            }

            if ($thread.status -notin @("active", "pending", "fixed", "wontFix", "closed")) {
                continue
            }

            # Check if any comment is from the current user (not deleted)
            $hasUserComment = $thread.comments | Where-Object {
                $_.author.displayName -eq $currentUserName 
            } | Select-Object -First 1

            if ($hasUserComment) {
                # Normalize file path (lowercase, ensure leading /)
                $normalizedPath = $thread.threadContext.filePath.ToLower()
                if (-not $normalizedPath.StartsWith('/')) {
                    $normalizedPath = "/$normalizedPath"
                }
                $key = "$normalizedPath|$($thread.threadContext.rightFileStart.line)"
                $existingComments[$key] = $true
            }
        }
    }
    Write-Host "[Set-PullRequestComments] Duplicate lookup contains $($existingComments.Count) existing comment key(s)."

    # Parse and validate reviews
    & $logStep "Parsing LLM review payload."
    try {
        $reviewsObject = $Reviews | ConvertFrom-Json
    }
    catch {
        Write-Error "[Set-PullRequestComments] Failed to parse Reviews JSON payload. $_"
        Write-Host "[Set-PullRequestComments] Raw Reviews payload:`n$Reviews"
        throw
    }

    if ($null -eq $reviewsObject) {
        & $fail "Reviews payload was parsed as null."
    }

    Write-Host "[Set-PullRequestComments] Parsed $($reviewsObject.reviews.Count) review item(s)."
    if ($null -eq $reviewsObject.reviews -or $reviewsObject.reviews.Count -eq 0) {
        Write-Host "No reviews to post."
        
        if ($AutoApprove) {
            & $logStep "AutoApprove enabled and there are no comments to post."
            Write-Host "AutoApprove enabled: Approving pull request..." -ForegroundColor Cyan
            $reviewerId = $connectionData.authenticatedUser.id
            $approveUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/reviewers/$($reviewerId)?api-version=7.1"
            
            $approveBody = @{
                vote = 10
            }
            
            try {
                $null = Invoke-RestMethod -Uri $approveUrl -Headers $headers -Method Put -Body ($approveBody | ConvertTo-Json -Depth 10) -ErrorAction Stop
                Write-Host "Pull request approved successfully." -ForegroundColor Green
                & $logStep "Pull request approval completed successfully."
            }
            catch {
                $httpError = & $getHttpErrorDetails $_.Exception
                Write-Error "[Set-PullRequestComments] Failed to approve pull request. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
                if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
                    Write-Host "[Set-PullRequestComments] HTTP error response body:`n$($httpError.ResponseBody)"
                }
                throw
            }
        }
        
        & $logStep "Stopping because there are no reviews to publish."
        return
    }

    & $logStep "Validating and normalizing review items."
    $validReviews = @()
    $generalReviews = @()
    $invalidReviewsCount = 0
    foreach ($review in $reviewsObject.reviews) {
        if ($review -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($review)) {
                $generalReviews += [pscustomobject]@{ comment = [string]$review }
            }
            else {
                $invalidReviewsCount++
            }
            continue
        }

        $hasFileName = $null -ne $review -and -not [string]::IsNullOrWhiteSpace($review.fileName)
        $hasLineNumber = $null -ne $review -and $null -ne $review.lineNumber -and ($review.lineNumber -as [int]) -gt 0
        $hasComment = $null -ne $review -and -not [string]::IsNullOrWhiteSpace($review.comment)

        if (-not $hasComment) {
            $invalidReviewsCount++
            Write-Warning "[Set-PullRequestComments] Skipping invalid review item. fileName='$($review.fileName)' lineNumber='$($review.lineNumber)' hasComment=$hasComment"
            continue
        }

        if (-not $hasFileName -or -not $hasLineNumber) {
            # Keep comment as a general PR thread when line context is unavailable.
            $generalReviews += [pscustomobject]@{ comment = [string]$review.comment }
            continue
        }

        $normalizedPath = $review.fileName.Trim().ToLower()
        if (-not $normalizedPath.StartsWith('/')) {
            $normalizedPath = "/$normalizedPath"
        }

        $validReviews += [pscustomobject]@{
            fileName = $normalizedPath
            lineNumber = [int]$review.lineNumber
            comment = [string]$review.comment
        }
    }

    if ($invalidReviewsCount -gt 0) {
        Write-Warning "[Set-PullRequestComments] Ignored $invalidReviewsCount invalid review item(s)."
    }

    if ($validReviews.Count -eq 0 -and $generalReviews.Count -eq 0) {
        & $logStep "Stopping because there are no valid reviews to publish."
        Write-Host "No valid reviews to post after validation."
        return
    }

    # Filter out duplicate reviews
    & $logStep "Filtering duplicate review comments."
    $newReviews = $validReviews | Where-Object {
        $key = "$($_.fileName)|$($_.lineNumber)"

        # Keep only reviews that don't exist yet
        -not $existingComments.ContainsKey($key)
    }
    Write-Host "[Set-PullRequestComments] $($newReviews.Count) new review(s) remain after duplicate filtering."

    if ($newReviews.Count -eq 0) {
        if ($generalReviews.Count -eq 0) {
            Write-Host "All comments already exist. No new comments to post." -ForegroundColor Yellow
            & $logStep "Stopping because every review already exists on the pull request."
            return
        }
    }

    $skipped = $validReviews.Count - $newReviews.Count
    if ($skipped -gt 0) {
        Write-Host "Skipping $skipped duplicate comment(s)" -ForegroundColor Yellow
    }

    # Post new reviews
    $createThreadUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"
    & $logStep "Posting new review threads to Azure DevOps."

    $failedPosts = @()

    foreach ($review in $newReviews) {
        # Determine line range for suggestions
        $startLine = $review.lineNumber
        $endLine = $review.lineNumber
        $endOffset = 1000

        Write-Host "[Set-PullRequestComments] Creating thread for file '$($review.fileName)' at line $($review.lineNumber)."

        $threadBody = @{
            comments      = @(
                @{
                    parentCommentId = 0
                    content         = $review.comment
                    commentType     = 1
                }
            )
            status        = 1
            threadContext = @{
                filePath       = $review.fileName
                rightFileStart = @{ line = $startLine; offset = 1 }
                rightFileEnd   = @{ line = $endLine; offset = $endOffset }
            }
        }

        try {
            $response = Invoke-RestMethod -Uri $createThreadUrl -Headers $headers -Method Post -Body ($threadBody | ConvertTo-Json -Depth 10) -ErrorAction Stop
            Write-Host "Comment posted on '$($review.fileName)' line $($review.lineNumber) (Thread ID: $($response.id))" -ForegroundColor Green
        }
        catch {
            $httpError = & $getHttpErrorDetails $_.Exception
            Write-Error "[Set-PullRequestComments] Failed to post comment on '$($review.fileName)' line $($review.lineNumber). StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
            if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
                Write-Host "[Set-PullRequestComments] HTTP error response body:`n$($httpError.ResponseBody)"
            }
            $failedPosts += "'$($review.fileName)' line $($review.lineNumber)"
        }
    }

    if ($generalReviews.Count -gt 0) {
        Write-Host "[Set-PullRequestComments] Posting $($generalReviews.Count) general review comment(s) without file/line context."
        foreach ($generalReview in $generalReviews) {
            $threadBody = @{
                comments = @(
                    @{
                        parentCommentId = 0
                        content         = $generalReview.comment
                        commentType     = 1
                    }
                )
                status   = 1
            }

            try {
                $response = Invoke-RestMethod -Uri $createThreadUrl -Headers $headers -Method Post -Body ($threadBody | ConvertTo-Json -Depth 10) -ErrorAction Stop
                Write-Host "General comment posted (Thread ID: $($response.id))" -ForegroundColor Green
            }
            catch {
                $httpError = & $getHttpErrorDetails $_.Exception
                Write-Error "[Set-PullRequestComments] Failed to post general comment. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
                if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
                    Write-Host "[Set-PullRequestComments] HTTP error response body:`n$($httpError.ResponseBody)"
                }
                $failedPosts += "general comment"
            }
        }
    }

    if ($failedPosts.Count -gt 0) {
        & $fail "Failed to post $($failedPosts.Count) review comment(s): $($failedPosts -join ', ')"
    }

    & $logStep "Completed pull request comment publication flow."
}
