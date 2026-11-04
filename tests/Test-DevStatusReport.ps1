#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\tools\DevExecution.psm1') -Force
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$directory = Join-Path ([IO.Path]::GetTempPath()) ('dev-status-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $directory)
    $result = @{
        outcome = 'capture_incomplete'; calls = 1; observedModels = @('fixture'); fusionPhases = @()
        acceptanceConfigured = $false; scoring = @{ regressionPassRate = 80.46; acceptancePassRate = $null }
        execution = @{ cliExitCode = 0; timedOut = $false; collectorExitCode = 1 }
        capture = @{ complete = $false; state = 'capture_incomplete' }
        verification = @{ passed = $false; error = $null; checks = @(
            @{ state = 'failed'; total = 87; passCount = 70; failures = 17; errors = 0; skipped = 0 }
        ) }
    }
    Export-DevStatusReport $result $directory 'fixture'
    $saved = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($saved.outcome -eq 'capture_incomplete' -and $saved.statusSummary.execution -eq 'succeeded' -and
        $saved.statusSummary.capture -eq 'incomplete' -and $saved.statusSummary.tests -eq 'failed' -and
        $saved.statusSummary.passed -eq 70 -and $saved.statusSummary.failures -eq 17) 'All simultaneous states must remain visible.'
    $text = Get-Content (Join-Path $directory 'summary.md') -Raw
    Assert ($text.Contains('| Execution | succeeded |') -and $text.Contains('| Capture | incomplete |') -and
        $text.Contains('| Tests | failed |') -and $text.Contains('failures: 17')) 'Markdown must show all three dimensions and failure counts.'
    $result.verification.passed = $true
    $result.verification.checks[0].state = 'passed'
    Assert ((Get-DevStatusSummary $result).tests -eq 'passed' -and (Get-DevStatusSummary $result).capture -eq 'incomplete') 'Tests cannot repair capture.'
    $result.execution.timedOut = $true
    $result.verification.checks[0].state = 'timed_out'
    Assert ((Get-DevStatusSummary $result).execution -eq 'timed_out' -and (Get-DevStatusSummary $result).tests -eq 'timed_out') 'Independent timeouts must be visible.'
    $result.execution.timedOut = $false
    $result.execution.cliExitCode = 7
    Assert ((Get-DevStatusSummary $result).execution -eq 'failed') 'CLI failure must not be hidden by collector status.'
    $result.verification.error = 'Missing interpreter'
    Assert ((Get-DevStatusSummary $result).tests -eq 'infrastructure_failed') 'Test infrastructure failures must be explicit.'
    $result.execution = $null; $result.capture = $null; $result.verification = $null
    Assert ((Get-DevStatusSummary $result).execution -eq 'not_run' -and
        (Get-DevStatusSummary $result).capture -eq 'not_run' -and (Get-DevStatusSummary $result).tests -eq 'not_run') 'Preflight rejection is not successful execution.'
    Write-Host 'PASS: three-dimensional Dev reports, simultaneous failures, timeouts and missing evidence.'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
