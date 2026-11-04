#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
Import-Module (Join-Path $PSScriptRoot '../tools/DialoguePolicy.psm1') -Force
$interrupted = @{
    outcome = 'failed'; error = 'Runtime tool failure'; turns = @(@{
        call = 1; role = 'target'; rawResponse = "A question.`nDIALOGUE_CONTROL: {`"status`":`"waiting_reply`",`"artifactPaths`":[],`"pending`":[]}"
    })
}
$facts = Get-DialogueCompletionFacts $interrupted
Assert ($facts.finalReplyPresent -and -not $facts.finalReplyDelivered -and
    $facts.finalTargetStatus -eq 'waiting_reply' -and -not $facts.completionClaimed -and
    -not $facts.deliveryVerified -and $facts.stopReason -eq 'Runtime tool failure') 'Interrupted raw reply remains a reply, not a completion or a delivery.'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('result-evaluation-' + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location
try {
    $productRoot = Join-Path $fixture 'product'
    $artifactDirectory = Join-Path $productRoot 'docs/requirements'
    [void](New-Item -ItemType Directory -Path $artifactDirectory -Force)
    'Summary evidence for evaluator.' | Set-Content (Join-Path $fixture 'summary-seed.txt') -Encoding utf8
    Set-Location $productRoot
    & git init --quiet
    Assert ($LASTEXITCODE -eq 0) 'Fixture product workspace initialized.'
    & git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet --allow-empty -m fixture
    Assert ($LASTEXITCODE -eq 0) 'Fixture product baseline committed.'
    Set-Location $originalLocation

    $runs = @()
    foreach ($name in @('condition-auto', 'condition-mai')) {
        $runDirectory = Join-Path $fixture $name
        [void](New-Item -ItemType Directory -Path $runDirectory)
        $artifactPath = Join-Path $artifactDirectory "$name.md"
        $deliveryVerified = $name -eq 'condition-auto'
        if ($deliveryVerified) { "# $name`nApproved scope and acceptance criteria." | Set-Content $artifactPath -Encoding utf8 }
        $relativeArtifact = "docs/requirements/$name.md"
        $turns = @(@{ call = 1; role = 'target'; startedAt = '2026-10-13T00:00:00.0000000+00:00'; finishedAt = '2026-10-13T00:00:08.0000000+00:00'; response = @{ control = @{ status = 'role_task_completed'; artifactPaths = @($relativeArtifact) } } })
        if ($deliveryVerified) {
            $turns += @{ call = 2; role = 'participant'; startedAt = '2026-10-13T00:00:08.0000000+00:00'; finishedAt = '2026-10-13T00:00:13.0000000+00:00'; response = @{ text = 'Participant answer.'; control = @{ status = 'waiting_reply'; artifactPaths = @() } } }
        }
        $state = @{
            outcome = $(if ($deliveryVerified) { 'completed_with_pending' } else { 'stage_completed' }); assessment = 'not_scored'; participantReplies = [int]$deliveryVerified
            startedAt = '2026-10-13T00:00:00.0000000+00:00'; finishedAt = $(if ($deliveryVerified) { '2026-10-13T00:00:13.0000000+00:00' } else { '2026-10-13T00:00:08.0000000+00:00' })
            repositoryPath = $productRoot; pending = @(@{ id = 'Q1'; question = 'Unresolved decision'; kind = 'business_decision' })
            questions = @(); artifactCheck = @{ ready = $deliveryVerified; failures = $(if ($deliveryVerified) { @() } else { @(@{ reason = 'artifact_not_found'; path = $relativeArtifact }) }); verifiedPaths = $(if ($deliveryVerified) { @($relativeArtifact) } else { @() }) }
            turns = $turns
        }
        $config = @{ targetAgent = 'fixture-target'; targetModel = $name; participantModel = 'fixture-participant' }
        $report = @{ actualModels = @{ target = @($name) } }
        $state | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $runDirectory 'result.json') -Encoding utf8
        $config | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $runDirectory 'config.json') -Encoding utf8
        $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $runDirectory 'report.json') -Encoding utf8
        'Summary evidence for evaluator.' | Set-Content (Join-Path $runDirectory 'summary.md') -Encoding utf8
        $runs += @{ name = $name; runDirectory = $runDirectory }
    }
    'PRIVATE_FIXTURE_ORACLE' | Set-Content (Join-Path $fixture 'private-oracle.json') -Encoding utf8
    $comparisonRoot = Join-Path $fixture 'comparison'
    [void](New-Item -ItemType Directory -Path $comparisonRoot)
    @{ conditions = $runs } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $comparisonRoot 'comparison.json') -Encoding utf8
    $evaluationDirectory = Join-Path $fixture 'evaluation-output'
    $scriptPath = Join-Path $PSScriptRoot '../tools/Invoke-DialogueResultEvaluation.ps1'
    $fakeCli = Join-Path $PSScriptRoot 'fixtures/fake-result-evaluator.ps1'
    $domainRubric = Join-Path $fixture 'domain-rubric.json'
    @{ schemaVersion = 1; id = 'synthetic-domain'; version = '1'; scale = @{ min = 0; max = 4 }
        criteria = @(
            @{ id = 'sample_scope'; title = 'Scope'; weight = 20; description = 'Synthetic scope is documented.' },
            @{ id = 'sample_rules'; title = 'Rules'; weight = 25; description = 'Synthetic rules are documented.' },
            @{ id = 'sample_compatibility'; title = 'Compatibility'; weight = 25; description = 'Synthetic compatibility is considered.' },
            @{ id = 'sample_failures'; title = 'Failures'; weight = 20; description = 'Synthetic failures are considered.' },
            @{ id = 'sample_boundaries'; title = 'Boundaries'; weight = 10; description = 'Synthetic boundaries are documented.' }
        ) } | ConvertTo-Json -Depth 8 | Set-Content $domainRubric
    & $scriptPath -RunDirectory $comparisonRoot -Model fixture-advanced -RubricFile (Join-Path $PSScriptRoot '../profiles/result-quality.json') `
        -DomainRubricFile $domainRubric -EvaluationDirectory $evaluationDirectory -CliPath $fakeCli
    Assert ($LASTEXITCODE -eq 0) 'Evaluation CLI completed successfully.'
    $results = Get-Content (Join-Path $evaluationDirectory 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($results.results.Count -eq 2 -and @($results.results | Where-Object status -ne 'completed').Count -eq 0) 'Comparison evaluates each condition independently.'
    $indexSummary = Get-Content (Join-Path $evaluationDirectory 'summary.md') -Raw
    Assert ($indexSummary.Contains('Target 请求模型') -and $indexSummary.Contains('整场耗时') -and
        $indexSummary.Contains('有效引用维度权重占比')) 'Comparison index follows the run overview format and labels evidence precisely.'
    foreach ($run in $runs) {
        $caseOutput = Join-Path $evaluationDirectory $run.name
        $evaluation = Get-Content (Join-Path $caseOutput 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert (($evaluation.score.scores | Measure-Object weight -Sum).Sum -eq 100) 'Effective scoring weights sum to 100.'
        Assert (@($evaluation.score.scores | Where-Object criterionId -eq 'sample_rules')[0].weight -eq 12.5) 'Domain weights contribute half of the combined score.'
        $completionScore = @($evaluation.score.scores | Where-Object criterionId -EQ 'completion_and_delivery')[0].score
        Assert ($evaluation.status -eq 'completed' -and $evaluation.score.scores.Count -eq 10 -and
            $completionScore -eq $(if ($run.name -eq 'condition-auto') { 3 } else { 0 })) 'Completion quality is scored against actual artifact verification.'
        $expectedRunDuration = if ($run.name -eq 'condition-auto') { 13000 } else { 8000 }
        $expectedParticipantDuration = if ($run.name -eq 'condition-auto') { 5000 } else { 0 }
        Assert ($evaluation.executionMetrics.totalWallClockMs -eq $expectedRunDuration -and
            $evaluation.executionMetrics.target.totalDurationMs -eq 8000 -and
            $evaluation.executionMetrics.participant.totalDurationMs -eq $expectedParticipantDuration -and
            -not $evaluation.executionMetrics.elapsedTimeIsQualityScore) 'Elapsed time is reported independently of quality score.'
        Assert ((Get-Content (Join-Path $caseOutput 'evaluation-input.txt') -Raw).Contains('Summary evidence for evaluator.') -and
            -not (Get-Content (Join-Path $caseOutput 'evaluation-input.txt') -Raw).Contains('PRIVATE_FIXTURE_ORACLE')) 'Evaluator receives summary/artifact evidence but no private Oracle.'
        Assert ((Test-Path (Join-Path $caseOutput 'run-facts.json')) -and
            (Get-Content (Join-Path $caseOutput 'evaluation-input.txt') -Raw).Contains('runFactsSource')) 'Machine-verifiable completion and timing facts have a stable citation source.'
        Assert (Test-Path (Join-Path $caseOutput 'evaluator-workspace/.github/agents/result-quality-evaluator.agent.md')) 'Evaluator runs with its isolated read-only agent.'
        Assert ((Get-Content (Join-Path $caseOutput 'evaluation.md') -Raw).Contains('Target：00:00:08.000')) 'Human-readable report shows objective runtime metrics.'
    }
    $replayOutput = Join-Path $fixture 'replayed-evaluation'
    'Changed after evaluation; must not enter replay.' | Set-Content (Join-Path $runs[0].runDirectory 'summary.md')
    & $scriptPath -RunDirectory $comparisonRoot -Model fixture-advanced -RubricFile (Join-Path $PSScriptRoot '../profiles/result-quality.json') `
        -DomainRubricFile $domainRubric -EvaluationDirectory $replayOutput -ReplayCaptureRoot $evaluationDirectory -CliPath $fakeCli
    $replayedResults = Get-Content (Join-Path $replayOutput 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert (@($replayedResults.results | Where-Object status -ne 'completed').Count -eq 0 -and
        (Get-Content (Join-Path $replayOutput 'condition-auto/evaluation.json') -Raw | ConvertFrom-Json -AsHashtable).replayedResponse -and
        -not (Test-Path (Join-Path $replayOutput 'condition-auto/capture'))) 'Saved evaluator captures can be revalidated offline without a second model call.'
    Assert (-not (Get-Content (Join-Path $replayOutput 'condition-auto/evaluation-input.txt') -Raw).Contains('Changed after evaluation')) 'Replay uses frozen evidence, not edited sources.'
    'Summary evidence for evaluator.' | Set-Content (Join-Path $runs[0].runDirectory 'summary.md')
    $changedRubric = Get-Content (Join-Path $PSScriptRoot '../profiles/result-quality.json') -Raw | ConvertFrom-Json -AsHashtable
    $changedRubric.version = 'changed-for-test'
    $changedPath = Join-Path $fixture 'changed-rubric.json'
    $changedRubric | ConvertTo-Json -Depth 10 | Set-Content $changedPath
    $changedOutput = Join-Path $fixture 'changed-replay'
    & $scriptPath -RunDirectory $comparisonRoot -Model fixture-advanced -RubricFile $changedPath `
        -DomainRubricFile $domainRubric -EvaluationDirectory $changedOutput -ReplayCaptureRoot $evaluationDirectory -CliPath 'must-not-run'
    $changedResult = Get-Content (Join-Path $changedOutput 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert (@($changedResult.results | Where-Object status -ne 'failed').Count -eq 0) 'Changed rubric cannot reuse prior model scores.'
    $otherDomain = @{ schemaVersion = 1; id = 'export-feature'; version = '1'; scale = @{ min = 0; max = 4 }
        criteria = @(@{ id = 'export_scope'; title = 'Export boundaries'; weight = 100; description = 'Check the agreed export permissions and data range.' }) }
    $otherDomainPath = Join-Path $fixture 'export-rubric.json'
    $otherDomain | ConvertTo-Json -Depth 10 | Set-Content $otherDomainPath
    $otherOutput = Join-Path $fixture 'other-business'
    & $scriptPath -RunDirectory $runs[0].runDirectory -Model fixture-advanced -DomainRubricFile $otherDomainPath `
        -EvaluationDirectory $otherOutput -CliPath $fakeCli
    $otherResult = Get-Content (Join-Path $otherOutput 'condition-auto/evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($otherResult.status -eq 'completed' -and $otherResult.score.scores.Count -eq 6 -and
        @($otherResult.score.scores | Where-Object criterionId -eq 'export_scope')[0].weight -eq 50) 'Same evaluator supports a non-login domain without business-specific code.'
    $referencePath = Join-Path $fixture 'confirmed-requirement.md'
    'Confirmed public requirement.' | Set-Content $referencePath -Encoding utf8
    $referenceOutput = Join-Path $fixture 'reference-evaluation'
    & $scriptPath -RunDirectory $runs[0].runDirectory -Model fixture-reference -DomainRubricFile $otherDomainPath `
        -ReferenceFile @($referencePath) -EvaluationDirectory $referenceOutput -CliPath $fakeCli
    $referenceCase = Join-Path $referenceOutput 'condition-auto'
    $referenceInput = Get-Content (Join-Path $referenceCase 'evaluation-input.txt') -Raw
    $referencePackage = [regex]::Match($referenceInput, '(?ms)^BEGIN_EVALUATION_PACKAGE\r?\n(.*)\r?\nEND_EVALUATION_PACKAGE\s*$').Groups[1].Value | ConvertFrom-Json -AsHashtable
    $referenceResult = Get-Content (Join-Path $referenceCase 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($referenceResult.status -eq 'completed' -and $referencePackage.referenceDocuments.Count -eq 1 -and
        $referencePackage.referenceDocuments[0].content.Contains('Confirmed public requirement.')) 'Public references are separate, citable inputs.'
    Assert ($referencePackage.rubrics[1].criteria[0].description -ceq $otherDomain.criteria[0].description) 'Reference documents do not mutate rubric descriptions.'
    Assert (Test-Path (Join-Path $referenceCase 'reference/001-confirmed-requirement.md')) 'Public reference snapshot is retained.'
    'Changed public requirement.' | Set-Content $referencePath -Encoding utf8
    $referenceReplay = Join-Path $fixture 'reference-replay'
    & $scriptPath -RunDirectory $runs[0].runDirectory -Model fixture-reference -DomainRubricFile $otherDomainPath `
        -EvaluationDirectory $referenceReplay -ReplayCaptureRoot $referenceOutput -CliPath 'must-not-run'
    Assert (-not (Get-Content (Join-Path $referenceReplay 'condition-auto/evaluation-input.txt') -Raw).Contains('Changed public requirement.')) 'Replay preserves original reference documents without rereading sources.'
    $invalidOutput = Join-Path $fixture 'invalid-evidence-evaluation'
    & $scriptPath -RunDirectory $runs[0].runDirectory -Model fixture-invalid-evidence `
        -EvaluationDirectory $invalidOutput -CliPath $fakeCli
    $invalid = Get-Content (Join-Path $invalidOutput 'condition-auto/evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($invalid.status -eq 'partial_evidence' -and
        $invalid.score.evidenceCoveragePercent -eq 0 -and $null -eq $invalid.score.overallScore -and
        $invalid.score.citationWarnings.Count -gt 0) 'Unverifiable evidence is excluded, warned, and left unscored.'
    $original = Get-Content (Join-Path $runs[0].runDirectory 'result.json') -Raw
    Assert ($original.Contains('completed_with_pending')) 'Evaluation does not mutate the original completed-with-pending outcome.'
    $unverifiedOriginal = Get-Content (Join-Path $runs[1].runDirectory 'result.json') -Raw
    Assert ($unverifiedOriginal.Contains('stage_completed')) 'Evaluation does not rewrite the unverified-delivery run outcome.'
    Write-Output 'PASS: isolated rubric-based evaluation, source evidence, artifact input, weighted score, and multi-condition summary'
} finally {
    Set-Location $originalLocation
    if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
}