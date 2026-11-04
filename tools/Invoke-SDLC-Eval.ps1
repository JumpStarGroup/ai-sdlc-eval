#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('ManifestFile')][string]$ScenarioFile,
    [ValidateSet('req', 'design', 'dev', 'test')][string]$Stage,
    [ValidateSet('ValidateOnly', 'Validate', 'Run')][string]$Mode = 'ValidateOnly',
    [string[]]$TargetModels = @('gpt-6-luna'),
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')][string]$ReasoningEffort,
    [string]$ParticipantModel = 'gpt-6.1-sol',
    [string]$EvaluatorModel = 'gpt-6.1-sol',
    [switch]$DialogueOnly,
    [string]$RunDirectory,
    [string]$RunsRoot,
    [string]$RunLabel,
    [string]$CliPath,
    [switch]$WithTest,
    [string]$DevRunDirectory,
    [string[]]$DevConditions = @(),
    [string[]]$TestModels = @('gpt-6.1-sol'),
    [string]$TestRunDirectory,
    [string]$TestProfileFile = (Join-Path $PSScriptRoot '..\profiles\backend-testing.json'),
    [switch]$UseGitHubCliAuth
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RunDirectory.psm1') -Force
if ($PSBoundParameters.ContainsKey('ReasoningEffort') -and $Stage -cne 'dev') {
    throw '-ReasoningEffort requires explicit -Stage dev; it is not applied to Participant, Evaluator or Test.'
}

$effectiveUseGitHubCliAuth = if ($PSBoundParameters.ContainsKey('UseGitHubCliAuth')) {
    [bool]$UseGitHubCliAuth
} else {
    $true
}
if ([string]::IsNullOrWhiteSpace($CliPath)) {
    $command = Get-Command 'copilot' -CommandType ExternalScript, Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and [IO.Path]::GetExtension($_.Source) -notin @('.cmd', '.bat') } |
        Select-Object -First 1
    if ($command) {
        $CliPath = $command.Source
    } elseif ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $vsCodeCopilotCli = Join-Path $env:APPDATA 'Code\User\globalStorage\github.copilot-chat\copilotCli\copilot.ps1'
        if (Test-Path -LiteralPath $vsCodeCopilotCli -PathType Leaf) { $CliPath = $vsCodeCopilotCli }
    }
    if ([string]::IsNullOrWhiteSpace($CliPath)) { $CliPath = 'copilot' }
}

$defaultStageProfiles = @{
    req = (Join-Path $PSScriptRoot '../profiles/pm-clarification.json')
    design = (Join-Path $PSScriptRoot '../profiles/architect-design.json')
    dev = (Join-Path $PSScriptRoot '../profiles/developer-coding.json')
}

