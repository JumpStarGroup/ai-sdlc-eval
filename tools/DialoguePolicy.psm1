Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DialogueWorkspaceFiles([string]$Repository, [switch]$ExcludeDependencies, [string[]]$ExcludeRelativePaths = @()) {
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($Repository)
    while ($directories.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $directories.Pop() -Force) {
            $relative = [IO.Path]::GetRelativePath($Repository, $item.FullName).Replace('\', '/')
            if (@($ExcludeRelativePaths | Where-Object { $relative -ieq $_.Replace('\', '/').TrimEnd('/') }).Count) { continue }
            if ($item.PSIsContainer) {
                if ($item.Name -eq '.git' -or
                    ($ExcludeDependencies -and $item.Name -in @('.venv', 'node_modules')) -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                $directories.Push($item.FullName)
            } else {
                $item
            }
        }
    }
}

function Read-DialogueMessage([string]$Text) {
    $matches = [regex]::Matches($Text, '(?m)^DIALOGUE_CONTROL: (\{[^\r\n]*\})\s*$')
    if ($matches.Count -ne 1 -or $Text.Substring($matches[0].Index + $matches[0].Length).Trim()) {
        throw 'Expected one final DIALOGUE_CONTROL JSON line.'
    }
    $control = $matches[0].Groups[1].Value | ConvertFrom-Json -AsHashtable
    if (($control.Keys | Sort-Object) -join ',' -cne 'artifactPaths,pending,status' -or
        $control.status -cnotin @('waiting_reply', 'role_task_completed', 'blocked') -or
        $control.artifactPaths -isnot [array] -or $control.pending -isnot [array]) { throw 'Invalid dialogue control.' }
    foreach ($path in $control.artifactPaths) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) { throw 'Invalid artifact path.' }
    }
    foreach ($item in $control.pending) {
        if ($item -isnot [System.Collections.IDictionary] -or
            @($item.Keys | Where-Object { $_ -cnotin @('id', 'kind', 'question', 'answeredParts', 'remainingQuestion', 'questionStatus') }).Count -or
            $item.kind -cnotin @('business_decision', 'baseline_investigation', 'technical_followup', 'unclassified') -or
            $item.id -isnot [string] -or [string]::IsNullOrWhiteSpace($item.id) -or
            $item.question -isnot [string] -or [string]::IsNullOrWhiteSpace($item.question)) { throw 'Invalid pending item.' }
        if ($item.Contains('answeredParts') -and ($item.answeredParts -isnot [array] -or
            @($item.answeredParts | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count)) { throw 'Invalid answered parts.' }
        if ($item.Contains('questionStatus') -and $item.questionStatus -cnotin @('awaiting_reply', 'answered', 'partially_answered', 'pending')) { throw 'Invalid question status.' }
        if ($item.Contains('remainingQuestion') -and $null -ne $item.remainingQuestion -and
            ($item.remainingQuestion -isnot [string] -or [string]::IsNullOrWhiteSpace($item.remainingQuestion))) { throw 'Invalid remaining question.' }
        if ($item['questionStatus'] -ceq 'answered' -and ($item['remainingQuestion'] -or -not $item['answeredParts'])) { throw 'Answered questions require answer evidence and no remaining decision.' }
        if ($item.Contains('remainingQuestion') -and $null -eq $item.remainingQuestion -and $item['questionStatus'] -cne 'answered') { throw 'Only answered questions may clear the remaining question.' }
        if ($item['questionStatus'] -ceq 'partially_answered' -and (-not $item['remainingQuestion'] -or -not $item['answeredParts'])) { throw 'Partial answers require known parts and a remaining question.' }
    }
    $body = $Text.Substring(0, $matches[0].Index).Trim()
    if ($control.status -in @('waiting_reply', 'blocked') -and -not $body) { throw 'Handoff content or blocker text is required.' }
    return @{ text = $body; control = $control }
}

function Get-DialogueCompletionFacts($State) {
    $replies = @()
    $claimed = @()
    foreach ($turn in @($State['turns'] | Where-Object { $_ -and $_.role -eq 'target' } | Sort-Object call)) {
        $response = $turn['response']
        $source = if ($response) { 'response' } else { 'rawResponse' }
        $text = if ($response -and $response['text']) { [string]$response.text } else { [string]$turn['rawResponse'] }
        if (-not $response -and -not [string]::IsNullOrWhiteSpace($text)) {
            try { $response = Read-DialogueMessage $text } catch { $response = $null }
        }
        $control = if ($response) { $response['control'] } else { $null }
        if ($control) { $claimed += @($control['artifactPaths'] | Where-Object { $_ -is [string] }) }
        $delivery = $turn['delivery']
        $replies += @{
            call = $turn.call; replyPresent = -not [string]::IsNullOrWhiteSpace($text)
            responseSource = $source; controlParsed = [bool]$control
            reportedStatus = $(if ($control) { $control.status } else { 'unknown' })
            deliveryStatus = $(if ($delivery) { $delivery.status } else { 'not_recorded' })
            delivered = [bool]($delivery -and $delivery.status -in @('captured_input', 'recorded_in_next_input'))
        }
    }
    $last = if ($replies.Count) { $replies[-1] } else { $null }
    $check = $State['artifactCheck']
    $lastTurn = @($State['turns'] | Where-Object { $_ }) | Select-Object -Last 1
    $decision = if ($lastTurn) { $lastTurn['controller'] } else { $null }
    return @{
        version = '2'; originalOutcome = $State['outcome']; targetReplies = $replies
        finalReplyPresent = [bool]($last -and $last.replyPresent)
        finalReplyDelivered = [bool]($last -and $last.delivered)
        finalTargetStatus = $(if ($last -and $last.controlParsed) { $last.reportedStatus } elseif ($last -and $last.replyPresent) { 'reply_present_status_unknown' } else { 'no_reply_recorded' })
        completionClaimed = [bool]($last -and $last.reportedStatus -eq 'role_task_completed')
        claimedArtifactPaths = @($claimed | Sort-Object -Unique)
        deliveryVerified = [bool]($check -and $check['ready'])
        controllerArtifactCheck = $check
        stopReason = $(if ($decision -and $decision['reason']) { $decision.reason } else { $State['error'] })
    }
}

function New-DialogueState {
    return @{ calls = 0; participantReplies = 0; questions = @(); pending = @(); recoveries = 0; pathRecoveries = 0; outcome = 'running'; turns = @() }
}

function Get-DialoguePathRecovery($Problems, [string]$Repository) {
    $corrections = @()
    $root = [IO.Path]::GetFullPath($Repository).TrimEnd('\', '/')
    $parent = Split-Path $root -Parent
    foreach ($problem in $Problems) {
        if ($problem['root'] -ne $true -or $problem['toolName'] -cne 'view' -or $problem['arguments'] -isnot [System.Collections.IDictionary] -or
            $problem.arguments['path'] -isnot [string] -or $problem.data['error'] -isnot [System.Collections.IDictionary] -or
            $problem.data.error['code'] -cne 'denied') { return @() }
        try {
            $requested = [IO.Path]::GetFullPath($problem.arguments.path, $root)
            if ($requested.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                -not $requested.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                (Test-Path -LiteralPath $requested)) { return @() }
            $relative = [IO.Path]::GetRelativePath($parent, $requested)
            $corrected = [IO.Path]::GetFullPath($relative, $root)
            if (-not $corrected.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $corrected)) { return @() }
            foreach ($path in @($requested, $corrected)) {
                $ancestor = $path
                while ($ancestor) {
                    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return @() }
                    $ancestor = Split-Path $ancestor -Parent
                }
            }
            $corrections += @{ eventId = $problem.eventId; requestedPath = $requested; workspacePath = $corrected; relativePath = $relative }
        } catch { return @() }
    }
    return $corrections
}

function Add-DialoguePending($State, $Message, [string]$Role) {
    $items = @($Message.control.pending)
    foreach ($item in $items) {
        $existing = @($State.questions | Where-Object { $_.id -ceq $item.id })
        $status = if ($item.Contains('questionStatus')) { $item.questionStatus }
            elseif ($Role -eq 'participant') { if ($item['answeredParts']) { 'partially_answered' } else { 'pending' } }
            elseif ($existing.Count) { $existing[0].questionStatus }
            elseif ($Message.control.status -eq 'waiting_reply') { 'awaiting_reply' } else { 'pending' }
        if ($existing.Count -and $existing[0].questionStatus -in @('partially_answered', 'pending') -and $status -eq 'awaiting_reply') {
            $status = $existing[0].questionStatus
        }
        if ($Role -eq 'target' -and $status -eq 'answered' -and
            (-not $existing.Count -or $existing[0].questionStatus -ne 'answered')) { throw 'Target cannot close a question without participant answer evidence.' }
        $revision = @{
            question = $item.question; kind = $item.kind; role = $Role; call = $State.calls
            time = [DateTimeOffset]::UtcNow.ToString('o')
            answeredParts = @($item['answeredParts'] | Where-Object { $null -ne $_ })
            remainingQuestion = $(if ($status -eq 'answered') { $null } elseif ($item.Contains('remainingQuestion')) { $item.remainingQuestion }
                elseif ($existing.Count -and $existing[0].remainingQuestion) { $existing[0].remainingQuestion } else { $item.question })
            questionStatus = $status
        }
        if ($existing.Count) {
            if ($existing[0].kind -cne $item.kind) { throw 'A pending ID cannot be reclassified; retain the decision category.' }
            $existing[0].question = $item.question
            $existing[0].remainingQuestion = $revision.remainingQuestion
            $existing[0].answeredParts = @($existing[0].answeredParts + $revision.answeredParts | Select-Object -Unique)
            $existing[0].questionStatus = $status
            $existing[0].history += $revision
        } else {
            $State.questions += @{
                id = $item.id; kind = $item.kind; originalQuestion = $item.question
                question = $item.question; remainingQuestion = $revision.remainingQuestion
                questionStatus = $status; answeredParts = @($revision.answeredParts); history = @($revision)
            }
        }
        if ($Role -eq 'target' -and $Message.control.status -eq 'waiting_reply') {
            $question = @($State.questions | Where-Object { $_.id -ceq $item.id })[0]
            $question['lastAskedCall'] = $State.calls
            $State['lastQuestionCall'] = $State.calls
        }
    }
    if ($Role -eq 'participant' -and $Message.text -and $Message.control.status -ne 'blocked') {
        foreach ($question in $State.questions) {
            if ($question.questionStatus -eq 'awaiting_reply' -and $question['lastAskedCall'] -eq $State['lastQuestionCall'] -and
                $question.id -cnotin @($items | ForEach-Object { $_.id })) {
                $question.questionStatus = 'answered'
                $question.remainingQuestion = $null
                $question.history += @{ time = [DateTimeOffset]::UtcNow.ToString('o'); role = $Role; call = $State.calls
                    question = $question.question; kind = $question.kind; questionStatus = 'answered'; remainingQuestion = $null
                    answerEvidenceCall = $State.calls; answerEvidenceKind = 'participant_omitted_from_unresolved_batch' }
            }
        }
    }
    $State.pending = @($State.questions | Where-Object { $_.questionStatus -in @('partially_answered', 'pending') })
}

function Test-DialogueArtifacts($Message, $State, [string]$Repository, $Baseline) {
    $State['artifactCheck'] = @{ ready = $false; failures = @(); verifiedPaths = @(); semanticValidation = 'not_assessed' }
    foreach ($question in @($State.questions | Where-Object { $_.questionStatus -eq 'awaiting_reply' })) {
        $State.artifactCheck.failures += @{ reason = 'question_not_answered'; questionId = $question.id }
    }
    if (-not $Message.control.artifactPaths.Count) {
        $State.artifactCheck.failures += @{ reason = 'artifact_path_missing' }
        return $false
    }
    $root = [IO.Path]::GetFullPath($Repository).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($relative in $Message.control.artifactPaths) {
        if ([IO.Path]::IsPathRooted($relative)) {
            $State.artifactCheck.failures += @{ reason = 'artifact_path_not_relative'; path = $relative }
            continue
        }
        $path = [IO.Path]::GetFullPath($relative, $root)
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $State.artifactCheck.failures += @{ reason = 'artifact_outside_workspace'; path = $relative }
            continue
        }
        if ([IO.Path]::GetRelativePath($root, $path) -match '(^|[\\/])(\.venv|node_modules)[\\/]') {
            $State.artifactCheck.failures += @{ reason = 'artifact_dependency_path'; path = $relative }
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $State.artifactCheck.failures += @{ reason = 'artifact_not_found'; path = $relative }
            continue
        }
        $ancestor = $path
        $linked = $false
        while ($ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true; break }
            $ancestor = Split-Path $ancestor -Parent
        }
        if ($linked) {
            $State.artifactCheck.failures += @{ reason = 'artifact_linked'; path = $relative }
            continue
        }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        if ($Baseline.ContainsKey($path) -and $Baseline[$path] -ceq $hash) {
            $State.artifactCheck.failures += @{ reason = 'artifact_unchanged'; path = $relative }
            continue
        }
        $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($content)) {
            $State.artifactCheck.failures += @{ reason = 'artifact_empty'; path = $relative }
            continue
        }
        $State.artifactCheck.verifiedPaths += $relative
        foreach ($pending in $State.pending) {
            $idPattern = '(?<![\p{L}\p{N}_-])' + [regex]::Escape($pending.id) + '(?![\p{L}\p{N}_-])'
            if (-not [regex]::IsMatch($content, $idPattern)) {
                $State.artifactCheck.failures += @{ reason = 'pending_reference_missing'; path = $relative; questionId = $pending.id }
            }
        }
    }
    $State.artifactCheck.ready = $State.artifactCheck.failures.Count -eq 0
    return $State.artifactCheck.ready
}

