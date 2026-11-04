# SDLC CLI Capture

`tools/Invoke-SdlcCapture.ps1` launches one real Copilot CLI turn and saves evidence.
It does not score the Agent, answer business questions, approve transitions, or start the next role.

It lives in the independent evaluation project. For automated multi-stage
evaluation use `tools/Invoke-SDLC-Eval.ps1`; see
[the project guide](../../README.md). The collector remains a single-turn primitive.

## Requirements and boundaries

- PowerShell 7, Git, an authenticated Copilot CLI supporting `--session-id`,
  `--output-format json`, `--usage-output-file`, and `--no-auto-update`.
- Authenticated `gh` is needed only when `-GitHubRepository` is supplied.
- Run evidence must be outside the repository. Use a private local directory; raw
  events, prompts, copied instructions, and GitHub bodies may contain sensitive data.
  Do not commit or publish them. Redact reports before sharing; do not expose internal reasoning.
- The script does not broaden the Agent's declared tools or use `--allow-all`.
  Pass explicit `-AllowTool` / `-DenyTool` patterns supported by `copilot help permissions`.
  Missing permissions are a recorded blocker, not a reason to retry with unrestricted access.
- Permission patterns do not necessarily constrain MCP writes to one repository or Issue.
  Confirm authorized resources before permitting writes; use an isolated test repository
  and appropriately scoped credentials when enforced isolation is required.
- Keep collector instructions and scoring expectations out of `-PromptFile`.
  The PM should receive only the business request and subsequent human answers.

## One turn and continuation

Create a UTF-8 text file containing the business request. From the repository root:

```powershell
$run = Join-Path $env:LOCALAPPDATA 'SdlcEvaluation\sample-001'
$request = Join-Path $env:LOCALAPPDATA 'SdlcEvaluation\request.txt'
.\tools\Invoke-SdlcCapture.ps1 -PromptFile $request -RunDirectory $run `
    -GitHubRepository 'example-owner/isolated-evaluation-repository'
