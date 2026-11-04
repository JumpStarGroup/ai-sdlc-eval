#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reporter = Join-Path (Split-Path $PSScriptRoot) 'tools/Export-PmReport.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('pm-report-test-' + [guid]::NewGuid().ToString('N'))
$runPath = Join-Path $fixture 'run-001'

function Assert($Condition, $Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Save-Json($Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Export-Fixture {
    & $reporter -RunDirectory $fixture
    return Get-Content (Join-Path $fixture 'report.json') -Raw | ConvertFrom-Json -AsHashtable
}

try {
    [void](New-Item -ItemType Directory -Path $runPath -Force)
    Save-Json (Join-Path $fixture 'experiment.json') @{ state = 'paused'; simulatorModel = 'fixture-user' }
    Save-Json (Join-Path $runPath 'result.json') @{
        model = 'fixture-pm'; simulatorStyle = 'restrained'; state = 'paused'; stopReason = 'operator_checkpoint'
        evaluation = 'not_scored'; rounds = 2; errors = @()
        transcript = @(@{ role = 'user'; content = 'Initial request' }, @{ role = 'assistant'; content = 'Question' },
            @{ role = 'user'; content = 'Approved answer' }, @{ role = 'assistant'; content = 'Follow-up question' })
        decisions = @(@{ round = 1; decision = @{ action = 'answer'; reason = 'Private reason' } })
    }
    foreach ($role in @('pm', 'simulator')) {
        foreach ($number in @(1, 2)) {
            $turnPath = Join-Path $runPath "$role/turn-0$number"
            [void](New-Item -ItemType Directory -Path $turnPath -Force)
            Save-Json (Join-Path $turnPath 'turn.json') @{ sessionId = "$role-session" }
            Save-Json (Join-Path $turnPath 'usage.json') @{
                totalNanoAiu = 1000 * $number; totalPremiumRequestCost = $number
                tokenDetails = @{ input = @{ tokenCount = 10 * $number }; cache_read = @{ tokenCount = 20 * $number }
                    cache_write = @{ tokenCount = 30 * $number }; output = @{ tokenCount = 5 * $number } }
                modelMetrics = @{ "$role-model" = @{ usage = @{ inputTokens = 99999 } } }
            }
        }
    }
    $roundPath = Join-Path $runPath 'round-01'
    [void](New-Item -ItemType Directory -Path $roundPath -Force)
    $exactInput = '{"oracle":{"private":"rules"},"latestPmReply":"Question"}'
    $exactOutput = '{"action":"answer","reason":"Private reason"}'
    $exactInput | Set-Content (Join-Path $roundPath 'simulator-input.json') -NoNewline
    Save-Json (Join-Path $roundPath 'simulator-input.json.call.json') @{ turn = 'C:\old-location\run-001\simulator\turn-01' }
    Save-Json (Join-Path $runPath 'simulator/turn-01/assistant-messages.json') @(@{ content = $exactOutput })
    $export = Export-Fixture
    Assert ($null -eq $export.completionPolicyVersion -and $null -eq $export.runs[0].completionPolicyVersion) 'Historical reports are not relabelled with the new completion policy'
    Assert ($export.runs[0].pendingItems.Count -eq 0 -and $export.runs[0].requirementsStatus -ceq 'not_recorded') 'Historical results without pending fields remain readable, not assumed resolved'
    Assert ($export.runs[0].attemptedRounds -eq 2 -and $export.runs[0].agentReplies -eq 2 -and $export.runs[0].simulatorDecisions -eq 1) 'Attempt, reply and decision counts are distinct'
    Assert ($export.usage.totalTokens -eq 260 -and $export.usage.inputTokens -eq 240 -and $export.usage.outputTokens -eq 20) 'Latest cumulative snapshot only; input includes cache exactly once'
    Assert ($export.usage.premiumRequests -eq 4 -and $export.usage.nanoAiu -eq 4000 -and $export.usage.aiCredits -eq 0.000004d) 'NanoAIU converts to credits without conflating premium requests'
    Assert ($export.runs[0].usage.pm.aiCredits -eq 0.000002d -and $export.runs[0].usage.simulator.aiCredits -eq 0.000002d) 'Per-role credits use final cumulative snapshots'
    Assert ($export.runs[0].usage.pm.models[0] -ceq 'pm-model' -and $export.runs[0].usage.simulator.models[0] -ceq 'simulator-model') 'Models come from actual usage metrics'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('| pm | pm-model |') -and $markdown.Contains('| simulator | simulator-model |')) 'Both concrete models are visible in the summary'
    Assert ($markdown.Contains('| AI Credits |') -and -not $markdown.Contains('| nanoAIU |')) 'Readable summary uses credits; raw units stay in JSON'
    Assert ($export.runs[0].rounds[0].simulatorInput -ceq $exactInput -and $export.runs[0].rounds[0].simulatorOutput -ceq $exactOutput) 'Exact simulator I/O survives relocated evidence paths'
    Assert ($export.runs[0].rounds[0].forwardedToAgent -ceq 'Approved answer' -and $null -eq $export.runs[0].rounds[1].forwardedToAgent) 'Only actual forwarded text is reported'
    $beforeReport = (Get-FileHash (Join-Path $fixture 'report.json')).Hash
    $export = Export-Fixture
    Assert ((Get-FileHash (Join-Path $fixture 'report.json')).Hash -ceq $beforeReport) 'Offline export is deterministic'
    $result = Get-Content (Join-Path $runPath 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($null -eq $export.runs[0].warningCount) 'Historical results without warnings do not imply clean execution'
    $result.errorPolicyVersion = 'local-read-errors-v2'
    $result.warnings = @(@{ round = 1; role = 'pm'; evidence = 'private-turn'; warning = @{ eventId = 'read-failure'; toolName = 'view'; arguments = @{ path = 'empty.md'; view_range = @(1, 180) }; data = @{ error = @{ message = 'view_range out of bounds' } }; continuationReason = 'Subsequent final root reply'; finalResponseEventId = 'final' } })
    Save-Json (Join-Path $runPath 'result.json') $result
    $export = Export-Fixture
    Assert ($export.runs[0].warningCount -eq 1 -and $export.runs[0].rounds[0].warnings[0].warning.finalResponseEventId -eq 'final') 'Warning count and final-response evidence survive export'
    Assert ($export.runs[0].rounds[1].warnings.Count -eq 0) 'Warnings attach only to their actual round'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('view_range out of bounds') -and $markdown.Contains('Recorded read warnings: **1**') -and $markdown.Contains('continuationReason')) 'Readable report preserves errors, parameters and continuation rationale'
    $result.requirementsStatus = 'pending_decisions'
    $result.completionPolicyVersion = 'clarification-completion-v1'
    Save-Json (Join-Path $fixture 'experiment.json') @{ state = 'paused'; simulatorModel = 'fixture-user'; completionPolicyVersion = 'clarification-completion-v1' }
    $result.pendingItems = @(@{ id = 'post_update_destination'; question = 'Which page?'; impact = 'Navigation only'; owner = 'Unassigned'; confirmBefore = 'Before implementation'; status = 'pending'; blocksDiscussion = $false; firstRound = 1; lastRound = 2 })
    Save-Json (Join-Path $runPath 'result.json') $result
    $export = Export-Fixture
    Assert ($export.completionPolicyVersion -ceq 'clarification-completion-v1' -and $export.runs[0].completionPolicyVersion -ceq $export.completionPolicyVersion) 'New reports expose the recorded completion policy'
    Assert ($export.runs[0].pendingItems[0].confirmBefore -ceq 'Before implementation' -and $export.runs[0].requirementsStatus -ceq 'pending_decisions') 'Pending ledger survives report export'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('pending decisions: **1**') -and $markdown.Contains('drafts only') -and $markdown.Contains('Which page?')) 'Readable report exposes unresolved questions and their limits'
    Assert ($markdown.Contains('Completion policy: clarification-completion-v1.')) 'Readable report identifies the stop policy'
    $result.completionOutcome = 'pending_confirmation'
    $result.pendingDraftCheck = @{ ready = $true; reason = 'pending_draft_verified'; pendingCount = 1; documentPath = 'draft.md' }
    Save-Json (Join-Path $runPath 'result.json') $result
    $export = Export-Fixture
    Assert ($export.runs[0].completionOutcome -eq 'pending_confirmation' -and $export.runs[0].pendingDraftCheck.ready -and $export.runs[0].pendingItems.Count -eq 1) 'Pending-draft terminal outcome preserves unresolved decisions'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('not full completion') -and $markdown.Contains('Pending-draft verification')) 'Readable report never presents pending draft as fully complete'
    $result.guidedCoverage = @{ ready = $false; requiredAnswerIds = @('login_entry', 'username_case'); missingAnswerIds = @('username_case'); pendingCount = 0; documentPath = $null; reason = 'missing_answers' }
    $result.decisions[0].decision = @{ action = 'pm_complete'; answerIds = @(); quote = 'Question'; reason = 'Incorrect fixture claim' }
    $result.decisions[0].controllerDecision = @{ action = 'ask_followup'; questionId = 'login_identity' }
    $result.decisions[0].completionCheck = $result.guidedCoverage
    Save-Json (Join-Path $runPath 'result.json') $result
    $export = Export-Fixture
    Assert (-not $export.runs[0].guidedCoverage.ready -and $export.runs[0].guidedCoverage.missingAnswerIds[0] -ceq 'username_case') 'Report preserves incomplete coverage'
    Assert ($export.runs[0].rounds[0].validatedDecision.action -ceq 'pm_complete' -and $export.runs[0].rounds[0].controllerDecision.action -ceq 'ask_followup') 'Raw model claim and controller override remain distinguishable'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('missing required answers: **1**') -and $markdown.Contains('Controller continuation decision')) 'Readable report explains why guided continued'
    $result.completionAssessment = @{ neutralProbeCount = 1; artifactStatus = 'claimed_produced'; clarificationStatus = 'unresolved_reported' }
    $result.assessments = @{ capability = 'not_scored'; domain = 'not_scored' }
    $result.profiles = @{ capability = @{ id = 'planning'; version = '1' }; domain = @{ id = 'enterprise'; version = '2' }; targetAgent = 'fixture-plan'; simulatorAgent = 'fixture-stakeholder' }
    $result.pendingItems = @()
    Save-Json (Join-Path $runPath 'result.json') $result
    $export = Export-Fixture
    Assert ($export.runs[0].completionAssessment.clarificationStatus -eq 'unresolved_reported' -and $export.runs[0].pendingItems.Count -eq 0) 'Reported unknowns remain visible even without registered decisions'
    Assert ($export.runs[0].profiles.targetAgent -eq 'fixture-plan' -and $export.runs[0].assessments.capability -eq 'not_scored' -and $export.runs[0].assessments.domain -eq 'not_scored') 'Agent capability and domain assessment identities remain separate'
    $markdown = Get-Content (Join-Path $fixture 'report.md') -Raw
    Assert ($markdown.Contains('Artifact status: **claimed_produced**') -and $markdown.Contains('neutral probes delivered: **1**') -and $markdown.Contains('zero does not prove absence')) 'Report distinguishes stopping, artifact claims and clarification'
    Save-Json (Join-Path $runPath 'pm/turn-02/turn.json') @{ sessionId = 'new-pm-session' }
    $export = Export-Fixture
    Assert ($export.usage.totalTokens -eq 325) 'Distinct sessions are summed'
    Assert ($export.usage.aiCredits -eq 0.000005d) 'Credits sum across distinct sessions, not cumulative turns'
    Remove-Item (Join-Path $runPath 'simulator/turn-02/usage.json')
    $export = Export-Fixture
    Assert ($null -eq $export.usage.totalTokens -and $null -eq $export.runs[0].usage.simulator.totalTokens) 'Missing final snapshot is unknown, not stale or zero'
    Assert ($null -eq $export.usage.aiCredits) 'Missing credit evidence remains unknown'
    '{invalid' | Set-Content (Join-Path $runPath 'simulator/turn-02/usage.json')
    $export = Export-Fixture
    Assert ($export.runs[0].usage.simulator.sessions[0].status -ceq 'unavailable') 'Malformed usage preserves the dialogue report'
    Remove-Item (Join-Path $runPath 'simulator') -Recurse -Force
    $export = Export-Fixture
    Assert ($export.runs[0].usage.simulator.calls -eq 0 -and $null -eq $export.usage.totalTokens) 'Uncaptured role does not fabricate usage'
    Write-Host 'PASS: exact dialogue, cumulative usage, billing units, missing evidence and offline regeneration'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}