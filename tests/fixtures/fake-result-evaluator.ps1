if ($args -contains '--version') { Write-Output 'fixture-evaluator 1.0'; exit 0 }
if ($args -contains '--help') { Write-Output "  --disallow-temp-dir`n  --no-remote`n  --no-remote-export"; exit 0 }
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
if ($prompt.Contains('PRIVATE_FIXTURE_ORACLE')) { throw 'Private Oracle leaked to evaluator.' }
$match = [regex]::Match($prompt, '(?s)BEGIN_EVALUATION_PACKAGE\s*(\{.*?\})\s*END_EVALUATION_PACKAGE')
if (-not $match.Success) { throw 'Evaluation package markers missing.' }
$package = $match.Groups[1].Value | ConvertFrom-Json -AsHashtable
$modelIndex = [Array]::IndexOf($args, '--model')
$model = if ($modelIndex -ge 0) { $args[$modelIndex + 1] } else { 'fixture-evaluator' }
$scores = @($package.criteria | ForEach-Object {
    $quote = if ($model -eq 'fixture-invalid-evidence') { 'This quote does not exist in the supplied sources.' }
        elseif ($model -eq 'fixture-reference') { $package.referenceDocuments[0].content.Trim() }
        else { 'Summary evidence for evaluator.' }
    $source = if ($model -eq 'fixture-reference') { $package.referenceDocuments[0].source } else { 'summary.md' }
    $score = if ($_.id -eq 'completion_and_delivery' -and -not $package.runFacts.completionAssessment.deliveryVerified) { 0 } else { 3 }
    @{ criterionId = $_.id; score = $score; rationale = 'Fixture assessment based on supplied summary and verified delivery facts.'
        evidence = @(@{ source = $source; quote = $quote }) }
})
$response = @{
    summary = 'Fixture evaluation completed.'; scores = $scores; findings = @()
    strengths = @('Evidence was supplied.'); limitations = @('Fixture output does not judge semantic quality.')
} | ConvertTo-Json -Depth 12 -Compress
$usagePathIndex = [Array]::IndexOf($args, '--usage-output-file')
if ($usagePathIndex -ge 0) {
    @{ totalNanoAiu = 1000000; aiCreditsStatus = 'complete'; totalPremiumRequestCost = 0
        tokenDetails = @{ input = @{ tokenCount = 100 }; cache_read = @{ tokenCount = 0 }; cache_write = @{ tokenCount = 0 }; output = @{ tokenCount = 20 } }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $args[$usagePathIndex + 1] -Encoding utf8
}
@{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
@{ type = 'assistant.message'; id = 'evaluator-final'; data = @{ content = $response; toolRequests = @() } } | ConvertTo-Json -Depth 15 -Compress
exit 0