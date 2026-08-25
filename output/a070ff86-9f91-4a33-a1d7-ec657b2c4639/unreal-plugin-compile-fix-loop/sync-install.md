# 同步与安装

将整个 `unreal-plugin-compile-fix-loop` 目录复制到 Box 用户技能目录，保持目录结构不变。无需安装 Python 第三方依赖。

验证：

```powershell
python scripts/run.py --help
python -m py_compile scripts/run.py scripts/lib/assets.py scripts/stages/common.py scripts/stages/build_worker.py scripts/stages/regression_worker.py
```

创建 UTF-8 `params.json` 后从技能根目录运行入口。运行状态只写入技能目录的 `.run_state/`。升级技能前保留该目录即可继续 `--resume`；若同步工具排除运行数据，请先完成或显式重置当前运行。

技能不会自动执行 Git 提交或推送。
