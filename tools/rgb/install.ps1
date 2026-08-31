#Requires -RunAsAdministrator
#Requires -Version 5.1
# 一次性：winget 安装官方 PawnIO + OpenRGB 系统服务（无窗口 SDK 6742）。
# 默认不装服务；本脚本必须带 INSTALLLEVEL=2。之后 ambient 只连 6742，不再启动 OpenRGB。
# 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按系统 ANSI 误读中文。

param(
    # 验收 SDK 成功后删除项目内 OpenRGB-App / PawnIO_setup.exe，让仓库变轻
    [switch]$PruneBundled,
    # 即使 SDK 已在听也强制 winget 重装
    [switch]$ForceReinstall
)

$ErrorActionPreference = "Stop"

# 控制台按 UTF-8 输出，避免 gsudo + powershell 5.1 把中文打成乱码
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
    $null = cmd /c "chcp 65001 >NUL"
} catch {
}

$root = $PSScriptRoot
$legacyTaskName = "OpenRGB-Server"
$serviceName = "OpenRGB"
$sdkPort = 6742
$bundledApp = Join-Path $root "OpenRGB-App"
$bundledPawn = Join-Path $root "PawnIO_setup.exe"
$userConfigDir = Join-Path $env:APPDATA "OpenRGB"

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host $Message -ForegroundColor $Color
}

function Test-SdkListening {
    # 与 Start-Ambient 一致：TCP 探测，不依赖管理员权限或英文 netstat。
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $sdkPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if (-not $ok) {
            return $false
        }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}

function Get-SdkPid {
    $tcp = Get-NetTCPConnection -LocalPort $sdkPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($tcp) { return $tcp.OwningProcess }
    return $null
}

function Get-WingetExe {
    $cmd = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }
    throw "未找到 winget.exe。请先安装 App Installer / winget。"
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory = $true)][string]$Id)
    $winget = Get-WingetExe
    $out = & $winget list --id $Id -e --accept-source-agreements --disable-interactivity 2>$null |
        Out-String
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return ($out -match [regex]::Escape($Id))
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Custom = "",
        [switch]$MachineScope,
        [switch]$Force
    )
    $winget = Get-WingetExe
    # 不要用 $args：那是 PowerShell 自动变量
    $wingetArgs = @(
        "install",
        "--id", $Id,
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    if ($MachineScope) {
        $wingetArgs += @("--scope", "machine")
    }
    if ($Force) {
        $wingetArgs += "--force"
    }
    if ($Custom) {
        # 追加给 MSI，不覆盖 winget 自己的静默参数
        $wingetArgs += @("--custom", $Custom)
    }
    Write-Step "   winget $($wingetArgs -join ' ')" "DarkGray"
    # 必须吃掉 stdout，否则会冒泡成上层函数返回值，把 [string]$ExePath 撑爆
    & $winget @wingetArgs 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
    # 已安装时 winget 常返回 -1978335189 (APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED)
    if ($code -eq 0 -or $code -eq -1978335189) {
        return
    }
    throw "winget install $Id 失败，exit=$code"
}

function Get-OpenRgbExe {
    $pf86 = ${env:ProgramFiles(x86)}
    $candidates = @(
        (Join-Path $env:ProgramFiles "OpenRGB\OpenRGB.exe")
    )
    if ($pf86) {
        $candidates += (Join-Path $pf86 "OpenRGB\OpenRGB.exe")
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    return $null
}

function Stop-LegacyOpenRgbStack {
    Write-Step "1/6 停止旧登录任务 / 便携 OpenRGB..."
    $stopAmbient = Join-Path $root "Stop-Ambient.ps1"
    if (Test-Path -LiteralPath $stopAmbient -PathType Leaf) {
        try {
            & $stopAmbient
        } catch {
            Write-Step "   Stop-Ambient 失败（可忽略）: $($_.Exception.Message)" "Yellow"
        }
    }

    $ErrorActionPreference = "Continue"
    try { schtasks /end /tn $legacyTaskName 2>$null | Out-Null } catch {}
    $existing = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
        Write-Step "   已删除任务 $legacyTaskName" "Green"
    } else {
        Write-Step "   任务 $legacyTaskName 不存在" "DarkGray"
    }

    # 先停系统服务，再杀残留进程，避免 MSI 升级时 6742 被占
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Stopped") {
        try { Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue } catch {}
    }
    Get-Process OpenRGB -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = "Stop"
}

function Install-OpenRgbDependencies {
    Write-Step "2/6 安装 PawnIO + VC++ 运行库（winget）..."
    if (Test-WingetPackageInstalled -Id "namazso.PawnIO") {
        Write-Step "   PawnIO 已安装，跳过" "Green"
    } else {
        Install-WingetPackage -Id "namazso.PawnIO" -MachineScope
        Write-Step "   PawnIO 安装完成" "Green"
    }

    if (Test-WingetPackageInstalled -Id "Microsoft.VCRedist.2015+.x64") {
        Write-Step "   VCRedist 已安装，跳过" "Green"
    } else {
        Install-WingetPackage -Id "Microsoft.VCRedist.2015+.x64" -MachineScope
        Write-Step "   VCRedist 安装完成" "Green"
    }
}

