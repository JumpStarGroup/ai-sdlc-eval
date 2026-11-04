#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConditionDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1, 86400)][int]$MaxSeconds = 180
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevDelivery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1') -Force
$condition = (Resolve-Path -LiteralPath $ConditionDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
Assert-DeliveryOutput $output (Split-Path $condition)
Assert-DeliveryOutput $output (Split-Path $PSScriptRoot)
if (Test-Path -LiteralPath $output) { throw 'Use a fresh benchmark directory.' }
$source = Get-DevDeliverySource $condition
Assert-DeliveryOutput $output $source.workspace
[void](New-Item -ItemType Directory -Path $output)
$timer = [Diagnostics.Stopwatch]::StartNew()
$report = @{
    sourceCondition = $condition; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    modelCallsStarted = $false; productTestsRun = $false; maxSeconds = $MaxSeconds
    passed = $false; stages = @{}; error = $null
}
try {
    $delivery = Join-Path $output 'delivery'
    $manifest = New-DevDelivery $condition $delivery
    $report.stages.freezeSeconds = $timer.Elapsed.TotalSeconds
    $stageStart = $timer.Elapsed.TotalSeconds
    $manifest = Read-DevDelivery $delivery
    $report.stages.readSeconds = $timer.Elapsed.TotalSeconds - $stageStart
    $stageStart = $timer.Elapsed.TotalSeconds
    $workspace = Join-Path $output 'test-product'
    Copy-DevDeliveryWorkspace $delivery $manifest $workspace (Join-Path $output 'test-copy')
    $report.stages.testWorkspaceSeconds = $timer.Elapsed.TotalSeconds - $stageStart
    Assert-DeliveryHashes $source.hashes (Get-DevHashes $source.workspace @($source.config.runtimeDirectories))
    if ((Get-FileHash -LiteralPath $source.resultPath).Hash -cne $manifest.sourceResultSha256) { throw 'Source Dev evidence changed during benchmark.' }
    $report['integrityPolicy'] = $manifest.integrityPolicy
    $report['dependencyFileCount'] = @($manifest.hashes.Values | Where-Object { $_ -like 'metadata:*' }).Count
    $report['sourceUnchanged'] = $true
    $report.passed = $timer.Elapsed.TotalSeconds -le $MaxSeconds
    if (-not $report.passed) { throw "Delivery preparation exceeded the ${MaxSeconds}s benchmark target." }
} catch {
    $report.error = $_.Exception.Message
    $report.passed = $false
    throw
} finally {
    $report['durationSeconds'] = $timer.Elapsed.TotalSeconds
    $report['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'benchmark.json') -Encoding utf8
}
[pscustomobject]$report
