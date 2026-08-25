# Unreal 插件持续修复接管

运行：`${run_id}`；阶段：`${stage}`

状态文件：`${state_path}`
失败版本：`${failed_versions}`
错误摘要：

`${error_summary}`

## 任务

读取状态、对应版本日志和必要的插件源码上下文。先理解错误语义，再做最小兼容修复。未知 C++/UBT 错误必须由 AI 判断，禁止照错误规则盲目替换源码。不得读取或输出 secrets，不得执行 `git commit`/`git push`。

策略阶段检查版本队列、路径边界和构建计划；修复阶段只修改 `plugin_repo` 内必要文件；最终审查确认全矩阵均成功且 ZIP 核验通过。

将结果写到状态目录的 `stage_XX_output.json`。格式：

```json
{
  "action": "retry | regression | stop",
  "summary": "简短说明",
  "changed_files": ["相对 plugin_repo 的路径"],
  "verdict": "needs_build | approve | reject"
}
```

首次策略用 `regression` 启动构建。修复后通常用 `retry`；需要强制全矩阵时用 `regression`；无法安全继续时用 `stop`。最终审查全绿时使用 `action=stop` 和 `verdict=approve`。
