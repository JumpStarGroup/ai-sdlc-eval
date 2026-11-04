# 自然语言双 Agent 自动对话

[需求与契约](../requirements/automatic-agent-dialogue-requirements.md)；
[三层配置示例](../../examples/scenario.json)；
[统一入口](../../tools/Invoke-SDLC-Eval.ps1)。

本页说明 Req/Design 共用的底层对话工具。正式运行使用 [三层统一入口](../../README.md)，
无需另外维护业务专属对话模板。旧 Oracle 矩阵和人工聊天仅作为独立维护工具保留。
运行器和控制器是同一个程序中的两种职责，没有新增主持 Agent。
共同约定自动加到双方提示中；Req 的私有知识全文只给工具禁用的业务参与者，
被测角色接收初始需求和参与者的回答；Design 双方使用同一份确认需求。
无需修改产品 Agent 文件，也无需让模拟人维护事实 ID 或判断隐藏知识覆盖。

## 运行

准备 PowerShell 7、Git、Copilot CLI、可用模型及认证。继承 CLI 支持的 token 或使用现有认证回退；
脚本不登录、不输出凭据。被测 Agent 必须已存在于产品工作区的 `.github/agents/<name>.agent.md`。
统一入口根据场景和阶段 Profile 生成对话配置，复制产品基线并为每个候选模型准备独立工作区。

```powershell
pwsh -NoProfile -File .\tools\Invoke-SDLC-Eval.ps1 `
  -ScenarioFile C:\evaluation-config\experiments\sample.json `
  -Stage req -Mode ValidateOnly -TargetModels "auto,gpt-6-luna"
```

预检不调用模型；改为 `-Mode Run` 才会真实执行并产生费用。
Req/Design 默认每个模型条件双方合计最多十次对话调用，不是十轮；独立评分调用另计。
源知识自身的冲突仍需修订，控制器不会替知识选边。
阶段工具和政策以 [PM Profile](../../profiles/pm-clarification.json) 或
[Architect Profile](../../profiles/architect-design.json) 为准；场景可指定自定义完整 Profile。
运行时生成的对话配置会覆盖底层 [dialogue-policy.json](../../profiles/dialogue-policy.json) 默认值。
修改底层默认值不会改变统一入口传入的完整阶段政策。
关闭 skipIssueRegistration 只恢复角色原有流程，不自动提供 MCP 或远程权限；工具开关与流程开关相互独立。

### 模型比较与底层兼容

统一入口使用 [比较工具](../../tools/Invoke-AgentDialogueComparison.ps1)运行 Req/Design 的多个候选模型。
它复制当前产品工作区中 Git 已跟踪及非忽略的新文件，保留未提交修改及删除状态，
冻结共同基线，再为各组分别创建独立副本，不修改原产品工作区。
排除任意场景的 `*.simple-knowledge.md`、`*.knowledge.json`、`*.oracle.json`、
`*.dialogue.json`、环境文件和指定 MCP 配置；不是任意敏感文件识别器，仍需检查输入清单。
底层比较工具的 `-TemplateFile` 和 [单次对话工具](../../tools/Invoke-AgentDialogue.ps1)的
`-ConfigFile` 仍可用于兼容和专项诊断，但不应作为新的并行业务配置来源；
直接调用单次对话工具允许被测角色在配置的工作区生成文件，不会自行复制产品仓库。

