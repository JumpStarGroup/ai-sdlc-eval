if ($args -contains '--version') { Write-Output 'fixture-dev 1.0'; exit 0 }
if ($args -contains '--help') { Write-Output "  --disallow-temp-dir`n  --sync-session[=<on|off>]"; exit 0 }
if ($args -contains '--no-remote' -or $args -contains '--no-remote-export' -or $args -notcontains '--sync-session=off') { throw 'Dev must use modern session isolation flags.' }
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
if ($args[$([Array]::IndexOf($args, '--agent') + 1)] -in @('eval-backend-tester', 'SDLCRole_Test')) {
    if ($args -contains '--reasoning-effort') { throw 'Dev reasoning effort must not leak into the Test stage.' }
    $prompt | & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'fake-test-cli.ps1') @args
    exit $LASTEXITCODE
}
if (-not $prompt.Contains('run the existing frontend build and focused tests for affected functionality') -or
    -not $prompt.Contains('Compilation alone does not prove that affected functionality works.') -or
    -not $prompt.Contains('Do not claim unexecuted checks or an empty test suite passed.') -or
    -not $prompt.Contains('Do not run browser/E2E tests or start persistent servers.') -or
    $prompt.Contains('Frontend builds and frontend tests are not required for this stage.')) {
    throw 'Dev prompt must require basic frontend verification without transferring self-tests to Test.'
}
$workspace = $args[[Array]::IndexOf($args, '-C') + 1]
$model = $args[[Array]::IndexOf($args, '--model') + 1]
$session = $args[[Array]::IndexOf($args, '--session-id') + 1]
$mode = $env:DEV_RUN_FIXTURE
if ($mode -eq 'reasoning-max') {
    $effortIndex = [Array]::IndexOf($args, '--reasoning-effort')
    if ($effortIndex -lt 0 -or $args[$effortIndex + 1] -cne 'max') {
        throw 'Explicit Dev reasoning effort must reach the CLI unchanged.'
    }
} elseif ($args -contains '--reasoning-effort') {
    throw 'Default Dev runs must not override CLI reasoning effort.'
}
if ($args -contains '--resume' -or $prompt.Contains('DIALOGUE_CONTROL')) { throw 'Dev must be a single invocation without dialogue protocol.' }
if (-not $env:TEMP.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar)) { throw 'Temp must be inside this product workspace.' }
Add-Content -LiteralPath $env:DEV_RUN_COUNTER -Value "$session $model"
@{ type = 'session.start'; id = 'start'; timestamp = '2026-01-01T00:00:00Z'; data = @{} } | ConvertTo-Json -Compress
@{ type = 'model.call_start'; id = 'model'; timestamp = '2026-01-01T00:00:01Z'; data = @{
    model = $(if ($mode -eq 'model-mismatch' -or $mode -eq 'mismatch-corrupt') { 'different-model' }
        elseif ($mode -eq 'missing-model-corrupt') { '' } else { $model })
} } | ConvertTo-Json -Compress
if ($mode -ne 'no-change') {
    $answer = if ($mode -in @('tamper', 'updated-regression')) { 0 } elseif ($mode -in @('feature-failed', 'tests-failed-corrupt')) { 1 } elseif ($mode -eq 'test-timeout') { 3 } else { 2 }
    "answer = $answer" | Set-Content -LiteralPath (Join-Path $workspace 'answer.py')
    'changed' | Set-Content -LiteralPath (Join-Path $workspace 'feature.txt')
}
if ($mode -eq 'tamper') {
    "def test_regression():`n    assert True" | Set-Content -LiteralPath (Join-Path $workspace 'tests\test_regression.py')
}
if ($mode -eq 'updated-regression') {
    "from answer import answer`n`ndef test_regression():`n    assert answer == 0" | Set-Content -LiteralPath (Join-Path $workspace 'tests\test_regression.py')
}
if ($mode -eq 'protected') { Add-Content -LiteralPath (Join-Path $workspace 'docs\requirements\req-dv01.md') -Value 'Unapproved change' }
if ($mode -like '*corrupt*') {
    Write-Output 'invalid JSON before final output'
    Write-Output '{"type":'
}
if ($mode -eq 'runtime-error-corrupt') {
    @{ type = 'session.error'; id = 'runtime-error'; timestamp = '2026-01-01T00:00:02Z'
        data = @{ message = 'Fixture runtime failure' } } | ConvertTo-Json -Compress
}
if ($mode -like 'timeout-*') { Start-Sleep -Seconds 30 }
$final = @{ type = 'assistant.message'; id = 'final'; timestamp = '2026-01-01T00:00:02Z'; data = @{ content = 'Code saved. Python/API self-tests complete.' } }
if ($mode -eq 'corrupt-recovered') {
    $directory = Join-Path $env:COPILOT_HOME "session-state\$session"
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $final | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath (Join-Path $directory 'events.jsonl')
} else { $final | ConvertTo-Json -Depth 8 -Compress }
if ($mode -eq 'failed-corrupt') { exit 7 }
exit 0
