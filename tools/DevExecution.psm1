Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CapturedProcess.psm1')
Import-Module (Join-Path $PSScriptRoot 'DialoguePolicy.psm1')

function Assert-DevRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains(':') -or
        @($Path.Replace('\', '/').Split('/') | Where-Object { $_ -in @('', '.', '..', '.git', '.eval-tmp') }).Count) {
        throw "Expected a safe Dev workspace-relative path: $Path"
    }
}

function Copy-DevSource([string]$Source, [string]$Destination, [string[]]$RuntimeDirectories = @()) {
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($file in Get-DialogueWorkspaceFiles $Source -ExcludeDependencies -ExcludeRelativePaths (@('.eval-tmp', '.pytest_cache') + $RuntimeDirectories)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source file: $($file.FullName)" }
        $target = Join-Path $Destination ([IO.Path]::GetRelativePath($Source, $file.FullName))
        [void](New-Item -ItemType Directory -Path (Split-Path $target) -Force)
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

function Copy-DevRuntime {
    param(
        [string]$Source, [string]$Destination, [string[]]$Directories, [string]$LogDirectory,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 600
    )
    [void](New-Item -ItemType Directory -Path $LogDirectory -Force)
    $index = 0
    foreach ($relative in $Directories) {
        Assert-DevRelativePath $relative
        Write-Host "[$([DateTimeOffset]::UtcNow.ToString('o'))] Runtime copy: $relative -> $Destination"
        $from = Join-Path $Source $relative
        if (-not (Test-Path -LiteralPath $from -PathType Container)) { throw "Missing runtime directory: $from" }
        $to = Join-Path $Destination $relative
        [void](New-Item -ItemType Directory -Path $to -Force)
        $robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
        if ($robocopy) {
            $executable = $robocopy.Source
            $arguments = @($from, $to, '/E', '/XJ', '/R:1', '/W:1', '/MT:16', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NP')
        } else {
            $payload = @{ source = $from; destination = $to } | ConvertTo-Json -Compress
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
            $script = @'
$ErrorActionPreference = 'Stop'
$paths = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PATHS__')) | ConvertFrom-Json
Get-ChildItem -LiteralPath $paths.source -Force | Copy-Item -Destination $paths.destination -Recurse -Force
'@.Replace('__PATHS__', $encoded)
            $executable = (Get-Command pwsh -ErrorAction Stop).Source
            $arguments = @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script)))
        }
        $prefix = Join-Path $LogDirectory "$index"
        $execution = Invoke-CapturedProcess -Executable $executable -Arguments $arguments -WorkingDirectory $Source `
            -Prefix $prefix -TimeoutSeconds $TimeoutSeconds
        @{ source = $from; destination = $to; execution = $execution; arguments = $arguments } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$prefix.json" -Encoding utf8
        if ($execution.timedOut -or $execution.outputDrainIncomplete -or $execution.exitCode -lt 0 -or
            ($robocopy -and $execution.exitCode -ge 8) -or (-not $robocopy -and $execution.exitCode -ne 0)) {
            throw "Runtime copy failed: exit=$($execution.exitCode), timedOut=$($execution.timedOut), incomplete=$($execution.outputDrainIncomplete); inspect $prefix.json"
        }
        $index++
        Write-Host "[$([DateTimeOffset]::UtcNow.ToString('o'))] Runtime copy complete: $relative ($([math]::Round($execution.durationSeconds, 2))s)"
    }
}

function Get-DevHashes([string]$Repository, [string[]]$RuntimeDirectories) {
    $hashes = @{}
    foreach ($file in Get-DialogueWorkspaceFiles $Repository -ExcludeDependencies -ExcludeRelativePaths (@('.eval-tmp', '.pytest_cache') + $RuntimeDirectories)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source file: $($file.FullName)" }
        $relative = [IO.Path]::GetRelativePath($Repository, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}

function Invoke-DevVerification {
    param(
        [string]$Candidate, [string]$Baseline, [string]$OutputDirectory,
        [hashtable]$Verification, [string[]]$RuntimeDirectories,
        [hashtable]$Environment, [string]$AcceptanceDirectory, [switch]$Preflight,
        [switch]$UseCandidateTests, [string]$StateSource
    )
    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
    $report = @{ passed = $false; checks = @(); error = $null }
    try {
        $shadow = Join-Path $OutputDirectory 'product'
        Copy-DevSource $Candidate $shadow $RuntimeDirectories
        $stateDirectories = @($RuntimeDirectories | Where-Object { $_ -and $_ -notmatch '(^|[/\\])(\.venv|node_modules)$' })
        if ($stateDirectories.Count) {
            Copy-DevRuntime $(if ($StateSource) { $StateSource } else { $Candidate }) $shadow $stateDirectories (Join-Path $OutputDirectory 'state-copy')
        }
        $report['testBaseline'] = if ($UseCandidateTests) { 'candidate-latest' } else { 'frozen-historical' }
        foreach ($relative in $(if (-not $UseCandidateTests) { $Verification.testPaths })) {
            Assert-DevRelativePath $relative
            $target = Join-Path $shadow $relative
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            $original = Join-Path $Baseline $relative
            if (-not (Test-Path -LiteralPath $original)) { throw "Missing frozen regression tests: $relative" }
            [void](New-Item -ItemType Directory -Path (Split-Path $target) -Force)
            Copy-Item -LiteralPath $original -Destination $target -Recurse
        }
        foreach ($relative in $(if (-not $UseCandidateTests) { @('pytest.ini', 'pyproject.toml', 'setup.cfg', 'tox.ini', 'conftest.py') })) {
            $target = Join-Path $shadow $relative
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
            $original = Join-Path $Baseline $relative
            if (Test-Path -LiteralPath $original) { Copy-Item -LiteralPath $original -Destination $target }
        }
        $python = if ($Verification.pythonExecutable -match '[/\\]') {
            Assert-DevRelativePath $Verification.pythonExecutable
            (Resolve-Path -LiteralPath (Join-Path $Candidate $Verification.pythonExecutable)).Path
        } else {
            (Get-Command $Verification.pythonExecutable -ErrorAction Stop).Source
        }
        $envForTest = $Environment.Clone()
        $envForTest['PYTHONPATH'] = (Join-Path $shadow 'src') + [IO.Path]::PathSeparator + $shadow
        $envForTest['PYTEST_ADDOPTS'] = $null
        $envForTest['PYTEST_PLUGINS'] = $null
        $checks = @(@{ name = 'regression'; paths = @($Verification.testPaths) })
        if (-not $Preflight -and $AcceptanceDirectory) {
            $acceptance = Join-Path $shadow '.framework-acceptance'
            if (Test-Path -LiteralPath $acceptance) { Remove-Item -LiteralPath $acceptance -Recurse -Force }
            Copy-DevSource $AcceptanceDirectory $acceptance
            $checks += @{ name = 'acceptance'; paths = @($acceptance) }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        foreach ($check in $checks) {
            $entry = @{ name = $check.name; passed = $false; state = 'starting'; total = 0; failures = 0; errors = 0; skipped = 0; passCount = 0; passRate = $null }
            $report.checks += $entry
            $remaining = [int][Math]::Floor($Verification.timeoutSeconds - $clock.Elapsed.TotalSeconds)
            if ($remaining -lt 1) { $entry.state = 'timed_out'; continue }
            $xmlPath = Join-Path $OutputDirectory "$($check.name).xml"
            $arguments = @('-m', 'pytest') + $check.paths + @('-q', '--rootdir', $shadow, '--junitxml', $xmlPath)
            $entry['command'] = @{ executable = $python; arguments = $arguments; workingDirectory = $shadow }
            $execution = Invoke-CapturedProcess -Executable $python -Arguments $arguments -WorkingDirectory $shadow `
                -Prefix (Join-Path $OutputDirectory $check.name) -TimeoutSeconds $remaining -Environment $envForTest
            $entry['execution'] = $execution
            $entry.state = if ($execution.timedOut) { 'timed_out' } elseif ($execution.exitCode -ne 0) { 'failed' } else { 'evidence_incomplete' }
            if (Test-Path -LiteralPath $xmlPath -PathType Leaf) {
                $settings = [Xml.XmlReaderSettings]::new()
                $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $reader = [Xml.XmlReader]::Create($xmlPath, $settings)
                try { $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader) }
                finally { $reader.Dispose() }
                foreach ($test in $xml.SelectNodes('//testcase')) {
                    $entry.total++
                    if ($test.SelectSingleNode('failure')) { $entry.failures++ }
                    elseif ($test.SelectSingleNode('error')) { $entry.errors++ }
                    elseif ($test.SelectSingleNode('skipped')) { $entry.skipped++ }
                    else { $entry.passCount++ }
                }
                if ($entry.total -gt 0) { $entry.passRate = [Math]::Round(100.0 * $entry.passCount / $entry.total, 2) }
                $entry.passed = -not $execution.timedOut -and -not $execution.outputDrainIncomplete -and $execution.exitCode -eq 0 -and
                    $entry.passCount -gt 0 -and $entry.failures -eq 0 -and $entry.errors -eq 0
                if ($entry.passed) { $entry.state = 'passed' }
            }
        }
        $report.passed = @($report.checks | Where-Object { -not $_.passed }).Count -eq 0 -and $report.checks.Count -gt 0
    } catch {
        $report.error = $_.Exception.Message
        Write-Warning "Dev verification failed: $($report.error)"
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'checks.json') -Encoding utf8
    return $report
}

