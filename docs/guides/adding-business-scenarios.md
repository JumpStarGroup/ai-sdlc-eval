# 新增外部业务场景

三层契约以 [README](../../README.md) 为准。不要在框架中添加实际业务知识或批次记录。

1. 将 [examples](../../examples) 复制到自己的配置目录；合成样例不是实际业务批准。
2. 编辑项目 `repositoryPath`、`runsRoot`、工作区路径和排除规则。
3. 在产品仓库安装需要的被测角色。框架默认角色是 `SDLCRole_PM/Architect/Dev/Test`；
   不同名称可通过自定义阶段 Profile 覆盖。
4. 用真实授权的知识和领域评分替换合成样例。Req 知识须含非空 `## 初始需求`。
5. 在场景 `stages` 中只配置需要的阶段，模型与输出标签仍用命令行传入。
6. 先执行 `ValidateOnly`，确认实际模型授权后才 `Run`。

Req 和 Design 分别默认使用框架的 [PM Profile](../../profiles/pm-clarification.json)、
[Architect Profile](../../profiles/architect-design.json)。工具、`policy.callLimit`、
交互提示等由阶段 Profile 提供；不要再为业务维护一份并行的对话模板。
Req 的初始业务请求保存在知识文档的 `## 初始需求`，Design 使用确认需求及阶段任务模板。
统一入口生成运行专用对话配置，并冻结输入以便审计。

外部目录可组织为 `projects/experiments/cases`，也可以放在同一目录。
相对引用以声明它们的 JSON 为基准，与当前 shell 工作目录无关。
阶段 Profile 中指向框架通用参与者和评分表的引用，应使用能解析到框架的路径。
场景可用 `stages.<stage>.phaseProfile` 选择完整的自定义阶段 Profile；
路径相对于场景 JSON，不能只提供部分政策字段。

扩展阶段的 `stages` 片段：

```json
{
  "design": {
    "inputFile": "../cases/confirmed-requirement.md",
    "rubricFile": "../cases/design-rubric.json"
  },
  "dev": {
    "inputFile": "../cases/confirmed-design.md",
    "verification": {
      "pythonExecutable": ".venv\\Scripts\\python.exe",
      "testPaths": ["tests"],
      "timeoutSeconds": 300
    }
  }
}
```

Dev 必须引用 `design.inputFile` 取得确认需求；不配置参与者或评分表。
只运行 Dev 时，该需求引用不必有 Design 评分表；实际执行 Design 时必须补齐。
Test 不新增 `stages.test`，从指定 Dev 交付取得输入。
项目内 `reportWorkspacePath` 声明 Test 报告布局，可选 `projectContractPath` 声明工作契约。

历史结果、模型输出和已经使用的批次配置放在运行目录；
人工确认的需求/设计及评分依据则是下一轮静态输入，应放外部配置目录，不应当作日志删除。
修改静态输入后新建运行，不回写过去的冻结证据。
