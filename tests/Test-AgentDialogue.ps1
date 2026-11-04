#requires -Version 7.0
param([string]$RecordedRunDirectory, [switch]$RuntimeErrorsOnly, [switch]$NamingOnly)
$ErrorActionPreference = 'Stop'
trap { Write-Output $_.ScriptStackTrace; throw }
Import-Module (Join-Path $PSScriptRoot '../tools/DialoguePolicy.psm1') -Force
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert (Test-Json -LiteralPath (Join-Path $PSScriptRoot '../profiles/dialogue-policy.json')) 'Infrastructure policy is valid JSON.'
$templatePolicy = Get-Content (Join-Path $PSScriptRoot '../profiles/dialogue-policy.json') -Raw | ConvertFrom-Json -AsHashtable
Assert ($templatePolicy.minimumParticipantReplies -eq 2 -and $templatePolicy.maxPathRecoveryPrompts -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($templatePolicy.interactionPrompt)) 'Interaction and recovery defaults are explicit in the template.'
function Reject([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Expected rejection.'
}
Import-Module (Join-Path $PSScriptRoot '../tools/RunDirectory.psm1') -Force
$namingFixture = Join-Path ([IO.Path]::GetTempPath()) ('dialogue-naming-' + [guid]::NewGuid().ToString('N'))
try {
    $date = [datetime]'2026-10-15'
    $first = Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId sample02 -RunLabel all-six-sol61 -RunDate $date
    Assert ([IO.Path]::GetFileName($first) -eq 'sample02-dialogue-001-20261015-all-six-sol61' -and
        -not (Test-Path $namingFixture)) 'Naming is sequence-first and does not create or reserve directories.'
    foreach ($name in @('sample02-dialogue-20261014-auto-luna-mai-gemini-sol61-017',
        'sample02-dialogue-20261014-all-six-sol61-018', 'sample02-dialogue-20261014-all-six-sol61-999-inputs',
        'sample01-dialogue-20261014-luna-astra-001', 'sample01-dialogue-20261014-luna-astra-002',
        'sample01-dialogue-20261014-model-sweep-001', 'sample01-dialogue-20261014-model-sweep-002')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $namingFixture $name) -Force)
    }
    $next = Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId sample02 -RunLabel all-six-sol61 -RunDate $date
    Assert ([IO.Path]::GetFileName($next) -eq 'sample02-dialogue-019-20261015-all-six-sol61') 'Legacy batches continue their shared sequence; input snapshots do not count.'
    [void](New-Item -ItemType Directory -Path $next)
    $after = Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId sample02 -RunLabel luna-sol61 -RunDate $date.AddDays(1)
    Assert ([IO.Path]::GetFileName($after) -eq 'sample02-dialogue-020-20261016-luna-sol61') 'New format, another date and another model group share one sequence.'
    $sample01 = Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId sample01 -RunLabel luna-astra -RunDate $date
    Assert ([IO.Path]::GetFileName($sample01) -eq 'sample01-dialogue-005-20261015-luna-astra') 'Four legacy batches with duplicate local suffixes produce shared batch 005.'
    Assert (@(@([IO.Path]::GetFileName($after), [IO.Path]::GetFileName($next)) | Sort-Object)[0] -eq
        [IO.Path]::GetFileName($next)) 'Batch sequence sorts before date and model labels.'
    Reject { Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId '../sample01' -RunLabel comparison }
    Reject { Get-DialogueRunDirectory -RunsRoot $namingFixture -CaseId sample01 -RunLabel '../comparison' }
    $taskConfig = Get-Content (Join-Path $PSScriptRoot '../.vscode/tasks.json') -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($label in @('SDLC validate', 'SDLC run (uses model credits)', 'SDLC Test validate', 'SDLC Test run (uses model credits)')) {
        $task = @($taskConfig.tasks | Where-Object { $_.label -eq $label })
        Assert ($task.Count -eq 1) "One reusable launch task exists: $label"
        $task = $task[0]
        Assert ($task.type -eq 'process' -and $task.command -eq 'pwsh' -and
            $task.args -contains '${workspaceFolder}\tools\Invoke-SDLC-Eval.ps1' -and
            $task.args -contains '${input:scenarioFile}' -and
            $task.args -notcontains '-RunDirectory') "Task uses the unified entry, selected scenario and fresh automatic run directory: $label"
        $expectedMode = if ($label.EndsWith('validate')) { 'ValidateOnly' } else { 'Run' }
        Assert ($task.args[([array]::IndexOf($task.args, '-Mode') + 1)] -eq $expectedMode) "Explicit launch mode: $label"
        if ($label.StartsWith('SDLC Test')) {
            Assert ($task.args -contains '${input:devRunDirectory}' -and $task.args -contains '${input:testModels}') 'Test tasks select a source Dev delivery and independent Test models.'
        }
    }
    Assert (@($taskConfig.inputs | Where-Object id -eq 'scenarioFile').Count -eq 1) 'Scenario input accepts any configured case.'
    Write-Output 'PASS: shared sequence-first UTC batch naming, legacy compatibility and input-directory exclusion'
} finally {
    if (Test-Path $namingFixture) { Remove-Item $namingFixture -Recurse -Force }
}
if ($NamingOnly) { return }
function Message([string]$Status, $Pending = @(), $Paths = @()) {
    Read-DialogueMessage ('Reply.' + "`nDIALOGUE_CONTROL: " + (ConvertTo-Json -Compress -Depth 8 @{ status = $Status; pending = @($Pending); artifactPaths = @($Paths) }))
}
$policy = @{ callLimit = 10; allowPendingDraft = $true; requireArtifact = $true; maxCoordinatorPrompts = 1; coordinatorPrompt = 'Any further questions? Deliver or report the blocker.' }
$state = New-DialogueState
$step = Get-DialogueStep $state (Message 'waiting_reply') 'target' $policy $PSScriptRoot @{}
Assert ($step.role -eq 'participant') 'Target questions reach participant.'
$state.calls = 10
Assert ((Get-DialogueStep $state (Message 'waiting_reply') 'target' $policy $PSScriptRoot @{}).action -eq 'stop' -and $state.outcome -eq 'budget_exceeded') 'No eleventh call.'
$state = New-DialogueState
$step = Get-DialogueStep $state (Message 'role_task_completed') 'target' $policy $PSScriptRoot @{}
Assert ($step.action -eq 'prompt' -and $step.text.Contains('完成声明尚未通过交付检查')) 'Invalid completion receives a specific delivery recovery, not a generic question.'
Assert ((Get-DialogueStep $state (Message 'role_task_completed') 'target' $policy $PSScriptRoot @{}).action -eq 'stop' -and $state.outcome -eq 'stalled') 'Completion recovery remains bounded.'
Reject { Read-DialogueMessage 'Reply.
DIALOGUE_CONTROL: {"status":"no_reply","pending":[],"artifactPaths":[]}' }
Reject { Read-DialogueMessage 'DIALOGUE_CONTROL: {"status":"waiting_reply","pending":[],"artifactPaths":[]}' }
$state = New-DialogueState
$answer = Message 'waiting_reply'
$step = Get-DialogueStep $state $answer 'participant' $policy $PSScriptRoot @{}
Assert ($step.action -eq 'send' -and $step.role -eq 'target' -and $step.text -ceq $answer.text -and
    $state.participantReplies -eq 1 -and $state.recoveries -eq 0) 'An answer without a question is handed off verbatim, without a replacement probe.'
$state = New-DialogueState
Assert ((Get-DialogueStep $state (Message 'blocked') 'participant' $policy $PSScriptRoot @{}).action -eq 'send' -and $state.outcome -eq 'running') 'Participant blockers reach target; they do not end the whole task.'
$state = New-DialogueState
Assert ((Get-DialogueStep $state (Message 'blocked') 'target' $policy $PSScriptRoot @{}).action -eq 'stop' -and $state.outcome -eq 'blocked_external') 'Target reports the actual whole-task blocker.'
$state = New-DialogueState
Assert ((Get-DialogueStep $state (Message 'role_task_completed') 'participant' $policy $PSScriptRoot @{}).action -eq 'send' -and $state.outcome -eq 'running') 'Participant completion delivers its final answer, not target completion.'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dialogue-policy-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $fixture)
    $product = Join-Path $fixture 'product'
    [void](New-Item -ItemType Directory -Path (Join-Path $product 'docs') -Force)
    'Template' | Set-Content (Join-Path $product 'docs/template.md')
    $problem = @{ eventId = 'denied-read'; root = $true; toolName = 'view'; arguments = @{ path = (Join-Path $fixture 'docs/template.md') }; data = @{ error = @{ code = 'denied' } } }
    $fixes = @(Get-DialoguePathRecovery @($problem) $product)
    Assert ($fixes.Count -eq 1 -and $fixes[0].workspacePath -eq (Join-Path $product 'docs/template.md')) 'Missing workspace segment yields only an existing workspace-local correction.'
    $problem.arguments.path = Join-Path $fixture 'knowledge.md'
    'Private' | Set-Content $problem.arguments.path
    Assert (@(Get-DialoguePathRecovery @($problem) $product).Count -eq 0) 'An existing private file outside the workspace is never authorized or redirected.'
    $problem.arguments.path = Join-Path $fixture 'docs/missing.md'
    Assert (@(Get-DialoguePathRecovery @($problem) $product).Count -eq 0) 'No guessed correction when the local counterpart does not exist.'
    $problem.arguments.path = Join-Path $fixture 'docs/template.md'
    $problem.toolName = 'edit'
    Assert (@(Get-DialoguePathRecovery @($problem) $product).Count -eq 0) 'Write permission failures are not path recovery candidates.'
    $pending = @{ id = 'pending-1'; question = 'Who approves the policy?'; kind = 'business_decision' }
    $state = New-DialogueState
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($pending)) 'participant' $policy $fixture @{})
    'Draft without pending evidence.' | Set-Content (Join-Path $fixture 'draft.md')
    $step = Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}
    Assert ($step.action -eq 'prompt' -and $step.artifactCheck.failures[0].reason -eq 'pending_reference_missing' -and
        $step.artifactCheck.failures[0].questionId -eq 'pending-1') 'Pending omission reports the precise failed question ID.'
    'Draft pending-1: Approval authority remains undecided; wording differs from the question.' | Set-Content (Join-Path $fixture 'draft.md')
    $state.calls = 10
    Assert ((Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}).action -eq 'stop' -and $state.outcome -eq 'completed_with_pending') 'Final budgeted call may deliver a pending draft.'
    $state = New-DialogueState
    $baseline = @{ (Join-Path $fixture 'draft.md') = (Get-FileHash (Join-Path $fixture 'draft.md')).Hash }
    Assert ((Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture $baseline).action -eq 'prompt') 'Preexisting unchanged files are not delivery.'
    $state = New-DialogueState
    $policy.allowPendingDraft = $false
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($pending)) 'participant' $policy $fixture @{})
    [void](Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{})
    Assert ($state.outcome -eq 'blocked_external') 'Pending draft authority is configurable.'
    $state = New-DialogueState
    $policy['minimumParticipantReplies'] = 1
    $policy['interactionPrompt'] = 'Ask a concrete business question first.'
    Assert ((Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}).action -eq 'prompt') 'A dialogue test cannot complete before any participant reply.'
    [void](Get-DialogueStep $state (Message 'waiting_reply') 'participant' $policy $fixture @{})
    Assert ($state.participantReplies -eq 1) 'Actual participant reply satisfies the interaction count.'
    $policy.allowPendingDraft = $true
    Assert ((Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}).action -eq 'stop') 'After interaction, normal artifact gates still apply.'
    $state = New-DialogueState
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($pending)) 'participant' $policy $fixture @{})
    $narrowed = @{ id = 'pending-1'; question = 'Which authority approves?'; kind = 'business_decision'; answeredParts = @('The policy applies to existing accounts.'); remainingQuestion = 'Which authority approves?' }
    $step = Get-DialogueStep $state (Message 'waiting_reply' @($narrowed)) 'target' $policy $fixture @{}
    Assert ($step.action -eq 'send' -and $state.pending[0].originalQuestion -eq 'Who approves the policy?' -and
        $state.pending[0].remainingQuestion -eq 'Which authority approves?' -and $state.pending[0].history.Count -eq 2 -and
        $state.pending[0].answeredParts.Count -eq 1) 'Question narrowing preserves original evidence and continues routing.'
    Reject { Get-DialogueStep $state (Message 'waiting_reply' @(@{ id = 'pending-1'; question = 'Changed'; kind = 'technical_followup' })) 'participant' $policy $fixture @{} }
    Reject { Read-DialogueMessage 'Received.' }
    Reject { Read-DialogueMessage ('Reply.' + "`n" + 'DIALOGUE_CONTROL: {"status":"waiting_reply","pending":[],"artifactPaths":[]}' + "`nExtra") }
    $state = New-DialogueState
    $state.calls = 1
    $known = @{ id = 'Q1'; question = 'Who may sign in?'; kind = 'business_decision' }
    $partial = @{ id = 'Q4'; question = 'Which policy changes, and who approves?'; kind = 'business_decision' }
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($known, $partial)) 'target' $policy $fixture @{})
    Assert ($state.pending.Count -eq 0 -and $state.questions[0].questionStatus -eq 'awaiting_reply') 'A new question is not a confirmed business unknown.'
    $state.calls = 2
    $partial['answeredParts'] = @('The sign-in policy changes.')
    $partial['remainingQuestion'] = 'Approval is not yet decided.'
    $partial['questionStatus'] = 'partially_answered'
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($partial)) 'participant' $policy $fixture @{})
    Assert ($state.questions[0].questionStatus -eq 'answered' -and $state.pending.Count -eq 1 -and
        $state.pending[0].questionStatus -eq 'partially_answered') 'Answered batch questions leave the pending projection; partial decisions remain.'
    'Draft Q4: The change is confirmed; the approving authority still needs a decision.' | Set-Content (Join-Path $fixture 'draft.md')
    $step = Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}
    Assert ($state.outcome -eq 'completed_with_pending' -and $step.artifactCheck.ready) 'Equivalent partial-question wording permits pending draft delivery without retaining answered IDs as blockers.'
    $reopened = $partial.Clone()
    $reopened.questionStatus = 'awaiting_reply'
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($reopened)) 'target' $policy $fixture @{})
    [void](Get-DialogueStep $state (Message 'waiting_reply') 'participant' $policy $fixture @{})
    Assert ($state.pending.Count -eq 1) 'A real pending decision cannot be downgraded to awaiting-reply and then erased by omission.'
    $resolved = @{ id = 'Q4'; question = $partial.question; kind = 'business_decision'; questionStatus = 'answered'; answeredParts = @('The authorized policy owner approves.'); remainingQuestion = $null }
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($resolved)) 'participant' $policy $fixture @{})
    Assert ($state.pending.Count -eq 0 -and $state.questions[1].questionStatus -eq 'answered') 'Explicit participant answer evidence can resolve a true pending decision.'
    [void](Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{})
    Assert ($state.outcome -eq 'stage_completed') 'A fully answered task is not permanently marked pending.'
    $state = New-DialogueState
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($known)) 'target' $policy $fixture @{})
    $policy.minimumParticipantReplies = 0
    $step = Get-DialogueStep $state (Message 'role_task_completed' @() @('draft.md')) 'target' $policy $fixture @{}
    Assert ($step.artifactCheck.failures[0].reason -eq 'question_not_answered') 'An unanswered question cannot be parked as a pending decision to skip interaction.'
    $state = New-DialogueState
    $policy.requireArtifact = $false
    [void](Get-DialogueStep $state (Message 'waiting_reply' @($known)) 'target' $policy $fixture @{})
    $step = Get-DialogueStep $state (Message 'role_task_completed') 'target' $policy $fixture @{}
    Assert ($step.action -eq 'prompt' -and $step.artifactCheck.failures[0].reason -eq 'question_not_answered') 'Discussion-only stages still require answers to actually asked questions.'
    $policy.requireArtifact = $true
    Reject { Get-DialogueStep $state (Message 'role_task_completed' @(@{ id = 'Q1'; question = 'Who may sign in?'; kind = 'business_decision'; questionStatus = 'answered'; answeredParts = @('Everyone.') })) 'target' $policy $fixture @{} }
    Write-Output 'PASS: routing, completion evidence, pending retention, configurable authority, exact call budget and bounded coordination'
} finally { Remove-Item $fixture -Recurse -Force }