```

This example does not authorize remote writes. Add only the tool permissions approved
for the run. A CLI permission failure is not a PM business failure.
Omitting `-Model` preserves the CLI-selected model; it is not a pinned-model comparison.
Use an explicit `-Model` for controlled comparisons, and inspect runtime events for the
actual selected model and effective Agent/tools. Configuration discovery alone does not
prove that a role was executed.

To answer a clarification, put the human answer in another UTF-8 file and repeat
the same options with `-Resume -PromptFile <answer-file>`. The script uses the saved,
explicit session ID; it never resumes whichever session happens to be most recent.
It rejects changes to the role, requested model, tool policy, CLI version, or captured
Agent/instruction/template content. Start a new run for a new role or changed configuration.
Do not resume while another turn is running.

To capture known resources in detail, add `-IssueNumber 123` or
`-PullRequestNumber 456`; these include comments and, for PRs, reviews and changed files.
At a role handoff, supply actual approved artifacts and record the preceding run directory.
There is deliberately no automatic stage progression in this first version.

## Evidence

Each run has `run.json` and append-only turn directories:

| Artifact | Meaning |
|---|---|
| `input.txt`, `turn.json` | Exact input, logical launcher arguments and transport, timestamps, requested configuration, exit/timeout/error status |
| `events.stdout`, `events.stderr` | Raw JSONL and errors, written while CLI runs |
| `assistant-messages.json` | Assistant message content only; not a verdict |
| `runtime.json` | Root-agent model/usage evidence, error policy version, fatal problems and recoverable warnings; no inferred business verdict |
| `usage.json`, `cli-logs/` | CLI-produced usage and diagnostic evidence, if emitted |
| `before/`, `after/` | Git HEAD/status, hashes of non-ignored files, copies of Agent/instruction/active-template files, optional GitHub observations |

Prompt transport is `utf8-stdin-v1`: the complete text is written to the final CLI's
UTF-8 stdin, then EOF is sent. No `-p`/`--prompt` payload is placed on a command line.
The installed CLI 1.0.89-5 advertises piped stdin for non-interactive prompts.
PowerShell shims run under an encoded bootstrap containing only the short launcher
path and argument JSON; the bootstrap does not consume stdin. Thus a shim starting
Node does not reintroduce Windows command-line length limits for the prompt.
Native executables use `ProcessStartInfo.ArgumentList` for flags and the same stdin
payload. Unicode, quotes, multiline JSON and full history are not truncated or
summarized. `input.txt` retains the exact input; turn.json records transport,
inputFile, inputCharacters and short arguments. The transport participates in the
resume policy; old captures need a new run rather than mixed transports.
Stdin writing is asynchronous and included in the process timeout, so a child that
does not read stdin cannot hang capture indefinitely. Exit codes, tree termination,
tool restrictions and model validation remain unchanged. Stdin bypasses a transport
limit, not model context limits or token costs.

Offline transport tests require Node.js in addition to PowerShell 7 and Git:
`pwsh -NoProfile -File ./tests/Test-SdlcCapture.ps1 -TransportOnly`.
They exercise large Unicode JSON, PowerShell-to-native forwarding, direct native
execution, session resume, exact input evidence and blocked-stdin timeout without
calling a model.

Root `model.call_start` and legacy `assistant.usage` events provide model evidence;
`session.model_change` alone does not. Child-agent calls are excluded. Unknown-tool
configuration messages are recorded as runtime problems and invalidate PM runs.
Token counts are not inferred from a model-start event.

Under `local-read-errors-v2`, only a correlated root `view` failure with code
`failure` and exact message `Path does not exist` or `view_range out of bounds`,
targeting a normalized path inside the workspace without linked ancestors, can
become a warning. It additionally requires CLI exit 0 and a nonblank final root
response with no tool requests after all tool events. A final response preceding
the failure is insufficient. No-tools sessions and child calls cannot use this
exception. Permission errors, writes, outside paths and unknown failures remain
problems. Warnings retain the event ID, tool arguments, error, continuation reason
and finalResponseEventId; they do not prove the read succeeded. Other runtime
problems and the evaluation controller's actual-model and artifact checks remain
blocking. Historical v1 snapshots are not rewritten.

GitHub activity snapshots list repository Issues/PRs updated since the run started.
They are a discovery aid, not proof of causation, and do not include every comment,
review, label definition, or branch. Use explicit resource IDs for detailed snapshots.
Deletion, concurrent writers, and resources modified outside the configured repository
require separate investigation. No activity returned is not proof of no remote effects.

User/global configuration, MCP credentials, ignored files, and inherited skills are
not copied. Ancestor instructions and runtime defaults may also affect behavior;
inspect runtime evidence before claiming reproducibility. Snapshots do not isolate
the workspace or prevent an authorized tool from making changes.

Exit `0` means the CLI exited successfully and capture completed, **not** that the
business requirement passed. Nonzero CLI exits are preserved; timeout is `124`;
capture failures are nonzero even if CLI returned `0`. A forcibly terminated collector
may leave `state: running`; treat that as incomplete, not success. Raw files remain
available if JSON parsing fails. An external reviewer must determine Agent behavior.

## Collector tests

```powershell
pwsh -NoProfile -File .\tests\Test-SdlcCapture.ps1
```

Tests use a fake CLI in a disposable local Git repository and make no model or
GitHub calls. They verify the collector, not PM behavior.

The optional `AvailableTool`, `NoTools`, `DisableBuiltinMcps`,
`NoCustomInstructions`, `CopilotHome`, and `ReasoningEffort` parameters are part of
the resume policy. Policy changes require a new run. Old captures without this
policy metadata must also start a new run. With `CopilotHome`, the child clears
inherited instruction-directory/model overrides and disables automatic temp
directory access and remote session export. This is not an OS isolation boundary.

Generated by Copilot
