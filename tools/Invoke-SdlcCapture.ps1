#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$RepositoryPath = (Get-Location).Path,
    [ValidatePattern('^[\w-]+$')][string]$Agent = 'pilotRole_Product_Manager',
    [string]$Model,
    [string]$AutoTier,
    [string]$ReasoningEffort,
    [string[]]$AvailableTool = @(),
    [switch]$NoTools,
    [switch]$DisableBuiltinMcps,
    [switch]$NoCustomInstructions,
    [switch]$RecoverLocalPatchErrors,
    [string]$CopilotHome,
    [hashtable]$ProcessEnvironment = @{},
    [string[]]$AllowTool = @(),
    [string[]]$DenyTool = @(),
    [ValidatePattern('^[\w.-]+/[\w.-]+$')][string]$GitHubRepository,
    [int[]]$IssueNumber = @(),
    [int[]]$PullRequestNumber = @(),
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900,
    [string]$CliPath = 'copilot',
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:enableFusionFeatureFlags = $false
Import-Module (Join-Path $PSScriptRoot 'CapturedProcess.psm1') -Force

function Write-Json($Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-CliIsolationArguments([string]$HelpText) {
    $options = @([regex]::Matches($HelpText, '(?m)^\s+(--[a-z0-9-]+)(?=[\s\[=<]|$)') |
        ForEach-Object { $_.Groups[1].Value })
    if ('--disallow-temp-dir' -notin $options) {
        throw 'CLI cannot enforce the required temporary-directory policy; --disallow-temp-dir is unavailable.'
    }
    if ('--sync-session' -in $options) {
        return @('--disallow-temp-dir', '--sync-session=off')
    }
    if ('--no-remote' -in $options -and '--no-remote-export' -in $options) {
        return @('--disallow-temp-dir', '--no-remote', '--no-remote-export')
    }
    throw 'CLI has no recognized session-sync disable option. Refusing to run with an implicit sharing default.'
}

function Read-CaptureEvents([string]$Path, [string]$Source, $Diagnostics) {
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = ConvertFrom-Json -InputObject $line -AsHashtable
            if ($event -isnot [System.Collections.IDictionary] -or $event['type'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($event.type)) { throw 'Expected an event object with a nonempty type.' }
            $event
        } catch {
            $Diagnostics.Add(@{ source = $Source; line = $lineNumber; error = $_.Exception.Message })
        }
    }
}

function Test-RecoverableReadFailure($Start, $Data) {
    if ($NoTools -or -not $Start -or $Start.toolName -cne 'view' -or
        $Data['error'] -isnot [System.Collections.IDictionary] -or
        $Data.error['code'] -cne 'failure' -or
        $Data.error['message'] -cnotin @('Path does not exist', 'view_range out of bounds') -or
        $Start.arguments -isnot [System.Collections.IDictionary] -or
        $Start.arguments['path'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Start.arguments.path)) {
        return $false
    }
    try {
        $path = [IO.Path]::GetFullPath($Start.arguments.path, $script:repository)
        $root = $script:repository.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current = $path
        while ($current) {
            if (Test-Path -LiteralPath $current) {
                if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    return $false
                }
            }
            $current = Split-Path $current -Parent
        }
        return $true
    }
    catch { return $false }
}

function Get-LocalPatchUpdatePath($Start) {
    if ($NoTools -or -not $Start -or -not $Start.root -or $Start.toolName -cne 'apply_patch' -or $Start.arguments -isnot [string]) { return $null }
    $headers = [regex]::Matches($Start.arguments, '(?m)^\*\*\* (Update File|Add File|Delete File|Move to): (.+)\r?$')
    if ($headers.Count -ne 1 -or $headers[0].Groups[1].Value -cne 'Update File') { return $null }
    try {
        $path = [IO.Path]::GetFullPath($headers[0].Groups[2].Value.Trim(), $script:repository)
        $root = $script:repository.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $current = $path
        while ($current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
            $current = Split-Path $current -Parent
        }
        return $path
    } catch { return $null }
}

