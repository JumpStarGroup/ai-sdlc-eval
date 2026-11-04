# AI SDLC Evaluation

独立的配置驱动 Agent 评估框架，支持 `req/design/dev/test` 四阶段。
框架不携带实际产品仓库、业务知识、历史实验配置或运行结果。
统一入口是 [Invoke-SDLC-Eval.ps1](tools/Invoke-SDLC-Eval.ps1)，覆盖全部四个阶段。

## 1. 三层配置与存储边界

| 层级 | 内容 | 存放位置 |
| --- | --- | --- |
| 基础架构层 | 阶段政策、角色名、权限、预算、通用评分、执行和报告代码 | 本仓库 [profiles](profiles)、[agents](agents)、[tools](tools) |
| 项目层 | 产品仓库地址、运行根目录、项目内路径约定、依赖及排除规则 | 使用者维护的外部配置目录 |
| 场景层 | 业务知识、人工确认输入、领域评分、独立验收配置 | 使用者维护的外部配置目录 |
| 运行期参数（不是第四层） | 阶段、模型、标签、输出覆盖 | 命令行或编辑器任务 |

```text
framework\                 源码、通用 Profile、文档、合成示例及测试
evaluation-config\
  projects\                项目 JSON
  experiments\             场景 JSON
  cases\                   私有知识、确认需求/设计、领域评分
  tests\                   可选的业务专用回归及夹具
evaluation-runs\
  <batch>\                 冻结输入、工作区副本、会话、验收、交付、报告
  archive\                 历史报告及批次配置（不是新场景模板）
```

三层是逻辑职责，不要求三个层级都存放在框架仓库内。
框架测试使用合成夹具；真实项目预检属于使用者的集成验证，不是框架离线测试前置。
[examples](examples) 只有合成示例，不是实际项目配置。

### 统一入口与配置来源

正式入口是 PowerShell CLI，可从普通终端、脚本或 CI 启动；不需要 VS Code。
Req 和 Design 使用同一个底层对话控制器，Dev 和 Test 使用各自的执行器。
VS Code Task 只是调用同一个 CLI 的可选快捷方式。

| 阶段 | 默认阶段 Profile | 场景提供的主要输入 |
| --- | --- | --- |
| `req` | [pm-clarification.json](profiles/pm-clarification.json) | 私有业务知识、领域评分 |
| `design` | [architect-design.json](profiles/architect-design.json) | 已确认需求、设计领域评分 |
| `dev` | [developer-coding.json](profiles/developer-coding.json) | 已确认设计及参考需求、验收设置 |
| `test` | [backend-testing.json](profiles/backend-testing.json) | 指定的 Dev 交付，不在 `stages` 中新增配置 |

阶段 Profile 是该阶段工具权限、调用预算、交互策略和通用提示的配置来源。
真实业务内容不放入 Profile：Req 从外部知识的 `## 初始需求` 提取首条业务输入；
Design 从已确认需求和 Profile 的提示模板生成首条任务。
项目配置提供产品仓库和路径约定；模型和本轮输出覆盖由命令行提供。

Req/Design 的统一入口将三层输入组合成临时对话配置，交给底层对话工具，
并将生效配置和输入冻结到本次运行的 `inputs` 中；不需要维护业务专属对话模板。
底层工具仍保留直接调用接口用于兼容和专项诊断，但它需要显式配置，
直接运行不等于经过统一入口的阶段编排和评分。
[dialogue-policy.json](profiles/dialogue-policy.json)是底层直接调用时的默认政策；
统一入口传入完整阶段政策并覆盖它，因此修改该默认文件不会改变正常的 Req/Design 阶段设置。
冻结的运行配置是历史证据，不是需要手工维护的下一轮配置。

## 2. 四阶段

| 阶段 | 默认被测角色 | 输入 | 执行和评价 |
| --- | --- | --- | --- |
| `req` | `SDLCRole_PM` | 私有知识的 `## 初始需求` | 首轮业务输入只提供起始段落；模拟参与者持有完整知识，默认至少回复两次；独立模型评价 |
| `design` | `SDLCRole_Architect` | 已确认需求 | 双方使用同源需求，按需澄清、最低回复数零；独立模型评价 |
| `dev` | `SDLCRole_Dev` | 已确认设计与参考需求 | 每模型一次 CLI；实现、自测和独立 Python/pytest 后端验收，无参与者或模型评分 |
| `test` | `SDLCRole_Test` | 冻结 Dev 交付 | 独立主 CLI 会话；后端只读复验，不续接 Dev 会话，目前不实现 Web |

被测角色实际定义来自产品 `.github\agents`，随运行冻结。项目指令、`AGENTS.md` 和可选项目契约保留在产品基线中，不把规则正文重复注入业务知识。
`design` 对应 Architect；不设独立 Planner。统一入口拒绝 `plan` 和旧扁平场景。

需求和设计不自动批准；模拟参与者不是自然人审批人。人工审查并确认后才能把交付作为下一阶段输入。
Dev 可显式使用 `-WithTest` 接续 Test，默认不串联；只有所有 Dev 条件通过才接续。
Test 后端通过不代表 Web 完成、业务验收通过或获准发布。

