#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) {
    [void](New-Item -ItemType Directory -Path (Split-Path $Path) -Force)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dev-report-' + [guid]::NewGuid().ToString('N'))
$exporter = Join-Path $PSScriptRoot '..\tools\Export-DevReport.ps1'
try {
    $checks = @{ passed = $false; error = $null; checks = @(
        @{ name = 'regression'; state = 'failed'; total = 87; passCount = 70; failures = 17; errors = 0; skipped = 0
            execution = @{ exitCode = 1; durationSeconds = 27.03 }; command = @{ executable = 'python'; arguments = @('-m', 'pytest') } }
    ) }
    $result = @{
        outcome = 'capture_incomplete'; model = 'model-one'; calls = 2; observedModels = @('model-one')
        capture = @{ complete = $false; errors = @('Malformed stdout'); state = 'capture_incomplete' }
        execution = @{ cliExitCode = 0; timedOut = $false; durationSeconds = 919.04 }
        verification = $checks; preflight = $checks; acceptanceConfigured = $false; protectedChanges = @()
        changedFiles = @(
            @{ path = 'src\app.py'; before = 'a'; after = 'b' },
            @{ path = 'tests/test_auth.py'; before = 'a'; after = 'b' },
            @{ path = 'src/__pycache__/app.pyc'; before = $null; after = 'b' }
        ); errors = @()
    }
    $one = Join-Path $fixture 'condition-one\dev'
    $two = Join-Path $fixture 'condition-two\dev'
    Write-Json (Join-Path $one 'result.json') $result
    $result.calls = 1; $result.model = 'model-two'; $result.observedModels = @('model-two')
    Write-Json (Join-Path $two 'result.json') $result
    foreach ($directory in @($one, $two)) {
        Write-Json (Join-Path (Split-Path $directory) 'config.json') @{ initialRequest = 'Implement approved design.' }
    }
    Write-Json (Join-Path $fixture 'comparison.json') @{
        stage = 'dev'; state = 'conditions_failed'; conditions = @(
            @{ name = 'condition-one'; runDirectory = $one }, @{ name = 'condition-two'; runDirectory = $two }
        )
    }
    $start = @{ type = 'tool.execution_start'; id = 'start'; timestamp = '2026-10-16T07:48:00Z'
        data = @{ toolCallId = 'test'; toolName = 'powershell'; arguments = @{ command = 'python -m pytest tests -q' } } }
    $complete = @{ type = 'tool.execution_complete'; id = 'complete'; timestamp = '2026-10-16T07:49:00Z'
        data = @{ toolCallId = 'test'; success = $true; shellExecution = @{ exitCode = 1 }; result = @{ content = '1 failed, 42 passed in 2.3s' } } }
    $unknown = @{ type = 'tool.execution_complete'; id = 'unknown'; timestamp = '2026-10-16T07:50:00Z'
        data = @{ toolCallId = 'unknown'; success = $true; result = @{ content = '114 passed in 31.59s' } } }
    $message = @{ type = 'assistant.message'; id = 'public'; timestamp = '2026-10-16T07:51:00Z'
        data = @{ content = 'Public delivery statement.'; toolRequests = @(); reasoningText = 'PRIVATE_SENTINEL' } }
    foreach ($index in 1..2) {
        $turn = Join-Path $one "capture\turn-0$index"
        Write-Json (Join-Path $turn 'turn.json') @{
            sessionId = 'same-session'; requestedAgent = 'developer'; startedAt = '2026-10-16T07:41:21Z'
            finishedAt = '2026-10-16T07:56:56Z'; cliVersion = 'fixture'
        }
        Write-Json (Join-Path $turn 'usage.json') @{
            totalNanoAiu = $(if ($index -eq 1) { 1000000000 } else { 8217935000 }); aiCreditsStatus = 'complete'
            totalUserRequests = 1; totalApiDurationMs = 695387
            modelMetrics = @{ 'model-one' = @{ requests = @{ count = 51 }; totalNanoAiu = 8217935000 } }
            agentMetrics = @{ main = @{ totalNanoAiu = 8217935000 } }
        }
    }
    $turn = Join-Path $one 'capture\turn-02'
    @($start, $complete, $unknown, $message) | ForEach-Object { $_ | ConvertTo-Json -Depth 15 -Compress } |
        Set-Content (Join-Path $turn 'session.events.jsonl')
    @($start, $complete) | ForEach-Object { $_ | ConvertTo-Json -Depth 15 -Compress } |
        Set-Content (Join-Path $turn 'events.stdout')
    Add-Content (Join-Path $turn 'events.stdout') 'broken JSON'
    $offlinePath = Join-Path $fixture 'offline-001'
    $offline = (Get-Content (Join-Path $one 'result.json') -Raw | ConvertFrom-Json -AsHashtable)
    $offline.offline = $true; $offline.sourceResult = Join-Path $one 'result.json'
    $offline.modelInvocationsThisRun = 0; $offline.sourceIntegrityVerified = $true
    $offline.testBaseline = Join-Path $offlinePath 'inputs\test-baseline'
    $offline.verification.passed = $true
    $offline.verification.checks[0].state = 'passed'; $offline.verification.checks[0].passCount = 87
    $offline.verification.checks[0].failures = 0; $offline.verification.checks[0].execution.exitCode = 0
    Write-Json (Join-Path $offlinePath 'result.json') $offline
    Write-Json (Join-Path $offlinePath 'manifest.json') @{ originalResultSha256 = (Get-FileHash (Join-Path $one 'result.json')).Hash }
    $before = (Get-FileHash (Join-Path $one 'result.json')).Hash
    & $exporter -RunDirectory $fixture -ReverificationDirectory @($offlinePath)
    $report = Get-Content (Join-Path $one 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($report.usage.aiCredits -eq 8.217935 -and $report.usage.snapshots.Count -eq 1 -and $report.usage.status -eq 'complete') 'Session cumulative snapshots and nested metrics must not be double counted.'
    Assert ($report.usage.snapshots[0].modelRequests -eq 51 -and $report.calls -eq 2) 'CLI calls and internal model requests must stay distinct.'
    Assert ($report.timeline.Count -eq 2 -and $report.timeline[0].status -eq 'failed' -and $report.timeline[1].status -eq 'unconfirmed') 'Deduplication and real command evidence must control milestone status.'
    Assert ($report.timeline[0].testCounts.failed -eq 1 -and $report.timeline[1].testCounts.passed -eq 114) 'Self-test counts must be extracted, not inferred from final prose.'
    Assert ($report.status.tests -eq 'failed' -and $report.offlineVerifications[0].status.tests -eq 'passed' -and
        $report.offlineVerifications[0].status.capture -eq 'incomplete') 'Offline checks must not overwrite initial tests or inherited capture.'
    Assert ($report.checks.Count -eq 3 -and $report.changes[2].category -eq 'generated') 'Layered evidence and generated files must remain distinct.'
    Assert ($null -eq $report.timing.preparationDurationSeconds -and $report.timing.captureDurationSeconds -eq 935) 'Unknown durations must not be fabricated.'
    $markdown = Get-Content (Join-Path $one 'summary.md') -Raw
    Assert ($markdown.Contains('2026-10-16 15:41:21') -and $markdown.Contains('8.22 AIC') -and
        $markdown.Contains('Public delivery statement.') -and -not $markdown.Contains('PRIVATE_SENTINEL')) 'Readable report must show local time, usage and only public content.'
    Assert ($markdown.Contains('后端门禁通过不代表前端基本验证已完成') -and
        -not $markdown.Contains('浏览器/E2E 和前端验证不属于本次 Dev 门禁')) 'Reports must distinguish backend gates from required Dev frontend self-tests.'
    Assert ((Get-Content (Join-Path $one 'report.json') -Raw) -notmatch 'PRIVATE_SENTINEL') 'Structured reports must not export private reasoning.'
    $index = Get-Content (Join-Path $fixture 'summary.md') -Raw
    Assert ($index.Contains('condition-one/dev/summary.md') -and $index.Contains('condition-two/dev/summary.md')) 'Comparison index must link every model summary with portable paths.'
    $aggregate = Get-Content (Join-Path $fixture 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($aggregate.usage.aiCredits -eq 8.217935 -and $aggregate.usage.status -eq 'partial') 'Comparison totals with unknown model usage must be explicitly partial.'
    $missing = Get-Content (Join-Path $two 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($missing.usage.status -eq 'unavailable' -and $null -eq $missing.usage.aiCredits) 'Missing usage must not become zero.'
    & $exporter -RunDirectory $fixture
    $replayed = Get-Content (Join-Path $one 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($replayed.offlineVerifications.Count -eq 1 -and (Get-FileHash (Join-Path $one 'result.json')).Hash -eq $before) 'Regeneration must preserve associations and original evidence.'
    $usage = Get-Content (Join-Path $turn 'usage.json') -Raw | ConvertFrom-Json -AsHashtable
    $usage.aiCreditsStatus = 'partial'
    Write-Json (Join-Path $turn 'usage.json') $usage
    & $exporter -RunDirectory $one
    $partial = Get-Content (Join-Path $one 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($partial.usage.status -eq 'partial' -and $partial.usage.aiCredits -eq 8.217935) 'Partial usage must remain explicitly partial.'
    $zero = Get-Content (Join-Path $two 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    $zero.calls = 0
    Write-Json (Join-Path $two 'result.json') $zero
    & $exporter -RunDirectory $two
    $notUsed = Get-Content (Join-Path $two 'report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($notUsed.usage.status -eq 'not_used' -and $notUsed.usage.aiCredits -eq 0) 'No invocation is distinguishable from missing usage.'
    Write-Json (Join-Path $offlinePath 'manifest.json') @{ originalResultSha256 = 'wrong' }
    $rejected = $false
    try { & $exporter -RunDirectory $fixture } catch { $rejected = $_.Exception.Message.Contains('source hash') }
    Assert $rejected 'Unmatched offline source hashes must be rejected explicitly.'
    Write-Host 'PASS: Dev multi-model reports, timeline evidence, usage deduplication, offline lineage and immutable results.'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