UseGitHubCliAuth 仅在进程内暂时移除 token 覆盖变量，使用已有认证回退，结束后恢复；
不读取、显示或存储凭据。统一入口不传 `-RunDirectory` 时，由
[批次命名模块](../../tools/RunDirectory.psm1)自动生成阶段批次名。
底层比较工具单独调用时的命名格式为
`<caseId>-dialogue-<三位序号>-<UTC日期>-<RunLabel>`，例如
`sample-dialogue-001-20261104-auto-luna-sol61`。同场景跨日期和模型组合共享序号；
同时识别旧的日期/模型/序号格式，排除 `*-inputs`，不重命名任何历史证据。
兼容旧格式局部序号重复：下一批号取已用最大批次号与匹配批次数量的较大值再加一。
底层比较工具的 `-RunsRoot` 指定父目录；省略时使用所给对话配置中 `runDirectory` 的父目录。
显式传 `-RunDirectory` 则使用指定的新目录，不自动改写路径。
命名函数只计算候选路径，不创建或占用目录；实际入口创建时仍拒绝已存在目录。
同时启动两个同场景任务可能选到相同候选号，冲突者须重新启动，不会合并证据或自动重试模型调用。
auto 只允许用于被测角色，模拟人必须固定模型。结果逐次记录 requestedModel、observedModels、
usage 和 warnings；auto 不预先假定底层模型，也不接受缺失实际模型证据。固定模型仍严格检查匹配。
每个条件失败后保留证据，继续下一个条件，不重试或自动回退。
默认 Req Profile 的 minimumParticipantReplies=2：至少有两次非空参与者回复才能接受完成声明；
默认 Design Profile 为 0，仅在存在业务歧义时按需对话。自定义完整 Profile 可调整此值。
这只防止双 Agent 测试退化为单边交付，不证明问答相关性或需求完整；不足时使用有限协调预算提醒提问。
comparison.json 保存共同基线哈希、排除清单与两组摘要；详细对话在各条件的 dialogue/result.json。
新测试子目录按 caseId、请求模型简称和序号命名，例如 sample-auto-01、sample-luna-02。
caseId 可在模板配置，缺省取模板文件名首段；旧 condition-01 等目录不自动重命名。
目录按请求模式命名，不跟随 auto 的实际路由变化。报告概览和索引分开显示请求模型与实际模型集合，
每次调用和每条对话都列出执行角色、requestedModel、observedModels，并提供 runtime.json 证据链接。
一次调用观测多个模型时完整列出；没有实际模型证据时标记未知，不从邻近调用或计费模型推断。
每组一个样本只用于本次流程诊断，不构成模型胜负或统计结论。

### 自动命名的通用启动任务

后续批次使用三层统一入口任务，由入口调用命名模块生成新目录。
场景路径选择外部场景，不再为每个业务/模型组合添加任务：

| 任务 | 输入 | 行为 |
| --- | --- | --- |
| SDLC validate | 场景、阶段、候选模型 | 预检，不调用模型 |
| SDLC run (uses model credits) | 场景、阶段、候选模型 | Req/Design 对话和评分；Dev 单次执行和后端验收 |
| SDLC Test validate | 场景、来源 Dev 目录、Test 模型 | 检查独立 Test 输入 |
| SDLC Test run (uses model credits) | 场景、来源 Dev 目录、Test 模型 | 独立后端 Test |

固定历史批次的任务已从编辑器配置中移除；历史运行目录、冻结知识和原评分不改写。
同场景的新批次应串行启动；命名函数不原子预留序号，不保证并行启动不同模型组合时序号唯一。
仅 `run` 任务真实调用模型并消耗额度，离线验证命令
`pwsh -NoProfile -File .\tests\Test-AgentDialogue.ps1 -NamingOnly` 仅验证命名和任务命令结构，不调用模型。

## 消息

控制器在 Invoke-AgentDialogue.ps1 中构造 $task 共同协议，连同有效 policy、工作区限制、问题台账和最新消息，
写入每次调用的 input.txt，通过 Invoke-SdlcCapture.ps1 的 PromptFile 送入 CLI。
这是 CLI 提示输入，不是独立的 system-role 消息；角色定义另由 --agent 加载。
共同约定每轮向双方说明：一次 CLI 返回只结束当前发言，控制器负责转发正文并恢复各自会话。
被测角色提出具体问题并返回 waiting_reply；参与者依据已有知识回答后也返回 waiting_reply，不必反问。
非交互 CLI、尚未收到答复或没有 Agent 调用工具本身不是 blocked；真实阻塞需说明具体证据和缺少的条件。
最低回复次数按整场累计，不要求单次调用取得全部回复，也不按一条回复的答案数量计数。
无已批准答案或知识冲突应如实答复并保留边界，不补造业务决定，也不为凑次数重复提问。
这些是协作提示说明，不改变控制器对 blocked 的停止规则，不新增自动纠正或 JSON 恢复。
interactionPrompt 用于最低交互次数不足，coordinatorPrompt 用于一般协调兜底；交付核验失败则生成含具体失败项的修复提示。
协议、路径限制和核验诊断属于控制器逻辑，不是模板中的业务规则，也不会被 coordinatorPrompt 替换。

