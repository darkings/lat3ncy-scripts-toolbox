# Uninstall-PowerPolicy.ps1
# 优雅停止常驻任务，恢复备份电源设置；Lenovo 服务保持禁用。

$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot 'PowerPolicy.ps1'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    throw "Missing file: $engine"
}

Write-Host '=== 卸载电源策略 ==='
& pwsh -NoProfile -ExecutionPolicy Bypass -File $engine -Uninstall
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host '剩余任务（应为空）：'
Get-ScheduledTask -TaskName 'PowerPolicy*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize

Write-Host '常驻已停止；请求已释放，电源设置已从备份恢复；Lenovo 服务保持禁用。'
