[CmdletBinding()]
param(
    [switch]$Force
)

# ---------- 1. 关闭正在运行的 Navicat ----------
$navicatProcess = Get-Process -Name "Navicat*" -ErrorAction SilentlyContinue
if ($navicatProcess) {
    if (-not $Force -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "   Navicat Premium 正在运行！"
        Write-Host "   请先保存您的工作。"
        Write-Host ""
        Read-Host -Prompt "按 Enter 键关闭 Navicat 并继续..."
    }
    Write-Host "正在关闭 Navicat Premium..."
    Stop-Process -Name "Navicat*" -Force
    Start-Sleep -Seconds 1
}

# ---------- 2. 获取 Navicat 版本 ----------
# 常见的安装路径
$navicatPaths = @(
    "C:\Program Files\PremiumSoft\Navicat Premium\Navicat.exe",
    "C:\Program Files (x86)\PremiumSoft\Navicat Premium\Navicat.exe",
    "${env:ProgramFiles}\PremiumSoft\Navicat Premium\Navicat.exe",
    "${env:ProgramFiles(x86)}\PremiumSoft\Navicat Premium\Navicat.exe",
    "C:\Program Files\PremiumSoft\Navicat Premium 17\Navicat.exe",
    "C:\Program Files\PremiumSoft\Navicat Premium 16\Navicat.exe",
    "C:\Program Files\PremiumSoft\Navicat Premium 15\Navicat.exe"
)
$exePath = $null
foreach ($path in $navicatPaths) {
    if (Test-Path $path) {
        $exePath = $path
        break
    }
}

if (-not $exePath) {
    # 尝试从注册表寻找版本
    $regRoots = @("HKCU:\Software\PremiumSoft\NavicatPremium\17", "HKCU:\Software\PremiumSoft\NavicatPremium\16", "HKCU:\Software\PremiumSoft\NavicatPremium\15")
    $regFound = $false
    foreach ($r in $regRoots) {
        if (Test-Path $r) {
            $regFound = $true
            break
        }
    }
    if (-not $regFound) {
        Write-Host "未找到 Navicat Premium 可执行文件或注册表项，请检查安装。" -ForegroundColor Yellow
    }
}

$fullVersion = "17.0.0"
$version = 17
if ($exePath) {
    $versionInfo = (Get-Item $exePath).VersionInfo
    $fullVersion = "$($versionInfo.FileMajorPart).$($versionInfo.FileMinorPart).$($versionInfo.FileBuildPart)"
    $version = $versionInfo.FileMajorPart
    Write-Host "检测到 Navicat Premium 版本: $fullVersion"
} else {
    Write-Host "使用默认支持版本扫描 (15/16/17)..."
}

# ---------- 3. 根据主版本号确定注册表路径 ----------
switch ($version) {
    17 { $regRoot = "HKCU:\Software\PremiumSoft\NavicatPremium\17" }
    16 { $regRoot = "HKCU:\Software\PremiumSoft\NavicatPremium\16" }
    15 { $regRoot = "HKCU:\Software\PremiumSoft\NavicatPremium\15" }
    default {
        Write-Host "不支持版本 '$version'，脚本仅支持 15/16/17。" -ForegroundColor Red
        exit 1
    }
}

# ---------- 4. 删除注册表中的哈希项 ----------
# 查找名称为 32 位十六进制大写字母的子键
if (Test-Path $regRoot) {
    $subKeys = Get-ChildItem -Path $regRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^[0-9A-F]{32}$' }
    foreach ($key in $subKeys) {
        $hash = $key.PSChildName
        Write-Host "正在删除注册表子键: $hash"
        Remove-Item -Path $key.PSPath -Force -Recurse
    }

    # 查找名称匹配的注册表值
    $properties = Get-ItemProperty -Path $regRoot -ErrorAction SilentlyContinue
    if ($properties) {
        $valueNames = $properties.PSObject.Properties | Where-Object { $_.Name -match '^[0-9A-F]{32}$' } | ForEach-Object { $_.Name }
        foreach ($valName in $valueNames) {
            Write-Host "正在删除注册表值: $valName"
            Remove-ItemProperty -Path $regRoot -Name $valName -Force
        }
    }
}

# ---------- 5. 删除文件系统中的哈希文件 ----------
$appDataPath = "$env:APPDATA\PremiumSoft CyberTech\Navicat CC\Navicat Premium"
if (Test-Path $appDataPath) {
    $hiddenFiles = Get-ChildItem -Path $appDataPath -File -Force | Where-Object { $_.Name -match '^\.([0-9A-F]{32})$' }
    foreach ($file in $hiddenFiles) {
        Write-Host "正在删除文件: $($file.Name)"
        Remove-Item -Path $file.FullName -Force
    }
}

# ---------- 6. 高版本（17.3.7+）额外清理凭据 ----------
$needsCredentialCleanup = $false
if ($version -eq 17) {
    $parts = $fullVersion -split '\.'
    if ($parts.Count -ge 3) {
        $minor = [int]$parts[1]
        $patch = [int]$parts[2]
        if ($minor -gt 3 -or ($minor -eq 3 -and $patch -ge 7)) {
            $needsCredentialCleanup = $true
        }
    }
}

if ($needsCredentialCleanup) {
    # 尝试删除常见的 Windows 凭据目标
    $targets = @("NavicatPremium", "Navicat", "PremiumSoft")
    foreach ($target in $targets) {
        # 使用 cmdkey 检查是否存在
        $result = cmdkey /list 2>$null | Select-String $target
        if ($result) {
            Write-Host "正在删除 Windows 凭据: $target"
            cmdkey /delete:$target 2>$null
        }
    }
}

Write-Host "重置完成！" -ForegroundColor Green