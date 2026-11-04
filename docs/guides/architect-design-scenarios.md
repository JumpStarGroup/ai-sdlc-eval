# 四阶段与三层配置

统一入口 [Invoke-SDLC-Eval.ps1](../../tools/Invoke-SDLC-Eval.ps1) 覆盖四阶段。
完整参数和隔离限制见 [README](../../README.md)，新增业务见[外部场景指南](adding-business-scenarios.md)。

| 阶段 | 角色 | 输入与评价 |
| --- | --- | --- |
| `req` | PM | 起始需求、私有参与者知识；独立模型评分 |
| `design` | Architect | 人工确认需求；按需澄清与独立模型评分 |
| `dev` | Dev | 人工确认设计和参考需求；单次编码与独立后端测试 |
| `test` | Test | 冻结 Dev 交付；独立后端只读复验 |

基础架构层存放在框架；项目层与业务场景层存放在外部配置目录。
被测产品在另一个仓库；运行证据在外部运行目录。
[示例项目](../../examples/project.json)和[示例场景](../../examples/scenario.json)仅是合成模板。
项目地址、业务输入和模型运行结果不是框架源码。

`design` 就是 Architect，不是已取消的 Planner。
阶段不自动批准或串联；仅 Dev 可用 `-WithTest` 显式接续 Test。
后端通过不等于 Web 或业务验收通过。
