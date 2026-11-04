if ($args -contains '--version') { Write-Output 'fixture-cli 1.0'; exit 0 }
if ($args -contains '--help') {
    if ($env:SDLC_CAPTURE_FIXTURE -eq 'help_failure') { exit 7 }
    Write-Output '  --disallow-temp-dir'
    if ($env:SDLC_CAPTURE_FIXTURE -eq 'remote_legacy') {
        Write-Output "  --no-remote`n  --no-remote-export"
    } elseif ($env:SDLC_CAPTURE_FIXTURE -ne 'remote_unknown') {
        Write-Output '  --sync-session[=<on|off>]'
    }
    exit 0
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'remote_modern' -and
    ($args -contains '--no-remote' -or $args -contains '--no-remote-export' -or $args -notcontains '--sync-session=off')) {
    [Console]::Error.WriteLine('Removed remote flags or missing explicit sync disable.')
    exit 1
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'native_stdin') {
    $native = Join-Path $PSScriptRoot 'fake-stdin-native.cjs'
    & node $native --version | Out-Null
    & node $native @args
    exit $LASTEXITCODE
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'timeout') {
    Write-Output '{"type":"session.start","id":"start","data":{}}'
    Start-Sleep -Seconds 30
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'malformed') {
    Write-Output 'not-json'
    exit 0
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'empty') { exit 0 }
if ($args -contains '-p' -or $args -contains '--prompt') { throw 'Prompt must not travel in command-line arguments.' }
$prompt = [Console]::In.ReadToEnd()
$sessionIndex = [Array]::IndexOf($args, '--session-id')
@{ type = 'session.start'; id = 'start'; data = @{ sessionId = $args[$sessionIndex + 1]; arguments = $args } } |
    ConvertTo-Json -Compress
