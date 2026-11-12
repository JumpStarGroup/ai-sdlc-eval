Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ModelReasoningEfforts([string]$Json = '{}') {
    $values = ConvertFrom-Json -InputObject $Json -AsHashtable
    if ($values -isnot [System.Collections.IDictionary]) { throw 'ModelReasoningEfforts must be a JSON object keyed by model ID.' }
    foreach ($model in $values.Keys) {
        if ($model -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$' -or
            $values[$model] -isnot [string] -or $values[$model] -cnotin @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')) {
            throw "Invalid ModelReasoningEfforts entry: $model"
        }
    }
    return $values
}

function Get-ModelReasoningEffort(
    [string]$Model,
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')][string]$Default = 'medium',
    [System.Collections.IDictionary]$Overrides = @{}
) {
    if ($Overrides.Contains($Model)) { return $Overrides[$Model] }
    if (Test-RoutedModel $Model) { return $null }
    return $Default
}

function Test-RoutedModel([string]$Model) {
    return $Model -imatch '^(auto(?::[a-z0-9_-]+)?|fusion(?::standard|:high|:max)?|hydrafusion(?:-max)?)$'
}

function Read-TargetConditions(
    [string]$Json,
    [string[]]$Models,
    [string]$Default = 'medium',
    [System.Collections.IDictionary]$Overrides = @{}
) {
    if ($Json) {
        $entries = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate
        if ($entries -isnot [array] -or -not $entries.Count) { throw 'TargetConditions must be a nonempty JSON array.' }
    } else {
        $entries = @($Models | ForEach-Object { @{ model = $_ } })
        if (-not $entries.Count) { throw 'Specify at least one target model.' }
    }
    foreach ($entry in $entries) {
        if ($entry -isnot [System.Collections.IDictionary] -or
            $entry['model'] -isnot [string] -or $entry.model -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$' -or
            @($entry.Keys | Where-Object { $_ -cnotin @('model', 'reasoningEffort') }).Count) {
            throw 'Invalid TargetConditions entry; expected model and optional reasoningEffort.'
        }
        if ($entry.model -imatch '^fusion:' -and -not (Test-RoutedModel $entry.model)) { throw "Invalid Fusion selector: $($entry.model)" }
        $effort = Get-ModelReasoningEffort $entry.model $Default $Overrides
        if ($entry.Contains('reasoningEffort')) {
            $effort = $entry.reasoningEffort
            if ($null -eq $effort) {
                if (-not (Test-RoutedModel $entry.model)) { throw 'Null TargetConditions reasoningEffort is only valid for routed models.' }
            } elseif ($effort -isnot [string] -or $effort -cnotin @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')) {
                throw "Invalid TargetConditions reasoningEffort: $($entry.model)"
            }
        }
        @{ model = $entry.model; reasoningEffort = $effort }
    }
}

function Resolve-EvaluationAgent([string]$File, [string]$Base, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($File) -or $Name -cnotmatch '^[\w-]+$') { throw 'Expected an explicit agent file and valid targetAgent.' }
    $path = [IO.Path]::GetFullPath($File, $Base)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing target Agent file: $path" }
    $ancestor = $path
    while ($ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked Agent input: $ancestor" }
        $ancestor = Split-Path $ancestor -Parent
    }
    $definition = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $frontmatter = [regex]::Match($definition, '\A\uFEFF?---\r?\n(?<metadata>[\s\S]*?)\r?\n---(?:\r?\n|$)')
    $nameMatch = [regex]::Match($frontmatter.Groups['metadata'].Value, '(?m)^name:[ \t]*(?<quote>[''"]?)(?<name>[\w-]+)\k<quote>[ \t]*\r?$')
    if (-not $nameMatch.Success -or $nameMatch.Groups['name'].Value -cne $Name) { throw 'Agent name does not match targetAgent.' }
    return $path
}

Export-ModuleMember -Function Read-ModelReasoningEfforts, Get-ModelReasoningEffort, Read-TargetConditions, Test-RoutedModel, Resolve-EvaluationAgent
