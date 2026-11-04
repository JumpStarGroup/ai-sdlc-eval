# 结构化知识参与者

这是独立维护工具，不是四阶段主线的必需依赖。
[知识 Schema](../../profiles/knowledge.schema.json) 为通用框架资产；
知识、批准来源、校准样本是外部业务资产。

新聊天必须显式指定知识，恢复聊天使用已有会话中冻结的配置：

```powershell
pwsh -NoProfile -File .\tools\Start-KnowledgeChat.ps1 `
  -KnowledgeFile C:\evaluation-config\cases\knowledge.json `
  -SessionDirectory C:\evaluation-runs\manual-new

pwsh -NoProfile -File .\tools\Start-KnowledgeChat.ps1 `
  -SessionDirectory C:\evaluation-runs\manual-new -Resume
```

实际模型调用可能产生费用。参与者只选择有来源的已批准事实；
`Prepare/Resolve/Acknowledge` 分离，显示回答不等于人工已经转发。
会话输入及回执身份检查防止混用知识版本，不代表自动语义正确性或业务批准。

框架聊天回归 `tests\Test-KnowledgeChat.ps1` 使用临时生成的合成知识，无真实项目依赖。
历史业务迁移和校准测试及其业务断言保存在外部，需显式指定框架与数据路径：

```powershell
pwsh -NoProfile -File C:\evaluation-config\tests\Test-KnowledgeParticipant.ps1 `
  -FrameworkRoot C:\framework -CasesDirectory C:\evaluation-config\cases
```

该外部数据集须包含历史知识、批准来源、Oracle 与 `knowledge-participant.calibration.json`；
可再用 `-DecisionDirectory` 比较实际预测，不把结构校验当作模型语义通过。