function Read-ScenarioJson([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}
function Resolve-ScenarioPath([string]$Value, [string]$Base) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Expected a configured path.' }
    [IO.Path]::GetFullPath($Value, $Base)
}
function Assert-ScenarioKeys($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [System.Collections.IDictionary]) { throw 'Expected a JSON object.' }
    foreach ($key in $Required) { if (-not $Value.Contains($key)) { throw "Missing key: $key" } }
    $allowed = @($Required) + @($Optional)
    foreach ($key in $Value.Keys) { if ($key -cnotin $allowed) { throw "Unknown key: $key" } }
}
function Assert-ScenarioNoLinks([string]$Path) {
    $ancestor = $Path
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked path: $ancestor"
        }
        $ancestor = Split-Path $ancestor -Parent
    }
}
function Assert-ScenarioRelative([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains(':') -or
        @($Path.Replace('\', '/').Split('/') | Where-Object { $_ -in @('..', '.git', '') }).Count) {
        throw "Expected a safe workspace-relative path: $Path"
    }
}
function Get-ShortModelLabel([string]$ModelName) {
    if ($ModelName -match '^gpt-(?<major>\d+)\.(?<minor>\d+)-(?<label>[a-z0-9-]+)$') {
        return ('{0}{1}{2}' -f $Matches['label'], $Matches['major'], $Matches['minor']).ToLowerInvariant()
    }
    if ($ModelName -match '^mai-code-\d+(?:\.\d+)?-(?<label>[a-z0-9-]+)$') {
        return $Matches['label'].ToLowerInvariant()
    }
    if ($ModelName -imatch '^auto:(?<tier>[a-z0-9_-]+)$') {
        return ('auto-' + $Matches['tier'].ToLowerInvariant()) -replace '[^a-z0-9-]', '-'
    }
    $short = $ModelName.ToLowerInvariant() -replace '^gpt-\d+(?:\.\d+)?-', ''
    $short = ($short -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $short) { throw "Invalid model label: $ModelName" }
    return $short
}

$manifestPath = (Resolve-Path -LiteralPath $ScenarioFile).Path
$manifest = Read-ScenarioJson $manifestPath
if ($manifest -isnot [System.Collections.IDictionary] -or $manifest['schemaVersion'] -ne 1 -or
    $manifest['caseId'] -isnot [string] -or $manifest.caseId -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
    throw 'Invalid scenario schema or ID.'
}
if (-not $manifest.Contains('stages')) {
    throw "Legacy flat scenarios are not supported. Use schemaVersion 1 with projectProfile and stages; see README.md."
}
Assert-ScenarioKeys $manifest @('schemaVersion', 'caseId', 'projectProfile', 'stages')
if ($manifest.stages -isnot [System.Collections.IDictionary]) { throw 'Scenario stages must be an object.' }
foreach ($stageName in $manifest.stages.Keys) {
    if ($stageName -cnotin @('req', 'design', 'dev')) {
        throw "Unsupported scenario stage '$stageName'. Configure req/design/dev; test consumes -DevRunDirectory."
    }
}
$manifestRoot = Split-Path $manifestPath
$projectPath = Resolve-ScenarioPath $manifest['projectProfile'] $manifestRoot
$project = Read-ScenarioJson $projectPath
Assert-ScenarioKeys $project @('schemaVersion', 'id', 'repositoryPath', 'runsRoot', 'requirementWorkspacePath', 'designWorkspacePath', 'excludePatterns') @('runtimeDirectories', 'projectContractPath', 'reportWorkspacePath')

if ($WithTest -and $Stage -ne 'dev') { throw '-WithTest requires -Stage dev.' }
if ($Stage -eq 'test') {
    if (-not $DevRunDirectory) { throw '-Stage test requires -DevRunDirectory.' }
    $devInput = Read-ScenarioJson (Join-Path $DevRunDirectory 'input-manifest.json')
    if ($devInput.caseId -cne $manifest.caseId) { throw 'Test scenario does not match the source Dev case.' }
    & (Join-Path $PSScriptRoot 'Invoke-TestRun.ps1') -DevRunDirectory $DevRunDirectory -DevConditions $DevConditions `
        -TestModels $TestModels -RunDirectory $RunDirectory -Mode $Mode -CliPath $CliPath `
        -ProfileFile $TestProfileFile -ProjectFile $projectPath -UseGitHubCliAuth:$effectiveUseGitHubCliAuth
    return
}
if ($DevRunDirectory -or $DevConditions.Count) { throw 'DevRunDirectory and DevConditions are only valid for -Stage test.' }
if ($WithTest) {
    Import-Module (Join-Path $PSScriptRoot 'DevDelivery.psm1') -Force
    $resolvedTestProfile = Read-BackendTestProfile $TestProfileFile (Resolve-ScenarioPath $project.repositoryPath (Split-Path $projectPath)) $project
    $testProfile = $resolvedTestProfile.profile
    $TestModels = @($TestModels | ForEach-Object { $_ -split '[,，]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $TestModels.Count) { throw 'Specify at least one Test model.' }
    foreach ($model in $TestModels) {
        if ($model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$' -or ($model -imatch '^fusion:' -and $model -inotmatch '^fusion:(standard|high|max)$')) {
            throw "Invalid Test model: $model"
        }
    }
}
if (-not $manifest.stages.Count) { throw 'Scenario stages must be a nonempty object.' }
$selectedStage = if (-not [string]::IsNullOrWhiteSpace($Stage)) {
    $Stage.ToLowerInvariant()
} elseif ($manifest.stages.Count -eq 1) {
    @($manifest.stages.Keys)[0].ToLowerInvariant()
} else {
    throw "Scenario defines multiple stages ($(@($manifest.stages.Keys) -join ', ')); specify -Stage <req|design|dev>."
}
if (-not $manifest.stages.Contains($selectedStage)) {
    throw "Stage '$selectedStage' is not defined in $ScenarioFile. Available: $(@($manifest.stages.Keys) -join ', ')."
}
$stageConfig = $manifest.stages[$selectedStage]
if ($stageConfig -isnot [System.Collections.IDictionary]) { throw "Stage '$selectedStage' must be an object." }
if ($selectedStage -eq 'dev') {
    Assert-ScenarioKeys $stageConfig @('inputFile') @('phaseProfile', 'verification')
} else {
    Assert-ScenarioKeys $stageConfig @('inputFile', 'rubricFile') @('phaseProfile')
}
$phasePath = if ($stageConfig.Contains('phaseProfile')) {
    Resolve-ScenarioPath $stageConfig.phaseProfile $manifestRoot
} elseif ($defaultStageProfiles.ContainsKey($selectedStage)) {
    [IO.Path]::GetFullPath($defaultStageProfiles[$selectedStage])
} else {
    throw "No default phase profile mapped for stage '$selectedStage'."
}
$phase = Read-ScenarioJson $phasePath
if ($phase.schemaVersion -ne 1 -or $project.schemaVersion -ne 1 -or $phase.stage -cne $selectedStage) {
    throw 'Unsupported phase/project contract.'
}
$isDevPhase = $selectedStage -ceq 'dev'
$isDesignPhase = $selectedStage -ceq 'design'
if ($isDevPhase) {
    Assert-ScenarioKeys $phase @('schemaVersion', 'id', 'version', 'stage', 'targetAgent', 'executionMode',
        'initialRequestTemplate', 'availableTools', 'allowTools', 'denyTools', 'policy')
} elseif ($isDesignPhase) {
    Assert-ScenarioKeys $phase @('schemaVersion', 'id', 'version', 'stage', 'targetAgent', 'participantAgentFile', 'generalRubricFile',
        'participantInput', 'participantContextLabel', 'initialRequestTemplate', 'availableTools', 'allowTools', 'denyTools', 'policy') @('rubricWeights')
    if ($phase.participantInput -cne 'confirmed-requirement') { throw 'Design requires confirmed-requirement participantInput.' }
} else {
    Assert-ScenarioKeys $phase @('schemaVersion', 'id', 'version', 'stage', 'targetAgent', 'participantAgentFile', 'generalRubricFile',
        'participantInput', 'participantContextLabel', 'initialRequestSource', 'availableTools', 'allowTools', 'denyTools', 'policy') @('rubricWeights')
    if ($phase.initialRequestSource -cne 'knowledge-heading') { throw 'Unsupported initialRequestSource.' }
    if ($phase.participantInput -cne 'private-knowledge') { throw 'Req requires private-knowledge participantInput.' }
}
$scenarioInputFile = Resolve-ScenarioPath $stageConfig.inputFile $manifestRoot
$referenceRequirementFile = if ($isDevPhase) {
    if ($manifest.stages.Contains('design') -and $manifest.stages.design -is [System.Collections.IDictionary] -and $manifest.stages.design.Contains('inputFile')) {
        Resolve-ScenarioPath $manifest.stages.design.inputFile $manifestRoot
    } else {
        throw "Dev stage requires 'design.inputFile' in $ScenarioFile as the confirmed requirement reference."
    }
} else {
    $null
}
$rubric = if (-not $isDevPhase) { Resolve-ScenarioPath $stageConfig.rubricFile $manifestRoot } else { $null }
$TargetModels = @(
    $TargetModels |
        ForEach-Object { if ($null -ne $_) { $_ -split '[,，]' } } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if (-not $TargetModels.Count) { throw 'Specify at least one target model.' }
if (-not $isDevPhase) {
    foreach ($fixedModel in @($ParticipantModel, $EvaluatorModel)) {
        if ([string]::IsNullOrWhiteSpace($fixedModel) -or $fixedModel -imatch '^(auto(?::.*)?|fusion(?::.*)?|hydrafusion(?:-max)?)$') { throw 'Participant and evaluator models must be explicit.' }
    }
}
if ($phase.targetAgent -cnotmatch '^[\w-]+$') { throw 'Invalid target Agent.' }
$projectRoot = Split-Path $projectPath
$source = (Resolve-Path -LiteralPath (Resolve-ScenarioPath $project.repositoryPath $projectRoot)).Path
$devVerification = $null
if ($isDevPhase) {
    Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'DevDelivery.psm1') -Force
    if ($phase['executionMode'] -cne 'single-shot-dev' -or $phase.stage -cne 'dev') { throw 'Dev requires the single-shot-dev profile.' }
    $devVerification = if ($stageConfig.Contains('verification')) { $stageConfig.verification.Clone() } else {
        @{ pythonExecutable = '.venv\Scripts\python.exe'; testPaths = @('tests'); timeoutSeconds = 300 }
    }
    Assert-ScenarioKeys $devVerification @('pythonExecutable', 'testPaths', 'timeoutSeconds') @('acceptanceDirectory')
    if ($devVerification.pythonExecutable -isnot [string] -or [string]::IsNullOrWhiteSpace($devVerification.pythonExecutable) -or
        $devVerification.testPaths -isnot [array] -or -not $devVerification.testPaths.Count -or
        ($devVerification.timeoutSeconds -isnot [int] -and $devVerification.timeoutSeconds -isnot [long]) -or
        $devVerification.timeoutSeconds -lt 1 -or $devVerification.timeoutSeconds -gt 86400) { throw 'Invalid Dev Python verification contract.' }
    foreach ($relative in $devVerification.testPaths) {
        Assert-DevRelativePath $relative
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) { throw "Missing regression tests: $relative" }
        Assert-ScenarioNoLinks (Join-Path $source $relative)
    }
    if ($devVerification.pythonExecutable -match '[/\\]') {
        Assert-DevRelativePath $devVerification.pythonExecutable
        $pythonPath = Join-Path $source $devVerification.pythonExecutable
        if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { throw "Missing Dev interpreter: $pythonPath" }
        Assert-ScenarioNoLinks $pythonPath
    } else { [void](Get-Command $devVerification.pythonExecutable -ErrorAction Stop) }
    if ($devVerification.Contains('acceptanceDirectory')) {
        $devVerification.acceptanceDirectory = Resolve-ScenarioPath $devVerification.acceptanceDirectory $manifestRoot
        if (-not (Test-Path -LiteralPath $devVerification.acceptanceDirectory -PathType Container)) { throw 'Missing trusted acceptance directory.' }
        Assert-ScenarioNoLinks $devVerification.acceptanceDirectory
    }
    if ($project.Contains('runtimeDirectories')) {
        if ($project.runtimeDirectories -isnot [array]) { throw 'runtimeDirectories must be an array.' }
        foreach ($relative in $project.runtimeDirectories) {
            Assert-DevRelativePath $relative
            if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Container)) { throw "Missing runtime directory: $relative" }
            Assert-ScenarioNoLinks (Join-Path $source $relative)
        }
    }
}
$participant = $null; $generalRubric = $null
if (-not $isDevPhase) {
    $participant = Resolve-ScenarioPath $phase.participantAgentFile (Split-Path $phasePath)
    $generalRubric = Resolve-ScenarioPath $phase.generalRubricFile (Split-Path $phasePath)
}
$agentRelative = ".github/agents/$($phase.targetAgent).agent.md"
$agent = Join-Path $source $agentRelative
$checkedInputPaths = @($manifestPath, $phasePath, $projectPath, $scenarioInputFile, $agent)
if (-not $isDevPhase) { $checkedInputPaths += @($rubric, $participant, $generalRubric) }
if ($project['projectContractPath']) {
    Assert-ScenarioRelative $project.projectContractPath
    $checkedInputPaths += Join-Path $source $project.projectContractPath
}
if ($isDevPhase -and $referenceRequirementFile) { $checkedInputPaths += $referenceRequirementFile }
foreach ($path in $checkedInputPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing input: $path" }
    Assert-ScenarioNoLinks $path
}
if ((Get-Item $scenarioInputFile).Length -eq 0) { throw 'Scenario input file cannot be empty.' }
if ($isDevPhase -and (Get-Item $referenceRequirementFile).Length -eq 0) { throw 'Reference requirement file cannot be empty.' }
$caseSlug = $manifest.caseId.ToLowerInvariant()
$requirementWorkspacePath = $project.requirementWorkspacePath.Replace('{caseId}', $caseSlug)
$designWorkspacePath = $project.designWorkspacePath.Replace('{caseId}', $caseSlug)
$artifactWorkspacePath = if ($isDevPhase) {
    'workspace:code-and-tests'
} elseif ($isDesignPhase) {
    $designWorkspacePath
} else {
    $requirementWorkspacePath
}
Assert-ScenarioRelative $requirementWorkspacePath
Assert-ScenarioRelative $designWorkspacePath
if (-not $isDevPhase) { Assert-ScenarioRelative $artifactWorkspacePath }
if ($isDesignPhase -and ($requirementWorkspacePath.Replace('\', '/') -ieq $artifactWorkspacePath.Replace('\', '/'))) {
    throw 'Requirement and output paths must differ.'
}
$effectiveRunsRoot = if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    Resolve-ScenarioPath $project.runsRoot $projectRoot
} else {
    [IO.Path]::GetFullPath($RunsRoot)
}
if ([string]::IsNullOrWhiteSpace($RunLabel)) {
    $targetPart = (@($TargetModels | ForEach-Object { Get-ShortModelLabel $_ }) -join '-')
    $RunLabel = if ($isDevPhase) {
        $targetPart
    } else {
        '{0}-{1}' -f $targetPart, (Get-ShortModelLabel $ParticipantModel)
    }
}
$root = if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
    Get-DialogueRunDirectory -RunsRoot $effectiveRunsRoot -CaseId $manifest.caseId -Stage $phase.stage -RunLabel $RunLabel
} else {
    Resolve-ScenarioPath $RunDirectory $manifestRoot
}
if (Test-Path $root) { throw 'Use a fresh run directory.' }
Assert-ScenarioNoLinks $root
if ($WithTest) {
    $resolvedTestRoot = if ($TestRunDirectory) { [IO.Path]::GetFullPath($TestRunDirectory) } else { $root + '-test' }
    if (Test-Path -LiteralPath $resolvedTestRoot) { throw 'Use a fresh Test run directory.' }
    Assert-DeliveryOutput $resolvedTestRoot $root
    foreach ($protected in @($source, (Split-Path $PSScriptRoot))) { Assert-DeliveryOutput $resolvedTestRoot $protected }
}
foreach ($protected in @($source, (Split-Path $PSScriptRoot))) {
    $prefix = [IO.Path]::GetFullPath($protected).TrimEnd('\', '/')
    if ($root.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must be outside source repositories.' }
}
$ancestor = $root
while ($ancestor) {
    if (Test-Path (Join-Path $ancestor '.git')) { throw 'Evidence cannot be inside Git.' }
    $ancestor = Split-Path $ancestor -Parent
}
$policyKeys = if ($isDevPhase) { @('callLimit', 'timeoutSeconds', 'disableBuiltinMcps') } else {
    @('callLimit', 'allowPendingDraft', 'disableBuiltinMcps', 'skipIssueRegistration', 'requireArtifact',
    'maxCoordinatorPrompts', 'maxIdenticalReplies', 'timeoutSeconds', 'maxPathRecoveryPrompts', 'minimumParticipantReplies',
    'interactionPrompt', 'artifactDescription', 'coordinatorPrompt')
}
Assert-ScenarioKeys $phase.policy $policyKeys
foreach ($key in $(if ($isDevPhase) { @('disableBuiltinMcps') } else { @('allowPendingDraft', 'requireArtifact', 'disableBuiltinMcps', 'skipIssueRegistration') })) {
    if ($phase.policy[$key] -isnot [bool]) { throw "Expected boolean policy: $key" }
}
foreach ($key in $(if ($isDevPhase) { @('callLimit', 'timeoutSeconds') } else { @('callLimit', 'timeoutSeconds', 'maxCoordinatorPrompts', 'maxIdenticalReplies', 'minimumParticipantReplies', 'maxPathRecoveryPrompts') })) {
    $minimum = if ($key -in @('maxCoordinatorPrompts', 'minimumParticipantReplies', 'maxPathRecoveryPrompts')) { 0 } else { 1 }
    if (($phase.policy[$key] -isnot [int] -and $phase.policy[$key] -isnot [long]) -or
        $phase.policy[$key] -lt $minimum -or $phase.policy[$key] -gt [int]::MaxValue) { throw "Invalid budget: $key" }
}
if ($isDevPhase -and $phase.policy.callLimit -ne 1) { throw 'Dev requires exactly one CLI invocation per model.' }
$allowedPhaseTools = @('view', 'glob', 'grep', 'apply_patch', 'create', 'edit')
if ($isDevPhase) {
    $allowedPhaseTools += @('shell', 'local_shell', 'powershell', 'read_powershell', 'write_powershell', 'stop_powershell', 'list_powershell', 'bash', 'read_bash', 'write_bash', 'stop_bash', 'list_bash')
}
if ($phase.policy.timeoutSeconds -gt 86400 -or -not $phase.policy.disableBuiltinMcps -or
    @($phase.availableTools | Where-Object { $_ -cnotin $allowedPhaseTools }).Count) { throw 'Expected bounded local tools.' }
$rubricWeights = if ($isDevPhase) { $null } elseif ($phase.Contains('rubricWeights')) {
    Assert-ScenarioKeys $phase.rubricWeights @('general', 'domain')
    foreach ($wKey in @('general', 'domain')) {
        if (($phase.rubricWeights[$wKey] -isnot [int] -and $phase.rubricWeights[$wKey] -isnot [long]) -or
            $phase.rubricWeights[$wKey] -le 0 -or $phase.rubricWeights[$wKey] -ge 100) {
            throw "Invalid rubricWeights.$wKey"
        }
    }
    if (($phase.rubricWeights.general + $phase.rubricWeights.domain) -ne 100) {
        throw 'rubricWeights.general and rubricWeights.domain must sum to 100.'
    }
    @{ general = [int]$phase.rubricWeights.general; domain = [int]$phase.rubricWeights.domain }
} else {
    @{ general = 30; domain = 70 }
}
$requiredTexts = if ($isDevPhase) { @() } else { @($phase.participantContextLabel, $phase.policy.interactionPrompt, $phase.policy.artifactDescription, $phase.policy.coordinatorPrompt) }
if ($isDesignPhase -or $isDevPhase) { $requiredTexts += $phase.initialRequestTemplate }
foreach ($text in $requiredTexts) {
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) { throw 'Missing shared phase text.' }
}
if (-not $isDevPhase) {
    $parseTokens = $null; $parseErrors = $null
    $evaluatorAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DialogueResultEvaluation.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Evaluator syntax error.' }
    $validator = $evaluatorAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-Rubric' }, $true)
    . ([scriptblock]::Create($validator.Extent.Text))
    Assert-Rubric (Read-ScenarioJson $rubric) 'domain'
    Assert-Rubric (Read-ScenarioJson $generalRubric) 'general'
}
$files = @(& git -c core.quotepath=false -C $source ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate project baseline.' }
$copiedFiles = @(); $excludedFiles = @()
foreach ($relative in @($files | Sort-Object -Unique)) {
    if (@($project.excludePatterns | Where-Object { $relative -like $_ }).Count) { $excludedFiles += $relative; continue }
    if ($isDevPhase -and $project.Contains('runtimeDirectories') -and @($project.runtimeDirectories | Where-Object {
        $relative.Replace('\', '/').StartsWith($_.Replace('\', '/').TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
    }).Count) { $excludedFiles += $relative; continue }
    Assert-ScenarioRelative $relative
    $path = Join-Path $source $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    Assert-ScenarioNoLinks $path
    $copiedFiles += $relative
}
if ($agentRelative -cnotin $copiedFiles) { throw 'Target Agent was excluded from project baseline.' }
if ($project['projectContractPath'] -and $project.projectContractPath.Replace('\', '/') -notin $copiedFiles) {
    throw 'Project contract was excluded from the product baseline.'
}
$instructionFiles = @($copiedFiles | Where-Object {
    $_ -in @('.github/copilot-instructions.md', 'copilot-instructions.md') -or $_ -match '(^|/)AGENTS\.md$' -or
    $_ -like '.github/instructions/*.instructions.md'
})
if ($project['projectContractPath']) { $instructionFiles += $project.projectContractPath.Replace('\', '/') }
$initialRequest = if ($isDevPhase) {
    $phase.initialRequestTemplate.Replace('{designPath}', $designWorkspacePath).Replace('{requirementPath}', $requirementWorkspacePath).Replace('{artifactPath}', $artifactWorkspacePath)
} elseif ($isDesignPhase) {
    $phase.initialRequestTemplate.Replace('{requirementPath}', $requirementWorkspacePath).Replace('{artifactPath}', $artifactWorkspacePath)
} else {
    $knowledgeContent = Get-Content -LiteralPath $scenarioInputFile -Raw -Encoding utf8
    $headingMatch = [regex]::Match($knowledgeContent, '(?ms)^##\s+初始需求\s*\r?\n(.*?)(?=^##\s+|\z)')
    if (-not $headingMatch.Success -or [string]::IsNullOrWhiteSpace($headingMatch.Groups[1].Value)) {
        throw 'Knowledge file must contain a nonempty "## 初始需求" section.'
    }
    $headingMatch.Groups[1].Value.Trim()
}
$effectivePolicy = $phase.policy.Clone()
if (-not $isDevPhase) {
    $effectivePolicy.artifactDescription = $effectivePolicy.artifactDescription.Replace('{artifactPath}', $artifactWorkspacePath).Replace('{designPath}', $designWorkspacePath).Replace('{requirementPath}', $requirementWorkspacePath)
}
$modelsSummary = @{
    target = @($TargetModels)
    participant = $(if ($isDevPhase) { $null } else { $ParticipantModel })
    evaluator = $(if ($isDevPhase) { $null } else { $EvaluatorModel })
}
$plan = @{
    caseId = $manifest.caseId
    stage = $phase.stage
    projectContractPath = $project['projectContractPath']
    layers = @{
        infrastructurePhaseProfile = $phasePath
        projectProfile = $projectPath
        scenarioManifest = $manifestPath
    }
    sourceRepository = $source
    targetAgent = $phase.targetAgent
    models = $modelsSummary
    requestedReasoningEffort = $(if ($ReasoningEffort) { $ReasoningEffort } else { $null })
    designFile = $(if ($isDevPhase) { $scenarioInputFile } else { $null })
    requirementFile = $(if ($isDevPhase) { $referenceRequirementFile } elseif ($isDesignPhase) { $scenarioInputFile } else { $null })
    knowledgeFile = $(if ($isDesignPhase -or $isDevPhase) { $null } else { $scenarioInputFile })
    designWorkspacePath = $(if ($isDevPhase) { $designWorkspacePath } else { $null })
    requirementWorkspacePath = $(if ($isDesignPhase -or $isDevPhase) { $requirementWorkspacePath } else { $null })
    artifactWorkspacePath = $artifactWorkspacePath
    domainRubricFile = $rubric
    designRubricFile = $rubric
    rubricWeights = $rubricWeights
    participantInput = $(if ($isDevPhase) { 'none' } elseif ($isDesignPhase) { 'same-confirmed-requirement' } else { 'private-knowledge' })
    instructionFiles = $instructionFiles
    instructionHandling = 'Project files retained; target CLI custom instructions enabled; no rule text injected.'
    runDirectory = $root
    excludedFiles = $excludedFiles
    minimumParticipantReplies = $(if ($isDevPhase) { 0 } else { $effectivePolicy.minimumParticipantReplies })
    initialRequest = $initialRequest
    dialogueOnly = [bool]$DialogueOnly
    cliPath = $CliPath
    useGitHubCliAuth = $effectiveUseGitHubCliAuth
    modelCallsStarted = $false
    executor = $(if ($isDevPhase) { 'single-shot-dev-v1' } else { 'agent-dialogue' })
    verification = $devVerification
    testStage = $(if ($WithTest) { @{ models = $TestModels; profileFile = [IO.Path]::GetFullPath($TestProfileFile)
        targetAgent = $testProfile.targetAgent; backendTestAccess = $resolvedTestProfile.backendTestAccess
        webTesting = 'not_implemented'; fullQaCompleted = $false } } else { $null })
}
if ($Mode -in @('ValidateOnly', 'Validate')) { [pscustomobject]$plan; return }

$tempPrep = Join-Path ([IO.Path]::GetTempPath()) ('scenario-prep-' + [guid]::NewGuid().ToString('N'))
try {
    $tempInputs = Join-Path $tempPrep 'inputs'
    [void](New-Item -ItemType Directory -Path $tempInputs -Force)
    $inputSnapshotName = if ($isDevPhase) { 'design.md' } elseif ($isDesignPhase) { 'requirement.md' } else { 'knowledge.md' }
    $snapshots = @{
        'scenario.json' = $manifestPath; 'phase.json' = $phasePath; 'project.json' = $projectPath
        $inputSnapshotName = $scenarioInputFile; 'target.agent.md' = $agent
    }
    if (-not $isDevPhase) {
        $snapshots['domain-rubric.json'] = $rubric
        $snapshots['general-rubric.json'] = $generalRubric
        $snapshots['participant.agent.md'] = $participant
    }
    if ($isDesignPhase) { $snapshots['architect.agent.md'] = $agent }
    if ($isDevPhase) {
        $snapshots['developer.agent.md'] = $agent
        $snapshots['requirement.md'] = $referenceRequirementFile
    }
    foreach ($name in $snapshots.Keys) { Copy-Item -LiteralPath $snapshots[$name] -Destination (Join-Path $tempInputs $name) }
    $staging = Join-Path $tempPrep 'product-source'
    [void](New-Item -ItemType Directory -Path $staging -Force)
    $baselineHashes = @{}
    foreach ($relative in $copiedFiles) {
        $destination = Join-Path $staging $relative
        [void](New-Item -ItemType Directory -Path (Split-Path $destination) -Force)
        Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination
        $baselineHashes[$relative] = (Get-FileHash -LiteralPath $destination).Hash
    }
    if ($isDesignPhase -or $isDevPhase) {
        $reqDestination = Join-Path $staging $requirementWorkspacePath
        if ((Test-Path $reqDestination) -and (Get-FileHash $reqDestination).Hash -cne (Get-FileHash (Join-Path $tempInputs 'requirement.md')).Hash) { throw 'Requirement destination collision.' }
        [void](New-Item -ItemType Directory -Path (Split-Path $reqDestination) -Force)
        Copy-Item (Join-Path $tempInputs 'requirement.md') $reqDestination -Force
    }
    if ($isDevPhase) {
        $designDestination = Join-Path $staging $designWorkspacePath
        if ((Test-Path $designDestination) -and (Get-FileHash $designDestination).Hash -cne (Get-FileHash (Join-Path $tempInputs 'design.md')).Hash) { throw 'Design destination collision.' }
        [void](New-Item -ItemType Directory -Path (Split-Path $designDestination) -Force)
        Copy-Item (Join-Path $tempInputs 'design.md') $designDestination -Force
    }
    & git -C $staging init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize prepared baseline.' }
    & git -C $staging add --force --all
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage prepared baseline.' }
    if ($isDevPhase) {
        $hashes = @{}
        Get-ChildItem $tempInputs -File | ForEach-Object { $hashes[$_.Name] = (Get-FileHash $_.FullName).Hash }
        $plan['inputHashes'] = $hashes
        $devComparison = & (Join-Path $PSScriptRoot 'Invoke-DevRun.ps1') -Plan $plan -Phase $phase -Project $project `
            -Verification $devVerification -SourceRepository $staging -InputsDirectory $tempInputs `
            -TargetModels $TargetModels -ReasoningEffort $ReasoningEffort -CliPath $CliPath -UseGitHubCliAuth:$effectiveUseGitHubCliAuth
        $devComparison
        if ($WithTest) {
            $pipeline = @{ schemaVersion = 1; stage = 'dev-test'; devRun = $root; devPassed = $devComparison.passed
                testRun = $null; testState = 'blocked_by_dev'; webTesting = 'not_implemented'; fullQaCompleted = $false }
            if ($devComparison.passed) {
                $testRoot = if ($TestRunDirectory) { [IO.Path]::GetFullPath($TestRunDirectory) } else { $root + '-test' }
                $pipeline.testRun = $testRoot; $pipeline.testState = 'running'
                $pipeline | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $root 'pipeline.json') -Encoding utf8
                try {
                    $testComparison = & (Join-Path $PSScriptRoot 'Invoke-TestRun.ps1') -DevRunDirectory $root `
                        -TestModels $TestModels -RunDirectory $testRoot -Mode Run -CliPath $CliPath `
                        -ProfileFile $TestProfileFile -UseGitHubCliAuth:$effectiveUseGitHubCliAuth
                    $pipeline.testState = $testComparison.state
                } catch {
                    $pipeline.testState = 'failed'; $pipeline['error'] = $_.Exception.Message
                    throw
                } finally {
                    $pipeline | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $root 'pipeline.json') -Encoding utf8
                }
            } else {
                $pipeline | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $root 'pipeline.json') -Encoding utf8
            }
        }
        if (-not $devComparison.passed) { throw "Dev conditions failed; inspect $(Join-Path $root 'comparison.json'). No automatic retry." }
        return
    }
    $config = @{
        caseId = $manifest.caseId
        repositoryPath = $staging; runDirectory = $root
        targetAgent = $phase.targetAgent; targetModel = $TargetModels[0]; participantModel = $ParticipantModel
        participantInput = $phase.participantInput
        protectedWorkspacePaths = @($instructionFiles)
        participantAgentFile = (Join-Path $tempInputs 'participant.agent.md'); knowledgeFile = (Join-Path $tempInputs $inputSnapshotName)
        participantContextLabel = $phase.participantContextLabel; initialRequest = $initialRequest
        availableTools = $phase.availableTools; allowTools = $phase.allowTools; denyTools = $phase.denyTools; policy = $effectivePolicy
    }
    $configPath = Join-Path $tempInputs 'dialogue-config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding utf8
    $hashes = @{}
    Get-ChildItem $tempInputs -File | ForEach-Object { $hashes[$_.Name] = (Get-FileHash $_.FullName).Hash }
    $plan['inputHashes'] = $hashes; $plan['baselineHashes'] = $baselineHashes; $plan['modelCallsStarted'] = $true
    $plan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $tempInputs 'manifest.json') -Encoding utf8
    & (Join-Path $PSScriptRoot 'Invoke-AgentDialogueComparison.ps1') -SourceRepository $staging -RunDirectory $root `
        -TemplateFile $configPath -ParticipantModel $ParticipantModel -TargetModels $TargetModels `
        -CliPath $CliPath -UseGitHubCliAuth:$effectiveUseGitHubCliAuth
    foreach ($name in $hashes.Keys) {
        if ((Get-FileHash (Join-Path $tempInputs $name)).Hash -cne $hashes[$name]) { throw "Frozen input changed: $name" }
    }
    $inputs = Join-Path $root 'inputs'
    [void](New-Item -ItemType Directory -Path $inputs -Force)
    Get-ChildItem $tempInputs -File | Copy-Item -Destination $inputs -Force
    $comparison = Read-ScenarioJson (Join-Path $root 'comparison.json')
    if ($isDesignPhase) {
        foreach ($condition in $comparison.conditions) {
            $product = Join-Path (Split-Path $condition.configFile) 'product'
            if ((Get-FileHash (Join-Path $product $requirementWorkspacePath)).Hash -cne $hashes['requirement.md']) { throw 'Confirmed requirement changed during design.' }
            $changed = @(& git -C $product diff --name-only) + @(& git -C $product ls-files --others)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect final workspace.' }
            if (@($changed | Where-Object { $_ -ine $artifactWorkspacePath.Replace('\', '/') }).Count) { throw 'Design changed files outside the agreed artifact.' }
        }
    }
    Copy-Item (Join-Path $inputs 'domain-rubric.json') (Join-Path $root 'domain-rubric.json') -Force
    Copy-Item (Join-Path $inputs 'manifest.json') (Join-Path $root 'input-manifest.json') -Force
    if (-not $DialogueOnly) {
        $evalParams = @{
            RunDirectory = $root; Model = $EvaluatorModel
            RubricFile = (Join-Path $inputs 'general-rubric.json')
            DomainRubricFile = (Join-Path $inputs 'domain-rubric.json')
            GeneralRubricWeight = $rubricWeights.general
            DomainRubricWeight = $rubricWeights.domain
            CliPath = $CliPath; UseGitHubCliAuth = $effectiveUseGitHubCliAuth
        }
        if ($isDesignPhase) {
            $references = @((Join-Path $inputs 'requirement.md'))
            $references += @($instructionFiles | ForEach-Object { Join-Path (Join-Path $root 'baseline') $_ })
            $evalParams['ReferenceFile'] = $references
        }
        & (Join-Path $PSScriptRoot 'Invoke-DialogueResultEvaluation.ps1') @evalParams
    }
} finally {
    if (Test-Path -LiteralPath $tempPrep) { Remove-Item -LiteralPath $tempPrep -Recurse -Force -ErrorAction SilentlyContinue }
}