业务正文自然语言，最后附一行控制信息。例如：

```text
这个选择没有已批准的决定。请继续处理其他独立问题，草稿保留该待决。
DIALOGUE_CONTROL: {"status":"waiting_reply","artifactPaths":[],"pending":[{"id":"pending-1","question":"是否扩展到外部客户端？","kind":"business_decision"}]}
```

完成自身任务时正文说明“角色任务已经完成”，状态使用 role_task_completed。
仅保留 waiting_reply、role_task_completed、blocked 三种状态；已取消 no_reply，当前解析器会拒绝旧状态。
waiting_reply 表示交给对方继续处理，适用于提问和答复，不要求正文必须有反问。
参与者回答完本轮问题通常仍使用 waiting_reply，不把一次答复结束当成整个角色任务完成。
参与者的非空正文仍先送达被测角色；对方吸收答复后继续自身工作，不必回复收到。
blocked 说明无法继续，但参与者的阻塞先交给被测角色判断，不直接结束全局任务。
汇总会标明正文交付状态：已送达需有实际 CLI 输入捕获凭据，等待调度不冒充送达，未转发明确注明。
被测角色完成后由程序验证实际产物；模拟人完成不代表被测任务完成。
完成声明缺少有效交付证据时，控制器针对产物及待决保留提出一次有界修复请求，而不是重复泛化追问。
待决编号不是知识事实编号，只记录本次实际提出的问题。
逐问题更新可附 questionStatus：awaiting_reply 为等待答复，answered 为已回答，partially_answered 为部分回答，pending 为确无批准答案。
参与者可用 answered 加非空 answeredParts 和 remainingQuestion=null 明确已回答；部分回答保留已答部分和剩余问题。
首次提问先进入问题台账，不立刻认定为业务未知。PM 不能凭完成声明消除真正业务待决。
正文与任务元数据分开转发；已登记待决作为公开会话状态提供给双方。

## 结果与边界

summary.md 的业务正文只展示一次，路线明确写为 Target → Controller → Participant 或反向。
只有实际输入与上次答复一致且存在送达记录时才省略重复输入；Controller 主动推进及不同输入仍单独展示。
每条转发附实际 CLI 输入链接，末尾有逐调用审计索引。report.json 保留全部输入、输出和问题修订历史，
主汇总只展示问题最终状态、必要的不同表述、回答部分及证据调用编号，不展开重复修订。

费用读取每个 session 最后一次 CLI 导出的累计 usage.json，不把多轮累计值相加。
totalNanoAiu 是 AIC 的纳单位表示；除以十亿后显示两位小数，保留原始值和 aiCreditsStatus，而不是按 token 推算费用。
partial 的已报告值会显示并标注不完整，缺失显示未知；输入 token 包括 input、cache_read、cache_write，输出独立统计。
此实现读取结构化导出，不自动恢复旧会话执行交互命令，不混入恢复后新增调用的费用。

可仅刷新既有测试的派生汇总，不调用模型、不修改 result.json 或冻结证据：

```powershell
.\tools\Export-AgentDialogueReport.ps1 -RunDirectory C:\evaluation-runs\<comparison>
```

私有目录保存冻结输入、两边独立的采集会话、每次消息及 result.json。
result.json 区分正常阶段交付、带待决交付、外部阻塞、停滞、预算耗尽与失败。
完成声明需非空且本次新增或变更的文件，并引用当前真正未决编号；允许等价措辞，不要求原问题和剩余问题逐字匹配。
全部原问题及回答历史保存在 questions 中，pending 是未决投影；summary.md 展示每个问题状态及每次交付检查的具体失败项。
文件检查不证明语义正确或需求无遗漏，assessment 保持 not_scored。
两边会话持续复用自己的 session ID；每轮带当前任务约定与待决记录。不盲目重发失败调用，不回退模型。
首版不恢复中断运行，也不兼容 JSON knowledge-participant 的决策输出。
工具限制和工作区分离不是操作系统级沙箱；真实试跑仍应核对越界访问与语义行为。

