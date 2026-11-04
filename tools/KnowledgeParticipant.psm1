#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-KpKeys($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [System.Collections.IDictionary]) { throw 'Expected an object.' }
    foreach ($key in $Required) { if (-not $Value.Contains($key)) { throw "Missing field: $key" } }
    foreach ($key in $Value.Keys) { if ($key -cnotin ($Required + $Optional)) { throw "Unexpected field: $key" } }
}

function Assert-KpText($Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw 'Expected nonempty text.' }
}

function Assert-KpList($Value) {
    if ($Value -isnot [array]) { throw 'Expected an array.' }
    foreach ($entry in $Value) { Assert-KpText $entry }
    if (@($Value | Sort-Object -Unique).Count -ne $Value.Count) { throw 'Duplicate list entry.' }
}

function Get-KpHash([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

function Read-KpKnowledge([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $text = Get-Content -LiteralPath $resolved -Raw -Encoding utf8
    $knowledge = ConvertFrom-Json -InputObject $text -AsHashtable
    Assert-KpKeys $knowledge @('schemaVersion', 'id', 'version', 'initialRequest', 'sources', 'facts', 'ruleSets', 'unknowns')
    if ($knowledge.schemaVersion -ne 1) { throw 'Unsupported knowledge schema.' }
    foreach ($key in @('id', 'version', 'initialRequest')) { Assert-KpText $knowledge[$key] }
    foreach ($key in @('sources', 'facts', 'ruleSets', 'unknowns')) {
        if ($knowledge[$key] -isnot [array]) { throw "$key must be an array." }
    }
    if (-not $knowledge.sources.Count) { throw 'Knowledge requires an approval source.' }
    $sources = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($source in $knowledge.sources) {
        Assert-KpKeys $source @('id', 'path', 'version', 'sha256')
        foreach ($key in $source.Keys) { Assert-KpText $source[$key] }
        if ($sources.ContainsKey($source.id)) { throw 'Duplicate source ID.' }
        $sourcePath = [IO.Path]::GetFullPath((Join-Path (Split-Path $resolved) $source.path))
        if ((Get-FileHash -LiteralPath $sourcePath).Hash -cne $source.sha256) { throw 'Source hash changed; review the knowledge migration.' }
        $original = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if ($original.version -cne $source.version) { throw 'Source version mismatch.' }
        $sources[$source.id] = $original
    }
    $facts = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($fact in $knowledge.facts) {
        Assert-KpKeys $fact @('id', 'topic', 'intent', 'answer', 'questions', 'exclude', 'sources')
        foreach ($key in @('id', 'topic', 'intent', 'answer')) { Assert-KpText $fact[$key] }
        Assert-KpList $fact.questions; Assert-KpList $fact.exclude
        if (-not $fact.questions.Count -or $fact.sources -isnot [array] -or -not $fact.sources.Count) { throw 'Facts require question examples and provenance.' }
        if ($facts.ContainsKey($fact.id)) { throw 'Duplicate fact ID.' }
        foreach ($reference in $fact.sources) {
            Assert-KpKeys $reference @('sourceId', 'answerId')
            if (-not $sources.ContainsKey($reference.sourceId) -or $reference.answerId -cnotin @($sources[$reference.sourceId].answers.id)) { throw 'Unknown source answer.' }
        }
        $facts[$fact.id] = $fact
    }
    if (-not $facts.Count) { throw 'Knowledge requires approved facts.' }
    $ruleSets = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($ruleSet in $knowledge.ruleSets) {
        Assert-KpKeys $ruleSet @('id', 'intent', 'factIds', 'questions', 'exclude')
        Assert-KpText $ruleSet.id; Assert-KpText $ruleSet.intent
        Assert-KpList $ruleSet.factIds; Assert-KpList $ruleSet.questions; Assert-KpList $ruleSet.exclude
        if (-not $ruleSet.factIds.Count -or $ruleSets.ContainsKey($ruleSet.id)) { throw 'Empty or duplicate ruleset.' }
        foreach ($id in $ruleSet.factIds) { if (-not $facts.ContainsKey($id)) { throw 'Unknown ruleset fact.' } }
        $ruleSets[$ruleSet.id] = $ruleSet
    }
    $unknowns = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($unknown in $knowledge.unknowns) {
        Assert-KpKeys $unknown @('id', 'intent', 'questions', 'reason', 'evidence') @('category')
        foreach ($key in @('id', 'intent', 'reason', 'evidence')) { Assert-KpText $unknown[$key] }
        Assert-KpList $unknown.questions
        if ($unknown.Contains('category') -and $unknown.category -cnotin @('business_decision', 'baseline_investigation', 'technical_followup', 'unclassified')) { throw 'Unknown unresolved category.' }
        if ($unknowns.ContainsKey($unknown.id) -or $facts.ContainsKey($unknown.id)) { throw 'Duplicate unknown ID.' }
        $unknowns[$unknown.id] = $unknown
    }
    return @{ document = $knowledge; hash = (Get-FileHash -LiteralPath $resolved).Hash; facts = $facts; ruleSets = $ruleSets; unknowns = $unknowns }
}

function New-KpRequest($Knowledge, [string]$Message, $Receipt = $null) {
    Assert-KpText $Message
    $delivered = @()
    if ($null -ne $Receipt) {
        Assert-KpKeys $Receipt @('protocolVersion', 'knowledgeHash', 'responseHash', 'deliveredFactIds')
        if ($Receipt.protocolVersion -cne 'knowledge-participant-v1' -or $Receipt.knowledgeHash -cne $Knowledge.hash) { throw 'Receipt belongs to another knowledge version.' }
        Assert-KpText $Receipt.responseHash
        Assert-KpList $Receipt.deliveredFactIds
        foreach ($id in $Receipt.deliveredFactIds) { if (-not $Knowledge.facts.ContainsKey($id)) { throw 'Unknown delivered fact.' } }
        $delivered = @($Receipt.deliveredFactIds)
    }
    return [ordered]@{
        protocolVersion = 'knowledge-participant-v1'; knowledgeHash = $Knowledge.hash
        message = $Message; messageHash = Get-KpHash $Message
        knowledge = $Knowledge.document; deliveredFactIds = $delivered
    }
}

function Resolve-KpDecision($Knowledge, $Request, $Decision) {
    Assert-KpKeys $Request @('protocolVersion', 'knowledgeHash', 'message', 'messageHash', 'knowledge', 'deliveredFactIds')
    Assert-KpText $Request.message; Assert-KpList $Request.deliveredFactIds
    if ($Request.protocolVersion -cne 'knowledge-participant-v1' -or $Request.knowledgeHash -cne $Knowledge.hash -or $Request.messageHash -cne (Get-KpHash $Request.message)) { throw 'Request identity mismatch.' }
    Assert-KpKeys $Decision @('protocolVersion', 'items')
    if ($Decision.protocolVersion -cne 'knowledge-participant-v1' -or $Decision.items -isnot [array]) { throw 'Invalid decision protocol.' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $selected = [System.Collections.Generic.List[string]]::new()
    $audit = @()
    foreach ($item in $Decision.items) {
        Assert-KpKeys $item @('kind', 'quote', 'factIds') @('ruleSetId', 'unknownId', 'unknownKind')
        Assert-KpText $item.quote; Assert-KpList $item.factIds
        if (-not $Request.message.Contains($item.quote, [StringComparison]::Ordinal)) { throw 'Quote must come from the latest counterpart message.' }
        if ($item.kind -cnotin @('answer', 'ruleset', 'unknown', 'clarify', 'scope', 'correct')) { throw 'Unknown response kind.' }
        if ($item.Contains('ruleSetId') -and $item.kind -cne 'ruleset') { throw 'Only a ruleset request may expand a ruleset.' }
        if ($item.Contains('unknownId') -and ($item.kind -cne 'unknown' -or -not $Knowledge.unknowns.ContainsKey($item.unknownId))) { throw 'Invalid unknown reference.' }
        if ($item.Contains('unknownKind') -and ($item.kind -cne 'unknown' -or $item.unknownKind -cnotin @('business_decision', 'baseline_investigation', 'technical_followup', 'unclassified'))) { throw 'Invalid unresolved classification.' }
        if ($item.kind -ceq 'unknown') {
            $category = 'unclassified'
            if ($item.Contains('unknownId')) {
                $knownUnknown = $Knowledge.unknowns[$item.unknownId]
                $category = if ($knownUnknown.Contains('category')) { $knownUnknown.category } else { 'business_decision' }
                if ($item.Contains('unknownKind') -and $item.unknownKind -cne $category) { throw 'A catalogued decision cannot be reclassified by the participant.' }
            } elseif ($item.Contains('unknownKind')) { $category = $item.unknownKind }
            $item = $item.Clone()
            $item['unknownKind'] = $category
        }
        foreach ($id in $item.factIds) { if (-not $Knowledge.facts.ContainsKey($id)) { throw 'Unapproved fact.' } }
        switch -CaseSensitive ($item.kind) {
            'answer' { if ($item.factIds.Count -ne 1) { throw 'One atomic question selects one fact; split independent questions.' } }
            'ruleset' {
                if (-not $item.Contains('ruleSetId') -or -not $Knowledge.ruleSets.ContainsKey($item.ruleSetId)) { throw 'Unknown ruleset.' }
                $allowed = $Knowledge.ruleSets[$item.ruleSetId].factIds
                if (($item.factIds -join ',') -cne ($allowed -join ',')) { throw 'Ruleset selection must match its explicit bounded members.' }
            }
            'correct' {
                if ($item.factIds.Count -ne 1 -or $item.factIds[0] -cnotin $Request.deliveredFactIds) { throw 'Corrections require one actually delivered fact.' }
            }
            default { if ($item.factIds.Count) { throw 'Unknown, ambiguous and generic scope requests cannot disclose facts.' } }
        }
        $lines.Add("关于：$($item.quote)")
        if ($item.kind -in @('answer', 'ruleset', 'correct')) {
            foreach ($id in $item.factIds) {
                $lines.Add($Knowledge.facts[$id].answer)
                if (-not $selected.Contains($id)) { $selected.Add($id) }
            }
        } elseif ($item.kind -eq 'unknown') {
            $lines.Add($(switch ($item.unknownKind) {
                'business_decision' { '现有知识库未提供这项业务选择的批准决定，保留待业务方确认，不选择默认方案。' }
                'baseline_investigation' { '这部分需要核实现行基线及证据；知识库没有提供核实结果，不能把现状猜测当成批准规则。' }
                'technical_followup' { '这部分属于技术或测试跟进，需相关负责人核实；知识库未指定具体方案，不据此新增业务决定、降低验收要求或授权实施。' }
                default { '现有知识库不足以回答这部分，需先区分业务选择、基线核实或技术跟进；不自动认定为业务阻塞，也不选择默认方案。' }
            }))
        } elseif ($item.kind -eq 'clarify') {
            $lines.Add('这个问题的具体含义尚不明确，请明确你希望确认的对象或规则。')
        } else {
            $lines.Add('本条不新增业务决定；仅确认此前已明确答复的内容，不确认未讨论事项，也不授权起草、实现或发布。')
        }
        $audit += $item
    }
    $text = $lines -join "`n"
    return [ordered]@{
        protocolVersion = 'knowledge-participant-v1'; knowledgeHash = $Knowledge.hash
        messageHash = $Request.messageHash; responseHash = Get-KpHash $text
        text = $text; selectedFactIds = @($selected); priorDeliveredFactIds = @($Request.deliveredFactIds)
        audit = $audit; semanticValidation = 'requires_review'; grantsDrafting = $false
    }
}

function Confirm-KpDelivery($Response, [string]$DeliveredText) {
    if ($Response.responseHash -cne (Get-KpHash $DeliveredText) -or $DeliveredText -cne $Response.text) { throw 'Delivered text does not match the validated response.' }
    return [ordered]@{
        protocolVersion = 'knowledge-participant-v1'; knowledgeHash = $Response.knowledgeHash
        responseHash = $Response.responseHash
        deliveredFactIds = @(@($Response.priorDeliveredFactIds) + @($Response.selectedFactIds) | Sort-Object -Unique)
    }
}

Export-ModuleMember -Function Read-KpKnowledge, New-KpRequest, Resolve-KpDecision, Confirm-KpDelivery