# 2026-11-25 Raycast 脚本参数

本批完成[后续计划](../ROADMAP.md)的优先项 1（现为已完成项）：成功提示、仅失败提示、静默模式与诊断输出范围。历史记录见 [HUD 复合回滚](2026-11-25-hud-rollback.md) 与 [2026-11-24 工具箱更新](2026-11-24-toolbox.md)。

## 使用上的变化

- 工具箱设置的 **Raycast 脚本** 页新增“成功提示方式”和“诊断输出范围”，自动保存，下次调用脚本生效。
- `success`（默认）保持原有成功与失败 Toast；`failure` 只提示失败；`silent` 不弹通知。所有顶层入口统一使用共用包装函数；RapidOCR 的独立进程通过 `--notify-mode` 读取同一选择。
- `full`（默认）保留诊断的日志摘录与定位细节；`brief` 只保留结论标记，不影响 `-Restart` 门控。
- 配置缺失或格式错误时沿用默认值，入口门控仍在正文之前执行；不导出密钥，不产生第二套模块参数。

## 命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1 -Preview '<release>'
```

本批不涉及新的维护命令；设置入口仍为 Raycast 的 **Toolbox Settings** 或翻译面板的工具箱设置。

## 边界

这些参数只改变提示与输出详略，不改变 AHK 快捷键、Raycast 客户端键位、翻译/朗读/OCR 引擎或设备状态。Toast 的实际横幅展示、真实 OCR 结果与物理点击仍按既有专项矩阵记录，不以桩测试代替。

## 验证与证据

通过 PowerShell 5.1 在临时仓库中验证三种提示模式与非法值回退、BOM/语法检查、入口包装与 OCR 参数转发的静态契约；OCR 的模式决策用隔离桩验证。Python 的全部行为测试在本机受沙箱临时目录权限限制未能完整运行，需在常规环境按离线入口复跑。未重载常驻、未操作设备或修改个人配置。