function Invoke-Captured($Executable, [string[]]$Arguments, $Prefix, [int]$Timeout = 60, [string]$InputText) {
    $environment = if (Get-Variable ProcessEnvironment -ErrorAction SilentlyContinue) { $ProcessEnvironment.Clone() } else { @{} }
    # A caller's broad auto-approval must not override the recorded allow list.
    foreach ($name in @('COPILOT_ALLOW_ALL', 'COPILOT_ASSISTED_APPROVAL')) {
        $environment[$name] = $null
    }
    if ($CopilotHome) {
        $environment['COPILOT_HOME'] = $CopilotHome
        foreach ($name in @('COPILOT_CUSTOM_INSTRUCTIONS_DIRS', 'COPILOT_MODEL', 'COPILOT_AUTO_TIER')) {
            $environment[$name] = $null
        }
    }
    if ($script:enableFusionFeatureFlags) {
        $environment['COPILOT_CLI_ENABLED_FEATURE_FLAGS'] = 'DYNAMIC_AUTO_TIERS,HYDRAFUSION,HYDRAFUSION_ROLLOUT,HYDRAFUSION_TURN_POLICY,HYDRAFUSION_REPAIR_WRITE_RECEIPTS,HYDRAFUSION_PLAN_V2'
    }
    $parameters = @{
        Executable = $Executable; Arguments = $Arguments; Prefix = $Prefix
        WorkingDirectory = $script:repository; TimeoutSeconds = $Timeout; Environment = $environment
    }
    if ($PSBoundParameters.ContainsKey('InputText')) { $parameters.InputText = $InputText }
    Invoke-CapturedProcess @parameters
}

function Invoke-EvidenceCommand($Executable, [string[]]$Arguments, $Prefix) {
    $result = Invoke-Captured $Executable $Arguments $Prefix
    if ($result.exitCode -ne 0 -or $result.timedOut) {
        throw "Evidence command failed: $Executable; inspect $Prefix.stderr"
    }
    return (Get-Content -LiteralPath "$Prefix.stdout" -Raw)
}

function Save-Snapshot($Name) {
    $directory = Join-Path $script:turn $Name
    [void](New-Item -ItemType Directory -Path $directory)
    $head = Invoke-EvidenceCommand 'git' @('rev-parse', 'HEAD') (Join-Path $directory 'head')
    $branch = Invoke-EvidenceCommand 'git' @('branch', '--show-current') (Join-Path $directory 'branch')
    $status = Invoke-EvidenceCommand 'git' @('status', '--porcelain=v1', '--untracked-files=all') (Join-Path $directory 'status')
    $paths = Invoke-EvidenceCommand 'git' @('ls-files', '--cached', '--others', '--exclude-standard', '-z') (Join-Path $directory 'paths')
    $config = @()
    $workingFiles = @()
    foreach ($relative in ($paths -split "`0" | Where-Object { $_ } | Sort-Object -Unique)) {
        $source = Join-Path $script:repository $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $workingFiles += @{ path = $relative; sha256 = $hash }
        if ($relative -match '(^|/)AGENTS\.md$|^\.github/(agents/.*\.agent\.md|copilot-instructions\.md|instructions/.*\.md)$|^docs/templates/[^/]+\.md$') {
            $destination = Join-Path $directory "config\$relative"
            [void](New-Item -ItemType Directory -Path (Split-Path $destination) -Force)
            Copy-Item -LiteralPath $source -Destination $destination
            $config += @{ path = $relative; sha256 = $hash }
        }
    }
    Write-Json (Join-Path $directory 'workspace.json') @{
        head = $head.Trim(); branch = $branch.Trim(); status = $status
        files = $workingFiles; config = $config
        coverage = 'Non-ignored Git files only; deleted files are represented in status. User/global settings and ignored files are not captured.'
    }
    if ($GitHubRepository) {
        # Repository activity is evidence, not proof that this run caused every change.
        $apiArgs = @('api', "repos/$GitHubRepository/issues", '--method', 'GET',
            '-f', 'state=all', '-f', "since=$($script:run.startedAt)", '-f', 'per_page=100', '--paginate', '--slurp')
        [void](Invoke-EvidenceCommand 'gh' $apiArgs (Join-Path $directory 'github-activity'))
        foreach ($number in $IssueNumber) {
            [void](Invoke-EvidenceCommand 'gh' @('issue', 'view', "$number", '--repo', $GitHubRepository,
                '--json', 'number,url,title,body,state,labels,comments,updatedAt') (Join-Path $directory "issue-$number"))
        }
        foreach ($number in $PullRequestNumber) {
            $prArgs = @('pr', 'view', "$number", '--repo', $GitHubRepository,
                '--json', 'number,url,title,body,state,isDraft,headRefName,baseRefName,commits,comments,reviews,files')
            [void](Invoke-EvidenceCommand 'gh' $prArgs (Join-Path $directory "pr-$number"))
        }
    }
    return $config
}

