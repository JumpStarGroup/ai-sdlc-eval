#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable]$Plan,
    [Parameter(Mandatory)][hashtable]$Phase,
    [Parameter(Mandatory)][hashtable]$Project,
    [Parameter(Mandatory)][hashtable]$Verification,
    [Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$InputsDirectory,
    [Parameter(Mandatory)][string[]]$TargetModels,
    [string]$ReasoningEffort,
    [Parameter(Mandatory)][string]$CliPath,
    [switch]$UseGitHubCliAuth
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CapturedProcess.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevDelivery.psm1') -Force

function Write-DevJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Write-DevProgress([string]$PhaseName, [string]$Message) {
    $progress = @{ updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); phase = $PhaseName; message = $Message }
    Write-DevJson (Join-Path $root 'progress.json') $progress
    Write-Host "[$($progress.updatedAt)] Dev ${PhaseName}: $Message"
}
function Invoke-DevGit([string]$Workspace, [string[]]$Arguments) {
    & git -C $Workspace @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Dev workspace Git command failed: $($Arguments -join ' ')" }
}

$root = $Plan.runDirectory
$runStartedAt = [DateTimeOffset]::UtcNow
if (Test-Path -LiteralPath $root) { throw 'Use a fresh Dev run directory.' }
[void](New-Item -ItemType Directory -Path $root)
Write-DevProgress 'preparing' "Preparing isolated run for: $($TargetModels -join ', ')"
$inputs = Join-Path $root 'inputs'
[void](New-Item -ItemType Directory -Path $inputs)
Get-ChildItem -LiteralPath $InputsDirectory -File | Copy-Item -Destination $inputs
$frameworkSnapshot = Join-Path $inputs 'framework'
[void](New-Item -ItemType Directory -Path $frameworkSnapshot)
foreach ($name in @('Invoke-DevRun.ps1', 'DevExecution.psm1', 'DevDelivery.psm1', 'CapturedProcess.psm1', 'Invoke-SdlcCapture.ps1', 'DialoguePolicy.psm1', 'Export-DevReport.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $frameworkSnapshot
}
$runtimeDirectories = @(if ($Project.ContainsKey('runtimeDirectories')) { $Project.runtimeDirectories })
$baseline = Join-Path $root 'baseline'
Copy-DevSource $SourceRepository $baseline
$baselineHashes = Get-DevHashes $baseline @()
$runtimeBaseline = Join-Path $root 'runtime-baseline'
Write-DevProgress 'runtime_baseline' 'Copying installed dependencies and database state; no model invocation yet.'
Copy-DevRuntime $Plan.sourceRepository $runtimeBaseline $runtimeDirectories (Join-Path $root 'runtime-copy')
$acceptance = $null
if ($Verification['acceptanceDirectory']) {
    $acceptance = Join-Path $inputs 'acceptance'
    Copy-DevSource $Verification.acceptanceDirectory $acceptance
}
$planSnapshot = $Plan.Clone()
$planSnapshot['modelCallsStarted'] = $false
$planSnapshot['baselineHashes'] = $baselineHashes
$planSnapshot['frameworkHashes'] = @{}
Get-ChildItem -LiteralPath $frameworkSnapshot -File | ForEach-Object {
    $planSnapshot.frameworkHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName).Hash
}
Write-DevJson (Join-Path $root 'input-manifest.json') $planSnapshot
$comparison = @{ schemaVersion = 1; stage = 'dev'; executor = 'single-shot-dev-v1'; runDirectory = $root
    requestedReasoningEffort = $(if ($ReasoningEffort) { $ReasoningEffort } else { $null })
    sourceRepository = $Plan.sourceRepository; conditions = @(); evaluation = 'python-api-tests'
    acceptanceConfigured = [bool]$acceptance; modelCallsStarted = $false; state = 'prepared'; passed = $false
    startedAt = $runStartedAt.ToString('o') }
