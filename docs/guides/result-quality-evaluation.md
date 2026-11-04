# 独立结果质量评价

[架构与规范 v2](../requirements/result-quality-evaluation-spec.md)；[打分评估 Agent](../../agents/result-quality-evaluator.agent.md)；[通用评分表 v2](../../profiles/result-quality.json)。

结果评价是对话运行之后的独立阶段，不参与提问、待决管理或交付状态判定，也不修改原 `result.json`、`report.json` 或 comparison 状态。

## 评分边界

默认通用评分表在 `profiles/result-quality.json`，评价证据忠实度、已确认范围覆盖、未决处理、产物可验收性，以及完成声明与实际交付是否一致。可通过 `-DomainRubricFile` 追加外部领域评分表；格式见[合成示例](../../examples/rubric.json)。每个评分表使用 0–4 整数分和正权重；评价模型给出逐项分数，工具校验维度、范围和证据引文，并计算加权总分及百分比。

通用 rubric 不知道某个功能的隐藏业务规则。若要检查参与者没有问到的领域要求，必须把经批准的覆盖点显式写入领域 rubric。评分结论应区分“对话未讨论”“产物遗漏”和“需求规则本身未在评分依据中提供”，不能让评价模型凭常识发明业务规则。

## 输入与隔离

每个条件只向评价模型提供该条件的 `summary.md`、独立生成的 `run-facts.json`（原始 outcome、完成声明、artifactCheck、待决和运行指标）、核验或声明过的最终产物，以及通用和领域 rubric。不提供 simulator 私有知识、Oracle 文件、源仓库全文或其他条件的产物。评价器在独立临时 Git workspace 中运行，禁用工具、MCP 和项目自定义指令；模型输出必须符合结构化 JSON 契约。引文逐条核验：无效引文不作为证据；如某维度没有剩余可核验证据，该维度不计入加权总分，并在报告列出引用警告和证据覆盖率。

summary/产物文本仍按不可信数据处理。原运行状态与评价分数是两类独立结论：`stage_completed` 不代表质量高，`completed_with_pending` 也不自动代表质量低。回复存在、回复送达、声明完成和交付核验由控制器公共事实函数分别提供。需要文件的任务未交付时，完成度得0分；没有虚假完成声明不能换取完成度分数。工具或控制器中断的原因需单独解释，不能据此概括模型能力。

执行时长以客观指标单独报告，包括整场墙钟时间、Target 和 Participant 累计时间、调用次数与逐调用时长；默认不直接计入质量总分。不同需求复杂度、提问数量和调用预算会显著影响时间，不宜脱离同任务条件把快慢当作质量。若要把性能作为验收维度，应在领域 rubric 中定义可比较的目标和适用条件。

## 运行

需使用 PowerShell 7、Git、Copilot CLI 和已登录的模型访问。`-Model` 必须显式指定评价模型；脚本不会自动登录，也不会启动付费调用以外的模拟流程。
若当前进程存在 classic PAT 覆盖 Copilot 认证，可显式加 `-UseGitHubCliAuth`：脚本仅在子调用期间移除 `COPILOT_GITHUB_TOKEN`、`GH_TOKEN`、`GITHUB_TOKEN`，使用现有 GitHub CLI 登录回退，并在结束后恢复进程变量；不会读取或打印 token。

评价单个 dialogue：

```powershell
pwsh -NoProfile -File ./tools/Invoke-DialogueResultEvaluation.ps1 `
  -RunDirectory C:/ai-sdlc-eval-runs/<run>/<condition>/dialogue `
  -Model gpt-6-luna `
  -DomainRubricFile C:\evaluation-config\cases\rubric.json `
  -UseGitHubCliAuth `
  -CliPath 'C:/path/to/copilot.ps1'
```

评价一个 comparison 下所有模型条件：

```powershell
pwsh -NoProfile -File ./tools/Invoke-DialogueResultEvaluation.ps1 `
  -RunDirectory C:/ai-sdlc-eval-runs/<comparison> `
  -Model gpt-6-luna `
  -DomainRubricFile C:\evaluation-config\cases\rubric.json `
  -UseGitHubCliAuth `
  -CliPath 'C:/path/to/copilot.ps1'
```

每次运行创建一个新的 `evaluation-<UTC时间>` 目录，保存评分输入、隔离 evaluator workspace、CLI capture、逐条件 `evaluation.json` / `evaluation.md` 和顶层索引。`evaluation.json` 独立保存 completion assessment、objective execution metrics 和 rubric score。可以传 `-EvaluationDirectory` 指定一个尚不存在的路径；已有评价不会被覆盖。产物单文件默认上限 512 KiB，可用 `-MaxArtifactBytes` 调整。

若仅修改了本地引用校验或展示，可通过 `-ReplayCaptureRoot <previous-evaluation-dir>` 使用同一v2标准的 evaluator capture 离线重验，不再发起模型调用。复验使用原始 capture 输入中的 summary/产物及原 run-facts，不读取后来修改的业务内容；校验哈希、实际模型和评分契约。指导或 rubric 改动后必须重新评价。旧010的v1评分保留，不可沿用为v2结果。

## rubric 格式

通用表和领域表均为 JSON：`schemaVersion` 必须为 1；`id`、`version` 为非空字符串；`scale` 固定为 0–4；`criteria` 至少有一项，每项含唯一 `id`、`title`、`description` 和正数 `weight`。每张表内部权重必须合计100；有领域表时两部分各占50%，无领域表时通用表占100%。程序传给模型及最终报告的权重已换算，合计100。

至少一维没有有效引用时状态为 partial_evidence，不提供总分，不能按剩余权重重新放大。JSON 的 evidenceCoveragePercent 表示有效引用维度的权重占比，不是需求覆盖率。存在引文也不代表语义结论正确。评分原则由 Agent 执行，脚本不会替它判断是否应该扣业务分。

## 验证

运行 `pwsh -NoProfile -File .\tests\Test-ResultEvaluation.ps1`。使用假 CLI 和合成领域表，不消耗模型额度；覆盖跨业务表替换、零参与者、未交付、原始回复留存、权重100、无效引文和冻结证据复验。真实效果需另行校准。