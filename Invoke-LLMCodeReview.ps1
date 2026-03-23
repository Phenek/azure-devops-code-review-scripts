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
        [ValidateRange(1, 2000000)]
        [int]
        $MaxChangesLength = 30000,

        [parameter()]
        [ValidateRange(10, 3600)]
        [int]
        $RequestTimeoutSeconds = 600,

        [parameter()]
        [ValidateRange(100, 128000)]
        [int]
        $MaxOutputTokens = 12000,

        [parameter()]
        [ValidateRange(2000, 40000)]
        [int]
        $RescueMaxInputLength = 15000,

        [parameter()]
        [bool]
        $UseJsonSchema = $false
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
        param($Exception, $ErrorRecord)

        $details = [ordered]@{
            Message      = $Exception.Message
            StatusCode   = $null
            ReasonPhrase = $null
            ResponseBody = $null
        }

        if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
            $details.ResponseBody = $ErrorRecord.ErrorDetails.Message
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
                elseif (-not [string]::IsNullOrWhiteSpace($response.StatusDescription)) {
                    $details.ReasonPhrase = $response.StatusDescription
                }
            }
            catch {
            }

            if ([string]::IsNullOrWhiteSpace($details.ResponseBody)) {
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

    $isResponsesUrl = $ModelDeploymentUrl -match '/openai/v1/responses(\?|$)|/responses(\?|$)'
    if (-not $isResponsesUrl) {
        & $fail "ModelDeploymentUrl must target the Responses API. Received '$ModelDeploymentUrl'."
    }

    if ([string]::IsNullOrWhiteSpace($Key)) {
        & $fail "Key is required."
    }

    $schema = @{
        type                 = 'object'
        properties           = @{
            reviews = @{
                type  = 'array'
                items = @{
                    type                 = 'object'
                    properties           = @{
                        fileName   = @{ type = 'string' }
                        lineNumber = @{ type = 'integer' }
                        comment    = @{ type = 'string' }
                    }
                    required             = @('fileName', 'lineNumber', 'comment')
                    additionalProperties = $false
                }
            }
        }
        required             = @('reviews')
        additionalProperties = $false
    }
    & $logStep "Response schema prepared."

    & $logStep "Collecting code changes."
    [string]$changes = Get-CodeChanges -SourceBranch $SourceBranch -TargetBranch $TargetBranch | Out-String
    if ([string]::IsNullOrWhiteSpace($changes)) {
        & $fail "Get-CodeChanges returned an empty payload."
    }

    $effectiveMaxChangesLength = $MaxChangesLength
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_REVIEW_MAX_CHANGES_LENGTH)) {
        $parsedLength = 0
        if ([int]::TryParse($env:LLM_REVIEW_MAX_CHANGES_LENGTH, [ref]$parsedLength) -and $parsedLength -gt 0) {
            $effectiveMaxChangesLength = $parsedLength
            Write-Host "[Invoke-LLMCodeReview] Using LLM_REVIEW_MAX_CHANGES_LENGTH override: $effectiveMaxChangesLength"
        }
        else {
            Write-Warning "[Invoke-LLMCodeReview] Ignoring invalid LLM_REVIEW_MAX_CHANGES_LENGTH value '$($env:LLM_REVIEW_MAX_CHANGES_LENGTH)'."
        }
    }

    $effectiveMaxOutputTokens = $MaxOutputTokens
    if (-not $UseJsonSchema -and $effectiveMaxOutputTokens -gt 12000) {
        $effectiveMaxOutputTokens = 12000
        Write-Warning "[Invoke-LLMCodeReview] MaxOutputTokens capped to $effectiveMaxOutputTokens for non-schema mode to avoid long-running free-form generations."
    }

    if ($changes.Length -gt $effectiveMaxChangesLength) {
        $truncated = $changes.Substring(0, $effectiveMaxChangesLength)

        # Prefer cutting at a section boundary to avoid ending in the middle of a hunk.
        $sectionDelimiter = "`n---`n"
        $lastSectionIndex = $truncated.LastIndexOf($sectionDelimiter)
        if ($lastSectionIndex -gt 0 -and $lastSectionIndex -ge [int]($effectiveMaxChangesLength * 0.6)) {
            $truncated = $truncated.Substring(0, $lastSectionIndex + $sectionDelimiter.Length)
        }

        $omittedChars = $changes.Length - $truncated.Length
        $changes = "$truncated`n`n[TRUNCATED: $omittedChars characters omitted to fit payload budget]"
        Write-Warning "[Invoke-LLMCodeReview] Changes payload is large ($($changes.Length + $omittedChars)). Truncated to $($changes.Length) characters."
    }

    $effectiveRequestTimeoutSeconds = $RequestTimeoutSeconds
    if (-not [string]::IsNullOrWhiteSpace($env:LLM_REVIEW_TIMEOUT_SECONDS)) {
        $parsedTimeoutSeconds = 0
        if ([int]::TryParse($env:LLM_REVIEW_TIMEOUT_SECONDS, [ref]$parsedTimeoutSeconds) -and $parsedTimeoutSeconds -ge 10 -and $parsedTimeoutSeconds -le 3600) {
            $effectiveRequestTimeoutSeconds = $parsedTimeoutSeconds
            Write-Host "[Invoke-LLMCodeReview] Using LLM_REVIEW_TIMEOUT_SECONDS override: $effectiveRequestTimeoutSeconds"
        }
        else {
            Write-Warning "[Invoke-LLMCodeReview] Ignoring invalid LLM_REVIEW_TIMEOUT_SECONDS value '$($env:LLM_REVIEW_TIMEOUT_SECONDS)'."
        }
    }

    & $logStep "Loading review prompt from '$PathToReviewFile'."
    $reviewPrompt = Get-Content -Path $PathToReviewFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($reviewPrompt)) {
        & $fail "Review prompt file is empty."
    }

    & $logStep "Building request payload."

    & $logStep "Serializing request JSON."
    $serializeSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Host "[Invoke-LLMCodeReview] Using manual JSON payload serialization (no ConvertTo-Json on large payload)."

        $encodeJsonString = {
            param([AllowNull()][string]$Value)
            if ($null -eq $Value) {
                return ''
            }

            # JSON-safe string escaping with minimal overhead.
            return [System.Text.Encodings.Web.JavaScriptEncoder]::Default.Encode($Value)
        }

        $modelEscaped = & $encodeJsonString $ModelName
        $instructionsEscaped = & $encodeJsonString $reviewPrompt
        $inputEscaped = & $encodeJsonString $changes

        # Static schema avoids heavy object graph serialization.
        $schemaJson = '{"type":"object","properties":{"reviews":{"type":"array","items":{"type":"object","properties":{"fileName":{"type":"string"},"lineNumber":{"type":"integer"},"comment":{"type":"string"}},"required":["fileName","lineNumber","comment"],"additionalProperties":false}}},"required":["reviews"],"additionalProperties":false}'

        $bodyWithSchema = '{"model":"' + $modelEscaped + '","instructions":"' + $instructionsEscaped + '","input":"' + $inputEscaped + '","tools":[{"type":"function","name":"submit_code_review","description":"Return code review findings in the required schema.","parameters":' + $schemaJson + ',"strict":true}],"tool_choice":{"type":"function","name":"submit_code_review"},"max_output_tokens":' + $effectiveMaxOutputTokens + ',"truncation":"auto","store":false}'
        $bodyWithoutSchema = '{"model":"' + $modelEscaped + '","instructions":"' + $instructionsEscaped + '","input":"' + $inputEscaped + '","text":{"format":{"type":"text"}},"max_output_tokens":' + $effectiveMaxOutputTokens + ',"truncation":"auto","store":false}'

        if ($UseJsonSchema) {
            $body = $bodyWithSchema
        }
        else {
            $body = $bodyWithoutSchema
        }
    }
    catch {
        Write-Error "[Invoke-LLMCodeReview] Request payload serialization failed: $($_.Exception.Message)"
        Write-Host "[Invoke-LLMCodeReview] ScriptStackTrace: $($_.ScriptStackTrace)"
        throw
    }
    finally {
        $serializeSw.Stop()
        Write-Host "[Invoke-LLMCodeReview] Serialization duration: $($serializeSw.ElapsedMilliseconds) ms"
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        & $fail "Serialized request body is empty."
    }

    $bodyByteLength = [System.Text.Encoding]::UTF8.GetByteCount($body)
    Write-Host "[Invoke-LLMCodeReview] Serialized payload length: $($body.Length) characters, $bodyByteLength bytes."
    Write-Host "[Invoke-LLMCodeReview] Request diagnostics: Model='$ModelName', InputLength=$($changes.Length), PromptLength=$($reviewPrompt.Length), MaxOutputTokens=$effectiveMaxOutputTokens, UseJsonSchema=$UseJsonSchema."

    & $logStep "Sending request to model endpoint."
    $invokeResponsesRequest = {
        param(
            [Parameter(Mandatory)]
            [string]$RequestBody,

            [Parameter(Mandatory)]
            [string]$AttemptName
        )

        $attemptByteLength = [System.Text.Encoding]::UTF8.GetByteCount($RequestBody)
        Write-Host "[Invoke-LLMCodeReview] Sending attempt '$AttemptName' (PayloadBytes=$attemptByteLength, TimeoutSeconds=$effectiveRequestTimeoutSeconds)."

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $httpClient = New-Object System.Net.Http.HttpClient($handler)
        try {
            $httpClient.Timeout = [TimeSpan]::FromSeconds($effectiveRequestTimeoutSeconds)
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $ModelDeploymentUrl)
            try {
                $request.Headers.Add('api-key', $Key)
                $request.Headers.Accept.Clear()
                $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
                $request.Headers.ExpectContinue = $false
                $request.Version = [Version]::new(1, 1)
                $request.Content = New-Object System.Net.Http.StringContent($RequestBody, [System.Text.Encoding]::UTF8, 'application/json')

                $sendSw = [System.Diagnostics.Stopwatch]::StartNew()
                Write-Host "[Invoke-LLMCodeReview] Attempt '$AttemptName': opening HTTP connection and sending request body."
                $rawHttpResponse = $httpClient.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $sendSw.Stop()
                Write-Host "[Invoke-LLMCodeReview] Attempt '$AttemptName': received response headers in $($sendSw.ElapsedMilliseconds) ms (StatusCode=$([int]$rawHttpResponse.StatusCode))."

                $readSw = [System.Diagnostics.Stopwatch]::StartNew()
                $responseBodyText = $rawHttpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $readSw.Stop()
                Write-Host "[Invoke-LLMCodeReview] Attempt '$AttemptName': response body read in $($readSw.ElapsedMilliseconds) ms."

                [pscustomobject]@{
                    IsSuccessStatusCode = $rawHttpResponse.IsSuccessStatusCode
                    StatusCode          = [int]$rawHttpResponse.StatusCode
                    ReasonPhrase        = $rawHttpResponse.ReasonPhrase
                    ResponseBody        = $responseBodyText
                    AttemptName         = $AttemptName
                }
            }
            finally {
                if ($null -ne $request) {
                    $request.Dispose()
                }
            }
        }
        finally {
            $httpClient.Dispose()
            $handler.Dispose()
        }
    }

    try {
        if ($UseJsonSchema) {
            $requestResult = & $invokeResponsesRequest -RequestBody $bodyWithSchema -AttemptName 'with_json_schema'

            if (-not $requestResult.IsSuccessStatusCode -and $requestResult.StatusCode -eq 400) {
                Write-Warning "[Invoke-LLMCodeReview] Attempt '$($requestResult.AttemptName)' returned 400. This endpoint/model may reject strict structured output for this request shape."
            }
        }
        else {
            $requestResult = & $invokeResponsesRequest -RequestBody $bodyWithoutSchema -AttemptName 'without_json_schema'
        }

        if (-not $requestResult.IsSuccessStatusCode) {
            Write-Error "[Invoke-LLMCodeReview] Request failed. StatusCode=$($requestResult.StatusCode) Reason='$($requestResult.ReasonPhrase)' Attempt='$($requestResult.AttemptName)'"
            if (-not [string]::IsNullOrWhiteSpace($requestResult.ResponseBody)) {
                Write-Host "[Invoke-LLMCodeReview] Request error body:`n$($requestResult.ResponseBody)"
            }

            if ($requestResult.StatusCode -eq 400 -and -not [string]::IsNullOrWhiteSpace($requestResult.ResponseBody)) {
                if ($requestResult.ResponseBody -match 'max_output_tokens|maximum|too large|invalid_request_error') {
                    & $fail "Model endpoint returned HTTP 400 on attempt '$($requestResult.AttemptName)'. Request was rejected; try lowering MaxOutputTokens (current=$effectiveMaxOutputTokens)."
                }
            }

            & $fail "Model endpoint returned HTTP $($requestResult.StatusCode) on attempt '$($requestResult.AttemptName)'."
        }

        $response = $requestResult.ResponseBody

    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        if ($errorMessage.StartsWith('[Invoke-LLMCodeReview] Model endpoint returned HTTP', [System.StringComparison]::Ordinal) -or $errorMessage.StartsWith('[Invoke-LLMCodeReview] Request failed.', [System.StringComparison]::Ordinal)) {
            throw
        }

        if ($_.Exception -is [System.Threading.Tasks.TaskCanceledException] -or $_.Exception -is [System.OperationCanceledException] -or $_.Exception -is [System.TimeoutException]) {
            & $fail "Request timed out after $effectiveRequestTimeoutSeconds second(s) while contacting model endpoint before a response was received. Model='$ModelName', MaxOutputTokens='$effectiveMaxOutputTokens', UseJsonSchema='$UseJsonSchema'."
        }

        $httpError = & $getHttpErrorDetails $_.Exception $_
        Write-Error "[Invoke-LLMCodeReview] Request failed. StatusCode=$($httpError.StatusCode) Reason='$($httpError.ReasonPhrase)' Message='$($httpError.Message)'"
        if (-not [string]::IsNullOrWhiteSpace($httpError.ResponseBody)) {
            Write-Host "[Invoke-LLMCodeReview] Request error body:`n$($httpError.ResponseBody)"
        }
        throw
    }

    & $logStep "Received response from model endpoint."

    if ($response -is [string]) {
        try {
            $response = $response | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Host "[Invoke-LLMCodeReview] Raw response:`n$response"
            & $fail "Model returned a non-JSON string response."
        }
    }

    $responseContent = $null

    if ($UseJsonSchema -and $null -ne $response.output) {
        foreach ($outputItem in $response.output) {
            if ($outputItem.type -eq 'function_call' -and $outputItem.name -eq 'submit_code_review' -and -not [string]::IsNullOrWhiteSpace($outputItem.arguments)) {
                $responseContent = $outputItem.arguments
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($responseContent) -and -not [string]::IsNullOrWhiteSpace($response.output_text)) {
        $responseContent = $response.output_text
    }
    elseif ([string]::IsNullOrWhiteSpace($responseContent) -and $null -ne $response.output) {
        $parts = @()
        foreach ($outputItem in $response.output) {
            if ($outputItem.type -ne 'message' -or $null -eq $outputItem.content) {
                continue
            }

            foreach ($contentItem in $outputItem.content) {
                if ($contentItem.type -eq 'output_text' -and -not [string]::IsNullOrWhiteSpace($contentItem.text)) {
                    $parts += $contentItem.text
                }
            }
        }

        if ($parts.Count -gt 0) {
            $responseContent = $parts -join "`n"
        }
    }

    if ([string]::IsNullOrWhiteSpace($responseContent)) {
        try {
            if ($response.status -eq 'incomplete' -and $null -ne $response.incomplete_details -and -not [string]::IsNullOrWhiteSpace($response.incomplete_details.reason)) {
                $usageOutputTokens = $null
                $usageReasoningTokens = $null
                $responseReasoningEffort = $null
                $responseTextFormatType = $null
                $responseTextVerbosity = $null

                if ($null -ne $response.usage) {
                    $usageOutputTokens = $response.usage.output_tokens
                    if ($null -ne $response.usage.output_tokens_details) {
                        $usageReasoningTokens = $response.usage.output_tokens_details.reasoning_tokens
                    }
                }

                if ($null -ne $response.reasoning) {
                    $responseReasoningEffort = $response.reasoning.effort
                }

                if ($null -ne $response.text) {
                    if ($null -ne $response.text.format) {
                        $responseTextFormatType = $response.text.format.type
                    }

                    $responseTextVerbosity = $response.text.verbosity
                }

                if ($response.incomplete_details.reason -eq 'max_output_tokens' -and $null -ne $usageOutputTokens -and $null -ne $usageReasoningTokens -and $usageOutputTokens -eq $usageReasoningTokens -and $usageOutputTokens -gt 0) {
                    & $fail "Model response exhausted max_output_tokens using reasoning only and produced no assistant message. usage.output_tokens='$usageOutputTokens', usage.reasoning_tokens='$usageReasoningTokens', response.reasoning.effort='$responseReasoningEffort', response.text.format='$responseTextFormatType', response.text.verbosity='$responseTextVerbosity', MaxOutputTokens='$effectiveMaxOutputTokens', UseJsonSchema='$UseJsonSchema'."
                }

                & $fail "Model response is incomplete (reason='$($response.incomplete_details.reason)') and contains no output_text. usage.output_tokens='$usageOutputTokens', usage.reasoning_tokens='$usageReasoningTokens', response.reasoning.effort='$responseReasoningEffort', response.text.format='$responseTextFormatType', response.text.verbosity='$responseTextVerbosity', MaxOutputTokens='$effectiveMaxOutputTokens'."
            }
        }
        catch {
        }

        Write-Host "[Invoke-LLMCodeReview] Raw response JSON:`n$($response | ConvertTo-Json -Depth 20)"
        & $fail "No extractable response content found."
    }

    try {
        $normalizedResponseContent = $responseContent.Trim()
        if ($normalizedResponseContent -match '^```(?:json)?\s*([\s\S]*?)\s*```$') {
            $normalizedResponseContent = $matches[1].Trim()
        }

        $reviewsObject = $normalizedResponseContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "[Invoke-LLMCodeReview] Raw response content:`n$responseContent"
        & $fail "Response content is not valid JSON."
    }

    if ($null -eq $reviewsObject.reviews) {
        Write-Host "[Invoke-LLMCodeReview] Parsed response object:`n$($reviewsObject | ConvertTo-Json -Depth 20)"
        & $fail "Response JSON does not include top-level 'reviews'."
    }

    $normalizedResponse = $reviewsObject | ConvertTo-Json -Depth 20 -Compress

    & $logStep "Returning parsed response content."

    return $normalizedResponse
}
