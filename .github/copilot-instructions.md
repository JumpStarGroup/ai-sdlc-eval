# Copilot instructions

## Architecture

- This repository is a reusable evaluation framework, not the product under evaluation. Keep project profiles, business scenarios, private knowledge, domain rubrics, and run evidence outside the framework.
- The three configuration layers are infrastructure (framework profiles/tools), project (product repository and path rules), and scenario (stage inputs and domain evaluation). Runtime options such as stage, model, and output location are CLI arguments, not another configuration layer.
- `tools/Invoke-SDLC-Eval.ps1` is the four-stage CLI entry point. Req and Design route through `Invoke-AgentDialogueComparison.ps1`, which coordinates isolated model workspaces and the shared `Invoke-AgentDialogue.ps1` dialogue controller; `Invoke-SdlcCapture.ps1` captures individual CLI turns. Dev uses `Invoke-DevRun.ps1` for one-shot implementation and backend verification per model. Test is an independent, read-only evaluation of a frozen Dev delivery via `Invoke-TestRun.ps1`. Result-quality evaluation is a separate post-run operation, not a fifth stage.
- Stage profiles define stage policy and shared tools. The unified entry point composes profiles, project and scenario inputs into frozen run inputs; do not reintroduce business-specific dialogue templates as a parallel configuration source. See [README](../README.md) and [external scenario guide](../docs/guides/adding-business-scenarios.md).

## Commands

Use PowerShell 7 from the repository root. The framework's core offline regression commands are:

```powershell
pwsh -NoProfile -File .\tests\Test-DesignScenario.ps1
pwsh -NoProfile -File .\tests\Test-AgentDialogue.ps1
pwsh -NoProfile -File .\tests\Test-DevRun.ps1
pwsh -NoProfile -File .\tests\Test-TestRun.ps1
pwsh -NoProfile -File .\tests\Test-ResultEvaluation.ps1
pwsh -NoProfile -File .\tests\Test-KnowledgeChat.ps1
```

Each test is a standalone script. Run one script directly to target a test; focused selectors include:

```powershell
pwsh -NoProfile -File .\tests\Test-DevRun.ps1 -Cases success
pwsh -NoProfile -File .\tests\Test-AgentDialogue.ps1 -NamingOnly
pwsh -NoProfile -File .\tests\Test-SdlcCapture.ps1 -CompatibilityOnly
```

Tests use synthetic fixtures and fake CLIs, so these commands do not make model calls. No separate build or lint command is defined.

## Configuration and run conventions

- Default evaluation mode is `ValidateOnly`; only `-Mode Run` executes model calls and may incur usage. Preflight checks configuration, not CLI authentication or model availability.
- Scenario/project paths are resolved relative to the JSON that declares them; references inside a phase profile are relative to that profile. A custom `phaseProfile` must satisfy the complete stage contract. Reject unknown or obsolete schema fields rather than silently accepting them.
- Do not add a `stages.test` entry: Test selects a frozen Dev delivery. Only the stage profiles and scenario inputs appropriate to the stage belong in its configuration.
- Send run evidence to a fresh directory outside the framework and product repositories. Preserve completed run evidence; do not overwrite or migrate it as part of routine changes.
- Keep synthetic regression fixtures self-contained and use fake CLI behavior to verify orchestration. Do not copy private knowledge or rubrics into the product baseline. Workspace copies and tool restrictions are not an OS sandbox; untrusted product code needs separate OS-level isolation.
- A completed dialogue or delivered artifact is not business approval or proof of quality. Preserve that distinction in result handling and reports.