function Install-OfficialOpenRgb {
    Write-Step "3/6 安装官方 OpenRGB MSI，并强制系统服务 Feature..."
    $already = Test-WingetPackageInstalled -Id "OpenRGB.OpenRGB"
    $needForce = $ForceReinstall -or ($already -and -not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue))
    if ($already -and -not $needForce) {
        Write-Step "   OpenRGB.OpenRGB 已安装" "Green"
    } else {
        # MSI 默认 Level=1 不含服务；INSTALLLEVEL=2 才会注册 OpenRGB 服务
        Install-WingetPackage -Id "OpenRGB.OpenRGB" -MachineScope -Custom "INSTALLLEVEL=2" -Force:$needForce
        Write-Step "   OpenRGB.OpenRGB 安装完成" "Green"
    }

    $exe = Get-OpenRgbExe
    if (-not $exe) {
        throw "未找到 C:\Program Files\OpenRGB\OpenRGB.exe。winget 安装可能失败。"
    }
    Write-Step "   exe=$exe" "DarkGray"
    # 只返回路径字符串，避免 Write-Host / winget 输出混进调用方
    return [string]$exe
}

function Ensure-OpenRgbService {
    param([Parameter(Mandatory = $true)][string]$ExePath)

    Write-Step "4/6 确保系统服务 OpenRGB（delayed-auto / 依赖 PawnIO / 失败重启）..."
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step "   MSI 未注册服务，用官方 exe 补注册（仍不是便携包）..." "Yellow"
        $quoted = "`"$ExePath`""
        $create = sc.exe create $serviceName binPath= $quoted start= auto obj= LocalSystem DisplayName= "OpenRGB SDK Server"
        Write-Step "   sc create: $create" "DarkGray"
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            throw "无法创建服务 $serviceName"
        }
        sc.exe description $serviceName "Headless OpenRGB SDK on 127.0.0.1:6742 for RGB Ambient" | Out-Null
    }

    # delayed-auto：等 PawnIO / 驱动稍后再起，降低冷启动 SMBus 抢跑
    sc.exe config $serviceName start= delayed-auto | Out-Null
    sc.exe config $serviceName depend= PawnIO | Out-Null
    sc.exe failure $serviceName reset= 86400 actions= restart/3000/restart/10000/restart/30000 | Out-Null
    Write-Step "   服务 $serviceName 已配置" "Green"
}

function Import-OpenRgbServiceConfig {
    param([Parameter(Mandatory = $true)][string]$ExePath)

    Write-Step "5/6 复制用户配置到 service_config（服务不读 %AppData%）..."
    $installDir = [System.IO.Path]::GetDirectoryName($ExePath)
    $svcDir = [System.IO.Path]::Combine($installDir, "service_config")
    [void][System.IO.Directory]::CreateDirectory($svcDir)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = [System.IO.Path]::Combine($svcDir, "backup-$stamp")
    $copied = 0
    foreach ($name in @("OpenRGB.json", "Configuration.json")) {
        $src = [System.IO.Path]::Combine($userConfigDir, $name)
        if (-not [System.IO.File]::Exists($src)) {
            continue
        }
        $dst = [System.IO.Path]::Combine($svcDir, $name)
        if ([System.IO.File]::Exists($dst)) {
            [void][System.IO.Directory]::CreateDirectory($backupDir)
            [System.IO.File]::Copy($dst, [System.IO.Path]::Combine($backupDir, $name), $true)
        }
        [System.IO.File]::Copy($src, $dst, $true)
        $copied++
        Write-Step "   已复制 $name" "Green"
    }
    if ($copied -eq 0) {
        Write-Step "   未找到 %AppData%\OpenRGB 配置，服务将重新检测设备" "Yellow"
    }
}

function Start-OpenRgbSdk {
    Write-Step "6/6 启动系统服务并等待 127.0.0.1:$sdkPort ..."
    $svc = Get-Service -Name $serviceName -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Start-Service -Name $serviceName
    }

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-SdkListening) {
            Write-Step "   SDK 已监听 $sdkPort PID $(Get-SdkPid)" "Green"
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Step "   SDK 未在 30s 内监听 $sdkPort。查看 C:\Program Files\OpenRGB\service_config\logs" "Yellow"
    return $false
}

function Remove-BundledOpenRgbPayload {
    Write-Step "删除项目内便携 OpenRGB / PawnIO 安装包..." "Yellow"
    foreach ($path in @($bundledApp, $bundledPawn)) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-Step "   已删除 $path" "Green"
    }
}

Stop-LegacyOpenRgbStack
Install-OpenRgbDependencies
$openRgbExe = Install-OfficialOpenRgb
Ensure-OpenRgbService -ExePath $openRgbExe
Import-OpenRgbServiceConfig -ExePath $openRgbExe
$ready = Start-OpenRgbSdk

Write-Host ""
if (-not $ready) {
    Write-Step "安装完成但 SDK 未就绪。不要启动 Ambient，不要删除 OpenRGB-App。" "Red"
    Write-Host "  Get-Service OpenRGB"
    Write-Host "  Get-Content `"C:\Program Files\OpenRGB\service_config\logs\*`" -Tail 50"
    exit 1
}

if ($PruneBundled) {
    Remove-BundledOpenRgbPayload
} elseif ((Test-Path -LiteralPath $bundledApp) -or (Test-Path -LiteralPath $bundledPawn)) {
    Write-Step "项目内仍有便携包。确认灯管正常后可减重：" "Yellow"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PruneBundled"
}

Write-Host ""
Write-Host "完成。官方系统服务常驻 6742 后，登录常驻 ambient（无需管理员）：" -ForegroundColor Cyan
Write-Host "  python `"$root\test.py`""
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$root\Install-Ambient.ps1`""
Write-Host "不要手动打开开始菜单里的 OpenRGB 窗口，会和系统服务抢设备。" -ForegroundColor DarkGray
exit 0
