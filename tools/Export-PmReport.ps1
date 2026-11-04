#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RunDirectory).Path

function Read-Json($Path) {
    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    }
    return $null
}

function Read-Text($Path) {
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return $null
}

function Sum-Known($Items, $Key) {
    $values = @($Items)
    if (-not $values.Count -or @($values | Where-Object { $null -eq $_[$Key] }).Count) { return $null }
    return ($values | ForEach-Object { $_[$Key] } | Measure-Object -Sum).Sum
}

function Get-Usage($RunPath, $Role) {
    $sessions = @{}
    $calls = @(Get-ChildItem -LiteralPath (Join-Path $RunPath $Role) -Directory -Filter 'turn-*' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($call in $calls) {
        $meta = Read-Json (Join-Path $call.FullName 'turn.json')
        $session = if ($meta -and $meta['sessionId']) { $meta.sessionId } else { $call.Name }
        $sessions[$session] = $call
    }
    $snapshots = @()
    foreach ($session in ($sessions.Keys | Sort-Object)) {
        $call = $sessions[$session]
        $source = [IO.Path]::GetRelativePath($root, (Join-Path $call.FullName 'usage.json')).Replace('\', '/')
        $snapshot = [ordered]@{
            sessionId = $session; source = $source; status = 'unavailable'
            inputTokens = $null; outputTokens = $null; totalTokens = $null
            cacheReadTokens = $null; cacheWriteTokens = $null
            premiumRequests = $null; nanoAiu = $null; aiCredits = $null
            models = @()
        }
        try {
            $raw = Read-Json (Join-Path $call.FullName 'usage.json')
            if ($raw) {
                foreach ($mapping in @(@('premiumRequests', 'totalPremiumRequestCost'), @('nanoAiu', 'totalNanoAiu'))) {
                    $value = $raw[$mapping[1]]
                    if ($value -is [ValueType] -and $value -isnot [bool] -and $value -ge 0) {
                        $snapshot[$mapping[0]] = $value
                    }
                }
                if ($null -ne $snapshot.nanoAiu) {
                    $snapshot.aiCredits = [decimal]$snapshot.nanoAiu / 1000000000d
                }
                if ($raw['modelMetrics'] -is [System.Collections.IDictionary]) {
                    $snapshot.models = @($raw.modelMetrics.Keys | Sort-Object)
                }
                $details = $raw['tokenDetails']
                if ($details -is [System.Collections.IDictionary]) {
                    $counts = @{}
                    foreach ($category in @('input', 'cache_read', 'cache_write', 'output')) {
                        $entry = $details[$category]
                        if ($entry -is [System.Collections.IDictionary] -and
                            $entry['tokenCount'] -is [ValueType] -and $entry['tokenCount'] -isnot [bool] -and $entry.tokenCount -ge 0) {
                            $counts[$category] = $entry.tokenCount
                        }
                    }
                    $snapshot.cacheReadTokens = $counts['cache_read']
                    $snapshot.cacheWriteTokens = $counts['cache_write']
                    $snapshot.outputTokens = $counts['output']
                    if ($counts.ContainsKey('input') -and $counts.ContainsKey('cache_read') -and $counts.ContainsKey('cache_write')) {
                        $snapshot.inputTokens = $counts.input + $counts.cache_read + $counts.cache_write
                    }
                    if ($null -ne $snapshot.inputTokens -and $null -ne $snapshot.outputTokens) {
                        $snapshot.totalTokens = $snapshot.inputTokens + $snapshot.outputTokens
                    }
                }
                $snapshot.status = if ($null -ne $snapshot.totalTokens -and $null -ne $snapshot.nanoAiu -and $null -ne $snapshot.premiumRequests) { 'available' } else { 'partial' }
            }
        }
        catch { $snapshot['error'] = $_.Exception.Message }
        $snapshots += $snapshot
    }
    $total = [ordered]@{
        calls = $calls.Count; sessions = $snapshots
        models = @($snapshots | ForEach-Object { $_.models } | Sort-Object -Unique)
    }
    foreach ($key in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens', 'premiumRequests', 'nanoAiu', 'aiCredits')) {
        $total[$key] = Sum-Known $snapshots $key
    }
    return $total
}

function Format-Value($Value) {
    if ($null -eq $Value) { return 'Unknown' }
    return [string]$Value
}

function Add-Text($Lines, $Text, $Language = 'text') {
    if ($null -eq $Text) { $Lines.Add('_Not recorded / not called._'); return }
    $fence = '````'
    while ($Text.Contains($fence)) { $fence += '`' }
    $Lines.Add($fence + $Language)
    $Lines.Add($Text)
    $Lines.Add($fence)
}

$experiment = Read-Json (Join-Path $root 'experiment.json')
if (-not $experiment) { throw "Missing experiment.json: $root" }
$report = [ordered]@{
    schemaVersion = 1; state = $experiment.state; simulatorModel = $experiment['simulatorModel']
    localOnly = $experiment['localOnly']
    completionPolicyVersion = $experiment['completionPolicyVersion']
    profiles = $experiment['profiles']
    usagePolicy = 'Latest cumulative usage.json per session, summed across distinct sessions. Input includes cache reads/writes. Missing is null, not zero. AI Credits = totalNanoAiu / 1,000,000,000 (Copilot CLI 1.0.89-5 session accounting). Raw nanoAiu is retained in report.json. Premium requests are a separate metric, not AI Credits; session usage is not an invoice.'
    runs = @()
}
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Dialogue Report')
$lines.Add('')
$lines.Add('Private evaluation report: includes simulator decisions and private Oracle inputs. Do not supply to the tested Agent.')
$lines.Add('')
$lines.Add("Experiment: $($experiment.state). Simulator model: $($experiment['simulatorModel']).")
if ($experiment.Contains('localOnly')) { $lines.Add("Local-only workflow: $($experiment.localOnly).") }
if ($experiment.Contains('completionPolicyVersion')) { $lines.Add("Completion policy: $($experiment.completionPolicyVersion).") }
$lines.Add('One round = one tested-Agent call followed by a simulator decision, when reached. Attempts, replies and validated decisions are counted separately. Completion is not business acceptance.')
$lines.Add('')
foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -Filter 'run-*' | Sort-Object Name)) {
    $result = Read-Json (Join-Path $directory.FullName 'result.json')
    if (-not $result) { continue }
    $transcript = @($result.transcript)
    $decisions = @($result.decisions)
    $run = [ordered]@{
        name = $directory.Name; model = $result.model; simulatorStyle = $result['simulatorStyle']
        simulatorModel = $experiment['simulatorModel']
        localOnly = $result['localOnly']
        disclosedAnswerIds = @(if ($result.Contains('disclosedAnswerIds')) { $result.disclosedAnswerIds })
        protocolVersion = $result['protocolVersion']
        completionPolicyVersion = $result['completionPolicyVersion']
        completionOutcome = $result['completionOutcome']
        pendingDraftCheck = $result['pendingDraftCheck']
        guidedCoverage = $result['guidedCoverage']
        errorPolicyVersion = $result['errorPolicyVersion']
        warnings = @(if ($result.Contains('warnings')) { $result.warnings })
        warningCount = $(if ($result.Contains('warnings')) { @($result.warnings).Count } else { $null })
        completionAssessment = $result['completionAssessment']
        profiles = $result['profiles']
        assessments = $result['assessments']
        assessmentCriteria = $result['assessmentCriteria']
        state = $result.state; stopReason = $result.stopReason; evaluation = $result['evaluation']
        pendingItems = @(if ($result.Contains('pendingItems')) { $result.pendingItems })
        requirementsStatus = if ($result.Contains('requirementsStatus')) { $result.requirementsStatus } else { 'not_recorded' }
        attemptedRounds = $result.rounds
        agentReplies = @($transcript | Where-Object role -EQ 'assistant').Count
        simulatorDecisions = $decisions.Count
        usage = [ordered]@{ pm = (Get-Usage $directory.FullName 'pm'); simulator = (Get-Usage $directory.FullName 'simulator') }
        rounds = @(); errors = $result['errors']
    }
    $run.usage['total'] = [ordered]@{}
    foreach ($key in @('inputTokens', 'outputTokens', 'totalTokens', 'premiumRequests', 'nanoAiu', 'aiCredits')) {
        $run.usage.total[$key] = Sum-Known @($run.usage.pm, $run.usage.simulator) $key
    }
    $lines.Add("## $($run.name): $($run.model) / $($run.simulatorStyle)")
    $lines.Add('')
    $lines.Add("Rounds attempted: **$($run.attemptedRounds)**; Agent replies: **$($run.agentReplies)**; validated simulator decisions: **$($run.simulatorDecisions)**.")
    $lines.Add("State: **$($run.state)**; stop reason: **$($run.stopReason)**; evaluation: $($run.evaluation).")
    if ($null -ne $run.warningCount) {
        $lines.Add("Recorded read warnings: **$($run.warningCount)**; error policy: $(Format-Value $run.errorPolicyVersion).")
        if ($run.warningCount) {
            $lines.Add('Read warnings were retained; a subsequent final reply allowed this turn to continue subject to other fatal/model checks. This is not a clean execution or quality acceptance.')
        }
    }
    $lines.Add("Requirements status: **$($run.requirementsStatus)**; pending decisions: **$($run.pendingItems.Count)**.")
    if ($run.completionOutcome) { $lines.Add("Completion outcome: **$($run.completionOutcome)**.") }
    if ($run.completionOutcome -eq 'pending_confirmation') {
        $lines.Add('A draft retaining pending questions was verified. Human decisions remain outstanding; this is not full completion, approval or a passing score.')
    }
    if ($run.pendingDraftCheck) {
        $lines.Add('**Pending-draft verification**')
        Add-Text $lines (ConvertTo-Json -InputObject $run.pendingDraftCheck -Depth 20) 'json'
    }
    $lines.Add('Pending count covers registered decisions only; zero does not prove absence of unknowns or omissions.')
    if ($run.profiles) {
        $lines.Add("Capability: $($run.profiles.capability.id) / $($run.profiles.capability.version); domain: $($run.profiles.domain.id) / $($run.profiles.domain.version); tested Agent: $($run.profiles.targetAgent); simulator: $($run.profiles.simulatorAgent).")
    }
    if ($run.assessments) { $lines.Add("Capability assessment: **$($run.assessments.capability)**; domain assessment: **$($run.assessments.domain)**.") }
    if ($run.assessmentCriteria) {
        $lines.Add('Private evaluation dimensions (not instructions to the tested Agent):')
        Add-Text $lines (ConvertTo-Json -InputObject $run.assessmentCriteria -Depth 20) 'json'
    }
    if ($run.completionAssessment) {
        $assessment = $run.completionAssessment
        $lines.Add("Artifact status: **$($assessment.artifactStatus)**; clarification status: **$($assessment.clarificationStatus)**; neutral probes delivered: **$($assessment.neutralProbeCount)**.")
        $lines.Add('Agent claims are observations, not verified artifact quality, resolved decisions or a passing score.')
    }
    if ($run.guidedCoverage) {
        $coverage = $run.guidedCoverage
        $lines.Add("Guided completion gate: **$($coverage.reason)**; missing required answers: **$($coverage.missingAnswerIds.Count)**; verified document: $(Format-Value $coverage.documentPath).")
        if ($coverage.missingAnswerIds.Count) { $lines.Add("Missing answer IDs: $($coverage.missingAnswerIds -join ', ').") }
    }
    if ($run.pendingItems.Count) {
        $lines.Add('Pending decisions permit discussion and drafts only; they do not authorize defaults, implementation, acceptance or release.')
        Add-Text $lines (ConvertTo-Json -InputObject $run.pendingItems -Depth 20) 'json'
    }
    $lines.Add('')
    $lines.Add('| Role | Model | Input tokens (incl. cache) | Output tokens | Total tokens | Premium requests | AI Credits |')
    $lines.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: |')
    foreach ($role in @('pm', 'simulator', 'total')) {
        $usage = $run.usage[$role]
        $modelLabel = if ($role -eq 'total') { '-' }
            elseif ($usage.models.Count) { $usage.models -join ', ' }
            else {
                $configuredModel = if ($role -eq 'pm') { $run.model } else { $run.simulatorModel }
                "$(Format-Value $configuredModel) (configured; usage model unavailable)"
            }
        $values = @('inputTokens', 'outputTokens', 'totalTokens', 'premiumRequests', 'aiCredits') | ForEach-Object { Format-Value $usage[$_] }
        $lines.Add("| $role | $modelLabel | $($values -join ' | ') |")
    }
    $lines.Add('')
    $lines.Add($report.usagePolicy)
    $lines.Add('')
    foreach ($errorText in @($run.errors)) { Add-Text $lines $errorText }
    for ($number = 1; $number -le $result.rounds; $number++) {
        $roundPath = Join-Path $directory.FullName ('round-{0:d2}' -f $number)
        $offset = ($number - 1) * 2
        $inputText = Read-Text (Join-Path $roundPath 'pm-input.txt')
        if ($null -eq $inputText -and $offset -lt $transcript.Count) { $inputText = $transcript[$offset].content }
        $outputText = if ($offset + 1 -lt $transcript.Count) { $transcript[$offset + 1].content } else { $null }
        $selection = @($decisions | Where-Object round -EQ $number)
        $decision = if ($selection.Count) { $selection[0].decision } else { $null }
        $simulatorInput = Read-Text (Join-Path $roundPath 'simulator-input.json')
        $receipt = Read-Json (Join-Path $roundPath 'simulator-input.json.call.json')
        $simulatorOutput = $null
        if ($receipt -and $receipt['turn']) {
            $turnName = ($receipt.turn -split '[/\\]')[-1]
            $messages = @(Read-Json (Join-Path $directory.FullName "simulator/$turnName/assistant-messages.json"))
            if ($messages.Count -and $messages[-1]) { $simulatorOutput = $messages[-1].content }
        }
        $forwarded = if ($offset + 2 -lt $transcript.Count) { $transcript[$offset + 2].content } else { $null }
        $round = [ordered]@{
            round = $number; agentInput = $inputText; agentOutput = $outputText
            simulatorInput = $simulatorInput; simulatorOutput = $simulatorOutput
            validatedDecision = $decision; forwardedToAgent = $forwarded
            controllerDecision = $(if ($selection.Count) { $selection[0]['controllerDecision'] } else { $null })
            completionCheck = $(if ($selection.Count) { $selection[0]['completionCheck'] } else { $null })
            warnings = @($run.warnings | Where-Object round -EQ $number)
        }
        $run.rounds += $round
        $lines.Add("### Round $number")
        $lines.Add('')
        $lines.Add('**Tested Agent input**')
        Add-Text $lines $inputText
        $lines.Add('**Tested Agent output / simulator latest PM reply**')
        Add-Text $lines $outputText
        if ($round.warnings.Count) {
            $lines.Add('**Recorded read warnings and continuation evidence**')
            Add-Text $lines (ConvertTo-Json -InputObject $round.warnings -Depth 30) 'json'
        }
        $lines.Add('**Simulator output (validated decision)**')
        Add-Text $lines $(if ($decision) { ConvertTo-Json -InputObject $decision -Depth 20 } else { $simulatorOutput }) 'json'
        if ($round.completionCheck) {
            $lines.Add('**Controller completion check (a model claim alone does not establish sufficient clarification)**')
            Add-Text $lines (ConvertTo-Json -InputObject $round.completionCheck -Depth 20) 'json'
            if ($round.controllerDecision) {
                $lines.Add('**Controller continuation decision**')
                Add-Text $lines (ConvertTo-Json -InputObject $round.controllerDecision -Depth 20) 'json'
            }
        }
        $lines.Add('**User reply actually forwarded to the next Agent round**')
        if ($null -eq $forwarded) { $lines.Add('_None recorded. A stop/checkpoint decision is not a user reply._') }
        else { Add-Text $lines $forwarded }
        $lines.Add('')
        $lines.Add('<details><summary>Exact simulator request and raw output</summary>')
        $lines.Add('')
        $lines.Add('Request includes private Oracle, full dialogue and latest PM reply. Agent definitions and resumed session context remain in the original evidence.')
        Add-Text $lines $simulatorInput 'json'
        Add-Text $lines $simulatorOutput 'text'
        $lines.Add('')
        $lines.Add('</details>')
        $lines.Add('')
    }
    $report.runs += $run
}
$report['usage'] = [ordered]@{}
foreach ($key in @('inputTokens', 'outputTokens', 'totalTokens', 'premiumRequests', 'nanoAiu', 'aiCredits')) {
    $report.usage[$key] = Sum-Known @($report.runs | ForEach-Object { $_.usage.total }) $key
}
$lines.Add('## Evidence')
$lines.Add('')
$lines.Add('This report is a derived view. Original snapshots, call receipts, runtime logs and workspaces are unchanged. report.json contains structured rounds, usage and source paths. Unknown usage is not free usage; Premium requests are not AI Credits.')
foreach ($artifact in @(@{ name = 'report.json'; text = (ConvertTo-Json -InputObject $report -Depth 60) }, @{ name = 'report.md'; text = ($lines -join "`n") })) {
    $destination = Join-Path $root $artifact.name
    $temporary = "$destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $artifact.text)
        [IO.File]::Move($temporary, $destination, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
Write-Host "Report: $(Join-Path $root 'report.md')"