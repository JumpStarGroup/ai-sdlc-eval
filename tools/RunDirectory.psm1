#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-DialogueRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunsRoot,
        [Parameter(Mandatory)][string]$CaseId,
        [Parameter(Mandatory)][string]$RunLabel,
        [string]$Stage = 'dialogue',
        [datetime]$RunDate = [DateTime]::UtcNow.Date
    )
    if ($CaseId -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$' -or
        $RunLabel -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$' -or
        $Stage -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
        throw 'CaseId, Stage and RunLabel must be safe directory labels.'
    }
    $root = [IO.Path]::GetFullPath($RunsRoot)
    $caseLabel = $CaseId.ToLowerInvariant()
    $stageLabel = $Stage.ToLowerInvariant()
    $prefix = [regex]::Escape($caseLabel)
    $stagePattern = if ($stageLabel -in @('req', 'dialogue')) { '(?:req|dialogue)' } else { [regex]::Escape($stageLabel) }
    $pattern = '^' + $prefix + '-' + $stagePattern + '-(?:(?<sequence>\d+)-\d{8}-.+|\d{8}-.+-(?<sequence>\d+))$'
    $highestSequence = 0
    $batchCount = 0
    if (Test-Path -LiteralPath $root) {
        foreach ($directory in Get-ChildItem -LiteralPath $root -Directory) {
            if ($directory.Name -like '*-inputs') { continue }
            $match = [regex]::Match($directory.Name, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) { continue }
            $batchCount++
            $highestSequence = [Math]::Max($highestSequence, [int]$match.Groups['sequence'].Value)
        }
    }
    $sequence = [Math]::Max($highestSequence, $batchCount) + 1
    $name = '{0}-{1}-{2:d3}-{3}-{4}' -f $caseLabel, $stageLabel, $sequence,
        $RunDate.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture), $RunLabel.ToLowerInvariant()
    return Join-Path $root $name
}

Export-ModuleMember -Function Get-DialogueRunDirectory