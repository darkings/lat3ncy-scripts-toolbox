#Requires -Version 5.1
# 停止官方 OpenRGB 系统服务。日常 ambient 不需要调用本脚本。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

$ErrorActionPreference = "Continue"
$serviceName = "OpenRGB"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Elevator {
    if (Get-Command gsudo -ErrorAction SilentlyContinue) { return "gsudo" }
    if (Get-Command sudo -ErrorAction SilentlyContinue) { return "sudo" }
    return $null
}

$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Stopped") {
    if (Test-Admin) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    } else {
        $elev = Get-Elevator
        $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $inner = "Stop-Service -Name '$serviceName' -Force"
        if ($elev -eq "gsudo") {
            & gsudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -Command $inner
        } elseif ($elev -eq "sudo") {
            & sudo --inline $powershell -NoProfile -ExecutionPolicy Bypass -Command $inner
        } else {
            Write-Warning "需要管理员才能停止服务 $serviceName"
        }
    }
}

Get-Process OpenRGB -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "[OpenRGB] service stopped" -ForegroundColor Yellow
