#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Resolve', 'Acknowledge', 'Invoke')][string]$Mode,
    [Parameter(Mandatory)][string]$KnowledgeFile,
    [Parameter(Mandatory)][string]$TurnDirectory,
    [string]$MessageFile,
    [string]$ReceiptFile,
    [string]$DecisionFile,
    [string]$DeliveredTextFile,
    [string]$Model,
    [string]$CliPath = 'copilot',
    [ValidateRange(1,86400)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$framework = Split-Path $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'KnowledgeParticipant.psm1') -Force
$knowledge = Read-KpKnowledge $KnowledgeFile
$root = [IO.Path]::GetFullPath($TurnDirectory)
$frameworkRoot = [IO.Path]::GetFullPath($framework).TrimEnd('\', '/')
if ($root.Equals($frameworkRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $root.StartsWith($frameworkRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Private turn evidence must be outside the framework repository and tested product.'
}
$ancestor = $root
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked evidence paths are not allowed.' }
    $ancestor = Split-Path $ancestor -Parent
}

function Write-NewJson([string]$Name, $Value) {
    $path = Join-Path $root $Name
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 40))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

if ($Mode -eq 'Prepare' -or $Mode -eq 'Invoke') {
    if (-not $MessageFile) { throw 'MessageFile is required.' }
    if (Test-Path -LiteralPath $root) { throw 'Use a fresh turn directory; automatic resend is prohibited.' }
    if ($Mode -eq 'Invoke' -and ([string]::IsNullOrWhiteSpace($Model) -or $Model -eq 'auto')) { throw 'Invoke requires an explicit model ID and makes a paid call.' }
    $receipt = if ($ReceiptFile) { Get-Content -LiteralPath $ReceiptFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { $null }
    $message = Get-Content -LiteralPath $MessageFile -Raw -Encoding utf8
    $request = New-KpRequest $knowledge $message $receipt
    [void](New-Item -ItemType Directory -Path $root)
    Write-NewJson 'request.json' $request
    Copy-Item -LiteralPath $KnowledgeFile -Destination (Join-Path $root 'knowledge.json')
    $agentSource = Join-Path $framework 'agents/knowledge-participant.agent.md'
    Copy-Item -LiteralPath $agentSource -Destination (Join-Path $root 'knowledge-participant.agent.md')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'KnowledgeParticipant.psm1') -Destination $root
    Write-NewJson 'manifest.json' @{
        protocolVersion = 'knowledge-participant-v1'; knowledgeHash = $knowledge.hash
        agentHash = (Get-FileHash $agentSource).Hash
        moduleHash = (Get-FileHash (Join-Path $PSScriptRoot 'KnowledgeParticipant.psm1')).Hash
        requestHash = (Get-FileHash (Join-Path $root 'request.json')).Hash
        model = $(if ($Mode -eq 'Invoke') { $Model } else { $null })
        state = $(if ($Mode -eq 'Invoke') { 'dispatching' } else { 'prepared' })
    }
    if ($Mode -eq 'Prepare') { Write-Output "Prepared private request: $root"; return }
    $workspace = Join-Path $root 'participant-workspace'
    $agentDirectory = Join-Path $workspace '.github/agents'
    [void](New-Item -ItemType Directory -Path $agentDirectory -Force)
    Copy-Item -LiteralPath (Join-Path $root 'knowledge-participant.agent.md') -Destination $agentDirectory
    & git -C $workspace init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize isolated participant workspace.' }
    & git -C $workspace add --all
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage isolated participant definition.' }
    & git -C $workspace -c core.hooksPath=.git/disabled-hooks -c user.name='Evaluation Fixture' -c user.email='fixture@example.invalid' -c commit.gpgsign=false commit --quiet -m 'Freeze isolated participant definition'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze isolated participant definition.' }
    $collector = Join-Path $PSScriptRoot 'Invoke-SdlcCapture.ps1'
    Copy-Item -LiteralPath $collector -Destination $root
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CapturedProcess.psm1') -Destination $root
    $collector = Join-Path $root 'Invoke-SdlcCapture.ps1'
    $parameters = @{
        PromptFile = (Join-Path $root 'request.json'); RunDirectory = (Join-Path $root 'capture')
        RepositoryPath = $workspace; Agent = 'knowledge-participant'; Model = $Model
        NoTools = $true; DisableBuiltinMcps = $true; NoCustomInstructions = $true
        CopilotHome = (Join-Path $root 'participant-home'); CliPath = $CliPath; TimeoutSeconds = $TimeoutSeconds
    }
    & $collector @parameters | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Capture failed. Evidence retained; do not automatically resend.' }
    $turn = Get-ChildItem (Join-Path $root 'capture') -Directory -Filter 'turn-*' | Sort-Object Name | Select-Object -Last 1
    $meta = Get-Content (Join-Path $turn.FullName 'turn.json') -Raw | ConvertFrom-Json -AsHashtable
    $runtime = Get-Content (Join-Path $turn.FullName 'runtime.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($meta.state -ne 'cli_exited' -or $runtime.problems.Count -or $runtime.observedModels.Count -ne 1 -or $runtime.observedModels[0] -cne $Model) { throw 'Invalid execution or actual model mismatch; retained for review.' }
    $messages = @(Get-Content (Join-Path $turn.FullName 'assistant-messages.json') -Raw | ConvertFrom-Json -AsHashtable)
    if (-not $messages.Count -or $messages[-1].hasToolRequests) { throw 'No final participant decision.' }
    Write-NewJson 'decision.json' ($messages[-1].content | ConvertFrom-Json -AsHashtable)
    $DecisionFile = Join-Path $root 'decision.json'
    $Mode = 'Resolve'
}

$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
if ($manifest.knowledgeHash -cne $knowledge.hash -or
    (Get-FileHash (Join-Path $root 'knowledge.json')).Hash -cne $knowledge.hash -or
    (Get-FileHash (Join-Path $root 'KnowledgeParticipant.psm1')).Hash -cne $manifest.moduleHash -or
    (Get-FileHash (Join-Path $root 'knowledge-participant.agent.md')).Hash -cne $manifest.agentHash -or
    (Get-FileHash (Join-Path $root 'request.json')).Hash -cne $manifest.requestHash) { throw 'Frozen turn input changed.' }
Import-Module (Join-Path $root 'KnowledgeParticipant.psm1') -Force
$request = Get-Content (Join-Path $root 'request.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($Mode -eq 'Resolve') {
    if (-not $DecisionFile) { throw 'DecisionFile is required; Prepare never calls a model.' }
    $decision = Get-Content -LiteralPath $DecisionFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $response = Resolve-KpDecision $knowledge $request $decision
    Write-NewJson 'response.json' $response
    Write-NewJson 'response-manifest.json' @{ sha256 = (Get-FileHash (Join-Path $root 'response.json')).Hash }
    Write-Output "Prepared response, not delivered or semantically approved: $root"
} elseif ($Mode -eq 'Acknowledge') {
    if (-not $DeliveredTextFile) { throw 'Supply the actual counterpart-input capture, not a delivery intention.' }
    $responseManifest = Get-Content (Join-Path $root 'response-manifest.json') -Raw | ConvertFrom-Json
    if ((Get-FileHash (Join-Path $root 'response.json')).Hash -cne $responseManifest.sha256) { throw 'Response changed.' }
    $response = Get-Content (Join-Path $root 'response.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $receipt = Confirm-KpDelivery $response (Get-Content -LiteralPath $DeliveredTextFile -Raw -Encoding utf8)
    Write-NewJson 'delivery.json' $receipt
    Write-Output "Recorded exact delivered text: $root"
}