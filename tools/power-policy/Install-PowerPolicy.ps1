# Install-PowerPolicy.ps1
# 注册电源策略的两个计划任务：
#   <TaskName>           常驻循环（AtLogOn，靠 Lat3ncyToolbox-Watchdog 兜底拉起）
#   <TaskName>-OnLidEvent 合盖/开盖/断电 事件触发，做一次即时检查
#
# 幂等；需要管理员（注册计划任务、写 HKLM 的 Lenovo 键、改电源设置）。
# 数值来自 config.toml，解析后由 PowerPolicy.ps1 烘焙进任务参数。

$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot 'PowerPolicy.ps1'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    throw "Missing file: $engine"
}

Write-Host '=== 安装电源策略计划任务 ==='
& pwsh -NoProfile -ExecutionPolicy Bypass -File $engine -Install
if ($LASTEXITCODE -ne 0) {
    Write-Host ("[!!] PowerPolicy -Install 退出码 {0}" -f $LASTEXITCODE) -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '已安装任务：'
Get-ScheduledTask -TaskName 'PowerPolicy*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize

Write-Host '下一步：'
Write-Host '  - 确认 Lat3ncyToolbox-Watchdog 已注册（它会把本工具一起看护）'
Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File ..\startup\Install-ToolboxWatchdog.ps1'
Write-Host ("  - 日志: " + (Join-Path $env:LOCALAPPDATA 'lat3ncy-toolbox\power-policy.log'))
