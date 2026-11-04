if ($args -contains '--version') { Write-Output 'fixture-test 1.0'; exit 0 }
if ($args -contains '--help') { Write-Output "  --disallow-temp-dir`n  --sync-session[=<on|off>]"; exit 0 }
if ($args -contains '--no-remote' -or $args -contains '--no-remote-export' -or $args -notcontains '--sync-session=off') { throw 'Test must use modern session isolation flags.' }
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
$workspace = $args[[Array]::IndexOf($args, '-C') + 1]
$model = $args[[Array]::IndexOf($args, '--model') + 1]
$mode = $env:TEST_RUN_FIXTURE
$agent = $args[[Array]::IndexOf($args, '--agent') + 1]
if ($agent -eq 'SDLCRole_Test' -and (-not $prompt.Contains('Backend test access: read-only') -or -not $prompt.Contains('BACKEND-ONLY'))) {
    throw 'SDLCRole_Test requires an explicit read-only backend assessment scope.'
}
if ($args -contains '--resume' -or -not $prompt.Contains('main Test session')) { throw 'Test must start a fresh main session.' }
if (-not (Test-Path -LiteralPath (Join-Path $workspace '.eval-evidence\result.json'))) { throw 'Dev handoff evidence missing.' }
if (-not $env:TEMP.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar)) { throw 'Test temp must be isolated.' }
if ($env:TEST_RUN_COUNTER) { Add-Content -LiteralPath $env:TEST_RUN_COUNTER -Value "$workspace $model" }
if ($model -eq 'auto') { $model = 'fixture-routed-tester' }
@{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
$changes = @()
if ($mode -eq 'maintain') {
    "from answer import answer`n`ndef test_added():`n    assert answer == 2" | Set-Content -LiteralPath (Join-Path $workspace 'tests\test_added.py')
    $changes += @{ path = 'tests/test_added.py'; reason = 'Covers the newly required value.' }
}
if ($mode -eq 'product-tamper') { 'answer = 9' | Set-Content -LiteralPath (Join-Path $workspace 'answer.py') }
if ($mode -eq 'dependency-tamper') { 'changed-dependency' | Set-Content -LiteralPath (Join-Path $workspace 'node_modules\fixture-package\index.js') }
if ($mode -eq 'fixture-tamper') { '# changed fixture' | Set-Content -LiteralPath (Join-Path $workspace 'tests\conftest.py') }
if ($mode -eq 'contract-tamper') { Add-Content -LiteralPath (Join-Path $workspace 'docs\PROJECT-WORKFLOW-ROLES-DEV-TEST.md') -Value 'Unapproved contract edit.' }
if ($mode -eq 'tests-fail') {
    "def test_added():`n    assert False" | Set-Content -LiteralPath (Join-Path $workspace 'tests\test_added.py')
    $changes += @{ path = 'tests/test_added.py'; reason = 'Exposes a missing requirement.' }
}
if ($mode -eq 'state-check') {
    if ((Get-Content -LiteralPath (Join-Path $workspace '.runtime\state.txt') -Raw).Trim() -ne 'frozen-state') { throw 'Test must start from reset state.' }
    'changed-by-test' | Set-Content -LiteralPath (Join-Path $workspace '.runtime\state.txt')
}
if ($mode -ne 'missing-review') {
    @{ requirementCoverage = @(@{ requirement = 'answer equals two'; tests = @('tests/test_regression.py::test_regression'); status = $(if ($mode -eq 'review-gap') { 'gap' } else { 'covered' }) })
        coreRegressionReview = 'Existing core requirement retained.'; testChanges = $changes
        defects = @(); limitations = @('Web not implemented')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $workspace 'test-review.json')
}
$report = [regex]::Match($prompt, 'independent report at ([a-zA-Z0-9_/-]+\.md)')
if ($report.Success -and $mode -ne 'missing-report') {
    $reportFile = Join-Path $workspace $report.Groups[1].Value
    [void](New-Item -ItemType Directory -Path (Split-Path $reportFile) -Force)
    'Independent backend report. Web not run; no full QA claim.' | Set-Content -LiteralPath $reportFile
}
$usagePath = $args[[Array]::IndexOf($args, '--usage-output-file') + 1]
@{ totalNanoAiu = 100000000; aiCreditsStatus = 'complete' } | ConvertTo-Json | Set-Content -LiteralPath $usagePath
if ($mode -eq 'corrupt') { Write-Output 'not-json' }
if ($mode -eq 'timeout') { Start-Sleep -Seconds 30 }
@{ type = 'assistant.message'; id = 'test-final'; data = @{ content = 'Independent backend review complete. Web not implemented.' } } | ConvertTo-Json -Compress
if ($mode -eq 'exit-failure') { exit 7 }
exit 0
