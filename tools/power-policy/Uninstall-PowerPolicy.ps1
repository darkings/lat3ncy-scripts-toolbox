# Uninstall-PowerPolicy.ps1
# 移除电源策略的计划任务，并把电源设置/Lenovo Smart Standby 恢复为默认行为。

$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot 'PowerPolicy.ps1'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    throw "Missing file: $engine"
}

Write-Host '=== 卸载电源策略 ==='
& pwsh -NoProfile -ExecutionPolicy Bypass -File $engine -Uninstall

Write-Host ''
Write-Host '剩余任务（应为空）：'
Get-ScheduledTask -TaskName 'PowerPolicy*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize

Write-Host '注意：常驻进程若仍在运行，会在下次检查到任务已删除后自然退出；'
Write-Host '      也可以直接结束 pwsh 进程（命令行含 PowerPolicy.ps1 -Run）。'
