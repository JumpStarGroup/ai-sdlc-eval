#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) {
    [void](New-Item -ItemType Directory -Path (Split-Path $Path) -Force)
    $Value | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $Path -Encoding utf8
}
$framework = Split-Path $PSScriptRoot
Import-Module (Join-Path $framework 'tools\DevDelivery.psm1') -Force
Import-Module (Join-Path $framework 'tools\DevExecution.psm1') -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('backend-test-' + [guid]::NewGuid().ToString('N'))
$saved = @{ mode = $env:TEST_RUN_FIXTURE; counter = $env:TEST_RUN_COUNTER; autoload = $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD }
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
try {
    $source = Join-Path $fixture 'dev-run'
    $condition = Join-Path $source 'dev-one'
    $workspace = Join-Path $condition 'product'
    foreach ($relative in @('tests', 'docs', '.github\agents', '.runtime', 'node_modules\fixture-package')) { [void](New-Item -ItemType Directory -Path (Join-Path $workspace $relative) -Force) }
    "---`nname: SDLCRole_Test`n---`nProject Test role." | Set-Content -LiteralPath (Join-Path $workspace '.github\agents\SDLCRole_Test.agent.md')
    'Project contract: backend test changes go to Dev.' | Set-Content -LiteralPath (Join-Path $workspace 'docs\PROJECT-WORKFLOW-ROLES-DEV-TEST.md')
    'dependency-v1' | Set-Content -LiteralPath (Join-Path $workspace 'node_modules\fixture-package\index.js')
    'answer = 2' | Set-Content -LiteralPath (Join-Path $workspace 'answer.py')
    "from answer import answer`n`ndef test_regression():`n    assert answer == 2" | Set-Content -LiteralPath (Join-Path $workspace 'tests\test_regression.py')
    'confirmed requirement' | Set-Content -LiteralPath (Join-Path $workspace 'docs\requirement.md')
    'confirmed design' | Set-Content -LiteralPath (Join-Path $workspace 'docs\design.md')
    'dirty-dev-state' | Set-Content -LiteralPath (Join-Path $workspace '.runtime\state.txt')
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'runtime-baseline\.runtime') -Force)
    'frozen-state' | Set-Content -LiteralPath (Join-Path $source 'runtime-baseline\.runtime\state.txt')
    $verification = @{ pythonExecutable = 'python'; testPaths = @('tests'); timeoutSeconds = 30 }
    Write-Json (Join-Path $condition 'config.json') @{ verification = $verification; runtimeDirectories = @('.runtime', 'node_modules'); repositoryPath = $workspace }
    Write-Json (Join-Path $source 'input-manifest.json') @{ stage = 'dev'; caseId = 'fixture'; sourceRepository = $workspace
        baselineHashes = (Get-DevHashes $workspace @('.runtime')); requirementWorkspacePath = 'docs/requirement.md'
        designWorkspacePath = 'docs/design.md' }
    Write-Json (Join-Path $condition 'dev\result.json') @{ outcome = 'tests_failed'; model = 'dev-model'; changedFiles = @()
        execution = @{ cliExitCode = 0; timedOut = $false }; protectedChanges = @(); observedModels = @('dev-model') }
    $comparison = @{ stage = 'dev'; conditions = @(@{ name = 'dev-one'; state = 'tests_failed'; configFile = (Join-Path $condition 'config.json'); runDirectory = (Join-Path $condition 'dev') }) }
    Write-Json (Join-Path $source 'comparison.json') $comparison
    $sourceHashes = Get-DeliveryHashes $source
    $env:TEST_RUN_COUNTER = Join-Path $fixture 'calls.txt'
    $profile = Get-Content (Join-Path $framework 'profiles\backend-testing.json') -Raw | ConvertFrom-Json -AsHashtable
    $profile.targetAgent = 'eval-backend-tester'
    $profile.agentSource = 'profile'
    $profile.backendTestAccess = 'maintain'
    [void]$profile.Remove('projectContractPath')
    [void]$profile.Remove('reportWorkspacePath')
    $profile.agentFile = Join-Path $framework 'agents\backend-tester.agent.md'
    $profile.timeoutSeconds = 10
    $profilePath = Join-Path $fixture 'profile.json'
    Write-Json $profilePath $profile
    $runner = Join-Path $framework 'tools\Invoke-TestRun.ps1'
    $cli = Join-Path $PSScriptRoot 'fixtures\fake-test-cli.ps1'
    $planOutput = Join-Path $fixture 'validate-only'
    $plan = & $runner -DevRunDirectory $source -RunDirectory $planOutput -TestModels 'fusion:standard,fusion:high' -ProfileFile $profilePath
    Assert (-not $plan.modelCallsStarted -and $plan.testModels.Count -eq 2 -and -not (Test-Path $planOutput)) 'Test validation must not create files or invoke CLI.'
    $projectPath = Join-Path $fixture 'project.json'
    Write-Json $projectPath @{ schemaVersion = 1; id = 'fixture'; repositoryPath = $workspace; runsRoot = $fixture
        requirementWorkspacePath = 'docs/requirement.md'; designWorkspacePath = 'docs/design.md'; excludePatterns = @()
        projectContractPath = 'docs/PROJECT-WORKFLOW-ROLES-DEV-TEST.md'; reportWorkspacePath = 'reports/backend-{caseId}.md' }
    $scenarioPath = Join-Path $fixture 'scenario.json'
    Write-Json $scenarioPath @{ schemaVersion = 1; caseId = 'fixture'; projectProfile = $projectPath; stages = @{} }
    $unified = & (Join-Path $framework 'tools\Invoke-SDLC-Eval.ps1') -ScenarioFile $scenarioPath -Stage test `
        -DevRunDirectory $source -DevConditions 'dev-one' -TestModels 'fixture-tester' -RunDirectory $planOutput -TestProfileFile $profilePath
    Assert ($unified.stage -eq 'test' -and -not $unified.modelCallsStarted) 'Unified Test entry must route to source delivery without requiring a duplicate stage input.'
    $externalPlan = & (Join-Path $framework 'tools\Invoke-SDLC-Eval.ps1') -ScenarioFile $scenarioPath -Stage test `
        -DevRunDirectory $source -RunDirectory $planOutput -TestModels fixture-tester
    Assert ($externalPlan.reportWorkspacePath -eq 'reports/backend-{caseId}.md' -and
        $externalPlan.projectContractPath -eq 'docs/PROJECT-WORKFLOW-ROLES-DEV-TEST.md' -and
        -not (Test-Path $planOutput)) 'Project-specific Test paths come from the external project configuration.'
    $env:TEST_RUN_FIXTURE = 'state-check'
    $externalRun = Join-Path $fixture 'external-project-test'
    & $runner -DevRunDirectory $source -ProjectFile $projectPath -Mode Run -RunDirectory $externalRun `
        -TestModels fixture-tester -CliPath $cli | Out-Null
    Assert (Test-Path (Join-Path $externalRun 'dev-one--test-fixture-tester-1\product\reports\backend-fixture.md')) 'Test writes its report at the project-configured path.'
    $effectiveProfile = Get-Content (Join-Path $externalRun 'inputs\profile.json') -Raw | ConvertFrom-Json
    Assert ($effectiveProfile.reportWorkspacePath -eq 'reports/backend-{caseId}.md') 'Effective Test paths are frozen in runtime evidence.'
    foreach ($mode in @('state-check', 'maintain', 'product-tamper', 'dependency-tamper', 'tests-fail', 'missing-review', 'review-gap', 'corrupt', 'exit-failure', 'timeout')) {
        $env:TEST_RUN_FIXTURE = $mode
        $profile.timeoutSeconds = if ($mode -eq 'timeout') { 2 } else { 10 }
        Write-Json $profilePath $profile
        $output = Join-Path $fixture $mode
        $models = @(if ($mode -eq 'state-check') { 'fusion:standard'; 'fusion:high' } else { 'fixture-tester' })
        $errorText = $null
        try { & $runner -DevRunDirectory $source -RunDirectory $output -Mode Run -TestModels $models -CliPath $cli -ProfileFile $profilePath | Out-Null }
        catch { $errorText = $_.Exception.Message }
        $index = Get-Content (Join-Path $output 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
        $expected = switch ($mode) {
            'product-tamper' { 'protected_input_changed' }; 'dependency-tamper' { 'infrastructure_failed' }; 'tests-fail' { 'tests_failed' }
            'review-gap' { 'review_findings' }
            'missing-review' { 'review_missing' }; 'exit-failure' { 'execution_failed' }; 'timeout' { 'timed_out' }
            default { 'backend_tests_passed' }
        }
        Assert (($null -eq $errorText) -eq ($expected -eq 'backend_tests_passed')) "$mode failed: $errorText"
        Assert ($index.conditions.Count -eq $models.Count -and -not $index.fullQaCompleted -and $index.webTesting -eq 'not_implemented') 'Backend-only status and independent conditions are required.'
        foreach ($item in $index.conditions) {
            $result = Get-Content (Join-Path $item.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert ($result.outcome -eq $expected -and $result.calls -eq 1 -and $result.integrityVerified) "$mode incorrect outcome: $($result.outcome) / $($result.errors -join '; ')"
            Assert ($result.devOutcome -eq 'tests_failed') 'Test may analyze failed Dev tests without rewriting the original outcome.'
            if ($mode -eq 'maintain') {
                Assert ($result.beforeVerification.checks[0].total -eq 1 -and $result.verification.checks[0].total -eq 2 -and
                    $result.review.testChanges.Count -eq 1) 'Independent before/after counts and reasons must reflect actual latest tests.'
            }
            if ($mode -eq 'corrupt') { Assert ($result.capture.nonBlocking -and -not $result.capture.complete) 'Diagnosed stdout damage must remain visible but not replace test evidence.' }
        }
        Assert-DeliveryHashes $sourceHashes (Get-DeliveryHashes $source)
        Write-Host "PASS: Test $mode"
    }
    $readOnlyProfile = Get-Content (Join-Path $framework 'profiles\backend-testing.json') -Raw | ConvertFrom-Json -AsHashtable
    $readOnlyProfile.projectContractPath = 'docs/PROJECT-WORKFLOW-ROLES-DEV-TEST.md'
    $readOnlyProfile.reportWorkspacePath = 'docs/Test/test-report-{caseId}.md'
    $readOnlyProfile.timeoutSeconds = 10
    $readOnlyPath = Join-Path $fixture 'readonly-profile.json'
    Write-Json $readOnlyPath $readOnlyProfile
    foreach ($mode in @('state-check', 'maintain', 'fixture-tamper', 'contract-tamper', 'missing-report')) {
        $env:TEST_RUN_FIXTURE = $mode
        $output = Join-Path $fixture "readonly-$mode"
        $errorText = $null
        try { & $runner -DevRunDirectory $source -RunDirectory $output -Mode Run -TestModels 'fusion:standard' -CliPath $cli -ProfileFile $readOnlyPath | Out-Null }
        catch { $errorText = $_.Exception.Message }
        $index = Get-Content (Join-Path $output 'comparison.json') -Raw | ConvertFrom-Json -AsHashtable
        $result = Get-Content (Join-Path $index.conditions[0].runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
        $expected = if ($mode -eq 'state-check') { 'backend_tests_passed' } elseif ($mode -eq 'missing-report') { 'review_missing' } else { 'protected_input_changed' }
        Assert ($result.outcome -eq $expected -and ($null -eq $errorText) -eq ($expected -eq 'backend_tests_passed')) "Read-only $mode unexpected outcome: $($result.outcome) / $errorText"
        Assert ($result.targetAgent -eq 'SDLCRole_Test' -and $result.backendTestAccess -eq 'read-only' -and $result.integrityVerified) 'New Test role and its read-only policy must be recorded and enforced.'
        Assert ((Get-FileHash (Join-Path $output 'inputs\tester.agent.md')).Hash -ceq
            (Get-FileHash (Join-Path $workspace '.github\agents\SDLCRole_Test.agent.md')).Hash) 'Test must snapshot the actual project role, not the legacy framework tester.'
        Assert-DeliveryHashes $sourceHashes (Get-DeliveryHashes $source)
        Write-Host "PASS: SDLCRole_Test read-only $mode"
    }
    $readOnlyProfile.webTesting = 'enabled'
    Write-Json $readOnlyPath $readOnlyProfile
    $rejected = $false
    try { & $runner -DevRunDirectory $source -RunDirectory (Join-Path $fixture 'unsupported-web') -ProfileFile $readOnlyPath | Out-Null } catch { $rejected = $true }
    Assert ($rejected -and -not (Test-Path (Join-Path $fixture 'unsupported-web'))) 'Unimplemented Web execution must be rejected before creating a run.'
    foreach ($invalid in @(
        @{ agentFile = '.github/agents/missing.agent.md' },
        @{ targetAgent = 'wrong-name' },
        @{ projectContractPath = 'docs/missing-contract.md' },
        @{ backendTestAccess = 'maintain' },
        @{ reportWorkspacePath = 'tests/new_test.py' }
    )) {
        $candidate = Get-Content (Join-Path $framework 'profiles\backend-testing.json') -Raw | ConvertFrom-Json -AsHashtable
        $candidate.reportWorkspacePath = 'reports/test-{caseId}.md'
        foreach ($key in $invalid.Keys) { $candidate[$key] = $invalid[$key] }
        Write-Json $readOnlyPath $candidate
        $rejected = $false
        try { Read-BackendTestProfile $readOnlyPath $workspace | Out-Null } catch { $rejected = $true }
        Assert $rejected "Invalid Test role input must fail before a model call: $($invalid.Keys -join ', ')"
    }
    foreach ($invalidProject in @(
        @{},
        @{ reportWorkspacePath = '' },
        @{ reportWorkspacePath = 42 },
        @{ reportWorkspacePath = '../outside.md' },
        @{ reportWorkspacePath = 'reports/test.py' },
        @{ reportWorkspacePath = 'reports/test.md'; projectContractPath = '../outside.md' }
    )) {
        $rejected = $false
        try { Read-BackendTestProfile (Join-Path $framework 'profiles\backend-testing.json') $workspace $invalidProject | Out-Null }
        catch { $rejected = $true }
        Assert $rejected 'Missing or invalid project Test paths must fail before execution.'
    }
    $invalidProjectPath = Join-Path $fixture 'invalid-project.json'
    Write-Json $invalidProjectPath @{ schemaVersion = 2; reportWorkspacePath = 'reports/test.md' }
    $rejected = $false
    try { & $runner -DevRunDirectory $source -ProjectFile $invalidProjectPath -RunDirectory $planOutput | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*schemaVersion 1 project object*' }
    Assert ($rejected -and -not (Test-Path $planOutput)) 'Unsupported project schema fails without creating runtime files.'
    $delivery = Join-Path $condition 'delivery'
    $manifest = New-DevDelivery $condition $delivery
    Assert ($manifest.schemaVersion -eq 2 -and $manifest.integrityPolicy -eq 'source-sha256-dependency-metadata-v1' -and
        $manifest.hashes['runtime/node_modules/fixture-package/index.js'] -like 'metadata:*' -and
        $manifest.hashes['runtime/.runtime/state.txt'] -notlike 'metadata:*') 'Only dependency contents must be exempt from SHA256.'
    $dependencyFile = Join-Path $delivery 'runtime\node_modules\fixture-package\index.js'
    $dependencyBytes = [IO.File]::ReadAllBytes($dependencyFile)
    $dependencyTime = [IO.File]::GetLastWriteTimeUtc($dependencyFile)
    $locked = [IO.File]::Open($dependencyFile, 'Open', 'ReadWrite', 'None')
    try { [void](Read-DevDelivery $delivery) } finally { $locked.Dispose() }
    $mutatedBytes = [byte[]]$dependencyBytes.Clone()
    $mutatedBytes[0] = [byte][char]'X'
    [IO.File]::WriteAllBytes($dependencyFile, $mutatedBytes)
    [IO.File]::SetLastWriteTimeUtc($dependencyFile, $dependencyTime)
    [void](Read-DevDelivery $delivery)
    'different size' | Add-Content -LiteralPath $dependencyFile
    $rejected = $false
    try { [void](Read-DevDelivery $delivery) } catch { $rejected = $true }
    Assert $rejected 'Dependency size changes must be detected.'
    [IO.File]::WriteAllBytes($dependencyFile, $dependencyBytes)
    [IO.File]::SetLastWriteTimeUtc($dependencyFile, $dependencyTime)
    $legacyPath = Join-Path $fixture 'legacy-delivery'
    Copy-Item -LiteralPath $delivery -Destination $legacyPath -Recurse
    $legacy = Get-Content (Join-Path $legacyPath 'delivery.json') -Raw | ConvertFrom-Json -AsHashtable
    $legacy.schemaVersion = 1
    $legacy.hashes = Get-DeliveryHashes $legacyPath
    [void]$legacy.hashes.Remove('delivery.json')
    Write-Json (Join-Path $legacyPath 'delivery.json') $legacy
    [void](Read-DevDelivery $legacyPath)
    $legacyDependency = Join-Path $legacyPath 'runtime\node_modules\fixture-package\index.js'
    [IO.File]::WriteAllBytes($legacyDependency, $mutatedBytes)
    [IO.File]::SetLastWriteTimeUtc($legacyDependency, $dependencyTime)
    $rejected = $false
    try { [void](Read-DevDelivery $legacyPath) } catch { $rejected = $true }
    Assert $rejected 'Legacy snapshots must still verify dependency contents, even with identical size and timestamp.'
    Write-Host 'PASS: schema 2 never reads dependency contents, detects metadata changes and preserves legacy full hashing.'
    $comparison.conditions[0]['delivery'] = @{ directory = $delivery; id = $manifest.id; manifestSha256 = (Get-FileHash (Join-Path $delivery 'delivery.json')).Hash }
    Write-Json (Join-Path $source 'comparison.json') $comparison
    $env:TEST_RUN_FIXTURE = 'maintain'
    $profile.timeoutSeconds = 10; Write-Json $profilePath $profile
    & $runner -DevRunDirectory $source -RunDirectory (Join-Path $fixture 'frozen-reuse') -Mode Run -CliPath $cli -ProfileFile $profilePath -TestModels 'fixture-tester' | Out-Null
    $beforeCalls = @(Get-Content $env:TEST_RUN_COUNTER).Count
    'changed' | Set-Content -LiteralPath (Join-Path $delivery 'product\answer.py')
    $rejected = $false
    try { & $runner -DevRunDirectory $source -RunDirectory (Join-Path $fixture 'tampered-delivery') -Mode Run -CliPath $cli -ProfileFile $profilePath | Out-Null }
    catch { $rejected = $true }
    Assert ($rejected -and @(Get-Content $env:TEST_RUN_COUNTER).Count -eq $beforeCalls) 'Changed frozen delivery must be rejected before a paid call.'
    $comparison.conditions[0].Remove('delivery')
    Write-Json (Join-Path $source 'comparison.json') $comparison
    $rejected = $false
    try { & $runner -DevRunDirectory $source -RunDirectory (Join-Path $source 'nested-test') -Mode Run -CliPath $cli -ProfileFile $profilePath | Out-Null }
    catch { $rejected = $true }
    Assert $rejected 'Test output must not be nested under Dev evidence.'
    Write-Host 'PASS: independent backend Test, historical import, frozen reuse, model matrix, immutable Dev evidence, integrity rejection and backend-only reporting.'
} finally {
    $env:TEST_RUN_FIXTURE = $saved.mode; $env:TEST_RUN_COUNTER = $saved.counter; $env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = $saved.autoload
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