## 3. 配置项目与场景

复制 [示例项目](examples/project.json)、[示例场景](examples/scenario.json)及其输入到外部目录后修改。
文件路径相对于声明它们的 JSON；阶段 Profile 路径相对于 Profile。
项目路径模板的 `{caseId}` 在运行时替换。

项目字段：

| 字段 | 用途 |
| --- | --- |
| `repositoryPath` | 本地被测 Git 仓库 |
| `runsRoot` | 仓库外的运行证据根目录 |
| `requirementWorkspacePath` / `designWorkspacePath` | 产品副本内的需求/设计目标路径模板 |
| `excludePatterns` | 从产品基线排除私有文件的模式 |
| `runtimeDirectories` | Dev 需复制的已安装依赖和可写状态目录，不自动下载依赖 |
| `projectContractPath` | 可选，产品内的角色工作契约 |
| `reportWorkspacePath` | 使用项目角色执行只读 Test 时必需，产品副本内的 Markdown 报告路径模板 |

`reportWorkspacePath` 不能覆盖已有产品文件；不限定产品必须使用某个文档目录。
基础 Test Profile 只定义角色与测试政策，不绑定项目契约或报告布局。
Req/Design 的通用与领域评分占比由阶段 Profile 的 `rubricWeights` 定义，
不同于直接调用独立评分工具的默认比例，详见[评分指南](docs/guides/result-quality-evaluation.md)。

场景使用 `schemaVersion: 1`、`caseId`、`projectProfile` 和 `stages`：

- Req/Design：`inputFile`、`rubricFile`，可选 `phaseProfile`。
- Dev：`inputFile`、可选 `phaseProfile` 与 `verification`，不配置评分表或参与者。
- Dev 的参考需求来自同场景 `design.inputFile`；若不运行 Design，该引用可不设置设计评分表。
- 不配置 `stages.test`；Test 使用 `-DevRunDirectory` 选择已有交付。
- 场景不配置模型、运行序号或本轮目录；这些由命令行传入。

未设置 `phaseProfile` 时使用上表的框架默认值；设置时，路径相对于场景 JSON，
并须提供符合对应阶段契约的完整 Profile。需要修改某阶段的 `callLimit`、工具或政策时，
应修改该阶段 Profile 或在场景中指定自定义 Profile，而不是修改旧业务对话模板。

Dev 验收示例：

```json
{
  "pythonExecutable": ".venv\\Scripts\\python.exe",
  "testPaths": ["tests"],
  "timeoutSeconds": 300
}
```

可选 `acceptanceDirectory` 指向外部可信验收测试。缺省只运行回归集合，不能冒充独立业务验收。
Dev Profile 第 5 版仅保留 `callLimit: 1`、`timeoutSeconds` 和 `disableBuiltinMcps` 政策。
旧自定义 Dev 配置需删除参与者、rubric、评分比例和对话控制字段；未知字段明确报错，不静默忽略。

## 4. 运行

前提：PowerShell 7、Git、可用 Copilot CLI 和模型权限。默认使用已有 `gh` 登录回退；不把凭据放进 JSON。
以下示例从框架目录运行，也可以从任意目录使用脚本绝对路径；占位路径须替换为实际外部配置。
仓库内合成示例只配置 Req；运行 Design/Dev 前须先添加对应阶段输入和评分，见[外部场景指南](docs/guides/adding-business-scenarios.md)。

```powershell
# 默认预检：不创建运行目录、不调用模型
pwsh -NoProfile -File .\tools\Invoke-SDLC-Eval.ps1 `
  -ScenarioFile C:\evaluation-config\experiments\sample.json -Stage req

# 已配置 Design 和 Dev 的场景；显式运行会产生模型用量
pwsh -NoProfile -File .\tools\Invoke-SDLC-Eval.ps1 `
  -ScenarioFile C:\evaluation-config\experiments\dev-enabled.json -Stage dev `
  -Mode Run -TargetModels "gpt-6-luna"

# 独立 Test 预检；显式 -Mode Run 才执行
pwsh -NoProfile -File .\tools\Invoke-SDLC-Eval.ps1 `
  -ScenarioFile C:\evaluation-config\experiments\dev-enabled.json -Stage test `
  -DevRunDirectory C:\evaluation-runs\<existing-dev-run>
