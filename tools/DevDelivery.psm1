Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevExecution.psm1')

function Assert-DeliveryOutput([string]$Output, [string]$Source) {
    $destination = [IO.Path]::GetFullPath($Output).TrimEnd('\', '/')
    $origin = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    if ($destination -ieq $origin -or $destination.StartsWith($origin + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must be outside the source directory.'
    }
    $ancestor = $destination
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked delivery path: $ancestor"
        }
        $ancestor = Split-Path $ancestor -Parent
    }
}

function Get-DeliveryHashes {
    param(
        [string]$Directory, [string[]]$MetadataOnlyPaths = @(), [switch]$MetadataOnly,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300
    )
    $Directory = [IO.Path]::GetFullPath($Directory)
    foreach ($path in $MetadataOnlyPaths) { Assert-DevRelativePath $path }
    $metadataPaths = @($MetadataOnlyPaths | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') })
    $root = [IO.DirectoryInfo]::new($Directory)
    if (-not $root.Exists -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Missing or linked delivery directory: $Directory" }
    $hashes = @{}
    $pending = [Collections.Generic.Stack[object]]::new()
    $pending.Push(@{ directory = $root; metadata = [bool]$MetadataOnly })
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProgress = 0
    Write-Host "Delivery inventory: $Directory (dependency metadata only: $([bool]$MetadataOnly -or $metadataPaths.Count -gt 0))"
    while ($pending.Count) {
        $current = $pending.Pop()
        foreach ($item in $current.directory.EnumerateFileSystemInfos()) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Delivery inventory timed out after ${TimeoutSeconds}s: $Directory" }
            if ($timer.Elapsed.TotalSeconds - $lastProgress -ge 10) {
                Write-Host "Delivery inventory: $($hashes.Count) files checked; $([int]$timer.Elapsed.TotalSeconds)s; $Directory"
                $lastProgress = $timer.Elapsed.TotalSeconds
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked delivery entry: $($item.FullName)" }
            $relative = [IO.Path]::GetRelativePath($Directory, $item.FullName).Replace('\', '/')
            if ($item.Attributes -band [IO.FileAttributes]::Directory) {
                $pending.Push(@{ directory = $item; metadata = ($current.metadata -or $relative -in $metadataPaths) })
            } elseif ($current.metadata) {
                # Metadata detects ordinary dependency changes, not same-size/timestamp content tampering.
                $hashes[$relative] = "metadata:$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
            } else {
                $stream = $item.OpenRead()
                try { $hashes[$relative] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
                finally { $stream.Dispose() }
            }
        }
    }
    Write-Host "Delivery inventory complete: $($hashes.Count) files in $([math]::Round($timer.Elapsed.TotalSeconds, 2))s"
    return $hashes
}

function Assert-DeliveryHashes([hashtable]$Expected, [hashtable]$Actual) {
    if ($Expected.Count -ne $Actual.Count -or @($Expected.Keys | Where-Object { $Expected[$_] -cne $Actual[$_] }).Count) {
        throw 'Delivery integrity mismatch: files were added, removed or changed.'
    }
}

function Get-DevDeliverySource([string]$ConditionDirectory) {
    $condition = (Resolve-Path -LiteralPath $ConditionDirectory).Path
    $root = Split-Path $condition
    $resultPath = Join-Path $condition 'dev\result.json'
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
    $config = Get-Content -LiteralPath (Join-Path $condition 'config.json') -Raw | ConvertFrom-Json -AsHashtable
    $plan = Get-Content -LiteralPath (Join-Path $root 'input-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($plan['stage'] -ne 'dev' -or -not $result['execution'] -or
        $result.execution['cliExitCode'] -ne 0 -or $result.execution['timedOut'] -or
        $result.protectedChanges.Count -or -not $result.observedModels.Count) {
        throw 'A completed Dev execution with concrete model evidence and intact protected inputs is required.'
    }
    $expected = $plan.baselineHashes.Clone()
    foreach ($change in $result.changedFiles) {
        if ($null -eq $change.after) { [void]$expected.Remove($change.path) }
        else { $expected[$change.path] = $change.after }
    }
    $workspace = Join-Path $condition 'product'
    Assert-DeliveryHashes $expected (Get-DevHashes $workspace @($config.runtimeDirectories))
    return @{ condition = $condition; root = $root; workspace = $workspace; resultPath = $resultPath
        result = $result; config = $config; plan = $plan; hashes = $expected }
}

function New-DevDelivery([string]$ConditionDirectory, [string]$OutputDirectory) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $source = Get-DevDeliverySource $ConditionDirectory
    Assert-DeliveryOutput $OutputDirectory $source.workspace
    if (Test-Path -LiteralPath $OutputDirectory) { throw "Delivery already exists: $OutputDirectory" }
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $product = Join-Path $OutputDirectory 'product'
    $runtime = Join-Path $OutputDirectory 'runtime'
    $directories = @($source.config.runtimeDirectories)
    Copy-DevSource $source.workspace $product $directories
    Assert-DeliveryHashes $source.hashes (Get-DevHashes $product $directories)
    $dependencies = @($directories | Where-Object { $_ -match '(^|[/\\])(\.venv|node_modules)$' })
    $state = @($directories | Where-Object { $_ -notmatch '(^|[/\\])(\.venv|node_modules)$' })
    $dependencyInventories = @{}
    foreach ($dependency in $dependencies) {
        $dependencyInventories[$dependency] = Get-DeliveryHashes (Join-Path $source.workspace $dependency) -MetadataOnly
    }
    [void](New-Item -ItemType Directory -Path $runtime)
    if ($dependencies.Count) { Copy-DevRuntime $source.workspace $runtime $dependencies (Join-Path $OutputDirectory 'dependency-copy') }
    if ($state.Count) { Copy-DevRuntime (Join-Path $source.root 'runtime-baseline') $runtime $state (Join-Path $OutputDirectory 'state-copy') }
    foreach ($dependency in $dependencies) {
        Assert-DeliveryHashes $dependencyInventories[$dependency] (Get-DeliveryHashes (Join-Path $runtime $dependency) -MetadataOnly)
    }
    $verification = $source.config.verification.Clone()
    if ($verification['acceptanceDirectory']) {
        Copy-DevSource (Join-Path $source.root 'inputs\acceptance') (Join-Path $OutputDirectory 'acceptance')
        $verification.acceptanceDirectory = 'acceptance'
    }
    $evidence = Join-Path $OutputDirectory 'evidence'
    [void](New-Item -ItemType Directory -Path $evidence)
    foreach ($name in @('result.json', 'summary.md')) {
        $file = Join-Path $source.condition "dev\$name"
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $evidence }
    }
    foreach ($name in @('verification', 'historical-verification')) {
        $folder = Join-Path $source.condition $name
        if (Test-Path -LiteralPath $folder) {
            $target = Join-Path $evidence $name
            [void](New-Item -ItemType Directory -Path $target)
            Get-ChildItem -LiteralPath $folder -File | Copy-Item -Destination $target
        }
    }
    Assert-DeliveryHashes $source.hashes (Get-DevHashes $source.workspace $directories)
    $manifest = @{
        schemaVersion = 2; id = [guid]::NewGuid().ToString(); createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        integrityPolicy = 'source-sha256-dependency-metadata-v1'
        dependencyIntegrity = 'Relative path, size and last-write UTC; dependency contents are not hashed.'
        sourceCondition = $source.condition; sourceResult = $source.resultPath
        sourceResultSha256 = (Get-FileHash -LiteralPath $source.resultPath).Hash
        devModel = $source.result.model; devOutcome = $source.result.outcome; caseId = $source.plan.caseId
        snapshotTiming = 'Created from saved Dev artifacts after verifying baseline plus recorded changes; not a reconstructed earlier environment.'
        requirementWorkspacePath = $source.plan.requirementWorkspacePath; designWorkspacePath = $source.plan.designWorkspacePath
        runtimeDirectories = $directories; verification = $verification
        statePolicy = 'Dependencies from delivered workspace; mutable state reset from original run runtime-baseline.'
        hashes = (Get-DeliveryHashes $OutputDirectory -MetadataOnlyPaths @($dependencies | ForEach-Object { "runtime/$_" }))
        preparationDurationSeconds = $timer.Elapsed.TotalSeconds
    }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'delivery.json') -Encoding utf8
    return $manifest
}

function Read-DevDelivery([string]$Directory) {
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'delivery.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest['schemaVersion'] -notin @(1, 2) -or -not $manifest['id'] -or $manifest['hashes'] -isnot [hashtable]) { throw 'Invalid delivery manifest.' }
    $metadataPaths = @()
    if ($manifest.schemaVersion -eq 2) {
        if ($manifest['integrityPolicy'] -ne 'source-sha256-dependency-metadata-v1') { throw 'Unknown delivery integrity policy.' }
        $metadataPaths = @($manifest.runtimeDirectories | Where-Object { $_ -match '(^|[/\\])(\.venv|node_modules)$' } | ForEach-Object { "runtime/$_" })
    }
    $actual = Get-DeliveryHashes $Directory -MetadataOnlyPaths $metadataPaths
    [void]$actual.Remove('delivery.json')
    Assert-DeliveryHashes $manifest.hashes $actual
    return $manifest
}

function Copy-DevDeliveryWorkspace([string]$DeliveryDirectory, [hashtable]$Manifest, [string]$Workspace, [string]$LogDirectory) {
    Assert-DeliveryOutput $Workspace $DeliveryDirectory
    if (Test-Path -LiteralPath $Workspace) { throw "Use a fresh delivery workspace: $Workspace" }
    $dirs = @($Manifest.runtimeDirectories)
    Copy-DevSource (Join-Path $DeliveryDirectory 'product') $Workspace $dirs
    if ($dirs.Count) { Copy-DevRuntime (Join-Path $DeliveryDirectory 'runtime') $Workspace $dirs $LogDirectory }
    Assert-DeliveryHashes (Get-DevHashes (Join-Path $DeliveryDirectory 'product') $dirs) (Get-DevHashes $Workspace $dirs)
    foreach ($relative in $dirs) {
        $metadata = $Manifest.schemaVersion -eq 2 -and $relative -match '(^|[/\\])(\.venv|node_modules)$'
        Assert-DeliveryHashes (Get-DeliveryHashes (Join-Path $DeliveryDirectory "runtime\$relative") -MetadataOnly:$metadata) `
            (Get-DeliveryHashes (Join-Path $Workspace $relative) -MetadataOnly:$metadata)
    }
}

function Read-BackendTestProfile([string]$ProfileFile, [string]$ProjectRepository, [hashtable]$Project = @{}) {
    $path = (Resolve-Path -LiteralPath $ProfileFile).Path
    $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($profile['stage'] -ne 'test' -or $profile['executionMode'] -ne 'single-shot-test' -or
        $profile['targetAgent'] -notmatch '^[\w-]+$' -or $profile['timeoutSeconds'] -lt 1 -or $profile.timeoutSeconds -gt 86400 -or
        $profile['webTesting'] -ne 'not_implemented') { throw 'Invalid backend-only Test profile.' }
    $origin = if ($profile.ContainsKey('agentSource')) { $profile.agentSource } else { 'profile' }
    $access = if ($profile.ContainsKey('backendTestAccess')) { $profile.backendTestAccess } else { 'maintain' }
    if ($origin -notin @('profile', 'project') -or $access -notin @('read-only', 'maintain')) { throw 'Invalid Test agent source or backend access policy.' }
    if ($profile.targetAgent -ceq 'SDLCRole_Test' -and $access -ne 'read-only') { throw 'SDLCRole_Test requires read-only backend access.' }
    $base = Split-Path $path
    if ($origin -eq 'project') {
        if (-not $ProjectRepository -or -not (Test-Path -LiteralPath $ProjectRepository -PathType Container)) { throw 'Project-sourced Test agent requires a valid Dev sourceRepository.' }
        $base = (Resolve-Path -LiteralPath $ProjectRepository).Path
        Assert-DevRelativePath $profile.agentFile
        foreach ($key in @('projectContractPath', 'reportWorkspacePath')) {
            if ($Project.ContainsKey($key)) {
                if ($Project[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Project[$key])) {
                    throw "Project $key must be a nonempty string."
                }
                $profile[$key] = $Project[$key]
            }
        }
        if ($access -eq 'read-only' -and -not $profile['reportWorkspacePath']) {
            throw 'Read-only Test requires project reportWorkspacePath (or an explicit legacy Test profile).'
        }
    }
    $agent = [IO.Path]::GetFullPath($profile.agentFile, $base)
    $contract = $null
    if ($profile['projectContractPath']) {
        if ($origin -ne 'project') { throw 'A Test project contract requires agentSource=project.' }
        Assert-DevRelativePath $profile.projectContractPath
        $contract = Join-Path $base $profile.projectContractPath
    }
    foreach ($file in @($agent, $contract) | Where-Object { $_ }) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing Test role input: $file" }
        $ancestor = $file
        while ($ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked Test role input: $ancestor" }
            $ancestor = Split-Path $ancestor -Parent
        }
    }
    $definition = Get-Content -LiteralPath $agent -Raw
    $frontmatter = [regex]::Match($definition, '\A\uFEFF?---\r?\n(?<metadata>[\s\S]*?)\r?\n---(?:\r?\n|$)')
    $name = [regex]::Match($frontmatter.Groups['metadata'].Value, '(?m)^name:[ \t]*(?<quote>[''"]?)(?<name>[\w-]+)\k<quote>[ \t]*\r?$')
    if (-not $name.Success -or $name.Groups['name'].Value -cne $profile.targetAgent) { throw 'Test agent name does not match targetAgent.' }
    if ($profile['reportWorkspacePath']) {
        $report = $profile.reportWorkspacePath.Replace('{caseId}', 'case').Replace('\', '/')
        Assert-DevRelativePath $report
        if ([IO.Path]::GetExtension($report) -ine '.md') { throw 'Test report must be a workspace-relative Markdown file.' }
    }
    return @{ profile = $profile; path = $path; agentFile = $agent; contractFile = $contract; backendTestAccess = $access }
}

Export-ModuleMember -Function Assert-DeliveryOutput, Get-DeliveryHashes, Assert-DeliveryHashes, Get-DevDeliverySource, New-DevDelivery, Read-DevDelivery, Copy-DevDeliveryWorkspace, Read-BackendTestProfile
