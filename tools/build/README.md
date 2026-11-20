# C# 助手构建与来源记录

锚点和音频助手使用 Windows 自带 .NET Framework C# 编译器，无需安装 SDK 或 Python 包。从仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/build/Build-ManagedHelpers.ps1
# 使用命令输出的 ManifestPath，核对当前源码与该产物
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/build/Test-ManagedBuild.ps1 -ManifestPath 'C:\path\to\repo\.tmp\managed-builds\build-id\managed-build.json'
```

默认在 `.tmp/managed-builds/<guid>/` 新建隔离目录。可通过 `-OutputDirectory` 指定一个尚不存在的目录；入口拒绝复用已有目录，避免覆盖生产助手或其他文件。

产物包括 `anchor-locator.exe`、`audio-switcher.exe`、`managed-build.json`。manifest 记录每个源码/产物的 SHA-256、编译器路径/版本/哈希、完整编译参数、显式引用程序集的路径/哈希及 Git HEAD。脏工作区以源码文件哈希为准，不能仅凭 HEAD 认定产物版本。

构建后运行锚点的合成几何/协议 self-test，并核对两个助手的源码及产物哈希。音频助手没有不访问设备的 self-test，构建入口不会执行它。`Test-ManagedBuild.ps1` 只读取 manifest、源码和文件哈希，不加载或运行程序集；源码变化、产物变化、缺失/重复组件、越界路径均报错。

该记录用于核对本次构建的具体文件，不是数字签名，也不保证跨编译器或跨时间构建的 PE 字节完全一致。现有生产 exe 没有因此获得追溯证明；应在将来审阅并发布新产物时一起保存对应 manifest。**本入口不替换生产 exe、不重启 AHK、不切换音频。** 原 `shared/notify/build-anchor-locator.ps1` 仍可使用，但不会生成这份双助手来源记录。

离线套件已纳入来源验证的故障桩；Windows Actions 还会实际编译两种助手并执行锚点 self-test。远端执行结果需提交推送后获取。

2026-11-19 本机验证：两个助手实际编译成功，来源检查通过，锚点 self-test 通过。额外手工以 `--get/--list` 读取生产和候选音频助手，均返回 1 个活动设备；默认输出在查询前后保持 Realtek 扬声器，候选与生产结果相同。没有运行 `--toggle/--ensure/--recover/--set`；AirPods 建链、切换和超时仍待实测。日志在 `.tmp/continue-20261119/`。
