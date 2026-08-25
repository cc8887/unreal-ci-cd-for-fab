# Assets

- `repair_prompt.md`：AI 策略、修复桥接和最终审查的固定约束与输出协议。
- `error-rules.json`：编译错误分类与非破坏性建议。规则不会自动修改 C++ 源码。

运行时模板会替换 `${run_id}`、`${stage}`、`${failed_versions}`、`${error_summary}`、`${state_path}`。
