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
        $Key
    )

    $logState = [pscustomobject]@{ Step = 1 }
    $logStep = {
        param([string]$Message)
        Write-Host "[Invoke-LLMCodeReview][Step $($logState.Step)] $Message"
        $logState.Step++
    }

    $fail = {
        param([string]$Message)
        Write-Error "[Invoke-LLMCodeReview] $Message"
        throw "[Invoke-LLMCodeReview] $Message"
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

    & $logStep "Starting LLM code review. SourceBranch='$SourceBranch', TargetBranch='$TargetBranch', ModelName='$ModelName'"

    if ([string]::IsNullOrWhiteSpace($PathToReviewFile) -or -not (Test-Path -Path $PathToReviewFile)) {
        & $fail "PathToReviewFile is missing or does not exist: '$PathToReviewFile'."
    }

    if ([string]::IsNullOrWhiteSpace($ModelDeploymentUrl)) {
        & $fail "ModelDeploymentUrl is required."
    }

    $isChatCompletionsUrl = $ModelDeploymentUrl -match '/chat/completions(\?|$)'
    $isResponsesUrl = $ModelDeploymentUrl -match '/responses(\?|$)'
    $hasApiVersion = $ModelDeploymentUrl -match '[\?&]api-version='

    if (-not ($isChatCompletionsUrl -or $isResponsesUrl) -or -not $hasApiVersion) {
        & $fail "ModelDeploymentUrl must be a full Azure OpenAI endpoint ending with '/chat/completions' or '/responses' and include 'api-version'. Received '$ModelDeploymentUrl'."
    }

    if ([string]::IsNullOrWhiteSpace($Key)) {
        & $fail "Key is required."
    }

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
    & $logStep "Response schema prepared."

    & $logStep "Collecting code changes to send to the model."
    [string] $changes = Get-CodeChanges -SourceBranch $SourceBranch -TargetBranch $TargetBranch | Out-String
    if ([string]::IsNullOrWhiteSpace($changes)) {
        & $fail "Get-CodeChanges returned an empty payload."
    }
    Write-Host "[Invoke-LLMCodeReview] Code changes payload length: $($changes.Length) characters."
    Write-Host "[Invoke-LLMCodeReview] Code changes to review:`n$changes"

    # Completion text
    & $logStep "Loading review prompt file from '$PathToReviewFile'."
    $reviewPrompt = Get-Content -Path $PathToReviewFile -Raw
    Write-Host "[Invoke-LLMCodeReview] Review prompt length: $($reviewPrompt.Length) characters."

    $messages = @()
    $messages += @{
        role    = 'system'
        content = @(
            @{
                type = "text"
                text = $reviewPrompt
            }
        )
    }
    $messages += @{
        role    = 'user'
        content = @(
            @{
                type = "text"
                text = $changes
            }
        )
    }
    & $logStep "Request messages prepared. Message count: $($messages.Count)."

    # Header for authentication
    $headers = [ordered]@{
        "api-key" = $Key
    }
    & $logStep "API key header prepared."

    # Adjust these values to fine-tune completions
    & $logStep "Building request body JSON fragments."
    $serializationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $escapedModelName = $ModelName | ConvertTo-Json -Compress
    $escapedReviewPrompt = $reviewPrompt | ConvertTo-Json -Compress
    $escapedChanges = $changes | ConvertTo-Json -Compress
    $schemaJson = $schema | ConvertTo-Json -Depth 20 -Compress

    & $logStep "Assembling final request body JSON."
    $body = @"
{"model":$escapedModelName,"messages":[{"role":"system","content":[{"type":"text","text":$escapedReviewPrompt}]},{"role":"user","content":[{"type":"text","text":$escapedChanges}]}],"response_format":{"type":"json_schema","json_schema":{"name":"CodeReviewResponse","strict":true,"schema":$schemaJson}}}
"@

    $serializationStopwatch.Stop()

    if ([string]::IsNullOrWhiteSpace($body)) {
        & $fail "Request body serialization returned an empty payload."
    }

    Write-Host "[Invoke-LLMCodeReview] Request body serialization completed in $($serializationStopwatch.ElapsedMilliseconds) ms."
    Write-Host "[Invoke-LLMCodeReview] Request body length: $($body.Length) characters."

    & $logStep "Sending request to model endpoint '$ModelDeploymentUrl'."
    try {
        $response = Invoke-RestMethod `
            -Uri $ModelDeploymentUrl `
            -Headers $headers `
            -Body $body `
            -Method Post `
            -ContentType 'application/json' `
            -ErrorAction Stop
    }
    catch {
        $httpError = & $getHttpErrorDetails $_.Exception
        Write-Error "[Invoke-LLMCodeReview] HTTP request failed. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
        if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
            Write-Host "[Invoke-LLMCodeReview] HTTP error response body:`n$($httpError.ResponseBody)"
        }
        throw
    }
    & $logStep "Received response from model endpoint."

    Write-Host "[Invoke-LLMCodeReview] Raw response type: $($response.GetType().FullName)"

    if ($response -is [string]) {
        if ([string]::IsNullOrWhiteSpace($response)) {
            & $fail "Model endpoint returned an empty string response. Verify ModelDeploymentUrl points to the full Azure OpenAI API path, not only the resource root."
        }

        try {
            $response = $response | ConvertFrom-Json -ErrorAction Stop
            Write-Host "[Invoke-LLMCodeReview] Parsed string response into JSON object."
        }
        catch {
            Write-Host "[Invoke-LLMCodeReview] Raw string response:`n$response"
            & $fail "Model endpoint returned a non-JSON string response. Verify ModelDeploymentUrl and API compatibility."
        }
    }

    $responseContent = $null
    if ($null -ne $response.choices -and $response.choices.Count -gt 0) {
        $responseContent = $response.choices[0].message.content
    }
    elseif ($null -ne $response.message) {
        $responseContent = $response.message.content
    }
    elseif ($null -ne $response.output_text) {
        $responseContent = $response.output_text
    }

    if ($null -eq $responseContent) {
        Write-Warning "[Invoke-LLMCodeReview] Unable to extract response content from model response."
        Write-Host ($response | ConvertTo-Json -Depth 20)
        & $fail "Model response did not contain message content in an expected location."
    }


    if ($ModelName -eq "model-router") {
        Write-Host "Response from $ModelName using $($response.model):"
        Write-Host ($responseContent | ConvertTo-Json)
    } else {
        Write-Host "Response from $($ModelName):"
        Write-Host ($responseContent | ConvertTo-Json)
    }

    & $logStep "Returning parsed response content."

    return $responseContent
}
