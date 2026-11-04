#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DevRunDirectory,
    [string[]]$DevConditions = @(),
    [string[]]$TestModels = @('gpt-6.1-sol'),
    [string]$RunDirectory,
    [ValidateSet('ValidateOnly', 'Validate', 'Run')][string]$Mode = 'ValidateOnly',
    [string]$CliPath = 'copilot',
    [string]$ProfileFile = (Join-Path $PSScriptRoot '..\profiles\backend-testing.json'),
    [string]$ProjectFile,
    [switch]$UseGitHubCliAuth
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevDelivery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
function Write-Json([string]$Path, $Value) { $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Progress([string]$Phase, [string]$Message) {
    Write-Json (Join-Path $root 'progress.json') @{ phase = $Phase; message = $Message; updatedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    Write-Host "Test ${Phase}: $Message"
}
function Save-Comparison {
    Write-Json (Join-Path $root 'comparison.json') $comparison
    $lines = @('# Backend Test comparison', '', 'Web testing: not_implemented. Full QA: not completed.', '',
        '| Dev condition | Test model | Outcome | Before / after | AIC | Report |',
        '| --- | --- | --- | --- | --- | --- |')
    foreach ($item in $comparison.conditions) {
        $lines += "| $($item.devCondition) | $($item.model) | $($item.state) | $($item['beforePassed']) / $($item['afterPassed']) | $($item['aiCredits']) | [Report](./$($item.name)/test/summary.md) |"
    }
    $lines | Set-Content -LiteralPath (Join-Path $root 'summary.md') -Encoding utf8
}

$sourceRoot = (Resolve-Path -LiteralPath $DevRunDirectory).Path
$dev = Read-Json (Join-Path $sourceRoot 'comparison.json')
if ($dev['stage'] -ne 'dev' -or -not $dev['conditions']) { throw 'DevRunDirectory must be a Dev comparison root.' }
$TestModels = @($TestModels | ForEach-Object { $_ -split '[,，]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $TestModels.Count) { throw 'Specify at least one Test model.' }
foreach ($model in $TestModels) {
    if ($model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$' -or ($model -imatch '^fusion:' -and $model -inotmatch '^fusion:(standard|high|max)$')) {
        throw "Invalid Test model: $model"
    }
}
foreach ($name in $DevConditions) { if ($name -notin @($dev.conditions.name)) { throw "Unknown Dev condition: $name" } }
$selected = @($dev.conditions | Where-Object { -not $DevConditions.Count -or $_.name -in $DevConditions })
$devInput = Read-Json (Join-Path $sourceRoot 'input-manifest.json')
$project = @{}
if ($ProjectFile) {
    $ProjectFile = (Resolve-Path -LiteralPath $ProjectFile).Path
    $project = Read-Json $ProjectFile
} elseif (Test-Path -LiteralPath (Join-Path $sourceRoot 'inputs\project.json')) {
    $ProjectFile = Join-Path $sourceRoot 'inputs\project.json'
    $project = Read-Json $ProjectFile
}
if ($ProjectFile -and ($project -isnot [System.Collections.IDictionary] -or $project['schemaVersion'] -ne 1)) {
    throw 'Test ProjectFile must be a schemaVersion 1 project object.'
}
$resolvedProfile = Read-BackendTestProfile $ProfileFile $devInput['sourceRepository'] $project
$profilePath = $resolvedProfile.path; $profile = $resolvedProfile.profile
$agentFile = $resolvedProfile.agentFile
$readOnlyBackend = $resolvedProfile.backendTestAccess -eq 'read-only'
$root = if ($RunDirectory) { [IO.Path]::GetFullPath($RunDirectory) } else {
    $sourceRoot + '-test-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
}
Assert-DeliveryOutput $root $sourceRoot
Assert-DeliveryOutput $root (Split-Path $PSScriptRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new Test RunDirectory; never overwrite an earlier run.' }
$sources = @()
foreach ($condition in $selected) {
    Assert-DevRelativePath $condition.name
    $conditionPath = Join-Path $sourceRoot $condition.name
    $deliveryPath = Join-Path $conditionPath 'delivery'
    if (Test-Path -LiteralPath (Join-Path $deliveryPath 'delivery.json')) {
        if (-not $condition['delivery'] -or (Get-FileHash -LiteralPath (Join-Path $deliveryPath 'delivery.json')).Hash -cne $condition.delivery.manifestSha256) {
            throw "Untrusted or changed delivery manifest: $($condition.name)"
        }
        $manifest = Read-DevDelivery $deliveryPath
        $resultPath = Join-Path $conditionPath 'dev\result.json'
        if ((Get-FileHash -LiteralPath $resultPath).Hash -cne $manifest.sourceResultSha256) { throw 'Source Dev result changed after delivery.' }
    } else {
        # Old runs are imported only after their files match baseline plus saved Dev changes.
        $source = Get-DevDeliverySource $conditionPath
        $manifest = @{ caseId = $source.plan.caseId; devOutcome = $source.result.outcome }
        $deliveryPath = $null
    }
    $sources += @{ name = $condition.name; condition = $conditionPath; delivery = $deliveryPath; manifest = $manifest }
}
if ($Mode -ne 'Run') {
    [pscustomobject]@{ stage = 'test'; devConditions = @($sources.name); testModels = $TestModels
        targetAgent = $profile.targetAgent; agentFile = $agentFile; backendTestAccess = $resolvedProfile.backendTestAccess
        reportWorkspacePath = $profile['reportWorkspacePath']; projectContractPath = $profile['projectContractPath']
        runDirectory = $root; modelCallsStarted = $false; webTesting = 'not_implemented'; fullQaCompleted = $false }
    return
}
[void](New-Item -ItemType Directory -Path $root)
$inputs = Join-Path $root 'inputs'
[void](New-Item -ItemType Directory -Path $inputs)
Write-Json (Join-Path $inputs 'profile.json') $profile
if ($ProjectFile) { Copy-Item -LiteralPath $ProjectFile -Destination (Join-Path $inputs 'project.json') }
Copy-Item -LiteralPath $agentFile -Destination (Join-Path $inputs 'tester.agent.md')
if ($resolvedProfile.contractFile) {
    Copy-Item -LiteralPath $resolvedProfile.contractFile -Destination (Join-Path $inputs 'project-contract.md')
}
foreach ($name in @('Invoke-TestRun.ps1', 'DevDelivery.psm1', 'DevExecution.psm1', 'DialoguePolicy.psm1', 'CapturedProcess.psm1', 'Invoke-SdlcCapture.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $inputs
}
$comparison = @{ schemaVersion = 1; stage = 'test'; sourceDevRun = $sourceRoot; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    targetAgent = $profile.targetAgent; backendTestAccess = $resolvedProfile.backendTestAccess
    agentSha256 = (Get-FileHash -LiteralPath (Join-Path $inputs 'tester.agent.md')).Hash
    state = 'running'; passed = $false; webTesting = 'not_implemented'; fullQaCompleted = $false; conditions = @() }
Save-Comparison
$savedTokens = @{}
try {
    if ($UseGitHubCliAuth) {
        foreach ($key in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $savedTokens[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $null, 'Process')
        }
    }
    foreach ($source in $sources) {
        if (-not $source.delivery) {
            Progress 'importing' "Verifying and freezing historical Dev delivery: $($source.name)"
            $source.delivery = Join-Path $root "deliveries\$($source.name)"
            $source.manifest = New-DevDelivery $source.condition $source.delivery
        }
        $manifest = $source.manifest
        $deliveryHash = (Get-FileHash -LiteralPath (Join-Path $source.delivery 'delivery.json')).Hash
        $index = 0
        foreach ($model in $TestModels) {
            $index++
            $name = "$($source.name)--test-$($model.ToLowerInvariant() -replace '[^a-z0-9-]', '-')-$index"
            $conditionRoot = Join-Path $root $name
            $workspace = Join-Path $conditionRoot 'product'
            $resultDirectory = Join-Path $conditionRoot 'test'
            [void](New-Item -ItemType Directory -Path $resultDirectory -Force)
            $entry = @{ name = $name; devCondition = $source.name; model = $model; state = 'preparing'; runDirectory = $resultDirectory }
            $comparison.conditions += $entry
            Save-Comparison
            $sourceBefore = Get-DevHashes (Join-Path $source.condition 'product') @($manifest.runtimeDirectories)
            $reportRelative = if ($profile['reportWorkspacePath']) { $profile.reportWorkspacePath.Replace('{caseId}', $manifest.caseId).Replace('\', '/') } else { $null }
            if ($reportRelative) { Assert-DevRelativePath $reportRelative }
            $result = @{ schemaVersion = 1; stage = 'test'; outcome = 'starting'; model = $model; calls = 0
                targetAgent = $profile.targetAgent; backendTestAccess = $resolvedProfile.backendTestAccess
                reportWorkspacePath = $reportRelative; agentSha256 = $comparison.agentSha256
                startedAt = [DateTimeOffset]::UtcNow.ToString('o'); deliveryId = $manifest.id; deliveryManifestSha256 = $deliveryHash
                sourceDevCondition = $source.name; devModel = $manifest.devModel; devOutcome = $manifest.devOutcome
                observedModels = @(); fusionPhases = @(); execution = $null; capture = $null; verification = $null
                beforeVerification = $null; changedFiles = @(); protectedChanges = @(); errors = @(); warnings = @()
                webTesting = 'not_implemented'; fullQaCompleted = $false; review = $null; integrityVerified = $false
                aiCredits = $null; usageStatus = 'unavailable'; testBaseline = 'latest-delivered-backend' }
            try {
                Progress 'preparing' "${name}: independent source, dependencies and reset state"
                [void](Read-DevDelivery $source.delivery)
                $dirs = @($manifest.runtimeDirectories)
                Copy-DevDeliveryWorkspace $source.delivery $manifest $workspace (Join-Path $conditionRoot 'runtime-copy')
                $result['deliveryIntegrityPolicy'] = if ($manifest.schemaVersion -eq 2) { $manifest.integrityPolicy } else { 'legacy-full-sha256' }
                foreach ($reserved in @('test-review.json', '.eval-evidence') + @($reportRelative | Where-Object { $_ })) {
                    if (Test-Path -LiteralPath (Join-Path $workspace $reserved)) { throw "Reserved Test path already exists: $reserved" }
                }
                [void](New-Item -ItemType Directory -Path (Join-Path $workspace '.github\agents') -Force)
                Copy-Item -LiteralPath (Join-Path $inputs 'tester.agent.md') -Destination (Join-Path $workspace ".github\agents\$($profile.targetAgent).agent.md") -Force
                if ($resolvedProfile.contractFile) {
                    $contractTarget = Join-Path $workspace $profile.projectContractPath
                    $contractInput = Join-Path $inputs 'project-contract.md'
                    $result.contractOrigin = if (Test-Path -LiteralPath $contractTarget) { 'dev-delivery' } else { 'test-input-only' }
                    $result.contractSha256 = (Get-FileHash -LiteralPath $contractInput).Hash
                    if ((Test-Path -LiteralPath $contractTarget) -and (Get-FileHash $contractTarget).Hash -cne (Get-FileHash $contractInput).Hash) {
                        throw 'Test project contract differs from the Dev delivery; explicitly reconcile the contract before testing.'
                    }
                    [void](New-Item -ItemType Directory -Path (Split-Path $contractTarget) -Force)
                    Copy-Item -LiteralPath $contractInput -Destination $contractTarget -Force
                }
                Copy-Item -LiteralPath (Join-Path $source.delivery 'evidence') -Destination (Join-Path $workspace '.eval-evidence') -Recurse
                & git -C $workspace init --quiet
                if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize Test workspace.' }
                @('/.eval-tmp/', '/.pytest_cache/') + @($dirs | ForEach-Object { '/' + $_.Replace('\', '/').TrimEnd('/') + '/' }) |
                    Add-Content -LiteralPath (Join-Path $workspace '.git\info\exclude')
                & git -C $workspace add --all
                if ($LASTEXITCODE -ne 0) { throw 'Cannot stage Test baseline.' }
                & git -C $workspace -c core.hooksPath=.git/disabled-hooks -c user.name='Evaluation Fixture' `
                    -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet --allow-empty `
                    -m "Freeze Test baseline`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
                if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze Test Git baseline.' }
                $before = Get-DevHashes $workspace $dirs
                $temp = Join-Path $workspace '.eval-tmp'
                [void](New-Item -ItemType Directory -Path $temp)
                $environment = @{ TEMP = $temp; TMP = $temp; TMPDIR = $temp; PYTHONDONTWRITEBYTECODE = '1'; PYTHONNOUSERSITE = '1'
                    PYTHONPATH = $null; PYTHONHOME = $null; DATABASE_URL = $null; JWT_SECRET = $null
                    FLASK_APP = $null; FLASK_ENV = $null; PYTEST_ADDOPTS = $null; PYTEST_PLUGINS = $null; VIRTUAL_ENV = $null }
                if (Test-Path -LiteralPath (Join-Path $workspace '.venv\Scripts')) {
                    $environment.VIRTUAL_ENV = Join-Path $workspace '.venv'
                    $environment.PATH = (Join-Path $workspace '.venv\Scripts') + [IO.Path]::PathSeparator + $env:PATH
                }
                $verification = $manifest.verification.Clone()
                $acceptance = if ($verification['acceptanceDirectory']) { Join-Path $source.delivery 'acceptance' } else { $null }
                $parameters = @{ Candidate = $workspace; Baseline = (Join-Path $source.delivery 'product'); Verification = $verification
                    RuntimeDirectories = $dirs; Environment = $environment; StateSource = (Join-Path $source.delivery 'runtime')
                    UseCandidateTests = $true; AcceptanceDirectory = $acceptance }
                Progress 'before_tests' "${name}: independently running delivered backend tests"
                $result.beforeVerification = Invoke-DevVerification @parameters -OutputDirectory (Join-Path $conditionRoot 'before-verification')
                $prompt = @"
Independently review Dev delivery $($manifest.id), case $($manifest.caseId).
Workspace root: $workspace. Use only this workspace; never access the original Dev directory.
Confirmed requirements: $($manifest.requirementWorkspacePath)
Confirmed design: $($manifest.designWorkspacePath)
Dev evidence: .eval-evidence (read-only). It is historical evidence, not your execution results.
Backend test paths: $($verification.testPaths -join ', ').
Backend test access: $($resolvedProfile.backendTestAccess).
$(if ($readOnlyBackend) { 'Do not modify backend tests, their fixtures, frontend unit tests, product code or configuration. Report test gaps and defects back to Dev; do not fix them.' } else { 'Only the listed backend test paths may be maintained; justify every test change.' })
Write test-review.json and $(if ($reportRelative) { "the independent report at $reportRelative" } else { 'a final summary' }). Do not modify other files.
Project contract: $($profile['projectContractPath']).
Contract origin: $($result['contractOrigin']). If test-input-only, it was added for this assessment and does not prove Dev followed this workflow.
Review new/changed requirement coverage, affected existing tests, and core regression membership.
Independently execute latest Python/API tests. Report defects rather than editing product implementation.
Python interpreter: $($verification.pythonExecutable). No dependency installation, browser tests or persistent servers.
This is one independent main Test session, not a Dev continuation or subagent. Do not ask questions.
This run is explicitly authorized as a BACKEND-ONLY assessment, not the full Test role's Web workflow.
Web testing is not implemented in this controller. Record it as not run; never claim full QA or hand off for business acceptance.
test-review.json must contain these fields:
{"requirementCoverage":[{"requirement":"AC or description","tests":["tests/test_example.py::test_name"],"status":"covered or gap"}],"coreRegressionReview":"Assessment and core-set recommendations","testChanges":[],"defects":[{"summary":"Product or test issue","evidence":"Reproduction and actual result"}],"limitations":["Unverified scope"]}
Use empty arrays if appropriate. Coverage is your assessment, not mechanically proven. For read-only tests, testChanges must remain empty.
For maintain mode only, each testChanges entry must contain path and a requirement-based reason.
Write the review and report even when blocked or tests fail, distinguish test defects from product defects, and exit.
"@
                $promptFile = Join-Path $resultDirectory 'prompt.txt'
                $prompt | Set-Content -LiteralPath $promptFile -Encoding utf8
                $result.calls = 1; $entry.state = 'running'
                Write-Json (Join-Path $resultDirectory 'result.json') $result
                Save-Comparison
                Progress 'model_running' "${name}: main Test CLI; budget $($profile.timeoutSeconds)s"
                $capture = Join-Path $resultDirectory 'capture'
                $tools = @('view', 'glob', 'grep', 'apply_patch', 'create', 'edit') +
                    $(if ($IsWindows) { @('powershell', 'read_powershell', 'stop_powershell', 'list_powershell') } else { @('bash', 'read_bash', 'stop_bash', 'list_bash') })
                & (Join-Path $inputs 'Invoke-SdlcCapture.ps1') -RepositoryPath $workspace -PromptFile $promptFile -RunDirectory $capture `
                    -Agent $profile.targetAgent -Model $model -CliPath $CliPath -AvailableTool $tools -AllowTool @('write', 'shell') `
                    -CopilotHome (Join-Path $conditionRoot 'target-home') -DisableBuiltinMcps -TimeoutSeconds $profile.timeoutSeconds -ProcessEnvironment $environment | Out-Host
                $exitCode = $LASTEXITCODE
                $turns = @(Get-ChildItem -LiteralPath $capture -Directory -Filter 'turn-*')
                if ($turns.Count -ne 1) { throw 'Test requires exactly one captured main invocation.' }
                $turn = $turns[0].FullName; $meta = Read-Json (Join-Path $turn 'turn.json')
                $runtime = if (Test-Path -LiteralPath (Join-Path $turn 'runtime.json')) { Read-Json (Join-Path $turn 'runtime.json') } else { $null }
                $result.execution = @{ cliExitCode = $meta['cliExitCode']; collectorExitCode = $exitCode; timedOut = $meta['timedOut']; durationSeconds = $meta['executionDurationSeconds'] }
                $result.capture = @{ complete = $meta['captureComplete'] -eq $true; state = $meta.state; turnDirectory = $turn }
                $result['requestedFusionTier'] = $meta['requestedFusionTier']; $result['requestedAutoTier'] = $meta['requestedAutoTier']
                if ($runtime) { $result.observedModels = $runtime.observedModels; $result.fusionPhases = $runtime.fusionPhases }
                if (Test-Path -LiteralPath (Join-Path $turn 'usage.json')) {
                    $usage = Read-Json (Join-Path $turn 'usage.json')
                    if ($null -ne $usage['totalNanoAiu'] -and $usage.totalNanoAiu -is [ValueType] -and $usage.totalNanoAiu -ge 0) {
                        $result.aiCredits = [decimal]$usage.totalNanoAiu / 1000000000d
                        $result.usageStatus = if ($usage['aiCreditsStatus'] -eq 'complete') { 'complete' } else { 'partial' }
                    }
                }
                $after = Get-DevHashes $workspace $dirs
                foreach ($dependency in @($dirs | Where-Object { $_ -match '(^|[/\\])(\.venv|node_modules)$' })) {
                    $metadata = $manifest.schemaVersion -eq 2
                    Assert-DeliveryHashes (Get-DeliveryHashes (Join-Path $source.delivery "runtime\$dependency") -MetadataOnly:$metadata) `
                        (Get-DeliveryHashes (Join-Path $workspace $dependency) -MetadataOnly:$metadata)
                }
                foreach ($path in @(@($before.Keys) + @($after.Keys) | Sort-Object -Unique)) {
                    if ($before[$path] -ceq $after[$path]) { continue }
                    $result.changedFiles += @{ path = $path; before = $before[$path]; after = $after[$path] }
                    $allowed = $path -ceq 'test-review.json' -or ($reportRelative -and $path -ceq $reportRelative) -or (-not $readOnlyBackend -and @($verification.testPaths | Where-Object {
                        $prefix = $_.Replace('\', '/').TrimEnd('/')
                        $path -ieq $prefix -or $path.StartsWith($prefix + '/', [StringComparison]::OrdinalIgnoreCase)
                    }).Count -gt 0)
                    if (-not $allowed) { $result.protectedChanges += $path }
                }
                Progress 'after_tests' "${name}: independently verifying reviewed backend tests"
                $result.verification = Invoke-DevVerification @parameters -OutputDirectory (Join-Path $conditionRoot 'verification')
                $diagnostics = if (Test-Path -LiteralPath (Join-Path $turn 'capture-diagnostics.json')) { Read-Json (Join-Path $turn 'capture-diagnostics.json') } else { $null }
                $result.outcome = Get-DevOutcome $result $runtime $meta $diagnostics -AllowNoChanges
                $reviewPath = Join-Path $workspace 'test-review.json'
                if (Test-Path -LiteralPath $reviewPath) {
                    $review = Read-Json $reviewPath
                    if ($review['requirementCoverage'] -isnot [array] -or -not $review.requirementCoverage.Count -or
                        $review['testChanges'] -isnot [array] -or $review['defects'] -isnot [array] -or
                        $review['limitations'] -isnot [array] -or [string]::IsNullOrWhiteSpace($review['coreRegressionReview'])) { throw 'Invalid backend review contract.' }
                    foreach ($coverage in $review.requirementCoverage) {
                        if ($coverage -isnot [hashtable] -or [string]::IsNullOrWhiteSpace($coverage['requirement']) -or
                            $coverage['status'] -notin @('covered', 'gap') -or $coverage['tests'] -isnot [array] -or
                            ($coverage.status -eq 'covered' -and -not $coverage.tests.Count)) { throw 'Invalid requirement coverage entry.' }
                    }
                    foreach ($change in $result.changedFiles | Where-Object { $_.path -ne 'test-review.json' -and $_.path -ne $reportRelative -and $_.path -notin $result.protectedChanges }) {
                        if (-not @($review.testChanges | Where-Object { $_.path -eq $change.path -and -not [string]::IsNullOrWhiteSpace($_.reason) }).Count) {
                            throw "Missing justification for test change: $($change.path)"
                        }
                    }
                    $result.review = $review
                    Copy-Item -LiteralPath $reviewPath -Destination (Join-Path $resultDirectory 'test-review.json')
                }
                if ($result.outcome -eq 'stage_completed') {
                    $reportExists = -not $reportRelative -or ((Test-Path -LiteralPath (Join-Path $workspace $reportRelative) -PathType Leaf) -and (Get-Item -LiteralPath (Join-Path $workspace $reportRelative)).Length -gt 0)
                    $result.outcome = if (-not $result.review -or -not $reportExists) { 'review_missing' }
                        elseif ($readOnlyBackend -and $result.review.testChanges.Count) { 'review_findings' }
                        elseif ($result.review.defects.Count -or @($result.review.requirementCoverage | Where-Object { $_.status -ne 'covered' }).Count) { 'review_findings' }
                        else { 'backend_tests_passed' }
                }
            } catch {
                $result.outcome = 'infrastructure_failed'; $result.errors += $_.Exception.Message
                Write-Warning "Test ${name}: $($_.Exception.Message)"
            } finally {
                try {
                    [void](Read-DevDelivery $source.delivery)
                    Assert-DeliveryHashes $sourceBefore (Get-DevHashes (Join-Path $source.condition 'product') @($manifest.runtimeDirectories))
                    if ((Get-FileHash -LiteralPath (Join-Path $source.delivery 'delivery.json')).Hash -cne $deliveryHash -or
                        (Get-FileHash -LiteralPath $manifest.sourceResult).Hash -cne $manifest.sourceResultSha256) { throw 'Source delivery or Dev evidence changed.' }
                    $result.integrityVerified = $true
                } catch {
                    $result.outcome = 'source_integrity_failed'; $result.errors += $_.Exception.Message
                    Write-Warning $_.Exception.Message
                }
                $result['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
                $result['statusSummary'] = Get-DevStatusSummary $result
                Write-Json (Join-Path $resultDirectory 'result.json') $result
                Write-Json (Join-Path $resultDirectory 'report.json') $result
                @("# Backend Test: $name", '', "Outcome: $($result.outcome)", "Delivery: $($result.deliveryId)",
                    "Dev: $($result.devModel) / $($result.devOutcome)", "Test requested / actual: $model / $($result.observedModels -join ', ')",
                    "Agent: $($result.targetAgent); backend access: $($result.backendTestAccess); project report: $reportRelative",
                    "Started: $($result.startedAt); finished: $($result.finishedAt)",
                    "AIC: $($result.aiCredits); status: $($result.usageStatus) (CLI evidence, not invoice)",
                    "Before tests passed: $($result.beforeVerification -and $result.beforeVerification.passed)",
                    "After tests: $($result.statusSummary.passed)/$($result.statusSummary.total); status: $($result.statusSummary.tests)",
                    "Execution: $($result.statusSummary.execution); capture: $($result.statusSummary.capture)",
                    "Source integrity: $($result.integrityVerified); policy: $($result['deliveryIntegrityPolicy'])",
                    'Dependency metadata checks do not prove byte-for-byte integrity.',
                    'Web testing: not_implemented; full QA: NOT completed.',
                    'Requirement coverage is an Agent review, not independently proven by a passing suite.',
                    '[Before checks](../before-verification/checks.json)',
                    '[After checks](../verification/checks.json)', '[Review](test-review.json)', '[Details](result.json)',
                    "Errors: $($result.errors -join '; ')") | Set-Content -LiteralPath (Join-Path $resultDirectory 'summary.md') -Encoding utf8
                $entry.state = $result.outcome; $entry['beforePassed'] = [bool]($result.beforeVerification -and $result.beforeVerification.passed)
                $entry['afterPassed'] = [bool]($result.verification -and $result.verification.passed); $entry['aiCredits'] = $result.aiCredits
                Save-Comparison
                Progress 'condition_finished' "$name -> $($result.outcome)"
            }
        }
    }
} catch {
    $comparison['error'] = $_.Exception.Message
    Write-Warning "Test run failed: $($_.Exception.Message)"
} finally {
    foreach ($key in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($key, $savedTokens[$key], 'Process') }
    $comparison.passed = -not $comparison['error'] -and $comparison.conditions.Count -eq ($sources.Count * $TestModels.Count) -and
        @($comparison.conditions | Where-Object state -ne 'backend_tests_passed').Count -eq 0
    $comparison.state = if ($comparison.passed) { 'backend_tests_passed' } else { 'test_conditions_failed' }
    $comparison['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    Save-Comparison
    Progress 'finished' $comparison.state
}
if (-not $comparison.passed) { throw "Backend Test failed; inspect $(Join-Path $root 'comparison.json'). No automatic retry." }
[pscustomobject]$comparison
