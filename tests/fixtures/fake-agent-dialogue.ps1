if ($args -contains '--version') { Write-Output 'fixture-dialogue 1.0'; exit 0 }
if ($args -contains '--help') { Write-Output "  --disallow-temp-dir`n  --sync-session[=<on|off>]"; exit 0 }
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
$agent = $args[[Array]::IndexOf($args, '--agent') + 1]
$model = $args[[Array]::IndexOf($args, '--model') + 1]
$autoTierIndex = [Array]::IndexOf($args, '--auto-tier')
$autoTier = if ($autoTierIndex -ge 0) { $args[$autoTierIndex + 1] } else { $null }
if ($autoTier -eq 'balance' -and ($model -ne 'auto' -or $args -contains '--experimental')) {
    throw 'Fusion Standard must use explicit auto/balance without legacy experimental flags.'
}
$isFusion = $model -in @('hydrafusion', 'hydrafusion-max') -or $autoTier -in @('hydrafusion', 'hydrafusion-max')
if ($model -ceq 'auto') { $model = if ($autoTier) { "fixture-fusion-$autoTier" } else { 'fixture-auto-selected' } }
elseif ($isFusion) { $model = "fixture-fusion-$model" }
$repository = $args[[Array]::IndexOf($args, '-C') + 1]
if ($env:DIALOGUE_DESIGN_FIXTURE -eq 'dev-coding') {
    if ($agent -eq 'result-quality-evaluator') {
        $prompt | & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'fake-result-evaluator.ps1') @args
        exit $LASTEXITCODE
    }
    if ($agent -eq 'simple-business-user') { throw 'Dev stage must not invoke Participant Agent.' }
    if ($isFusion -and $args -notcontains '--experimental') { throw 'HydraFusion requires --experimental flag.' }
    if ($args -notcontains 'shell') { throw 'Dev stage must allow shell tool category.' }
    if (-not (Get-Content (Join-Path $repository 'docs/design/design-uf01.md') -Raw).Contains('CONFIRMED_DESIGN_DOC')) { throw 'Target design doc missing in dev workspace.' }
    if (-not (Get-Content (Join-Path $repository 'docs/requirements/req-uf01.md') -Raw).Contains('SHARED_CONFIRMED_REQUIREMENT')) { throw 'Target requirement doc missing in dev workspace.' }
    $codeFile = Join-Path $repository 'src/auth_login.py'
    [void](New-Item -ItemType Directory -Path (Split-Path $codeFile) -Force)
    'Summary evidence for evaluator: implemented login code and unit tests.' | Set-Content $codeFile -Encoding utf8
    $usageIndex = [Array]::IndexOf($args, '--usage-output-file')
    @{ totalNanoAiu = 1000000; aiCreditsStatus = 'complete'; tokenDetails = @{
        input = @{ tokenCount = 10 }; cache_read = @{ tokenCount = 0 }; cache_write = @{ tokenCount = 0 }; output = @{ tokenCount = 10 }
    } } | ConvertTo-Json -Depth 8 | Set-Content $args[$usageIndex + 1] -Encoding utf8
    if ($isFusion) {
        @{ type = 'assistant.fusion_phase_started'; id = 'fusion-1'; data = @{ phaseId = 'p1'; phaseKind = 'primary'; pattern = 'cascade'; role = 'solver'; model = 'gpt-6.1-sol' } } | ConvertTo-Json -Compress
        @{ type = 'assistant.fusion_phase_completed'; id = 'fusion-2'; data = @{ phaseId = 'p2'; phaseKind = 'judge'; role = 'judge'; model = 'claude-opus-5.5' } } | ConvertTo-Json -Compress
        @{ type = 'session.fusion_completed'; id = 'fusion-3'; data = @{ fusionId = 'f1'; pattern = 'cascade'; finalSourceModel = 'gpt-6.1-sol'; followUpModel = 'gpt-6.1-sol' } } | ConvertTo-Json -Compress
    }
    @{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
    $body = 'Summary evidence for evaluator. Implemented feature and passed local pytest.'
    if ($prompt.Contains('DIALOGUE_CONTROL')) { throw 'Dev prompt must not require dialogue control.' }
    @{ type = 'assistant.message'; id = 'dev-final'; data = @{ content = $body } } | ConvertTo-Json -Depth 12 -Compress
    exit 0
}
if ($env:DIALOGUE_DESIGN_FIXTURE -in @('shared-requirement', 'req-sdlc', 'req-sdlc-tamper')) {
    $isReq = $env:DIALOGUE_DESIGN_FIXTURE -like 'req-sdlc*'
    if ($agent -eq 'result-quality-evaluator') {
        $prompt | & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'fake-result-evaluator.ps1') @args
        exit $LASTEXITCODE
    }
    if ($prompt.Contains('PRIVATE_DOMAIN_SCORE') -or $prompt.Contains('PROJECT_RULE_ONLY')) { throw 'Scoring or project rule text injected into dialogue.' }
    if ($isReq) {
        if ($agent -eq 'simple-business-user') {
            $second = $prompt.Contains('Second business question')
            if (-not $second -and -not $prompt.Contains('PRIVATE_REQ_KNOWLEDGE')) { throw 'The first Req participant call must receive private knowledge.' }
            $body = if ($second) { 'Second mock answer.' } else { 'First mock answer.' }
            $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @(@{
                id = $(if ($second) { 'Q2' } else { 'Q1' }); question = 'Business question'; kind = 'business_decision'
                questionStatus = 'answered'; answeredParts = @($body); remainingQuestion = $null
            }) }
        } else {
            if ($agent -ne 'SDLCRole_PM' -or $prompt.Contains('PRIVATE_REQ_KNOWLEDGE')) { throw 'Req must select the new PM without leaking private knowledge.' }
            if ($env:DIALOGUE_DESIGN_FIXTURE -eq 'req-sdlc-tamper') { Add-Content (Join-Path $repository 'docs\contract.md') 'Unauthorized edit.' }
            if ($prompt.Contains('Second mock answer.')) {
                $artifact = Join-Path $repository 'docs\requirements\req-uf01.md'
                [void](New-Item -ItemType Directory -Path (Split-Path $artifact) -Force)
                'Summary evidence for evaluator. Draft; human approval pending.' | Set-Content $artifact -Encoding utf8
                $body = 'Summary evidence for evaluator. Draft only; no human approval.'
                $control = @{ status = 'role_task_completed'; artifactPaths = @('docs/requirements/req-uf01.md'); pending = @() }
            } else {
                $second = $prompt.Contains('First mock answer.')
                $body = if ($second) { 'Second business question?' } else { 'First business question?' }
                $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @(@{
                    id = $(if ($second) { 'Q2' } else { 'Q1' }); question = $body; kind = 'business_decision'; questionStatus = 'awaiting_reply'
                }) }
            }
        }
    } elseif ($agent -eq 'simple-business-user') {
        if (-not $prompt.Contains('SHARED_CONFIRMED_REQUIREMENT') -or $prompt.Contains('以下是私有业务知识')) { throw 'Participant must receive the shared requirement label and content.' }
        $body = 'Confirmed requirement answer.'
        $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @(@{
            id = 'Q1'; question = 'What is confirmed?'; kind = 'business_decision'
            questionStatus = 'answered'; answeredParts = @('SHARED_CONFIRMED_REQUIREMENT'); remainingQuestion = $null
        }) }
    } else {
        if (-not (Get-Content (Join-Path $repository 'docs/requirements/req-uf01.md') -Raw).Contains('SHARED_CONFIRMED_REQUIREMENT')) { throw 'Target requirement missing.' }
        if (-not (Get-Content (Join-Path $repository '.github/copilot-instructions.md') -Raw).Contains('PROJECT_RULE_ONLY')) { throw 'Project instructions missing from workspace.' }
        if (Test-Path (Join-Path $repository 'docs/fixture.simple-knowledge.md')) { throw 'Excluded private input copied.' }
        if ($prompt.Contains('Confirmed requirement answer.')) {
            $artifact = Join-Path $repository 'docs/design/design-uf01.md'
            [void](New-Item -ItemType Directory -Path (Split-Path $artifact) -Force)
            'Summary evidence for evaluator.' | Set-Content $artifact -Encoding utf8
            $body = 'Summary evidence for evaluator. Role task completed.'
            $control = @{ status = 'role_task_completed'; artifactPaths = @('docs/design/design-uf01.md'); pending = @() }
        } else {
            $body = 'What is confirmed?'
            $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @(@{
                id = 'Q1'; question = 'What is confirmed?'; kind = 'business_decision'; questionStatus = 'awaiting_reply'
            }) }
        }
    }
    $usageIndex = [Array]::IndexOf($args, '--usage-output-file')
    @{ totalNanoAiu = 1000000; aiCreditsStatus = 'complete'; tokenDetails = @{
        input = @{ tokenCount = 10 }; cache_read = @{ tokenCount = 0 }; cache_write = @{ tokenCount = 0 }; output = @{ tokenCount = 10 }
    } } | ConvertTo-Json -Depth 8 | Set-Content $args[$usageIndex + 1] -Encoding utf8
    @{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
    @{ type = 'assistant.message'; id = 'design-final'; data = @{ content = ($body + "`nDIALOGUE_CONTROL: " + (ConvertTo-Json $control -Depth 8 -Compress)) } } | ConvertTo-Json -Depth 12 -Compress
    exit 0
}
if ($env:DIALOGUE_RUNTIME_FIXTURE -in @('path-denied', 'path-denied-no-reply') -and $agent -ne 'simple-business-user' -and -not $prompt.Contains('上次读取被拒绝')) {
    $badPath = Join-Path (Split-Path $repository) '.github/agents/fixture-target.agent.md'
    @{ type = 'tool.execution_start'; data = @{ toolCallId = 'bad-path'; toolName = 'view'; arguments = @{ path = $badPath } } } | ConvertTo-Json -Depth 8 -Compress
    @{ type = 'tool.execution_complete'; id = 'path-denied'; data = @{ toolCallId = 'bad-path'; success = $false; error = @{ code = 'denied'; message = 'Permission denied because no interactive user response was available.' } } } | ConvertTo-Json -Depth 8 -Compress
}
@{ type = 'prompt_cache_break'; data = @{ afterRequest = @{ model = $model; tools_truncated = 0; tools = @(@{ name = 'view' }, @{ name = 'create' }, @{ name = 'edit' }) } } } | ConvertTo-Json -Depth 8 -Compress
$usagePath = $args[[Array]::IndexOf($args, '--usage-output-file') + 1]
$nanoAiu = if ($agent -eq 'simple-business-user') { 2000000000 } elseif ($prompt.Contains('That policy has no approved decision.')) { 3000000000 } else { 1000000000 }
@{ totalNanoAiu = $nanoAiu; aiCreditsStatus = 'complete'; totalPremiumRequestCost = 1
    tokenDetails = @{ input = @{ tokenCount = 10 }; cache_read = @{ tokenCount = 20 }; cache_write = @{ tokenCount = 5 }; output = @{ tokenCount = 15 } }
} | ConvertTo-Json -Depth 8 | Set-Content $usagePath -Encoding utf8
if ($agent -eq 'simple-business-user') {
    if ($args -notcontains '--available-tools' -or $args -notcontains '--disable-builtin-mcps') { throw 'Participant isolation missing.' }
    if (-not $prompt.Contains('PRIVATE_FIXTURE_KNOWLEDGE')) { throw 'Knowledge missing.' }
    $body = 'That policy has no approved decision.'
    $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @(@{ id = 'pending-1'; question = 'Who approves the policy?'; kind = 'business_decision' }) }
} else {
    if ($args -notcontains 'create' -or $args -notcontains 'edit' -or $args -contains '--allow-all') { throw 'Target requires compatible local write tools without global approval.' }
    if (-not $prompt.Contains($repository) -or -not $prompt.Contains('优先使用相对路径')) { throw 'Workspace path contract missing.' }
    if ($prompt.Contains('PRIVATE_FIXTURE_KNOWLEDGE')) { throw 'Private knowledge leaked to target.' }
    if ($prompt.Contains('That policy has no approved decision.')) {
        'Draft pending-1: Who approves the policy?' | Set-Content (Join-Path $repository 'draft.md') -Encoding utf8
        $body = 'Role task completed. Draft produced: draft.md; pending decision retained.'
        $control = @{ status = 'role_task_completed'; artifactPaths = @('draft.md'); pending = @() }
    } else {
        $body = 'Who approves the policy?'
        $control = @{ status = 'waiting_reply'; artifactPaths = @(); pending = @() }
    }
}
@{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
if ($env:DIALOGUE_RUNTIME_FIXTURE -eq 'path-denied-no-reply' -and $agent -ne 'simple-business-user') { exit 0 }
@{ type = 'assistant.message'; id = 'final'; data = @{ content = ($body + "`nDIALOGUE_CONTROL: " + (ConvertTo-Json $control -Depth 8 -Compress)) } } | ConvertTo-Json -Depth 10 -Compress
exit 0