```

| 参数 | 行为 |
| --- | --- |
| `-TargetModels` | 候选模型，支持数组/逗号分隔，分别执行；可使用 CLI 支持的路由模型 |
| `-ParticipantModel` / `-EvaluatorModel` | Req/Design 使用明确模型，不接受 Auto/Fusion；Dev 不使用 |
| `-ReasoningEffort` | 仅显式 `-Stage dev`，适用于本轮 Dev 条件，不传给其他角色 |
| `-DialogueOnly` | Req/Design 跳过模型评价；不跳过 Dev 验收 |
| `-RunsRoot` / `-RunLabel` | Req/Design/Dev 的本轮输出根目录及标签覆盖 |
| `-RunDirectory` | 本阶段输出目录覆盖，目录必须全新；适用于独立 Test |
| `-CliPath` | 显式指定优先；否则先查 PATH 中支持的 CLI，再尝试 Windows 上 VS Code 附带版本 |
| `-UseGitHubCliAuth` | 统一入口默认启用，直接 PowerShell 调用可用 `:$false` 关闭 |
| `-WithTest` / `-TestModels` | Dev 通过后可选接续独立 Test；Test 模型不继承 Dev 模型 |
| `-DevConditions` | 独立 Test 可选择部分 Dev 条件，省略则全部 |
| `-TestProfileFile` / `-TestRunDirectory` | 覆盖 Test 政策/一键流程输出 |

Req/Design 默认每个模型条件下双方合计最多 10 次对话调用、每次 900 秒；
独立评分调用不计入该对话预算。Dev/Test 默认每条件一次、3600 秒。
框架独立后端测试默认合计 300 秒。超时或失败保留证据，不自动重跑模型。
预检不验证 CLI 能否启动，也不证明实际认证、模型可用性或业务输入质量。
CLI 应是可用的 `.ps1` 脚本或原生可执行文件；采集器不接受 `.cmd/.bat` 包装器。

[VS Code 任务](.vscode/tasks.json)只是命令快捷方式，不是配置层：
`SDLC validate/run` 询问外部场景路径、阶段和候选模型；
`SDLC Test validate/run` 另询问 Dev 来源目录与 Test 模型；不默认绑定任何业务。
两个 offline 任务只验证框架。

## 5. 运行资产与隔离

正式运行将 `inputs`、`input-manifest.json`、`baseline`、产品副本、CLI 会话、用量、
`comparison.json`、验收证据、`delivery` 和报告写到外部运行目录。
独立 Test 默认创建来源 Dev 目录旁的新目录；一键 Dev/Test 默认后缀为 `-test`。
运行期临时准备使用系统临时目录，框架测试夹具也在临时目录中创建并清理。

Req/Design/Dev 入口拒绝仓库内证据目录，Test 拒绝覆盖框架或来源交付。
每个模型使用独立副本；已冻结运行不被迁移或覆盖。
Test 默认读取来源 Dev 的 `inputs\project.json`；直接调用 Test 工具可用 `-ProjectFile` 显式覆盖，
统一入口则传入当前选定项目配置。实际生效的 Test 配置和项目配置都冻结到新 Test 运行中。
旧 Test Profile 内的项目路径仍可显式使用，但不作为新版通用默认。
迁移前的 Dev 冻结项目若缺少报告路径，应通过统一入口选择当前外部项目，
或在直接 Test 命令中显式指定 `-ProjectFile`；不要修改原 Dev 证据来补配置。

目录复制、工具限制及哈希检查不是操作系统沙箱。运行不可信代码应使用容器/虚拟机、
最小权限和网络限制；不要放凭据或生产数据。私有知识与评分不能进入目标产品基线。
依赖内容的部分完整性校验采用大小/时间元数据，不保证发现保持元数据不变的篡改。
排除规则不是通用敏感信息检测，需审查实际基线。

Dev 验收使用最新后端测试，历史冻结测试仅供对照；前端自测证据单列，不冒充框架独立验收。
Test 只允许指定报告及执行证据，不允许修改产品、后端测试或依赖；已有报告路径会被拒绝。
运行状态、交付完整性、测试结果、模型评分是不同维度；费用缺失应标未知而非零。

## 6. 维护与验证

核心离线测试不依赖实际产品或外部业务配置，不产生模型费用：

```powershell
pwsh -NoProfile -File .\tests\Test-DesignScenario.ps1
pwsh -NoProfile -File .\tests\Test-AgentDialogue.ps1
pwsh -NoProfile -File .\tests\Test-DevRun.ps1
pwsh -NoProfile -File .\tests\Test-TestRun.ps1
pwsh -NoProfile -File .\tests\Test-ResultEvaluation.ps1
pwsh -NoProfile -File .\tests\Test-KnowledgeChat.ps1
```

历史 Oracle/知识校准测试含业务专用断言，应与其数据一起放在外部配置目录，
不属于无业务数据的核心测试集。运行这些私有测试时须指定框架与业务数据路径。
见[历史工具维护](docs/guides/business-user-simulator.md)和[结构化知识参与者](docs/guides/knowledge-participant.md)。
真实集成预检应另外使用你的外部场景配置，不应混进框架默认回归。

可选工具：[离线复验](tools/Invoke-DevReverification.ps1)、[交付性能测量](tools/Measure-DevDelivery.ps1)、
[结果评价](docs/guides/result-quality-evaluation.md)。这些不是额外阶段。

历史运行报告、批次 JSON、业务知识和旧文档应保存在外部资产/归档目录。
迁移时先复制、逐文件校验哈希，再从框架工作区移除；原批次证据不变。
本仓库忽略根目录 `cases/experiments/projects` 及本地结果目录，防止再次混入实际资产。
发布前还应审查将要推送的 Git 历史；删除工作区文件不会自动移除旧提交。
