#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConditionDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$TestBaseline,
    [string]$AdjustmentRecord
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
$condition = (Resolve-Path -LiteralPath $ConditionDirectory).Path
$configPath = Join-Path $condition 'config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
$sourceResult = Join-Path $config.runDirectory 'result.json'
$original = Get-Content -LiteralPath $sourceResult -Raw | ConvertFrom-Json -AsHashtable
$candidate = (Resolve-Path -LiteralPath $config.repositoryPath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Use a fresh offline output directory.' }
foreach ($protected in @($candidate, (Join-Path (Split-Path $condition) 'baseline'),
    $config.runDirectory, (Join-Path $condition 'verification'), (Join-Path $condition 'preflight'))) {
    $prefix = [IO.Path]::GetFullPath($protected).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (($output + [IO.Path]::DirectorySeparatorChar).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Offline output must not overwrite original evidence or product: $protected"
    }
}
for ($ancestor = $output; $ancestor; $ancestor = Split-Path $ancestor -Parent) {
    if (Test-Path -LiteralPath $ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Test-Path -LiteralPath (Join-Path $ancestor '.git'))) { throw 'Offline output must be outside Git repositories and links.' }
    }
}
if ($TestBaseline -and -not $AdjustmentRecord) { throw 'An alternate baseline requires an explicit adjustment record.' }
$baseline = if ($TestBaseline) { (Resolve-Path -LiteralPath $TestBaseline).Path }
    else { Join-Path (Split-Path $condition) 'baseline' }
$recordPath = if ($AdjustmentRecord) { (Resolve-Path -LiteralPath $AdjustmentRecord).Path } else { $null }
$before = Get-DevHashes $candidate $config.runtimeDirectories
$originalResultHash = (Get-FileHash -LiteralPath $sourceResult).Hash
[void](New-Item -ItemType Directory -Path $output)
$inputs = Join-Path $output 'inputs'
[void](New-Item -ItemType Directory -Path $inputs)
$frozenBaseline = Join-Path $inputs 'test-baseline'
Copy-DevSource $baseline $frozenBaseline
Copy-Item -LiteralPath $sourceResult -Destination (Join-Path $inputs 'original-result.json')
Copy-Item -LiteralPath $configPath -Destination $inputs
if ($recordPath) { Copy-Item -LiteralPath $recordPath -Destination (Join-Path $inputs 'adjustments.json') }
foreach ($name in @('Invoke-DevReverification.ps1', 'DevExecution.psm1', 'CapturedProcess.psm1', 'DialoguePolicy.psm1', 'Export-DevReport.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $inputs
}
$frozenAcceptance = Join-Path (Split-Path $condition) 'inputs\acceptance'
$acceptance = if (Test-Path -LiteralPath $frozenAcceptance -PathType Container) { $frozenAcceptance } else { $null }
$temp = Join-Path $output 'temp'
[void](New-Item -ItemType Directory -Path $temp)
$environment = @{
    TEMP = $temp; TMP = $temp; TMPDIR = $temp; PYTHONDONTWRITEBYTECODE = '1'; PYTHONNOUSERSITE = '1'
    PYTHONPATH = $null; PYTHONHOME = $null; DATABASE_URL = $null; JWT_SECRET = $null
    FLASK_APP = $null; FLASK_ENV = $null; PYTEST_ADDOPTS = $null; PYTEST_PLUGINS = $null
}
$result = $original.Clone()
$result['offline'] = $true
$result['originalOutcome'] = $original.outcome
$result['sourceResult'] = $sourceResult
$result['testBaseline'] = $baseline
$result['modelInvocationsThisRun'] = 0
$result['reverificationStartedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
$result['sourceIntegrityVerified'] = $false
$result['errors'] = @()
$result.scoring = @{ regressionPassRate = $null; acceptancePassRate = $null; modelScore = $null }
$result.verification = Invoke-DevVerification -Candidate $candidate -Baseline $frozenBaseline `
    -OutputDirectory (Join-Path $output 'verification') -Verification $config.verification `
    -RuntimeDirectories $config.runtimeDirectories -Environment $environment -AcceptanceDirectory $acceptance
$result.acceptanceConfigured = [bool]$acceptance
$result.acceptanceVerified = $null
foreach ($check in $result.verification.checks) {
    if ($check.name -eq 'regression') { $result.scoring.regressionPassRate = $check.passRate }
    if ($check.name -eq 'acceptance') {
        $result.scoring.acceptancePassRate = $check.passRate
        $result.acceptanceVerified = $check.passed
    }
}
$after = Get-DevHashes $candidate $config.runtimeDirectories
$result.sourceIntegrityVerified = $before.Count -eq $after.Count -and
    @($before.Keys | Where-Object { $before[$_] -cne $after[$_] }).Count -eq 0 -and
    (Get-FileHash -LiteralPath $sourceResult).Hash -ceq $originalResultHash
$result.outcome = if (-not $result.sourceIntegrityVerified) { 'source_changed_during_verification' }
    elseif (-not $result.verification.passed) { 'tests_failed' }
    else { 'offline_tests_passed' }
$result['reverificationFinishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
@{
    originalResultSha256 = $originalResultHash; candidateHashesBefore = $before; candidateHashesAfter = $after
    baselineHashes = (Get-DevHashes $frozenBaseline @()); modelInvocations = 0
} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $output 'manifest.json') -Encoding utf8
Export-DevStatusReport $result $output ([IO.Path]::GetFileName($condition) + ' offline')
& (Join-Path $PSScriptRoot 'Export-DevReport.ps1') -RunDirectory (Split-Path $condition) -ReverificationDirectory @($output)
Write-Host "Offline: execution=$($result.statusSummary.execution) (inherited); capture=$($result.statusSummary.capture) (inherited); tests=$($result.statusSummary.tests) ($($result.statusSummary.passed)/$($result.statusSummary.total))."
[pscustomobject]$result.statusSummary
if ($result.outcome -ne 'offline_tests_passed') { throw "Offline verification failed; inspect $output." }