function Get-DialogueStep($State, $Message, [string]$Role, $Policy, [string]$Repository, $Baseline) {
    if ($Role -cnotin @('target', 'participant')) { throw 'Invalid role.' }
    Add-DialoguePending $State $Message $Role
    if ($Role -eq 'participant' -and $Message.text) {
        $State.participantReplies++
    }
    if ($Role -eq 'target' -and $Message.control.status -eq 'role_task_completed') {
        if ($Policy.ContainsKey('minimumParticipantReplies') -and $State.participantReplies -lt $Policy.minimumParticipantReplies) {
            if ($State.calls -ge $Policy.callLimit) {
                $State.outcome = 'budget_exceeded'
                return @{ action = 'stop'; reason = 'call_limit_before_required_interaction' }
            }
            if ($State.recoveries -ge $Policy.maxCoordinatorPrompts) {
                $State.outcome = 'stalled'
                return @{ action = 'stop'; reason = 'required_interaction_missing' }
            }
            $State.recoveries++
            return @{ action = 'prompt'; role = 'target'; text = $Policy.interactionPrompt }
        }
        if ($State.pending.Count -and -not $Policy.allowPendingDraft) {
            $State.outcome = 'blocked_external'
            return @{ action = 'stop'; reason = 'pending_draft_not_authorized' }
        }
        $unanswered = @($State.questions | Where-Object { $_.questionStatus -eq 'awaiting_reply' })
        if (-not $Policy.requireArtifact) {
            $State['artifactCheck'] = @{ ready = $unanswered.Count -eq 0; verifiedPaths = @(); semanticValidation = 'not_assessed'
                failures = @($unanswered | ForEach-Object { @{ reason = 'question_not_answered'; questionId = $_.id } }) }
        }
        if (($Policy.requireArtifact -and (Test-DialogueArtifacts $Message $State $Repository $Baseline)) -or
            (-not $Policy.requireArtifact -and $unanswered.Count -eq 0)) {
            $State.outcome = if ($State.pending.Count) { 'completed_with_pending' } else { 'stage_completed' }
            return @{ action = 'stop'; reason = 'verified_stage_delivery'; artifactCheck = $State['artifactCheck'] }
        }
    }
    if ($Role -eq 'target' -and $Message.control.status -eq 'blocked') {
        $State.outcome = 'blocked_external'
        return @{ action = 'stop'; reason = 'agent_reported_blocker' }
    }
    if ($State.calls -ge $Policy.callLimit) {
        $State.outcome = 'budget_exceeded'
        return @{ action = 'stop'; reason = 'call_limit' }
    }
    if ($Message.control.status -eq 'waiting_reply' -or ($Role -eq 'participant' -and $Message.text)) {
        return @{
            action = 'send'; role = $(if ($Role -eq 'target') { 'participant' } else { 'target' })
            text = $Message.text; senderStatus = $Message.control.status
        }
    }
    if ($State.recoveries -ge $Policy.maxCoordinatorPrompts) {
        $State.outcome = 'stalled'
        return @{ action = 'stop'; reason = 'coordination_budget_exhausted'; artifactCheck = $State['artifactCheck'] }
    }
    $State.recoveries++
    $recoveryText = $Policy.coordinatorPrompt
    if ($Role -eq 'target' -and $Message.control.status -eq 'role_task_completed') {
        $details = ConvertTo-Json -InputObject $State.artifactCheck.failures -Depth 8 -Compress
        $recoveryText = "完成声明尚未通过交付检查。具体失败项：$details。请修复对应产物或待决编号引用；自然语言不要求逐字一致。若不能交付，请说明具体阻塞。"
    }
    return @{ action = 'prompt'; role = 'target'; text = $recoveryText; reason = 'completion_evidence_missing_or_empty_handoff'; artifactCheck = $State['artifactCheck'] }
}

Export-ModuleMember -Function Get-DialogueWorkspaceFiles, Read-DialogueMessage, New-DialogueState, Get-DialogueStep, Get-DialoguePathRecovery, Get-DialogueCompletionFacts