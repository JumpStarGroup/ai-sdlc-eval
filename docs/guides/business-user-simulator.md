# 历史 Oracle 工具维护

新评估使用 [三层统一入口](../../README.md)。历史 Oracle 执行器和报告器保留用于专门维护，
不要求新场景建立另一套配置。

[Invoke-PmEvaluation.ps1](../../tools/Invoke-PmEvaluation.ps1) 接收外部 `-ConfigFile`。
配置须显式提供 `oracle` 与 `domainProfile`，不再默认读取框架中的某个业务。
`capabilityProfile` 可引用通用旧 PM/Plan Profile；业务规则不能放进基础架构层。

历史报告及编号实验配置属于外部运行归档。原记录不要改写成当前格式，
也不要复用已经使用的输出目录。需要重跑时另建配置并选择新目录，
补齐明确的领域 Profile 和有效的路径、角色、模型授权。

业务专用回归及其夹具应随私有数据放在外部配置目录，不属于默认框架测试。
原项目的历史回归需要包含历史 Oracle、领域 Profile 的外部数据目录及框架路径：

```powershell
pwsh -NoProfile -File C:\evaluation-config\tests\Test-PmEvaluation.ps1 `
  -FrameworkRoot C:\framework -CasesDirectory C:\evaluation-config\cases -ProfilesOnly
```

该套件保留特定历史业务的预期断言，不声称是通用合成夹具。
原始业务资料、历史协议说明和结果需由外部配置/归档管理，不随框架发布。