function Get-DevOutcome([hashtable]$Result, $Runtime, [hashtable]$Meta, $CaptureDiagnostics, [switch]$AllowNoChanges) {
    $Result['warnings'] = @()
    $Result.capture['nonBlocking'] = $false
    $Result['modelVerified'] = $false
    if ($Result.execution.timedOut) { return 'timed_out' }
    if ($Result.protectedChanges.Count) { return 'protected_input_changed' }
    if ($null -eq $Result.execution.cliExitCode) { return 'evidence_insufficient' }
    if ($Result.execution.cliExitCode -ne 0) { return 'execution_failed' }
    if (-not $Runtime) { return 'evidence_insufficient' }
    if (@($Runtime.problems | Where-Object { $_.type -in @('session.error', 'session.info') }).Count) {
        return 'runtime_failed'
    }
    $selectorPattern = '^(auto(?::[a-z0-9_-]+)?|fusion(?::standard|:high|:max)?|hydrafusion(?:-max)?)$'
    $automaticModel = $Result.model -imatch $selectorPattern
    $Result.modelVerified = $Result.observedModels.Count -gt 0 -and
        @($Result.observedModels | Where-Object { $_ -imatch $selectorPattern }).Count -eq 0 -and
        ($automaticModel -or ($Result.observedModels.Count -eq 1 -and $Result.observedModels[0] -ceq $Result.model))
    if (-not $Result.observedModels.Count) { return 'evidence_insufficient' }
    if (-not $Result.modelVerified) { return 'model_mismatch' }

    $invalidRecords = if ($CaptureDiagnostics) { @($CaptureDiagnostics['invalidRecords']) } else { @() }
    # Only diagnosed stdout parse damage is advisory. Other collector failures remain blocking.
    $stdoutDamageOnly = $Meta.state -eq 'capture_incomplete' -and
        $Result.execution.collectorExitCode -eq 1 -and $CaptureDiagnostics -and
        $invalidRecords.Count -gt 0 -and
        @($invalidRecords | Where-Object { $_.source -ne 'events.stdout' }).Count -eq 0 -and
        $Meta['outputDrainIncomplete'] -eq $false -and $CaptureDiagnostics['outputDrainIncomplete'] -eq $false
    if (-not $Result.capture.complete -or $Result.execution.collectorExitCode -ne 0) {
        if (-not $stdoutDamageOnly) { return 'evidence_insufficient' }
        $Result.capture.nonBlocking = $true
        $Result.warnings += @{
            code = 'stdout_json_damage'; invalidRecordCount = $invalidRecords.Count
            recoveredEventCount = $CaptureDiagnostics['recoveredEventCount']
            message = 'CLI stdout contains malformed events. Capture remains incomplete; observed model and independent test evidence are evaluated separately. Recovery does not prove full event coverage.'
        }
    }
    if (-not $AllowNoChanges -and -not $Result.changedFiles.Count) { return 'no_code_changes' }
    if (-not $Result.verification.passed) { return 'tests_failed' }
    return 'stage_completed'
}

