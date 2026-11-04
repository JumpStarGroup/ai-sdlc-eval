#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$framework = Split-Path $PSScriptRoot
Import-Module (Join-Path $framework 'tools\DevDelivery.psm1') -Force
Import-Module (Join-Path $framework 'tools\DevExecution.psm1') -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('delivery-check-' + [guid]::NewGuid().ToString('N'))
try {
    $source = Join-Path $fixture 'source'
    $dependency = Join-Path $source 'node_modules\package'
    [void](New-Item -ItemType Directory -Path $dependency -Force)
    'dependency' | Set-Content -LiteralPath (Join-Path $dependency 'package.js')
    'implementation' | Set-Content -LiteralPath (Join-Path $source 'app.py')
    $hashes = Get-DeliveryHashes $source -MetadataOnlyPaths @('node_modules')
    Assert ($hashes['app.py'] -eq (Get-FileHash (Join-Path $source 'app.py')).Hash) 'Source must retain real content SHA256.'
    Assert ($hashes['node_modules/package/package.js'] -like 'metadata:*') 'Dependency metadata prefix must be explicit.'
    $app = Join-Path $source 'app.py'
    $time = [IO.File]::GetLastWriteTimeUtc($app)
    'Implementation' | Set-Content -LiteralPath $app
    [IO.File]::SetLastWriteTimeUtc($app, $time)
    $rejected = $false
    try { Assert-DeliveryHashes $hashes (Get-DeliveryHashes $source -MetadataOnlyPaths @('node_modules')) } catch { $rejected = $true }
    Assert $rejected 'Same-size and same-timestamp source edits must still be detected.'
    $inventory = Get-DeliveryHashes $dependency -MetadataOnly
    $added = Join-Path $dependency 'added.js'
    'added' | Set-Content -LiteralPath $added
    $rejected = $false
    try { Assert-DeliveryHashes $inventory (Get-DeliveryHashes $dependency -MetadataOnly) } catch { $rejected = $true }
    Assert $rejected 'Added dependency files must be detected.'
    Remove-Item -LiteralPath $added
    $package = Join-Path $dependency 'package.js'
    $packageTime = [IO.File]::GetLastWriteTimeUtc($package)
    [IO.File]::SetLastWriteTimeUtc($package, $packageTime.AddSeconds(2))
    $rejected = $false
    try { Assert-DeliveryHashes $inventory (Get-DeliveryHashes $dependency -MetadataOnly) } catch { $rejected = $true }
    Assert $rejected 'Dependency timestamp changes must be detected.'
    [IO.File]::SetLastWriteTimeUtc($package, $packageTime)
    $destination = Join-Path $fixture 'copied'
    $logs = Join-Path $fixture 'copy-logs'
    Copy-DevRuntime $source $destination @('node_modules') $logs
    Assert-DeliveryHashes (Get-DeliveryHashes (Join-Path $source 'node_modules')) (Get-DeliveryHashes (Join-Path $destination 'node_modules'))
    Assert-DeliveryHashes (Get-DeliveryHashes (Join-Path $source 'node_modules') -MetadataOnly) (Get-DeliveryHashes (Join-Path $destination 'node_modules') -MetadataOnly)
    $copy = Get-Content (Join-Path $logs '0.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert (-not $copy.execution.timedOut -and $copy.execution.durationSeconds -ge 0) 'Copy execution evidence must be recorded.'
    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        Assert ($copy.arguments -contains '/MT:16' -and $copy.arguments -contains '/COPY:DAT') 'Windows copies must use bounded parallelism and preserve timestamps.'
    }
    Remove-Item -LiteralPath $package
    $rejected = $false
    try { Assert-DeliveryHashes $inventory (Get-DeliveryHashes $dependency -MetadataOnly) } catch { $rejected = $true }
    Assert $rejected 'Deleted dependency files must be detected.'
    if ($IsWindows) {
        $link = Join-Path $source 'linked-package'
        [void](New-Item -ItemType Junction -Path $link -Target $dependency)
        try {
            $rejected = $false
            try { Get-DeliveryHashes $source -MetadataOnly | Out-Null } catch { $rejected = $true }
            Assert $rejected 'Metadata scans must reject linked directories.'
        } finally { [IO.Directory]::Delete($link) }
    }
    # Exercise process failure handling without waiting for a real ten-minute timeout.
    $module = Get-Module DevExecution
    foreach ($failure in @(
        @{ exitCode = 8; timedOut = $false; outputDrainIncomplete = $false; durationSeconds = 0 },
        @{ exitCode = -1; timedOut = $true; outputDrainIncomplete = $false; durationSeconds = 1 },
        @{ exitCode = 0; timedOut = $false; outputDrainIncomplete = $true; durationSeconds = 0 }
    )) {
        & $module {
            param($Failure)
            $script:copyFailure = $Failure
            function script:Invoke-CapturedProcess { return $script:copyFailure }
        } $failure
        $rejected = $false
        try { Copy-DevRuntime $source $destination @('node_modules') $logs -TimeoutSeconds 1 } catch { $rejected = $true }
        Assert $rejected 'Copy errors, timeouts and incomplete logs must all prevent success.'
    }
    Write-Host 'PASS: source hashes, dependency metadata, add/delete/change detection, link rejection, copy fidelity, recorded timings and fail-closed copy outcomes.'
} finally {
    Import-Module (Join-Path $framework 'tools\DevExecution.psm1') -Force
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
