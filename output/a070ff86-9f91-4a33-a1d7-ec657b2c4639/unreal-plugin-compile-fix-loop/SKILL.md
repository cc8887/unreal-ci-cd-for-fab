---
name: unreal-plugin-compile-fix-loop
description: 跨 Unreal Engine 4.27 和 5.0–5.8 编译、诊断并回归验证 C++ 插件。用于多引擎兼容性修复、Editor/Game/Shipping 目标检查、自动化测试或 Commandlet 行为验证及 ZIP 安全核验；不用于单版本日常编译，也不自动提交或推送 Git。
metadata:
  version: 1.1.0
  cn_name: Unreal 插件持续编译修复
---

# Unreal Plugin Compile Fix Loop

## 触发

当用户要求跨 Unreal Engine 版本编译、诊断、修复并回归验证插件时使用本技能。技能只修改用户指定的插件源码并执行验证；**绝不执行 `git commit` 或 `git push`**。

## 默认范围

- 引擎矩阵：UE `4.27`, `5.0`, `5.1`, `5.2`, `5.3`, `5.4`, `5.5`, `5.6`, `5.7`, `5.8`
- 流水线仓库：调用时的当前工作目录，或参数 `pipeline_repo`
- 配置：`<pipeline_repo>/config.json`
- 插件仓库：优先取参数；否则取配置中的 `PluginSourceDirectory`
- 最大 AI 修复轮数：`3`
- 引擎根目录：保留配置值，并补充由 `ProgramFiles` 推导出的 Epic Games Launcher 目录

## 唯一入口

```powershell
& python scripts/run.py --params params.json
& python scripts/run.py --resume
& python scripts/run.py --reset
```

```bash
python3 scripts/run.py --params params.json
python3 scripts/run.py --resume
python3 scripts/run.py --reset
```

`--params` 只接受现有 UTF-8 JSON 文件路径，禁止内联 JSON。首次运行必填；`--resume` 无需参数文件，并通过 `.run_state/active_run.json` 安全定位活动运行。

```json
{
  "pipeline_repo": "<pipeline-repo>",
  "plugin_repo": "<plugin-repo>",
  "config_path": "<pipeline-repo>/config.json",
  "engine_versions": ["4.27", "5.0", "5.1", "5.2", "5.3", "5.4", "5.5", "5.6", "5.7", "5.8"],
  "max_repair_rounds": 3,
  "dry_run": false
}
```

`dry_run` 仅用于验证参数、状态机和模拟构建，不启动 PowerShell 或真实构建。

## 阶段

1. **AI 策略**：读取参数、配置和仓库状态，写 `stage_01_output.json`。
2. **构建诊断（auto-long）**：默认仅构建失败/待处理版本；逐版本生成临时单版本配置并调用 `Tools/package_plugin.ps1`。
3. **AI 修复桥接**：未知错误由 AI 结合源码处理；禁止脚本盲改 C++。
4. **全矩阵回归（auto-long）**：源码变化后强制重建全部版本，并核验 ZIP。
5. **AI 最终审查**：确认全矩阵结果并输出最终结论。

## 分层验证

构建 ZIP 只证明插件可被 UAT 打包，不足以证明工具行为一致。若插件包含 Automation Test、Commandlet 或结构化报告，AI 最终审查还必须按用户任务执行相关运行验证：

1. 全版本至少编译 Editor、Game Development 和 Game Shipping 所需模块。
2. 在最老版本、兼容性边界版本和最新版本运行相关 Automation Test；当前默认代表版本为 `4.27`、`5.0`、`5.8`。
3. 对 Commandlet 同时验证成功路径和至少一个策略失败路径，并检查退出码、报告条目与关键指标，而不是只检查文件存在。
4. 同一输入跨版本运行时，对规范化后的结构化结果做语义比较；时间戳、绝对路径等环境字段不参与比较。

遇到引擎宿主、工具链或 UAT 特例时，先读取 [UE 版本验证参考](references/ue-version-validation.md)，只把已复现且与插件源码有关的问题交给 AI 修复。

自动阶段默认 `wait_for_completion=true`：当前 `run.py` 调用前台同步等待整批目标版本完成，worker 仅更新 state、写提示和 `RESUME_READY.txt`，不调用 `box_cli.py` 拉起重复 AI 会话；完成并进入 `waiting_ai` 后，当前调用打印清晰状态并返回 `20` 交由当前 AI 接管。只有显式设置 `wait_for_completion=false` 才通过脱离式 worker 后台执行，标准输出和错误写入运行日志，调度器确认启动后返回 `21`，worker 完成后可通过 `box_cli.py` 唤起新 AI。初始化或等待 AI 输出返回 `20`，这不是异常。

## AI 接管协议

等待 AI 时查看：

- `.run_state/<run_id>/state.json`
- `.run_state/<run_id>/stage_XX_input.json`
- `.run_state/<run_id>/stage_XX_prompt.md`

AI 必须原子写入对应的 `.run_state/<run_id>/stage_XX_output.json`：

```json
{
  "action": "retry",
  "summary": "已修改兼容性代码，重试失败版本",
  "changed_files": ["Source/MyPlugin/Private/Foo.cpp"],
  "verdict": "needs_build"
}
```

`action` 仅允许：

- `retry`：回到失败版本构建；超过 `max_repair_rounds` 自动停止。
- `regression`：进入强制全矩阵回归。
- `stop`：停止；仅最终审查阶段且全矩阵全绿、`verdict` 为 `approve`/`approved`/`pass` 时标记完成。

阶段 1 通常输出 `regression`（进入首次构建时实现会归一化到构建阶段）；阶段 3 输出 `retry`、`regression` 或 `stop`；阶段 5 输出 `stop`。

## 断点续跑与重置

- `--resume` 无需 `--params`，从安全活动指针消费当前 AI 输出，或继续未完成自动阶段。
- 每份 AI 输出消费后归档到 `consumed/`，避免重复消费。
- `--reset` 仅清理活动指针指向、且经校验位于本技能 `.run_state` 下的运行目录，再重新初始化。
- 每次使用 `--params`（且不带恢复选项）都生成唯一新 `run_id`，不会复用已完成或已停止状态。

## 安全边界

- 不读取、打印或上传 secrets。
- 自动规则只分类和建议，不执行源码替换。
- 仅允许清理当前技能运行目录内的临时文件。
- 已存在 ZIP 必须通过核验，但不能据此假定本轮构建成功。
- ZIP 必须可打开，包含 `.uplugin` 与 Win64 DLL；发现 `.env`、私钥或明显凭据文件名即失败。
- 仅 Windows 支持真实构建；其他平台返回明确错误。
- 所有子进程使用参数数组，禁止 `shell=True`。

## 结果

只有全矩阵每个版本真实构建成功、ZIP 核验通过、任务要求的运行验证通过且 AI 最终审查批准，状态才是 `completed`。完整日志和每版本结果保存在 `.run_state/<run_id>/`。
