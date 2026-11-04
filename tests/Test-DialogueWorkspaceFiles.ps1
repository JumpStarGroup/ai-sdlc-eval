#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\tools\DialoguePolicy.psm1') -Force
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dialogue-workspace-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($relative in @('.git', '.venv', 'frontend\node_modules', 'src', 'hidden')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $fixture $relative) -Force)
        'Workspace enumeration fixture.' | Set-Content (Join-Path $fixture "$relative\fixture.txt")
    }
    'Source file.' | Set-Content (Join-Path $fixture 'draft.md')
    $allFiles = @(Get-DialogueWorkspaceFiles -Repository $fixture | ForEach-Object {
        [IO.Path]::GetRelativePath($fixture, $_.FullName).Replace('\', '/')
    })
    $devFiles = @(Get-DialogueWorkspaceFiles -Repository $fixture -ExcludeDependencies | ForEach-Object {
        [IO.Path]::GetRelativePath($fixture, $_.FullName).Replace('\', '/')
    })
    Assert ($allFiles.Count -eq 5 -and '.git/fixture.txt' -notin $allFiles -and
        '.venv/fixture.txt' -in $allFiles -and 'frontend/node_modules/fixture.txt' -in $allFiles) 'Default enumeration preserves dependency files and excludes Git metadata.'
    Assert ($devFiles.Count -eq 3 -and 'src/fixture.txt' -in $devFiles -and
        'hidden/fixture.txt' -in $devFiles -and 'draft.md' -in $devFiles) 'Dev enumeration prunes dependency trees while retaining untracked source files.'
    $state = New-DialogueState
    $policy = @{
        callLimit = 4; allowPendingDraft = $false; requireArtifact = $true
        maxCoordinatorPrompts = 1; coordinatorPrompt = 'Deliver code.'
    }
    $message = Read-DialogueMessage ('Code delivered.' + "`n" +
        'DIALOGUE_CONTROL: {"status":"role_task_completed","pending":[],"artifactPaths":[".venv/fixture.txt","frontend/node_modules/fixture.txt"]}')
    $step = Get-DialogueStep $state $message 'target' $policy $fixture @{}
    Assert ($step.action -eq 'prompt' -and
        @($state.artifactCheck.failures | Where-Object { $_.reason -eq 'artifact_dependency_path' }).Count -eq 2) 'Excluded dependencies cannot be claimed as newly delivered code.'
    $message.control.artifactPaths = @('src/../frontend/node_modules/fixture.txt')
    $state = New-DialogueState
    [void](Get-DialogueStep $state $message 'target' $policy $fixture @{})
    Assert ($state.artifactCheck.failures[0].reason -eq 'artifact_dependency_path') 'Dependency checks normalize relative paths.'
    $message.control.artifactPaths = @('draft.md')
    $state = New-DialogueState
    $baseline = @{ (Join-Path $fixture 'draft.md') = (Get-FileHash (Join-Path $fixture 'draft.md')).Hash }
    [void](Get-DialogueStep $state $message 'target' $policy $fixture $baseline)
    Assert ($state.artifactCheck.failures[0].reason -eq 'artifact_unchanged') 'Source files still require a real change.'
    'Changed source file.' | Set-Content (Join-Path $fixture 'draft.md')
    $state = New-DialogueState
    [void](Get-DialogueStep $state $message 'target' $policy $fixture $baseline)
    Assert $state.artifactCheck.ready 'Changed source files remain valid artifacts.'
    Write-Output 'PASS: workspace pruning, dependency artifact rejection and source hash checks'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