if ($RecordedRunDirectory) {
    $recorded = Get-Content (Join-Path $RecordedRunDirectory 'result.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $replayed = New-DialogueState
    foreach ($turn in $recorded.turns) {
        $replayed.calls = $turn.call
        $decision = Get-DialogueStep $replayed $turn.response $turn.role $recorded.policy $recorded.repositoryPath @{}
    }
    Assert ($replayed.outcome -eq 'completed_with_pending' -and $replayed.artifactCheck.ready) 'Archived final draft passes delivery checks without exact wording.'
    $answeredIds = @($replayed.questions | Where-Object { $_.questionStatus -eq 'answered' } | ForEach-Object { $_.id })
    Assert (@('Q1', 'Q2', 'Q5', 'Q6' | Where-Object { $_ -cnotin $answeredIds }).Count -eq 0) 'Recorded answered questions are not retained as unresolved decisions.'
    Write-Output "PASS: read-only final-artifact replay; outcome=$($replayed.outcome); pending=$(@($replayed.pending.id) -join ','); original run files unchanged"
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dialogue-run-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$savedRuntimeFixture = $env:DIALOGUE_RUNTIME_FIXTURE
try {
    $env:PATH = $PSHOME + [IO.Path]::PathSeparator + $env:PATH
    $repository = Join-Path $fixture 'product'
    $agents = Join-Path $repository '.github/agents'
    [void](New-Item -ItemType Directory -Path $agents -Force)
    "---`nname: fixture-target`n---`nComplete the assigned task." | Set-Content (Join-Path $agents 'fixture-target.agent.md')
    & git -C $repository init --quiet
    Assert ($LASTEXITCODE -eq 0) 'Fixture repository initialized.'
    & git -C $repository add --all
    & git -C $repository -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=.git/disabled-hooks commit --quiet -m fixture
    Assert ($LASTEXITCODE -eq 0) 'Fixture baseline committed.'
    'PRIVATE_FIXTURE_KNOWLEDGE' | Set-Content (Join-Path $fixture 'knowledge.md')
    $config = @{
        repositoryPath = $repository; runDirectory = (Join-Path $fixture 'run')
        targetAgent = 'fixture-target'; targetModel = 'fixture-model'; participantModel = 'fixture-model'
        knowledgeFile = (Join-Path $fixture 'knowledge.md'); initialRequest = 'Prepare the requirements draft.'
        policy = @{ minimumParticipantReplies = 1 }
    }
    $configFile = Join-Path $fixture 'config.json'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    $runner = Join-Path $PSScriptRoot '../tools/Invoke-AgentDialogue.ps1'
    $cli = Join-Path $PSScriptRoot 'fixtures/fake-agent-dialogue.ps1'
    if ($RuntimeErrorsOnly) {
        $env:DIALOGUE_RUNTIME_FIXTURE = 'path-denied'
        $config['policy'] = @{ callLimit = 2; maxPathRecoveryPrompts = 0 }
        $config.runDirectory = Join-Path $fixture 'runtime-errors'
        $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
        & $runner -ConfigFile $configFile -CliPath $cli
        $continued = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
        Assert ($continued.calls -eq 2 -and $continued.turns[0].runtimeProblemDisposition -eq 'continued_with_valid_reply' -and
            $continued.turns[0].runtimeProblems.Count -eq 1 -and $continued.turns[0].delivery.status -eq 'captured_input' -and
            $continued.turns[1].inputSender -eq 'target' -and $continued.outcome -eq 'budget_exceeded') 'A valid reply after a denied tool call is recorded and delivered despite the runtime error.'
        Assert ($continued.durationMs -gt 0 -and $continued.roleDurationMs.target -ge $continued.turns[0].durationMs -and
            $continued.roleDurationMs.participant -ge $continued.turns[1].durationMs -and
            @($continued.turns | Where-Object { $null -eq $_.durationMs }).Count -eq 0) 'Run, per-role and per-call elapsed times are recorded.'
        $continuedSummary = Get-Content (Join-Path $config.runDirectory 'summary.md') -Raw
        Assert ($continuedSummary.Contains('已记录错误并继续对话') -and $continuedSummary.Contains('path-denied') -and
            $continuedSummary.Contains('整场耗时') -and $continuedSummary.Contains('累计耗时')) 'Readable report retains the runtime error and shows elapsed times.'
        $continuedReport = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
        Assert ($continuedReport.durationMs -gt 0 -and $continuedReport.executions[0].durationMs -gt 0 -and
            $continuedReport.roleDurationMs.target -ge $continuedReport.executions[0].durationMs) 'Structured report contains total, per-role and per-call elapsed times.'
        $env:DIALOGUE_RUNTIME_FIXTURE = 'path-denied-no-reply'
        $config.runDirectory = Join-Path $fixture 'no-runtime-reply'
        $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
        Reject { & $runner -ConfigFile $configFile -CliPath $cli }
        $noReply = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
        Assert ($noReply.calls -eq 1 -and $noReply.error.Contains('Runtime tool failure (not a model mismatch)')) 'A runtime error without a valid final reply still fails the turn.'
        Write-Output 'PASS: valid replies continue after runtime errors; missing replies still fail'
        return
    }
    & $runner -ConfigFile $configFile -CliPath $cli
    $result = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert (Test-Path (Join-Path $config.runDirectory 'summary.md')) 'Each standalone run automatically has a readable summary.'
    Assert ($result.outcome -eq 'completed_with_pending' -and $result.calls -eq 3) 'Two real collector sessions deliver pending draft in three fake model calls.'
    Assert ($result.policy.callLimit -eq 10 -and $result.policy.skipIssueRegistration -and $result.policy.disableBuiltinMcps) 'Approved test defaults are configurable policy.'
    Assert ($result.policy.minimumParticipantReplies -eq 1) 'Three-call fixture explicitly overrides the production interaction minimum.'
    foreach ($key in $templatePolicy.Keys) {
        if ($key -eq 'minimumParticipantReplies') { continue }
        Assert ($result.policy.$key -ceq $templatePolicy[$key]) "Runner inherits template policy: $key"
    }
    Assert ($result.pending.Count -eq 1 -and $result.assessment -eq 'not_scored') 'Delivery is not business approval or scoring.'
    Assert ($result.turns[1].response.control.status -eq 'waiting_reply' -and
        $result.turns[2].input -ceq $result.turns[1].response.text -and
        $result.turns[2].inputSender -eq 'participant' -and $result.recoveries -eq 0) 'Actual target input receives the full answer, not a coordinator prompt.'
    Assert ($result.turns[1].delivery.status -eq 'captured_input' -and $result.turns[1].delivery.targetCall -eq 3) 'Forwarding is confirmed by captured counterpart input, not just a routing intention.'
    foreach ($turn in $result.turns) {
        $capturedPrompt = Get-Content (Join-Path $turn.capturePath 'input.txt') -Raw -Encoding utf8
        Assert ($capturedPrompt.Contains('一次 CLI 调用返回，只结束当前发言，不代表整场任务结束') -and
            $capturedPrompt.Contains('控制器再将答复送回被测角色并恢复其会话') -and
            $capturedPrompt.Contains('尚未收到业务回复、当前 CLI 非交互、没有 Agent 调用工具，本身都不构成 blocked') -and
            $capturedPrompt.Contains('minimumParticipantReplies 是整场对话累计的业务参与者回复次数要求') -and
            $capturedPrompt.Contains('业务参与者遇到没有已批准答案或知识冲突的问题，应如实说明')) 'Both roles receive the handoff, reply-count and blocker contract on every captured call, including resumed calls.'
    }
    & (Join-Path $PSScriptRoot '../tools/Export-AgentDialogueReport.ps1') -RunDirectory $config.runDirectory
    $report = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert ($report.usage.target.totalNanoAiu -eq 3000000000 -and $report.usage.participant.totalNanoAiu -eq 2000000000 -and
        $report.usage.target.aiCredits -eq 3 -and $report.usage.participant.aiCredits -eq 2 -and
        $report.usage.target.inputTokens -eq 35 -and $report.usage.target.outputTokens -eq 15) 'Use latest session totals for AIC and tokens, not the sum of cumulative turn snapshots.'
    Assert ($report.messages.Count -eq 6 -and $report.messages[0].time -and $report.messages[1].time) 'Complete dialogue includes timed inputs and replies.'
    Assert ($report.messages[3].delivery.status -eq 'captured_input') 'Report distinguishes receiving a response from confirmed delivery.'
    Assert ($report.executions.Count -eq 3 -and $report.executions[0].requestedModel -eq 'fixture-model' -and
        $report.executions[1].observedModels[0] -eq 'fixture-model') 'Each invocation exposes its requested and actual models independently of message sender.'
    Assert ($report.conversation.Count -eq 4 -and $report.messages.Count -eq 6) 'Readable view deduplicates forwarded inputs while structured audit retains every message.'
    $summary = Get-Content (Join-Path $config.runDirectory 'summary.md') -Raw
    Assert ($summary.Contains('Participant → Controller → Target') -and $summary.Contains('送达凭据：') -and
        -not $summary.Contains('修订：')) 'Summary shows accurate routes, input evidence, and concise question states.'
    $latestTarget = Get-ChildItem (Join-Path $config.runDirectory 'target-capture') -Directory -Filter 'turn-*' | Sort-Object Name | Select-Object -Last 1
    $partialUsage = Get-Content (Join-Path $latestTarget.FullName 'usage.json') -Raw | ConvertFrom-Json -AsHashtable
    $partialUsage.aiCreditsStatus = 'partial'
    $partialUsage | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $latestTarget.FullName 'usage.json') -Encoding utf8
    & (Join-Path $PSScriptRoot '../tools/Export-AgentDialogueReport.ps1') -RunDirectory $config.runDirectory
    $partialReport = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert ($partialReport.usage.target.aiCredits -eq 3 -and $partialReport.usage.target.status -eq 'partial') 'Partial reported credits remain visible with their incomplete status.'
    Remove-Item (Join-Path $latestTarget.FullName 'usage.json')
    & (Join-Path $PSScriptRoot '../tools/Export-AgentDialogueReport.ps1') -RunDirectory $config.runDirectory
    $report = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert ($null -eq $report.usage.target.aiCredits) 'Missing final usage is unknown, not free and not an earlier snapshot.'
    Reject { & $runner -ConfigFile $configFile -CliPath $cli }
    $config.runDirectory = Join-Path $fixture 'budget'
    $config['policy'] = @{ callLimit = 1; minimumParticipantReplies = 0; maxPathRecoveryPrompts = 0
        interactionPrompt = 'Configured interaction prompt.'; coordinatorPrompt = 'Configured coordinator prompt.' }
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    & $runner -ConfigFile $configFile -CliPath $cli
    $result = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert ($result.outcome -eq 'budget_exceeded' -and $result.calls -eq 1) 'Runner obeys total call budget.'
    foreach ($key in $config.policy.Keys) {
        Assert ($result.policy.$key -ceq $config.policy[$key]) "Explicit policy overrides template defaults: $key"
    }
    $config.runDirectory = Join-Path $fixture 'auto'
    $config.targetModel = 'auto'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    & $runner -ConfigFile $configFile -CliPath $cli
    $result = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert ($result.turns[0].requestedModel -ceq 'auto' -and
        $result.turns[0].observedModels[0] -ceq 'fixture-auto-selected') 'Auto target retains the actually selected model evidence.'
    $autoReport = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert ($autoReport.executions[0].requestedModel -eq 'auto' -and
        $autoReport.executions[0].observedModels[0] -eq 'fixture-auto-selected') 'Auto reports the resolved model rather than displaying auto as the actual model.'
    $modelEvidencePath = Join-Path $config.runDirectory 'result.json'
    $modelFixture = Get-Content $modelEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    $modelFixture.turns[0].observedModels = @('fixture-first', 'fixture-second')
    $modelFixture | ConvertTo-Json -Depth 40 | Set-Content $modelEvidencePath
    & (Join-Path $PSScriptRoot '../tools/Export-AgentDialogueReport.ps1') -RunDirectory $config.runDirectory
    $multipleReport = Get-Content (Join-Path $config.runDirectory 'report.json') -Raw | ConvertFrom-Json
    Assert ($multipleReport.executions[0].observedModels.Count -eq 2 -and
        (Get-Content (Join-Path $config.runDirectory 'summary.md') -Raw).Contains('fixture-first, fixture-second')) 'Multiple actually observed models within a call are not collapsed to one.'
    $config.runDirectory = Join-Path $fixture 'invalid-participant'
    $config.participantModel = 'auto'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    Reject { & $runner -ConfigFile $configFile -CliPath $cli }
    Remove-Item (Join-Path $repository 'draft.md')
    $config.targetModel = 'fixture-model'
    $config.participantModel = 'fixture-model'
    $config.Remove('policy')
    $config['participantAgentFile'] = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../agents/simple-business-user.agent.md'))
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    'Private source knowledge must be excluded.' | Set-Content (Join-Path $repository 'sample02.simple-knowledge.md')
    'Another case knowledge must also be excluded.' | Set-Content (Join-Path $repository 'sample01.simple-knowledge.md')
    'Private unrelated scenario oracle.' | Set-Content (Join-Path $repository 'unrelated.oracle.json')
    $comparisonRoot = Join-Path $fixture 'comparison'
    $config['caseId'] = 'sample02'
    $config['policy'] = @{ minimumParticipantReplies = 0; interactionPrompt = 'Comparison template interaction prompt.' }
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    & (Join-Path $PSScriptRoot '../tools/Invoke-AgentDialogueComparison.ps1') -SourceRepository $repository -RunDirectory $comparisonRoot -TemplateFile $configFile -ParticipantModel fixture-model -TargetModels @('auto', 'gpt-6-luna') -CliPath $cli
    $comparison = Get-Content (Join-Path $comparisonRoot 'comparison.json') -Raw | ConvertFrom-Json
    foreach ($private in @('sample01.simple-knowledge.md', 'sample02.simple-knowledge.md', 'unrelated.oracle.json')) {
        Assert ($private -in $comparison.excludedFiles -and -not (Test-Path (Join-Path $comparisonRoot "baseline\$private"))) "Private case file excluded without a hardcoded case ID: $private"
    }
    foreach ($condition in $comparison.conditions) {
        $conditionConfig = Get-Content $condition.configFile -Raw | ConvertFrom-Json
        $conditionResult = Get-Content (Join-Path $condition.runDirectory 'result.json') -Raw | ConvertFrom-Json
        Assert ($conditionConfig.policy.minimumParticipantReplies -eq 0 -and
            $conditionResult.policy.minimumParticipantReplies -eq 0 -and
            $conditionResult.policy.interactionPrompt -ceq $config.policy.interactionPrompt) 'Comparison preserves explicit template values, including zero and prompt text.'
    }
    Assert (@($comparison.conditions | Where-Object { $_.state -ne 'completed_with_pending' }).Count -eq 0) 'Both conditions deliver from independent identical baselines.'
    Assert ($comparison.conditions[0].name -eq 'sample02-auto-01' -and $comparison.conditions[1].name -eq 'sample02-luna-02') 'Test directories identify case, requested model and sample sequence.'
    Assert ((Test-Path (Join-Path $comparisonRoot 'summary.md')) -and $comparison.conditions[0].targetAiCredits -eq 3) 'Comparison index links independent reports with session credit statistics.'
    $automaticRuns = Join-Path $fixture 'automatic-comparisons'
    & (Join-Path $PSScriptRoot '../tools/Invoke-AgentDialogueComparison.ps1') -SourceRepository $repository -RunsRoot $automaticRuns -RunLabel fixture-models -TemplateFile $configFile -ParticipantModel fixture-model -TargetModels @('auto') -CliPath $cli
    $automaticRoot = @(Get-ChildItem $automaticRuns -Directory)[0].FullName
    $automaticComparison = Get-Content (Join-Path $automaticRoot 'comparison.json') -Raw | ConvertFrom-Json
    Assert ([IO.Path]::GetFileName($automaticRoot) -match '^sample02-dialogue-001-\d{8}-fixture-models$' -and
        $automaticComparison.runDirectory -eq $automaticRoot -and
        $automaticComparison.conditions[0].state -eq 'completed_with_pending') 'Automatic root naming is used by the actual comparison entry and all generated paths.'
    & (Join-Path $PSScriptRoot '../tools/Export-AgentDialogueReport.ps1') -RunDirectory $comparisonRoot
    Assert ((Get-Content (Join-Path $comparisonRoot 'summary.md') -Raw).Contains('3.00')) 'Existing comparisons can regenerate their readable indexes without rerunning sessions.'
    $env:DIALOGUE_RUNTIME_FIXTURE = 'path-denied'
    $config.targetModel = 'fixture-model'; $config.participantModel = 'fixture-model'
    $config['policy'] = @{ callLimit = 2; maxPathRecoveryPrompts = 1 }
    $config.runDirectory = Join-Path $fixture 'path-recovery'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    & $runner -ConfigFile $configFile -CliPath $cli
    $recoveryResult = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert ($recoveryResult.calls -eq 2 -and $recoveryResult.pathRecoveries -eq 1 -and
        $recoveryResult.turns[0].controller.reason -eq 'workspace_path_correction' -and
        $recoveryResult.turns[1].inputSender -eq 'controller' -and $recoveryResult.outcome -eq 'budget_exceeded') 'Path correction is bounded by the shared call budget.'
    $sessions = @(Get-ChildItem (Join-Path $config.runDirectory 'target-capture') -Directory -Filter 'turn-*' | ForEach-Object {
        (Get-Content (Join-Path $_.FullName 'turn.json') -Raw | ConvertFrom-Json).sessionId
    } | Sort-Object -Unique)
    Assert ($sessions.Count -eq 1) 'Path recovery resumes the same target session.'
    Assert ($recoveryResult.turns[0].toolSnapshots[0].names -contains 'create') 'Effective tool evidence is recorded separately from allowlist intent.'
    $config.policy.maxPathRecoveryPrompts = 0
    $config.policy.callLimit = 2
    $config.runDirectory = Join-Path $fixture 'path-recovery-disabled'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    & $runner -ConfigFile $configFile -CliPath $cli
    $deniedResult = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert ($deniedResult.calls -eq 2 -and $deniedResult.turns[0].runtimeProblemDisposition -eq 'continued_with_valid_reply' -and
        $deniedResult.turns[0].runtimeProblems.Count -eq 1 -and $deniedResult.turns[0].delivery.status -eq 'captured_input' -and
        $deniedResult.turns[1].inputSender -eq 'target' -and $deniedResult.outcome -eq 'budget_exceeded') 'A valid reply after a denied tool call is recorded and delivered despite the runtime error.'
    $continuedSummary = Get-Content (Join-Path $config.runDirectory 'summary.md') -Raw
    Assert ($continuedSummary.Contains('已记录错误并继续对话') -and $continuedSummary.Contains('path-denied')) 'Readable report distinguishes a continued runtime error and retains its event evidence.'
    $env:DIALOGUE_RUNTIME_FIXTURE = 'path-denied-no-reply'
    $config.runDirectory = Join-Path $fixture 'path-denied-no-reply'
    $config | ConvertTo-Json -Depth 8 | Set-Content $configFile
    Reject { & $runner -ConfigFile $configFile -CliPath $cli }
    $noReplyResult = Get-Content (Join-Path $config.runDirectory 'result.json') -Raw | ConvertFrom-Json
    Assert ($noReplyResult.calls -eq 1 -and $noReplyResult.error.Contains('Runtime tool failure (not a model mismatch)')) 'A runtime error without a valid final reply still fails the turn.'
    Assert (-not (Test-Path (Join-Path $repository 'draft.md'))) 'Comparison leaves the source working tree unchanged.'
    Assert (-not (Test-Path (Join-Path $comparisonRoot 'sample02-auto-01/product/sample02.simple-knowledge.md'))) 'Private source knowledge is excluded from target snapshots.'
    Write-Output 'PASS: automatic dual sessions, private knowledge isolation, captured transport, pending draft and call limit'
} finally {
    $env:DIALOGUE_RUNTIME_FIXTURE = $savedRuntimeFixture
    $env:PATH = $savedPath
    if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
}