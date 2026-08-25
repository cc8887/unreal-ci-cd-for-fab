# UE 版本验证参考

仅在多版本构建失败、运行验证异常或需要声明兼容性结论时读取本文件。

## 结论层级

- **编译通过**：目标模块在指定 Target 与 Configuration 下由 UBT 成功构建。
- **打包通过**：UAT BuildPlugin 成功且本轮 ZIP 可验证。已有 ZIP 不能代替本轮构建。
- **行为通过**：与改动相关的 Automation Test 和 Commandlet 在代表版本实际运行成功。
- **跨版本一致**：对相同输入生成的结构化结果规范化后，关键业务字段语义一致。

最终报告分别列出这些结论，不要用“全绿”掩盖只验证了其中一层的情况。

## Windows 工具链

先从引擎 UBT 日志确认它实际选择的 MSVC，而不是根据 Visual Studio 安装目录猜测。PowerShell 调用带多段点号的编译器版本参数时，将整个参数作为一个字符串传入：

```powershell
UnrealBuildTool.exe UnrealEditor Win64 Development `
  -Project="$ProjectRoot\Project.uproject" `
  -Compiler=VisualStudio2022 `
  "-CompilerVersion=14.32.31326"
```

UE 4.27 的部分 AutomationTool 发行版会在 Game Target 编译时附加 `-2017`。若宿主没有 VS2017，而插件本身可用受支持的 VS2022 工具链编译，则直接用 UBT 验证 Editor、Game Development 和 Game Shipping，并在结论中注明 UAT 宿主限制。

UE 5.0 AutomationTool 依赖 .NET Core 3.1。优先使用引擎自带的 dotnet host；本机只有新运行时时，可在隔离进程设置 `DOTNET_ROLL_FORWARD=Major` 做本地验证，不要把宿主运行时缺失归因于插件源码。

## 运行验证

Automation Test 至少覆盖最老版本、API 边界版本和最新版本。测试日志已报告全部通过但编辑器在退出阶段崩溃时，先定位崩溃模块；若是临时 HostProject 自动启用的无关插件，在临时 `.uproject` 中禁用它并重跑，必须取得干净退出后才报告通过。

Commandlet 验证应包含：

- 正常输入的退出码、报告数量和 verdict。
- 一个确定触发阈值或策略失败的输入，确认非零退出码及 violation 内容。
- 跨版本关键字段对比。排除生成时间、主机绝对路径和日志顺序等非语义字段。

使用 `-NullRHI -Unattended -NoSplash -NoP4 -UTF8Output` 降低宿主差异，但不能因此跳过实际命令执行。

## 失败归因

按顺序区分：宿主依赖、引擎/UAT 限制、临时项目默认插件、插件编译错误、插件行为错误。只有最后两类才修改用户插件源码；其他类别记录可复现命令和采用的隔离方式。
