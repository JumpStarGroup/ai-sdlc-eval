#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [string[]]$ReverificationDirectory = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
$root = (Resolve-Path -LiteralPath $RunDirectory).Path
$diagnostics = [Collections.Generic.List[string]]::new()
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $arguments = @{ InputObject = (Get-Content -LiteralPath $Path -Raw -Encoding utf8); AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $arguments.DateKind = 'String' }
    return ConvertFrom-Json @arguments
}
function Relative([string]$Path) { [IO.Path]::GetRelativePath($root, $Path).Replace('\', '/') }
function Link([string]$Path, [string]$Label) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 'not available' }
    return "[$Label](<$(Relative $Path)>)"
}
function Cell($Value) {
    if ($null -eq $Value -or [string]$Value -eq '') { return 'unknown' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", '').Replace("`n", '<br>')
}
function Number($Value, [string]$Format = '0.##') {
    if ($null -eq $Value) { return 'unknown' }
    return ([decimal]$Value).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}
function Valid-Number($Value) {
    return $Value -is [ValueType] -and $Value -isnot [bool] -and $Value -ge 0
}
function Duration($Seconds) {
    if ($null -eq $Seconds) { return 'unknown' }
    $time = [TimeSpan]::FromMilliseconds([Math]::Round($Seconds * 1000))
    return '{0:00}:{1:00}:{2:00}.{3:000}' -f [int][Math]::Floor($time.TotalHours), $time.Minutes, $time.Seconds, $time.Milliseconds
}
function Time($Value) {
    if (-not $Value) { return 'unknown' }
    return ([DateTimeOffset]::Parse([string]$Value)).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
}
function Span($StartedAt, $FinishedAt) {
    if (-not $StartedAt -or -not $FinishedAt) { return $null }
    return ([DateTimeOffset]::Parse([string]$FinishedAt) - [DateTimeOffset]::Parse([string]$StartedAt)).TotalSeconds
}
function Write-Json([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Add-Text($Lines, [string]$Text) {
    $fence = '````'
    while ($Text.Contains($fence)) { $fence += '`' }
    $Lines.Add($fence + 'text'); $Lines.Add($Text); $Lines.Add($fence)
}
function Get-Usage($Turns, [int]$Calls) {
    $sessions = @{}
    foreach ($turn in $Turns) {
        $meta = Read-Json (Join-Path $turn.FullName 'turn.json')
        $id = if ($meta -and $meta['sessionId']) { $meta.sessionId } else { $turn.Name }
        $sessions[$id] = $turn
    }
    $snapshots = @()
    foreach ($id in ($sessions.Keys | Sort-Object)) {
        $path = Join-Path $sessions[$id].FullName 'usage.json'
        $raw = Read-Json $path
        $snapshot = @{
            sessionId = $id; source = $path; status = 'unavailable'; aiCredits = $null
            userRequests = $null; modelRequests = $null; apiDurationSeconds = $null
            inputTokens = $null; cacheReadTokens = $null; cacheWriteTokens = $null; outputTokens = $null
        }
        if ($raw) {
            if (Valid-Number $raw['totalNanoAiu']) {
                $snapshot.aiCredits = [decimal]$raw.totalNanoAiu / 1000000000d
                $snapshot.status = if ($raw['aiCreditsStatus'] -ceq 'complete') { 'complete' } else { 'partial' }
            }
            $snapshot.userRequests = $raw['totalUserRequests']
            if (Valid-Number $raw['totalApiDurationMs']) { $snapshot.apiDurationSeconds = $raw.totalApiDurationMs / 1000.0 }
            if ($raw['modelMetrics'] -and $raw.modelMetrics.Count) {
                $counts = @($raw.modelMetrics.Values | ForEach-Object { if ($_['requests']) { $_.requests['count'] } else { $null } })
                if ($counts.Count -eq $raw.modelMetrics.Count -and @($counts | Where-Object { -not (Valid-Number $_) }).Count -eq 0) {
                    $snapshot.modelRequests = ($counts | Measure-Object -Sum).Sum
                }
            }
            foreach ($pair in @(@('input', 'inputTokens'), @('cache_read', 'cacheReadTokens'),
                @('cache_write', 'cacheWriteTokens'), @('output', 'outputTokens'))) {
                if ($raw['tokenDetails'] -and $raw.tokenDetails[$pair[0]] -and
                    (Valid-Number $raw.tokenDetails[$pair[0]]['tokenCount'])) {
                    $snapshot[$pair[1]] = $raw.tokenDetails[$pair[0]].tokenCount
                }
            }
        }
        $snapshots += $snapshot
    }
    $known = @($snapshots | Where-Object { $null -ne $_.aiCredits })
    $status = if ($Calls -eq 0) { 'not_used' }
        elseif ($Turns.Count -ge $Calls -and $snapshots.Count -gt 0 -and
            @($snapshots | Where-Object status -ne 'complete').Count -eq 0) { 'complete' }
        elseif ($known.Count) { 'partial' } else { 'unavailable' }
    $sum = [decimal]0
    foreach ($snapshot in $known) { $sum += $snapshot.aiCredits }
    return @{
        status = $status; aiCredits = $(if ($Calls -eq 0) { 0 } elseif ($known.Count) { $sum } else { $null })
        snapshots = $snapshots; policy = 'Latest cumulative snapshot per session; no nested metric summation; CLI evidence, not an invoice.'
    }
}
function Get-Timeline($Turns) {
    $items = [Collections.Generic.List[object]]::new()
    $publicMessages = [Collections.Generic.List[object]]::new()
    foreach ($turn in $Turns) {
        $events = @{}
        foreach ($name in @('events.stdout', 'session.events.jsonl')) {
            $path = Join-Path $turn.FullName $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $lineNumber = 0; $bad = 0
            foreach ($line in [IO.File]::ReadLines($path)) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $event = ConvertFrom-Json -InputObject $line -AsHashtable }
                catch { $bad++; continue }
                if ($event['type'] -notin @('tool.execution_start', 'tool.execution_complete', 'assistant.message')) { continue }
                $key = if ($event['id']) { [string]$event.id } else { "$name-$lineNumber" }
                # Canonical records replace stdout duplicates without discarding stdout-only evidence.
                $events[$key] = @{ event = $event; source = $path; line = $lineNumber }
            }
            if ($bad) { $diagnostics.Add("$path : $bad malformed records excluded; original capture status unchanged.") }
        }
        $starts = @{}
        foreach ($record in @($events.Values | Sort-Object { $_.event['timestamp'] })) {
            $event = $record.event; $data = $event['data']
            if (-not $data) { continue }
            if ($event.type -eq 'tool.execution_start') { $starts[$data.toolCallId] = $data; continue }
            if ($event.type -eq 'assistant.message') {
                if ($data['content'] -and -not $data['toolRequests']) {
                    $publicMessages.Add(@{ timestamp = $event['timestamp']; content = $data.content; source = $record.source; eventId = $event['id'] })
                }
                continue
            }
            $start = $starts[$data['toolCallId']]
            $tool = if ($start) { $start['toolName'] } else { 'unknown' }
            $arguments = if ($start -and $start['arguments'] -is [System.Collections.IDictionary]) { $start.arguments } else { @{} }
            $command = $arguments['command']
            $output = if ($data['result'] -and $data.result -is [System.Collections.IDictionary]) { [string]$data.result['content'] } else { '' }
            $exitCode = if ($data['shellExecution']) { $data.shellExecution['exitCode'] } else { $null }
            if ($null -eq $exitCode -and $output -match '<shellId: [^\r\n]+ completed with exit code (-?\d+)>') { $exitCode = [int]$Matches[1] }
            $summaryMatches = [regex]::Matches($output, '(?m)^[=\s]*((?:\d+ (?:passed|failed|errors?|skipped|warnings?|deselected|xfailed|xpassed)(?:, )?)+)(?: in |[=\r\n]|$)')
            $summary = if ($summaryMatches.Count) { $summaryMatches[$summaryMatches.Count - 1].Groups[1].Value.Trim() } else { $null }
            $counts = @{}
            if ($summary) {
                foreach ($match in [regex]::Matches($summary, '(\d+) (passed|failed|errors?|skipped|warnings?|deselected|xfailed|xpassed)')) {
                    $counts[$match.Groups[2].Value] = [int]$match.Groups[1].Value
                }
            }
            $failed = $data['success'] -eq $false -or ($null -ne $exitCode -and $exitCode -ne 0)
            $kind = if ($summary -or $command -match '\bpytest\b') { 'agent_self_test' }
                elseif ($tool -in @('apply_patch', 'edit', 'create')) { 'code_change' }
                elseif ($failed) { 'tool_issue' }
                elseif ($command -match 'compileall|diff --check|json\.load') { 'static_check' }
                else { $null }
            if (-not $kind) { continue }
            $status = if ($failed) { 'failed' }
                elseif ($null -ne $exitCode -and $exitCode -eq 0) { 'completed' }
                elseif ($kind -eq 'code_change' -and $data['success'] -eq $true) { 'completed' }
                else { 'unconfirmed' }
            if ($summary -and ($counts['failed'] -gt 0 -or $counts['errors'] -gt 0 -or $counts['error'] -gt 0)) { $status = 'failed' }
            $paths = @()
            if ($kind -eq 'code_change') {
                if ($start['arguments'] -is [string]) {
                    $paths = @([regex]::Matches($start.arguments, '(?m)^\*\*\* (?:Add|Update|Delete) File: (.+)\r?$') |
                        ForEach-Object { $_.Groups[1].Value.Trim() })
                } else {
                    foreach ($key in @('path', 'filePath', 'file_path')) { if ($arguments[$key]) { $paths += $arguments[$key] } }
                }
            }
            $detail = if ($summary) { $summary } elseif ($command) { [string]$command }
                elseif ($paths.Count) { "$tool : $($paths -join ', ')" }
                elseif ($arguments['description']) { [string]$arguments.description } else { [string]$tool }
            $items.Add(@{
                timestamp = $event['timestamp']; kind = $kind; status = $status; detail = $detail
                command = $command; tool = $tool; exitCode = $exitCode; testCounts = $counts
                source = $record.source; sourceLine = $record.line; eventId = $event['id']; paths = $paths
            })
        }
    }
    return @{ items = $items.ToArray(); publicMessages = $publicMessages.ToArray() }
}
function Add-Checks($Rows, [string]$Layer, $Verification, [string]$Directory, [string]$Baseline, [bool]$Inherited = $false) {
    if (-not $Verification) { return }
    foreach ($check in $Verification.checks) {
        $Rows.Add(@{
            layer = $Layer; name = $check['name']; state = $check.state; total = $check.total; passed = $check.passCount
            failures = $check.failures; errors = $check.errors; skipped = $check.skipped
            durationSeconds = $(if ($check['execution']) { $check.execution['durationSeconds'] } else { $null })
            exitCode = $(if ($check['execution']) { $check.execution['exitCode'] } else { $null })
            command = $check['command']; baseline = $Baseline; inherited = $Inherited
            source = (Join-Path $Directory 'checks.json'); xml = (Join-Path $Directory "$($check['name']).xml")
        })
    }
}
$comparison = Read-Json (Join-Path $root 'comparison.json')
if ($comparison) {
    if ($comparison['stage'] -cne 'dev') { throw 'Expected a Dev comparison directory.' }
    $previous = Read-Json (Join-Path $root 'report.json')
    $offlinePaths = @($ReverificationDirectory)
    if ($previous -and $previous['reverificationDirectories']) { $offlinePaths += $previous.reverificationDirectories }
    $offlinePaths = @($offlinePaths | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction Stop).Path } | Sort-Object -Unique)
    foreach ($path in $offlinePaths) {
        $offline = Read-Json (Join-Path $path 'result.json')
        if (-not $offline -or -not $offline['offline'] -or -not $offline['sourceResult']) { throw "Not an offline Dev verification: $path" }
        $matches = @($comparison.conditions | Where-Object {
            [IO.Path]::GetFullPath((Join-Path $_.runDirectory 'result.json')) -ieq [IO.Path]::GetFullPath($offline.sourceResult)
        })
        if ($matches.Count -ne 1) { throw "Offline verification does not belong to exactly one condition: $path" }
    }
    $children = @()
    foreach ($condition in $comparison.conditions) {
        & $PSCommandPath -RunDirectory $condition.runDirectory -ReverificationDirectory $offlinePaths | Out-Null
        $children += Read-Json (Join-Path $condition.runDirectory 'report.json')
    }
    $knownUsage = @($children | Where-Object { $null -ne $_.usage.aiCredits })
    $totalCredits = [decimal]0
    foreach ($child in $knownUsage) { $totalCredits += $child.usage.aiCredits }
    $usageStatus = if ($children.Count -gt 0 -and @($children | Where-Object { $_.usage.status -notin @('complete', 'not_used') }).Count -eq 0) { 'complete' }
        elseif ($knownUsage.Count) { 'partial' } else { 'unavailable' }
    $totalUsage = @{ aiCredits = $(if ($knownUsage.Count) { $totalCredits } else { $null }); status = $usageStatus }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Dev 多模型测试汇总 / Dev comparison summary'); $lines.Add('')
    $lines.Add('本报告不进行模型主观评分。执行、采集、测试状态分别展示；离线复验追加证据，不覆盖原始结果。')
    $lines.Add('')
    $lines.Add("整轮开始：$(Time $comparison['startedAt'])；结束：$(Time $comparison['finishedAt'])；整轮时长（包含准备与验收）：$(Duration (Span $comparison['startedAt'] $comparison['finishedAt']))。历史缺失值不推算。")
    $lines.Add("本轮已知模型用量合计：$(Number $totalUsage.aiCredits) AIC；状态：$usageStatus。partial 表示仅部分用量已知，不能视为最终总费用。")
    $lines.Add('')
    $lines.Add('| 模型报告 | 请求 / 实际模型 | 采集开始 (UTC+08:00) | 开发 CLI 时长 | AIC / 用量状态 | 执行 | 采集 | 原独立测试 | 最近离线复验 | 业务验收 | 原结果 / 警告 |')
    $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($child in $children) {
        $latest = @($child.offlineVerifications | Select-Object -Last 1)
        $offlineText = if ($latest.Count) { "$($latest[0].status.tests): $($latest[0].status.passed)/$($latest[0].status.total)" } else { 'not run' }
        $status = $child.status
        $lines.Add("| $(Link (Join-Path $child.directory 'summary.md') $child.name) | $(Cell $child.model) / $(Cell ($child.observedModels -join ', ')) | $(Time $child.timing.captureStartedAt) | $(Duration $child.timing.cliDurationSeconds) | $(Number $child.usage.aiCredits) / $($child.usage.status) | $($status.execution) | $($status.capture) | $($status.tests): $($status.passed)/$($status.total) | $offlineText | $(if ($child.acceptanceConfigured) { 'configured; see checks' } else { 'not configured' }) | $($child.outcome) / $(@($child.warnings).Count) |")
    }
    $lines.Add(''); $lines.Add('AIC 来自 CLI 用量记录，不是账单；离线复验新增 0 AIC，原开发用量只计算一次。缺失用量不记为零。')
    $lines.Add('详细报告保留每次关联的复验及其基准，而非仅保留最近结果。显示时间为 UTC+08:00；JSON 保留原始时间。')
    Write-Json (Join-Path $root 'report.json') @{
        schemaVersion = 1; stage = 'dev'; generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        originalOutcome = $comparison.state; reverificationDirectories = $offlinePaths; usage = $totalUsage
        timing = @{ startedAt = $comparison['startedAt']; finishedAt = $comparison['finishedAt']; durationSeconds = (Span $comparison['startedAt'] $comparison['finishedAt']) }
        conditions = @($children | ForEach-Object { @{
            name = $_.name; model = $_.model; requestedFusionTier = $_.requestedFusionTier
            requestedAutoTier = $_.requestedAutoTier; observedModels = $_.observedModels
            report = (Join-Path $_.directory 'report.json'); status = $_.status; usage = $_.usage
            outcome = $_.outcome; warnings = $_.warnings
        } })
    }
    $lines | Set-Content -LiteralPath (Join-Path $root 'summary.md') -Encoding utf8
    return
}
$resultPath = Join-Path $root 'result.json'
$result = Read-Json $resultPath
if (-not $result) { throw "Missing Dev result: $resultPath" }
if ($result['offline']) { throw 'Generate the original Dev report and attach offline results with -ReverificationDirectory.' }
$conditionRoot = Split-Path $root
$runRoot = Split-Path $conditionRoot
$config = Read-Json (Join-Path $conditionRoot 'config.json')
$manifest = Read-Json (Join-Path $runRoot 'input-manifest.json')
$turns = @(if (Test-Path -LiteralPath (Join-Path $root 'capture')) {
    Get-ChildItem -LiteralPath (Join-Path $root 'capture') -Directory -Filter 'turn-*' | Sort-Object Name
})
$turnMeta = if ($turns.Count) { Read-Json (Join-Path $turns[0].FullName 'turn.json') } else { $null }
$lastMeta = if ($turns.Count) { Read-Json (Join-Path $turns[-1].FullName 'turn.json') } else { $null }
$timeline = Get-Timeline $turns
$checks = [Collections.Generic.List[object]]::new()
Add-Checks $checks 'preflight' $result['preflight'] (Join-Path $conditionRoot 'preflight') (Join-Path $runRoot 'baseline')
Add-Checks $checks 'initial_independent_verification' $result['verification'] (Join-Path $conditionRoot 'verification') (Join-Path $runRoot 'baseline')
if ($result['verificationPolicy'] -eq 'latest-backend-with-historical-comparison-v1') {
    foreach ($row in $checks | Where-Object layer -eq 'initial_independent_verification') { $row.baseline = (Join-Path $conditionRoot 'product') }
}
Add-Checks $checks 'historical_comparison_nonblocking' $result['historicalVerification'] (Join-Path $conditionRoot 'historical-verification') (Join-Path $runRoot 'baseline')
$offlineVerifications = @()
$previous = Read-Json (Join-Path $root 'report.json')
$offlinePaths = @($ReverificationDirectory)
if ($previous -and $previous['offlineVerifications']) { $offlinePaths += @($previous.offlineVerifications | ForEach-Object { $_.directory }) }
foreach ($path in @($offlinePaths | Sort-Object -Unique)) {
    $offline = Read-Json (Join-Path $path 'result.json')
    if (-not $offline -or -not $offline['offline'] -or -not $offline['sourceResult']) { throw "Not an offline Dev verification: $path" }
    if ([IO.Path]::GetFullPath($offline.sourceResult) -ine [IO.Path]::GetFullPath($resultPath)) { continue }
    $offlineManifest = Read-Json (Join-Path $path 'manifest.json')
    if (-not $offlineManifest -or $offlineManifest['originalResultSha256'] -ine (Get-FileHash -LiteralPath $resultPath).Hash) {
        throw "Offline verification source hash does not match original result: $path"
    }
    $record = @{
        directory = $path; status = (Get-DevStatusSummary $offline); outcome = $offline.outcome
        sourceIntegrityVerified = $offline['sourceIntegrityVerified']; modelInvocations = $offline['modelInvocationsThisRun']
        baseline = (Join-Path $path 'inputs\test-baseline'); baselineSource = $offline['testBaseline']; manifest = (Join-Path $path 'manifest.json')
        adjustments = (Join-Path $path 'inputs\adjustments.json'); incrementalAiCredits = 0
        startedAt = $offline['reverificationStartedAt']; finishedAt = $offline['reverificationFinishedAt']
        evidenceWrittenAt = (Get-Item -LiteralPath (Join-Path $path 'result.json')).LastWriteTimeUtc.ToString('o')
    }
    $offlineVerifications += $record
    Add-Checks $checks "offline_verification:$(Split-Path $path -Leaf)" $offline.verification (Join-Path $path 'verification') $record.baseline
}
$offlineVerifications = @($offlineVerifications | Sort-Object { if ($_['startedAt']) { $_.startedAt } else { $_.evidenceWrittenAt } })
$changes = @($result['changedFiles'] | ForEach-Object {
    $path = $_.path.Replace('\', '/')
    $category = if ($path -match '(^|/)(__pycache__|\.pytest_cache|\.eval-tmp)(/|$)|\.py[co]$') { 'generated' }
        elseif ($path -match '(^|/)(tests?|__tests__)/|[._](test|spec)\.') { 'tests' }
        elseif ($path -match '^migrations/') { 'migration' }
        elseif ($path -match '^frontend/') { 'frontend' }
        else { 'source_or_configuration' }
    @{ path = $path; category = $category; before = $_.before; after = $_.after }
})
$captureSeconds = if ($turnMeta -and $lastMeta -and $turnMeta['startedAt'] -and $lastMeta['finishedAt']) {
    ([DateTimeOffset]::Parse([string]$lastMeta.finishedAt) - [DateTimeOffset]::Parse([string]$turnMeta.startedAt)).TotalSeconds
} else { $null }
$report = @{
    schemaVersion = 1; stage = 'dev'; generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    name = (Split-Path $conditionRoot -Leaf); directory = $root; model = $result['model']; observedModels = @($result['observedModels'])
    requestedFusionTier = $(if ($turnMeta) { $turnMeta['requestedFusionTier'] } else { $null })
    requestedAutoTier = $(if ($turnMeta) { $turnMeta['requestedAutoTier'] } else { $null })
    effectiveCliModel = $(if ($turnMeta) { $turnMeta['effectiveCliModel'] } else { $null })
    fusionPhases = @($result['fusionPhases'] | Where-Object { $_ })
    agent = $(if ($turnMeta) { $turnMeta['requestedAgent'] } else { $null })
    cliVersion = $(if ($turnMeta) { $turnMeta['cliVersion'] } else { $null })
    caseId = $(if ($manifest) { $manifest['caseId'] } else { $null })
    outcome = $result.outcome; status = (Get-DevStatusSummary $result); acceptanceConfigured = $result.acceptanceConfigured
    verificationPolicy = $result['verificationPolicy']; historicalVerification = $result['historicalVerification']
    warnings = @($result['warnings'] | Where-Object { $_ })
    captureNonBlocking = [bool]($result['capture'] -and $result.capture['nonBlocking'])
    timing = @{
        captureStartedAt = $(if ($turnMeta) { $turnMeta['startedAt'] } else { $null })
        captureFinishedAt = $(if ($lastMeta) { $lastMeta['finishedAt'] } else { $null })
        captureDurationSeconds = $captureSeconds
        cliDurationSeconds = $(if ($result['execution']) { $result.execution['durationSeconds'] } else { $null })
        conditionStartedAt = $result['startedAt']; conditionFinishedAt = $result['finishedAt']
        preparationDurationSeconds = $result['preparationDurationSeconds']
    }
    calls = $result.calls; usage = (Get-Usage $turns $result.calls); timeline = $timeline.items
    publicMessages = $timeline.publicMessages; checks = $checks.ToArray(); offlineVerifications = $offlineVerifications
    changes = $changes; protectedChanges = $result['protectedChanges']
    inputManifest = (Join-Path $runRoot 'input-manifest.json'); inputHashes = $(if ($manifest) { $manifest['inputHashes'] } else { $null })
    diagnostics = @($diagnostics) + @($result['errors']) + $(if ($result['capture']) { @($result.capture['errors']) } else { @() })
}
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# Dev: $($report.name)"); $lines.Add('')
$lines.Add('## 本轮概览 / Overview'); $lines.Add('')
$lines.Add('| Item | Value |'); $lines.Add('| --- | --- |')
foreach ($pair in @(
    @('Case / stage', "$($report.caseId) / Dev"), @('Agent', $report.agent),
    @('Requested / actual model', "$($report.model) / $($report.observedModels -join ', ')"),
    @('Requested Fusion tier / routing profile', "$($report.requestedFusionTier) / $($report.requestedAutoTier)"),
    @('CLI model selector', $report.effectiveCliModel),
    @('CLI version', $report.cliVersion), @('Original outcome', $report.outcome),
    @('Capture start (UTC+08:00)', (Time $report.timing.captureStartedAt)), @('Capture finish (UTC+08:00)', (Time $report.timing.captureFinishedAt)),
    @('CLI process duration', (Duration $report.timing.cliDurationSeconds)), @('Capture span (includes collection overhead)', (Duration $captureSeconds)),
    @('Condition start (UTC+08:00)', (Time $report.timing.conditionStartedAt)), @('Condition finish (UTC+08:00)', (Time $report.timing.conditionFinishedAt)),
    @('Condition duration (preflight + development + verification)', (Duration (Span $report.timing.conditionStartedAt $report.timing.conditionFinishedAt))),
    @('Workspace preparation duration', (Duration $report.timing.preparationDurationSeconds)),
    @('CLI invocations', $report.calls), @('AI credits / usage status', "$(Number $report.usage.aiCredits) AIC / $($report.usage.status)")
)) { $lines.Add("| $($pair[0]) | $(Cell $pair[1]) |") }
$phases = @($report.fusionPhases | Where-Object { $_.data['phaseKind'] -and $_.data['model'] } |
    ForEach-Object { "$($_.data.phaseKind):$($_.data.model)" }) -join ', '
$lines.Add("Fusion phases: $phases")
$lines.Add('Requested routing profiles are command evidence, not proof of every internal routing decision. No phase events does not imply failure: Standard may use a single model.')
$status = $report.status
$lines.Add(''); $lines.Add('| Dimension | Original status | Evidence |'); $lines.Add('| --- | --- | --- |')
$lines.Add("| Execution | $($status.execution) | $(Link $resultPath 'Original result') |")
$lines.Add("| Capture | $($status.capture) | $(if ($turns.Count) { Link (Join-Path $turns[0].FullName 'capture-diagnostics.json') 'Capture diagnostics' } else { 'not run' }) |")
$lines.Add("| Tests | $($status.tests) | $($status.passed)/$($status.total); failures: $($status.failures); errors: $($status.errors); skipped: $($status.skipped) |")
$lines.Add(''); $lines.Add('## 任务范围与冻结输入'); $lines.Add('')
$lines.Add("$(Link $report.inputManifest 'Input manifest (versions and hashes)'); $(Link (Join-Path $conditionRoot 'config.json') 'Condition configuration'); $(Link (Join-Path $runRoot 'inputs\requirement.md') 'Requirement'); $(Link (Join-Path $runRoot 'inputs\design.md') 'Design').")
$lines.Add('框架独立门禁范围：代码落盘及 Python/API 测试。Dev 仍须对前端改动执行必要构建和受影响功能的基本验证，并在开发记录中提供命令、退出码、结果及未验证范围；后端门禁通过不代表前端基本验证已完成。完整 Web/E2E 独立验收归 Test，不据此宣称 QA 完成。')
if ($report.verificationPolicy) {
    $lines.Add('本轮门禁使用 Dev 交付的最新后端测试（不代表覆盖已获独立审核）；旧冻结测试仅作非阻断历史对照。Test 后续独立审核与执行，不能用自测通过替代需求覆盖。')
}
if ($config -and $config['initialRequest']) { Add-Text $lines $config.initialRequest }
$lines.Add(''); $lines.Add('## AI credit 与调用用量'); $lines.Add('')
$lines.Add('| Session | AIC | Status | User requests | Internal model requests | API duration | Evidence |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($snapshot in $report.usage.snapshots) {
    $lines.Add("| $($snapshot.sessionId) | $(Number $snapshot.aiCredits) | $($snapshot.status) | $(Number $snapshot.userRequests) | $(Number $snapshot.modelRequests) | $(Duration $snapshot.apiDurationSeconds) | $(Link $snapshot.source 'usage.json') |")
}
$lines.Add($report.usage.policy)
$lines.Add('Input tokens are split into uncached / cache read / cache write in report.json. Premium-request cost is not AIC. Unknown usage is not zero; partial usage is not a complete total. Offline verification adds 0 AIC.')
$lines.Add(''); $lines.Add('## 核心开发时间线'); $lines.Add('')
$lines.Add('依据工具执行与测试输出提取，不包含内部推理。Agent 自测可能使用其修改的测试，不等于独立验收；工具返回不等于命令执行成功。')
$lines.Add(''); $lines.Add('| Time (UTC+08:00) | Event | Status | Detail | Evidence |')
$lines.Add('| --- | --- | --- | --- | --- |')
foreach ($item in $report.timeline) {
    $detail = $item.detail
    if ($detail.Length -gt 350) { $detail = $detail.Substring(0, 350) + ' ... (see report.json)' }
    $lines.Add("| $(Time $item.timestamp) | $($item.kind) | $($item.status) | $(Cell $detail) | $(Link $item.source "event $($item.eventId), line $($item.sourceLine)") |")
}
if (-not $report.timeline.Count) { $lines.Add('| unknown | no observable milestones | unconfirmed | See raw capture | - |') }
$lines.Add(''); $lines.Add('### Agent 公开交付说明（声明，不等于独立验证）'); $lines.Add('')
if ($report.publicMessages.Count) { Add-Text $lines $report.publicMessages[-1].content }
else { $lines.Add('No public delivery statement captured.') }
$lines.Add(''); $lines.Add('## 分层测试证据'); $lines.Add('')
$lines.Add('预检确认初始环境；原独立验收恢复冻结测试；离线复验使用单独记录的测试基准。不同层次的测试数量不能相加，也不代表相同业务覆盖。Agent 自测及其迭代结果见上方时间线。')
$lines.Add(''); $lines.Add('| Layer | Check | State | Passed / total | Failed | Errors | Skipped | Process duration | Exit | Evidence |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
foreach ($check in $checks) {
    $lines.Add("| $(Cell $check.layer) | $($check.name) | $($check.state) | $($check.passed)/$($check.total) | $($check.failures) | $($check.errors) | $($check.skipped) | $(Duration $check.durationSeconds) | $(Cell $check.exitCode) | $(Link $check.source 'checks.json'), $(Link $check.xml 'JUnit') |")
}
$lines.Add("Business acceptance: $(if ($report.acceptanceConfigured) { 'configured; see acceptance checks above' } else { 'NOT CONFIGURED. Passing regression does not prove full business acceptance.' })")
foreach ($offline in $offlineVerifications) {
    $lines.Add('')
    $lines.Add("### Offline verification: $(Split-Path $offline.directory -Leaf)")
    $lines.Add("Baseline: $(Link $offline.baseline 'test baseline'); $(Link $offline.manifest 'hashes and integrity'); $(Link $offline.adjustments 'approved adjustments'); $(Link (Join-Path $offline.directory 'summary.md') 'offline summary').")
    $lines.Add("Tests=$($offline.status.tests); execution/capture inherited, not rerun. Source integrity verified=$($offline.sourceIntegrityVerified); model invocations=$($offline.modelInvocations); incremental AIC=0. Original outcome remains $($report.outcome).")
    $lines.Add("复验开始：$(Time $offline.startedAt)；结束：$(Time $offline.finishedAt)。历史时间缺失时，仅记录证据文件写入时间 $(Time $offline.evidenceWrittenAt)，不视作执行时间。")
}
$lines.Add(''); $lines.Add('## 代码交付概览'); $lines.Add('')
$lines.Add('Framework hash comparison, not CLI edit-operation counts. Generated files are excluded from deliverable counts.')
foreach ($group in @($changes | Group-Object category | Sort-Object Name)) {
    $lines.Add("- $($group.Name): $($group.Count)")
}
$lines.Add(''); $lines.Add('| Category | File | Change |'); $lines.Add('| --- | --- | --- |')
foreach ($change in @($changes | Where-Object category -ne 'generated')) {
    $action = if (-not $change.before) { 'added' } elseif (-not $change.after) { 'deleted' } else { 'modified' }
    $lines.Add("| $($change.category) | $(Cell $change.path) | $action |")
}
$lines.Add("Protected input changes: $(@($report.protectedChanges).Count).")
$lines.Add(''); $lines.Add('## 限制、诊断与证据索引'); $lines.Add('')
$lines.Add('- Execution, capture and test states are independent. Re-verification never repairs incomplete capture or rewrites the original result.')
$lines.Add('Dev 验收不要求 Agent 用 JSON 回答。已诊断的标准输出 JSON 损坏可作为非阻断警告；不会将采集状态改为完整，也不代表业务验收通过。执行失败、模型不符、关键证据缺失及独立测试失败仍阻断完成。')
foreach ($warning in $report.warnings) { $lines.Add("- Warning / $(Cell $warning.code): $(Cell $warning.message)") }
$lines.Add('- Self-test counts, tokens and code volume are observations, not quality scores. No model scoring was invoked.')
$lines.Add('- Missing historical preparation/end-to-end timestamps remain unknown; CLI duration and capture span use distinct clocks.')
foreach ($message in $report.diagnostics) { if ($message) { $lines.Add("- $(Cell $message)") } }
$lines.Add("- $(Link $resultPath 'Original result'); $(Link (Join-Path $root 'report.json') 'Structured report'); $(Link (Join-Path $root 'capture') 'Raw capture').")
Write-Json (Join-Path $root 'report.json') $report
$lines | Set-Content -LiteralPath (Join-Path $root 'summary.md') -Encoding utf8
