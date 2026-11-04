if ($args -contains '--version') { Write-Output 'fixture-knowledge 1.0'; exit 0 }
if ($args -contains '--help') { Write-Output "  --disallow-temp-dir`n  --no-remote`n  --no-remote-export"; exit 0 }
$ErrorActionPreference = 'Stop'
if ($args -notcontains '--available-tools' -or $args -notcontains '--disable-builtin-mcps' -or $args -notcontains '--no-custom-instructions') { throw 'Isolation flags missing.' }
if ($args -contains '-p' -or $args -contains '--prompt') { throw 'Use stdin transport.' }
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($request.protocolVersion -cne 'knowledge-participant-v1') { throw 'Wrong protocol.' }
$model = $args[[Array]::IndexOf($args, '--model') + 1]
$decision = @{ protocolVersion = 'knowledge-participant-v1'; items = @(@{ kind = 'answer'; quote = $request.message; factIds = @('name.unique') }) }
if ($request.message -ceq 'Fixture no question.') { $decision.items = @() }
if ($request.message -ceq 'Fixture invalid decision.') { $decision.items[0].factIds = @('unapproved') }
if ($request.message -like 'Fixture unknown*') {
	$decision.items = @(@{ kind = 'unknown'; quote = $request.message; factIds = @(); unknownId = 'unknown.existing-sessions' })
}
@{ type = 'model.call_start'; data = @{ model = $model } } | ConvertTo-Json -Compress
@{ type = 'assistant.message'; id = 'final'; data = @{ content = ($decision | ConvertTo-Json -Depth 8 -Compress) } } | ConvertTo-Json -Depth 10 -Compress
exit 0