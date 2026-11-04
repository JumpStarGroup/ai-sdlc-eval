#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action, [string]$MessagePattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert ($failure -and $failure -like $MessagePattern) "Expected rejection matching '$MessagePattern'; actual: $failure"
}
$framework = Split-Path $PSScriptRoot
$runner = Join-Path $framework 'tools/Invoke-SDLC-Eval.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('design-scenario-' + [guid]::NewGuid().ToString('N'))
$savedFixture = $env:DIALOGUE_DESIGN_FIXTURE
$savedAutoload = $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
try {
    $source = Join-Path $fixture 'product'
    [void](New-Item -ItemType Directory -Path (Join-Path $source '.github/agents') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'docs') -Force)
    "---`nname: fixture-architect`ntools: [read/readFile, edit]`n---`nDesign only." | Set-Content (Join-Path $source '.github/agents/fixture-architect.agent.md') -Encoding utf8
    "---`nname: fixture-developer`ntools: [read/readFile, edit, execute/runInTerminal]`n---`nCode and test." | Set-Content (Join-Path $source '.github/agents/fixture-developer.agent.md') -Encoding utf8
    'PROJECT_RULE_ONLY' | Set-Content (Join-Path $source '.github/copilot-instructions.md') -Encoding utf8
    'EXCLUDED_PRIVATE_INPUT' | Set-Content (Join-Path $source 'docs/fixture.simple-knowledge.md') -Encoding utf8
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'tests') -Force)
    "def test_smoke():`n    assert 2 + 2 == 4" | Set-Content (Join-Path $source 'tests/test_smoke.py') -Encoding utf8
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'runtime-state') -Force)
    'fixture state' | Set-Content (Join-Path $source 'runtime-state/state.txt') -Encoding utf8
    & git -C $source init --quiet
    Assert ($LASTEXITCODE -eq 0) 'Fixture Git initialization failed.'
    & git -C $source add --all
    Assert ($LASTEXITCODE -eq 0) 'Fixture baseline staging failed.'
    $requirement = Join-Path $fixture 'requirement.md'
    'SHARED_CONFIRMED_REQUIREMENT' | Set-Content $requirement -Encoding utf8
    $designDoc = Join-Path $fixture 'design.md'
    'CONFIRMED_DESIGN_DOC' | Set-Content $designDoc -Encoding utf8
    $rubric = @{ schemaVersion = 1; id = 'unrelated-feature'; version = '1'; scale = @{ min = 0; max = 4 }
        criteria = @(@{ id = 'design_scope'; title = 'Design scope'; weight = 100; description = 'PRIVATE_DOMAIN_SCORE' }) }
    $rubricPath = Join-Path $fixture 'rubric.json'
    $rubric | ConvertTo-Json -Depth 10 | Set-Content $rubricPath -Encoding utf8
    $phase = Get-Content (Join-Path $framework 'profiles/architect-design.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $phase.targetAgent = 'fixture-architect'
    $phase.participantAgentFile = Join-Path $framework 'agents/simple-business-user.agent.md'
    $phase.generalRubricFile = Join-Path $framework 'profiles/result-quality.json'
    $phase.policy.callLimit = 7
    $phase.policy.interactionPrompt = 'DESIGN_PROFILE_INTERACTION'
    $phasePath = Join-Path $fixture 'phase.json'
    $phase | ConvertTo-Json -Depth 15 | Set-Content $phasePath -Encoding utf8
    $devPhase = Get-Content (Join-Path $framework 'profiles/developer-coding.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $devPhase.targetAgent = 'fixture-developer'
    $devPhasePath = Join-Path $fixture 'dev-phase.json'
    $devPhase | ConvertTo-Json -Depth 15 | Set-Content $devPhasePath -Encoding utf8
    $runsRoot = Join-Path $fixture 'runs'
    $project = @{
        schemaVersion = 1; id = 'fixture-project'; repositoryPath = $source; runsRoot = $runsRoot
        requirementWorkspacePath = 'docs/requirements/req-{caseId}.md'
        designWorkspacePath = 'docs/design/design-{caseId}.md'
        excludePatterns = @('docs/*.simple-knowledge.md')
        runtimeDirectories = @('runtime-state')
    }
    $projectPath = Join-Path $fixture 'project.json'
    $project | ConvertTo-Json -Depth 10 | Set-Content $projectPath -Encoding utf8
    $manifestPath = Join-Path $fixture 'scenario.json'
    $manifest = @{
        schemaVersion = 1; caseId = 'uf01'; projectProfile = $projectPath
        stages = @{
            design = @{
                phaseProfile = $phasePath
                inputFile = $requirement
                rubricFile = $rubricPath
            }
            dev = @{
                phaseProfile = $devPhasePath
                inputFile = $designDoc
                verification = @{ pythonExecutable = 'python'; testPaths = @('tests'); timeoutSeconds = 30 }
            }
        }
    }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
    $savedPath = $env:PATH
    $savedAppData = $env:APPDATA
    $gitDirectory = Split-Path (Get-Command git -CommandType Application).Source
    $cliDirectory = Join-Path $fixture 'path-cli'
    $fakeAppData = Join-Path $fixture 'fake-appdata'
    $pathCli = Join-Path $cliDirectory 'copilot.ps1'
    $bundledCli = Join-Path $fakeAppData 'Code\User\globalStorage\github.copilot-chat\copilotCli\copilot.ps1'
    [void](New-Item -ItemType Directory -Path $cliDirectory, (Split-Path $bundledCli) -Force)
    'exit 0' | Set-Content $pathCli
    'exit 0' | Set-Content $bundledCli
    try {
        $env:PATH = $cliDirectory + [IO.Path]::PathSeparator + $gitDirectory
        $env:APPDATA = $fakeAppData
        $cliPlan = & $runner -ScenarioFile $manifestPath -Stage design
        Assert ($cliPlan.cliPath -ceq $pathCli) 'A supported CLI on PATH takes priority over an editor-bundled CLI.'
        $explicitCli = Join-Path $fixture 'explicit-cli.ps1'
        $cliPlan = & $runner -ScenarioFile $manifestPath -Stage design -CliPath $explicitCli
        Assert ($cliPlan.cliPath -ceq $explicitCli) 'An explicit CLI path takes priority over automatic discovery.'
        $env:PATH = $gitDirectory
        if ($IsWindows) {
            $cliPlan = & $runner -ScenarioFile $manifestPath -Stage design
            Assert ($cliPlan.cliPath -ceq $bundledCli) 'The editor CLI remains a fallback when no supported PATH CLI exists.'
            'exit /b 0' | Set-Content (Join-Path $cliDirectory 'copilot.cmd')
            Remove-Item -LiteralPath $pathCli
            $env:PATH = $cliDirectory + [IO.Path]::PathSeparator + $gitDirectory
            $cliPlan = & $runner -ScenarioFile $manifestPath -Stage design
            Assert ($cliPlan.cliPath -ceq $bundledCli) 'Unsupported cmd wrappers do not hide a usable editor fallback.'
            $env:PATH = $gitDirectory
        }
        $env:APPDATA = $null
        $cliPlan = & $runner -ScenarioFile $manifestPath -Stage design
        Assert ($cliPlan.cliPath -ceq 'copilot' -and -not $cliPlan.modelCallsStarted) 'Preflight works without a CLI or editor environment and does not invent an executable.'
    } finally {
        $env:PATH = $savedPath
        $env:APPDATA = $savedAppData
    }
    $devPlan = & $runner -ScenarioFile $manifestPath -Stage dev -ParticipantModel auto -EvaluatorModel auto
    Assert ($null -eq $devPlan.domainRubricFile -and $null -eq $devPlan.rubricWeights -and
        $null -eq $devPlan.models.participant -and $null -eq $devPlan.models.evaluator -and
        -not $devPlan.modelCallsStarted -and -not (Test-Path $devPlan.runDirectory)) 'Dev preflight needs no participant, evaluator or rubric.'
    $minimalTools = Join-Path $fixture 'minimal-framework\tools'
    [void](New-Item -ItemType Directory -Path $minimalTools -Force)
    foreach ($tool in @('Invoke-SDLC-Eval.ps1', 'RunDirectory.psm1', 'DevExecution.psm1', 'DevDelivery.psm1', 'CapturedProcess.psm1', 'DialoguePolicy.psm1')) {
        Copy-Item (Join-Path $framework "tools\$tool") $minimalTools
    }
    $independentDevPlan = & (Join-Path $minimalTools 'Invoke-SDLC-Eval.ps1') -ScenarioFile $manifestPath -Stage dev
    Assert ($independentDevPlan.stage -eq 'dev' -and -not $independentDevPlan.modelCallsStarted) 'Dev preflight works with no evaluator script, participant agent or rubric files in the framework.'
    $manifest.stages.plan = @{ inputFile = $requirement }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage dev } "*Unsupported scenario stage 'plan'*"
    [void]$manifest.stages.Remove('plan')
    $manifest.stages.dev.rubricFile = 'nonexistent-rubric.json'
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage dev } '*Unknown key: rubricFile*'
    [void]$manifest.stages.dev.Remove('rubricFile')
    $devPhase.participantAgentFile = 'nonexistent-participant.md'
    $devPhase | ConvertTo-Json -Depth 15 | Set-Content $devPhasePath -Encoding utf8
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage dev } '*Unknown key: participantAgentFile*'
    [void]$devPhase.Remove('participantAgentFile')
    $devPhase.policy.callLimit = 2
    $devPhase | ConvertTo-Json -Depth 15 | Set-Content $devPhasePath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage dev } '*exactly one CLI*'
    $devPhase.policy.callLimit = 1
    $devPhase | ConvertTo-Json -Depth 15 | Set-Content $devPhasePath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage plan } '*ValidateSet*'
    $flatPath = Join-Path $fixture 'flat.json'
    @{ schemaVersion = 1; caseId = 'old'; projectProfile = $projectPath; phaseProfile = $phasePath; requirementFile = $requirement; domainRubricFile = $rubricPath } |
        ConvertTo-Json | Set-Content $flatPath
    Assert-Rejected { & $runner -ScenarioFile $flatPath -Stage design } '*Legacy flat scenarios*'
    $phase.stage = 'req'
    $phase | ConvertTo-Json -Depth 15 | Set-Content $phasePath -Encoding utf8
    Assert-Rejected { & $runner -ScenarioFile $manifestPath -Stage design } '*Unsupported phase/project contract*'
    $phase.stage = 'design'
    $phase | ConvertTo-Json -Depth 15 | Set-Content $phasePath -Encoding utf8
    $plan = & $runner -ScenarioFile $manifestPath -Stage design -TargetModels @('fixture-designer') -ParticipantModel 'fixture-participant' -EvaluatorModel 'fixture-evaluator'
    Assert ($plan.participantInput -eq 'same-confirmed-requirement' -and $plan.minimumParticipantReplies -eq 0) 'Shared-input contract failed.'
    Assert ([IO.Path]::GetFileName($plan.runDirectory) -match '^uf01-design-001-\d{8}-fixture-designer-fixture-participant$') 'Automatic sequential run naming failed.'
    Assert ($plan.requirementWorkspacePath -eq 'docs/requirements/req-uf01.md' -and
        $plan.artifactWorkspacePath -eq 'docs/design/design-uf01.md') 'Workspace paths must be derived from project conventions.'
    Assert ($plan.instructionFiles -contains '.github/copilot-instructions.md' -and -not $plan.initialRequest.Contains('PROJECT_RULE_ONLY')) 'Project instructions must be discovered, not injected.'
    Assert (-not (Test-Path $plan.runDirectory) -and -not (Test-Path ($plan.runDirectory + '-inputs'))) 'Default validation must not create a run or call models.'
    $project.designWorkspacePath = '../outside.md'
    $project | ConvertTo-Json -Depth 10 | Set-Content $projectPath -Encoding utf8
    $rejected = $false
    try { & $runner -ScenarioFile $manifestPath -Stage design | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Unsafe output path must be rejected before creating evidence.'
    $project.designWorkspacePath = 'docs/design/design-{caseId}.md'
    $project | ConvertTo-Json -Depth 10 | Set-Content $projectPath -Encoding utf8
    $run = Join-Path $fixture 'run'
    $env:DIALOGUE_DESIGN_FIXTURE = 'shared-requirement'
    & $runner -ScenarioFile $manifestPath -Stage design -Mode Run -RunDirectory $run -TargetModels @('fusion:standard', 'fusion:high') `
        -ParticipantModel 'fixture-participant' -EvaluatorModel 'fixture-evaluator' `
        -CliPath (Join-Path $PSScriptRoot 'fixtures/fake-agent-dialogue.ps1') | Out-Null
    Assert (-not (Test-Path ($run + '-inputs'))) 'No sibling -inputs directory should be created.'
    $inputs = Join-Path $run 'inputs'
    $config = Get-Content (Join-Path $inputs 'dialogue-config.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ((Get-FileHash (Join-Path $inputs 'requirement.md')).Hash -ceq (Get-FileHash $requirement).Hash) 'Participant must receive exactly the confirmed requirement.'
    $devRun = Join-Path $fixture 'dev-run'
    $env:DIALOGUE_DESIGN_FIXTURE = 'dev-coding'
    & $runner -ScenarioFile $manifestPath -Stage dev -Mode Run -RunDirectory $devRun -TargetModels @('hydrafusion', 'fusion:standard', 'fusion:high') `
        -ParticipantModel auto -EvaluatorModel auto -CliPath (Join-Path $PSScriptRoot 'fixtures/fake-agent-dialogue.ps1') | Out-Null
    foreach ($unused in @('participant.agent.md', 'general-rubric.json', 'domain-rubric.json')) {
        Assert (-not (Test-Path (Join-Path $devRun "inputs\$unused"))) "Dev must not freeze unused inputs: $unused"
    }
    $devComparison = Get-Content (Join-Path $devRun 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
    $devCondition = $devComparison.conditions[0]
    $devState = Get-Content (Join-Path $devCondition.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($devState.outcome -eq 'stage_completed' -and $devState.calls -eq 1 -and -not $devState.ContainsKey('participantReplies') -and
        'gpt-6.1-sol' -in $devState.observedModels -and
        'claude-opus-5.5' -in $devState.observedModels -and
        $devState.fusionPhases.Count -eq 3 -and $devState.verification.passed) 'Dev independent HydraFusion execution failed.'
    $devSummaryText = Get-Content (Join-Path $devCondition.runDirectory 'summary.md') -Raw
    Assert ($devSummaryText.Contains('primary:gpt-6.1-sol') -and $devSummaryText.Contains('judge:claude-opus-5.5')) 'Dev summary must list concrete HydraFusion phase models.'
    Assert (@(Get-ChildItem $devRun -Directory -Filter 'evaluation-*').Count -eq 0) 'Dev must not invoke a model evaluator.'
    Assert (-not (Test-Path (Join-Path (Split-Path $devCondition.configFile) 'dialogue'))) 'Dev must not use the dialogue controller.'
    Assert (-not (Test-Path (Join-Path $inputs 'principles.md')) -and -not (Test-Path (Join-Path $inputs 'knowledge.md'))) 'No extra business principles or knowledge file should be generated.'
    Assert ($devComparison.conditions.Count -eq 3) 'Legacy, Standard and High must remain independent conditions.'
    foreach ($index in 1..2) {
        $directory = $devComparison.conditions[$index].runDirectory
        $report = Get-Content (Join-Path $directory 'report.json') -Raw | ConvertFrom-Json -AsHashtable
        $tier = if ($index -eq 1) { 'standard' } else { 'high' }
        $routing = if ($index -eq 1) { 'balance' } else { 'hydrafusion' }
        Assert ($report.model -eq "fusion:$tier" -and $report.outcome -eq 'stage_completed' -and
            $report.requestedFusionTier -eq $tier -and $report.requestedAutoTier -eq $routing -and
            $report.effectiveCliModel -eq 'auto') "Fusion $tier request, routing and independent tests must be reported."
        Assert ($report.fusionPhases.Count -eq $(if ($index -eq 1) { 0 } else { 3 })) 'Standard single-model and High multi-phase evidence must both be supported.'
    }
    $comparison = Get-Content (Join-Path $run 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($comparison.conditions.Count -eq 2) 'Design Fusion tiers must remain independent conditions.'
    foreach ($fusionCondition in $comparison.conditions) {
        $fusionState = Get-Content (Join-Path $fusionCondition.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($fusionState.outcome -eq 'stage_completed') 'Design must accept routed concrete models for either Fusion tier.'
    }
    $condition = $comparison.conditions[0]
    $state = Get-Content (Join-Path $condition.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    $conditionConfig = Get-Content $condition.configFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($config.policy.callLimit -eq 7 -and $conditionConfig.policy.callLimit -eq 7 -and
        $state.policy.callLimit -eq 7 -and $state.policy.interactionPrompt -ceq 'DESIGN_PROFILE_INTERACTION' -and
        ($config.availableTools -join ',') -ceq ($phase.availableTools -join ',')) 'Design policy and tools must flow from its phase Profile to the running controller.'
    Assert ($state.outcome -eq 'stage_completed' -and $state.participantReplies -eq 1 -and $state.pending.Count -eq 0) 'On-demand clarification should complete with one shared-input answer.'
    $evaluationRoot = Get-ChildItem $run -Directory -Filter 'evaluation-*' | Select-Object -First 1
    $evaluation = Get-Content (Join-Path $evaluationRoot.FullName 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($evaluation.evaluatorModel -eq 'fixture-evaluator' -and $evaluation.results[0].status -eq 'completed' -and
        $evaluation.rubricWeights.general -eq 30 -and $evaluation.rubricWeights.domain -eq 70 -and
        $evaluation.results[0].targetAiCredits -eq '0.00') 'Explicit evaluator model, 30:70 rubric weights, and AI credit extraction failed.'
    $evalSummaryMd = Get-Content (Join-Path $evaluationRoot.FullName 'summary.md') -Raw
    $evalCaseMd = Get-Content (Join-Path (Join-Path $evaluationRoot.FullName $condition.name) 'evaluation.md') -Raw
    Assert ($evalSummaryMd.Contains('| AI credit |') -and $evalCaseMd.Contains('被评估 Agent 消耗 AI credit：0.00') -and
        $evalCaseMd.Contains('评分权重比例：通用 30% + 领域 70%')) 'Evaluation markdown must include AI credits and 30:70 rubric weights.'
    $evaluationInput = Get-Content (Join-Path (Join-Path $evaluationRoot.FullName $condition.name) 'evaluation-input.txt') -Raw
    $package = [regex]::Match($evaluationInput, '(?ms)^BEGIN_EVALUATION_PACKAGE\r?\n(.*)\r?\nEND_EVALUATION_PACKAGE\s*$').Groups[1].Value | ConvertFrom-Json -AsHashtable
    Assert ($package.referenceDocuments.Count -eq 2 -and $package.referenceDocuments[0].content.Contains('SHARED_CONFIRMED_REQUIREMENT')) 'Evaluator must receive separate requirement and discovered project instruction references.'
    Assert ($package.rubrics[1].criteria[0].description -ceq 'PRIVATE_DOMAIN_SCORE') 'Scenario rubric must remain unchanged.'
    Assert (-not $evaluationInput.Contains('EXCLUDED_PRIVATE_INPUT')) 'Excluded project knowledge must not leak to evaluation.'
    "---`nname: SDLCRole_PM`n---`nProduce a requirement draft, not human approval." |
        Set-Content (Join-Path $source '.github\agents\SDLCRole_PM.agent.md')
    'Project contract. Human approval remains pending.' | Set-Content (Join-Path $source 'docs\contract.md')
    $project.projectContractPath = 'docs/contract.md'
    $project | ConvertTo-Json -Depth 10 | Set-Content $projectPath
    $knowledge = Join-Path $fixture 'private-knowledge.md'
    "## 初始需求`nClarify this feature.`n## Private knowledge`nPRIVATE_REQ_KNOWLEDGE" | Set-Content $knowledge
    $pmProfile = Get-Content (Join-Path $framework 'profiles\pm-clarification.json') -Raw | ConvertFrom-Json -AsHashtable
    $pmProfile.participantAgentFile = Join-Path $framework 'agents\simple-business-user.agent.md'
    $pmProfile.generalRubricFile = Join-Path $framework 'profiles\result-quality.json'
    $pmProfile.availableTools = @('view', 'glob', 'apply_patch')
    $pmProfile.policy.callLimit = 7
    $pmProfile.policy.interactionPrompt = 'REQ_PROFILE_INTERACTION'
    $pmProfilePath = Join-Path $fixture 'pm-phase.json'
    $pmProfile | ConvertTo-Json -Depth 15 | Set-Content $pmProfilePath
    $manifest.stages.req = @{ phaseProfile = $pmProfilePath; inputFile = $knowledge; rubricFile = $rubricPath }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath
    $reqRun = Join-Path $fixture 'req-run'
    $env:DIALOGUE_DESIGN_FIXTURE = 'req-sdlc'
    $headlessDirectory = Join-Path $fixture 'headless-cli'
    $headlessCli = Join-Path $headlessDirectory 'copilot.ps1'
    [void](New-Item -ItemType Directory -Path $headlessDirectory)
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\fake-agent-dialogue.ps1') $headlessCli
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\fake-result-evaluator.ps1') $headlessDirectory
    $savedPath = $env:PATH
    $savedAppData = $env:APPDATA
    try {
        $env:PATH = $headlessDirectory + [IO.Path]::PathSeparator + $savedPath
        $env:APPDATA = $null
        & $runner -ScenarioFile $manifestPath -Stage req -Mode Run -RunDirectory $reqRun -TargetModels 'fusion:standard' `
            -ParticipantModel 'fixture-participant' -EvaluatorModel 'fixture-evaluator' | Out-Null
    } finally {
        $env:PATH = $savedPath
        $env:APPDATA = $savedAppData
    }
    $reqComparison = Get-Content (Join-Path $reqRun 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
    $reqResult = Get-Content (Join-Path $reqComparison.conditions[0].runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    $reqConfig = Get-Content (Join-Path $reqRun 'inputs\dialogue-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $reqConditionConfig = Get-Content $reqComparison.conditions[0].configFile -Raw | ConvertFrom-Json -AsHashtable
    $reqManifest = Get-Content (Join-Path $reqRun 'inputs\manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($reqManifest.cliPath -ceq $headlessCli) 'A full Req run must use the PATH CLI without an editor environment.'
    Assert ($reqResult.outcome -eq 'stage_completed' -and $reqResult.participantReplies -eq 2 -and
        $reqConfig.targetAgent -eq 'SDLCRole_PM' -and 'docs/contract.md' -in $reqConfig.protectedWorkspacePaths) "New PM must complete a private-knowledge dialogue with protected contract and two simulated answers: $($reqResult.outcome), replies=$($reqResult.participantReplies), error=$($reqResult['error'])"
    Assert ($reqConfig.policy.callLimit -eq 7 -and $reqConditionConfig.policy.callLimit -eq 7 -and
        $reqResult.policy.callLimit -eq 7 -and $reqResult.policy.interactionPrompt -ceq 'REQ_PROFILE_INTERACTION' -and
        ($reqConfig.availableTools -join ',') -ceq ($pmProfile.availableTools -join ',')) 'Req policy and tools must come from its phase Profile, not a business template or controller defaults.'
    $firstCapture = $reqResult.turns[0].capturePath
    $firstPrompt = Get-Content (Join-Path $firstCapture 'input.txt') -Raw
    $firstCommand = (Get-Content (Join-Path $firstCapture 'turn.json') -Raw | ConvertFrom-Json -AsHashtable).command.arguments
    $toolsIndex = [array]::IndexOf($firstCommand, '--available-tools')
    Assert ($reqConfig.initialRequest -ceq 'Clarify this feature.' -and
        $reqConditionConfig.initialRequest -ceq $reqConfig.initialRequest -and
        $reqResult.turns[0].input -ceq $reqConfig.initialRequest -and
        $firstPrompt.Contains($reqConfig.initialRequest) -and -not $firstPrompt.Contains('PRIVATE_REQ_KNOWLEDGE')) 'The first PM prompt contains only the initial request from scenario knowledge, not private answers.'
    Assert ($toolsIndex -ge 0 -and
        ($firstCommand[($toolsIndex + 1)..($toolsIndex + $pmProfile.availableTools.Count)] -join ',') -ceq ($pmProfile.availableTools -join ',') -and
        $firstCommand -contains '--allow-tool' -and $firstCommand -contains '--deny-tool') 'The capture receives the selected Profile tool permissions.'
    $reqEvaluationRoot = Get-ChildItem $reqRun -Directory -Filter 'evaluation-*' | Select-Object -First 1
    $reqEvaluation = Get-Content (Join-Path $reqEvaluationRoot.FullName 'evaluation.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($reqEvaluation.results[0].status -eq 'completed') 'The new PM draft must reach independent evaluation.'
    $pmProfile.policy.callLimit = 4
    $pmProfile | ConvertTo-Json -Depth 15 | Set-Content $pmProfilePath
    $limitedRun = Join-Path $fixture 'req-limited'
    & $runner -ScenarioFile $manifestPath -Stage req -Mode Run -DialogueOnly -RunDirectory $limitedRun -TargetModels 'fusion:standard' `
        -ParticipantModel 'fixture-participant' -EvaluatorModel 'fixture-evaluator' `
        -CliPath (Join-Path $PSScriptRoot 'fixtures\fake-agent-dialogue.ps1') | Out-Null
    $limitedComparison = Get-Content (Join-Path $limitedRun 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
    $limitedResult = Get-Content (Join-Path $limitedComparison.conditions[0].runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($limitedResult.policy.callLimit -eq 4 -and $limitedResult.calls -eq 4 -and
        $limitedResult.outcome -eq 'budget_exceeded') 'A phase Profile call limit must stop actual dialogue calls at the configured threshold.'
    $pmProfile.policy.callLimit = 7
    $pmProfile | ConvertTo-Json -Depth 15 | Set-Content $pmProfilePath
    $env:DIALOGUE_DESIGN_FIXTURE = 'req-sdlc-tamper'
    $tamperRun = Join-Path $fixture 'req-contract-tamper'
    & $runner -ScenarioFile $manifestPath -Stage req -Mode Run -DialogueOnly -RunDirectory $tamperRun -TargetModels 'fusion:standard' `
        -ParticipantModel 'fixture-participant' -EvaluatorModel 'fixture-evaluator' `
        -CliPath (Join-Path $PSScriptRoot 'fixtures\fake-agent-dialogue.ps1') | Out-Null
    $tamperComparison = Get-Content (Join-Path $tamperRun 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
    $tamperResult = Get-Content (Join-Path $tamperComparison.conditions[0].runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($tamperResult.outcome -eq 'failed' -and $tamperResult.calls -eq 1 -and
        $tamperResult.error.Contains('Protected workspace input changed')) 'Contract tampering must stop Req immediately without dispatching Participant.'
    [void]$manifest.stages.req.Remove('phaseProfile')
    foreach ($caseId in @('sample-one', 'sample-two')) {
        $manifest.caseId = $caseId
        $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath
        $pmPlan = & $runner -ScenarioFile $manifestPath -Stage req
        Assert ($pmPlan.stage -eq 'req' -and $pmPlan.targetAgent -eq 'SDLCRole_PM' -and
            $pmPlan.participantInput -eq 'private-knowledge' -and $pmPlan.minimumParticipantReplies -eq 2 -and
            $pmPlan.layers.infrastructurePhaseProfile -ceq (Join-Path $framework 'profiles\pm-clarification.json') -and
            -not [string]::IsNullOrWhiteSpace($pmPlan.initialRequest)) "Unified req layered scenario validation failed: $caseId"
    }
    $designPlan = & $runner -ScenarioFile $manifestPath -Stage design
    Assert ($designPlan.stage -eq 'design' -and $designPlan.targetAgent -eq 'fixture-architect' -and
        $designPlan.participantInput -eq 'same-confirmed-requirement' -and $designPlan.minimumParticipantReplies -eq 0) 'Synthetic design stage validation failed.'
    "---`nname: SDLCRole_Architect`n---`nProduce a design draft." |
        Set-Content (Join-Path $source '.github\agents\SDLCRole_Architect.agent.md')
    [void]$manifest.stages.design.Remove('phaseProfile')
    $manifest | ConvertTo-Json -Depth 12 | Set-Content $manifestPath
    $defaultDesignPlan = & $runner -ScenarioFile $manifestPath -Stage design
    Assert ($defaultDesignPlan.targetAgent -eq 'SDLCRole_Architect' -and
        $defaultDesignPlan.layers.infrastructurePhaseProfile -ceq (Join-Path $framework 'profiles\architect-design.json')) 'Design uses its framework Profile when the scenario does not override it.'
    $devPlan = & $runner -ScenarioFile $manifestPath -Stage dev -TargetModels 'auto, hydrafusion'
    Assert ($devPlan.executor -eq 'single-shot-dev-v1' -and $null -eq $devPlan.models.evaluator -and
        -not $devPlan.initialRequest.Contains('DIALOGUE_CONTROL')) 'Dev plan must use independent execution and test-based evaluation.'
    Assert ($devPlan.stage -eq 'dev' -and $devPlan.targetAgent -eq 'fixture-developer' -and
        $devPlan.participantInput -eq 'none' -and $null -eq $devPlan.models.participant -and
        $devPlan.models.target.Count -eq 2 -and $devPlan.models.target[1] -eq 'hydrafusion' -and
        $devPlan.designWorkspacePath -eq 'docs/design/design-sample-two.md' -and
        $devPlan.requirementWorkspacePath -eq 'docs/requirements/req-sample-two.md' -and
        [IO.Path]::GetFileName($devPlan.runDirectory) -match '^sample-two-dev-\d{3}-\d{8}-auto-hydrafusion$') 'Synthetic dev stage validation failed.'
    Assert ($pmPlan.projectContractPath -in $pmPlan.instructionFiles -and $devPlan.initialRequest.Contains('维护并运行受影响前端单元测试')) 'New roles must discover a protected contract and retain frontend unit-test responsibility.'
    $exampleRoot = Join-Path $fixture 'example-config'
    Copy-Item -LiteralPath (Join-Path $framework 'examples') -Destination $exampleRoot -Recurse
    $exampleProjectPath = Join-Path $exampleRoot 'project.json'
    $exampleProject = Get-Content $exampleProjectPath -Raw | ConvertFrom-Json -AsHashtable
    $exampleProject.repositoryPath = '../product'
    $exampleProject.runsRoot = '../example-runs'
    $exampleProject | ConvertTo-Json -Depth 8 | Set-Content $exampleProjectPath
    $examplePlan = & $runner -ScenarioFile (Join-Path $exampleRoot 'scenario.json') -Stage req
    Assert ($examplePlan.caseId -eq 'sample' -and $examplePlan.targetAgent -eq 'SDLCRole_PM' -and
        -not (Test-Path (Join-Path $fixture 'example-runs'))) 'Published examples preflight outside the framework using relative paths and create no runtime artifacts.'
    Write-Output 'PASS: synthetic multi-stage scenarios, external examples, SDLCRole defaults and contract, 30:70 rubric weights, AI credit reporting, hydrafusion, fake-CLI end-to-end'
} finally {
    $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = $savedAutoload
    $env:DIALOGUE_DESIGN_FIXTURE = $savedFixture
    if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
}