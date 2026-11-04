#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$framework = Split-Path $PSScriptRoot
$runner = Join-Path $framework 'tools/Start-KnowledgeChat.ps1'
$fake = Join-Path $PSScriptRoot 'fixtures/fake-knowledge-participant.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('knowledge-chat-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-Chat([string]$Name, [string]$InputText, [switch]$ResumeChat, [int]$ExpectedExit = 0) {
    $session = Join-Path $fixture $Name
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME 'pwsh.exe'
    $start.UseShellExecute = $false; $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in @('-NoProfile','-File',$runner,'-SessionDirectory',$session)) { $start.ArgumentList.Add($argument) }
    if ($ResumeChat) { $start.ArgumentList.Add('-Resume') }
    else { foreach ($argument in @('-Model','fixture-model','-CliPath',$fake,'-KnowledgeFile',(Join-Path $fixture 'knowledge.json'))) { $start.ArgumentList.Add($argument) } }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($InputText); $process.StandardInput.Close()
    if (-not $process.WaitForExit(90000)) { $process.Kill($true); throw 'Chat fixture timed out.' }
    $output = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
    Assert ($process.ExitCode -eq $ExpectedExit) "Chat exit $($process.ExitCode): $output $errorText"
    $process.Dispose()
    return @{ session = $session; state = (Get-Content (Join-Path $session 'chat.json') -Raw | ConvertFrom-Json); output = $output }
}
try {
    [void](New-Item -ItemType Directory -Path $fixture)
    $missingKnowledgeSession = Join-Path $fixture 'missing-knowledge'
    $rejected = $false
    try { & $runner -SessionDirectory $missingKnowledgeSession | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*require -KnowledgeFile*' }
    Assert ($rejected -and -not (Test-Path $missingKnowledgeSession)) 'New chat requires explicit knowledge without creating a session.'
    $approval = Join-Path $fixture 'approval.json'
    @{ version = 'fixture'; answers = @(@{ id = 'unique'; text = 'Synthetic names are unique.' }) } |
        ConvertTo-Json -Depth 5 | Set-Content $approval
    @{ schemaVersion = 1; id = 'synthetic-chat'; version = '1'; initialRequest = 'Synthetic fixture only.'
        sources = @(@{ id = 'fixture'; path = 'approval.json'; version = 'fixture'; sha256 = (Get-FileHash $approval).Hash })
        facts = @(@{ id = 'name.unique'; topic = 'Synthetic names'; intent = 'Uniqueness'; answer = 'Synthetic names are unique.'
            questions = @('用户名是否唯一？'); exclude = @(); sources = @(@{ sourceId = 'fixture'; answerId = 'unique' }) })
        ruleSets = @(); unknowns = @(@{ id = 'unknown.existing-sessions'; intent = 'Synthetic unknown'
            questions = @('Fixture unknown'); reason = 'Not decided'; evidence = 'Fixture'; category = 'business_decision' })
    } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture 'knowledge.json')
    $pending = Invoke-Chat 'manual' "/send`n用户名是否唯一？`n请只回答这一项。`n/send`n/quit`n"
    Assert ($pending.state.status -eq 'review' -and $pending.state.turns.Count -eq 1) "Empty input does not call; a reply waits for review. State=$($pending.state | ConvertTo-Json -Depth 8 -Compress) Output=$($pending.output)"
    Assert (-not (Test-Path (Join-Path $pending.session 'turn-001/delivery.json'))) 'Displayed answer is not delivery.'
    $request = Get-Content (Join-Path $pending.session 'turn-001/request.json') -Raw | ConvertFrom-Json
    Assert ($request.message -ceq "用户名是否唯一？`n请只回答这一项。") 'Multiline paste is preserved.'
    $continued = Invoke-Chat 'manual' "/sent`n用户名是否唯一？`n/send`n/discard`n/quit`n" -ResumeChat
    Assert ($continued.state.status -eq 'ready' -and $continued.state.turns.Count -eq 2) 'Resume does not repeat the first call.'
    Assert ($continued.state.turns[0].status -eq 'sent' -and $continued.state.turns[1].status -eq 'discarded') 'Manual confirmation and discard are distinct.'
    $request = Get-Content (Join-Path $continued.session 'turn-002/request.json') -Raw | ConvertFrom-Json
    Assert ($request.deliveredFactIds -contains 'name.unique') 'Confirmed forwarding enables the next-turn ledger.'
    Assert (-not (Test-Path (Join-Path $continued.session 'turn-002/delivery.json'))) 'Discarded reply creates no receipt.'
    $attestation = Get-Content (Join-Path $continued.session 'turn-001/manual-attestation.json') -Raw | ConvertFrom-Json
    Assert ($attestation.kind -eq 'operator_attestation') 'Manual delivery is never labeled automatically observed.'
    $cancelled = Invoke-Chat 'cancel' "取消这段`n/cancel`n/send`n/quit`n"
    Assert ($cancelled.state.turns.Count -eq 0) 'Cancel makes no call.'
    $unsent = Invoke-Chat 'discard' "用户名是否唯一？`n/send`n/discard`n/api/login`n用户名是否唯一？`n/send`n/quit`n"
    $unsentRequest = Get-Content (Join-Path $unsent.session 'turn-002/request.json') -Raw | ConvertFrom-Json
    Assert ($unsentRequest.deliveredFactIds.Count -eq 0) 'Discard does not leak selected facts into the next request.'
    Assert ($unsentRequest.message.StartsWith('/api/login')) 'Unrecognized slash-prefixed content remains part of the pasted message.'
    $empty = Invoke-Chat 'empty-reply' "Fixture no question.`n/send`n/quit`n"
    Assert ($empty.state.status -eq 'ready' -and $empty.state.turns[0].status -eq 'no_reply') 'An empty response is not a completion or delivery.'
    Assert (-not (Test-Path (Join-Path $empty.session 'turn-001/delivery.json'))) 'Empty response has no fabricated receipt.'
    $failed = Invoke-Chat 'failure' "Fixture invalid decision.`n/send`n" -ExpectedExit 1
    Assert ($failed.state.status -eq 'failed' -and $failed.state.turns.Count -eq 1) 'Invalid model decision is retained without retry.'
    $refused = Invoke-Chat 'failure' '/quit' -ResumeChat -ExpectedExit 1
    Assert ($refused.state.turns.Count -eq 1) 'Failed session cannot automatically resend on resume.'
    $loop = Invoke-Chat 'unknown-loop' "Fixture unknown one.`n/send`n/feedback 此问题应分类后处理`n/sent`nFixture unknown two.`n/send`n/pending`n/sent`nFixture unknown three.`n/send`n/quit`n"
    Assert ($loop.state.turns.Count -eq 2 -and $loop.output.Contains('连续未知保护')) 'Third unknown-only exchange is blocked before another paid call.'
    Assert ($loop.state.feedback.Count -eq 1 -and $loop.state.feedback[0].text -eq '此问题应分类后处理') 'Operator feedback is recorded during review.'
    $loopRequest = Get-Content (Join-Path $loop.session 'turn-002/request.json') -Raw
    Assert (-not $loopRequest.Contains('此问题应分类后处理')) 'Operator feedback is never forwarded to the participant.'
    $continuedLoop = Invoke-Chat 'unknown-loop' "Fixture unknown three.`n/send`n/send-anyway`n/discard`n/quit`n" -ResumeChat
    Assert ($continuedLoop.state.turns.Count -eq 3 -and $continuedLoop.state.turns[2].repeatOverride) 'Explicit override is required and recorded after resume.'
    Write-Output 'PASS: multiline manual chat, empty/cancel input, review, sent/discard, receipts and resume; fake CLI only'
} finally { if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force } }