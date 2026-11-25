# 2026-11-25 复合发布回滚入口

本批完成[后续计划](../ROADMAP.md)的优先项 1：HUD＋anchor 复合发布的手动回滚入口、版本/差异预览与备份列表。历史记录见 [2026-11-24 工具箱更新](2026-11-24-toolbox.md)。

## 使用上的变化

- **备份列表**：无参数运行入口即可列出 `.tmp/releases/hud-*` 批次，显示创建时间、状态、HUD/anchor 源码指纹、产物数量和备份完整性；损坏或不兼容记录保留并说明原因。
- **差异预览**：按文件显示当前哈希、发布时哈希、备份哈希与恢复动作；后来写入会标记为冲突，不改动任何文件。
- **手动回滚**：从列表中选择批次并用绝对或相对路径传入；复用仓库部署锁、运行时停止/启动与健康检查，恢复产物后核对哈希与 self-test。
- **现场保护**：预检冲突或停止期间出现新写入时不动产物、重启原运行时；写入后的失败用回滚前备份恢复并重启，保留失败批次供审阅。成功回滚不改写原批次 manifest。

## 命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1 -Preview '<release>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/startup/Restore-ToolboxHudRelease.ps1 -RollbackRelease '<release>'
```

旧的 `Deploy-Toolbox.ps1 -RollbackRelease` 仍只接受单独 HUD 发布记录，不能用于复合批次。

## 边界

回滚只恢复 HUD 与 anchor 产物，不回退 AHK/Python/PowerPolicy 源码、个人 TOML、凭证或偏好；复合发布的备份范围与单目录发布不同。批次目录与回滚前备份位于 Git 忽略的 `.tmp/releases/`，需按本机需要保留。真实重启、灯光/音频设备与多屏场景不在本批验证范围。

## 验证与证据

新增临时夹具测试，真实执行文件备份/恢复、列表与预览、后来写入冲突、停止期间漂移、写入后失败恢复及跨仓库拒绝；运行时以桩代替。修改过的 PowerShell 文件通过 AST/BOM 解析检查；在本机既有历史批次上实际运行列表与只读预览，当前产物与该批次一致且无冲突。测试未在生产实例制造故障，也未重载常驻。