function Get-DevStatusSummary([hashtable]$Result) {
    $execution = $Result['execution']
    $capture = $Result['capture']
    $verification = $Result['verification']
    $executionStatus = if (-not $execution) { 'not_run' }
        elseif ($execution['timedOut'] -eq $true) { 'timed_out' }
        elseif ($null -eq $execution['cliExitCode']) { 'unknown' }
        elseif ($execution.cliExitCode -eq 0) { 'succeeded' }
        else { 'failed' }
    $captureStatus = if (-not $capture) { 'not_run' }
        elseif ($capture['complete'] -eq $true) { 'complete' }
        else { 'incomplete' }
    $testStatus = if (-not $verification) { 'not_run' }
        elseif ($verification['error']) { 'infrastructure_failed' }
        elseif (@($verification.checks | Where-Object { $_.state -eq 'timed_out' }).Count) { 'timed_out' }
        elseif ($verification['passed'] -eq $true) { 'passed' }
        else { 'failed' }
    $summary = @{
        execution = $executionStatus; capture = $captureStatus; tests = $testStatus
        total = 0; passed = 0; failures = 0; errors = 0; skipped = 0
    }
    if ($verification) {
        foreach ($check in $verification.checks) {
            $summary.total += $check.total
            $summary.passed += $check.passCount
            $summary.failures += $check.failures
            $summary.errors += $check.errors
            $summary.skipped += $check.skipped
        }
    }
    return $summary
}