### 本地工具与恢复

阶段 Profile 和底层默认工具列表同时开放 view、glob、grep、apply_patch、create、edit；write 仍是操作批准类别，
不等于工具 schema。不同模型可能获得不同的本地写入通道，不能只允许 apply_patch 就假定所有模型均可写。
模拟人仍始终 NoTools。自定义配置显式提供 availableTools 时不自动扩展，需自行包含兼容写入工具。
没有启用全局 Allow all、父目录访问、shell 或 MCP。

每轮提示明确唯一工作区根目录，优先相对路径。maxPathRecoveryPrompts 默认 1，可设 0 关闭：
仅对主角色 view 的 denied，且请求路径不存在、只是漏了工作区根层级、补回后对应工作区内现存文件或目录、
路径均无链接、没有其他运行问题时，才追加纠正提示，让原 session 在原总调用预算内继续。
原始拒绝保留在 runtimeProblems；不会读取原外部路径、授予额外权限或静默改写工具参数。
真正的外部文件、没有本地对应项、写入拒绝、子 Agent 错误均不适用此恢复。

新自然语言入口为被测角色显式启用 RecoverLocalPatchErrors；旧 Oracle 入口默认不启用。
仅单个工作区内现存非链接文件的 Update File 补丁上下文匹配失败可作为候选。
同一次 CLI 调用中须在失败后成功重读同文件，并成功 apply_patch 修改同文件且有 fileEdits 证据，
最后有有效最终回复及成功 CLI 退出，才降为 recovered_local_patch_error 警告。
保留原错误、重读事件、修复事件、最终回复事件及修复后文件哈希；没有这些证据仍失败。
Add/Delete/Move、多文件补丁、权限拒绝、其他文件写入和子 Agent 错误不自动降级。

runtime.json 与报告的运行诊断分别保存 Disabled tools 配置事件、实际请求 schema 快照、工具参数、
原始错误及恢复证据。schema 快照来自 CLI 的 prompt_cache_break 事件，不保证每次调用都有；无快照不代表无工具。
CLI 状态失败、模型证据不匹配和工具失败分别报告，不再统一显示模型不匹配。

### 后续工作：控制 JSON 格式错误的有界恢复

状态：待实现；当前使用严格解析，不自动修正控制 JSON。
控制元数据解析失败会导致对话终止，即使业务正文已有内容。

后续验收要求：
- 原始正文、控制元数据和解析错误完整保留，不覆盖历史失败证据。
- 仅对控制元数据格式错误，允许同一角色、同一 session 最多一次修复请求；
  要求只修正元数据，不改变业务正文，不替业务作决定。
- 修复结果重新通过完整协议校验后才转发；修复失败或调用预算耗尽仍终止。
- 修复调用计入总调用预算，恢复次数单独记录，不计作模拟人的有效业务回复。
- 分别报告格式错误、恢复结果、业务质量与最终交付；不把辅助恢复称为无干预成功。
- 使用回归测试覆盖多余括号、修复成功、再次无效、正文变化拒绝及预算边界。

历史日志中的工具禁用事件和请求快照只反映对应调用；真实模型的写入能力需单独验证。
假 CLI 仅验证工具参数与控制器行为。

## 测试

运行：

```powershell
pwsh -NoProfile -File .\tests\Test-AgentDialogue.ps1
```

同文件补丁恢复和原有读取边界可分别运行
`pwsh -NoProfile -File .\tests\Test-SdlcCapture.ps1 -PatchErrorsOnly` 与 `-ReadErrorsOnly`。

使用假 CLI，不消耗模型额度。验证真实采集器接入、两边会话、知识提示隔离、待决草稿、
完成核验与调用预算，并检查首次及恢复调用中双方实际收到上述交接约定，不证明真实模型已经遵守约定。真实付费试跑没有自动启动。

历史记录的可选只读回放需显式提供 `-RecordedRunDirectory`；它不改写旧结果或调用模型，
也不把历史回放称为真实模型复测。