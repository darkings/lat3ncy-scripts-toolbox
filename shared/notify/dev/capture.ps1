param(
    [string]$Icon = "✓",
    [string]$Text = "成功",
    [string]$Type = "success",
    [int]$Duration = 2500,
    [string]$OutFile = "$env:TEMP\notify_capture.png"
)

# 开发用截图脚本，不进生产调用链。
# 通过脚本位置向上找仓库根，AHK 可执行文件走环境变量 / 官方安装目录 / PATH。
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Get-ToolboxRepoRoot {
    param([string]$StartDir)

    $dir = $StartDir
    while ($dir) {
        $marker = Join-Path $dir 'ahk\main.ahk'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            return $dir
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) {
            break
        }
        $dir = $parent
    }
    throw "Unable to resolve repo root from $StartDir"
}

function Get-AutoHotkeyV2Executable {
    if ($env:LAT3NCY_AHK -and (Test-Path -LiteralPath $env:LAT3NCY_AHK -PathType Leaf)) {
        return $env:LAT3NCY_AHK
    }

    if ($env:LOCALAPPDATA) {
        $officialV2 = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2'
        foreach ($engineName in @('AutoHotkey64.exe', 'AutoHotkey32.exe')) {
            $candidate = Join-Path $officialV2 $engineName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    $command = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    throw "AutoHotkey v2 not found. Add it to PATH or set LAT3NCY_AHK to AutoHotkey64.exe."
}

$repoRoot = Get-ToolboxRepoRoot -StartDir $PSScriptRoot
$ahk = Get-AutoHotkeyV2Executable
$cli = Join-Path $repoRoot 'shared\notify\notify-cli.ahk'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
    throw "notify CLI not found: $cli"
}

# 启动通知（后台）
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ahk
$psi.Arguments = "/ErrorStdOut=UTF-8 `"$cli`" $Type `"$Icon`" `"$Text`" $Duration"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)

# 等待 HUD 出现
Start-Sleep -Milliseconds 600

# 截图
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
$g.Dispose()

# 保存全屏
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "Saved full screenshot to $OutFile size $($bounds.Width)x$($bounds.Height)"

# 计算通知预期位置（与 renderer 一致: 居中底部 0.82）
# 简化：裁剪底部中心区域
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$centerX = $workArea.X + $workArea.Width / 2
$centerY = $workArea.Y + $workArea.Height * 0.82
$cropW = 600
$cropH = 120
$cropX = [Math]::Max(0, [int]($centerX - $cropW/2))
$cropY = [Math]::Max(0, [int]($centerY - $cropH/2))
if ($cropX + $cropW -gt $bounds.Width) { $cropX = $bounds.Width - $cropW }
if ($cropY + $cropH -gt $bounds.Height) { $cropY = $bounds.Height - $cropH }

$cropped = $bmp.Clone([System.Drawing.Rectangle]::FromLTRB($cropX, $cropY, $cropX+$cropW, $cropY+$cropH), $bmp.PixelFormat)
$cropFile = [System.IO.Path]::ChangeExtension($OutFile, $null) + "_crop.png"
$cropped.Save($cropFile, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "Saved cropped to $cropFile at $cropX,$cropY ${cropW}x${cropH} center ${centerX},${centerY}"

$bmp.Dispose()
$cropped.Dispose()

$src = [System.Drawing.Bitmap]::FromFile($cropFile)
$zoomW = $src.Width * 3
$zoomH = $src.Height * 3
$zoomed = New-Object System.Drawing.Bitmap $zoomW, $zoomH
$gz = [System.Drawing.Graphics]::FromImage($zoomed)
$gz.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gz.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$gz.DrawImage($src, 0,0, $zoomW, $zoomH)
$gz.Dispose()
$zoomFile = [System.IO.Path]::ChangeExtension($OutFile, $null) + "_zoom.png"
$zoomed.Save($zoomFile, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "Saved zoom to $zoomFile"
$src.Dispose()
$zoomed.Dispose()

$proc.WaitForExit(4000) | Out-Null
if (-not $proc.HasExited) { $proc.Kill() }

Write-Host "Done"