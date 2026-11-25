# 2026-11-25 Caffeine 与托盘验证

本批完成[后续计划](../ROADMAP.md)的优先项：核对托盘图标与实际防休眠状态的一致性，并把运行结果与视觉结果分开记录。历史记录见[配置备份与迁移](2026-11-25-config-transfer.md)。

## 使用上的变化

- `CaffeineIndicator` 增加可注入的托盘后端，显示/隐藏/换图标不再直接依赖全局 `TrayHost` 调用，便于在隔离夹具中验证“图标跟随真实 Coffee 状态”。
- 托盘状态仍由 `CaffeineIndicator.IsActive()` 判定：PID + 创建 FILETIME、stop.flag、有效期与 `coffee_dir` 配置；与 PowerPolicy 的 `Test-CaffeineActive` 使用同一契约。
- Explorer 重启恢复由 `TrayHost.OnTaskbarCreated` 以 `NIM_ADD` 重新登记已有图标；`SendIcon` 增加测试注入点，可在不调用 Shell 的前提下验证重建动作。

## 验证与边界

运行结果已用真实状态文件与隔离托盘后端验证：有效状态显示、停止/到期/PID 复用隐藏、主题切换换图、Explorer 重启重新登记；专注夹具输出 `PASS: caffeine tray regressions`。托盘注册成功或协议通过**不等于**图标在任务栏可见。

视觉结果（咖啡杯出现/消失、浅/深色对比度、展开区域位置、实际 Explorer 重启后的可见性）尚未在可见桌面确认；合盖、睡眠与防休眠效果仍按电源专项矩阵单独验收。逐项记录见[功能检查记录](../../tools/settings/FUNCTION-REVIEW.md)。

未重载常驻、未重启 Explorer、未修改电源策略或四份个人配置。