for ($index = 0; $index -lt $TargetModels.Count; $index++) {
    $preparationStartedAt = [DateTimeOffset]::UtcNow
    $label = ($TargetModels[$index].ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $label) { throw 'Invalid Dev model label.' }
    $name = '{0}-{1}-{2:d2}' -f $Plan.caseId, $label, ($index + 1)
    $conditionRoot = Join-Path $root $name
    $workspace = Join-Path $conditionRoot 'product'
    Write-DevProgress 'workspace' "Preparing $name at $workspace"
    Copy-DevSource $baseline $workspace
    Invoke-DevGit $workspace @('init', '--quiet')
    Invoke-DevGit $workspace @('add', '--force', '--all')
    Invoke-DevGit $workspace @('-c', 'core.hooksPath=.git/disabled-hooks', '-c', 'user.name=Evaluation Fixture',
        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Freeze Dev baseline')
    @('/.eval-tmp/', '/.pytest_cache/') + @($runtimeDirectories | ForEach-Object { '/' + $_.Replace('\', '/').TrimEnd('/') + '/' }) |
        Add-Content -LiteralPath (Join-Path $workspace '.git\info\exclude')
    Copy-DevRuntime $runtimeBaseline $workspace $runtimeDirectories (Join-Path $conditionRoot 'runtime-copy')
    $preparedHashes = Get-DevHashes $workspace $runtimeDirectories
    if ($preparedHashes.Count -ne $baselineHashes.Count -or
        @($baselineHashes.Keys | Where-Object { $preparedHashes[$_] -cne $baselineHashes[$_] }).Count) {
        throw "Prepared Dev source baseline differs: $workspace"
    }
    $config = @{
        repositoryPath = $workspace; runDirectory = (Join-Path $conditionRoot 'dev')
        model = $TargetModels[$index]; timeoutSeconds = $Phase.policy.timeoutSeconds
        requestedReasoningEffort = $comparison.requestedReasoningEffort
        verification = $Verification; runtimeDirectories = $runtimeDirectories
        initialRequest = $Plan.initialRequest
        preparationStartedAt = $preparationStartedAt.ToString('o')
        preparationDurationSeconds = ([DateTimeOffset]::UtcNow - $preparationStartedAt).TotalSeconds
    }
    $configFile = Join-Path $conditionRoot 'config.json'
    Write-DevJson $configFile $config
    $comparison.conditions += @{ name = $name; model = $TargetModels[$index]; configFile = $configFile
        requestedReasoningEffort = $comparison.requestedReasoningEffort
        runDirectory = $config.runDirectory; state = 'prepared'; calls = 0 }
}
Write-DevJson (Join-Path $root 'comparison.json') $comparison
$savedTokens = @{}
try {
    if ($UseGitHubCliAuth) {
        foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    foreach ($condition in $comparison.conditions) {
        $comparison.state = 'running'
        $condition.state = 'preflight'
        Write-DevJson (Join-Path $root 'comparison.json') $comparison
        Write-DevProgress 'preflight' "$($condition.model): preparing independent baseline test copy, then running Python/API tests."
        $conditionRoot = Split-Path $condition.configFile
        $workspace = Join-Path $conditionRoot 'product'
        $resultDirectory = $condition.runDirectory
        [void](New-Item -ItemType Directory -Path $resultDirectory)
        $result = @{ schemaVersion = 1; outcome = 'starting'; calls = 0; model = $condition.model
            requestedReasoningEffort = $condition.requestedReasoningEffort
            startedAt = [DateTimeOffset]::UtcNow.ToString('o')
            execution = $null; capture = $null; verification = $null; preflight = $null; errors = @()
            observedModels = @(); fusionPhases = @(); changedFiles = @(); protectedChanges = @()
            acceptanceConfigured = [bool]$acceptance; acceptanceVerified = $null
            scoring = @{ regressionPassRate = $null; acceptancePassRate = $null; modelScore = $null } }
        $conditionConfig = Get-Content -LiteralPath $condition.configFile -Raw | ConvertFrom-Json -AsHashtable
        $result['preparationDurationSeconds'] = $conditionConfig.preparationDurationSeconds
        $temporary = Join-Path $workspace '.eval-tmp'
        [void](New-Item -ItemType Directory -Path $temporary)
        $environment = @{
            TEMP = $temporary; TMP = $temporary; TMPDIR = $temporary
            PYTHONDONTWRITEBYTECODE = '1'; PYTHONNOUSERSITE = '1'
            PYTHONPATH = $null; PYTHONHOME = $null; DATABASE_URL = $null; JWT_SECRET = $null
            FLASK_APP = $null; FLASK_ENV = $null; PYTEST_ADDOPTS = $null; PYTEST_PLUGINS = $null
        }
        if (Test-Path -LiteralPath (Join-Path $workspace '.venv\Scripts') -PathType Container) {
            $environment.VIRTUAL_ENV = Join-Path $workspace '.venv'
            $environment.PATH = (Join-Path $workspace '.venv\Scripts') + [IO.Path]::PathSeparator + $env:PATH
        } else { $environment.VIRTUAL_ENV = $null }
        try {
            $verificationParameters = @{
                Candidate = $workspace; Baseline = $baseline; Verification = $Verification
                RuntimeDirectories = $runtimeDirectories; Environment = $environment; AcceptanceDirectory = $acceptance
            }
            $result.preflight = Invoke-DevVerification @verificationParameters -OutputDirectory (Join-Path $conditionRoot 'preflight') -Preflight
            if (-not $result.preflight.passed) { $result.outcome = 'environment_failed'; continue }
            $prompt = @"
$($Plan.initialRequest)

Workspace root: $workspace
All relative file paths are relative to this product directory, NOT its parent.
Use relative paths when reading or editing project files. Tool output files are in .eval-tmp inside this workspace; use the exact returned path.
This is one noninteractive development invocation. Do not ask questions or wait for approvals.
Complete code changes, Python/API self-tests and basic frontend verification, then exit. Do not run browser/E2E tests or start persistent servers.
When frontend code or its dependencies change, run the existing frontend build and focused tests for affected functionality, including affected unit/component tests. Run configured type/static checks as applicable. Compilation alone does not prove that affected functionality works.
Keep frontend verification proportional to the change and use existing project tooling; do not introduce a new testing framework or run a broad Web regression campaign. Test owns independent Web/E2E acceptance, not Dev self-tests.
Record actual frontend commands, exit codes, results and coverage in the Dev update list. If required tooling or tests are missing, checks fail or basic functionality cannot be verified, explicitly report the blocker and unverified scope. Do not claim unexecuted checks or an empty test suite passed.
No dialogue protocol or special completion marker is required. The framework independently verifies the saved code after exit.
"@
            $promptFile = Join-Path $resultDirectory 'prompt.txt'
            $prompt | Set-Content -LiteralPath $promptFile -Encoding utf8
            $tools = @($Phase.availableTools | Where-Object { $_ -cne 'shell' })
            if ('shell' -cin $Phase.availableTools) {
                $tools += if ($IsWindows) { @('powershell', 'read_powershell', 'stop_powershell', 'list_powershell') }
                    else { @('bash', 'read_bash', 'stop_bash', 'list_bash') }
            }
            $captureParameters = @{
                RepositoryPath = $workspace; PromptFile = $promptFile; RunDirectory = (Join-Path $resultDirectory 'capture')
                Agent = $Phase.targetAgent; Model = $condition.model; CliPath = $CliPath
                AvailableTool = $tools; AllowTool = $Phase.allowTools; DenyTool = $Phase.denyTools
                CopilotHome = (Join-Path $conditionRoot 'target-home'); DisableBuiltinMcps = $true
                TimeoutSeconds = $Phase.policy.timeoutSeconds; ProcessEnvironment = $environment
            }
            if ($ReasoningEffort) { $captureParameters.ReasoningEffort = $ReasoningEffort }
            $result.calls = 1
            $comparison.modelCallsStarted = $true
            $planSnapshot.modelCallsStarted = $true
            Write-DevJson (Join-Path $root 'input-manifest.json') $planSnapshot
            $result.outcome = 'running'
            $condition.state = 'running'
            $condition.calls = 1
            Write-DevJson (Join-Path $root 'comparison.json') $comparison
            Write-DevJson (Join-Path $resultDirectory 'result.json') $result
            Write-DevProgress 'model_running' "$($condition.model): one CLI invocation; budget $($Phase.policy.timeoutSeconds)s. Capture: $($captureParameters.RunDirectory)"
            & (Join-Path $PSScriptRoot 'Invoke-SdlcCapture.ps1') @captureParameters | Out-Host
            $captureExit = $LASTEXITCODE
            $turn = @(Get-ChildItem -LiteralPath $captureParameters.RunDirectory -Directory -Filter 'turn-*')
            if ($turn.Count -ne 1) { throw 'Dev requires exactly one captured invocation.' }
            $meta = Get-Content -LiteralPath (Join-Path $turn[0].FullName 'turn.json') -Raw | ConvertFrom-Json -AsHashtable
            $result.execution = @{ collectorExitCode = $captureExit; cliExitCode = $meta['cliExitCode']
                timedOut = $meta['timedOut']; timeoutSeconds = $meta.timeoutSeconds; durationSeconds = $meta['executionDurationSeconds'] }
            $result.capture = @{ complete = $meta['captureComplete'] -eq $true; state = $meta.state
                turnDirectory = $turn[0].FullName; errors = $meta.errors }
            $runtimePath = Join-Path $turn[0].FullName 'runtime.json'
            $runtime = $null
            if (Test-Path -LiteralPath $runtimePath) {
                $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json -AsHashtable
                $result.observedModels = $runtime.observedModels
                $result.fusionPhases = $runtime.fusionPhases
            }
            $result['usageFile'] = Join-Path $turn[0].FullName 'usage.json'
            $after = Get-DevHashes $workspace $runtimeDirectories
            foreach ($relative in @(@($baselineHashes.Keys) + @($after.Keys) | Sort-Object -Unique)) {
                if ($baselineHashes[$relative] -cne $after[$relative]) {
                    $result.changedFiles += @{ path = $relative; before = $baselineHashes[$relative]; after = $after[$relative] }
                    if ($relative -ieq $Plan.requirementWorkspacePath.Replace('\', '/') -or
                        $relative -ieq $Plan.designWorkspacePath.Replace('\', '/') -or
                        $relative -in $Plan.instructionFiles -or $relative -imatch '^\.github/agents/') {
                        $result.protectedChanges += $relative
                    }
                }
            }
            $condition.state = 'verifying'
            Write-DevJson (Join-Path $root 'comparison.json') $comparison
            Write-DevProgress 'verification' "$($condition.model): CLI exited; verifying latest backend tests, then historical comparison."
            $result['verificationPolicy'] = 'latest-backend-with-historical-comparison-v1'
            $result.verification = Invoke-DevVerification @verificationParameters -OutputDirectory (Join-Path $conditionRoot 'verification') `
                -UseCandidateTests -StateSource $runtimeBaseline
            $result['historicalVerification'] = Invoke-DevVerification @verificationParameters `
                -OutputDirectory (Join-Path $conditionRoot 'historical-verification') -Preflight -StateSource $runtimeBaseline
            foreach ($check in $result.verification.checks) {
                if ($check.name -eq 'regression') { $result.scoring.regressionPassRate = $check.passRate }
                if ($check.name -eq 'acceptance') {
                    $result.scoring.acceptancePassRate = $check.passRate
                    $result.acceptanceVerified = $check.passed
                }
            }
            $diagnosticsPath = Join-Path $turn[0].FullName 'capture-diagnostics.json'
            $captureDiagnostics = if (Test-Path -LiteralPath $diagnosticsPath) {
                Get-Content -LiteralPath $diagnosticsPath -Raw | ConvertFrom-Json -AsHashtable
            } else { $null }
            $result.outcome = Get-DevOutcome $result $runtime $meta $captureDiagnostics
            foreach ($warning in @($result['warnings'])) {
                Write-Warning "$($condition.model): $($warning.code): $($warning.message)"
            }
        } catch {
            $result.outcome = 'infrastructure_failed'
            $result.errors += $_.Exception.Message
            Write-Warning "Dev condition $($condition.name): $($_.Exception.Message)"
        } finally {
            $result['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
            $condition.state = $result.outcome
            $condition.calls = $result.calls
            $condition['observedTargetModels'] = $result.observedModels
            Export-DevStatusReport $result $resultDirectory $condition.name
            if ($result.outcome -in @('stage_completed', 'tests_failed', 'no_code_changes')) {
                try {
                    $deliveryPath = Join-Path $conditionRoot 'delivery'
                    Write-DevProgress 'delivery' "$($condition.model): freezing source, dependencies and reset state for independent Test runs."
                    $delivery = New-DevDelivery $conditionRoot $deliveryPath
                    $condition['delivery'] = @{ directory = $deliveryPath; id = $delivery.id
                        manifestSha256 = (Get-FileHash -LiteralPath (Join-Path $deliveryPath 'delivery.json')).Hash }
                } catch {
                    $result.outcome = 'delivery_failed'; $result.errors += $_.Exception.Message
                    $condition.state = $result.outcome
                    Write-Warning "Dev delivery failed: $($_.Exception.Message)"
                    Export-DevStatusReport $result $resultDirectory $condition.name
                }
            }
            $condition['statusSummary'] = $result.statusSummary
            $condition['warnings'] = @($result['warnings'])
            Write-Host "Dev $($condition.name): execution=$($result.statusSummary.execution); capture=$($result.statusSummary.capture); tests=$($result.statusSummary.tests) ($($result.statusSummary.passed)/$($result.statusSummary.total))."
            Write-DevJson (Join-Path $root 'comparison.json') $comparison
            Write-DevProgress 'condition_finished' "$($condition.model): $($result.outcome)"
        }
    }
} finally {
    foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name], 'Process') }
}
$comparison.passed = @($comparison.conditions | Where-Object { $_.state -ne 'stage_completed' }).Count -eq 0
$comparison.state = if ($comparison.passed) { 'stage_completed' } else { 'conditions_failed' }
$comparison['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
Write-DevJson (Join-Path $root 'comparison.json') $comparison
& (Join-Path $PSScriptRoot 'Export-DevReport.ps1') -RunDirectory $root
Write-DevProgress 'finished' "$($comparison.state); summary: $(Join-Path $root 'summary.md')"
[pscustomobject]$comparison
