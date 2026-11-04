#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SimulatorModel,
    [ValidateSet('restrained', 'guided')][string]$SimulatorStyle = 'restrained',
    [switch]$LocalOnly,
    [string]$CliPath = 'copilot',
    [switch]$Resume,
    [ValidateRange(0, 100000)][int]$PauseAfterRounds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot 'Invoke-SdlcCapture.ps1'
$reporter = Join-Path $PSScriptRoot 'Export-PmReport.ps1'
$framework = Split-Path $PSScriptRoot
$simulatorAgent = if ($SimulatorStyle -eq 'guided') { 'eval-business-user-guided' } else { 'eval-business-user' }
$simulatorAgentFile = Join-Path $framework "agents\$simulatorAgent.agent.md"
$completionPolicy = [ordered]@{
    version = 'restrained-pending-completion-v4'
    stopOnDraftProduced = $true
    stopOnClarificationReady = $true
    instruction = '先处理实际提出的安全或未批准决策、具体问题，再判断结束。功能 Agent 声明产物已生成，或明确表示足以起草且无需继续澄清时，可提出 pm_complete。必须提供 completionKind（artifact_produced、clarification_ready 或 after_probe）以及 unresolvedQuote（Agent 自己在最新回复中承认未讨论或待确认事项的原文；没有则为 null）。不得根据隐藏答案推断或枚举遗漏。产物声明伴随未决事项时，控制器最多追加一次中性确认；之后有具体问题照常回答，不再提问则可用 after_probe 结束观测，未决不等于解决。未来计划、否定、条件句、引用他人及范围确认请求不是产物声明。仅记录观察结果，不代表业务通过；不得清除已登记待决项。'
}
if ($SimulatorStyle -eq 'guided') {
    $completionPolicy = [ordered]@{
        version = 'guided-pending-document-v2'
        stopOnDraftProduced = $false
        stopOnClarificationReady = $false
        instruction = 'guided 只有全部必答内容已在会话中得到回答、没有未解决的已登记问题，并且 PM 明确声明需求文件已生成且提供实际相对路径时才可 pm_complete。没有问题、可以定稿、请确认、确认后起草都不算完成；只生成部分草稿也不能绕过未回答问题。先回答当前具体问题；没有具体问题时依据 guidedCoverage 的缺口一次询问一个主题，不发送答案清单。必答内容齐全后确认范围并要求生成文件。pm_complete 必须提供 documentPath 并引用已生成文件的声明，控制器将核对文件；不需要 MCP/Issue 登记、实现或验收。轮数上限仍是未完成停止的兜底。'
    }
}

if ($LocalOnly -and $SimulatorStyle -eq 'restrained') {
    $completionPolicy.version = 'restrained-local-document-v5'
    $completionPolicy.stopOnClarificationReady = $false
    $completionPolicy.instruction += ' 本地模式覆盖上述仅凭就绪结束的规则：简单和复杂任务均须实际生成文件，pm_complete 必须提供 documentPath 及包含路径的产物声明。clarification_ready、after_probe 或“需求分析已经完成！”不能代替文档证据。文件未核实则先完成范围确认并生成文档；不借此提示隐藏业务答案。'
}

$completionPolicy.instruction += ' 业务规则的未知问题（包括安全规则讨论）使用 needs_human 并标记 interventionKind=business_question，提供 pendingQuestions 原文，登记后继续；实际操作授权、安全违规或不能可靠分类才硬暂停。待决项未清时使用 draft_pending：已知必答内容仍需完成（guided），实际文件必须逐条包含待确认编号和原问题；这是待人工确认终态，不是全部明确或业务通过。仅有就绪声明不能结束带待决项的运行。'
if ($SimulatorStyle -eq 'restrained') {
    $completionPolicy.instruction += ' 分类细化覆盖泛称未决的规则：unresolvedQuote 非空时用 unresolvedKind 区分 business_decision、investigation_blocker、nonblocking_followup、scope_boundary；仅前两类触发一次中性追问。范围免责声明及非阻塞设计或远程跟进不等于业务未决。已登记待决不受此分类豁免。after_probe 可复用 completionAssessment 中 verified_present 的 documentPath，无须在最新回复重复路径，但控制器仍重新检查文件；从未核实的文件不能复用。'
}

function Write-Json($Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject $Value -Depth 40 |
            Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Assert-Keys($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [System.Collections.IDictionary]) { throw 'Expected a JSON object.' }
    foreach ($key in $Required) {
        if (-not $Value.Contains($key)) { throw "Missing required key: $key" }
    }
    foreach ($key in $Value.Keys) {
        if ($key -cnotin ($Required + $Optional)) { throw "Unknown key: $key" }
    }
}

function Write-Input($Path, [string]$Text) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Content -LiteralPath $Path -Raw -Encoding utf8) -cne $Text) {
            throw "Checkpoint input changed: $Path"
        }
    }
    else { $Text | Set-Content -LiteralPath $Path -Encoding utf8 -NoNewline }
}

function Assert-Text($Value, $Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be a nonempty string."
    }
}

function Assert-List($Value, $Name, [switch]$Nonempty) {
    if ($Value -isnot [array] -or ($Nonempty -and $Value.Count -eq 0)) {
        throw "$Name must be a JSON array."
    }
    foreach ($item in $Value) { Assert-Text $item $Name }
    if (@($Value | Sort-Object -Unique).Count -ne $Value.Count) { throw "$Name contains duplicates." }
}

function Read-DialogueProfiles($CapabilityPath, $DomainPath) {
    $capability = Get-Content -LiteralPath $CapabilityPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Assert-Keys $capability @('schemaVersion', 'id', 'version', 'targetRole', 'artifactName', 'readinessQuestion', 'localNotice', 'assessmentCriteria')
    if ($capability.schemaVersion -ne 1) { throw 'Unsupported capability profile schema.' }
    foreach ($key in @('id', 'version', 'targetRole', 'artifactName', 'readinessQuestion', 'localNotice')) { Assert-Text $capability[$key] $key }
    if ($capability.assessmentCriteria -isnot [array] -or -not $capability.assessmentCriteria.Count) { throw 'Capability assessment criteria must be a nonempty array.' }
    $criterionIds = @()
    foreach ($criterion in $capability.assessmentCriteria) {
        Assert-Keys $criterion @('id', 'question')
        Assert-Text $criterion.id 'criterion.id'; Assert-Text $criterion.question 'criterion.question'
        if ($criterion.id -cin $criterionIds) { throw 'Duplicate capability criterion.' }
        $criterionIds += $criterion.id
    }
    $domain = Get-Content -LiteralPath $DomainPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Assert-Keys $domain @('schemaVersion', 'id', 'version', 'forbiddenAnswerIds', 'topics') @('scopeConstraints')
    if ($domain.schemaVersion -ne 1) { throw 'Unsupported domain profile schema.' }
    if ($domain.Contains('scopeConstraints')) { Assert-Text $domain.scopeConstraints 'scopeConstraints' }
    foreach ($key in @('id', 'version')) { Assert-Text $domain[$key] $key }
    Assert-List $domain.forbiddenAnswerIds 'forbiddenAnswerIds'
    if ($domain.topics -isnot [array]) { throw 'Domain topics must be an array.' }
    $topics = [ordered]@{}; $questions = [ordered]@{}; $mapped = @()
    foreach ($topic in $domain.topics) {
        Assert-Keys $topic @('id', 'answerIds', 'question')
        Assert-Text $topic.id 'topic.id'; Assert-Text $topic.question 'topic.question'
        Assert-List $topic.answerIds 'topic.answerIds' -Nonempty
        if ($topics.Contains($topic.id)) { throw 'Duplicate domain topic.' }
        foreach ($id in $topic.answerIds) {
            if ($id -cin $mapped -or $id -cin $domain.forbiddenAnswerIds) { throw 'Topic answer is duplicated or forbidden.' }
            $mapped += $id
        }
        $topics[$topic.id] = $topic.answerIds; $questions[$topic.id] = $topic.question
    }
    return @{ capability = $capability; domain = $domain; topics = $topics; questions = $questions }
}

function Test-Within($Path, $Root) {
    return $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoLinks($Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked paths are not allowed in an evaluation workspace: $current"
            }
        }
        $current = Split-Path $current -Parent
    }
}

function Invoke-Git($Directory, [string[]]$Arguments) {
    $result = & git -C $Directory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' '): $result" }
    return ($result -join "`n")
}

function Initialize-Workspace($Directory) {
    [void](Invoke-Git $Directory @('init', '--quiet', '--initial-branch=main'))
    [void](Invoke-Git $Directory @('-c', 'core.autocrlf=false', 'add', '--all'))
    [void](Invoke-Git $Directory @('-c', 'core.hooksPath=.git/disabled-hooks',
        '-c', 'user.name=Eval Fixture', '-c', 'user.email=eval@example.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m',
        "test: freeze isolated evaluation input`n`nGenerated by Copilot`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"))
}

