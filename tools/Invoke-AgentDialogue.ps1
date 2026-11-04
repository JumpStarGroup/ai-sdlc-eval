#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$CliPath = 'copilot'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DialoguePolicy.psm1') -Force
$configPath = (Resolve-Path -LiteralPath $ConfigFile).Path
$configRoot = Split-Path $configPath
$config = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
function Resolve-ConfigPath([string]$Value) { [IO.Path]::GetFullPath($Value, $configRoot) }
function Save-Dialogue {
    $temporary = Join-Path $root 'result.tmp'
    ConvertTo-Json -InputObject $state -Depth 40 | Set-Content $temporary -Encoding utf8
    [IO.File]::Move($temporary, (Join-Path $root 'result.json'), $true)
}
function Assert-ProtectedWorkspaceInputs {
    foreach ($file in $protectedWorkspaceHashes.Keys) {
        $relative = [IO.Path]::GetRelativePath($repository, $file)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Protected workspace input missing: $relative" }
        $ancestor = $file
        while ($ancestor -ne $repository) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Protected workspace input linked: $relative" }
            $ancestor = Split-Path $ancestor -Parent
        }
        if ((Get-FileHash -LiteralPath $file).Hash -cne $protectedWorkspaceHashes[$file]) { throw "Protected workspace input changed: $relative" }
    }
}
foreach ($key in @('repositoryPath', 'runDirectory', 'targetAgent', 'targetModel', 'participantModel', 'knowledgeFile', 'initialRequest')) {
    if ($config[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($config[$key])) { throw "Missing configuration: $key" }
}
if ($config.targetAgent -cnotmatch '^[\w-]+$' -or $config.participantModel -imatch '^(auto(?::.*)?|fusion(?::.*)?|hydrafusion(?:-max)?)$') { throw 'Use an explicit Agent and participant model; only targetModel may use Auto/Fusion.' }
$policy = Get-Content (Join-Path $PSScriptRoot '..\profiles\dialogue-policy.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($config.ContainsKey('policy')) {
    foreach ($key in $config.policy.Keys) {
        if (-not $policy.ContainsKey($key)) { throw "Unknown policy: $key" }
        $policy[$key] = $config.policy[$key]
    }
}
foreach ($key in @('allowPendingDraft', 'requireArtifact', 'disableBuiltinMcps', 'skipIssueRegistration')) {
    if ($policy[$key] -isnot [bool]) { throw "Expected boolean policy: $key" }
}
foreach ($key in @('callLimit', 'timeoutSeconds', 'maxCoordinatorPrompts', 'maxIdenticalReplies', 'minimumParticipantReplies', 'maxPathRecoveryPrompts')) {
    if (($policy[$key] -isnot [int] -and $policy[$key] -isnot [long]) -or
        $policy[$key] -gt [int]::MaxValue -or
        $policy[$key] -lt $(if ($key -in @('maxCoordinatorPrompts', 'minimumParticipantReplies', 'maxPathRecoveryPrompts')) { 0 } else { 1 })) { throw "Invalid budget: $key" }
}
if ($policy.timeoutSeconds -gt 86400) { throw 'timeoutSeconds exceeds the collector limit.' }
foreach ($key in @('coordinatorPrompt', 'artifactDescription', 'interactionPrompt')) {
    if ($policy[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($policy[$key])) { throw "Expected text policy: $key" }
}
$repository = (Resolve-Path -LiteralPath (Resolve-ConfigPath $config.repositoryPath)).Path
$knowledgePath = (Resolve-Path -LiteralPath (Resolve-ConfigPath $config.knowledgeFile)).Path
$participantSource = if ($config.ContainsKey('participantAgentFile')) {
    (Resolve-Path -LiteralPath (Resolve-ConfigPath $config.participantAgentFile)).Path
} else { Join-Path $PSScriptRoot '../agents/simple-business-user.agent.md' }
$participantDefinition = Get-Content $participantSource -Raw -Encoding utf8
$nameMatch = [regex]::Match($participantDefinition, '(?m)^name:\s*([\w-]+)\s*$')
if (-not $nameMatch.Success) { throw 'Participant definition needs a valid name.' }
$participantAgent = $nameMatch.Groups[1].Value
$participantContextLabel = if ($config.ContainsKey('participantContextLabel')) { $config.participantContextLabel } else { '以下是私有业务知识，只用于回答，不转发全文：' }
if ($participantContextLabel -isnot [string] -or [string]::IsNullOrWhiteSpace($participantContextLabel)) { throw 'Expected nonempty participantContextLabel.' }
$targetSource = [IO.Path]::GetFullPath((Join-Path $repository ".github/agents/$($config.targetAgent).agent.md"))
if (-not (Test-Path -LiteralPath $targetSource -PathType Leaf)) { throw 'Install the configured target Agent in the product repository first.' }
$root = Resolve-ConfigPath $config.runDirectory
$framework = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($protected in @($repository, $framework)) {
    $prefix = $protected.TrimEnd('\', '/')
    if ($root.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Private evidence must be outside product and framework.' }
}
$ancestor = $root
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        if ((Get-Item $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Test-Path (Join-Path $ancestor '.git'))) { throw 'Private evidence cannot be linked or inside a Git repository.' }
    }
    $ancestor = Split-Path $ancestor -Parent
}
if (Test-Path -LiteralPath $root) { throw 'Use a fresh run directory; no automatic resend or resume.' }
$rawTools = if ($config.ContainsKey('availableTools')) { @($config.availableTools) } else { @('view', 'glob', 'grep', 'apply_patch', 'create', 'edit') }
$platformShellTools = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    @('powershell', 'read_powershell', 'stop_powershell', 'list_powershell')
} else {
    @('bash', 'read_bash', 'stop_bash', 'list_bash')
}
$tools = @(
    foreach ($toolItem in $rawTools) {
        if ($toolItem -ceq 'shell') { $platformShellTools } else { $toolItem }
    }
) | Select-Object -Unique
$allow = if ($config.ContainsKey('allowTools')) { @($config.allowTools) } else { @('write') }
$deny = if ($config.ContainsKey('denyTools')) { @($config.denyTools) } else { @('shell') }
$allowedLocalToolNames = @('view', 'glob', 'grep', 'apply_patch', 'create', 'edit')
if ('shell' -cin $allow) {
    $allowedLocalToolNames += @('shell', 'local_shell', 'powershell', 'read_powershell', 'write_powershell', 'stop_powershell', 'list_powershell', 'bash', 'read_bash', 'write_bash', 'stop_bash', 'list_bash')
}
if ($policy.disableBuiltinMcps -and @($tools | Where-Object { $_ -cnotin $allowedLocalToolNames }).Count) { throw 'MCP-disabled tests require the local file/shell tool allowlist.' }
$baseline = @{}
Get-DialogueWorkspaceFiles -Repository $repository -ExcludeDependencies:($config['participantInput'] -ceq 'none') | ForEach-Object {
    $baseline[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash
}
$protectedWorkspaceHashes = @{ $targetSource = $baseline[$targetSource] }
foreach ($relative in @($config['protectedWorkspacePaths'] | Where-Object { $_ })) {
    $full = [IO.Path]::GetFullPath($relative, $repository)
    if (-not $full.StartsWith($repository.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not $baseline.ContainsKey($full)) { throw "Protected workspace input must be an existing baseline file: $relative" }
    $protectedWorkspaceHashes[$full] = $baseline[$full]
}
Assert-ProtectedWorkspaceInputs
[void](New-Item -ItemType Directory -Path $root)
Copy-Item $knowledgePath (Join-Path $root 'knowledge.md')
Copy-Item $targetSource (Join-Path $root 'target.agent.md')
Copy-Item $participantSource (Join-Path $root 'participant.agent.md')
Copy-Item $configPath (Join-Path $root 'config.json')
Copy-Item (Join-Path $PSScriptRoot 'Invoke-SdlcCapture.ps1') $root
Copy-Item (Join-Path $PSScriptRoot 'CapturedProcess.psm1') $root
Copy-Item (Join-Path $PSScriptRoot 'DialoguePolicy.psm1') $root
Copy-Item (Join-Path $PSScriptRoot 'Export-AgentDialogueReport.ps1') $root
$contract = @{}
foreach ($file in @('knowledge.md', 'target.agent.md', 'participant.agent.md', 'config.json', 'Invoke-SdlcCapture.ps1', 'CapturedProcess.psm1', 'DialoguePolicy.psm1', 'Export-AgentDialogueReport.ps1')) {
    $contract[$file] = (Get-FileHash (Join-Path $root $file)).Hash
}
$workspace = Join-Path $root 'participant-workspace'
$agents = Join-Path $workspace '.github/agents'
[void](New-Item -ItemType Directory -Path $agents -Force)
Copy-Item (Join-Path $root 'participant.agent.md') (Join-Path $agents "$participantAgent.agent.md")
& git -C $workspace init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize participant workspace.' }
& git -C $workspace add --all
if ($LASTEXITCODE -ne 0) { throw 'Cannot stage participant definition.' }
& git -C $workspace -c core.hooksPath=.git/disabled-hooks -c user.name='Evaluation Fixture' -c user.email='fixture@example.invalid' -c commit.gpgsign=false commit --quiet -m 'Freeze dialogue participant'
if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze participant baseline.' }
$state = New-DialogueState
$state['policy'] = $policy
$state['contract'] = $contract
$state['assessment'] = 'not_scored'
$state['startedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
$state['repositoryPath'] = $repository
$state['note'] = 'Completion checks delivery evidence, not semantic quality or business approval.'
$task = @"
本次自动协作约定（不来自业务知识，不构成业务规则）：
本次是控制器驱动的双 Agent 多轮对话；一次 CLI 调用返回，只结束当前发言，不代表整场任务结束。双方各自的会话由控制器保存和恢复，不需要在当前调用内等待对方，也不需要自行调用另一 Agent 或寻找人工交互工具。
交接流程：被测角色在正文提出实际需要澄清的具体业务问题，以 waiting_reply 返回；控制器将正文发送给业务参与者。业务参与者只按已有知识回答本轮实际问题，以 waiting_reply 返回，即使没有反问；控制器再将答复送回被测角色并恢复其会话。被测角色吸收答案后继续调查、追问其他必要问题或交付，不以重复摘要代替推进。
尚未收到业务回复、当前 CLI 非交互、没有 Agent 调用工具，本身都不构成 blocked；需要答复时应先提出问题并交回控制权。仅在确实无法执行下一步时报告 blocked，正文说明具体障碍、已观察到的证据及缺少的条件，不把未尝试的交流判断为不可用。真实权限、认证或工具故障不能被当作已恢复，也不得扩大权限绕过。
你完成自身角色任务后，正文必须明确说“角色任务已经完成”。被测角色负责发现问题、调查基线、交付；业务参与者只回答实际问题，不提示隐藏遗漏或评价覆盖率。收到不等于批准。
任务配置：$(ConvertTo-Json $policy -Compress)
allowPendingDraft=true 时，启动约定已授予按讨论证据整理草稿的权限，不必再次向业务参与者索取起草许可；未决仍未决。false 时不得带待决交付。
skipIssueRegistration=true 时，Issue 登记不是继续讨论或交付的前置条件；false 时遵守角色原流程。disableBuiltinMcps=true 时不使用 MCP，远程工作只记录跟进。
产物要求：$($policy.artifactDescription)
minimumParticipantReplies 是整场对话累计的业务参与者回复次数要求，不是当前调用必须完成的轮数，也不是一条回复中的答案条数。被测角色声明交付完成前须达到配置次数，并处理已提出问题的答复；业务参与者明确说明无已批准答案也属于答复，不等于该决定已解决。围绕实际需求持续发现并澄清必要问题，不为凑次数虚构问题、拆分同一问题或重复索取同一未知决定。不能直接把未曾询问的问题停放到草稿，现行代码也不是业务批准。这个数量只检查实际交互，不证明需求覆盖。
知识缺失分为业务待决、基线调查、技术跟进或尚未分类。业务参与者遇到没有已批准答案或知识冲突的问题，应如实说明，保留未决或冲突，以 waiting_reply 交回被测角色，不补造答案、提示隐藏遗漏或把单项未知当作整场无法交流。被测角色保留这些边界，继续其他独立工作；知识冲突不自行选边。
正文继续使用自然语言；只有最后一行使用控制元数据，覆盖角色中仅针对输出格式的限制，不改变知识权限：
DIALOGUE_CONTROL: {"status":"waiting_reply","artifactPaths":[],"pending":[]}
status 只能是 waiting_reply（将控制权交给对方继续处理）、role_task_completed（本次约定的角色任务已经完成）、blocked（无法继续，正文解释具体原因）。每轮只有一个状态。提问和本轮业务答复通常都使用 waiting_reply，即使正文没有反问；回答完一个问题不等于整个角色任务完成。业务参与者的非空正文先送达被测角色，再由被测角色吸收答案、继续澄清或交付；不要为维持对话而回复收到或重复摘要。参与者完成或阻塞不等于被测任务完成，最终结束由控制器核验。
artifactPaths 是实际生成的工作区相对文件路径。pending 数组用于逐问题状态更新，每项必需 id、question、kind；可附 questionStatus、answeredParts 和 remainingQuestion。questionStatus 只能是 awaiting_reply（提问待答复）、answered（已回答）、partially_answered（部分回答）、pending（确无批准答案）。kind 是 business_decision、baseline_investigation、technical_followup 或 unclassified。首次提问不是未知业务决定，使用 awaiting_reply；参与者应对最新批次逐项标记回答状态。answered 必须附非空 answeredParts 且 remainingQuestion 为 null 或省略；partially_answered 必须附已答部分和非空 remainingQuestion。业务答复若仅列未决项，程序只将最新提问批次中此前 awaiting_reply 且未列出的项目记为已回答推断，语义仍需评审；已经登记的真正待决不能靠省略消除。PM 不得自行把真正待决标为 answered。
同编号允许 question 改写、收窄或补充，程序保留 originalQuestion 和 history；不改变 kind 来消除业务待决。只登记实际提出的问题，不虚构决定、负责人或期限。草稿区分已回答和仍待决内容，引用真正待决编号并明确未批准部分；允许概括及等价表达，不要求自然语言逐字一致。历史原文在会话台账中保留，不要求每个已回答问题都成为草稿阻塞项。
控制器可以有限追问“还有问题吗？”，不替业务作决定。角色完成声明由控制器核验，不表示验收、实现或发布获批。
"@
$role = 'target'
$nextInput = $config.initialRequest
$inputSender = 'task_initiator'
$sourceCall = $null
$senderStatus = $null
$roleCalls = @{ target = 0; participant = 0 }
$fingerprints = @{ target = ''; participant = '' }
$repeats = @{ target = 0; participant = 0 }
$savedPath = $env:PATH
try {
    $env:PATH = $PSHOME + [IO.Path]::PathSeparator + $env:PATH
    Save-Dialogue
    while ($state.outcome -eq 'running' -and $state.calls -lt $policy.callLimit) {
        foreach ($file in $contract.Keys) {
            if ((Get-FileHash (Join-Path $root $file)).Hash -cne $contract[$file]) { throw 'Frozen run input changed.' }
        }
        Assert-ProtectedWorkspaceInputs
        $state.calls++
        $turnDirectory = Join-Path $root ('message-{0:d2}' -f $state.calls)
        [void](New-Item -ItemType Directory -Path $turnDirectory)
        $questionView = @($state.questions | ForEach-Object {
            @{ id = $_.id; kind = $_.kind; questionStatus = $_.questionStatus; originalQuestion = $_.originalQuestion
                question = $_.question; remainingQuestion = $_.remainingQuestion; answeredParts = $_.answeredParts }
        })
        $roleWorkspace = if ($role -eq 'target') { $repository } else { $workspace }
        $pathNotice = "本次角色唯一工作区根目录：$roleWorkspace。文件路径均相对此目录；优先使用相对路径，不要自行拼接长绝对路径，不要访问父目录或同级证据目录。读取失败先在当前工作区内定位文件，不能删除路径中的目录层级来重试。"
        if ($role -eq 'target') {
            $pathNotice += " 配置允许的本地工具：$($tools -join ', ')。实际可用工具以当前 CLI 提供的 schema 为准：有 apply_patch 时使用它新建或修改；有 create/edit 时分别用于新建或修改。写入前读取当前文件，补丁上下文不匹配时重新读取并修正，不将失败补丁当成已写入。只有成功写入并读回核对后才能声明产物已生成。"
        }
        $prompt = "$task`n`n$pathNotice`n`n问题台账：$(ConvertTo-Json -InputObject $questionView -Depth 8 -Compress)`n`n当前真正待决：$(ConvertTo-Json -InputObject @($state.pending) -Depth 12 -Compress)`n`n对方最新消息：`n$nextInput"
        if ($senderStatus) {
            $prompt += "`n`n对方消息状态：$senderStatus。请先吸收正文，继续自己的澄清或交付任务，不必回复收到；对方角色完成或阻塞不自动终止你的任务。"
        }
        if ($role -eq 'participant' -and $roleCalls.participant -eq 0) {
            $prompt += "`n`n$participantContextLabel`n$(Get-Content (Join-Path $root 'knowledge.md') -Raw -Encoding utf8)"
        }
        $promptPath = Join-Path $turnDirectory 'input.txt'
        $prompt | Set-Content $promptPath -Encoding utf8 -NoNewline
        $capture = Join-Path $root "$role-capture"
        $parameters = @{
            PromptFile = $promptPath; RunDirectory = $capture
            RepositoryPath = $(if ($role -eq 'target') { $repository } else { $workspace })
            Agent = $(if ($role -eq 'target') { $config.targetAgent } else { $participantAgent })
            Model = $(if ($role -eq 'target') { $config.targetModel } else { $config.participantModel })
            CopilotHome = (Join-Path $root "$role-home"); CliPath = $CliPath
            TimeoutSeconds = $policy.timeoutSeconds; Resume = ($roleCalls[$role] -gt 0)
        }
        if ($role -eq 'participant') {
            $parameters.NoTools = $true; $parameters.DisableBuiltinMcps = $true; $parameters.NoCustomInstructions = $true
        } else {
            $parameters.AvailableTool = $tools; $parameters.AllowTool = $allow; $parameters.DenyTool = $deny
            $parameters.DisableBuiltinMcps = $policy.disableBuiltinMcps
            $parameters.RecoverLocalPatchErrors = $true
        }
        $state.turns += @{ call = $state.calls; role = $role; input = $nextInput; inputSender = $inputSender; startedAt = [DateTimeOffset]::UtcNow.ToString('o'); state = 'dispatching'; evidence = $turnDirectory }
        Save-Dialogue
        & (Join-Path $root 'Invoke-SdlcCapture.ps1') @parameters | Out-Host
        $state.turns[-1]['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
        $turnStartedAt = [DateTimeOffset]::Parse($state.turns[-1].startedAt, [Globalization.CultureInfo]::InvariantCulture)
        $turnFinishedAt = [DateTimeOffset]::Parse($state.turns[-1].finishedAt, [Globalization.CultureInfo]::InvariantCulture)
        $state.turns[-1]['durationMs'] = [long][Math]::Round(($turnFinishedAt - $turnStartedAt).TotalMilliseconds)
        Assert-ProtectedWorkspaceInputs
        if ($LASTEXITCODE -ne 0) { throw 'Capture failed; no automatic retry.' }
        $roleCalls[$role]++
        $capturedTurn = Get-ChildItem $capture -Directory -Filter 'turn-*' | Sort-Object Name | Select-Object -Last 1
        $state.turns[-1]['capturePath'] = $capturedTurn.FullName
        if ($null -ne $sourceCall) {
            $actualInput = Get-Content (Join-Path $capturedTurn.FullName 'input.txt') -Raw -Encoding utf8
            if ($actualInput -cne (Get-Content $promptPath -Raw -Encoding utf8)) { throw 'Captured counterpart input differs from the dispatched message.' }
            $state.turns[$sourceCall - 1]['delivery'] = @{
                status = 'captured_input'; recipient = $role; targetCall = $state.calls
                time = $state.turns[-1].startedAt; inputFile = (Join-Path $capturedTurn.FullName 'input.txt')
            }
        }
        $runtime = Get-Content (Join-Path $capturedTurn.FullName 'runtime.json') -Raw | ConvertFrom-Json -AsHashtable
        $meta = Get-Content (Join-Path $capturedTurn.FullName 'turn.json') -Raw | ConvertFrom-Json -AsHashtable
        $state.turns[-1]['requestedModel'] = $parameters.Model
        $state.turns[-1]['observedModels'] = @($runtime.observedModels)
        if ($runtime.ContainsKey('fusionPhases') -and @($runtime.fusionPhases).Count) {
            $state.turns[-1]['fusionPhases'] = $runtime.fusionPhases
        }
        $state.turns[-1]['usage'] = $runtime.usage
        $state.turns[-1]['warnings'] = $runtime.warnings
        $state.turns[-1]['runtimeProblems'] = $runtime.problems
        $state.turns[-1]['toolSnapshots'] = $runtime['toolSnapshots']
        $state.turns[-1]['disabledTools'] = $runtime['disabledTools']
        if ($meta.state -ne 'cli_exited') { throw "CLI execution state invalid: $($meta.state)." }
        $selectorPattern = '^(auto(?::[a-z0-9_-]+)?|fusion(?::standard|:high|:max)?|hydrafusion(?:-max)?)$'
        $autoTarget = $role -eq 'target' -and ($parameters.Model -imatch $selectorPattern)
        if (-not $runtime.observedModels.Count -or @($runtime.observedModels | Where-Object { $_ -imatch $selectorPattern }).Count -gt 0 -or
            (-not $autoTarget -and ($runtime.observedModels.Count -ne 1 -or $runtime.observedModels[0] -cne $parameters.Model))) {
            throw "Actual model mismatch: requested=$($parameters.Model); observed=$($runtime.observedModels -join ',')."
        }
        $messages = @(Get-Content (Join-Path $capturedTurn.FullName 'assistant-messages.json') -Raw | ConvertFrom-Json -AsHashtable)
        if ($messages.Count) { $state.turns[-1]['rawResponse'] = $messages[-1].content }
        $message = $null
        $onlyRecoverableReadErrors = $runtime.problems.Count -gt 0 -and
            @($runtime.problems | Where-Object { $_['category'] -cne 'recoverable_local_read_error' }).Count -eq 0
        if ($runtime.problems.Count -and -not $onlyRecoverableReadErrors) {
            $corrections = if ($role -eq 'target') { @(Get-DialoguePathRecovery $runtime.problems $repository) } else { @() }
            if (@($corrections).Count -gt 0 -and $state.pathRecoveries -lt $policy.maxPathRecoveryPrompts -and $state.calls -lt $policy.callLimit) {
                $state.pathRecoveries++
                $nextInput = "上次读取被拒绝：路径漏了工作区根目录的一层。唯一根目录为 $repository。只在此根目录内使用下列相对路径重新读取：$(ConvertTo-Json -InputObject @($corrections) -Compress)。不要访问原来的外部路径。权限没有扩大；请在原任务上下文中继续，核实后再提出问题或交付。"
                $state.turns[-1]['controller'] = @{ action = 'prompt'; role = 'target'; reason = 'workspace_path_correction'; corrections = @($corrections); text = $nextInput }
                $state.turns[-1]['delivery'] = @{ status = 'not_forwarded'; action = 'prompt' }
                $state.turns[-1].state = 'runtime_recovery_requested'
                $inputSender = 'controller'; $sourceCall = $null; $senderStatus = $null
                Save-Dialogue
                continue
            }
            if ($messages.Count -and -not $messages[-1].hasToolRequests) {
                try { $message = Read-DialogueMessage $messages[-1].content } catch { $message = $null }
            }
            if ($null -eq $message) {
                $details = @($runtime.problems | ForEach-Object {
                    @{ eventId = $_.eventId; tool = $_['toolName']; error = $_.data['error']; arguments = $_['arguments'] }
                }) | ConvertTo-Json -Depth 10 -Compress
                throw "Runtime tool failure (not a model mismatch): $details"
            }
            $state.turns[-1]['runtimeProblemDisposition'] = 'continued_with_valid_reply'
        }
        if ($messages.Count -and -not $messages[-1].hasToolRequests -and $null -eq $message) {
            try { $message = Read-DialogueMessage $messages[-1].content } catch { $message = $null }
        }
        if ($null -eq $message) {
            if ($role -eq 'target' -and $state.recoveries -lt $policy.maxCoordinatorPrompts -and $state.calls -lt $policy.callLimit) {
                $state.recoveries++
                $nextInput = "上一轮调用未输出完整的最终回复或缺少末尾的 DIALOGUE_CONTROL 行。请直接输出你的完整正文（提问或交付说明），并在最后一行严格附上 DIALOGUE_CONTROL: {`"status`":`"waiting_reply|role_task_completed|blocked`",`"artifactPaths`":[...],`"pending`":[...]}。"
                $state.turns[-1]['controller'] = @{ action = 'prompt'; role = 'target'; reason = 'missing_or_malformed_final_reply_recovery'; text = $nextInput }
                $state.turns[-1]['delivery'] = @{ status = 'not_forwarded'; action = 'prompt' }
                $state.turns[-1].state = 'runtime_recovery_requested'
                $inputSender = 'controller'; $sourceCall = $null; $senderStatus = $null
                Save-Dialogue
                continue
            }
            if (-not $messages.Count -or $messages[-1].hasToolRequests) { throw 'Missing final Agent reply.' }
            $message = Read-DialogueMessage $messages[-1].content
        }
        $state.turns[-1]['rawResponse'] = $messages[-1].content
        if ($role -eq 'target' -and $config['participantInput'] -ceq 'none' -and $message.control.status -eq 'role_task_completed' -and -not $message.control.artifactPaths.Count) {
            $protectedRelatives = @($config['protectedWorkspacePaths'] | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') })
            $detectedChanged = [System.Collections.Generic.List[string]]::new()
            Get-DialogueWorkspaceFiles -Repository $repository -ExcludeDependencies | ForEach-Object {
                $full = $_.FullName
                $rel = [IO.Path]::GetRelativePath($repository, $full).Replace('\', '/')
                if ($rel -notin $protectedRelatives -and (-not $baseline.ContainsKey($full) -or $baseline[$full] -cne (Get-FileHash -LiteralPath $full).Hash)) {
                    $detectedChanged.Add($rel)
                }
            }
            if ($detectedChanged.Count) {
                $message.control.artifactPaths = @($detectedChanged | Sort-Object -Unique)
            }
        }
        $state.turns[-1]['response'] = $message
        $state.turns[-1].state = 'received'
        $step = Get-DialogueStep $state $message $role $policy $repository $baseline
        if ($config['participantInput'] -ceq 'none' -and $step.action -eq 'send' -and $step['role'] -eq 'participant') {
            if ($state.calls -ge $policy.callLimit) {
                $state.outcome = 'budget_exceeded'
                $step = @{ action = 'stop'; reason = 'call_limit_reached_in_single_agent_stage' }
            } elseif ($state.recoveries -ge $policy.maxCoordinatorPrompts) {
                $state.outcome = 'stalled'
                $step = @{ action = 'stop'; reason = 'unexpected_waiting_reply_in_single_agent_stage' }
            } else {
                $state.recoveries++
                $step = @{ action = 'prompt'; role = 'target'; reason = 'single_agent_stage_no_participant'; text = $policy.interactionPrompt }
            }
        }
        $fingerprint = ConvertTo-Json -InputObject $message -Depth 10 -Compress
        if ($fingerprints[$role] -ceq $fingerprint) { $repeats[$role]++ } else { $repeats[$role] = 0 }
        $fingerprints[$role] = $fingerprint
        if ($step.action -ne 'stop' -and $repeats[$role] -ge $policy.maxIdenticalReplies - 1) {
            $state.outcome = 'stalled'
            $step = @{ action = 'stop'; reason = 'repeated_identical_reply' }
        }
        $state.turns[-1]['controller'] = $step
        $state.turns[-1]['delivery'] = @{
            status = $(if ($step.action -eq 'send') { 'pending_dispatch' } else { 'not_forwarded' })
            action = $step.action
        }
        Save-Dialogue
        if ($step.action -eq 'stop') { break }
        $inputSender = if ($step.action -eq 'prompt') { 'controller' } else { $role }
        $sourceCall = if ($step.action -eq 'send') { $state.calls } else { $null }
        $senderStatus = if ($step.action -eq 'send') { $step.senderStatus } else { $null }
        $role = $step.role
        $nextInput = $step.text
    }
    if ($state.outcome -eq 'running') { $state.outcome = 'budget_exceeded' }
    Save-Dialogue
    Write-Output "Dialogue ended: $($state.outcome); calls=$($state.calls); evidence=$root"
} catch {
    $state.outcome = 'failed'
    $state['error'] = $_.Exception.Message
    Save-Dialogue
    throw
} finally {
    $state['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    $state['completionFacts'] = Get-DialogueCompletionFacts $state
    $runStartedAt = [DateTimeOffset]::Parse($state.startedAt, [Globalization.CultureInfo]::InvariantCulture)
    $runFinishedAt = [DateTimeOffset]::Parse($state.finishedAt, [Globalization.CultureInfo]::InvariantCulture)
    $state['durationMs'] = [long][Math]::Round(($runFinishedAt - $runStartedAt).TotalMilliseconds)
    $state['roleDurationMs'] = @{}
    foreach ($durationRole in @('target', 'participant')) {
        $roleDurations = @($state.turns | Where-Object { $_.role -eq $durationRole } | ForEach-Object { [long]$_.durationMs })
        $state.roleDurationMs[$durationRole] = [long](($roleDurations | Measure-Object -Sum).Sum)
    }
    Save-Dialogue
    try { & (Join-Path $root 'Export-AgentDialogueReport.ps1') -RunDirectory $root | Out-Host }
    catch { Write-Warning "Conversation summary failed: $($_.Exception.Message)" }
    $env:PATH = $savedPath
}