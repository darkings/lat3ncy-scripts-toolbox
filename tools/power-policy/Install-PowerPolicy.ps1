# Install-PowerPolicy.ps1
# 注册静默常驻任务，原生回调监听盖子/供电；移除旧事件任务。
#
# 幂等；需要管理员注册计划任务。不写 Lenovo 注册表，不启用其服务。
# 数值在常驻启动时读取 config.toml。

$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot 'PowerPolicy.ps1'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    throw "Missing file: $engine"
}

Write-Host '=== 安装电源策略计划任务 ==='
$hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File $engine -Install
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