$repository = (Resolve-Path -LiteralPath $RepositoryPath).Path
if ($NoTools -and $AvailableTool.Count) { throw 'NoTools cannot be combined with AvailableTool.' }
if ($CopilotHome) { $CopilotHome = [IO.Path]::GetFullPath($CopilotHome) }
$prompt = Get-Content -LiteralPath (Resolve-Path -LiteralPath $PromptFile).Path -Raw -Encoding utf8
if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Prompt must not be empty.' }
$output = [IO.Path]::GetFullPath($RunDirectory)
if ($output.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($repository.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'RunDirectory must be outside the repository to avoid contaminating the task context.'
}
if (-not (Test-Path -LiteralPath (Join-Path $repository ".github\agents\$Agent.agent.md"))) {
    throw "Local Agent file not found: $Agent"
}
if (($IssueNumber.Count -or $PullRequestNumber.Count) -and -not $GitHubRepository) {
    throw 'Explicit GitHub resources require GitHubRepository.'
}
$cli = (Get-Command $CliPath -ErrorAction Stop).Source
if ($cli.EndsWith('.ps1')) {
    $executable = (Get-Command pwsh -ErrorAction Stop).Source
    $launcher = @('-NoProfile', '-File', $cli)
}
elseif ($cli.EndsWith('.cmd') -or $cli.EndsWith('.bat')) {
    throw 'Use the copilot.ps1 shim or native executable, not a cmd/bat shell wrapper.'
}
else { $executable = $cli; $launcher = @() }

$runFile = Join-Path $output 'run.json'
$environmentEntries = @($ProcessEnvironment.Keys | Sort-Object | ForEach-Object {
    [ordered]@{ name = $_; value = $ProcessEnvironment[$_] }
})
$environmentJson = ConvertTo-Json -InputObject $environmentEntries -Depth 5 -Compress
$environmentFingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($environmentJson)))
$policy = [ordered]@{
    reasoningEffort = $ReasoningEffort; availableTools = @($AvailableTool)
    noTools = [bool]$NoTools; disableBuiltinMcps = [bool]$DisableBuiltinMcps
    noCustomInstructions = [bool]$NoCustomInstructions; copilotHome = $CopilotHome
    promptTransport = 'utf8-stdin-v1'
    cliIsolationPolicy = 'help-detected-v1'
    recoverLocalPatchErrors = [bool]$RecoverLocalPatchErrors
    processEnvironmentFingerprint = $environmentFingerprint
} | ConvertTo-Json -Depth 5 -Compress
if ($Resume) {
    $run = Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json -AsHashtable
    if ($run.repository -ne $repository -or $run.agent -ne $Agent -or $run.model -ne $Model -or
        $run.githubRepository -ne $GitHubRepository -or
        ($run.allowTool -join "`n") -ne ($AllowTool -join "`n") -or
        ($run.denyTool -join "`n") -ne ($DenyTool -join "`n")) {
        throw 'Resume requires the same repository, Agent, model, GitHub repository and tool policy.'
    }
    if ($run['policy'] -ne $policy) { throw 'Resume requires the same runtime isolation and tool policy; legacy runs need a new directory.' }
}
else {
    if (Test-Path -LiteralPath $output) { throw 'Use a new RunDirectory, or Resume an existing run.' }
    [void](New-Item -ItemType Directory -Path $output)
    $run = @{
        schemaVersion = 1; sessionId = [guid]::NewGuid().ToString()
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        repository = $repository; agent = $Agent; model = $Model
        githubRepository = $GitHubRepository; allowTool = $AllowTool; denyTool = $DenyTool
        policy = $policy
        inheritedConfiguration = 'User/global CLI, MCP, skills and model defaults are not snapshotted. Effective exposure must be checked in runtime evidence.'
    }
    Write-Json $runFile $run
}
$lock = [IO.File]::Open((Join-Path $output 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$turn = Join-Path $output ("turn-" + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $turn)
$meta = @{
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); state = 'starting'
    sessionId = $run.sessionId; resume = [bool]$Resume
    requestedAgent = $Agent; requestedModel = $Model
    timeoutSeconds = $TimeoutSeconds
    collectorSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    evaluation = 'not_scored'; errors = @()
}
$exitCode = 1
try {
    $prompt | Set-Content -LiteralPath (Join-Path $turn 'input.txt') -Encoding utf8 -NoNewline
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $turn 'collector.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CapturedProcess.psm1') -Destination $turn
    Write-Json (Join-Path $turn 'turn.json') $meta
    $meta.cliVersion = (Invoke-EvidenceCommand $executable ($launcher + @('--no-auto-update', '--version')) (Join-Path $turn 'version')).Trim()
    $isolationArguments = @()
    if ($CopilotHome) {
        $cliHelp = Invoke-EvidenceCommand $executable ($launcher + @('--no-auto-update', '--help')) (Join-Path $turn 'help')
        $isolationArguments = @(Get-CliIsolationArguments $cliHelp)
        $meta['cliIsolation'] = @{
            policy = 'help-detected-v1'; arguments = $isolationArguments; helpEvidence = 'help.stdout'
            incomingControl = 'No connect or hosting options requested; session sync is disabled, not an OS sandbox.'
        }
    }
    $config = @(Save-Snapshot 'before')
    $fingerprint = ($config | Sort-Object { $_.path } | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n"
    if ($Resume -and ($run.configFingerprint -ne $fingerprint -or $run.cliVersion -ne $meta.cliVersion)) {
        throw 'Agent/instruction/template content or CLI version changed. Start a new run.'
    }
    $run.configFingerprint = $fingerprint
    $run.cliVersion = $meta.cliVersion
    Write-Json $runFile $run
    $effectiveCliModel = $Model
    $effectiveAutoTier = $AutoTier
    $script:enableFusionFeatureFlags = $false
    if ($Model -imatch '^fusion(?::(?<tier>standard|high|max))?$') {
        $fusionTier = if ($Matches['tier']) { $Matches['tier'].ToLowerInvariant() } else { 'standard' }
        $routingTier = @{ standard = 'balance'; high = 'hydrafusion'; max = 'hydrafusion-max' }[$fusionTier]
        if ($AutoTier -and $AutoTier -ine $routingTier) {
            throw "Fusion $fusionTier requires routing profile '$routingTier', not '$AutoTier'."
        }
        $effectiveCliModel = 'auto'
        $effectiveAutoTier = $routingTier
        $meta['requestedFusionTier'] = $fusionTier
    } elseif ($Model -imatch '^fusion:') {
        throw 'Unknown Fusion tier. Use fusion:standard, fusion:high or fusion:max.'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveAutoTier) -and $Model) {
        if ($Model -imatch '^(?<tier>hydrafusion(?:-max)?)$') {
            $effectiveCliModel = $Matches['tier'].ToLowerInvariant()
            $script:enableFusionFeatureFlags = $true
        } elseif ($Model -imatch '^auto:(?<tier>[a-z0-9_-]+)$') {
            $effectiveCliModel = 'auto'
            $effectiveAutoTier = $Matches['tier'].ToLowerInvariant()
            $script:enableFusionFeatureFlags = $true
        }
    }
    if ($effectiveAutoTier) {
        $meta['requestedAutoTier'] = $effectiveAutoTier
        $script:enableFusionFeatureFlags = -not ($meta['requestedFusionTier'] -eq 'standard')
    }
    $meta['effectiveCliModel'] = $effectiveCliModel
    if ($script:enableFusionFeatureFlags -and $CopilotHome) {
        [void](New-Item -ItemType Directory -Path $CopilotHome -Force)
        $sandboxConfigPath = Join-Path $CopilotHome 'config.json'
        $hostConfigPath = Join-Path $HOME '.copilot/config.json'
        if (-not (Test-Path -LiteralPath $sandboxConfigPath) -and (Test-Path -LiteralPath $hostConfigPath -PathType Leaf)) {
            try {
                $hostRaw = Get-Content -LiteralPath $hostConfigPath -Raw -Encoding utf8
                $hostJson = ($hostRaw -replace '(?m)^\s*//.*$', '') | ConvertFrom-Json -AsHashtable
                $seedConfig = @{ staff = [bool]$hostJson['staff'] }
                if ($hostJson['expAssignmentsCache']) { $seedConfig['expAssignmentsCache'] = $hostJson['expAssignmentsCache'] }
                if ($hostJson['firstLaunchAt']) { $seedConfig['firstLaunchAt'] = $hostJson['firstLaunchAt'] }
                ConvertTo-Json -InputObject $seedConfig -Depth 20 | Set-Content -LiteralPath $sandboxConfigPath -Encoding utf8
            } catch { }
        }
    }
    $cliArgs = @('-C', $repository, '--agent', $Agent, '--session-id', $run.sessionId,
        '--output-format', 'json', '--stream', 'off', '--no-auto-update',
        '--log-dir', (Join-Path $turn 'cli-logs'),
        '--usage-output-file', (Join-Path $turn 'usage.json'))
    if ($effectiveCliModel) { $cliArgs += @('--model', $effectiveCliModel) }
    if ($effectiveAutoTier) { $cliArgs += @('--auto-tier', $effectiveAutoTier) }
    if ($script:enableFusionFeatureFlags) { $cliArgs += '--experimental' }
    if ($ReasoningEffort) { $cliArgs += @('--reasoning-effort', $ReasoningEffort) }
    if ($NoTools -or $AvailableTool.Count) {
        $cliArgs += '--available-tools'
        if (-not $NoTools) { $cliArgs += $AvailableTool }
    }
    if ($DisableBuiltinMcps) { $cliArgs += '--disable-builtin-mcps' }
    if ($NoCustomInstructions) { $cliArgs += '--no-custom-instructions' }
    $cliArgs += $isolationArguments
    foreach ($tool in $AllowTool) { $cliArgs += @('--allow-tool', $tool) }
    foreach ($tool in $DenyTool) { $cliArgs += @('--deny-tool', $tool) }
    $meta.command = @{
        executable = $executable; arguments = @($launcher + $cliArgs)
        transport = 'utf8-stdin-v1'
        launcherTransport = if ($launcher.Count) { 'powershell-encoded-arguments' } else { 'native-argument-list' }
        inputFile = 'input.txt'; inputCharacters = $prompt.Length
    }
    $meta.state = 'running'
    Write-Json (Join-Path $turn 'turn.json') $meta
    Write-Host "Capturing CLI session $($run.sessionId) in $turn"
    $result = Invoke-Captured $executable ($launcher + $cliArgs) (Join-Path $turn 'events') $TimeoutSeconds -InputText $prompt
    $meta.cliExitCode = $result.exitCode
    $meta.timedOut = $result.timedOut
    $meta.outputDrainIncomplete = $result.outputDrainIncomplete
    $meta.executionDurationSeconds = $result.durationSeconds
    $exitCode = if ($result.timedOut) { 124 } else { $result.exitCode }
    $meta.state = if ($exitCode -eq 0) { 'cli_exited' } else { 'execution_failed' }
    $count = 0
    $messages = @()
    $observedModels = @()
    $fusionPhases = @()
    $usage = @()
    $runtimeProblems = @()
    $runtimeWarnings = @()
    $readCandidates = @()
    $patchCandidates = @()
    $shellCandidates = @()
    $toolSnapshots = @()
    $disabledTools = @()
    $lastFinalSequence = 0
    $lastToolSequence = 0
    $lastFinalEventId = $null
    $toolCalls = @{}
    $parseDiagnostics = [Collections.Generic.List[object]]::new()
    $events = @(Read-CaptureEvents (Join-Path $turn 'events.stdout') 'events.stdout' $parseDiagnostics)
    $stdoutEventCount = $events.Count
    $recoveredEventCount = 0
    if ($parseDiagnostics.Count -and $CopilotHome) {
        $canonical = Join-Path $CopilotHome "session-state\$($run.sessionId)\events.jsonl"
        if (Test-Path -LiteralPath $canonical -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $canonical -Destination (Join-Path $turn 'session.events.jsonl')
                $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($event in $events) { if ($event['id']) { [void]$ids.Add($event.id) } }
                $recovered = @(Read-CaptureEvents (Join-Path $turn 'session.events.jsonl') 'session.events.jsonl' $parseDiagnostics |
                    Where-Object { $_['id'] -and $ids.Add($_.id) })
                $recoveredEventCount = $recovered.Count
                $events = @(@($events) + @($recovered) | Sort-Object { $_['timestamp'] } -Stable)
            } catch {
                $parseDiagnostics.Add(@{ source = 'session.events.jsonl'; line = $null; error = $_.Exception.Message })
            }
        }
    }
    $captureComplete = $parseDiagnostics.Count -eq 0 -and $events.Count -gt 0 -and -not $result.outputDrainIncomplete
    $meta.captureComplete = $captureComplete
    if (-not $captureComplete) {
        $meta.errors += 'Incomplete CLI evidence; inspect capture-diagnostics.json and original output.'
        if ($exitCode -eq 0) { $exitCode = 1; $meta.state = 'capture_incomplete' }
    }
    Write-Json (Join-Path $turn 'capture-diagnostics.json') @{
        complete = $captureComplete; stdoutEventCount = $stdoutEventCount
        recoveredEventCount = $recoveredEventCount; invalidRecords = @($parseDiagnostics.ToArray())
        outputDrainIncomplete = $result.outputDrainIncomplete
    }
    $modelCalls = @()
    foreach ($event in $events) {
        $data = if ($event['data'] -is [System.Collections.IDictionary]) { $event['data'] } else { @{} }
        $count++
        if ($event.type -eq 'session.info' -and $data['infoType'] -eq 'configuration' -and $data['message'] -match '^Disabled tools: (.*)$') {
            $disabledTools += @{ eventId = $event['id']; names = @($Matches[1] -split ',\s*') }
        }
        if ($event.type -eq 'prompt_cache_break') {
            foreach ($side in @('beforeRequest', 'afterRequest')) {
                $snapshot = $data[$side]
                if ($snapshot -is [System.Collections.IDictionary] -and $snapshot['tools'] -is [array]) {
                    $toolSnapshots += @{ eventId = $event['id']; side = $side; model = $snapshot['model']; truncated = $snapshot['tools_truncated']; names = @($snapshot.tools | ForEach-Object { $_.name }) }
                }
            }
        }
        if ($event.type -eq 'assistant.message' -and $data['content'] -and
            -not $event['agentId'] -and -not $data['parentToolCallId']) {
            $messages += @{
                eventId = $event['id']; content = $data['content']
                hasToolRequests = [bool]$data['toolRequests']
            }
            $lastFinalSequence = 0
            if (-not $data['toolRequests'] -and -not [string]::IsNullOrWhiteSpace($data.content)) {
                $lastFinalSequence = $count
                $lastFinalEventId = $event['id']
            }
        }
        if ($event.type -like 'assistant.fusion_phase_*' -or $event.type -like 'session.fusion_*') {
            $fusionPhases += @{ eventId = $event['id']; type = $event.type; data = $data }
            foreach ($modelKey in @('model', 'sourceModel', 'targetModel', 'finalSourceModel', 'followUpModel')) {
                if ($data[$modelKey] -is [string] -and -not [string]::IsNullOrWhiteSpace($data[$modelKey])) {
                    $observedModels += $data[$modelKey]
                }
            }
            if ($data['critics'] -is [array]) {
                foreach ($critic in $data['critics']) {
                    if ($critic -is [System.Collections.IDictionary] -and $critic['model']) {
                        $observedModels += $critic['model']
                    }
                }
            }
        }
        if (-not $event['agentId'] -and -not $data['parentToolCallId']) {
            if ($event.type -eq 'assistant.usage') {
                $observedModels += $data['model']
                if ($data['fusion'] -is [System.Collections.IDictionary] -and $data.fusion['model']) {
                    $observedModels += $data.fusion['model']
                }
                $usage += @{
                    model = $data['model']; inputTokens = $data['inputTokens']
                    outputTokens = $data['outputTokens']; duration = $data['duration']
                    fusion = $data['fusion']
                }
            }
            if ($event.type -eq 'model.call_start') { $observedModels += $data['model'] }
        }
        if ($event.type -in @('tool.execution_start', 'tool.execution_complete')) { $lastToolSequence = $count }
        if ($event.type -eq 'tool.execution_start' -and $data['toolCallId']) {
            $toolCalls[$data.toolCallId] = @{
                toolName = $data['toolName']; arguments = $data['arguments']
                root = (-not $event['agentId'] -and -not $data['parentToolCallId'])
                startedAt = $event['timestamp']; completedAt = $null; success = $null; error = $null
            }
        }
        if ($event.type -eq 'tool.execution_complete' -and $data['toolCallId'] -and $toolCalls.ContainsKey($data.toolCallId)) {
            $toolCalls[$data.toolCallId].completedAt = $event['timestamp']
            $toolCalls[$data.toolCallId].success = $data['success']
            $toolCalls[$data.toolCallId].error = $data['error']
        }
        if ($event.type -like 'model.call_*') {
            $modelCalls += @{ eventId = $event['id']; type = $event.type; timestamp = $event['timestamp']
                model = $data['model']; duration = $data['duration']; error = $data['error'] }
        }
        $recoverable = $false
        $start = if ($data['toolCallId']) { $toolCalls[$data.toolCallId] } else { $null }
        if ($RecoverLocalPatchErrors -and $event.type -eq 'tool.execution_complete' -and $data['success'] -eq $true -and
            $start -and $start.root -and -not $event['agentId'] -and -not $data['parentToolCallId']) {
            if ($start.toolName -ceq 'view' -and $start.arguments -is [System.Collections.IDictionary] -and $start.arguments['path']) {
                try {
                    $readPath = [IO.Path]::GetFullPath($start.arguments.path, $script:repository)
                    foreach ($candidate in $patchCandidates) {
                        if ($candidate.path -ieq $readPath -and -not $candidate['recoveryEventId']) { $candidate['rereadEventId'] = $event['id'] }
                    }
                } catch { }
            }
            $updatedPath = Get-LocalPatchUpdatePath $start
            if ($updatedPath) {
                $edits = @($data['fileEdits'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['kind'] -eq 'edit' -and $_['path'] })
                $sameEdit = @($edits | Where-Object { [IO.Path]::GetFullPath($_.path, $script:repository) -ieq $updatedPath }).Count -gt 0
                foreach ($candidate in $patchCandidates) {
                    if ($sameEdit -and $candidate.path -ieq $updatedPath -and $candidate['rereadEventId']) {
                        $candidate['recoveryEventId'] = $event['id']
                        $candidate['recoveredHash'] = (Get-FileHash -LiteralPath $updatedPath).Hash
                    }
                }
            }
        }
        if ($event.type -eq 'tool.execution_complete' -and $data['success'] -eq $false -and $data['toolCallId']) {
            $start = $toolCalls[$data.toolCallId]
            if ($start -and $start.root -and -not $event['agentId'] -and -not $data['parentToolCallId']) {
                $recoverable = Test-RecoverableReadFailure $start $data
            }
            if ($recoverable) {
                $readCandidates += @{
                    eventId = $event['id']; type = $event.type; data = $data
                    category = 'recoverable_local_read_error'
                    toolName = $start.toolName; arguments = $start.arguments
                }
            }
            elseif ($RecoverLocalPatchErrors -and $data['error'] -is [System.Collections.IDictionary] -and
                $data.error['code'] -ceq 'failure' -and $data.error['message'] -is [string] -and
                $data.error.message.StartsWith('Failed to apply patch: Error: Failed to find expected lines in ', [StringComparison]::Ordinal) -and
                -not $event['agentId'] -and -not $data['parentToolCallId']) {
                $patchPath = Get-LocalPatchUpdatePath $start
                if ($patchPath) {
                    $patchCandidates += @{ eventId = $event['id']; type = $event.type; data = $data; path = $patchPath
                        category = 'local_patch_context_mismatch'; toolName = $start.toolName; arguments = $start.arguments }
                    $recoverable = $true
                }
            }
            elseif ('shell' -cin $AllowTool -and $start -and $start.root -and
                $start.toolName -cin @('powershell', 'read_powershell', 'write_powershell', 'stop_powershell', 'list_powershell', 'bash', 'read_bash', 'write_bash', 'stop_bash', 'list_bash', 'local_shell') -and
                -not $event['agentId'] -and -not $data['parentToolCallId']) {
                $shellCandidates += @{
                    eventId = $event['id']; type = $event.type; data = $data
                    category = 'recoverable_local_shell_error'
                    toolName = $start.toolName; arguments = $start.arguments
                }
                $recoverable = $true
            }
        }
        if ($event.type -eq 'session.error' -or
            ($event.type -eq 'session.info' -and $data['infoType'] -eq 'configuration' -and
                $data['message'] -match 'Unknown tool name in the tool allowlist') -or
            ($event.type -eq 'tool.execution_complete' -and $data['success'] -eq $false -and -not $recoverable) -or
            ($event.type -eq 'tool.execution_start' -and $data['toolName'] -eq 'ask_user')) {
            $runtimeProblems += @{ eventId = $event['id']; type = $event.type; data = $data
                root = [bool]($start -and $start.root -and -not $event['agentId'] -and -not $data['parentToolCallId'])
                toolName = $(if ($start) { $start.toolName } else { $null }); arguments = $(if ($start) { $start.arguments } else { $null }) }
        }
    }
    foreach ($candidate in $patchCandidates) {
        if ($exitCode -eq 0 -and $lastFinalSequence -gt $lastToolSequence -and $candidate['recoveryEventId']) {
            $candidate['category'] = 'recovered_local_patch_error'
            $candidate['finalResponseEventId'] = $lastFinalEventId
            $candidate['continuationReason'] = 'Same local file was reread and successfully patched with file-edit evidence before a final response. Original failure retained.'
            $runtimeWarnings += $candidate
        } else {
            $candidate['continuationReason'] = 'No verified reread and successful same-file update followed by final response.'
            $runtimeProblems += $candidate
        }
    }
    foreach ($candidate in $readCandidates) {
        if ($exitCode -eq 0 -and $lastFinalSequence -gt $lastToolSequence) {
            $candidate['continuationReason'] = 'Allowlisted workspace-local read failure followed by a final root response and successful CLI exit; other fatal and model checks still apply.'
            $candidate['finalResponseEventId'] = $lastFinalEventId
            $runtimeWarnings += $candidate
        }
        else {
            $candidate['continuationReason'] = 'No valid final root response after tool activity or CLI did not exit successfully.'
            $runtimeProblems += $candidate
        }
    }
    foreach ($candidate in $shellCandidates) {
        if ($exitCode -eq 0 -and $lastFinalSequence -gt $lastToolSequence) {
            $candidate['continuationReason'] = 'Allowlisted workspace-local shell command failure followed by a final root response and successful CLI exit.'
            $candidate['finalResponseEventId'] = $lastFinalEventId
            $runtimeWarnings += $candidate
        }
        else {
            $candidate['continuationReason'] = 'No valid final root response after shell tool failure or CLI did not exit successfully.'
            $runtimeProblems += $candidate
        }
    }
    $usageFilePath = Join-Path $turn 'usage.json'
    if (Test-Path -LiteralPath $usageFilePath -PathType Leaf) {
        try {
            $usageSummary = Get-Content -LiteralPath $usageFilePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            if ($usageSummary -is [System.Collections.IDictionary] -and $usageSummary['modelMetrics'] -is [System.Collections.IDictionary]) {
                foreach ($metricModel in $usageSummary.modelMetrics.Keys) {
                    if (-not [string]::IsNullOrWhiteSpace($metricModel) -and $metricModel -inotmatch '^(auto(?::[a-z0-9_-]+)?|fusion(?::standard|:high|:max)?|hydrafusion(?:-max)?)$') {
                        $observedModels += $metricModel
                    }
                }
            }
        } catch {
            $runtimeWarnings += @{ category = 'usage_parse_error'; file = 'usage.json'; error = $_.Exception.Message }
        }
    }
    $meta.eventCount = $count
    Write-Json (Join-Path $turn 'assistant-messages.json') @($messages)
    Write-Json (Join-Path $turn 'runtime.json') @{
        errorPolicyVersion = 'local-read-errors-v2'
        observedModels = @($observedModels | Where-Object {
            $_ -and $_ -inotmatch '^(auto(?::[a-z0-9_-]+)?|fusion(?::standard|:high|:max)?|hydrafusion(?:-max)?)$'
        } | Sort-Object -Unique)
        fusionPhases = $fusionPhases
        usage = $usage; problems = $runtimeProblems; warnings = $runtimeWarnings
        patchRecoveryPolicyVersion = $(if ($RecoverLocalPatchErrors) { 'local-patch-recovery-v1' } else { 'disabled' })
        toolSnapshots = $toolSnapshots; disabledTools = $disabledTools
        toolExecutions = $toolCalls; modelCalls = $modelCalls
        captureComplete = $captureComplete
    }
}
catch {
    $meta.errors += $_.Exception.Message
    $meta.state = 'capture_or_execution_failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    Write-Warning $_.Exception.Message
}
finally {
    try { [void](Save-Snapshot 'after') }
    catch {
        $meta.errors += "After snapshot: $($_.Exception.Message)"
        $meta.state = 'evidence_incomplete'
        $meta.captureComplete = $false
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
    $meta.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-Json (Join-Path $turn 'turn.json') $meta
    $lock.Dispose()
}
Write-Host "Capture state: $($meta.state); exit: $exitCode; evidence: $turn"
exit $exitCode