function Copy-Inputs($Source, $Destination, $Paths) {
    [void](New-Item -ItemType Directory -Path $Destination)
    foreach ($relative in $Paths) {
        $from = [IO.Path]::GetFullPath((Join-Path $Source $relative))
        $to = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
        if (-not (Test-Within $from $Source) -or -not (Test-Within $to $Destination)) {
            throw "Path outside snapshot: $relative"
        }
        Assert-NoLinks $from
        [void](New-Item -ItemType Directory -Path (Split-Path $to) -Force)
        Copy-Item -LiteralPath $from -Destination $to
    }
}

function Invoke-Turn($Workspace, $Evidence, $Agent, $Model, $InputFile, $CliHomePath, [bool]$Resume, [switch]$Simulator) {
    $receiptPath = "$InputFile.call.json"
    $inputHash = (Get-FileHash -LiteralPath $InputFile -Algorithm SHA256).Hash
    $replayed = Test-Path -LiteralPath $receiptPath
    if ($replayed) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.state -ne 'completed') {
            throw "Uncertain call outcome; refusing automatic resend: $receiptPath"
        }
        if ($receipt.inputSha256 -cne $inputHash -or $receipt.model -cne $Model -or $receipt.agent -cne $Agent -or
            -not (Test-Within $receipt.turn $Evidence)) { throw "Checkpoint mismatch: $receiptPath" }
        foreach ($file in $receipt.hashes.Keys) {
            if ((Get-FileHash -LiteralPath (Join-Path $receipt.turn $file) -Algorithm SHA256).Hash -cne $receipt.hashes[$file]) {
                throw "Checkpoint evidence changed: $file"
            }
        }
        $turn = Get-Item -LiteralPath $receipt.turn
        Write-Host "Reusing completed $Agent call: $($turn.Name)"
    }
    else {
        $parameters = @{
            RepositoryPath = $Workspace; RunDirectory = $Evidence; Agent = $Agent
            Model = $Model; PromptFile = $InputFile; CliPath = $CliPath
            TimeoutSeconds = $config.timeoutSeconds; CopilotHome = $CliHomePath; Resume = $Resume
        }
        if ($Simulator) {
            $parameters.NoTools = $true
            $parameters.DisableBuiltinMcps = $true
            $parameters.NoCustomInstructions = $true
        }
        else {
            $parameters.AvailableTool = $config.availableTools
            $parameters.AllowTool = $config.allowTools
            $parameters.DenyTool = $config.denyTools
            $parameters.DisableBuiltinMcps = $config.disableBuiltinMcps
            if ($script:remoteRepository) { $parameters.GitHubRepository = $script:remoteRepository }
        }
        Write-Json $receiptPath @{
            state = 'dispatching'; inputSha256 = $inputHash; model = $Model; agent = $Agent
            startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        & $collector @parameters | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Collector failed with exit $LASTEXITCODE; inspect $Evidence" }
        $turn = Get-ChildItem -LiteralPath $Evidence -Directory -Filter 'turn-*' |
            Sort-Object Name | Select-Object -Last 1
    }
    $meta = Get-Content -LiteralPath (Join-Path $turn.FullName 'turn.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($meta.state -ne 'cli_exited') { throw "Incomplete capture: $($meta.state)" }
    $runtime = Get-Content -LiteralPath (Join-Path $turn.FullName 'runtime.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($runtime.problems.Count) { throw "Runtime/tool error or unsupported ask_user request; inspect $($turn.FullName)" }
    if ($runtime.observedModels.Count -ne 1 -or $runtime.observedModels[0] -cne $Model) {
        throw "Actual model missing or different from '$Model'; inspect $($turn.FullName)"
    }
    $messages = @(Get-Content -LiteralPath (Join-Path $turn.FullName 'assistant-messages.json') -Raw |
        ConvertFrom-Json -AsHashtable)
    if (-not $messages.Count -or $messages[-1].hasToolRequests) {
        throw "No final root-assistant response; inspect $($turn.FullName)"
    }
    if (-not $replayed) {
        $hashes = @{}
        foreach ($file in @('turn.json', 'input.txt', 'runtime.json', 'assistant-messages.json', 'events.stdout', 'events.stderr')) {
            $hashes[$file] = (Get-FileHash -LiteralPath (Join-Path $turn.FullName $file) -Algorithm SHA256).Hash
        }
        Write-Json $receiptPath @{
            state = 'completed'; inputSha256 = $inputHash; model = $Model; agent = $Agent
            turn = $turn.FullName; hashes = $hashes
        }
    }
    return @{
        text = $messages[-1].content; turn = $turn.FullName; usage = $runtime.usage
        warnings = @($runtime.warnings); replayed = $replayed
    }
}

function Get-GuidedCompletionCheck([string[]]$RequiredAnswerIds, [string[]]$DisclosedAnswerIds,
    $PendingItems, $DocumentPath, [string]$PmText, [string]$Workspace, [string]$Baseline) {
    $check = [ordered]@{
        ready = $false
        missingAnswerIds = @($RequiredAnswerIds | Where-Object { $_ -cnotin $DisclosedAnswerIds })
        pendingCount = @($PendingItems).Count
        documentPath = $null
        reason = 'missing_answers'
    }
    if ($check.missingAnswerIds.Count) { return $check }
    if ($check.pendingCount) { $check.reason = 'pending_decisions'; return $check }
    $check.reason = 'document_not_verified'
    if ($DocumentPath -isnot [string] -or [string]::IsNullOrWhiteSpace($DocumentPath)) { return $check }
    $DocumentPath = $DocumentPath.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($DocumentPath) -or $DocumentPath -match '^[A-Za-z]:' -or
        -not $PmText.Replace('\', '/').Contains($DocumentPath, [StringComparison]::Ordinal)) {
        return $check
    }
    try {
        $document = [IO.Path]::GetFullPath((Join-Path $Workspace $DocumentPath))
        $original = [IO.Path]::GetFullPath((Join-Path $Baseline $DocumentPath))
        if (-not (Test-Within $document $Workspace) -or -not (Test-Within $original $Baseline)) { return $check }
        Assert-NoLinks $document
        if (-not (Test-Path -LiteralPath $document -PathType Leaf) -or (Get-Item -LiteralPath $document).Length -eq 0) { return $check }
        if ((Test-Path -LiteralPath $original -PathType Leaf) -and
            (Get-FileHash -LiteralPath $document).Hash -ceq (Get-FileHash -LiteralPath $original).Hash) { return $check }
        $check.documentPath = $DocumentPath
        $check.ready = $true
        $check.reason = 'answers_and_document_verified'
    }
    catch { $check.reason = 'document_not_verified' }
    return $check
}

function Get-RestrainedCompletionCheck($Decision, [int]$ProbeCount, [bool]$RequireDocument = $false,
    [string]$Workspace = '', [string]$Baseline = '', $PreviousAssessment = @{}) {
    $unresolved = -not [string]::IsNullOrWhiteSpace($Decision['unresolvedQuote']) -and
        $Decision['unresolvedKind'] -notin @('nonblocking_followup', 'scope_boundary')
    $check = [ordered]@{
        ready = -not ($unresolved -and $ProbeCount -eq 0)
        reason = if ($unresolved -and $ProbeCount -eq 0) { 'neutral_probe_required' }
            elseif ($unresolved) { 'stopped_with_reported_unknowns' }
            else { 'agent_claimed_completion' }
        artifactStatus = if ($Decision.completionKind -eq 'artifact_produced') { 'claimed_produced' } else { 'not_verified' }
        clarificationStatus = if ($unresolved) { 'unresolved_reported' }
            elseif ($Decision.completionKind -eq 'clarification_ready') { 'agent_claimed_ready' }
            else { 'not_assessed' }
    }
    if ($RequireDocument) {
        $documentCheck = Get-GuidedCompletionCheck @() @() @() $Decision['documentPath'] $Decision.quote $Workspace $Baseline
        if (-not $documentCheck.ready -and $Decision.completionKind -eq 'after_probe' -and $ProbeCount -gt 0 -and
            $PreviousAssessment['artifactStatus'] -eq 'verified_present' -and $PreviousAssessment['documentPath'] -and
            (-not $Decision['documentPath'] -or $Decision['documentPath'] -ceq $PreviousAssessment['documentPath'])) {
            $path = $PreviousAssessment['documentPath']
            $documentCheck = Get-GuidedCompletionCheck @() @() @() $path $path $Workspace $Baseline
        }
        $check['documentPath'] = $documentCheck.documentPath
        $check.artifactStatus = if ($documentCheck.ready) { 'verified_present' } else { 'not_verified' }
        if (-not $documentCheck.ready) {
            $check.ready = $false
            $check.reason = 'document_not_verified'
        }
    }
    return $check
}

function Get-GuidedFollowupId($Preferred, $MissingAnswerIds, $Decisions) {
    $candidates = @($Preferred) + @($guidedTopics.Keys | Where-Object { $_ -cne $Preferred })
    foreach ($topicId in $candidates) {
        $missing = @($guidedTopics[$topicId] | Where-Object { $_ -cin $MissingAnswerIds })
        if (-not $missing.Count) { continue }
        $attempts = @($Decisions | Where-Object {
            $_.Contains('guidanceTopic') -and $_.guidanceTopic -ceq $topicId -and
            ($_.guidanceMissingAnswerIds -join ',') -ceq ($missing -join ',')
        }).Count
        if ($attempts -lt 2) { return $topicId }
    }
    return $null
}

function Get-ScopeDecisionText($Decisions) {
    return (@($Decisions | ForEach-Object {
        $text = if ($_.kind -eq 'preserve_existing') {
            '本期不新增或改变该既有能力，沿用经核实的现行规则；这不确认问题中提出的任一具体行为。请核实现状并记录依据，不以猜测代替事实。若与本期已确认要求冲突，提出具体冲突；不得扩大已确认范围或新增未经批准的例外。'
        } else {
            '该细节转交设计阶段，在已确认范围和业务约束内确定；不据此批准具体方案或扩大范围，不阻塞其他需求澄清。设计若暴露影响核心验收、安全或权限的业务取舍，再提交人工决定。'
        }
        "范围处理：$($_.quote)`n$text"
    }) -join "`n")
}

function Test-DialogueStalled($Decision, $Records, $PendingItems) {
    if ($Decision.action -notin @('correct', 'check_readiness')) { return $false }
    $key = if ($Decision.action -eq 'correct') {
        @('correct', [regex]::Replace($Decision.quote.Trim(), '\s+', ' '), @($Decision.answerIds | Sort-Object)) | ConvertTo-Json -Compress
    } else {
        @('check_readiness', @($PendingItems | ForEach-Object { $_.id } | Sort-Object)) | ConvertTo-Json -Compress
    }
    $Records[-1]['recoveryKey'] = $key
    $recent = @($Records | Select-Object -Last 3)
    return $recent.Count -eq 3 -and @($recent | Where-Object { -not $_.Contains('recoveryKey') -or $_.recoveryKey -cne $key }).Count -eq 0
}

function Add-BusinessQuestions($Run, $Questions, [string]$Evidence) {
    $ids = @()
    foreach ($question in $Questions) {
        $normalized = [regex]::Replace($question.quote.Trim(), '\s+', ' ')
        $existing = @($Run.pendingItems | Where-Object {
            ($question['existingId'] -and $_.id -ceq $question.existingId) -or
            [regex]::Replace($_.question.Trim(), '\s+', ' ') -ceq $normalized
        })
        if ($existing.Count) {
            $item = $existing[0]
            $item.lastRound = $Run.rounds
        }
        else {
            $number = $Run.pendingItems.Count + 1
            do { $id = 'question-{0:d4}' -f $number; $number++ }
            while ($id -cin @($Run.pendingItems | ForEach-Object { $_.id }) -or $answers.ContainsKey($id) -or $deferredTopics.ContainsKey($id))
            $item = [ordered]@{
                id = $id; question = $question.quote
                impact = '待人工评估；不得据此选择默认方案或授权实施。'
                owner = '待指定，由业务方确认'; confirmBefore = '相关决定采用、实现及验收前'
                status = 'pending'; blocksDiscussion = $false; blocksImplementation = $true
                source = 'agent_question'; firstRound = $Run.rounds; lastRound = $Run.rounds
                occurrences = @()
            }
            $Run.pendingItems += $item
        }
        if ($question.Contains('remainingQuestion')) {
            $item['remainingQuestion'] = $question.remainingQuestion
            $item['resolvedAnswerIds'] = @($question.resolvedAnswerIds)
        }
        if (-not $item.Contains('occurrences')) { $item['occurrences'] = @() }
        $item.occurrences += [ordered]@{ round = $Run.rounds; quote = $question.quote; evidence = $Evidence }
        if ($item.id -cnotin $ids) { $ids += $item.id }
    }
    return $ids
}

function Get-PendingDraftCheck($RequiredAnswerIds, $DisclosedAnswerIds, $PendingItems, $DocumentPath, $PmText, $Workspace, $Baseline) {
    $check = Get-GuidedCompletionCheck $RequiredAnswerIds $DisclosedAnswerIds @() $DocumentPath $PmText $Workspace $Baseline
    $check.pendingCount = @($PendingItems).Count
    if (-not $check.ready) { return $check }
    $check.ready = $false
    $check.reason = 'pending_items_not_in_document'
    if (-not $check.pendingCount) { return $check }
    $content = Get-Content -LiteralPath (Join-Path $Workspace $check.documentPath) -Raw -Encoding utf8
    foreach ($item in $PendingItems) {
        if (-not $content.Contains($item.id, [StringComparison]::Ordinal) -or
            -not $content.Contains($item.question, [StringComparison]::Ordinal)) { return $check }
        if ($item.Contains('remainingQuestion') -and -not $content.Contains($item.remainingQuestion, [StringComparison]::Ordinal)) { return $check }
    }
    $check.ready = $true
    $check.reason = 'pending_draft_verified'
    return $check
}

function Read-Decision($Text, $PmText, [string[]]$AskedQuestionIds = @(), [string[]]$DisclosedAnswerIds = @(), $PendingItems = @()) {
    $decision = ConvertFrom-Json -InputObject $Text -AsHashtable
    Assert-Keys $decision @('action', 'answerIds', 'quote', 'reason') @('pendingIds', 'questionId', 'answerQuotes', 'documentPath', 'completionKind', 'unresolvedQuote', 'unresolvedKind', 'interventionKind', 'pendingQuestions', 'scopeDecisions')
    Assert-Text $decision.action 'action'
    Assert-Text $decision.quote 'quote'
    Assert-Text $decision.reason 'reason'
    if ($decision.action -cnotin @('answer', 'correct', 'defer', 'scope_decision', 'check_readiness', 'ask_followup', 'confirm_scope', 'pm_complete', 'draft_pending', 'needs_human')) {
        throw "Invalid simulator action: $($decision.action)"
    }
    $businessQuestion = $false
    if ($decision.action -ceq 'needs_human') {
        if ($decision['interventionKind'] -cnotin @('business_question', 'operation_authorization', 'safety_violation', 'uncertain')) {
            throw 'needs_human requires an explicit interventionKind.'
        }
        $businessQuestion = $decision.interventionKind -ceq 'business_question'
    }
    elseif ($decision.Contains('interventionKind')) { throw 'Only needs_human may classify intervention.' }
    if ($businessQuestion) {
        if ($decision['pendingQuestions'] -isnot [array] -or -not $decision.pendingQuestions.Count) { throw 'Business questions require a nonempty pendingQuestions array.' }
        foreach ($question in $decision.pendingQuestions) {
            Assert-Keys $question @('quote') @('existingId', 'remainingQuestion', 'resolvedAnswerIds')
            Assert-Text $question.quote 'pending question quote'
            if (-not $PmText.Contains($question.quote, [StringComparison]::Ordinal)) { throw 'Pending question must quote the latest Agent reply.' }
            if ($question.Contains('remainingQuestion') -or $question.Contains('resolvedAnswerIds')) {
                Assert-Text $question['remainingQuestion'] 'remainingQuestion'
                if (-not $question.quote.Contains($question.remainingQuestion, [StringComparison]::Ordinal)) { throw 'Remaining question must quote a narrower part of the original question.' }
                Assert-List $question['resolvedAnswerIds'] 'resolvedAnswerIds'
                foreach ($answerId in $question.resolvedAnswerIds) {
                    if ($answerId -cnotin $decision.answerIds -and $answerId -cnotin $DisclosedAnswerIds) { throw 'Resolved parts require delivered or currently selected answers.' }
                }
            }
            if ($question.Contains('existingId')) {
                Assert-Text $question.existingId 'existingId'
                if ($question.existingId -cnotin @($PendingItems | ForEach-Object { $_.id })) { throw 'Unknown existing pending question.' }
            }
        }
    }
    elseif ($decision.Contains('pendingQuestions')) { throw 'Only business questions may add pendingQuestions.' }
    if ($decision.Contains('scopeDecisions')) {
        if ($decision.action -cnotin @('answer', 'defer', 'scope_decision') -and -not $businessQuestion) { throw 'Scope decisions cannot accompany completion, corrections or hard stops.' }
        if ($decision.scopeDecisions -isnot [array] -or -not $decision.scopeDecisions.Count) { throw 'Scope decisions must be a nonempty array.' }
        foreach ($scopeDecision in $decision.scopeDecisions) {
            Assert-Keys $scopeDecision @('kind', 'quote', 'reason')
            if ($scopeDecision.kind -cnotin @('preserve_existing', 'defer_design')) { throw 'Unsupported scope decision.' }
            Assert-Text $scopeDecision.quote 'scope decision quote'
            Assert-Text $scopeDecision.reason 'scope decision reason'
            if (-not $PmText.Contains($scopeDecision.quote, [StringComparison]::Ordinal)) { throw 'Scope decisions must cite an actual current question.' }
        }
    }
    elseif ($decision.action -ceq 'scope_decision') { throw 'scope_decision requires scopeDecisions.' }
    if ($decision.action -ceq 'ask_followup') {
        if ($SimulatorStyle -ne 'guided') { throw 'Follow-up topics are only allowed for the guided simulator.' }
        Assert-Text $decision['questionId'] 'questionId'
        if ($decision.questionId -cnotin @($guidedQuestions.Keys)) { throw 'Follow-up topic must be approved.' }
        if ($decision.questionId -cin $AskedQuestionIds -and
            -not @($guidedTopics[$decision.questionId] | Where-Object { $_ -cin $guidedRequiredAnswerIds -and $_ -cnotin $DisclosedAnswerIds }).Count) {
            throw 'A covered follow-up topic must not be repeated.'
        }
    }
    elseif ($decision.Contains('questionId')) { throw 'Only ask_followup may include questionId.' }
    if ($decision.Contains('documentPath')) {
        if ($decision.action -cnotin @('pm_complete', 'draft_pending')) { throw 'Only completion decisions may include documentPath.' }
        Assert-Text $decision.documentPath 'documentPath'
    }
    if ($SimulatorStyle -eq 'restrained' -and $decision.action -ceq 'pm_complete') {
        if ($decision['completionKind'] -cnotin @('artifact_produced', 'clarification_ready', 'after_probe') -or
            -not $decision.Contains('unresolvedQuote')) { throw 'Restrained completion requires completionKind and unresolvedQuote.' }
        if ($null -ne $decision.unresolvedQuote) {
            Assert-Text $decision.unresolvedQuote 'unresolvedQuote'
            if (-not $PmText.Contains($decision.unresolvedQuote, [StringComparison]::Ordinal)) {
                throw 'Unresolved quote must come from the latest Agent reply, not the Oracle.'
            }
        }
        if ($decision.Contains('unresolvedKind') -and
            ($null -eq $decision.unresolvedQuote -or $decision.unresolvedKind -cnotin @('business_decision', 'investigation_blocker', 'nonblocking_followup', 'scope_boundary'))) {
            throw 'Unresolved classification requires a quoted admission and an approved category.'
        }
    }
    elseif ($decision.Contains('completionKind') -or $decision.Contains('unresolvedQuote') -or $decision.Contains('unresolvedKind')) {
        throw 'Only restrained pm_complete may include completion evidence.'
    }
    Assert-List $decision.answerIds 'answerIds'
    if (@($decision.answerIds | Where-Object { $_ -cin $forbiddenAnswerIds }).Count) {
        throw 'Complete scope answers must never be disclosed as dialogue answers or corrections.'
    }
    if ($SimulatorStyle -eq 'restrained' -and $decision.action -ceq 'correct') {
        foreach ($id in $decision.answerIds) {
            if ($id -cnotin $DisclosedAnswerIds) { throw "Restrained correction cannot disclose a new answer: $id" }
        }
    }
    if (-not $PmText.Contains($decision.quote, [StringComparison]::Ordinal)) {
        throw 'Simulator quote is not present in the latest PM response.'
    }
    foreach ($id in $decision.answerIds) {
        if (-not $answers.ContainsKey($id)) { throw "Unapproved answer ID: $id" }
    }
    if (($decision.action -cin @('answer', 'defer', 'scope_decision') -or $businessQuestion) -and $decision.answerIds.Count) {
        Assert-Keys $decision['answerQuotes'] $decision.answerIds
        foreach ($id in $decision.answerIds) {
            Assert-Text $decision.answerQuotes[$id] "answerQuotes.$id"
            if (-not $PmText.Contains($decision.answerQuotes[$id], [StringComparison]::Ordinal)) {
                throw "Answer question quote is not present in the latest PM reply: $id"
            }
        }
    }
    elseif ($decision.Contains('answerQuotes')) { throw 'Only answer/defer with answers may include answerQuotes.' }
    if ($decision.action -ceq 'defer') {
        if (-not $decision.Contains('pendingIds')) { throw 'Defer requires pendingIds.' }
        Assert-List $decision.pendingIds 'pendingIds' -Nonempty
        foreach ($id in $decision.pendingIds) {
            if (-not $deferredTopics.ContainsKey($id)) { throw "Unapproved deferred topic: $id" }
        }
    }
    elseif ($decision.Contains('pendingIds')) { throw 'Only defer may include pendingIds.' }
    if ($decision.action -cin @('answer', 'correct')) {
        if (-not $decision.answerIds.Count) { throw 'Answer/correction requires approved answer IDs.' }
    }
    elseif ($decision.action -cnotin @('defer', 'scope_decision') -and -not $businessQuestion -and $decision.answerIds.Count) { throw 'This action must not disclose answer IDs.' }
    return $decision
}

$configPath = (Resolve-Path -LiteralPath $ConfigFile).Path
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
Assert-Keys $config @('schemaVersion', 'oracle', 'repositoryPath', 'runDirectory', 'pmAgent',
    'models', 'repetitions', 'roundLimit', 'timeoutSeconds', 'availableTools', 'allowTools',
    'denyTools', 'externalIsolationConfirmed', 'disableBuiltinMcps', 'remoteRepositories', 'domainProfile') @('capabilityProfile', 'simulatorAgentFile')
if ($config.schemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
foreach ($name in @('repetitions', 'roundLimit', 'timeoutSeconds')) {
    if ($config[$name] -isnot [long] -and $config[$name] -isnot [int]) { throw "$name must be an integer." }
    if ($config[$name] -lt 1) { throw "$name must be positive." }
}
if ($config.timeoutSeconds -gt 86400) { throw 'timeoutSeconds exceeds collector limit.' }
foreach ($name in @('oracle', 'repositoryPath', 'runDirectory', 'pmAgent', 'domainProfile')) { Assert-Text $config[$name] $name }
foreach ($name in @('models', 'availableTools')) { Assert-List $config[$name] $name -Nonempty }
foreach ($name in @('allowTools', 'denyTools', 'remoteRepositories')) { Assert-List $config[$name] $name }
if ($config.externalIsolationConfirmed -isnot [bool] -or $config.disableBuiltinMcps -isnot [bool]) {
    throw 'Isolation and MCP flags must be JSON booleans.'
}
if ($SimulatorModel -eq 'auto' -or $config.models -contains 'auto') { throw 'Pin explicit model IDs; auto is not an evaluation model.' }
if ($config.pmAgent -notmatch '^[\w-]+$') { throw 'Invalid PM Agent name.' }

$profileSources = [ordered]@{}
foreach ($entry in @(@{ key = 'capabilityProfile'; default = 'profiles/pm.json'; snapshot = 'capability-profile.json' },
    @{ key = 'domainProfile'; default = ''; snapshot = 'domain-profile.json' })) {
    $path = Join-Path $framework $entry.default
    if ($config.Contains($entry.key)) {
        Assert-Text $config[$entry.key] $entry.key
        $path = if ([IO.Path]::IsPathRooted($config[$entry.key])) { $config[$entry.key] } else { Join-Path (Split-Path $configPath) $config[$entry.key] }
    }
    $profileSources[$entry.snapshot] = [IO.Path]::GetFullPath($path)
}
$profiles = Read-DialogueProfiles $profileSources['capability-profile.json'] $profileSources['domain-profile.json']
$capability = $profiles.capability
$guidedTopics = $profiles.topics; $guidedQuestions = $profiles.questions
$forbiddenAnswerIds = $profiles.domain.forbiddenAnswerIds
$localNotice = $capability.localNotice
$completionPolicy.instruction = $completionPolicy.instruction.Replace('需求文件', $capability.artifactName)
if ($config.Contains('simulatorAgentFile')) {
    Assert-Text $config.simulatorAgentFile 'simulatorAgentFile'
    $simulatorAgentFile = if ([IO.Path]::IsPathRooted($config.simulatorAgentFile)) { $config.simulatorAgentFile } else { Join-Path (Split-Path $configPath) $config.simulatorAgentFile }
    $simulatorAgentFile = [IO.Path]::GetFullPath($simulatorAgentFile)
    if ((Split-Path $simulatorAgentFile -Leaf) -notmatch '^(?<agent>[\w-]+)\.agent\.md$') { throw 'Simulator definition must be named <agent>.agent.md.' }
    $simulatorAgent = $Matches.agent
}
$profileIdentity = @{ capability = @{ id = $capability.id; version = $capability.version }; domain = @{ id = $profiles.domain.id; version = $profiles.domain.version }; targetAgent = $config.pmAgent; simulatorAgent = $simulatorAgent }
$source = (Resolve-Path -LiteralPath $config.repositoryPath).Path
$output = [IO.Path]::GetFullPath($config.runDirectory)
$oraclePath = if ([IO.Path]::IsPathRooted($config.oracle)) {
    [IO.Path]::GetFullPath($config.oracle)
}
else { [IO.Path]::GetFullPath((Join-Path (Split-Path $configPath) $config.oracle)) }
foreach ($path in (@($source, $output, $oraclePath, $framework, $simulatorAgentFile) + @($profileSources.Values))) { Assert-NoLinks $path }
foreach ($private in (@($output, $framework, $oraclePath, $configPath, $simulatorAgentFile) + @($profileSources.Values))) {
    if ((Test-Within $private $source) -or (Test-Within $source $private)) {
        throw 'Evaluation framework, oracle, configuration and output must be separate from the product source.'
    }
}
if ((Test-Path -LiteralPath $output) -and -not $Resume) { throw 'RunDirectory already exists; use a new directory or explicit Resume.' }
if ($Resume -and -not (Test-Path -LiteralPath (Join-Path $output 'experiment.json'))) { throw 'No experiment to resume.' }
if (-not (Test-Path -LiteralPath (Join-Path $source ".github\agents\$($config.pmAgent).agent.md"))) {
    throw 'PM Agent file not found in product source.'
}
$safeTools = @('view', 'glob', 'grep', 'create', 'edit', 'apply_patch')
$externalTools = @($config.availableTools | Where-Object { $_ -cnotin $safeTools })
if ($LocalOnly -and ($externalTools.Count -or -not $config.disableBuiltinMcps -or $config.remoteRepositories.Count)) {
    throw 'LocalOnly requires local file tools, disableBuiltinMcps=true and no remoteRepositories.'
}
if (($externalTools.Count -or -not $config.disableBuiltinMcps -or $config.remoteRepositories.Count) -and
    -not $config.externalIsolationConfirmed) {
    throw 'Shell/MCP/other tools require externally enforced isolation and externalIsolationConfirmed=true.'
}
if ($config.availableTools -contains 'ask_user') {
    throw 'CLI text-turn transport does not support ask_user; omit it from availableTools.'
}
$runCount = $config.models.Count * $config.repetitions
if ($config.remoteRepositories.Count -and $config.remoteRepositories.Count -ne $runCount) {
    throw 'Remote artifact tests require a distinct, pre-provisioned sandbox repository for every independent run.'
}
$protectedRepositories = @()
if ($config.remoteRepositories.Count) {
    $sourceRemotes = @(& git -C $source remote -v)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect product remotes before enabling sandbox repositories.' }
    foreach ($line in $sourceRemotes) {
        if ($line -match '[:/](?<owner>[\w.-]+)/(?<repository>[\w.-]+?)(?:\.git)?\s+\(') {
            $protectedRepositories += "$($Matches.owner)/$($Matches.repository)"
        }
    }
}
foreach ($remote in $config.remoteRepositories) {
    if ($remote -notmatch '^[\w.-]+/[\w.-]+$' -or $remote -iin $protectedRepositories) {
        throw 'Invalid sandbox repository or protected product repository.'
    }
}
$oracle = Get-Content -LiteralPath $oraclePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
Assert-Keys $oracle @('id', 'version', 'approvedBy', 'initialRequest', 'confirmation', 'answers', 'unresolved', 'deferredTopics')
foreach ($name in @('id', 'version', 'approvedBy', 'initialRequest', 'confirmation')) { Assert-Text $oracle[$name] $name }
if ($oracle.answers -isnot [array] -or -not $oracle.answers.Count) { throw 'Oracle requires answers.' }
$answers = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($answer in $oracle.answers) {
    Assert-Keys $answer @('id', 'topic', 'text')
    foreach ($name in @('id', 'topic', 'text')) { Assert-Text $answer[$name] $name }
    if (-not $answers.TryAdd($answer.id, $answer.text)) { throw "Duplicate Oracle ID: $($answer.id)" }
}
if (-not $answers.TryAdd('initial_request', $oracle.initialRequest)) { throw 'initial_request is reserved for the public initial request.' }
$guidedRequiredAnswerIds = @($oracle.answers | Where-Object { $_.id -cnotin $forbiddenAnswerIds } | ForEach-Object { $_.id })
if ($SimulatorStyle -eq 'guided') {
    $mappedIds = @($guidedTopics.Values | ForEach-Object { $_ })
    foreach ($id in $guidedRequiredAnswerIds) {
        if ($id -cnotin $mappedIds) { throw "Guided required answer has no question topic: $id" }
    }
}
Assert-List $oracle.unresolved 'unresolved'
$deferredTopics = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
if ($oracle.deferredTopics -isnot [array]) { throw 'deferredTopics must be an array.' }
foreach ($topic in $oracle.deferredTopics) {
    Assert-Keys $topic @('id', 'question', 'impact', 'owner', 'confirmBefore')
    foreach ($key in @('id', 'question', 'impact', 'owner', 'confirmBefore')) { Assert-Text $topic[$key] $key }
    if ($answers.ContainsKey($topic.id) -or -not $deferredTopics.TryAdd($topic.id, $topic)) {
        throw "Duplicate deferred topic ID: $($topic.id)"
    }
}

$contract = [ordered]@{
    config = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    oracle = (Get-FileHash -LiteralPath $oraclePath -Algorithm SHA256).Hash
    controller = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    collector = (Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash
    processCapture = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'CapturedProcess.psm1') -Algorithm SHA256).Hash
    reporter = (Get-FileHash -LiteralPath $reporter -Algorithm SHA256).Hash
    simulator = (Get-FileHash -LiteralPath $simulatorAgentFile -Algorithm SHA256).Hash
    simulatorStyle = $SimulatorStyle; simulatorAgent = $simulatorAgent
    localOnly = [bool]$LocalOnly
    simulatorModel = $SimulatorModel; cli = (Get-Command $CliPath -ErrorAction Stop).Source
    completionPolicyVersion = $completionPolicy.version
    capabilityProfile = (Get-FileHash -LiteralPath $profileSources['capability-profile.json']).Hash
    domainProfile = (Get-FileHash -LiteralPath $profileSources['domain-profile.json']).Hash
} | ConvertTo-Json -Compress
if (-not $Resume) { [void](New-Item -ItemType Directory -Path $output) }
$lock = [IO.File]::Open((Join-Path $output 'experiment.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
if ($Resume) {
    try {
        $previous = Get-Content -LiteralPath (Join-Path $output 'experiment.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($previous['checkpointVersion'] -ne 1 -or $previous['contract'] -cne $contract) {
            throw 'Resume requires unchanged configuration, Oracle, models, CLI path and implementation.'
        }
        if ($previous.state -notin @('paused', 'running')) {
            throw "Cannot resume experiment state: $($previous.state). Start a new experiment after human review."
        }
        foreach ($file in $previous.inputFiles) {
            $path = Join-Path (Join-Path $output 'baseline') $file.path
            Assert-NoLinks $path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $file.sha256) { throw "Frozen input changed: $path" }
        }
        foreach ($file in @('config.json', 'oracle.json')) {
            $expected = if ($file -eq 'config.json') { $configPath } else { $oraclePath }
            if ((Get-FileHash (Join-Path $output $file)).Hash -cne (Get-FileHash $expected).Hash) { throw "Frozen $file changed." }
        }
        foreach ($file in $profileSources.Keys) {
            if ((Get-FileHash (Join-Path $output $file)).Hash -cne (Get-FileHash $profileSources[$file]).Hash) { throw "Frozen profile changed: $file" }
        }
        foreach ($file in @($collector, (Join-Path $PSScriptRoot 'CapturedProcess.psm1'), $reporter, $PSCommandPath, $simulatorAgentFile)) {
            if ((Get-FileHash (Join-Path (Join-Path $output 'runner') (Split-Path $file -Leaf))).Hash -cne (Get-FileHash $file).Hash) {
                throw 'Frozen implementation changed.'
            }
        }
    }
    catch { $lock.Dispose(); throw }
}
$manifest = @{
    schemaVersion = 1; caseId = $oracle.id; oracleVersion = $oracle.version
    protocolVersion = if ($SimulatorStyle -eq 'guided') { 'dialogue-guided-v9' } else { 'dialogue-restrained-v10' }
    simulatorStyle = $SimulatorStyle; simulatorAgent = $simulatorAgent
    localOnly = [bool]$LocalOnly
    errorPolicyVersion = 'local-read-errors-v2'
    completionPolicyVersion = $completionPolicy.version
    profiles = $profileIdentity
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); state = 'preparing'
    evaluation = 'not_scored'; simulatorModel = $SimulatorModel; config = $config
    source = $source; plannedRunCount = $runCount; runs = @(); errors = @()
    isolation = 'Fresh workspace and CLI home per role/run; not an OS sandbox. External tool access requires external enforcement.'
    checkpointVersion = 1; contract = $contract; resumeCount = 0
}
if ($Resume) {
    $manifest = $previous
    $manifest.resumeCount++
    $manifest.runs = @()
}
$exitCode = 0
$newRounds = 0
try {
    if (-not $Resume) {
    Write-Json (Join-Path $output 'experiment.json') $manifest
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $output 'config.json')
    Copy-Item -LiteralPath $oraclePath -Destination (Join-Path $output 'oracle.json')
    foreach ($file in $profileSources.Keys) { Copy-Item -LiteralPath $profileSources[$file] -Destination (Join-Path $output $file) }
    $manifest.oracleSha256 = (Get-FileHash -LiteralPath $oraclePath -Algorithm SHA256).Hash
    $manifest.sourceHead = (Invoke-Git $source @('rev-parse', 'HEAD')).Trim()
    $manifest.sourceStatus = Invoke-Git $source @('status', '--porcelain=v1', '--untracked-files=all')
    $paths = @((Invoke-Git $source @('ls-files', '--cached', '--others', '--exclude-standard', '-z')) -split "`0" |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $source $_) -PathType Leaf) } |
        Sort-Object -Unique)
    $excluded = '^(\.vscode/|\.github/(hooks/|mcp|prompts/maintain-sdlc-agent)|\.copilot/|docs/eval-Agent/|docs/guides/sdlc-capture\.md$|tools/(Invoke-SdlcCapture\.ps1|CapturedProcess\.psm1)$|tests/(Test-SdlcCapture\.ps1|fixtures/fake-copilot\.ps1)$)|(^|/)\.env($|\.(?!example$))'
    $manifest.excludedPaths = @($paths | Where-Object { $_ -match $excluded })
    $paths = @($paths | Where-Object { $_ -notmatch $excluded })
    $baseline = Join-Path $output 'baseline'
    Copy-Inputs $source $baseline $paths
    $manifest.inputFiles = @($paths | ForEach-Object {
        @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $baseline $_) -Algorithm SHA256).Hash }
    })
    $frozenTools = Join-Path $output 'runner'
    [void](New-Item -ItemType Directory -Path $frozenTools)
    foreach ($file in @($collector, (Join-Path $PSScriptRoot 'CapturedProcess.psm1'), $reporter, $PSCommandPath, $simulatorAgentFile)) {
        Copy-Item -LiteralPath $file -Destination $frozenTools
    }
    }
    else {
        $baseline = Join-Path $output 'baseline'
        $paths = @($manifest.inputFiles | ForEach-Object { $_.path })
        $frozenTools = Join-Path $output 'runner'
    }
    $collector = Join-Path $frozenTools 'Invoke-SdlcCapture.ps1'
    $reporter = Join-Path $frozenTools 'Export-PmReport.ps1'
    $manifest.state = 'running'
    $index = 0
    for ($repetition = 1; $repetition -le $config.repetitions; $repetition++) {
        foreach ($model in $config.models) {
            $index++
            $runPath = Join-Path $output ('run-{0:d3}' -f $index)
            $existingRun = Test-Path -LiteralPath $runPath
            $resultPath = Join-Path $runPath 'result.json'
            if ($Resume -and $existingRun -and (Test-Path -LiteralPath $resultPath)) {
                $savedRun = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
                if ($savedRun.index -ne $index -or $savedRun.model -cne $model -or
                    $savedRun.repetition -ne $repetition -or $savedRun.path -cne $runPath) {
                    throw "Saved run identity mismatch: $resultPath"
                }
                if ($savedRun.state -in @('invalid', 'stopped')) {
                    $manifest.runs += $savedRun
                    if ($savedRun.state -eq 'invalid') { $exitCode = 1 }
                    Write-Json (Join-Path $output 'experiment.json') $manifest
                    Write-Host "Preserving terminal run $index ($($savedRun.state)); no calls repeated."
                    continue
                }
            }
            if (-not $existingRun) { [void](New-Item -ItemType Directory -Path $runPath) }
            $run = @{
                index = $index; model = $model; repetition = $repetition; rounds = 0
                protocolVersion = $manifest.protocolVersion
                simulatorStyle = $SimulatorStyle; simulatorAgent = $simulatorAgent
                localOnly = [bool]$LocalOnly
                errorPolicyVersion = $manifest.errorPolicyVersion
                completionPolicyVersion = $completionPolicy.version
                profiles = $profileIdentity
                assessments = @{ capability = 'not_scored'; domain = 'not_scored' }
                assessmentCriteria = @{ capability = $capability.assessmentCriteria; domainAnswerIds = $guidedRequiredAnswerIds }
                state = 'running'; stopReason = $null; evaluation = 'not_scored'
                startedAt = [DateTimeOffset]::UtcNow.ToString('o'); path = $runPath
                transcript = @(); decisions = @(); usage = @{ pm = @(); simulator = @() }; errors = @(); warnings = @()
                pendingItems = @(); requirementsStatus = 'not_assessed'
                completionOutcome = 'not_completed'
                pendingDraftCheck = $null
                disclosedAnswerIds = @()
                guidedCoverage = $null
                completionAssessment = [ordered]@{ neutralProbeCount = 0; artifactStatus = 'not_verified'; clarificationStatus = 'not_assessed' }
            }
            $manifest.runs += $run
            Write-Json (Join-Path $output 'experiment.json') $manifest
            try {
                $workspace = Join-Path $runPath 'pm-workspace'
                $script:remoteRepository = if ($config.remoteRepositories.Count) { $config.remoteRepositories[$index - 1] } else { $null }
                $userWorkspace = Join-Path $runPath 'user-workspace'
                $pmHome = Join-Path $runPath 'pm-home'
                $userHome = Join-Path $runPath 'user-home'
                if ($existingRun) {
                    if (-not (Test-Path -LiteralPath (Join-Path $runPath 'workspace-ready.json'))) {
                        throw 'Workspace initialization was interrupted; start a new experiment.'
                    }
                    $ready = Get-Content (Join-Path $runPath 'workspace-ready.json') -Raw | ConvertFrom-Json
                    $run.startedAt = $ready.startedAt
                }
                else {
                    Copy-Inputs $baseline $workspace $paths
                    Initialize-Workspace $workspace
                    if ($script:remoteRepository) {
                        [void](Invoke-Git $workspace @('remote', 'add', 'origin', "https://github.com/$script:remoteRepository.git"))
                    }
                    $agentDirectory = Join-Path $userWorkspace '.github\agents'
                    [void](New-Item -ItemType Directory -Path $agentDirectory -Force)
                    Copy-Item -LiteralPath (Join-Path $frozenTools "$simulatorAgent.agent.md") -Destination $agentDirectory
                    Initialize-Workspace $userWorkspace
                    foreach ($cliHomePath in @($pmHome, $userHome)) { [void](New-Item -ItemType Directory -Path $cliHomePath) }
                    Write-Json (Join-Path $runPath 'workspace-ready.json') @{ startedAt = $run.startedAt }
                }
                $pmEvidence = Join-Path $runPath 'pm'
                $userEvidence = Join-Path $runPath 'simulator'
                $nextInput = $oracle.initialRequest
                $nextAnswerIds = @('initial_request')
                $nextIsNeutralProbe = $false
                $userTurns = 0
                while ($true) {
                    $run.rounds++
                    $round = Join-Path $runPath ('round-{0:d2}' -f $run.rounds)
                    if (-not (Test-Path -LiteralPath $round)) { [void](New-Item -ItemType Directory -Path $round) }
                    $inputFile = Join-Path $round 'pm-input.txt'
                    $pmInput = $nextInput
                    if ($LocalOnly) { $pmInput += "`n`n$localNotice" }
                    Write-Input $inputFile $pmInput
                    $run.transcript += [ordered]@{ role = 'user'; content = $pmInput }
                    if ($nextIsNeutralProbe) { $run.completionAssessment.neutralProbeCount++ }
                    $nextIsNeutralProbe = $false
                    foreach ($id in $nextAnswerIds) {
                        if ($id -cnotin $run.disclosedAnswerIds) { $run.disclosedAnswerIds += $id }
                    }
                    if ($SimulatorStyle -eq 'guided') {
                        $run.guidedCoverage = Get-GuidedCompletionCheck $guidedRequiredAnswerIds $run.disclosedAnswerIds $run.pendingItems $null '' $workspace $baseline
                        $run.guidedCoverage['requiredAnswerIds'] = $guidedRequiredAnswerIds
                    }
                    $pm = Invoke-Turn $workspace $pmEvidence $config.pmAgent $model $inputFile $pmHome ($run.rounds -gt 1)
                    $run.usage.pm += $pm.usage
                    foreach ($warning in $pm.warnings) {
                        $run.warnings += @{ round = $run.rounds; role = 'pm'; evidence = $pm.turn; warning = $warning }
                    }
                    $run.transcript += [ordered]@{ role = 'assistant'; content = $pm.text; evidence = $pm.turn }
                    Write-Json (Join-Path $runPath 'result.json') $run
                    if ($run.rounds -gt $config.roundLimit) {
                        $run.stopReason = 'round_limit_exceeded'
                        break
                    }
                    $userInput = Join-Path $round 'simulator-input.json'
                    $askedQuestionIds = @($run.decisions | ForEach-Object {
                        $effective = if ($_.Contains('controllerDecision')) { $_.controllerDecision } else { $_.decision }
                        if ($effective.action -ceq 'ask_followup') { $effective.questionId }
                    })
                    $simulatorRequest = [ordered]@{
                        protocolVersion = $manifest.protocolVersion
                        simulatorStyle = $SimulatorStyle
                        localOnly = [bool]$LocalOnly
                        completionPolicy = $completionPolicy
                        completionAssessment = $run.completionAssessment
                        capability = $capability
                        decisionPolicy = [ordered]@{
                            version = 'bounded-scope-v3'
                            domainConstraints = $profiles.domain['scopeConstraints']
                            instruction = '逐一拆分实际问题，按已有批准答案、明确保留的人工决策、授权政策、未知问题的顺序处理；已披露答案被误记为未知时应纠正，重复待决复用原编号。保持现状仅适用于本期不改变的相邻能力，不得覆盖核心要求或已保留的人工决策，不断言未核实的现状。仅不影响核心验收、安全、权限或隐私取舍的细节可转交设计。复合问题保留原文，仅将剩余未知部分登记待决。范围决定不算必答覆盖；只处理实际提出的问题，不主动枚举外围场景。'
                        }
                        forbiddenAnswerIds = $forbiddenAnswerIds
                        oracle = $oracle; dialogue = $run.transcript
                        pendingItems = $run.pendingItems
                        disclosedAnswerIds = $run.disclosedAnswerIds
                        initialRequestAnswerId = 'initial_request'
                        askedQuestionIds = $askedQuestionIds
                        guidedQuestions = $(if ($SimulatorStyle -eq 'guided') { $guidedQuestions } else { $null })
                        guidedCoverage = $run.guidedCoverage
                        guidedTopics = $(if ($SimulatorStyle -eq 'guided') { $guidedTopics } else { $null })
                        latestPmReply = $pm.text
                    }
                    Write-Input $userInput (ConvertTo-Json -InputObject $simulatorRequest -Depth 40)
                    $user = Invoke-Turn $userWorkspace $userEvidence $simulatorAgent $SimulatorModel $userInput $userHome ($userTurns -gt 0) -Simulator
                    $userTurns++
                    $run.usage.simulator += $user.usage
                    $decision = Read-Decision $user.text $pm.text $askedQuestionIds $run.disclosedAnswerIds $run.pendingItems
                    $scopeText = if ($decision.Contains('scopeDecisions')) { Get-ScopeDecisionText $decision.scopeDecisions } else { '' }
                    Write-Json (Join-Path $round 'decision.json') $decision
                    $run.decisions += @{ round = $run.rounds; decision = $decision; evidence = $user.turn }
                    if ($decision.action -eq 'needs_human' -and $decision.interventionKind -eq 'business_question') {
                        $pendingIds = @(Add-BusinessQuestions $run $decision.pendingQuestions $user.turn)
                        $run.requirementsStatus = 'pending_decisions'
                        $decision = @{ action = 'defer_question'; answerIds = @($decision.answerIds); quote = $decision.quote; reason = 'Record the business decision without choosing an answer; continue clarification.'; pendingIds = $pendingIds }
                        $run.decisions[-1]['controllerDecision'] = $decision
                        if ($SimulatorStyle -eq 'guided') {
                            $run.guidedCoverage = Get-GuidedCompletionCheck $guidedRequiredAnswerIds $run.disclosedAnswerIds $run.pendingItems $null '' $workspace $baseline
                            $run.guidedCoverage['requiredAnswerIds'] = $guidedRequiredAnswerIds
                        }
                    }
                    $pendingCompletion = $decision.action -in @('pm_complete', 'draft_pending') -and $run.pendingItems.Count -gt 0
                    if ($decision.action -eq 'draft_pending' -and -not $run.pendingItems.Count) { throw 'draft_pending requires recorded unresolved questions.' }
                    if ($pendingCompletion) {
                        $required = if ($SimulatorStyle -eq 'guided') { $guidedRequiredAnswerIds } else { @() }
                        $run.pendingDraftCheck = Get-PendingDraftCheck @($required) $run.disclosedAnswerIds $run.pendingItems $decision['documentPath'] $decision.quote $workspace $baseline
                        $run.decisions[-1]['completionCheck'] = $run.pendingDraftCheck
                        if ($run.pendingDraftCheck.ready) {
                            $run.completionAssessment.artifactStatus = 'verified_present'
                            $run.completionAssessment.clarificationStatus = 'pending_decisions'
                            $run.completionOutcome = 'pending_confirmation'
                            $run.stopReason = 'draft_pending_confirmation'
                            $run.decisions[-1]['controllerDecision'] = @{ action = 'draft_pending'; answerIds = @(); quote = $decision.quote; reason = 'Verified draft retains pending IDs and original questions; human decisions are still required.' }
                            break
                        }
                        $decision = @{ action = 'check_readiness'; answerIds = @(); quote = $decision.quote; reason = 'Pending draft requires answered known questions and a verified file retaining the ledger.' }
                        if ($run.pendingDraftCheck.missingAnswerIds.Count) {
                            $decision.action = 'ask_followup'
                            $decision['questionId'] = @($guidedTopics.Keys | Where-Object { @($guidedTopics[$_] | Where-Object { $_ -cin $run.pendingDraftCheck.missingAnswerIds }).Count })[0]
                        }
                        $run.decisions[-1]['controllerDecision'] = $decision
                    }
                    if ($SimulatorStyle -eq 'restrained' -and $decision.action -eq 'pm_complete') {
                        if ($decision.completionKind -eq 'after_probe' -and -not $run.completionAssessment.neutralProbeCount) {
                            throw 'after_probe requires an actually delivered neutral probe.'
                        }
                        $check = Get-RestrainedCompletionCheck $decision $run.completionAssessment.neutralProbeCount ([bool]$LocalOnly) $workspace $baseline $run.completionAssessment
                        $run.decisions[-1]['completionCheck'] = $check
                        if ($check.artifactStatus -in @('claimed_produced', 'verified_present') -or $LocalOnly) { $run.completionAssessment.artifactStatus = $check.artifactStatus }
                        if ($LocalOnly) { $run.completionAssessment['documentPath'] = $check.documentPath }
                        $run.completionAssessment.clarificationStatus = $check.clarificationStatus
                        if (-not $check.ready) {
                            $decision = if ($check.reason -eq 'document_not_verified') {
                                @{ action = 'check_readiness'; answerIds = @(); quote = $decision.quote; reason = 'Local completion requires a verified document, not oral readiness.' }
                            } else {
                                @{ action = 'check_pending'; answerIds = @(); quote = $decision.unresolvedQuote; reason = 'One neutral probe based only on the Agent-reported unknowns.' }
                            }
                            $run.decisions[-1]['controllerDecision'] = $decision
                        }
                    }
                    if ($SimulatorStyle -eq 'guided' -and $decision.action -eq 'pm_complete') {
                        $run.guidedCoverage = Get-GuidedCompletionCheck $guidedRequiredAnswerIds $run.disclosedAnswerIds $run.pendingItems $decision['documentPath'] $decision.quote $workspace $baseline
                        $run.guidedCoverage['requiredAnswerIds'] = $guidedRequiredAnswerIds
                        $run.decisions[-1]['completionCheck'] = $run.guidedCoverage
                        if ($run.guidedCoverage.ready) {
                            $run.completionAssessment.artifactStatus = 'verified_present'
                            $run.completionAssessment.clarificationStatus = 'required_answers_delivered'
                        }
                        if (-not $run.guidedCoverage.ready) {
                            $decision = @{ action = 'check_readiness'; answerIds = @(); quote = $decision.quote; reason = 'Guided completion gate requires answered questions and a produced document.' }
                            if ($run.guidedCoverage.missingAnswerIds.Count) {
                                $decision.action = 'ask_followup'
                                $decision['questionId'] = @($guidedTopics.Keys | Where-Object {
                                    @($guidedTopics[$_] | Where-Object { $_ -cin $run.guidedCoverage.missingAnswerIds }).Count
                                })[0]
                            }
                            $run.decisions[-1]['controllerDecision'] = $decision
                        }
                    }
                    if ($decision.action -eq 'defer') {
                        foreach ($id in $decision.pendingIds) {
                            $existing = @($run.pendingItems | Where-Object { $_.id -ceq $id })
                            if ($existing.Count) { $existing[0].lastRound = $run.rounds }
                            else {
                                $topic = $deferredTopics[$id]
                                $run.pendingItems += [ordered]@{
                                    id = $id; question = $topic.question; impact = $topic.impact
                                    owner = $topic.owner; confirmBefore = $topic.confirmBefore
                                    status = 'pending'; blocksDiscussion = $false
                                    blocksImplementation = $true; source = 'oracle_deferred_topic'
                                    firstRound = $run.rounds; lastRound = $run.rounds
                                }
                            }
                        }
                        $run.requirementsStatus = 'pending_decisions'
                        if ($SimulatorStyle -eq 'guided') {
                            $run.guidedCoverage = Get-GuidedCompletionCheck $guidedRequiredAnswerIds $run.disclosedAnswerIds $run.pendingItems $null '' $workspace $baseline
                            $run.guidedCoverage['requiredAnswerIds'] = $guidedRequiredAnswerIds
                        }
                    }
                    if ($decision.action -eq 'pm_complete') {
                        $run.completionOutcome = if ($SimulatorStyle -eq 'guided') { 'complete' } else { 'agent_claim_only' }
                        $run.stopReason = if ($SimulatorStyle -eq 'restrained' -and $run.completionAssessment.clarificationStatus -eq 'unresolved_reported') { 'pm_stopped_with_unresolved' } else { 'pm_claimed_complete' }
                        break
                    }
                    if ($decision.action -eq 'needs_human') {
                        $run.state = 'needs_human'; $run.stopReason = 'oracle_or_interaction_gap'
                        $exitCode = 2
                        Write-Warning "Run $index needs human input: $($decision.reason)"
                        break
                    }
                    if (Test-DialogueStalled $decision $run.decisions $run.pendingItems) {
                        $run.stopReason = 'dialogue_stalled'
                        $run.decisions[-1]['controllerDecision'] = @{ action = 'stop_incomplete'; answerIds = @(); quote = $decision.quote; reason = 'Two identical recovery messages were delivered without resolving the same contradiction or document-delivery gap.' }
                        break
                    }
                    if ($decision.action -eq 'confirm_scope') {
                        $nextInput = if ($run.pendingItems.Count) {
                            '仅确认已明确的讨论范围；仍有待确认事项，不能视为需求全部明确、实现授权或验收通过。'
                        } elseif ($SimulatorStyle -eq 'restrained') {
                            '仅确认已明确讨论的内容；尚未讨论的行为不在本次确认之内。'
                        } else { $oracle.confirmation }
                    }
                    elseif ($decision.action -eq 'check_pending') {
                        $nextInput = '你提到还有未讨论或待确认事项。其中是否有需要我现在回答、才能明确本次任务的问题？如果有，请直接向我提问。'
                        $nextIsNeutralProbe = $true
                    }
                    elseif ($decision.action -eq 'check_readiness') {
                        $nextInput = if ($run.pendingItems.Count) {
                            "请继续处理其他可明确的问题；确认已讨论范围后，在当前工作区生成$($capability.artifactName)，逐字保留全部待确认编号和原问题，标记待人工确认，并明确已生成的文件路径。不要替待决项作出决定。"
                        } elseif ($SimulatorStyle -eq 'guided' -or $LocalOnly) {
                            "还有问题吗？请先完成必要的范围确认；确认后在当前工作区生成$($capability.artifactName)，并明确说明已生成的文件路径。仅表示没有问题或可以起草不代表文件已经产出。"
                        } else { $capability.readinessQuestion }
                    }
                    elseif ($decision.action -eq 'ask_followup') {
                        $missing = @($guidedRequiredAnswerIds | Where-Object { $_ -cnotin $run.disclosedAnswerIds })
                        $topicId = Get-GuidedFollowupId $decision.questionId $missing $run.decisions
                        if (-not $topicId) {
                            $run.stopReason = 'guidance_stalled'
                            $run.completionOutcome = 'not_completed'
                            $run.decisions[-1]['controllerDecision'] = @{ action = 'stop_incomplete'; answerIds = @(); quote = $decision.quote; reason = 'All remaining topics have received two prompts without new answer coverage.' }
                            break
                        }
                        if ($topicId -cne $decision.questionId) {
                            $decision = @{ action = 'ask_followup'; answerIds = @(); questionId = $topicId; quote = $decision.quote; reason = 'Move to another missing topic after two unproductive prompts.' }
                            $run.decisions[-1]['controllerDecision'] = $decision
                        }
                        $run.decisions[-1]['guidanceTopic'] = $topicId
                        $run.decisions[-1]['guidanceMissingAnswerIds'] = @($guidedTopics[$topicId] | Where-Object { $_ -cin $missing })
                        $nextInput = $guidedQuestions[$topicId]
                    }
                    else {
                        $nextInput = ($decision.answerIds | ForEach-Object { $answers[$_] }) -join "`n"
                        if ($decision.action -eq 'correct') { $nextInput = "这里需要纠正。你刚才的原文：`n$($decision.quote)`n已明确的事实：`n$nextInput" }
                        if ($decision.action -eq 'defer') {
                            $notes = @($decision.pendingIds | ForEach-Object {
                                $topic = $deferredTopics[$_]
                                "待确认：$($topic.question)`n影响：$($topic.impact)`n确认责任：$($topic.owner)`n确认阶段：$($topic.confirmBefore)"
                            }) -join "`n"
                            $nextInput = (@($nextInput, $notes) | Where-Object { $_ }) -join "`n"
                        }
                        if ($decision.action -eq 'defer_question') {
                            $nextInput = (@($nextInput, '这个问题需要进一步考虑，请保留为待人工确认，不选择默认方案，也不要把现有实现视为批准答案。请继续分析是否还有其他问题需要澄清？') | Where-Object { $_ }) -join "`n"
                        }
                    }
                    if ($scopeText) { $nextInput = (@($nextInput, $scopeText) | Where-Object { $_ }) -join "`n" }
                    if ($run.pendingItems.Count) {
                        $nextInput += "`n待确认清单（生成草稿时逐字保留编号和原问题，不自行消除）："
                        foreach ($item in $run.pendingItems) {
                            $nextInput += "`n[$($item.id)] $($item.question)"
                            if ($item.Contains('remainingQuestion')) {
                                $nextInput += "`n仅剩待决部分（草稿须原样记录）：$($item.remainingQuestion)"
                                $resolved = @($item.resolvedAnswerIds | ForEach-Object { $answers[$_] }) -join "`n"
                                if ($resolved) { $nextInput += "`n已回答部分（不要重新列为未知）：`n$resolved" }
                            }
                        }
                        $nextInput += "`n请保留待确认事项及影响，不自行设定默认值或沿用现有实现作为决定；可继续整理其他已明确输入及带未决项的草稿。已有记录不重复建项，涉及这些事项的实现与验收须待确认，不能宣称所有决策均已明确。"
                    }
                    if ($SimulatorStyle -eq 'guided' -and $decision.action -in @('answer', 'correct', 'defer')) {
                        $nextInput += "`n还有问题吗？"
                    }
                    $nextAnswerIds = @($decision.answerIds)
                    Write-Json (Join-Path $runPath 'result.json') $run
                    if (-not $pm.replayed -or -not $user.replayed) { $newRounds++ }
                    if ($PauseAfterRounds -gt 0 -and $newRounds -ge $PauseAfterRounds) {
                        $run.state = 'paused'; $run.stopReason = 'operator_checkpoint'; $exitCode = 3
                        break
                    }
                }
                if ($run.state -eq 'running') { $run.state = 'stopped' }
            }
            catch {
                $run.state = 'invalid'; $run.stopReason = 'execution_or_protocol_error'
                $run.errors += $_.Exception.Message
                $exitCode = 1
                Write-Warning "Run $index invalid: $($_.Exception.Message)"
            }
            finally {
                $run.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
                $run.elapsedSeconds = ([DateTimeOffset]::Parse($run.finishedAt) - [DateTimeOffset]::Parse($run.startedAt)).TotalSeconds
                Write-Json (Join-Path $runPath 'result.json') $run
                Write-Json (Join-Path $output 'experiment.json') $manifest
            }
            if ($run.state -in @('needs_human', 'paused')) { break }
        }
        if ($exitCode -in @(2, 3)) { break }
    }
    $manifest.state = if ($exitCode -eq 0) { 'stopped' } elseif ($exitCode -eq 2) { 'needs_human' } elseif ($exitCode -eq 3) { 'paused' } else { 'invalid' }
}
catch {
    $manifest.state = 'invalid'
    $manifest.errors += $_.Exception.Message
    $exitCode = 1
    Write-Warning $_.Exception.Message
}
finally {
    $manifest.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-Json (Join-Path $output 'experiment.json') $manifest
    $summary = @($manifest.runs | ForEach-Object {
        @{
            model = $_.model; repetition = $_.repetition; rounds = $_.rounds
            protocolVersion = $manifest.protocolVersion
            simulatorStyle = $SimulatorStyle; simulatorAgent = $simulatorAgent
            localOnly = [bool]$LocalOnly
            completionPolicyVersion = $completionPolicy.version
            profiles = $_.profiles; assessments = $_.assessments; completionAssessment = $_.completionAssessment
            oracleVersion = $manifest.oracleVersion; simulatorModel = $SimulatorModel
            errorPolicyVersion = $manifest.errorPolicyVersion; warningCount = @($_.warnings).Count
            state = $_.state; stopReason = $_.stopReason; evaluation = $_.evaluation
            pendingCount = @($_.pendingItems).Count; requirementsStatus = $_.requirementsStatus
            completionOutcome = $_.completionOutcome
            elapsedSeconds = $_.elapsedSeconds; result = (Join-Path $_.path 'result.json')
        }
    })
    Write-Json (Join-Path $output 'comparison.json') $summary
    try { & $reporter -RunDirectory $output }
    catch { Write-Warning "Report export failed; original evidence is preserved: $($_.Exception.Message)" }
    $lock.Dispose()
}
Write-Host "Experiment $($manifest.state). Evidence: $output. Business results remain not_scored."
exit $exitCode
