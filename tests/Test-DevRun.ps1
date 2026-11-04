#requires -Version 7.0
param([string[]]$Cases = @('success', 'reasoning-max', 'tamper', 'feature-failed', 'no-change', 'protected', 'model-mismatch',
    'corrupt', 'corrupt-recovered', 'failed-corrupt', 'timeout-corrupt', 'tests-failed-corrupt',
    'missing-model-corrupt', 'mismatch-corrupt', 'runtime-error-corrupt', 'test-timeout', 'preflight-failed', 'updated-regression', 'regression-only'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$framework = Split-Path $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dev-run-' + [guid]::NewGuid().ToString('N'))
$savedMode = $env:DEV_RUN_FIXTURE
$savedCounter = $env:DEV_RUN_COUNTER
$savedAutoload = $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
try {
    $source = Join-Path $fixture 'source'
    foreach ($relative in @('.github\agents', 'docs', 'tests', '.runtime')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $source $relative) -Force)
    }
    "---`nname: fixture-developer`n---`nImplement code and run Python tests." |
        Set-Content (Join-Path $source '.github\agents\fixture-developer.agent.md')
    "---`nname: SDLCRole_Test`n---`nProject-owned independent Test role." |
        Set-Content (Join-Path $source '.github\agents\SDLCRole_Test.agent.md')
    'Project contract: backend tests belong to Dev.' |
        Set-Content (Join-Path $source 'docs\PROJECT-WORKFLOW-ROLES-DEV-TEST.md')
    'answer = 1' | Set-Content (Join-Path $source 'answer.py')
    ".runtime/`n__pycache__/`n.pytest_cache/" | Set-Content (Join-Path $source '.gitignore')
    'frozen-state' | Set-Content (Join-Path $source '.runtime\state.txt')
    @'
import time
from answer import answer

def test_regression():
    if answer == 3:
        time.sleep(30)
    assert answer >= 1
'@ | Set-Content (Join-Path $source 'tests\test_regression.py')
    $acceptance = Join-Path $fixture 'trusted-tests'
    [void](New-Item -ItemType Directory -Path $acceptance)
    "from answer import answer`n`ndef test_feature():`n    assert answer == 2" |
        Set-Content (Join-Path $acceptance 'test_feature.py')
    'Confirmed requirement' | Set-Content (Join-Path $fixture 'requirement.md')
    'Confirmed design' | Set-Content (Join-Path $fixture 'design.md')
    & git -C $source init --quiet
    Assert ($LASTEXITCODE -eq 0) 'Fixture initialization failed.'
    & git -C $source add --all
    Assert ($LASTEXITCODE -eq 0) 'Fixture staging failed.'
    $phase = Get-Content (Join-Path $framework 'profiles\developer-coding.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($phase.policy.timeoutSeconds -eq 3600 -and $phase.policy.callLimit -eq 1 -and
        $phase.policy.Count -eq 3 -and $phase.policy.disableBuiltinMcps) 'Default Dev has only single-call, timeout and MCP policy.'
    $phase.targetAgent = 'fixture-developer'
    $phase.policy.timeoutSeconds = 10
    $phasePath = Join-Path $fixture 'phase.json'
    $project = @{ schemaVersion = 1; id = 'fixture'; repositoryPath = $source; runsRoot = (Join-Path $fixture 'runs')
        requirementWorkspacePath = 'docs\requirements\req-{caseId}.md'; designWorkspacePath = 'docs\design\design-{caseId}.md'
        excludePatterns = @(); runtimeDirectories = @('.runtime'); projectContractPath = 'docs/PROJECT-WORKFLOW-ROLES-DEV-TEST.md'
        reportWorkspacePath = 'docs/Test/test-report-{caseId}.md' }
    $project | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture 'project.json')
    $verification = @{ pythonExecutable = 'python'; testPaths = @('tests'); timeoutSeconds = 30; acceptanceDirectory = $acceptance }
    $manifest = @{ schemaVersion = 1; caseId = 'dv01'; projectProfile = 'project.json'; stages = @{
        design = @{ inputFile = 'requirement.md' }
        dev = @{ inputFile = 'design.md'; phaseProfile = $phasePath; verification = $verification }
    } }
    $manifestPath = Join-Path $fixture 'scenario.json'
    $env:DEV_RUN_COUNTER = Join-Path $fixture 'invocations.txt'
    $runner = Join-Path $framework 'tools\Invoke-SDLC-Eval.ps1'
    $fake = Join-Path $PSScriptRoot 'fixtures\fake-dev-cli.ps1'
    $phase | ConvertTo-Json -Depth 15 | Set-Content $phasePath
    $manifest | ConvertTo-Json -Depth 15 | Set-Content $manifestPath
    $effortPlan = & $runner -ScenarioFile $manifestPath -Stage dev -Mode ValidateOnly -ReasoningEffort max -CliPath $fake
    Assert ($effortPlan.requestedReasoningEffort -ceq 'max' -and -not (Test-Path $effortPlan.runDirectory)) 'Validation must retain explicit effort without running models.'
    foreach ($arguments in @(@{ Stage = 'design'; ReasoningEffort = 'max' }, @{ Stage = 'test'; ReasoningEffort = 'max' },
        @{ Stage = 'dev'; ReasoningEffort = 'invalid-effort' })) {
        $rejected = $false
        try { & $runner -ScenarioFile $manifestPath -Mode ValidateOnly @arguments | Out-Null } catch {
            $rejected = if ($arguments.Stage -eq 'dev') {
                $_.Exception.Message.Contains('ReasoningEffort') -and $_.Exception.Message.Contains('invalid-effort')
            } else {
                $_.Exception.Message.StartsWith('-ReasoningEffort requires explicit -Stage dev;')
            }
            if (-not $rejected) { throw }
        }
        Assert $rejected 'Reasoning effort must reject unsupported values or non-Dev scope before model invocation.'
    }
    foreach ($mode in $Cases) {
        $env:DEV_RUN_FIXTURE = $mode
        $phase.policy.timeoutSeconds = if ($mode -eq 'timeout-corrupt') { 2 } else { 10 }
        $verification.timeoutSeconds = if ($mode -eq 'test-timeout') { 20 } else { 60 }
        if ($mode -in @('regression-only', 'updated-regression')) { [void]$verification.Remove('acceptanceDirectory') }
        $phase | ConvertTo-Json -Depth 15 | Set-Content $phasePath
        $manifest | ConvertTo-Json -Depth 15 | Set-Content $manifestPath
        if ($mode -eq 'preflight-failed') { 'answer = 0' | Set-Content (Join-Path $source 'answer.py') }
        $run = Join-Path $fixture $mode
        $before = if (Test-Path $env:DEV_RUN_COUNTER) { @(Get-Content $env:DEV_RUN_COUNTER).Count } else { 0 }
        $models = @(if ($mode -eq 'success') { 'fixture-model'; 'fixture-other' } else { 'fixture-model' })
        $runError = $null
        $pipelineArgs = if ($mode -eq 'success') { @{ WithTest = $true; TestModels = @('fixture-tester', 'fixture-second-tester') } } else { @{} }
        if ($mode -eq 'reasoning-max') {
            $pipelineArgs = @{ ReasoningEffort = 'max'; WithTest = $true; TestModels = @('fixture-tester') }
        }
        try {
            & $runner -ScenarioFile $manifestPath -Stage dev -Mode Run -RunDirectory $run -TargetModels $models `
                -CliPath $fake -UseGitHubCliAuth:$false @pipelineArgs | Out-Null
        } catch { $runError = $_.Exception.Message }
        $comparison = Get-Content (Join-Path $run 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
        $expectedEffort = if ($mode -eq 'reasoning-max') { 'max' } else { $null }
        $inputManifest = Get-Content (Join-Path $run 'input-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($comparison.requestedReasoningEffort -ceq $expectedEffort -and
            $inputManifest.requestedReasoningEffort -ceq $expectedEffort) 'Requested effort must be persisted without inventing a default.'
        $expected = switch ($mode) {
            'tamper' { 'tests_failed' }
            'feature-failed' { 'tests_failed' }
            'test-timeout' { 'tests_failed' }
            'no-change' { 'no_code_changes' }
            'protected' { 'protected_input_changed' }
            'model-mismatch' { 'model_mismatch' }
            'tests-failed-corrupt' { 'tests_failed' }
            'missing-model-corrupt' { 'evidence_insufficient' }
            'mismatch-corrupt' { 'model_mismatch' }
            'runtime-error-corrupt' { 'runtime_failed' }
            'failed-corrupt' { 'execution_failed' }
            'timeout-corrupt' { 'timed_out' }
            'preflight-failed' { 'environment_failed' }
            default { 'stage_completed' }
        }
        Assert (($null -eq $runError) -eq ($expected -eq 'stage_completed')) "$mode entrypoint must explicitly report failed conditions: $runError"
        $reportIndex = Get-Content (Join-Path $run 'report.json') -Raw | ConvertFrom-Json -AsHashtable
        $progress = Get-Content (Join-Path $run 'progress.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($progress.phase -eq 'finished' -and $progress.updatedAt) 'Durable progress must identify completion even when conditions fail.'
        Assert ($reportIndex.conditions.Count -eq $models.Count -and $null -ne $reportIndex.timing.durationSeconds) 'Every model must have an indexed report with a measured run duration.'
        foreach ($condition in $comparison.conditions) {
            $state = Get-Content (Join-Path $condition.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ($state.outcome -eq $expected) "$mode expected $expected, got $($state.outcome): $($state.errors -join '; ')"
            Assert ($state.calls -eq [int]($mode -ne 'preflight-failed')) "$mode must never retry a paid invocation."
            $conditionConfig = Get-Content $condition.configFile -Raw | ConvertFrom-Json -AsHashtable
            Assert ($state.requestedReasoningEffort -ceq $expectedEffort -and
                $condition.requestedReasoningEffort -ceq $expectedEffort -and
                $conditionConfig.requestedReasoningEffort -ceq $expectedEffort) 'Condition and result must preserve the requested effort.'
            if ($state.calls -eq 1) {
                $turnMeta = Get-Content (Join-Path $state.capture.turnDirectory 'turn.json') -Raw | ConvertFrom-Json -AsHashtable
                $effortIndex = [Array]::IndexOf($turnMeta.command.arguments, '--reasoning-effort')
                if ($expectedEffort) {
                    Assert ($effortIndex -ge 0 -and $turnMeta.command.arguments[$effortIndex + 1] -ceq $expectedEffort) 'Captured command must contain the requested reasoning effort.'
                } else {
                    Assert ($effortIndex -eq -1) 'Omitted effort must preserve CLI defaults.'
                }
            }
            Assert ($null -eq $state.scoring.modelScore) 'Dev must never invent a model score.'
            $report = Get-Content (Join-Path $condition.runDirectory 'report.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ((Test-Path (Join-Path $condition.runDirectory 'summary.md')) -and
                $report.status.execution -eq $state.statusSummary.execution -and
                $report.timing.preparationDurationSeconds -ge 0 -and $report.timing.conditionFinishedAt) 'Automatic detailed reports must preserve states and recorded timings.'
            Assert ($condition.statusSummary.tests -eq $state.statusSummary.tests -and
                $condition.statusSummary.capture -eq $state.statusSummary.capture -and
                $condition.statusSummary.execution -eq $state.statusSummary.execution) 'Comparison must expose all status dimensions.'
            if ($state.verification -and $state.verification.passed) {
                $stateCopy = Join-Path (Split-Path $condition.configFile) 'verification\product\.runtime\state.txt'
                Assert ((Get-Content -LiteralPath $stateCopy -Raw).Trim() -eq 'frozen-state') 'Verification must use its own copied runtime state.'
            }
            if ($mode -like '*corrupt*') {
                $turn = $state.capture.turnDirectory
                $diagnostics = Get-Content (Join-Path $turn 'capture-diagnostics.json') -Raw | ConvertFrom-Json
                Assert ($diagnostics.invalidRecords.Count -eq 2 -and -not $state.capture.complete) 'All corrupt records must be reported.'
                Assert (Test-Path (Join-Path $turn 'runtime.json')) 'Corrupt output must retain usable runtime evidence.'
                Assert ($state.scoring.regressionPassRate -eq 100) 'Malformed CLI logs must not alter independent regression results.'
                if ($mode -in @('corrupt', 'corrupt-recovered', 'tests-failed-corrupt')) {
                    Assert ($state.capture.nonBlocking -and $state.warnings.Count -eq 1 -and
                        $report.warnings[0].code -eq 'stdout_json_damage' -and $report.captureNonBlocking -and
                        $comparison.conditions[0].warnings.Count -eq 1) 'Advisory capture damage must remain visible in results, comparison and reports.'
                }
                if ($mode -eq 'tests-failed-corrupt') {
                    Assert (-not $state.verification.passed -and $state.verification.checks[1].failures -eq 1) 'Capture warnings must not hide independently failing feature tests.'
                }
                if ($mode -eq 'corrupt-recovered') {
                    Assert ($diagnostics.recoveredEventCount -eq 1) 'Canonical recovery must retain the missing final event.'
                    Assert (@(Get-Content (Join-Path $turn 'assistant-messages.json') -Raw | ConvertFrom-Json).Count -eq 1) 'Recovered public response must be retained.'
                }
                if ($mode -eq 'timeout-corrupt') { Assert ($state.execution.timedOut -and $state.execution.collectorExitCode -eq 124) 'Malformed output must not overwrite timeout.' }
                if ($mode -eq 'failed-corrupt') { Assert ($state.execution.cliExitCode -eq 7 -and $state.execution.collectorExitCode -eq 7) 'Malformed output must not overwrite CLI exit code.' }
            }
            if ($mode -eq 'tamper') {
                Assert ($state.verification.checks[0].failures -eq 0 -and $state.verification.checks[1].failures -eq 1 -and
                    $state.historicalVerification.checks[0].failures -eq 1) 'Latest, trusted acceptance and historical failures must remain separate.'
            }
            if ($mode -eq 'test-timeout') {
                Assert ($state.verification.checks[0].state -eq 'timed_out') 'Independent tests must also be bounded.'
            }
            if ($mode -eq 'regression-only') {
                Assert (-not $state.acceptanceConfigured -and $null -eq $state.acceptanceVerified -and
                    $null -eq $state.scoring.acceptancePassRate) 'Regression-only results must not claim feature acceptance.'
            }
            if ($mode -eq 'updated-regression') {
                Assert ($state.verification.passed -and -not $state.historicalVerification.passed -and
                    $state.verification.testBaseline -eq 'candidate-latest') 'Updated requirement tests must gate Dev; historical semantic conflicts remain nonblocking evidence.'
            }
        }
        $after = if (Test-Path $env:DEV_RUN_COUNTER) { @(Get-Content $env:DEV_RUN_COUNTER).Count } else { 0 }
        Assert (($after - $before) -eq $(if ($mode -eq 'preflight-failed') { 0 } else { $models.Count })) 'Actual CLI invocation count must match the bounded contract.'
        Assert ((Get-Content (Join-Path $source '.runtime\state.txt') -Raw).Trim() -eq 'frozen-state') 'Runtime source must remain unchanged.'
        if ($mode -in @('success', 'corrupt')) {
            $offline = Join-Path $run 'offline'
            & (Join-Path $framework 'tools\Invoke-DevReverification.ps1') `
                -ConditionDirectory (Split-Path $comparison.conditions[0].configFile) -OutputDirectory $offline | Out-Null
            $offlineResult = Get-Content (Join-Path $offline 'result.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ($offlineResult.outcome -eq 'offline_tests_passed' -and $offlineResult.sourceIntegrityVerified -and
                $offlineResult.modelInvocationsThisRun -eq 0 -and $offlineResult.statusSummary.tests -eq 'passed') 'Offline verification must be real, bounded and leave source unchanged.'
            Assert ($offlineResult.statusSummary.capture -eq $comparison.conditions[0].statusSummary.capture -and
                $offlineResult.originalOutcome -eq $expected) 'Offline passing tests cannot rewrite original capture status or outcome.'
            Assert (@(Get-Content $env:DEV_RUN_COUNTER).Count -eq $after) 'Offline verification must not invoke the model.'
            $updatedReport = Get-Content (Join-Path $comparison.conditions[0].runDirectory 'report.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ($updatedReport.offlineVerifications.Count -eq 1 -and $updatedReport.offlineVerifications[0].startedAt -and
                $updatedReport.offlineVerifications[0].incrementalAiCredits -eq 0) 'Offline verification must update model and root reports without charging inherited usage.'
        }
        if ($mode -eq 'success') {
            $pipeline = Get-Content (Join-Path $run 'pipeline.json') -Raw | ConvertFrom-Json -AsHashtable
            $testComparison = Get-Content (Join-Path $pipeline.testRun 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ($pipeline.testState -eq 'backend_tests_passed' -and $testComparison.conditions.Count -eq 4 -and
                -not $pipeline.fullQaCompleted) 'Dev x Test pipeline must create four independent backend conditions, never claim full QA.'
            $first = Join-Path (Split-Path $comparison.conditions[0].configFile) 'product\.runtime\state.txt'
            'mutated-copy' | Set-Content $first
            $second = Join-Path (Split-Path $comparison.conditions[1].configFile) 'product\.runtime\state.txt'
            Assert ((Get-Content $second -Raw).Trim() -eq 'frozen-state') 'Models must not share writable runtime files.'
        }
        if ($mode -eq 'preflight-failed') { 'answer = 1' | Set-Content (Join-Path $source 'answer.py') }
        Write-Host "PASS: Dev $mode"
    }
    Assert ((Get-Content (Join-Path $source 'answer.py') -Raw).Trim() -eq 'answer = 1') 'Original source must remain unchanged.'
    Write-Host 'PASS: independent Dev execution, frozen regression/acceptance, runtime copies, one-shot budgets and failure evidence.'
} finally {
    $env:DEV_RUN_FIXTURE = $savedMode
    $env:DEV_RUN_COUNTER = $savedCounter
    $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = $savedAutoload
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