@{ type = 'session.model_change'; data = @{ newModel = 'configured-only' } } | ConvertTo-Json -Compress
@{ type = 'model.call_start'; agentId = 'child'; data = @{ model = 'child-model' } } | ConvertTo-Json -Compress
if ($env:SDLC_CAPTURE_FIXTURE -eq 'modern') {
    @{ type = 'model.call_start'; data = @{ model = 'fixture-model' } } | ConvertTo-Json -Compress
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'fusion_routing') {
    @{ type = 'model.call_start'; data = @{ model = 'auto' } } | ConvertTo-Json -Compress
    @{ type = 'assistant.usage'; data = @{ model = 'fusion'; fusion = @{ model = 'fixture-model' } } } | ConvertTo-Json -Depth 8 -Compress
    $usagePath = $args[[Array]::IndexOf($args, '--usage-output-file') + 1]
    @{ modelMetrics = @{ auto = @{}; fusion = @{}; 'fusion:high' = @{}; hydrafusion = @{}; 'fixture-usage-model' = @{} } } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $usagePath -Encoding utf8
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'legacy') {
    @{ type = 'assistant.usage'; data = @{ model = 'fixture-model'; inputTokens = 10; outputTokens = 5; duration = 1 } } | ConvertTo-Json -Compress
}
if ($env:SDLC_CAPTURE_FIXTURE -eq 'unknown_tool') {
    @{ type = 'session.info'; data = @{ infoType = 'configuration'; message = 'Unknown tool name in the tool allowlist: "create"' } } | ConvertTo-Json -Compress
}
if ($env:SDLC_CAPTURE_FIXTURE -like 'read_*') {
    $mode = $env:SDLC_CAPTURE_FIXTURE
    $workspace = $args[[Array]::IndexOf($args, '-C') + 1]
    $path = Join-Path $workspace 'missing.txt'
    if ($mode -eq 'read_range') { $path = Join-Path $workspace 'empty.txt'; [IO.File]::WriteAllText($path, '') }
    if ($mode -eq 'read_before_error') {
        @{ type = 'assistant.message'; id = 'early-final'; data = @{ content = 'Earlier response.' } } | ConvertTo-Json -Compress
    }
    if ($mode -eq 'read_outside') { $path = Join-Path (Split-Path $workspace) 'missing.txt' }
    if ($mode -eq 'read_sibling') { $path = Join-Path ($workspace + '-other') 'missing.txt' }
    if ($mode -eq 'read_traversal') { $path = Join-Path $workspace '..\missing.txt' }
    $tool = if ($mode -eq 'read_write') { 'apply_patch' } else { 'view' }
    if ($mode -ne 'read_uncorrelated') {
        $start = @{ type = 'tool.execution_start'; data = @{ toolCallId = 'read'; toolName = $tool; arguments = @{ path = $path } } }
        if ($mode -eq 'read_range') { $start.data.arguments.view_range = @(1, 180) }
        if ($mode -eq 'read_child') { $start.agentId = 'child' }
        $start | ConvertTo-Json -Compress -Depth 8
    }
    $message = switch ($mode) {
        'read_denied' { 'Permission denied' }
        'read_unknown' { 'Unexpected read error' }
        'read_range' { 'view_range out of bounds' }
        default { 'Path does not exist' }
    }
    @{ type = 'tool.execution_complete'; id = 'read-failure'; data = @{
        toolCallId = 'read'; success = $false; error = @{ code = 'failure'; message = $message }
    } } | ConvertTo-Json -Compress -Depth 8
}
if ($env:SDLC_CAPTURE_FIXTURE -like 'patch_*') {
    $mode = $env:SDLC_CAPTURE_FIXTURE
    $workspace = $args[[Array]::IndexOf($args, '-C') + 1]
    $path = Join-Path $workspace 'draft.md'
    if ($mode -eq 'patch_outside') { $path = Join-Path (Split-Path $workspace) 'draft.md' }
    'Before' | Set-Content $path
    $patch = "*** Begin Patch`n*** Update File: $path`n@@`n-Before`n+After`n*** End Patch"
    $start = @{ type = 'tool.execution_start'; data = @{ toolCallId = 'patch-failed'; toolName = 'apply_patch'; arguments = $patch } }
    if ($mode -eq 'patch_child') { $start.agentId = 'child' }
    $start | ConvertTo-Json -Compress -Depth 8
    @{ type = 'tool.execution_complete'; id = 'patch-error'; data = @{ toolCallId = 'patch-failed'; success = $false
        error = @{ code = $(if ($mode -eq 'patch_denied') { 'denied' } else { 'failure' }); message = "Failed to apply patch: Error: Failed to find expected lines in $path`:" } } } | ConvertTo-Json -Compress -Depth 8
    if ($mode -ne 'patch_no_read') {
        @{ type = 'tool.execution_start'; data = @{ toolCallId = 'reread'; toolName = 'view'; arguments = @{ path = $path } } } | ConvertTo-Json -Compress -Depth 8
        @{ type = 'tool.execution_complete'; id = 'reread-ok'; data = @{ toolCallId = 'reread'; success = $true } } | ConvertTo-Json -Compress
    }
    if ($mode -ne 'patch_unrecovered') {
        if ($mode -eq 'patch_other_file') { $path = Join-Path $workspace 'other.md'; 'Before' | Set-Content $path; $patch = "*** Begin Patch`n*** Update File: $path`n@@`n-Before`n+After`n*** End Patch" }
        @{ type = 'tool.execution_start'; data = @{ toolCallId = 'patch-ok'; toolName = 'apply_patch'; arguments = $patch } } | ConvertTo-Json -Compress
        'After' | Set-Content $path
        @{ type = 'tool.execution_complete'; id = 'patch-success'; data = @{ toolCallId = 'patch-ok'; success = $true; fileEdits = @(@{ path = $path; kind = 'edit' }) } } | ConvertTo-Json -Compress -Depth 8
    }
}
if ($env:SDLC_CAPTURE_FIXTURE -notin @('read_no_final', 'read_before_error', 'patch_no_final')) {
    $final = @{ type = 'assistant.message'; id = 'message'; data = @{ content = $prompt } }
    if ($env:SDLC_CAPTURE_FIXTURE -eq 'read_pending_tools') { $final.data.toolRequests = @(@{ name = 'view' }) }
    if ($env:SDLC_CAPTURE_FIXTURE -eq 'read_blank_final') { $final.data.content = ' ' }
    $final | ConvertTo-Json -Compress -Depth 8
}
[Console]::Error.WriteLine('fixture stderr')
if ($env:SDLC_CAPTURE_FIXTURE -in @('failure', 'read_failed_exit')) { exit 7 }
exit 0
