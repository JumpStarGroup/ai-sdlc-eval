#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DialoguePolicy.psm1') -Force
$root = (Resolve-Path -LiteralPath $RunDirectory).Path
function Read-ReportJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $arguments = @{ InputObject = (Get-Content -LiteralPath $Path -Raw -Encoding utf8); AsHashtable = $true }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $arguments['DateKind'] = 'String' }
        return ConvertFrom-Json @arguments
    }
    return $null
}
function Get-RoleCredits([string]$Role, [int]$ExpectedCalls) {
    $sessions = @{}
    $capture = Join-Path $root "$Role-capture"
    $calls = @(Get-ChildItem -LiteralPath $capture -Directory -Filter 'turn-*' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($call in $calls) {
        $meta = Read-ReportJson (Join-Path $call.FullName 'turn.json')
        $sessionId = if ($meta -and $meta['sessionId']) { $meta.sessionId } else { $call.Name }
        $sessions[$sessionId] = $call
    }
    $snapshots = @()
    foreach ($sessionId in ($sessions.Keys | Sort-Object)) {
        $path = Join-Path $sessions[$sessionId].FullName 'usage.json'
        $snapshot = @{ sessionId = $sessionId; source = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/'); status = 'unavailable'; nanoAiu = $null; aiCredits = $null; premiumRequests = $null; inputTokens = $null; outputTokens = $null; cacheReadTokens = $null; cacheWriteTokens = $null; totalTokens = $null }
        try {
            $raw = Read-ReportJson $path
            if ($raw) {
                $value = $raw['totalNanoAiu']
                if ($value -is [ValueType] -and $value -isnot [bool] -and $value -ge 0) {
                    $snapshot.nanoAiu = [decimal]$value
                    $snapshot.aiCredits = [decimal]$value / 1000000000d
                    $snapshot.status = if ($raw['aiCreditsStatus'] -ceq 'complete') { 'complete' } else { 'partial' }
                }
                if ($raw['tokenDetails'] -is [System.Collections.IDictionary]) {
                    $counts = @{}
                    foreach ($category in @('input', 'cache_read', 'cache_write', 'output')) {
                        $entry = $raw.tokenDetails[$category]
                        if ($entry -is [System.Collections.IDictionary] -and $entry['tokenCount'] -is [ValueType] -and
                            $entry.tokenCount -isnot [bool] -and $entry.tokenCount -ge 0) { $counts[$category] = [decimal]$entry.tokenCount }
                    }
                    $snapshot.cacheReadTokens = $counts['cache_read']
                    $snapshot.cacheWriteTokens = $counts['cache_write']
                    $snapshot.outputTokens = $counts['output']
                    if (@('input', 'cache_read', 'cache_write' | Where-Object { -not $counts.ContainsKey($_) }).Count -eq 0) {
                        $snapshot.inputTokens = $counts.input + $counts.cache_read + $counts.cache_write
                    }
                    if ($null -ne $snapshot.inputTokens -and $null -ne $snapshot.outputTokens) { $snapshot.totalTokens = $snapshot.inputTokens + $snapshot.outputTokens }
                }
                if ($raw['totalPremiumRequestCost'] -is [ValueType] -and $raw.totalPremiumRequestCost -isnot [bool] -and $raw.totalPremiumRequestCost -ge 0) {
                    $snapshot.premiumRequests = $raw.totalPremiumRequestCost
                }
            }
        } catch { $snapshot['error'] = $_.Exception.Message }
        $snapshots += $snapshot
    }
    $known = [decimal]0
    foreach ($snapshot in $snapshots) { if ($null -ne $snapshot.nanoAiu) { $known += $snapshot.nanoAiu } }
    $complete = $ExpectedCalls -eq 0 -or ($calls.Count -ge $ExpectedCalls -and $snapshots.Count -gt 0 -and
        @($snapshots | Where-Object { $_.status -ne 'complete' }).Count -eq 0)
    $hasCredits = @($snapshots | Where-Object { $null -ne $_.aiCredits }).Count -gt 0
    $total = @{
        calls = $ExpectedCalls; snapshots = $snapshots; status = $(if ($complete) { 'complete' } elseif ($hasCredits) { 'partial' } else { 'unavailable' })
        aiCredits = $(if ($ExpectedCalls -eq 0 -or $hasCredits) { $known / 1000000000d } else { $null })
        totalNanoAiu = $(if ($complete) { $known } else { $null }); observedNanoAiu = $known
    }
    foreach ($key in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens')) {
        $total[$key] = $null
        if ($ExpectedCalls -eq 0) { $total[$key] = [decimal]0 }
        elseif ($calls.Count -ge $ExpectedCalls -and $snapshots.Count -gt 0 -and @($snapshots | Where-Object { $null -eq $_[$key] }).Count -eq 0) {
            $sum = [decimal]0
            foreach ($snapshot in $snapshots) { $sum += $snapshot[$key] }
            $total[$key] = $sum
        }
    }
    return $total
}
function Format-ReportTime($Value) {
    if ($null -eq $Value) { return '未知' }
    if ($Value -is [DateTimeOffset] -or $Value -is [DateTime]) { return $Value.ToString('o') }
    return [string]$Value
}
function Get-ReportDurationMs($StartedAt, $FinishedAt) {
    if ($null -eq $StartedAt -or $null -eq $FinishedAt) { return $null }
    try {
        $started = [DateTimeOffset]::Parse([string]$StartedAt, [Globalization.CultureInfo]::InvariantCulture)
        $finished = [DateTimeOffset]::Parse([string]$FinishedAt, [Globalization.CultureInfo]::InvariantCulture)
        return [long][Math]::Round(($finished - $started).TotalMilliseconds)
    } catch { return $null }
}
function Format-ReportNumber($Value, [string]$Format = '0.##') {
    if ($null -eq $Value) { return '未知' }
    return ([decimal]$Value).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}
function Format-ReportDuration($Milliseconds) {
    if ($null -eq $Milliseconds) { return '未知' }
    $duration = [TimeSpan]::FromMilliseconds([double]$Milliseconds)
    return '{0:00}:{1:00}:{2:00}.{3:000}' -f [int][Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds, $duration.Milliseconds
}
function Get-RoleLabel([string]$Role) {
    switch ($Role) { 'target' { 'Target' }; 'participant' { 'Participant' }; 'controller' { 'Controller' }; 'task_initiator' { '任务发起方' }; default { $Role } }
}
function Format-ReportModels($Models) {
    $values = @($Models | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (-not $values.Count) { return '未知（无实际模型证据）' }
    return $values -join ', '
}
function Add-ReportText($Lines, [string]$Text) {
    $fence = '````'
    while ($Text.Contains($fence)) { $fence += '`' }
    $Lines.Add($fence + 'text'); $Lines.Add($Text); $Lines.Add($fence)
}
$state = Read-ReportJson (Join-Path $root 'result.json')
if (-not $state -and (Test-Path (Join-Path $root 'comparison.json'))) {
    $comparison = Read-ReportJson (Join-Path $root 'comparison.json')
    $indexLines = @('# 本次比较测试索引', '', '| PM 请求模型 | PM 实际模型 | 结果 | 整场耗时 | Target 累计 | Participant 累计 | 完整会话 | Session AIC（被评估 Agent） | 输入 tokens | 输出 tokens | 状态 |', '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($condition in $comparison.conditions) {
        if (-not (Test-Path (Join-Path $condition.runDirectory 'result.json'))) { continue }
        & $PSCommandPath -RunDirectory $condition.runDirectory | Out-Host
        $child = Read-ReportJson (Join-Path $condition.runDirectory 'report.json')
        $usage = $child.usage.target
        $summaryPath = [IO.Path]::GetRelativePath($root, (Join-Path $condition.runDirectory 'summary.md')).Replace('\', '/')
        $indexLines += "| $($condition.model) | $(Format-ReportModels $child.actualModels.target) | $($child.outcome) | $(Format-ReportDuration $child.durationMs) | $(Format-ReportDuration $child.roleDurationMs.target) | $(Format-ReportDuration $child.roleDurationMs.participant) | [完整会话]($summaryPath) | $(Format-ReportNumber $usage.aiCredits '0.00') | $(Format-ReportNumber $usage.inputTokens) | $(Format-ReportNumber $usage.outputTokens) | $($usage.status) |"
    }
    $indexLines += @('', '此索引及各组汇总是派生视图；comparison.json、result.json、冻结代码、原始 session 和采集快照保持不变。')
    $indexLines | Set-Content (Join-Path $root 'summary.md') -Encoding utf8
    Write-Output "Comparison summary: $(Join-Path $root 'summary.md')"
    return
}
if (-not $state) { throw 'Missing result.json.' }
$config = Read-ReportJson (Join-Path $root 'config.json')
$runDurationMs = $state['durationMs']
if ($null -eq $runDurationMs) { $runDurationMs = Get-ReportDurationMs $state['startedAt'] $state['finishedAt'] }
$report = @{
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o'); outcome = $state.outcome
    completionFacts = Get-DialogueCompletionFacts $state
    durationMs = $runDurationMs; roleDurationMs = @{ target = [long]0; participant = [long]0 }
    accounting = 'Copilot CLI session usage snapshots are the source. AIC = totalNanoAiu / 1,000,000,000; display to two decimals, retain exact raw value. Checked against session 9e9ed14d-718f-4b5c-830e-16681610ef3d: 9155771100 matches CLI /usage 9.16 AIC. Latest cumulative snapshot per session, not a sum of turns. Partial credits remain reported partial amounts, not complete totals. Premium requests are separate. Missing usage is not zero; CLI usage is not an invoice.'
    usage = @{}; messages = @(); executions = @(); actualModels = @{}; pending = $state.pending; questions = $state['questions']; artifactCheck = $state['artifactCheck']
}
foreach ($role in @('target', 'participant')) {
    $expected = @($state.turns | Where-Object { $_.role -eq $role }).Count
    $report.usage[$role] = Get-RoleCredits $role $expected
}
foreach ($turn in $state.turns) {
    $captured = $null
    if ($turn['capturePath']) { $captured = $turn.capturePath }
    elseif ($turn['evidence']) {
        $captureRoot = Join-Path $root "$($turn.role)-capture"
        foreach ($candidate in @(Get-ChildItem $captureRoot -Directory -Filter 'turn-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $inputPath = Join-Path $candidate.FullName 'input.txt'
            $originalInput = Join-Path $turn.evidence 'input.txt'
            if ((Test-Path $inputPath) -and (Test-Path $originalInput) -and
                (Get-FileHash $inputPath).Hash -ceq (Get-FileHash $originalInput).Hash) { $captured = $candidate.FullName; break }
        }
    }
    $meta = if ($captured) { Read-ReportJson (Join-Path $captured 'turn.json') } else { $null }
    $runtime = if ($captured) { Read-ReportJson (Join-Path $captured 'runtime.json') } else { $null }
    $requestedModel = if ($turn['requestedModel']) { $turn.requestedModel } elseif ($meta) { $meta['requestedModel'] }
        elseif ($config) { if ($turn.role -eq 'target') { $config.targetModel } else { $config.participantModel } } else { $null }
    $observedModels = @(if ($turn['observedModels']) { $turn.observedModels } elseif ($runtime) { $runtime['observedModels'] })
    $turnDurationMs = $turn['durationMs']
    if ($null -eq $turnDurationMs) { $turnDurationMs = Get-ReportDurationMs $turn['startedAt'] $turn['finishedAt'] }
    if ($null -eq $turnDurationMs) { $report.roleDurationMs[$turn.role] = $null }
    elseif ($null -ne $report.roleDurationMs[$turn.role]) { $report.roleDurationMs[$turn.role] += [long]$turnDurationMs }
    $execution = @{ call = $turn.call; role = $turn.role; requestedModel = $requestedModel; observedModels = @($observedModels)
        fusionPhases = $(if ($turn['fusionPhases']) { $turn.fusionPhases } elseif ($runtime) { $runtime['fusionPhases'] } else { $null })
        durationMs = $turnDurationMs
        modelEvidence = $(if ($observedModels.Count) { 'observed' } else { 'unavailable' })
        runtimeProblemDisposition = $turn['runtimeProblemDisposition']
        source = $(if ($captured) { [IO.Path]::GetRelativePath($root, (Join-Path $captured 'runtime.json')).Replace('\', '/') } else { $null })
        toolSnapshots = $(if ($runtime) { $runtime['toolSnapshots'] } else { $null })
        disabledTools = $(if ($runtime) { $runtime['disabledTools'] } else { $null })
        problems = $(if ($runtime) { $runtime['problems'] } else { $null })
        warnings = $(if ($runtime) { $runtime['warnings'] } else { $null }) }
    $report.executions += $execution
    $started = if ($turn['startedAt']) { $turn.startedAt } elseif ($meta) { $meta['startedAt'] } else { $null }
    $finished = if ($turn['finishedAt']) { $turn.finishedAt } elseif ($meta) { $meta['finishedAt'] } else { $null }
    $sender = if ($turn['inputSender']) { $turn.inputSender } elseif ($turn.call -eq 1) { 'task_initiator' }
        elseif ($state.turns[$turn.call - 2]['controller'] -and $state.turns[$turn.call - 2].controller.action -eq 'prompt') { 'controller' }
        elseif ($turn.role -eq 'target') { 'participant' } else { 'target' }
    $report.messages += @{ call = $turn.call; time = $started; sender = $sender; recipient = $turn.role; content = $turn.input; type = 'input'; execution = $execution; inputFile = $(if ($captured) { Join-Path $captured 'input.txt' } else { Join-Path $turn.evidence 'input.txt' }) }
    $text = $null
    if ($turn['response']) { $text = $turn.response.text }
    elseif ($turn['rawResponse']) { $text = $turn.rawResponse }
    elseif ($captured) {
        $rawMessages = @(Read-ReportJson (Join-Path $captured 'assistant-messages.json'))
        if ($rawMessages.Count -and $rawMessages[-1]) { $text = $rawMessages[-1].content }
    }
    if ($null -ne $text) {
        $delivery = if ($turn['delivery']) { $turn.delivery } else { @{ status = 'not_forwarded' } }
        if (-not $turn['delivery'] -and $turn.call -lt $state.turns.Count) {
            $next = $state.turns[$turn.call]
            if ($next.input -ceq $text) { $delivery = @{ status = 'recorded_in_next_input'; recipient = $next.role; targetCall = $next.call } }
        }
        $report.messages += @{ call = $turn.call; time = $finished; sender = $turn.role; recipient = 'controller'; content = $text; type = 'response'; delivery = $delivery; execution = $execution }
    }
}
foreach ($role in @('target', 'participant')) {
    $report.actualModels[$role] = @($report.executions | Where-Object { $_.role -eq $role } | ForEach-Object { $_.observedModels } | Sort-Object -Unique)
}
$report['conversation'] = @()
for ($index = 0; $index -lt $report.messages.Count; $index++) {
    $message = $report.messages[$index]
    $previous = if ($index -gt 0) { $report.messages[$index - 1] } else { $null }
    $forwarded = $message.type -eq 'input' -and $previous -and $previous.type -eq 'response' -and
        $message.content -ceq $previous.content -and $message.sender -ceq $previous.sender -and
        $previous.delivery.status -in @('captured_input', 'recorded_in_next_input') -and
        $previous.delivery.targetCall -eq $message.call -and $previous.delivery.recipient -ceq $message.recipient
    if (-not $forwarded) { $report.conversation += $message }
}
$report | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $root 'report.json') -Encoding utf8
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# 本次测试完整会话汇总')
$lines.Add('')
$lines.Add("- 测试目录：$root")
$lines.Add("- 结束状态：$($state.outcome)")
$facts = $report.completionFacts
$lines.Add("- Target 最后回复：存在=$($facts.finalReplyPresent)；已送达=$($facts.finalReplyDelivered)；报告状态=$($facts.finalTargetStatus)；声明完成=$($facts.completionClaimed)；交付核验通过=$($facts.deliveryVerified)")
if ($config) {
    $lines.Add("- 被评估 Agent：$($config.targetAgent)；请求模型：$($config.targetModel)")
    $lines.Add("- 模拟人请求模型：$($config.participantModel)")
}
$lines.Add("- 被评估 Agent 实际模型：$(Format-ReportModels $report.actualModels.target)")
$lines.Add("- 模拟人实际模型：$(Format-ReportModels $report.actualModels.participant)")
$lines.Add("- 整场耗时：$(Format-ReportDuration $report.durationMs)；被评估 Agent 累计：$(Format-ReportDuration $report.roleDurationMs['target'])；模拟人累计：$(Format-ReportDuration $report.roleDurationMs['participant'])")
if ($state['error']) { $lines.Add("- 错误：$($state.error)") }
$lines.Add('')
$lines.Add('## 逐调用模型记录')
$lines.Add('auto 是请求模式，不是实际模型；同一会话不同调用可切换模型。一次调用若观测到多个模型全部列出，不按汇总模型猜测单次模型。')
$lines.Add('| 调用 | 执行角色 | 请求模型 | 实际观测模型 | 耗时 | 证据 |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($execution in $report.executions) {
    $source = if ($execution.source) { "[runtime.json]($($execution.source.Replace(' ', '%20')))" } else { '无记录' }
    $requested = if ($execution.requestedModel) { $execution.requestedModel } else { '未知' }
    $observedText = Format-ReportModels $execution.observedModels
    if ($execution['fusionPhases'] -and @($execution.fusionPhases).Count) {
        $phaseModels = @(
            $execution.fusionPhases | ForEach-Object {
                $d = $_['data']
                if ($d -is [System.Collections.IDictionary]) {
                    $pk = if ($d['phaseKind']) { $d.phaseKind } elseif ($d['pattern']) { $d.pattern } else { $null }
                    $pm = if ($d['model']) { $d.model } elseif ($d['finalSourceModel']) { $d.finalSourceModel } elseif ($d['sourceModel']) { $d.sourceModel } else { $null }
                    if ($pk -and $pm) { "${pk}:$pm" } elseif ($pm) { "$pm" }
                }
            } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($phaseModels.Count) {
            $observedText = "$observedText (HydraFusion 阶段: $($phaseModels -join ' → '))"
        }
    }
    $lines.Add("| $($execution.call) | $(Get-RoleLabel $execution.role) | $requested | $observedText | $(Format-ReportDuration $execution.durationMs) | $source |")
}
$lines.Add('')
$lines.Add('## 完整会话')
$lines.Add('每条业务正文只展示一次；只有已有送达凭据且内容完全一致的转发输入才省略重复正文。report.json 保留完整 inputs/responses，实际 CLI 输入含共同约定和台账，可通过送达凭据核对。时间使用 ISO 8601。')
foreach ($message in $report.conversation) {
    $time = Format-ReportTime $message.time
    $sender = Get-RoleLabel $message.sender
    $recipient = Get-RoleLabel $message.recipient
    $route = if ($message.type -eq 'input' -and $message.sender -ne 'controller') { "$sender → Controller → $recipient" } else { "$sender → $recipient" }
    if ($message.type -eq 'response' -and $message.delivery.status -in @('captured_input', 'recorded_in_next_input')) {
        $route = "$sender → Controller → $(Get-RoleLabel $message.delivery.recipient)"
    } elseif ($message.type -eq 'response' -and $state.turns[$message.call - 1]['controller'] -and $state.turns[$message.call - 1].controller.action -eq 'stop') {
        $route = "$sender → Controller（结束判定）"
    }
    $lines.Add('')
    $lines.Add("### 调用 $($message.call) | $time | $route")
    $lines.Add("执行角色：$(Get-RoleLabel $message.execution.role)；请求模型：$($message.execution.requestedModel)；实际模型：$(Format-ReportModels $message.execution.observedModels)。")
    if ($message.Contains('delivery')) {
        $delivery = $message.delivery
        $label = switch ($delivery.status) {
            'captured_input' { "已送达 $($delivery.recipient)，调用 $($delivery.targetCall)，有 CLI 输入捕获凭据" }
            'recorded_in_next_input' { "已记录到 $($delivery.recipient) 的调用 $($delivery.targetCall) 输入（历史记录）" }
            'pending_dispatch' { '等待送达，尚无下一次成功输入捕获' }
            default { '未转发正文；请查看下一次输入及控制决策' }
        }
        if ($state.turns[$message.call - 1]['controller'] -and $state.turns[$message.call - 1].controller.action -eq 'stop') {
            $label = "控制器已结束本次任务，无后续转发；原因：$($state.turns[$message.call - 1].controller.reason)"
        }
        $lines.Add("正文交付：$label")
        if ($delivery['inputFile']) {
            $relativeInput = [IO.Path]::GetRelativePath($root, $delivery.inputFile).Replace('\', '/')
            $lines.Add("送达凭据：[对方实际 CLI 输入]($($relativeInput.Replace(' ', '%20')))")
        }
    } elseif ($message['inputFile']) {
        $relativeInput = [IO.Path]::GetRelativePath($root, $message.inputFile).Replace('\', '/')
        $lines.Add("原始输入：[完整 CLI 提示]($($relativeInput.Replace(' ', '%20')))")
    }
    Add-ReportText $lines $message.content
}
$lines.Add('')
$lines.Add('## AI credit 费用汇总')
$lines.Add('| 角色 | 调用次数 | 累计耗时 | Session AIC | 输入 tokens（含缓存） | 输出 tokens | 数据状态 |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($role in @('target', 'participant')) {
    $usage = $report.usage[$role]
    $total = Format-ReportNumber $usage.aiCredits '0.00'
    $label = if ($role -eq 'target') { '被评估 Agent' } else { '业务模拟人' }
    $duration = Format-ReportDuration $report.roleDurationMs[$role]
    $lines.Add("| $label | $($usage.calls) | $duration | $total | $(Format-ReportNumber $usage.inputTokens) | $(Format-ReportNumber $usage.outputTokens) | $($usage.status) |")
}
$lines.Add('')
foreach ($role in @('target', 'participant')) {
    foreach ($snapshot in $report.usage[$role].snapshots) { $lines.Add("- $role 用量来源：[$($snapshot.source)]($($snapshot.source))；会话：$($snapshot.sessionId)") }
}
$lines.Add('')
$lines.Add('## 问题状态与待决记录')
$questions = if ($state.Contains('questions')) { @($state.questions) } else { @($state.pending) }
foreach ($pending in $questions) {
    $status = if ($pending.Contains('questionStatus')) { $pending.questionStatus } else { 'legacy_unclassified' }
    $lines.Add("### $($pending.id) | $status | $($pending.kind)")
    $original = if ($pending.Contains('originalQuestion')) { $pending.originalQuestion } else { $pending.question }
    $lines.Add('问题：'); Add-ReportText $lines $original
    if ($pending.question -cne $original) { $lines.Add('当前表述：'); Add-ReportText $lines $pending.question }
    if ($pending['remainingQuestion'] -and $pending.remainingQuestion -cne $original -and $pending.remainingQuestion -cne $pending.question) { $lines.Add('剩余问题：'); Add-ReportText $lines $pending.remainingQuestion }
    if ($pending.Contains('answeredParts') -and $pending.answeredParts.Count) { $lines.Add('已回答部分（Agent 声明）：'); Add-ReportText $lines (@($pending.answeredParts) -join "`n") }
    if ($pending.Contains('history')) {
        $evidenceCalls = @($pending.history | ForEach-Object { $_.call } | Sort-Object -Unique)
        $lines.Add("证据调用：$($evidenceCalls -join ', ')；完整修订记录见 [report.json](report.json)。")
    }
}
$lines.Add('')
$lines.Add('## 审计索引')
$lines.Add('主汇总精简显示，不删除 inputs/responses 或问题历史。下表逐次保留实际输入文件，转发可与上一条 Agent 输出逐字核对。')
foreach ($message in @($report.messages | Where-Object { $_.type -eq 'input' })) {
    $relativeInput = [IO.Path]::GetRelativePath($root, $message.inputFile).Replace('\', '/')
    $route = if ($message.sender -eq 'controller') { "Controller → $(Get-RoleLabel $message.recipient)" } else { "$(Get-RoleLabel $message.sender) → Controller → $(Get-RoleLabel $message.recipient)" }
    $lines.Add("- 调用 $($message.call) | $route | [实际输入]($($relativeInput.Replace(' ', '%20')))")
}
$lines.Add('')
$lines.Add('## 运行诊断')
$lines.Add('配置白名单不等于模型最终收到的工具。以下 schema 快照仅在 CLI 提供证据时显示；缺失不代表没有工具。')
foreach ($execution in $report.executions) {
    $lines.Add("### 调用 $($execution.call)")
    if ($execution.runtimeProblemDisposition -eq 'continued_with_valid_reply') { $lines.Add('工具错误处置：存在运行时工具错误，但 Agent 返回了有效答复，已记录错误并继续对话。') }
    foreach ($snapshot in @($execution.toolSnapshots | Where-Object { $null -ne $_ })) {
        $lines.Add("实际请求快照：$($snapshot.side)；模型：$($snapshot.model)；工具：$($snapshot.names -join ', ')；截断标志：$($snapshot.truncated)；事件：$($snapshot.eventId)")
    }
    foreach ($disabled in @($execution.disabledTools | Where-Object { $null -ne $_ })) {
        $lines.Add("CLI 禁用工具：$($disabled.names -join ', ')；事件：$($disabled.eventId)")
    }
    foreach ($problem in @($execution.problems | Where-Object { $null -ne $_ })) {
        Add-ReportText $lines (ConvertTo-Json @{ eventId = $problem.eventId; tool = $problem['toolName']; arguments = $problem['arguments']; error = $problem.data['error'] } -Depth 8)
    }
    foreach ($warning in @($execution.warnings | Where-Object { $null -ne $_ })) {
        $lines.Add("警告：$($warning['category'])；原事件：$($warning['eventId'])；恢复事件：$($warning['recoveryEventId'])；说明：$($warning['continuationReason'])")
    }
}
$lines.Add('')
$lines.Add('## 交付核验')
$lines.Add('只核验文件及真实待决编号引用，不证明自然语言内容正确或需求完整，不要求逐字匹配。')
foreach ($turn in $state.turns) {
    if ($turn['controller'] -and $turn.controller['artifactCheck']) {
        $check = $turn.controller.artifactCheck
        $lines.Add("### 调用 $($turn.call) | 核验结果：$($check.ready)")
        foreach ($failure in $check.failures) { Add-ReportText $lines (ConvertTo-Json $failure -Compress -Depth 8) }
    }
}
$lines.Add('')
$lines.Add($report.accounting)
$lines.Add('此汇总是派生视图，不修改原始对话、冻结输入或运行结果。任务许可、控制协议与私有知识全文不混入业务正文。')
$lines | Set-Content (Join-Path $root 'summary.md') -Encoding utf8
Write-Output "Conversation summary: $(Join-Path $root 'summary.md')"