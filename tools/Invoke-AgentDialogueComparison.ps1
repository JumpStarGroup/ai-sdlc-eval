#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRepository,
    [string]$RunDirectory,
    [string]$RunsRoot,
    [string]$RunLabel = 'comparison',
    [Parameter(Mandatory)][string]$TemplateFile,
    [string]$ParticipantModel = 'gpt-6.1-sol',
    [string[]]$TargetModels = @('auto', 'gpt-6-luna'),
    [string]$CliPath = 'copilot',
    [switch]$UseGitHubCliAuth
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RunDirectory.psm1') -Force
$source = (Resolve-Path -LiteralPath $SourceRepository).Path
$templatePath = (Resolve-Path -LiteralPath $TemplateFile).Path
$templateRoot = Split-Path $templatePath
$template = Get-Content $templatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$caseId = if ($template.ContainsKey('caseId')) { $template.caseId } else { [IO.Path]::GetFileNameWithoutExtension($templatePath).Split('-')[0] }
if ($caseId -isnot [string] -or $caseId -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') { throw 'caseId must be a safe directory name.' }
if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
    if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
        $RunsRoot = Split-Path ([IO.Path]::GetFullPath($template.runDirectory, $templateRoot)) -Parent
    }
    $RunDirectory = Get-DialogueRunDirectory -RunsRoot $RunsRoot -CaseId $caseId -RunLabel $RunLabel
}
$root = [IO.Path]::GetFullPath($RunDirectory)
if (-not $TargetModels.Count -or $ParticipantModel -imatch '^(auto(?::.*)?|fusion(?::.*)?|hydrafusion(?:-max)?)$') { throw 'Use target models and one fixed participant model.' }
if (Test-Path $root) { throw 'Use a fresh comparison directory.' }
$ancestor = $root
while ($ancestor) {
    if (Test-Path $ancestor) {
        if ((Get-Item $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Test-Path (Join-Path $ancestor '.git'))) { throw 'Comparison evidence must be outside Git repositories and links.' }
    }
    $ancestor = Split-Path $ancestor -Parent
}
$framework = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($protected in @($source, $framework)) {
    $prefix = $protected.TrimEnd('\', '/')
    if ($root.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Comparison must not be inside source repositories.' }
}
$savedPath = $env:PATH
$savedTokens = @{}
$comparison = @{ runDirectory = $root; participantModel = $ParticipantModel; sourceRepository = $source; conditions = @(); excludedFiles = @(); baseline = @{} }
try {
    $env:PATH = $PSHOME + [IO.Path]::PathSeparator + $env:PATH
    if ($UseGitHubCliAuth) {
        foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    $files = @(& git -c core.quotepath=false -C $source ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate the product working baseline.' }
    [void](New-Item -ItemType Directory -Path $root)
    $baselineRoot = Join-Path $root 'baseline'
    [void](New-Item -ItemType Directory -Path $baselineRoot)
    foreach ($relative in @($files | Sort-Object -Unique)) {
        if ($relative -match '(^|/)([^/]+\.(simple-knowledge\.md|knowledge\.json|oracle\.json|dialogue\.json)|\.env(?:\..*)?)$' -or
            $relative -in @('.vscode/mcp.json', '.github/mcp.json')) {
            $comparison.excludedFiles += $relative
            continue
        }
        $path = [IO.Path]::GetFullPath($relative, $source)
        if (-not $path.StartsWith($source.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid source path.' }
        if (-not (Test-Path $path -PathType Leaf)) { continue }
        $ancestor = $path
        while ($ancestor -and $ancestor -ne $source) {
            if ((Get-Item $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked source files cannot be frozen.' }
            $ancestor = Split-Path $ancestor -Parent
        }
        $destination = Join-Path $baselineRoot $relative
        [void](New-Item -ItemType Directory -Path (Split-Path $destination) -Force)
        Copy-Item -LiteralPath $path -Destination $destination
        $comparison.baseline[$relative] = (Get-FileHash $destination).Hash
    }
    $knowledge = [IO.Path]::GetFullPath($template.knowledgeFile, $templateRoot)
    $participant = [IO.Path]::GetFullPath($template.participantAgentFile, $templateRoot)
    Copy-Item $knowledge (Join-Path $root 'knowledge.md')
    Copy-Item $participant (Join-Path $root 'participant.agent.md')
    $comparison['knowledgeHash'] = (Get-FileHash (Join-Path $root 'knowledge.md')).Hash
    $comparison['participantAgentHash'] = (Get-FileHash (Join-Path $root 'participant.agent.md')).Hash
    for ($index = 0; $index -lt $TargetModels.Count; $index++) {
        $modelName = $TargetModels[$index].ToLowerInvariant() -replace '^gpt-\d+(?:\.\d+)?-', ''
        $modelName = ($modelName -replace '[^a-z0-9-]', '-').Trim('-')
        if (-not $modelName) { throw 'Model must have a nonempty directory label.' }
        $conditionName = '{0}-{1}-{2:d2}' -f $caseId.ToLowerInvariant(), $modelName, ($index + 1)
        $conditionRoot = Join-Path $root $conditionName
        $workspace = Join-Path $conditionRoot 'product'
        [void](New-Item -ItemType Directory -Path $workspace -Force)
        Get-ChildItem $baselineRoot -Force | Copy-Item -Destination $workspace -Recurse -Force
        foreach ($relative in $comparison.baseline.Keys) {
            if ((Get-FileHash (Join-Path $workspace $relative)).Hash -cne $comparison.baseline[$relative]) { throw 'Condition baseline differs.' }
        }
        & git -C $workspace init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize comparison workspace.' }
        & git -C $workspace add --all
        if ($LASTEXITCODE -ne 0) { throw 'Cannot stage comparison workspace.' }
        & git -C $workspace -c core.hooksPath=.git/disabled-hooks -c user.name='Evaluation Fixture' -c user.email='fixture@example.invalid' -c commit.gpgsign=false commit --quiet -m 'Freeze comparison baseline'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze comparison baseline.' }
        $config = Get-Content $templatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $config.repositoryPath = $workspace
        $config.runDirectory = Join-Path $conditionRoot 'dialogue'
        $config.targetModel = $TargetModels[$index]
        $config.participantModel = $ParticipantModel
        if (-not $config.ContainsKey('policy')) { $config['policy'] = @{} }
        $config.knowledgeFile = Join-Path $root 'knowledge.md'
        $config.participantAgentFile = Join-Path $root 'participant.agent.md'
        $configFile = Join-Path $conditionRoot 'config.json'
        $config | ConvertTo-Json -Depth 15 | Set-Content $configFile -Encoding utf8
        $comparison.conditions += @{ name = $conditionName; model = $TargetModels[$index]; configFile = $configFile; runDirectory = $config.runDirectory; state = 'prepared' }
    }
    $comparison | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $root 'comparison.json') -Encoding utf8
    foreach ($condition in $comparison.conditions) {
        try {
            & (Join-Path $PSScriptRoot 'Invoke-AgentDialogue.ps1') -ConfigFile $condition.configFile -CliPath $CliPath
            $result = Get-Content (Join-Path $condition.runDirectory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
            $condition.state = $result.outcome
            $condition['calls'] = $result.calls
            $condition['pendingCount'] = $result.pending.Count
            $condition['observedTargetModels'] = @($result.turns | Where-Object { $_.role -eq 'target' } | ForEach-Object { $_['observedModels'] } | Sort-Object -Unique)
            $condition['observedParticipantModels'] = @($result.turns | Where-Object { $_.role -eq 'participant' } | ForEach-Object { $_['observedModels'] } | Sort-Object -Unique)
        } catch {
            $condition.state = 'failed'
            $condition['error'] = $_.Exception.Message
            Write-Warning "Condition $($condition.model) failed: $($_.Exception.Message)"
        }
        $resultPath = Join-Path $condition.runDirectory 'result.json'
        if (Test-Path $resultPath) {
            $result = Get-Content $resultPath -Raw | ConvertFrom-Json -AsHashtable
            $condition['calls'] = $result.calls
            $condition['pendingCount'] = $result.pending.Count
            $condition['observedTargetModels'] = @($result.turns | Where-Object { $_.role -eq 'target' } | ForEach-Object { $_['observedModels'] } | Sort-Object -Unique)
            $condition['observedParticipantModels'] = @($result.turns | Where-Object { $_.role -eq 'participant' } | ForEach-Object { $_['observedModels'] } | Sort-Object -Unique)
        }
        $reportPath = Join-Path $condition.runDirectory 'report.json'
        $condition['summary'] = [IO.Path]::GetRelativePath($root, (Join-Path $condition.runDirectory 'summary.md')).Replace('\', '/')
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json -AsHashtable
            $condition['targetAiCredits'] = $report.usage.target.aiCredits
            $condition['participantAiCredits'] = $report.usage.participant.aiCredits
        }
        $comparison | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $root 'comparison.json') -Encoding utf8
        $indexLines = @('# 本次比较测试索引', '', '| PM 请求模型 | PM 实际模型 | 结果 | 完整会话 | 被评估 Agent AI credit |', '| --- | --- | --- | --- | --- |')
        foreach ($entry in $comparison.conditions) {
            $credit = if ($entry.Contains('targetAiCredits') -and $null -ne $entry.targetAiCredits) {
                ([decimal]$entry.targetAiCredits).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
            } else { '未知' }
            $link = if ($entry.Contains('summary')) { "[打开本组独立汇总]($($entry.summary))" } else { '尚未运行' }
            $actual = if ($entry.Contains('observedTargetModels') -and $entry.observedTargetModels.Count) { $entry.observedTargetModels -join ', ' } else { '未知（尚无实际模型证据）' }
            $indexLines += "| $($entry.model) | $actual | $($entry.state) | $link | $credit |"
        }
        $indexLines | Set-Content (Join-Path $root 'summary.md') -Encoding utf8
    }
    $comparison.conditions | Select-Object model, state, calls, pendingCount, observedTargetModels | Format-Table -AutoSize
    Write-Output "Comparison evidence: $root"
} finally {
    foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name], 'Process') }
    $env:PATH = $savedPath
}