#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$KnowledgeFile,
    [string]$Model = 'gpt-6-astra',
    [string]$CliPath,
    [string]$SessionDirectory,
    [switch]$Resume,
    [switch]$UseGitHubCliAuth,
    [ValidateRange(1,86400)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$framework = Split-Path $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'Invoke-KnowledgeParticipant.ps1'
Import-Module (Join-Path $PSScriptRoot 'KnowledgeParticipant.psm1') -Force

function Write-ChatJson([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Assert-ChatPath([string]$Path) {
    $frameworkRoot = [IO.Path]::GetFullPath($framework).TrimEnd('\', '/')
    if ($Path.Equals($frameworkRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($frameworkRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '会话证据必须放在评估和产品仓库之外。' }
    $ancestor = $Path
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '会话路径不能包含链接。' }
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw '请使用 Git 仓库之外的私有会话目录。' }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
}

function Get-ChatContract {
    $contract = [ordered]@{ knowledge = (Get-FileHash -LiteralPath $KnowledgeFile).Hash }
    foreach ($relative in @('tools/Start-KnowledgeChat.ps1', 'tools/Invoke-KnowledgeParticipant.ps1', 'tools/KnowledgeParticipant.psm1', 'tools/Invoke-SdlcCapture.ps1', 'tools/CapturedProcess.psm1', 'agents/knowledge-participant.agent.md')) {
        $contract[$relative] = (Get-FileHash -LiteralPath (Join-Path $framework $relative)).Hash
    }
    return $contract
}

function Assert-ChatContract {
    $current = Get-ChatContract
    foreach ($key in $current.Keys) { if ($current[$key] -cne $state.contract[$key]) { throw "会话输入已变化，请新建会话：$key" } }
    [void](Read-KpKnowledge $KnowledgeFile)
}

function Read-ChatResponse([string]$Turn) {
    $responsePath = Join-Path $Turn 'response.json'
    $seal = Get-Content (Join-Path $Turn 'response-manifest.json') -Raw | ConvertFrom-Json
    if ((Get-FileHash $responsePath).Hash -cne $seal.sha256) { throw '候选回答已被修改，拒绝复制或登记。' }
    return (Get-Content $responsePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
}

function Show-ChatResponse($Response) {
    Write-Host ''
    Write-Host '----- 业务回答开始 -----'
    Write-Host $Response.text
    Write-Host '----- 业务回答结束 -----'
    Write-Host '请先检查是否漏答或越界。/copy 复制；原样转发后 /sent 确认；未转发用 /discard；/quit 保留待确认状态退出。'
}

function Copy-ChatText([string]$Text) {
    try { Set-Clipboard -Value $Text -ErrorAction Stop; Write-Host '已复制业务文本，尚未登记为已转发。' }
    catch { Write-Host '剪贴板不可用，请手动复制业务文本；尚未登记为已转发。' }
}

function Show-ChatUnknowns {
    Write-Host '----- 操作员待处理记录（不要复制给 PM）-----'
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($turn in $state.turns) {
        if (-not $turn.Contains('unknowns')) { continue }
        foreach ($unknown in $turn.unknowns) {
            if ($seen.Add($unknown.key)) {
                $label = switch ($unknown.category) {
                    'business_decision' { '业务待决' }
                    'baseline_investigation' { '基线核实' }
                    'technical_followup' { '技术跟进' }
                    default { '尚未分类' }
                }
                Write-Host "[$label] $($unknown.quote)"
            }
        }
    }
    if (-not $seen.Count) { Write-Host '没有已记录的未知回答；这不证明所有需求均已明确。' }
}

function Get-UnknownStreak {
    $count = 0
    for ($index = $state.turns.Count - 1; $index -ge 0; $index--) {
        $turn = $state.turns[$index]
        if (-not $turn.Contains('onlyUnknown') -or -not $turn.onlyUnknown) { break }
        $count++
    }
    return $count
}

if ($Resume -and -not $SessionDirectory) { throw '恢复会话需要指定 -SessionDirectory。' }
if (-not $Resume -and [string]::IsNullOrWhiteSpace($KnowledgeFile)) {
    throw 'New chats require -KnowledgeFile pointing to external knowledge.'
}
if (-not $SessionDirectory) {
    $base = if ($IsWindows) { Join-Path ([IO.Path]::GetPathRoot($framework)) 'ai-sdlc-eval-runs' } else { Join-Path $HOME 'ai-sdlc-eval-runs' }
    $SessionDirectory = Join-Path $base ('manual-kp-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
}
$root = [IO.Path]::GetFullPath($SessionDirectory)
Assert-ChatPath $root
$statePath = Join-Path $root 'chat.json'
if ($Resume) {
    $state = Get-Content $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($state.schemaVersion -ne 1 -or $state.root -cne $root) { throw '会话身份不匹配。' }
    foreach ($key in @('KnowledgeFile', 'Model', 'CliPath')) {
        if ($PSBoundParameters.ContainsKey($key)) {
            $value = Get-Variable $key -ValueOnly
            if ($key -eq 'KnowledgeFile') { $value = (Resolve-Path $value).Path }
            if ($value -cne $state[$key]) { throw "恢复时不能改变 $key。" }
        }
    }
    $KnowledgeFile = $state.KnowledgeFile; $Model = $state.Model; $CliPath = $state.CliPath
} else {
    if (Test-Path -LiteralPath $root) { throw '目录已存在；使用新目录或显式 -Resume，不自动重发调用。' }
    $KnowledgeFile = (Resolve-Path -LiteralPath $KnowledgeFile).Path
    if (-not $CliPath) {
        $command = Get-Command copilot -ErrorAction SilentlyContinue
        if ($command -and [IO.Path]::GetExtension($command.Source) -notin @('.cmd', '.bat')) { $CliPath = $command.Source }
        elseif ($IsWindows -and $env:APPDATA) {
            $bundled = Join-Path $env:APPDATA 'Code/User/globalStorage/github.copilot-chat/copilotCli/copilot.ps1'
            if (Test-Path $bundled) { $CliPath = $bundled }
        }
    }
    if (-not $CliPath) { throw '找不到 Copilot CLI，请用 -CliPath 指定 copilot.ps1 或可执行文件。' }
    $CliPath = (Get-Command $CliPath -ErrorAction Stop).Source
    if ([string]::IsNullOrWhiteSpace($Model) -or $Model -eq 'auto') { throw '请选择明确模型，不能使用 auto。' }
    $knowledge = Read-KpKnowledge $KnowledgeFile
    [void](New-Item -ItemType Directory -Path $root)
    $state = [ordered]@{
        schemaVersion = 1; root = $root; KnowledgeFile = $KnowledgeFile; Model = $Model; CliPath = $CliPath
        contract = Get-ChatContract; status = 'ready'; pendingTurn = $null; receiptFile = $null; turns = @()
    }
    Write-ChatJson $statePath $state
}
$lock = [IO.File]::Open((Join-Path $root 'chat.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$savedPath = $env:PATH
$savedInputEncoding = [Console]::InputEncoding
$savedOutputEncoding = [Console]::OutputEncoding
$savedTokens = @{}
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $env:PATH = $PSHOME + [IO.Path]::PathSeparator + $env:PATH
    if ($UseGitHubCliAuth) {
        foreach ($name in @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    Assert-ChatContract
    $knowledge = Read-KpKnowledge $KnowledgeFile
    if ($state.status -in @('calling', 'failed')) { throw '上次调用未完成或失败，证据已保留。不自动重发；请检查后另建会话。' }
    if ($state.status -eq 'acknowledging') {
        $receiptPath = Join-Path $state.pendingTurn 'delivery.json'
        if (-not (Test-Path $receiptPath)) { throw '上次转发登记中断，请检查证据，不自动推定已完成。' }
        $state.receiptFile = $receiptPath; $state.pendingTurn = $null; $state.status = 'ready'
        $state.turns[-1].status = 'sent'
        Write-ChatJson $statePath $state
    }
    Write-Host "通用业务参与者 | 模型：$Model"
    Write-Host "私有证据：$root"
    Write-Host '每次 /send 会调用模型并产生费用；本工具不启动 Luna，不自动发送给 PM，也不授权起草。'
    Write-Host '先在 VS Code 的 Luna + PM Agent 窗口发送以下初始需求（/initial 可复制）：'
    Write-Host $knowledge.document.initialRequest
    Write-Host '粘贴多行 PM 回复，以单独一行 /send 提交。/pending 看未知记录；/feedback 内容 记录意见；/quit 退出；/help 显示命令。'
    $buffer = [System.Collections.Generic.List[string]]::new()
    $response = $null
    if ($state.status -eq 'review') { $response = Read-ChatResponse $state.pendingTurn; Show-ChatResponse $response }
    if ((Get-UnknownStreak) -ge 2) { Write-Host '操作员提示：已连续两轮只有未知回答。请先处理 /pending；确有新信息再用 /send-anyway 明确继续。' }
    while ($true) {
        Write-Host 'kp> ' -NoNewline
        $line = [Console]::ReadLine()
        if ($null -eq $line -or $line -ceq '/quit') { break }
        if ($line -ceq '/help') {
            Write-Host '/send 提交；/send-anyway 明确越过重复未知提醒；/cancel 清空；/initial 复制初始需求；/copy 复制回答；/sent 确认已原样转发；/discard 丢弃未转发回答；/pending 看记录；/feedback 内容 仅记录操作员意见；/quit 退出。'
            continue
        }
        if ($line -ceq '/pending') { Show-ChatUnknowns; continue }
        if ($line.StartsWith('/feedback ', [StringComparison]::Ordinal)) {
            $note = $line.Substring(10).Trim()
            if (-not $note) { Write-Host '意见为空，未记录。'; continue }
            if (-not $state.Contains('feedback')) { $state['feedback'] = @() }
            $state.feedback += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); turn = $state.turns.Count; text = $note }
            Write-ChatJson $statePath $state
            Write-Host '已记录操作员意见，未发送给任何模型，也未改变批准答案或转发台账。'
            continue
        }
        if ($state.status -eq 'review') {
            switch -CaseSensitive ($line) {
                '/copy' { $response = Read-ChatResponse $state.pendingTurn; Copy-ChatText $response.text }
                '/sent' {
                    Assert-ChatContract
                    $response = Read-ChatResponse $state.pendingTurn
                    $state.status = 'acknowledging'; Write-ChatJson $statePath $state
                    $delivered = Join-Path $state.pendingTurn 'manual-forwarded.txt'
                    $response.text | Set-Content $delivered -Encoding utf8 -NoNewline
                    Write-ChatJson (Join-Path $state.pendingTurn 'manual-attestation.json') @{
                        kind = 'operator_attestation'; assertedAt = [DateTimeOffset]::UtcNow.ToString('o')
                        responseHash = $response.responseHash; statement = 'Operator confirmed the entire response was forwarded unchanged; not automatically observed.'
                    }
                    & $runner -Mode Acknowledge -KnowledgeFile $KnowledgeFile -TurnDirectory $state.pendingTurn -DeliveredTextFile $delivered *> (Join-Path $state.pendingTurn 'acknowledge.log')
                    $state.receiptFile = Join-Path $state.pendingTurn 'delivery.json'
                    $state.turns[-1].status = 'sent'; $state.pendingTurn = $null; $state.status = 'ready'
                    Write-ChatJson $statePath $state
                    $response = $null
                    Write-Host '已按你的人工确认登记转发。请粘贴 PM 的下一条回复。'
                }
                '/discard' {
                    $state.turns[-1].status = 'discarded'; $state.pendingTurn = $null; $state.status = 'ready'
                    Write-ChatJson $statePath $state
                    $response = $null
                    Write-Host '已丢弃候选回答，未更新披露台账。'
                }
                default { Write-Host '当前回答尚待确认；请先 /sent、/discard 或 /quit，不接收下一轮问题。' }
            }
            continue
        }
        if ($line -ceq '/initial') { Copy-ChatText $knowledge.document.initialRequest; continue }
        if ($line -ceq '/cancel') { $buffer.Clear(); Write-Host '已清空，未调用模型。'; continue }
        if ($line -cin @('/send', '/send-anyway')) {
            $message = $buffer -join "`n"
            if ([string]::IsNullOrWhiteSpace($message)) { Write-Host '问题为空，未调用模型。'; continue }
            if ($line -ceq '/send' -and (Get-UnknownStreak) -ge 2) {
                Write-Host '连续未知保护：已连续两轮没有批准答案，重复调用未必能解决。输入已保留，未调用模型。请查看 /pending；补充业务决定或核实技术基线后，确需继续用 /send-anyway。'
                continue
            }
            Assert-ChatContract
            $index = $state.turns.Count + 1
            $turn = Join-Path $root ('turn-{0:d3}' -f $index)
            $messagePath = Join-Path $root ('message-{0:d3}.txt' -f $index)
            $message | Set-Content -LiteralPath $messagePath -Encoding utf8 -NoNewline
            $state.pendingTurn = $turn; $state.status = 'calling'
            $state.turns += @{ index = $index; path = $turn; status = 'calling'; repeatOverride = ($line -ceq '/send-anyway') }
            Write-ChatJson $statePath $state
            $parameters = @{ Mode = 'Invoke'; KnowledgeFile = $KnowledgeFile; MessageFile = $messagePath; TurnDirectory = $turn; Model = $Model; CliPath = $CliPath; TimeoutSeconds = $TimeoutSeconds }
            if ($state.receiptFile) { $parameters.ReceiptFile = $state.receiptFile }
            $log = Join-Path $root ('turn-{0:d3}.log' -f $index)
            Write-Host '正在调用模拟人...'
            try {
                & $runner @parameters *> $log
                $response = Read-ChatResponse $turn
            } catch {
                $state.status = 'failed'; $state.turns[-1].status = 'failed'
                Write-ChatJson $statePath $state
                throw "调用或校验失败，未自动重试。日志：$log；$($_.Exception.Message)"
            }
            $buffer.Clear()
            $unknownItems = @($response.audit | Where-Object { $_.kind -eq 'unknown' })
            $state.turns[-1]['unknowns'] = @($unknownItems | ForEach-Object {
                $category = if ($_.Contains('unknownKind')) { $_.unknownKind } else { 'unclassified' }
                $key = if ($_.Contains('unknownId')) { $_.unknownId } else { $category + ':' + [regex]::Replace($_.quote.Trim(), '\s+', ' ') }
                @{ key = $key; category = $category; quote = $_.quote }
            })
            $state.turns[-1]['onlyUnknown'] = $unknownItems.Count -gt 0 -and $unknownItems.Count -eq $response.audit.Count
            if ([string]::IsNullOrWhiteSpace($response.text)) {
                $state.status = 'ready'; $state.pendingTurn = $null; $state.turns[-1].status = 'no_reply'
                Write-ChatJson $statePath $state
                Write-Host '模拟人未选择可回答的问题；不新增业务答复，不代表需求完整或允许起草。'
            } else {
                $state.status = 'review'; $state.turns[-1].status = 'review'
                Write-ChatJson $statePath $state
                Show-ChatResponse $response
                if ((Get-UnknownStreak) -ge 2) {
                    Write-Host '操作员提示：已连续两轮只有未知回答。这不是等待模型多想一轮即可解决；请先核对知识缺口或技术跟进。下一次 /send 将暂停，/send-anyway 可明确继续。'
                    Show-ChatUnknowns
                }
            }
            continue
        }
        if ($line -cin @('/copy', '/sent', '/discard')) { Write-Host '当前没有待审阅回答，未更新台账。'; continue }
        $buffer.Add($line)
    }
    Write-Host "会话已保留：$root"
    Write-Host "恢复：pwsh -NoProfile -File `"$PSCommandPath`" -SessionDirectory `"$root`" -Resume"
} finally {
    $env:PATH = $savedPath
    [Console]::InputEncoding = $savedInputEncoding
    [Console]::OutputEncoding = $savedOutputEncoding
    foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name], 'Process') }
    $lock.Dispose()
}