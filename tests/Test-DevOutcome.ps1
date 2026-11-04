#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\tools\DevExecution.psm1') -Force
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Fixture {
    @{
        result = @{
            model = 'fixture'; observedModels = @('fixture'); protectedChanges = @(); changedFiles = @(@{ path = 'app.py' })
            execution = @{ cliExitCode = 0; collectorExitCode = 1; timedOut = $false }
            capture = @{ complete = $false }; verification = @{ passed = $true }
        }
        runtime = @{ problems = @() }
        meta = @{ state = 'capture_incomplete'; outputDrainIncomplete = $false }
        diagnostics = @{ invalidRecords = @(@{ source = 'events.stdout'; line = 1 }); outputDrainIncomplete = $false; recoveredEventCount = 2 }
    }
}
foreach ($case in @('advisory', 'failed-tests', 'missing-runtime', 'missing-model', 'wrong-model', 'auto',
    'fusion', 'fusion-standard', 'fusion-high', 'fusion-max', 'legacy-fusion', 'fusion-selector-only',
    'missing-exit', 'failed-exit', 'timeout', 'protected', 'no-change', 'runtime-error', 'collector-fault',
    'unknown-diagnostics', 'canonical-damage', 'undrained', 'missing-drain-status', 'complete')) {
    $f = New-Fixture
    $expected = switch ($case) {
        'advisory' { 'stage_completed' }
        'failed-tests' { $f.result.verification.passed = $false; 'tests_failed' }
        'missing-runtime' { $f.runtime = $null; 'evidence_insufficient' }
        'missing-model' { $f.result.observedModels = @(); 'evidence_insufficient' }
        'wrong-model' { $f.result.observedModels = @('other'); 'model_mismatch' }
        'auto' { $f.result.model = 'auto'; 'stage_completed' }
        'fusion' { $f.result.model = 'fusion'; 'stage_completed' }
        'fusion-standard' { $f.result.model = 'fusion:standard'; 'stage_completed' }
        'fusion-high' { $f.result.model = 'fusion:high'; $f.result.observedModels = @('solver', 'judge'); 'stage_completed' }
        'fusion-max' { $f.result.model = 'fusion:max'; $f.result.observedModels = @('solver', 'judge'); 'stage_completed' }
        'legacy-fusion' { $f.result.model = 'hydrafusion'; 'stage_completed' }
        'fusion-selector-only' { $f.result.model = 'fusion:high'; $f.result.observedModels = @('fusion'); 'model_mismatch' }
        'missing-exit' { $f.result.execution.cliExitCode = $null; 'evidence_insufficient' }
        'failed-exit' { $f.result.execution.cliExitCode = 7; 'execution_failed' }
        'timeout' { $f.result.execution.timedOut = $true; 'timed_out' }
        'protected' { $f.result.protectedChanges = @('requirement.md'); 'protected_input_changed' }
        'no-change' { $f.result.changedFiles = @(); 'no_code_changes' }
        'runtime-error' { $f.runtime.problems = @(@{ type = 'session.error' }); 'runtime_failed' }
        'collector-fault' { $f.meta.state = 'capture_or_execution_failed'; 'evidence_insufficient' }
        'unknown-diagnostics' { $f.diagnostics = $null; 'evidence_insufficient' }
        'canonical-damage' { $f.diagnostics.invalidRecords += @{ source = 'session.events.jsonl'; line = 2 }; 'evidence_insufficient' }
        'undrained' { $f.meta.outputDrainIncomplete = $true; 'evidence_insufficient' }
        'missing-drain-status' { $f.meta.Remove('outputDrainIncomplete'); 'evidence_insufficient' }
        'complete' { $f.result.capture.complete = $true; $f.result.execution.collectorExitCode = 0; 'stage_completed' }
    }
    $actual = Get-DevOutcome $f.result $f.runtime $f.meta $f.diagnostics
    Assert ($actual -eq $expected) "${case}: expected $expected, got $actual"
    if ($case -in @('advisory', 'failed-tests', 'auto', 'no-change')) {
        Assert ($f.result.capture.nonBlocking -and -not $f.result.capture.complete -and
            $f.result.warnings[0].code -eq 'stdout_json_damage') "$case must retain non-blocking capture warning."
    }
    if ($case -eq 'complete') { Assert ($f.result.warnings.Count -eq 0) 'Complete capture must not invent a warning.' }
}
Write-Host 'PASS: Dev advisory capture damage and blocking execution, model, test and evidence failures.'