function Export-DevStatusReport([hashtable]$Result, [string]$Directory, [string]$Name) {
    $Result['statusSummary'] = Get-DevStatusSummary $Result
    $status = $Result.statusSummary
    $execution = $Result['execution']
    $capture = $Result['capture']
    $lines = @(
        "# Dev: $Name", '', "Overall outcome: $($Result.outcome)", '',
        '| Dimension | Status | Evidence |', '| --- | --- | --- |',
        "| Execution | $($status.execution) | CLI exit: $(if ($execution) { $execution['cliExitCode'] }); timed out: $(if ($execution) { $execution['timedOut'] }) |",
        "| Capture | $($status.capture) | Collector exit: $(if ($execution) { $execution['collectorExitCode'] }); state: $(if ($capture) { $capture['state'] }) |",
        "| Tests | $($status.tests) | Total: $($status.total); passed: $($status.passed); failures: $($status.failures); errors: $($status.errors); skipped: $($status.skipped) |",
        '', "Invocations: $($Result.calls)", "Observed models: $($Result.observedModels -join ', ')",
        "Acceptance configured: $($Result.acceptanceConfigured)",
        "Regression pass rate: $($Result.scoring.regressionPassRate)",
        "Acceptance pass rate: $($Result.scoring.acceptancePassRate)"
    )
    $phases = @($Result.fusionPhases | Where-Object { $_.data['phaseKind'] -and $_.data['model'] } |
        ForEach-Object { "$($_.data.phaseKind):$($_.data.model)" }) -join ', '
    $lines += "Fusion phases: $phases"
    if ($Result['offline']) {
        $lines += @('', 'Offline verification: no model invocation. Execution/capture status is inherited, not rerun.',
            "Original outcome: $($Result.originalOutcome)", "Original result: $($Result.sourceResult)",
            "Test baseline: $($Result.testBaseline)")
    }
    $lines += @('', 'Dimensions are independent; passing tests do not repair incomplete capture or prove full feature acceptance.',
        'Original logs and test XML are retained.')
    if ($Result['capture'] -and $Result.capture['nonBlocking']) {
        $lines += 'Capture warning (non-blocking): diagnosed stdout JSON damage does not determine Dev acceptance. Capture is still incomplete.'
    }
    foreach ($warning in @($Result['warnings'])) {
        if ($warning) { $lines += "Warning: $($warning.code): $($warning.message)" }
    }
    $Result | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath (Join-Path $Directory 'result.json') -Encoding utf8
    $lines | Set-Content -LiteralPath (Join-Path $Directory 'summary.md') -Encoding utf8
}

Export-ModuleMember -Function Assert-DevRelativePath, Copy-DevSource, Copy-DevRuntime, Get-DevHashes, Invoke-DevVerification, Get-DevOutcome, Get-DevStatusSummary, Export-DevStatusReport
